/// `pgadmin/about`: the About dialog data.
module pgadmin.about;

import std.algorithm : canFind;
import std.regex : regex, matchFirst, matchAll;
import std.string : replace;
import pgadmin.core.config;
import pgadmin.core.i18n;
import pgadmin.core.value;
import pgadmin.model : db, userRoles;
import pgadmin.web.auth;
import pgadmin.web.context;
import pgadmin.web.flask;
import pgadmin.web.http;

final class AboutModule : Blueprint
{
    this()
    {
        super("about");
        staticUrlPath = "";
    }

    override Value getOwnMenuItems()
    {
        auto item = Value.dictOf("name", "mnu_about", "priority", 999, "module", "pgAdmin.About", "callback",
                "about_show", "icon", "fa fa-info-circle", "label",
                gettext("About %(appname)s").replace("%(appname)s", cfgStr("APP_NAME")));
        return Value.dictOf("help_items", Value([item]));
    }

    override string[] getExposedUrlEndpoints() => ["about.index"];

    override void setup()
    {
        route("/", "index", ["GET"], loginRequired((Dict a) {
            auto info = new Dict;
            auto agent = request().userAgent;
            string browser, osDetails, electron;
            detectBrowser(agent, browser, osDetails, electron);
            auto admin = currentUserHasRole("Administrator");
            if (electron.length)
                info["electron"] = electron;
            info["app_mode"] = cfgBool("SERVER_MODE") ? gettext("Server") : gettext("Desktop");
            info["commit_hash"] = ConfigAccess.has("COMMIT_HASH") ? ConfigAccess.get("COMMIT_HASH") : Value(null);
            info["browser_details"] = browser;
            info["version"] = cfgStr("APP_VERSION");
            info["admin"] = Value(admin);
            info["current_user"] = currentUserAttr("email");
            info["python_version"] = "D (andaime)";
            if (admin)
            {
                string settings;
                info["os_details"] = osDetails;
                info["log_file"] = cfgStr("LOG_FILE");
                if (!ConfigAccess.get("CONFIG_DATABASE_URI").truthy)
                    info["config_db"] = cfgStr("SQLITE_PATH");
                immutable hidden = ["CSRF_SESSION_KEY", "SECRET_KEY", "SECURITY_PASSWORD_SALT", "SECURITY_PASSWORD_HASH",
                    "ALLOWED_HOSTS", "MAIL_PASSWORD", "LDAP_BIND_PASSWORD"];
                import std.algorithm : sort;
                auto keys = ConfigAccess.all.keys;
                sort(keys);
                foreach (k; keys)
                {
                    if (hidden.canFind(k) || k == "PGADMIN_WEB_DIR")
                        continue;
                    auto v = ConfigAccess.get(k);
                    settings ~= v.isString ? k ~ " = \"" ~ v.str ~ "\"\n" : k ~ " = " ~ v.toString ~ "\n";
                }
                info["settings"] = settings;
            }
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(info), 200);
        }));
    }
}

private void detectBrowser(string agent, out string browser, out string osDetails, out string electron)
{
    import std.file : exists, readText;
    import std.string : splitLines, startsWith, strip;
    try
    {
        if ("/etc/os-release".exists)
            foreach (l; readText("/etc/os-release").splitLines)
                if (l.startsWith("PRETTY_NAME="))
                    osDetails = l["PRETTY_NAME=".length .. $].strip("\"") ~ ", ";
    }
    catch (Exception)
    {
    }
    osDetails ~= "Linux";
    if (agent.canFind("Electron"))
    {
        auto m = matchFirst(agent, regex(`Electron/([\d.]+\d+)`));
        if (!m.empty)
            electron = m[1].idup;
    }
    auto m = matchFirst(agent, regex(`(opera|chrome|safari|firefox|msie|trident(?=/))/?\s*([\d.]+\d+)`, "i"));
    if (m.empty)
    {
        import std.array : split;
        browser = agent.split("/")[0];
    }
    else
        browser = m[1].idup ~ " " ~ m[2].idup;
}
