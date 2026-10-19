/// The Flask layer on top of andaime: blueprints, request dispatch, hooks, CSRF, login, static files and the template
/// globals (`request`, `session`, `url_for`, `current_user`, `config`...).
///
/// andaime gives one HTTP request at a time to a middleware; `FlaskApp.install` registers a single middleware that does
/// what `Flask.wsgi_app` does: build the `Request`, open the session, run `before_request` hooks, match the URL map,
/// check CSRF, call the view, run `after_request` hooks, save the session and write the `Response`.
module pgadmin.web.flask;

import std.algorithm : canFind, endsWith, startsWith;
import std.array : array, split, join, replace;
import std.conv : to;
import std.datetime : Clock;
import std.file : exists, isFile, read, timeLastModified;
import std.path : buildPath, buildNormalizedPath, absolutePath, extension, baseName;
import std.string : toLower, toUpper, strip, indexOf, representation;
import andaime.web.application : App;
import andaime.web.context : Context, Next;
import andaime.http.types : Method, methodName;
import andaime.http.multipart : classifyFormContentType, parseMultipart, FormContentType, FormCoding, MultipartPart;
import pgadmin.core.config;
import pgadmin.core.crypto;
import pgadmin.core.log;
import pgadmin.core.templates;
import pgadmin.core.value;
import pgadmin.jinja.runtime;
import pgadmin.model;
import pgadmin.web.context;
import pgadmin.web.http;
import pgadmin.web.routing;
import pgadmin.web.session;
import pgadmin.utils.preferences : Preferences;

alias View = Response delegate(Dict args);

/// A `flask.Blueprint` (and pgAdmin's `PgAdminModule`).
class Blueprint
{
    string name;
    string urlPrefix;
    string staticFolder;     /// absolute directory, or null
    string staticUrlPath;    /// relative to the prefix ("/static")
    Blueprint[] submodules;
    Blueprint[] parentmodules;

    private struct Pending
    {
        string rule;
        string endpoint;
        string[] methods;
        View view;
        bool csrfExempt;
        Value defaults;
    }

    private Pending[] pending;
    private bool registered;
    FlaskApp app;
    /// Label of the module in the preferences dialog (`LABEL`); null = none.
    Value label = Value(null);
    /// The module's preferences (`self.preference`); they are registered at start-up from the preference tables
    /// of `resources/prefs_*.json` (see `pgadmin.utils.preferences_data`).
    @property Preferences preference() => Preferences.module_(name);

    this(string name, string urlPrefix = null)
    {
        this.name = name;
        this.urlPrefix = urlPrefix is null ? "/" ~ name : urlPrefix;
    }

    /// `@blueprint.route(rule, endpoint=..., methods=[...])`; the endpoint defaults to `name` given here.
    void route(string rule, string endpoint, string[] methods, View view, bool csrfExempt = false,
            Value defaults = Value(null))
    {
        pending ~= Pending(rule, endpoint, methods, view, csrfExempt, defaults);
    }

    /// Called by the app when the blueprint is registered; subclasses register their routes in `setup`.
    void register(FlaskApp a)
    {
        if (registered)
            return;
        registered = true;
        app = a;
        a.blueprints[name] = this;
        a.allBlueprints ~= this;
        setup();
        auto mine = joinRule(urlPrefix, null);
        foreach (p; pending)
        {
            string rule = joinRule(urlPrefix, p.rule);
            auto r = new Rule(rule, name ~ "." ~ p.endpoint, p.methods, p.view);
            r.csrfExempt = p.csrfExempt;
            r.blueprint = name;
            r.defaults = p.defaults;
            a.map.add(r);
        }
        if (staticFolder.length)
        {
            auto sp = staticUrlPath.length ? staticUrlPath : "/static";
            auto rule = joinRule(urlPrefix, sp ~ "/<path:filename>");
            auto r = new Rule(rule, name ~ ".static", ["GET"], staticView(staticFolder));
            r.csrfExempt = true;
            r.blueprint = name;
            a.map.add(r);
        }
        foreach (m; submodules)
        {
            if (!m.parentmodules.canFind(this))
                m.parentmodules ~= this;
            m.register(a);
        }
    }

