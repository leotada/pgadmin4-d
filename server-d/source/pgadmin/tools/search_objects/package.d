/// `pgadmin/tools/search_objects`: search the objects of a database by name and type.
module pgadmin.tools.search_objects;

import std.algorithm : canFind;
import pgadmin.browser.common;
import pgadmin.utils.preferences : Preferences;
import pgadmin.web.flask;

private immutable string[] allNodeTypes = [
    "cast", "fts_dictionary", "check_constraint", "exclusion_constraint", "foreign_key", "primary_key", "unique_constraint",
    "constraints", "trigger", "table", "compound_trigger", "rule", "column", "partition", "index", "type", "domain",
    "domain_constraints", "schema", "synonym", "sequence", "edbvar", "edbfunc", "edbproc", "package", "foreign_table",
    "fts_parser", "function", "procedure", "trigger_function", "fts_template", "collation", "view", "mview",
    "fts_configuration", "extension", "language", "event_trigger", "foreign_server", "user_mapping", "foreign_data_wrapper",
    "row_security_policy", "publication", "subscription", "aggregate", "operator"
];

private BrowserPluginModule nodeBlueprint(string nodeType)
{
    foreach (b; flaskApp().allBlueprints)
        if (b.name == "NODE-" ~ nodeType)
            return cast(BrowserPluginModule) b;
    return null;
}

/// `SearchObjectsHelper`
struct SearchObjectsHelper
{
    Value sid, did;
    bool showSystemObjects;
    ServerManager manager;

    this(Value sid, Value did, bool showSystemObjects)
    {
        this.sid = sid;
        this.did = did;
        this.showSystemObjects = showSystemObjects;
        manager = getDriver().connectionManager(sid.integer);
    }

    string templatePath() => "search_objects/sql/" ~ manager.serverType ~ "/#" ~ to!string(manager.version_) ~ "#";

    Value getShowNodePrefs()
    {
        auto r = Value.newDict();
        foreach (t; allNodeTypes)
        {
            auto b = nodeBlueprint(t);
            // modules that are not available here keep their default (shown)
            r[t] = Value(b is null ? true : b.showNode);
        }
        return r;
    }

    Value getSupportedTypes(bool skipCheck = false)
    {
        auto r = Value.newDict();
        foreach (t; allNodeTypes)
        {
            auto b = nodeBlueprint(t);
            if (b is null)
                continue;
            auto cm = cast(CollectionNodeModule) b;
            auto kw = new Dict;
            kw["is_catalog"] = Value(false);
            kw["did"] = did;
            if (cm !is null && (cm.backendSupported(manager, kw) || skipCheck))
            {
                if (t == "edbfunc" || t == "edbproc")
                    r[t] = Value(fmtPackage(cm.collectionLabel));
                else
                    r[t] = Value(cm.collectionLabel);
            }
        }
        return r;
    }

    private static string fmtPackage(string label) => gettext("Package %s").replace("%s", label);

    /// (status, result)
    Res search(string text, string objType)
    {
        string[] skip;
        auto conn = manager.connection(null, null, true, did);
        auto showNodePrefs = getShowNodePrefs();
        auto nodeLabels = getSupportedTypes(true);
        text = text.replace("'", "''");
        if (objType == "all")
        {
            auto r = conn.executeDict("SELECT COUNT(1) FROM information_schema.table_privileges  WHERE table_name = 'pg_subscription' "
                    ~ "AND privilege_type = 'SELECT'");
            if (r.ok && r.value["rows"][0].contains("count") && r.value["rows"][0]["count"] == Value("0"))
                skip ~= "subscription";
        }
        Value[] skipV;
        foreach (s; skip)
            skipV ~= Value(s);
        auto sql = renderTemplate(templatePath ~ "/search.sql", tv("search_text", text.toLower, "obj_type", objType is null ? Value(null) : Value(objType),
                "show_system_objects", showSystemObjects, "show_node_prefs", showNodePrefs, "last_system_oid", DATABASE_LAST_SYSTEM_OID,
                "skip_obj_type", Value(skipV)));
        auto res = conn.executeDict(sql);
        if (!res.ok)
            return res;
        Value[] ret;
        foreach (row; res.value["rows"].list.items)
        {
            auto t = row["obj_type"].toString;
            if (!nodeLabels.contains(t))
                throw new Exception("'" ~ t ~ "'");
            ret ~= Value.dictOf("name", row["obj_name"], "type", row["obj_type"], "type_label", nodeLabels[t], "path",
                    row["obj_path"], "show_node", row["show_node"], "other_info", row["other_info"], "catalog_level",
                    row["catalog_level"]);
        }
        return Res(true, Value(ret));
    }
}

final class SearchObjectsModule : Blueprint
{
    this()
    {
        super("search_objects", "/search_objects");
        staticUrlPath = "";
    }

    override string[] getExposedUrlEndpoints() => ["search_objects.search", "search_objects.types"];

    private static bool showSystemObjects()
        => Preferences.module_("browser").preference("show_system_objects").get().truthy;

    override void setup()
    {
        route("/", "index", ["GET"], loginRequired((Dict a) => badRequest(gettext("This URL cannot be called directly."))));
        route("types/<int:sid>/<int:did>", "types", ["GET"], permissionsRequired(loginRequired((Dict a) {
            auto so = SearchObjectsHelper(a["sid"], a["did"], showSystemObjects());
            return makeJsonResponse(1, Value(""), Value(""), Value(null), so.getSupportedTypes());
        }), "tools_search_objects"));
        route("search/<int:sid>/<int:did>", "search", ["GET"], permissionsRequired(loginRequired((Dict a) {
            auto args = request().args;
            auto text = args.has("text") ? args.get("text") : null;
            auto type = args.has("type") ? args.get("type") : null;
            auto so = SearchObjectsHelper(a["sid"], a["did"], showSystemObjects());
            if (text is null)
                throw new Exception("'NoneType' object has no attribute 'replace'");
            auto r = so.search(text, type);
            if (!r.ok)
                return internalServerError(r.error);
            return makeJsonResponse(1, Value(""), Value(""), Value(null), r.value);
        }), "tools_search_objects"));
    }
}
