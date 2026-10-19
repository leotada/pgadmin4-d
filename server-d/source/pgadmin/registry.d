/// Builds the Flask application and registers the modules (`pgadmin/__init__.py: create_app`).
module pgadmin.registry;

import std.algorithm : canFind, startsWith;
import std.array : split;
import std.path : buildPath;
import std.process : environment;
import std.string : strip, toLower;
import pgadmin.about;
import pgadmin.dashboard : DashboardModule;
import pgadmin.misc.cloud : CloudModule;
import pgadmin.misc.file_manager : FileManagerModule;
import pgadmin.misc.workspaces : WorkspaceModule;
import pgadmin.tools.grant_wizard : GrantWizardModule;
import pgadmin.tools.backup : BackupModule;
import pgadmin.tools.import_export : ImportExportModule;
import pgadmin.tools.maintenance : MaintenanceModule;
import pgadmin.tools.import_export_servers : ImportExportServersModule;
import pgadmin.tools.restore : RestoreModule;
import pgadmin.tools.search_objects : SearchObjectsModule;
import pgadmin.authenticate;
import pgadmin.browser;
import pgadmin.core.config;
import pgadmin.core.i18n;
import pgadmin.core.log;
import pgadmin.core.templates;
import pgadmin.core.value;
import pgadmin.db.driver;
import pgadmin.help;
import pgadmin.jinja.runtime;
import pgadmin.llm;
import pgadmin.misc;
import pgadmin.misc.bgprocess;
import pgadmin.model;
import pgadmin.preferences;
import pgadmin.redirects;
import pgadmin.settings;
import pgadmin.tools;
import pgadmin.tools.debugger : DebuggerModule;
import pgadmin.tools.erd : ERDModule;
import pgadmin.tools.psql : PSQLModule;
import pgadmin.tools.schema_diff : SchemaDiffModule;
import pgadmin.tools.sqleditor;
import pgadmin.tools.user_management;
import pgadmin.utils.constants;
import pgadmin.web.context;
import pgadmin.web.flask;
import pgadmin.web.http;
import pgadmin.web.session;

private __gshared string internalKey;      /// PGADMIN_INT_KEY (desktop runtime)
private __gshared bool runtimeMode;        /// started by the desktop runtime

/// `PGADMIN_INT_KEY` of the desktop runtime ('' when not set).
void setRuntime(string key)
{
    internalKey = key;
    runtimeMode = key.length > 0;
}

void createFlaskApp()
{
    ServerType.registerDefaults();
    auto env = createEnvironment(pgadminDir());
    installTemplateGlobals(env);
    setTemplateEnv(env);

    auto app = new FlaskApp;
    setFlaskApp(app);
    app.secretKey = cfgStr("SECRET_KEY");
    app.desktopMode = !cfgBool("SERVER_MODE");
    string[] skip;
    foreach (v; ConfigAccess.get("SESSION_SKIP_PATHS").iterItems())
        skip ~= v.toString;
    app.sessions = new SessionManager(cfgStr("SESSION_DB_PATH"), app.secretKey,
            ConfigAccess.has("PGADMIN_SESSION_DISK_WRITE_DELAY") ? cfgInt("PGADMIN_SESSION_DISK_WRITE_DELAY") : 10, skip);
    app.addStatic(buildPath(pgadminDir(), "static"));

    app.csrfExemptBlueprints = ["redirects", "security"];
    app.csrfExemptEndpoints = ["authenticate.login", "pgadmin.tools.translations"];

    // Flask-Security first (its views live at /login and /logout), then pgAdmin's modules in `get_submodules()` order
    app.registerBlueprint(new SecurityModule);

    auto tools = new ToolsModule;
    tools.tools = [cast(Blueprint) new BackupModule, new DebuggerModule, new ERDModule, new GrantWizardModule, new ImportExportModule, new ImportExportServersModule,
        new MaintenanceModule, new PSQLModule, new RestoreModule, new SchemaDiffModule, new SearchObjectsModule, new SqlEditorModule, new UserManagementModule];
    auto misc = new MiscModule;
    misc.subs = [cast(Blueprint) new BGProcessModule, new CloudModule, new FileManagerModule, new WorkspaceModule];

    foreach (b; [cast(Blueprint) new AboutModule, new AuthenticateModule, new BrowserModule, new DashboardModule, new HelpModule,
            new LLMModule, misc, new PreferencesModule, new RedirectModule, new SettingsModule, tools])
        app.registerBlueprint(b);

    installHooks(app);
    app.runBeforeAppStart();
}

