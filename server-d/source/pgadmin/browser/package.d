/// `pgadmin/browser`: the main window, its JavaScript bootstrap files, the tree root and the master password.
module pgadmin.browser;

import std.algorithm : canFind;
import std.array : join, split;
import std.conv : to;
import std.regex : regex, matchFirst;
import std.string : replace, toLower;
import pgadmin.core.config;
import pgadmin.core.i18n;
import pgadmin.core.log;
import pgadmin.core.templates : renderTemplate;
import pgadmin.core.value;
import pgadmin.db.driver;
import pgadmin.db.libpq : loadLibpq, pq;
import pgadmin.llm : isLlmEnabled;
import pgadmin.model;
import pgadmin.settings : getLayout;
import pgadmin.utils.constants;
import pgadmin.utils.master_password;
import pgadmin.utils.preferences;
import pgadmin.web.auth;
import pgadmin.web.context;
import pgadmin.web.flask;
import pgadmin.web.http;
import pgadmin.browser.utils;
import pgadmin.browser.server_groups : ServerGroupModule;

enum BROWSER_INDEX = "browser.index";

/// Name and version of the browser from the User-Agent (what `request.user_agent` gives in Werkzeug).
struct UserAgent
{
    string browser;
    int version_;
}

UserAgent parseUserAgent(string ua)
{
    UserAgent r;
    auto m = matchFirst(ua, regex(`(?:(Edg|Edge)/|(OPR|Opera)/|(Chrome|CriOS)/|(Firefox|FxiOS)/|Version/(\d+)[\d.]* .*?(Safari)/|(MSIE |Trident/.*rv:))(\d+)?`));
    if (!m.empty)
    {
        if (m[1].length)
            r.browser = "edge";
        else if (m[2].length)
            r.browser = "opera";
        else if (m[3].length)
            r.browser = "chrome";
        else if (m[4].length)
            r.browser = "firefox";
        else if (m[6].length)
            r.browser = "safari";
        else if (m[7].length)
            r.browser = "msie";
        try
            r.version_ = to!int(m[5].length ? m[5] : m[8]);
        catch (Exception)
            r.version_ = 0;
    }
    return r;
}

final class BrowserModule : Blueprint
{
    this()
    {
        super("browser");
        label = Value(gettext("Browser"));
    }

    override string[] getExposedUrlEndpoints()
    {
        return [BROWSER_INDEX, "browser.nodes", "browser.check_corrupted_db_file", "browser.check_master_password",
            "browser.set_master_password", "browser.reset_master_password"];
    }