    /// Sets the folder served at `<prefix>/static` (relative to the `pgadmin` directory of the web tree).
    void staticDir(string relative)
    {
        import std.path : buildPath;
        staticFolder = buildPath(cfgStr("PGADMIN_WEB_DIR"), "pgadmin", relative, "static");
    }

    /// Override to add routes (`route(...)`) and hooks.
    void setup() {}

    /// i18n messages of this module (without the submodules').
    Value getOwnMessages() => Value.newDict();
    /// Menu items of this module: key -> list of items (dicts).
    Value getOwnMenuItems() => Value.newDict();
    string[] getExposedUrlEndpoints() => null;

    final Value messages()
    {
        auto res = getOwnMessages();
        foreach (m; submodules)
            res.dict.update(m.messages.dict);
        return res;
    }

    final string[] exposedEndpoints()
    {
        auto res = getExposedUrlEndpoints();
        foreach (m; submodules)
            res ~= m.exposedEndpoints;
        return res;
    }

    /// Menu items grouped by key and sorted by priority.
    final Value menuItems()
    {
        auto own = getOwnMenuItems();
        auto merged = new Dict;
        foreach (k, v; own.dict)
            merged[k] = Value(v.list.items.dup);
        foreach (m; submodules)
            foreach (k, v; m.menuItems.dict)
            {
                if (!merged.has(k))
                    merged[k] = Value.newList();
                merged[k].list.items ~= v.list.items;
            }
        foreach (k, v; merged)
        {
            import std.algorithm : sort, SwapStrategy;
            sort!((a, b) => a.get("priority").integer < b.get("priority").integer, SwapStrategy.stable)(v.list.items);
        }
        return Value(merged);
    }

    void registerPreferences() {}
    /// Called on logout for every module that implements it.
    void onLogout() {}
    bool hasLogoutHook() => false;
}

/// A view serving files from `folder` (a function, so each call gets its own closure).
View staticView(string folder)
{
    return (Dict args) => sendFromDirectory(folder, args["filename"].str);
}

private string joinRule(string prefix, string rule)
{
    if (prefix is null)
        prefix = "";
    if (rule is null)
        rule = "";
    // werkzeug: rule = prefix.rstrip('/') + '/' + rule.lstrip('/')  (blueprint with url_prefix '/' gives '/rule')
    while (prefix.length && prefix[$ - 1] == '/')
        prefix = prefix[0 .. $ - 1];
    if (rule.length == 0)
        return prefix.length ? prefix : "/";
    if (rule[0] != '/')
        rule = "/" ~ rule;
    return prefix ~ rule;
}

alias BeforeHook = Response delegate();
alias AfterHook = void delegate(Response r);
alias ErrorFn = Response delegate(Exception e);

/// Mimetypes used for static files (python mimetypes + the overrides pgAdmin adds).
string guessMimetype(string path)
{
    switch (path.extension.toLower)
    {
    case ".js", ".mjs": return "application/javascript";
    case ".css": return "text/css";
    case ".html", ".htm": return "text/html";
    case ".json", ".map": return "application/json";
    case ".svg": return "image/svg+xml";
    case ".png": return "image/png";
    case ".jpg", ".jpeg": return "image/jpeg";
    case ".gif": return "image/gif";
    case ".ico": return "image/vnd.microsoft.icon";
    case ".woff": return "font/woff";
    case ".woff2": return "font/woff2";
    case ".ttf": return "font/ttf";
    case ".otf": return "font/otf";
    case ".eot": return "application/vnd.ms-fontobject";
    case ".txt", ".sql", ".log": return "text/plain";
    case ".xml": return "text/xml";
    case ".csv": return "text/csv";
    case ".pdf": return "application/pdf";
    case ".zip": return "application/zip";
    case ".wasm": return "application/wasm";
    case ".mo": return "application/octet-stream";
    default: return "application/octet-stream";
    }
}