private bool isAllowedHost(string host)
{
    auto allowed = ConfigAccess.get("ALLOWED_HOSTS");
    if (allowed.length == 0)
        return true;
    auto clientHost = host.split(":")[0];
    foreach (h; allowed.iterItems())
        if (h.toString == clientHost)
            return true;
    return false;
}

private void installHooks(FlaskApp app)
{
    // Host header validation
    app.beforeRequest ~= () {
        if (!isAllowedHost(request().host))
            return makeJsonResponse(0, Value(gettext("403 FORBIDDEN")), Value(""), Value(null), Value(null), 403);
        return null;
    };

    // desktop mode: the runtime's key and the automatic login of the desktop user
    app.beforeRequest ~= () {
        auto req = request();
        if (!cfgBool("SERVER_MODE") && internalKey.length
                && (!req.args.has("key") || req.args.get("key") != internalKey)
                && req.cookies.get("PGADMIN_INT_KEY", "") != internalKey && req.endpoint != "help.static")
            return new HTTPException(401).toResponse();
        if (!cfgBool("SERVER_MODE") && !isAuthenticated())
        {
            auto user = db.queryOne(`SELECT * FROM "user" WHERE email = ?`, ConfigAccess.get("DESKTOP_USER"));
            if (user.isNone)
            {
                logError("The desktop user " ~ cfgStr("DESKTOP_USER") ~ " was not found in the configuration database.");
                return new HTTPException(401).toResponse();
            }
            flaskApp.loginUser(user);
        }
        return null;
    };

    app.afterRequest ~= (Response resp) {
        auto req = request();
        if (cfgBool("LOG_AUTHENTICATED_USER"))
        {
            if (isAuthenticated() && currentUserAttr("username").truthy)
                resp.setHeader("X-Remote-User", printableLatin1(currentUserAttr("username").toString));
        }
        if (req.args.has("key"))
        {
            CookieSpec c;
            c.name = "PGADMIN_INT_KEY";
            c.value = req.args.get("key");
            c.path = cfgStr("SESSION_COOKIE_PATH");
            c.secure = cfgBool("SESSION_COOKIE_SECURE");
            c.httpOnly = cfgBool("SESSION_COOKIE_HTTPONLY");
            c.sameSite = cfgStr("SESSION_COOKIE_SAMESITE");
            auto dom = ConfigAccess.get("COOKIE_DEFAULT_DOMAIN");
            if (dom.truthy && dom.toString != "localhost")
                c.domain = dom.toString;
            resp.setCookie(c);
        }
        setSecurityHeaders(resp);
    };
}

private string printableLatin1(string s)
{
    string r;
    foreach (dchar c; s)
        r ~= (c >= 0x20 && c < 0x7f) ? cast(char) c : '?';
    return r;
}

/// `SecurityHeaders.set_response_headers`
private void setSecurityHeaders(Response resp)
{
    auto xfo = cfgStr("X_FRAME_OPTIONS");
    if (xfo.length && xfo.toLower != "deny")
        resp.setHeader("X-Frame-Options", xfo);
    if (cfgBool("STRICT_TRANSPORT_SECURITY_ENABLED") && cfgStr("STRICT_TRANSPORT_SECURITY").length)
        resp.setHeader("Strict-Transport-Security", cfgStr("STRICT_TRANSPORT_SECURITY"));
    auto csp = cfgStr("CONTENT_SECURITY_POLICY");
    if (csp.length)
    {
        import std.string : replace;
        if (csp.canFind("{nonce}"))
        {
            csp = csp.replace("{nonce}", reqctx().cspNonce);
            if (cfgBool("DEBUG"))
                csp = addUnsafeEval(csp);
        }
        resp.setHeader("Content-Security-Policy", csp);
    }
    foreach (pair; [["X_CONTENT_TYPE_OPTIONS", "X-Content-Type-Options"], ["X_XSS_PROTECTION", "X-XSS-Protection"],
            ["WEB_SERVER", "Server"], ["CROSS_ORIGIN_OPENER_POLICY", "Cross-Origin-Opener-Policy"]])
    {
        auto v = ConfigAccess.get(pair[0]);
        if (!v.isNone && v.toString.length)
            resp.setHeader(pair[1], v.toString);
    }
}

private string addUnsafeEval(string csp)
{
    string[] directives;
    foreach (d; csp.split(";"))
    {
        auto t = d.strip;
        if (t.length == 0)
            continue;
        if (t.split(" ")[0] == "script-src" && !t.canFind("'unsafe-eval'"))
            t ~= " 'unsafe-eval'";
        directives ~= t;
    }
    string r;
    foreach (i, d; directives)
        r ~= (i ? "; " : "") ~ d;
    return r ~ ";";
}