    override void setup()
    {
        submodules ~= new ServerGroupModule;

        route("/", "index", ["GET"], loginRequired(&index), true);
        route("/js/utils.js", "utils", ["GET"], loginRequired(&utilsJs), true);
        route("/js/endpoints.js", "exposed_urls", ["GET"], (Dict a) {
            auto r = new Response(renderTemplate("browser/js/endpoints.js"), 200, MIMETYPE_APP_JS);
            return r;
        }, true);
        route("/js/error.js", "error_js", ["GET"], loginRequired((Dict a) {
            return new Response(renderTemplate("browser/js/error.js"), 200, MIMETYPE_APP_JS);
        }), true);
        route("/js/messages.js", "messages_js", ["GET"], (Dict a) {
            return new Response(renderTemplate("browser/js/messages.js"), 200, MIMETYPE_APP_JS);
        }, true);
        route("/browser.css", "browser_css", ["GET"], loginRequired((Dict a) {
            Value[] snippets;
            foreach (m; submodules)
                if (auto b = cast(BrowserPluginModule) m)
                    foreach (s; b.csssnippets)
                        snippets ~= Value(s);
            return new Response(renderTemplate("browser/css/browser.css", ["snippets": Value(snippets)]), 200, "text/css");
        }), true);
        route("/nodes/", "nodes", ["GET"], loginRequired((Dict a) {
            Value[] nodes;
            foreach (m; submodules)
                if (auto b = cast(BrowserPluginModule) m)
                    nodes ~= b.getNodes(new Dict);
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(nodes));
        }));
        route("/check_corrupted_db_file", "check_corrupted_db_file", ["GET"], (Dict a) {
            import std.process : environment;
            auto loc = environment.get("CORRUPTED_DB_BACKUP_FILE", "");
            environment["CORRUPTED_DB_BACKUP_FILE"] = "";
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(loc));
        });
        route("/master_password", "check_master_password", ["GET"], (Dict a) {
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(getCryptKey().present));
        });
        route("/master_password", "reset_master_password", ["DELETE"], (Dict a) {
            import pgadmin.browser.master_password : cleanupMasterPassword;
            cleanupMasterPassword();
            auto ck = getCryptKey();
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(ck.present));
        });
        route("/master_password", "set_master_password", ["POST"], (Dict a) {
            import pgadmin.browser.master_password : setMasterPassword;
            return setMasterPassword();
        });
    }

    private Response index(Dict a)
    {
        if (cfgBool("CHECK_SUPPORTED_BROWSER"))
        {
            auto ua = parseUserAgent(request().userAgent);
            string browserName;
            bool known = true;
            if (ua.browser == "chrome" && ua.version_ < 72)
                browserName = "Chrome";
            else if (ua.browser == "firefox" && ua.version_ < 65)
                browserName = "Firefox";
            else if (ua.browser == "edge" && ua.version_ < 18)
                browserName = "Edge";
            else if (ua.browser == "safari" && ua.version_ < 12)
                browserName = "Safari";
            else if (ua.browser == "msie")
                browserName = "Internet Explorer";
            else if (ua.browser != "chrome" && ua.browser != "firefox" && ua.browser != "edge" && ua.browser != "safari")
            {
                browserName = ua.browser;
                known = false;
            }
            if (browserName.length)
            {
                auto msg = renderTemplate("browser/browser.html", ["version": Value(ua.version_),
                    "browser": Value(browserName), "known": Value(known)]);
                flash(msg, "Warning");
            }
        }

        session()["allow_save_password"] = Value(true);
        if (cfgBool("SERVER_MODE") && !cfgBool("MASTER_PASSWORD_REQUIRED") && session().has("pass_enc_key"))
            session()["allow_save_password"] = Value(false);

        auto misc = Preferences.module_("misc");
        auto langPref = misc.preference("user_language");
        string language = "en";
        if (langPref !is null)
        {
            auto l = langPref.get();
            language = l.truthy ? l.toString : "en";
        }
        auto themePref = misc.preference("theme");
        string theme = "light";
        if (themePref !is null)
        {
            auto t = themePref.get();
            theme = t.truthy ? t.toString : "light";
        }

        auto resp = new Response(renderTemplate("browser/index.html", [
            "username": currentUserAttr("username"), "theme": Value(theme)
        ]));
        CookieSpec c;
        c.name = "PGADMIN_LANGUAGE";
        c.value = language;
        c.path = cfgStr("SESSION_COOKIE_PATH");
        c.secure = cfgBool("SESSION_COOKIE_SECURE");
        c.httpOnly = cfgBool("SESSION_COOKIE_HTTPONLY");
        c.sameSite = cfgStr("SESSION_COOKIE_SAMESITE");
        auto domain = ConfigAccess.get("COOKIE_DEFAULT_DOMAIN");
        if (domain.truthy && domain.toString != "localhost")
            c.domain = domain.toString;
        resp.setCookie(c);
        return resp;
    }

    private Response utilsJs(Dict a)
    {
        auto layout = getLayout();
        Value[] snippets;
        foreach (m; submodules)
            if (auto b = cast(BrowserPluginModule) m)
                foreach (s; b.jssnippets)
                    snippets ~= Value(s);

        auto paths = Preferences.module_("paths");
        auto pgHelp = paths.preference("pg_help_path");
        auto pgHelpPath = pgHelp is null ? Value("") : pgHelp.get();

        long libpq;
        try
        {
            loadLibpq();
            libpq = pq.PQlibVersion();
        }
        catch (Exception)
            libpq = 0;

        bool authOnlyInternal;
        Value authSource = Value.newList();
        if (cfgBool("SERVER_MODE"))
        {
            auto sm = session().get("auth_source_manager");
            if (sm.isDict && sm["current_source"].toString == INTERNAL)
                authOnlyInternal = true;
            authSource = sm.isDict ? sm["source_friendly_name"] : Value(INTERNAL);
        }

        auto sharedStorage = getSharedStorageList();
        Value restricted = currentUserHasRole("Administrator") ? Value.newList() : sharedStorage.restricted;

        Value[string] vars;
        vars["layout"] = layout;
        vars["jssnippets"] = Value(snippets);
        vars["pg_help_path"] = pgHelpPath;
        vars["app_name"] = Value(cfgStr("APP_NAME"));
        vars["app_version_int"] = ConfigAccess.get("APP_VERSION_INT");
        vars["pg_libpq_version"] = Value(libpq);
        vars["support_ssh_tunnel"] = Value(cfgBool("SUPPORT_SSH_TUNNEL"));
        vars["logout_url"] = Value(getLogoutUrl());
        vars["platform"] = Value("linux");
        vars["qt_default_placeholder"] = Value(QT_DEFAULT_PLACEHOLDER);
        vars["vw_edt_default_placeholder"] = Value(VW_EDT_DEFAULT_PLACEHOLDER);
        vars["enable_psql"] = ConfigAccess.get("ENABLE_PSQL");
        vars["auth_only_internal"] = Value(authOnlyInternal);
        vars["mfa_enabled"] = Value(false);
        vars["is_admin"] = Value(currentUserHasRole("Administrator"));
        vars["login_url"] = Value(new Func("login_url", (Value[] args, Dict kw) {
            auto nextUrl = kw !is null ? kw.get("next_url").strOr(null) : null;
            return Value(loginUrl(args[0].toString, nextUrl));
        }));
        vars["username"] = Value(currentUserAttr("username").toString.replace("'", "\\'"));
        vars["auth_source"] = authSource;
        vars["heartbeat_timeout"] = ConfigAccess.get("SERVER_HEARTBEAT_TIMEOUT");
        vars["password_length_min"] = ConfigAccess.get("PASSWORD_LENGTH_MIN");
        vars["shared_storage_list"] = sharedStorage.list;
        vars["restricted_shared_storage_list"] = restricted;
        vars["enable_server_passexec_cmd"] = ConfigAccess.get("ENABLE_SERVER_PASS_EXEC_CMD");
        vars["max_server_tags_allowed"] = ConfigAccess.get("MAX_SERVER_TAGS_ALLOWED");
        vars["llm_enabled"] = Value(isLlmEnabled());
        auto r = new Response(renderTemplate("browser/js/utils.js", vars), 200, MIMETYPE_APP_JS);
        r.setHeader("Cache-Control", NO_CACHE_CONTROL);
        return r;
    }
}