/// `send_from_directory(directory, filename)`: 404 when the file is missing or escapes the directory.
Response sendFromDirectory(string directory, string filename)
{
    foreach (part; filename.split("/"))
        if (part == ".." || part.startsWith("\\"))
            return notFoundResponse();
    auto base = absolutePath(directory).buildNormalizedPath;
    auto full = buildNormalizedPath(base, filename);
    if (!full.startsWith(base ~ "/") || !full.exists || !full.isFile)
        return notFoundResponse();
    return sendFile(full);
}

Response notFoundResponse() => new HTTPException(404).toResponse();

/// `send_file(path)` with Last-Modified, ETag and the configured max-age.
Response sendFile(string full, string mimetype = null, string downloadName = null, bool asAttachment = false)
{
    auto r = new Response;
    r.body = cast(string) read(full).idup;
    r.mimetype = mimetype.length ? mimetype : guessMimetype(full);
    auto mtime = full.timeLastModified.toUnixTime;
    r.setHeader("Last-Modified", httpDate(mtime));
    r.setHeader("ETag", `"` ~ to!string(mtime) ~ "-" ~ to!string(r.body.length) ~ `"`);
    r.setHeader("Cache-Control", "no-cache");
    if (downloadName.length || asAttachment)
        r.setHeader("Content-Disposition",
                (asAttachment ? "attachment" : "inline") ~ "; filename=\"" ~ (downloadName.length ? downloadName : baseName(full)) ~ "\"");
    return r;
}

/// Flask application object.
final class FlaskApp
{
    Map map;
    Blueprint[string] blueprints;
    Blueprint[] blueprintOrder;     /// the blueprints registered with `registerBlueprint` (top level)
    Blueprint[] allBlueprints;      /// every registered blueprint, nested ones included, in registration order
    BeforeHook[] beforeRequest;
    AfterHook[] afterRequest;
    SessionManager sessions;
    string staticFolder;
    string secretKey;
    void delegate()[] beforeAppStart;

    /// `run_before_app_start()`: module start-up hooks (preferences registration, timers).
    void runBeforeAppStart()
    {
        import pgadmin.utils.preferences_data : registerAllPreferences;
        registerAllPreferences();
        foreach (cb; beforeAppStart)
            cb();
    }
    Blueprint[] logoutHooks;
    /// Custom exception handlers: the first that accepts the exception turns it into a response.
    Response delegate(Exception) [] errorHandlers;
    /// Called after the user is loaded (login manager `unauthorized` view etc.)
    Response delegate() unauthorizedHandler;
    string loginView = "security.login";
    string logoutView = "security.logout";
    bool desktopMode;
    string[] csrfExemptBlueprints;
    string[] csrfExemptEndpoints;

    this()
    {
        map = new Map;
    }

    void registerBlueprint(Blueprint b)
    {
        if (b.name in blueprints)
            return;
        b.register(this);
        blueprintOrder ~= b;
    }

    void addStatic(string folder)
    {
        staticFolder = folder;
        auto r = new Rule("/static/<path:filename>", "static", ["GET"], staticView(folder));
        r.csrfExempt = true;
        map.add(r);
    }

    // ------------------------------------------------------------ url_for

