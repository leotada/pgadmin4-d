/// `pgadmin/help`: Help menu items, the documentation path preference and the static documentation.
module pgadmin.help;

import std.path : buildPath, absolutePath, buildNormalizedPath;
import pgadmin.core.config;
import pgadmin.core.i18n;
import pgadmin.core.value;
import pgadmin.utils.preferences;
import pgadmin.web.flask;
import pgadmin.misc : kw;

final class HelpModule : Blueprint
{
    this()
    {
        super("help");
        staticUrlPath = "/help";
        staticFolder = absolutePath(cfgStr("HELP_PATH"), pgadminDirectory).buildNormalizedPath;
    }

    private static string pgadminDirectory() => buildPath(cfgStr("PGADMIN_WEB_DIR"), "pgadmin");

    override Value getOwnMenuItems()
    {
        Value mi(string name, string label, int prio, string target, string icon, string url)
            => Value.dictOf("name", name, "label", label, "priority", prio, "target", target, "icon", icon, "url", url);
        return Value.dictOf("help_items", Value([
            mi("mnu_quick_search_help", gettext("Quick Search"), 99, "pgadmin_quick_search_help", "fa fa-question", "#"),
            mi("mnu_online_help", gettext("Online Help"), 100, "pgadmin_help", "fa fa-question",
                flaskApp.urlFor("help.static", Value.dictOf("filename", "index.html").dict)),
            mi("mnu_pgadmin_website", gettext("pgAdmin Website"), 200, "pgadmin_website", "fa fa-external-link-alt",
                "https://www.pgadmin.org/"),
            mi("mnu_postgresql_website", gettext("PostgreSQL Website"), 300, "postgres_website",
                "fa fa-external-link-alt", "https://www.postgresql.org/"),
        ]));
    }

    override string[] getExposedUrlEndpoints() => ["help.static"];
}