struct SharedStorage
{
    Value list;
    Value restricted;
}

/// `get_shared_storage_list()`: names of the valid shared storage entries, and of the restricted ones.
SharedStorage getSharedStorageList()
{
    SharedStorage r;
    r.list = Value.newList();
    r.restricted = Value.newList();
    if (!cfgBool("SERVER_MODE"))
        return r;
    Value[] valid;
    foreach (s; ConfigAccess.get("SHARED_STORAGE").iterItems())
        if (s.isDict && s.contains("name") && s.contains("path") && s.contains("restricted_access")
                && s["name"].isString && s["path"].isString && s["restricted_access"].isBool)
            valid ~= s;
    ConfigAccess.set("SHARED_STORAGE", Value(valid));
    foreach (s; valid)
    {
        r.list.append(s["name"]);
        if (s["restricted_access"].truthy)
            r.restricted.append(s["name"]);
    }
    return r;
}

/// `get_logout_url()`
string getLogoutUrl()
{
    auto next = flaskApp.urlFor(BROWSER_INDEX);
    if (cfgBool("SERVER_MODE"))
    {
        auto cur = session().get("auth_source_manager").get("current_source").toString;
        if (cur == KERBEROS)
            return flaskApp.urlFor("kerberos.logout") ~ "?next=" ~ next;
        if (cur == OAUTH2)
            return flaskApp.urlFor("oauth2.logout") ~ "?next=" ~ next;
    }
    return flaskApp.urlFor(flaskApp.logoutView) ~ "?next=" ~ next;
}