    string urlFor(string endpoint, Dict values = null, bool external = false)
    {
        if (endpoint.startsWith("."))
        {
            auto bp = hasRequestContext && request() !is null ? request().blueprint : null;
            endpoint = (bp.length ? bp : "") ~ endpoint;
        }
        if (values is null)
            values = new Dict;
        else
            values = values.copy();
        // cache busting: add_internal_version
        auto verParam = cfgStr("APP_VERSION_PARAM");
        if (verParam.length)
        {
            auto exts = ConfigAccess.get("APP_VERSION_EXTN");
            bool add;
            if (values.has("filename"))
            {
                foreach (e; exts.iterItems())
                    if (values["filename"].toString.endsWith(e.toString))
                        add = true;
            }
            else
            {
                auto rs = map.forEndpoint(endpoint);
                if (rs.length == 1)
                    foreach (e; exts.iterItems())
                        if (rs[0].rule.endsWith(e.toString))
                            add = true;
            }
            if (add)
                values[verParam] = ConfigAccess.get("APP_VERSION_INT");
        }
        auto path = map.build(endpoint, values);
        auto root = cfgStr("APPLICATION_ROOT");
        if (root.length > 1)
            path = (root.endsWith("/") ? root[0 .. $ - 1] : root) ~ path;
        if (external && hasRequestContext && request() !is null)
            return request().scheme ~ "://" ~ request().host ~ path;
        return path;
    }

    // ------------------------------------------------------------ dispatch

    /// Registers the dispatcher as andaime middleware.
    void install(App vapp)
    {
        vapp.use((Context ctx, Next next) @system {
            handleRequest(ctx);
        });
    }

    private Request buildRequest(Context ctx)
    {
        auto vr = ctx.request;
        auto req = new Request;
        req.method = methodName(vr.method).idup;
        req.rawPath = vr.path.idup;
        req.path = urlUnquote(vr.path);
        req.queryString = vr.query.idup;
        foreach (h; vr.headers)
            req.headers ~= [h.name.idup, h.value.idup];
        req.data = vr.body.idup;
        req.args = parseQueryString(vr.query);
        req.form = new MultiDict;
        req.cookies = parseCookies(req.header("Cookie"));
        req.remoteAddr = ctx.clientIp().toString().idup;
        req.host = req.header("Host");
        auto xfp = req.header("X-Forwarded-Proto");
        if (xfp.length)
            req.scheme = xfp.split(",")[0].strip;
        // forms
        auto ct = req.contentType;
        if (ct.length)
        {
            FormContentType fct;
            string err;
            classifyFormContentType(ct, fct, err);
            if (err is null && fct.coding == FormCoding.urlEncoded)
            {
                foreach (k; parseQueryString(cast(string) req.data).keys)
                    foreach (v; parseQueryString(cast(string) req.data).getList(k))
                        req.form.add(k, v);
            }
            else if (err is null && fct.coding == FormCoding.multipart)
            {
                MultipartPart[] parts;
                auto e = parseMultipart(req.data, fct.boundary, parts);
                if (e is null)
                    foreach (p; parts)
                    {
                        if (p.filename !is null)
                        {
                            auto f = new FileStorage;
                            f.name = p.name;
                            f.filename = p.filename;
                            f.contentType = p.contentType;
                            f.data = p.data.idup;
                            req.files[p.name] ~= f;
                        }
                        else
                            req.form.add(p.name, sanitizeUtf8(cast(string) p.data.idup));
                    }
            }
        }
        return req;
    }

    private void handleRequest(Context ctx)
    {
        auto rc = new RequestContext;
        rc.raw = ctx;
        rc.request = buildRequest(ctx);
        rc.cspNonce = tokenUrlsafe(16);
        bindContext(rc);
        scope (exit)
            unbindContext();

        Response resp;
        try
            resp = process(rc);
        catch (HTTPException he)
            resp = he.toResponse();
        catch (Exception e)
        {
            logException(e);
            resp = errorResponse(e);
        }
        try
            resp = finalize(rc, resp);
        catch (Exception e)
        {
            logException(e);
            resp = internalServerError(e.msg);
        }
        writeResponse(ctx, resp);
    }

    private Response errorResponse(Exception e)
    {
        foreach (h; errorHandlers)
            if (auto r = h(e))
                return r;
        if (auto he = cast(HTTPException) e)
            return he.toResponse();
        // a view that returns None fails while the response is built: Werkzeug's generic 500 page (not the JSON of
        // pgAdmin's `all_exception_handler`, which only sees exceptions raised inside the view)
        if (cast(ViewReturnedNone) e)
            return new HTTPException(500).toResponse();
        return internalServerError(e.msg);
    }

    private Response process(RequestContext rc)
    {
        auto req = rc.request;
        // session
        auto cookieName = cfgStr("SESSION_COOKIE_NAME");
        auto cookie = req.cookies.get(cookieName, null);
        Session s;
        if (cookie.length && cookie.canFind('!'))
        {
            auto bang = cookie.indexOf('!');
            auto sid = cookie[0 .. bang];
            auto digest = cookie[bang + 1 .. $];
            s = sessions.exists_(sid) ? sessions.get(sid, digest, req.path) : sessions.newSession(req.path);
        }
        else
            s = sessions.newSession(req.path);
        rc.session = s;
        loadUser(rc);

        auto m = map.match(req.path, req.method);
        if (m.rule is null && m.redirectTo.length)
        {
            auto q = req.queryString.length ? "?" ~ req.queryString : "";
            return redirect(m.redirectTo ~ q, 308);
        }
        if (m.rule is null)
        {
            if (m.allowed.length)
            {
                auto r = new HTTPException(405).toResponse();
                r.setHeader("Allow", m.allowed.join(", "));
                return r;
            }
            return new HTTPException(404).toResponse();
        }
        req.endpoint = m.rule.endpoint;
        req.blueprint = m.rule.blueprint;
        req.viewArgs = Value(m.args);

        foreach (h; beforeRequest)
            if (auto r = h())
                return r;

        if (!m.rule.csrfExempt && !csrfExemptBlueprints.canFind(m.rule.blueprint)
                && !csrfExemptEndpoints.canFind(m.rule.endpoint) && csrfMethods.canFind(req.method))
        {
            auto bad = checkCsrf(req, s);
            if (bad !is null)
                return bad;
        }
        if (req.method == "OPTIONS")
        {
            auto r = new Response("", 200);
            r.setHeader("Allow", m.rule.methods.join(", "));
            return r;
        }
        auto r = m.rule.view(m.args);
        if (req.method == "HEAD" && r !is null)
        {
            r.contentLength = r.body.length;
            r.body = "";
        }
        return r;
    }

    private immutable string[] csrfMethods = ["GET", "POST", "PUT", "DELETE"];

    private Response finalize(RequestContext rc, Response resp)
    {
        if (resp is null)
            resp = new Response("", 200);
        foreach_reverse (h; afterRequest)
            h(resp);
        auto s = rc.session;
        if (s !is null)
        {
            auto cookieName = cfgStr("SESSION_COOKIE_NAME");
            auto path = rc.request.path;
            if (s.empty)
            {
                sessions.remove_(s.sid);
                if (s.modified)
                    resp.deleteCookie(cookieName, cfgStr("SESSION_COOKIE_PATH"));
            }
            else if (s.modified)
            {
                sessions.put(s, path);
                s.modified = false;
                CookieSpec c;
                c.name = cookieName;
                c.value = s.sid ~ "!" ~ s.hmacDigest;
                c.path = cfgStr("SESSION_COOKIE_PATH");
                c.secure = cfgBool("SESSION_COOKIE_SECURE");
                c.httpOnly = cfgBool("SESSION_COOKIE_HTTPONLY");
                c.sameSite = cfgStr("SESSION_COOKIE_SAMESITE");
                auto dom = ConfigAccess.get("SESSION_COOKIE_DOMAIN");
                if (dom.truthy)
                    c.domain = dom.toString;
                auto days = cfgInt("SESSION_EXPIRATION_TIME");
                c.expires = httpDate(Clock.currTime.toUnixTime + days * 86_400);
                resp.setCookie(c);
            }
        }
        return resp;
    }

    private void writeResponse(Context ctx, Response r)
    {
        if (r.eventStream !is null)
        {
            import andaime.web.stream : EventStream, runStream;
            ctx.response.status = r.status;
            foreach (h; r.headers)
            {
                if (h[0].toLower == "content-type")
                    continue;
                ctx.addHeader(h[0], h[1]);
            }
            foreach (c; r.cookies)
                ctx.addHeader("Set-Cookie", cookieHeader(c));
            auto es = EventStream(r.eventStream);
            runStream(ctx, es);
            return;
        }

        if (r.stream !is null)
        {
            import andaime.web.stream : Stream, runStream, StreamWriter;
            ctx.response.status = r.status;
            ctx.response.contentType = r.contentType();
            foreach (h; r.headers)
            {
                if (h[0].toLower == "content-type")
                    continue;
                ctx.addHeader(h[0], h[1]);
            }
            foreach (c; r.cookies)
                ctx.addHeader("Set-Cookie", cookieHeader(c));
            auto st = Stream(r.contentType(), (scope StreamWriter w) {
                r.stream((const(char)[] chunk) {
                    w.write(chunk);
                    w.flush();
                });
            }, r.contentLength);
            runStream(ctx, st);
            return;
        }

        ctx.response.status = r.status;
        ctx.response.contentType = r.contentType();
        ctx.response.body.clear();
        ctx.response.body.put(r.body);
        foreach (h; r.headers)
        {
            if (h[0].toLower == "content-type")
                continue;
            ctx.addHeader(h[0], h[1]);
        }
        foreach (c; r.cookies)
            ctx.addHeader("Set-Cookie", cookieHeader(c));
    }

    // ------------------------------------------------------------ CSRF (Flask-WTF compatible behaviour)

    string generateCsrf()
    {
        auto s = session();
        auto raw = s.get("csrf_token");
        if (!raw.isString)
        {
            raw = Value(tokenUrlsafe(32));
            s["csrf_token"] = raw;
        }
        auto mac = Base64Url(hmac(Digest.sha256, cfgStr("CSRF_SESSION_KEY").representation, raw.str.representation));
        return raw.str ~ "." ~ mac;
    }

    private Response checkCsrf(Request req, Session s)
    {
        string token;
        auto hdrs = ConfigAccess.get("WTF_CSRF_HEADERS");
        foreach (h; hdrs.iterItems())
            if (!token.length)
                token = req.header(h.toString);
        if (!token.length)
            token = req.form.get("csrf_token", "");
        string msg;
        if (!token.length)
            msg = "The CSRF token is missing.";
        else
        {
            auto raw = s.get("csrf_token");
            if (!raw.isString)
                msg = "The CSRF session token is missing.";
            else
            {
                auto dot = token.indexOf('.');
                if (dot < 0)
                    msg = "The CSRF token is invalid.";
                else
                {
                    auto given = token[0 .. dot];
                    auto mac = token[dot + 1 .. $];
                    auto expected = Base64Url(hmac(Digest.sha256, cfgStr("CSRF_SESSION_KEY").representation,
                            given.representation));
                    if (!constantTimeEquals(mac, expected) || !constantTimeEquals(given, raw.str))
                        msg = "The CSRF tokens do not match.";
                }
            }
        }
        if (msg.length == 0)
            return null;
        return unauthorized(msg ~ " You need to refresh the page.");
    }

    // ------------------------------------------------------------ login manager

    private void loadUser(RequestContext rc)
    {
        auto s = rc.session;
        rc.user = Value(null);
        rc.roles = null;
        auto uid = s.get("_user_id");
        if (!uid.isString)
            return;
        auto u = db.queryOne(`SELECT * FROM "user" WHERE fs_uniquifier = ?`, uid);
        if (u.isNone || !u["active"].truthy || u.get("locked").truthy)
            return;
        rc.user = u;
        rc.roles = userRoles(u["id"].integer);
    }

    /// Flask-Login `login_user(user)`.
    void loginUser(Value user)
    {
        auto rc = reqctx();
        auto s = rc.session;
        s["_user_id"] = user["fs_uniquifier"];
        s["_fresh"] = Value(true);
        s["_id"] = Value(tokenUrlsafe(16));
        s.forceWrite = true;
        rc.user = user;
        rc.roles = userRoles(user["id"].integer);
    }

    /// Flask-Login `logout_user()`.
    void logoutUser()
    {
        auto rc = reqctx();
        auto s = rc.session;
        foreach (k; ["_user_id", "_fresh", "_id"])
            s.pop(k);
        s.forceWrite = true;
        rc.user = Value(null);
        rc.roles = null;
    }
}

private string Base64Url(const(ubyte)[] b)
{
    import std.base64 : Base64URL;
    auto s = Base64URL.encode(b).idup;
    while (s.length && s[$ - 1] == '=')
        s = s[0 .. $ - 1];
    return s;
}

// ------------------------------------------------------------ template integration

private __gshared FlaskApp theApp;

FlaskApp flaskApp() => theApp;
void setFlaskApp(FlaskApp a)
{
    theApp = a;
}

/// `request` in templates.
final class RequestProxy : Obj
{
    override Value getAttr(string name)
    {
        auto r = request();
        if (r is null)
            return Value.undefined;
        switch (name)
        {
        case "method": return Value(r.method);
        case "path": return Value(r.path);
        case "full_path": return Value(r.fullPath);
        case "url": return Value(r.url);
        case "url_root": return Value(r.urlRoot);
        case "host": return Value(r.host);
        case "args": return r.args.toDict;
        case "form": return r.form.toDict;
        case "cookies":
            auto d = new Dict;
            foreach (k, v; r.cookies)
                d[k] = Value(v);
            return Value(d);
        case "endpoint": return Value(r.endpoint);
        case "blueprint": return Value(r.blueprint);
        case "remote_addr": return Value(r.remoteAddr);
        case "scheme": return Value(r.scheme);
        case "is_json": return Value(r.isJson);
        case "headers":
            auto d = new Dict;
            foreach (h; r.headers)
                d[h[0]] = Value(h[1]);
            return Value(d);
        case "user_agent":
            auto d = new Dict;
            d["string"] = Value(r.userAgent);
            return Value(d);
        default: return Value.undefined;
        }
    }

    override string typeName() const { return "Request"; }
}

/// `session` in templates.
final class SessionProxy : Obj
{
    override Value getAttr(string name)
    {
        auto s = session();
        if (s is null || !s.has(name))
            return Value.undefined;
        return s.get(name);
    }

    override string typeName() const { return "SecureCookieSession"; }
}

/// `current_user` in templates.
final class UserProxy : Obj
{
    override Value getAttr(string name)
    {
        auto rc = reqctx();
        switch (name)
        {
        case "is_authenticated": return Value(rc.user.isDict);
        case "is_anonymous": return Value(!rc.user.isDict);
        case "is_active": return Value(rc.user.isDict);
        case "has_role":
            return Value(new Func("has_role", (Value[] a, Dict k) => Value(rc.roles.canFind(a[0].toString))));
        case "has_permission":
            return Value(new Func("has_permission", (Value[] a, Dict k) =>
                    Value(rc.user.isDict && userHasPermission(rc.user["id"].integer, a[0].toString))));
        default:
            if (rc.user.isDict && rc.user.dict.has(name))
                return rc.user.dict[name];
            return Value.undefined;
        }
    }

    override string typeName() const { return "User"; }
}

/// `csp_nonce` in templates: prints the nonce of the current request.
final class NonceProxy : Obj
{
    override string toString() const => reqctx().cspNonce;
    override string typeName() const { return "str"; }
}

/// `current_app` in templates.
final class AppProxy : Obj
{
    override Value getAttr(string name)
    {
        switch (name)
        {
        case "config": return Value(ConfigAccess.all);
        case "debug": return Value(cfgBool("DEBUG"));
        case "messages":
            auto d = new Dict;
            if (theApp !is null)
                foreach (b; theApp.allBlueprints)
                    d.update(b.getOwnMessages().dict);
            return Value(d);
        case "menu_items": return theApp is null ? Value.undefined : mergedMenuItems();
        case "exposed_endpoint_url_map": return theApp is null ? Value.undefined : exposedEndpointUrlMap();
        default: return Value.undefined;
        }
    }

    override string typeName() const { return "PgAdmin"; }
}

/// `app.menu_items`: the menu items of every top-level module, merged and sorted by priority.
Value mergedMenuItems()
{
    auto merged = new Dict;
    foreach (b; theApp.allBlueprints)
        foreach (k, v; b.getOwnMenuItems().dict)
        {
            if (!merged.has(k))
                merged[k] = Value.newList();
            merged[k].list.items ~= v.list.items;
        }
    foreach (k, v; merged)
    {
        import std.algorithm : sort, SwapStrategy;
        sort!((a, b) => a.get("priority").integer < b.get("priority").integer, SwapStrategy.stable)(v.list.items);
    }
    return Value(merged);
}

/// `app.exposed_endpoint_url_map`: (endpoint, url) pairs the frontend can build URLs from.
Value exposedEndpointUrlMap()
{
    auto root = theApp.urlFor("browser.index");
    string wsgiRoot = root == "/browser/" ? "" : root.replace("/browser/", "");
    Value[] r;
    foreach (rule; theApp.map.forEndpoint("static"))
        r ~= Value.tuple(Value(rule.endpoint), Value(wsgiRoot ~ rule.rule));
    foreach (b; theApp.allBlueprints)
        foreach (ep; b.exposedEndpoints)
            foreach (rule; theApp.map.forEndpoint(ep))
                r ~= Value.tuple(Value(rule.endpoint), Value(wsgiRoot ~ rule.rule));
    // the reference lists more than the declared endpoints (its list is extended in place on every request),
    // so the front end can rely on every endpoint of every module being there
    bool[string] seen;
    foreach (v; r)
        seen[v.list.items[0].toString ~ "|" ~ v.list.items[1].toString] = true;
    foreach (rule; theApp.map.all())
    {
        auto key = rule.endpoint ~ "|" ~ wsgiRoot ~ rule.rule;
        if (key in seen)
            continue;
        seen[key] = true;
        r ~= Value.tuple(Value(rule.endpoint), Value(wsgiRoot ~ rule.rule));
    }
    r ~= Value.tuple(Value("pgadmin.root"), Value(wsgiRoot));
    return Value(r);
}

/// Adds Flask's template globals to the environment.
void installTemplateGlobals(Environment env)
{
    env.globals["request"] = Value(new RequestProxy);
    env.globals["session"] = Value(new SessionProxy);
    env.globals["current_user"] = Value(new UserProxy);
    env.globals["current_app"] = Value(new AppProxy);
    env.globals["config"] = Value(ConfigAccess.all);
    env.globals["g"] = Value(new Func("g", (Value[] a, Dict k) => Value(g())));
    env.globals["url_for"] = Value(new Func("url_for", (Value[] a, Dict kw) {
        auto endpoint = a[0].toString;
        auto values = new Dict;
        if (kw !is null)
            foreach (k, v; kw)
                values[k] = v;
        bool external = values.has("_external") && values["_external"].truthy;
        values.pop("_external");
        values.pop("_scheme");
        return Value(theApp.urlFor(endpoint, values, external));
    }));
    env.globals["get_flashed_messages"] = Value(new Func("get_flashed_messages", (Value[] a, Dict kw) {
        bool withCategories = kw !is null && kw.get("with_categories").truthy;
        return getFlashedMessages(withCategories);
    }));
    env.globals["csrf_token"] = Value(new Func("csrf_token", (Value[] a, Dict kw) => Value(theApp.generateCsrf())));
    env.globals["csp_nonce"] = Value(new NonceProxy);
}
