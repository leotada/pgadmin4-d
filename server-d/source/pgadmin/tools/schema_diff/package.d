/// `pgadmin/tools/schema_diff`: Schema Diff tool blueprint.
module pgadmin.tools.schema_diff;

import std.algorithm : canFind;
import std.array : split;
import std.conv : to;
import pgadmin.browser.server_groups.servers : serverIconAndBackground, ServerNode;
import pgadmin.browser.server_groups.servers.databases : DatabaseView;
import pgadmin.browser.server_groups.servers.databases.schemas : SchemaView;
import pgadmin.browser.utils;
import pgadmin.core.config;
import pgadmin.core.i18n;
import pgadmin.core.log;
import pgadmin.core.templates;
import pgadmin.core.value;
import pgadmin.db.driver;
import pgadmin.model : db;
import pgadmin.tools.schema_diff.compare;
import pgadmin.tools.schema_diff.directory_compare;
import pgadmin.tools.schema_diff.model;
import pgadmin.tools.schema_diff.node_registry;
import pgadmin.utils.constants;
import pgadmin.utils.preferences : Preferences;
import pgadmin.utils.server_access;
import pgadmin.web.auth : loginRequired;
import pgadmin.web.context : request, session, currentUserId;
import pgadmin.web.flask : Blueprint;
import pgadmin.web.http;
import pgadmin.web.socketio : SocketIoServer, SocketIoClient, getSocketIo;

final class SchemaDiffModule : Blueprint
{
    enum MODULE_NAME = "schema_diff";

    this()
    {
        super(MODULE_NAME, "/schema_diff");
    }

    override string[] getExposedUrlEndpoints()
    {
        return [
            "schema_diff.initialize",
            "schema_diff.panel",
            "schema_diff.servers",
            "schema_diff.databases",
            "schema_diff.schemas",
            "schema_diff.ddl_compare",
            "schema_diff.connect_server",
            "schema_diff.connect_database",
            "schema_diff.get_server",
            "schema_diff.close"
        ];
    }

    override void registerPreferences()
    {
        auto prefs = Preferences.module_(MODULE_NAME);
        if (prefs is null)
            return;

        Dict kw(string help)
        {
            auto d = new Dict;
            d["category_label"] = Value(PREF_LABEL_DISPLAY);
            d["help_str"] = Value(help);
            return d;
        }

        prefs.register("display", "ignore_whitespaces", gettext("Ignore Whitespace"), "boolean", Value(false),
            kw(gettext("Set ignore whitespace on or off by default in the drop-down menu near the Compare button in the Schema Diff tab.")));

        prefs.register("display", "ignore_owner", gettext("Ignore Owner"), "boolean", Value(false),
            kw(gettext("Set ignore owner on or off by default in the drop-down menu near the Compare button in the Schema Diff tab.")));

        prefs.register("display", "ignore_tablespace", gettext("Ignore Tablespace"), "boolean", Value(false),
            kw(gettext("Set ignore tablespace on or off by default in the drop-down menu near the Compare button in the Schema Diff tab.")));

        prefs.register("display", "ignore_grants", gettext("Ignore Grants/Revoke"), "boolean", Value(false),
            kw(gettext("Set ignore grants/revoke on or off by default in the drop-down menu near the Compare button in the Schema Diff tab.")));
    }

    override void setup()
    {
        // Register all default node views in SchemaDiffRegistry
        registerDefaultSchemaDiffNodes();

        // 1. Root route
        route("/", "index", ["GET"], loginRequired((Dict a) {
            return badRequest(gettext("This URL cannot be requested directly."));
        }));

        // 2. Panel
        route("/panel/<int:trans_id>/<path:editor_title>", "panel", ["POST"], loginRequired((Dict a) {
            auto transId = a["trans_id"].integer;
            auto editorTitle = a["editor_title"].toString;
            return handlePanel(transId, editorTitle);
        }));

        // 3. Initialize
        route("/initialize/<int:trans_id>", "initialize", ["GET"], loginRequired((Dict a) {
            auto transId = a["trans_id"].integer;
            initSchemaDiffSession(session().sid, transId);
            return makeJsonResponse();
        }));

        // 4. Close
        route("/close/<int:trans_id>", "close", ["DELETE"], loginRequired((Dict a) {
            auto transId = a["trans_id"].integer;
            closeSchemaDiffSession(session().sid, transId);
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value.dictOf("status", true));
        }));

        // 5. Servers
        route("/servers", "servers", ["GET"], loginRequired((Dict a) {
            return handleServers();
        }));

        // 6. Get Server
        route("/get_server/<int:sid>/<int:did>", "get_server", ["GET"], loginRequired((Dict a) {
            auto sid = a["sid"].integer;
            auto did = a["did"].integer;
            return handleGetServer(sid, did);
        }));

        // 7. Connect Server
        route("/server/connect/<int:sid>", "connect_server", ["POST"], loginRequired((Dict a) {
            auto sid = a["sid"].integer;
            return handleConnectServer(sid);
        }));

        // 8. Connect Database
        route("/database/connect/<int:sid>/<int:did>", "connect_database", ["POST"], loginRequired((Dict a) {
            auto sid = a["sid"].integer;
            auto did = a["did"].integer;
            return handleConnectDatabase(sid, did);
        }));

        // 9. Databases
        route("/databases/<int:sid>", "databases", ["GET"], loginRequired((Dict a) {
            auto sid = a["sid"].integer;
            return handleDatabases(sid);
        }));

        // 10. Schemas
        route("/schemas/<int:sid>/<int:did>", "schemas", ["GET"], loginRequired((Dict a) {
            auto sid = a["sid"].integer;
            auto did = a["did"].integer;
            return handleSchemas(sid, did);
        }));

        // 11. DDL Compare
        route("/ddl_compare/<int:trans_id>/<int:source_sid>/<int:source_did>/<int:source_scid>/<int:target_sid>/<int:target_did>/<int:target_scid>/<int:source_oid>/<int:target_oid>/<node_type>/<comp_status>/",
              "ddl_compare", ["GET"], loginRequired((Dict a) {
            auto transId = a["trans_id"].integer;
            auto sourceSid = a["source_sid"].integer;
            auto sourceDid = a["source_did"].integer;
            auto sourceScid = a["source_scid"].integer;
            auto targetSid = a["target_sid"].integer;
            auto targetDid = a["target_did"].integer;
            auto targetScid = a["target_scid"].integer;
            auto sourceOid = a["source_oid"].integer;
            auto targetOid = a["target_oid"].integer;
            auto nodeType = a["node_type"].toString;
            auto compStatus = a["comp_status"].toString;
            return handleDdlCompare(transId, sourceSid, sourceDid, sourceScid, targetSid, targetDid, targetScid, sourceOid, targetOid, nodeType, compStatus);
        }));

        registerSchemaDiffSocketHandlers(getSocketIo());
    }

    private static Response handlePanel(long transId, string editorTitle)
    {
        auto req = request();
        if (req.args.has("fslashes") && req.args.get("fslashes").length)
        {
            try
            {
                auto list = req.args.get("fslashes").split(",");
                foreach (idxStr; list)
                {
                    auto idx = to!size_t(idxStr);
                    if (idx < editorTitle.length)
                        editorTitle = editorTitle[0 .. idx] ~ "/" ~ editorTitle[idx .. $];
                }
            }
            catch (Exception) {}
        }

        Value params = Value.newDict();
        if (!req.args.empty)
        {
            auto ad = req.args.toDict();
            foreach (k, v; ad.dict)
                params[k] = v;
        }
        if (!req.form.empty)
        {
            auto fd = req.form.toDict();
            foreach (k, v; fd.dict)
                params[k] = v;
        }

        auto rendered = renderTemplate("schema_diff/index.html", tv(
            "trans_id", transId,
            "editor_title", editorTitle,
            "params", params.toJson
        ));
        return new Response(rendered, 200, "text/html");
    }

    private static Response handleServers()
    {
        auto servers = getUserServers("is_adhoc = 0", null, "name");
        Value res = Value.newDict();
        auto driver = getDriver();
        auto uid = currentUserId();

        foreach (server; servers)
        {
            auto sid = server["id"].integer;
            if (server.contains("discovery_id") && !server["discovery_id"].isNone && server["discovery_id"].toString.length)
            {
                auto sharedRow = db.queryOne("SELECT 1 FROM sharedserver WHERE user_id = ? AND osid = ?", Value(uid), Value(sid));
                if (!sharedRow.isNone)
                    continue;
            }

            auto manager = driver.connectionManager(sid);
            auto conn = manager.connection();
            bool connected = conn.connected();
            auto icon = serverIconAndBackground(connected, manager, server);

            auto serverInfo = Value.dictOf(
                "value", sid,
                "label", server["name"],
                "image", icon,
                "_id", sid,
                "connected", connected
            );

            string groupName = "Servers";
            if (server.contains("servergroup_id") && !server["servergroup_id"].isNone)
            {
                auto sg = getServerGroup(server["servergroup_id"]);
                if (!sg.isNone && sg.contains("name"))
                    groupName = sg["name"].toString;
            }

            if (!res.contains(groupName))
                res[groupName] = Value.newList();
            res[groupName].list.items ~= serverInfo;
        }
        return makeJsonResponse(1, Value(""), Value(""), Value(null), res, 200);
    }

    private static Response handleGetServer(long sid, long did)
    {
        auto server = getServer(sid);
        if (server.isNone)
            return makeJsonResponse(0, Value(gettext("Could not find the required server.")), Value(""), Value(null), Value(null), 410);

        auto manager = getDriver().connectionManager(sid);
        auto conn = manager.connection(null, null, true, Value(did));
        bool connected = conn.connected();

        auto res = Value.dictOf(
            "sid", sid,
            "name", server["name"],
            "user", server.contains("username") ? server["username"] : Value(""),
            "gid", server["servergroup_id"],
            "type", manager.serverType,
            "connected", connected,
            "database", conn.db.length ? conn.db : ""
        );
        return makeJsonResponse(1, Value(""), Value(""), Value(null), res, 200);
    }

    private static Response handleConnectServer(long sid)
    {
        auto manager = getDriver().connectionManager(sid);
        auto conn = manager.connection();
        if (conn.connected())
        {
            return makeJsonResponse(1, Value(""), Value(gettext("Server connected.")), Value(null), Value.newDict());
        }

        auto server = getServer(sid);
        if (server.isNone)
            return makeJsonResponse(0, Value(gettext("Could not find the required server.")), Value(""), Value(null), Value(null), 410);

        auto view = makeView!ServerNode();
        return view.connect(server["servergroup_id"], Value(sid), false);
    }

    private static Response handleConnectDatabase(long sid, long did)
    {
        auto server = getServer(sid);
        if (server.isNone)
            return makeJsonResponse(0, Value(gettext("Could not find the required server.")), Value(""), Value(null), Value(null), 410);

        auto view = makeView!DatabaseView();
        return view.connect(server["servergroup_id"], Value(sid), Value(did));
    }

    private static Response handleDatabases(long sid)
    {
        auto server = getServer(sid);
        if (server.isNone)
            return makeJsonResponse(0, Value(gettext("Could not find the required server.")), Value(""), Value(null), Value(null), 410);

        auto view = makeView!DatabaseView();
        Response err;
        auto nodes = view.getNodes(server["servergroup_id"], Value(sid), err, true);
        if (err !is null)
            return err;

        Value[] res;
        foreach (dbItem; nodes)
        {
            bool isMaint = server.contains("maintenance_db") && dbItem["label"].toString == server["maintenance_db"].toString;
            res ~= Value.dictOf(
                "value", dbItem["_id"],
                "label", dbItem["label"],
                "_id", dbItem["_id"],
                "connected", dbItem["connected"],
                "allowConn", dbItem["allowConn"],
                "image", dbItem["icon"],
                "canDisconn", dbItem["canDisconn"],
                "is_maintenance_db", isMaint
            );
        }
        return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
    }

    private static Response handleSchemas(long sid, long did)
    {
        auto schemasList = getSchemas(sid, did);
        Value[] res;
        if (schemasList !is null)
        {
            foreach (sch; schemasList)
            {
                res ~= Value.dictOf(
                    "value", sch["_id"],
                    "label", sch["label"],
                    "_id", sch["_id"],
                    "image", sch["icon"]
                );
            }
        }
        return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
    }

    private static Response handleDdlCompare(long transId, long sourceSid, long sourceDid, long sourceScid,
                                            long targetSid, long targetDid, long targetScid,
                                            long sourceOid, long targetOid, string nodeType, string compStatus)
    {
        auto sessionObj = getSchemaDiffSession(session().sid, transId);
        if (sessionObj is null)
            return makeJsonResponse(0, Value(ERROR_MSG_TRANS_ID_NOT_FOUND), Value(""), Value(null), Value(null), 404);

        auto diff = ddlCompare(sourceSid, sourceDid, sourceScid, targetSid, targetDid, targetScid, sourceOid, targetOid, nodeType, compStatus);
        if (diff is null)
        {
            auto msg = Value(gettext("Selected object is not supported for DDL comparison."));
            return makeResponse(Value.dictOf(
                "source_ddl", msg,
                "target_ddl", msg,
                "diff_ddl", msg
            ), 200);
        }
        return makeResponse(Value(diff), 200);
    }
}

void registerSchemaDiffSocketHandlers(SocketIoServer sio)
{
    sio.on("/schema_diff", "connect", (SocketIoClient client, Value data) {
        sio.emit("/schema_diff", "connected", Value.dictOf("sid", client.sid), client.sid);
    });

    sio.on("/schema_diff", "compare_database", (SocketIoClient client, Value data) {
        try
        {
            long transId = data.contains("trans_id") ? data["trans_id"].integer : 0;
            long sourceSid = data.contains("source_sid") ? data["source_sid"].integer : 0;
            long sourceDid = data.contains("source_did") ? data["source_did"].integer : 0;
            long targetSid = data.contains("target_sid") ? data["target_sid"].integer : 0;
            long targetDid = data.contains("target_did") ? data["target_did"].integer : 0;

            bool ignoreOwner = data.contains("ignore_owner") ? data["ignore_owner"].truthy : false;
            bool ignoreWhitespaces = data.contains("ignore_whitespaces") ? data["ignore_whitespaces"].truthy : false;
            bool ignoreTablespace = data.contains("ignore_tablespace") ? data["ignore_tablespace"].truthy : false;
            bool ignoreGrants = data.contains("ignore_grants") ? data["ignore_grants"].truthy : false;

            sio.emit("/schema_diff", "compare_status", Value.dictOf(
                "diff_percentage", 0,
                "compare_msg", gettext("Comparing database objects...")
            ), client.sid);

            auto verCheck = checkVersionCompatibility(sourceSid, targetSid);
            if (!verCheck[0])
            {
                sio.emit("/schema_diff", "compare_database_failed", Value(verCheck[1]), client.sid);
                return;
            }

            auto schemaResult = fetchCompareSchemas(sourceSid, sourceDid, targetSid, targetDid);
            if (schemaResult is null)
            {
                sio.emit("/schema_diff", "compare_database_failed", Value(gettext("Failed to fetch schemas from the server.")), client.sid);
                return;
            }

            long count = 0;
            Value[] comparisonResult = compareDatabaseObjects(
                sourceSid, sourceDid,
                targetSid, targetDid,
                ignoreOwner, ignoreWhitespaces,
                ignoreTablespace, ignoreGrants,
                count
            );

            // Compare schema objects
            if (schemaResult.has("source_only") && schemaResult["source_only"].isList)
            {
                foreach (item; schemaResult["source_only"].list.items)
                {
                    long scid = item["scid"].integer;
                    string schemaName = item["schema_name"].toString;
                    auto res = compareSchemaObjects(
                        sourceSid, sourceDid, scid,
                        targetSid, targetDid, 0,
                        schemaName,
                        ignoreOwner, ignoreWhitespaces,
                        ignoreTablespace, ignoreGrants,
                        count
                    );
                    comparisonResult ~= res;
                }
            }

            if (schemaResult.has("target_only") && schemaResult["target_only"].isList)
            {
                foreach (item; schemaResult["target_only"].list.items)
                {
                    long scid = item["scid"].integer;
                    string schemaName = item["schema_name"].toString;
                    auto res = compareSchemaObjects(
                        sourceSid, sourceDid, 0,
                        targetSid, targetDid, scid,
                        schemaName,
                        ignoreOwner, ignoreWhitespaces,
                        ignoreTablespace, ignoreGrants,
                        count
                    );
                    comparisonResult ~= res;
                }
            }

            if (schemaResult.has("in_both_database") && schemaResult["in_both_database"].isList)
            {
                foreach (item; schemaResult["in_both_database"].list.items)
                {
                    long srcScid = item["src_scid"].integer;
                    long tarScid = item["tar_scid"].integer;
                    string schemaName = item["schema_name"].toString;
                    auto res = compareSchemaObjects(
                        sourceSid, sourceDid, srcScid,
                        targetSid, targetDid, tarScid,
                        schemaName,
                        ignoreOwner, ignoreWhitespaces,
                        ignoreTablespace, ignoreGrants,
                        count
                    );
                    comparisonResult ~= res;
                }
            }

            sio.emit("/schema_diff", "compare_status", Value.dictOf(
                "diff_percentage", 100,
                "compare_msg", gettext("Comparison completed.")
            ), client.sid);

            sio.emit("/schema_diff", "compare_database_success", Value(comparisonResult), client.sid);
        }
        catch (Exception e)
        {
            sio.emit("/schema_diff", "compare_database_failed", Value(e.msg), client.sid);
        }
    });

    sio.on("/schema_diff", "compare_schema", (SocketIoClient client, Value data) {
        try
        {
            long transId = data.contains("trans_id") ? data["trans_id"].integer : 0;
            long sourceSid = data.contains("source_sid") ? data["source_sid"].integer : 0;
            long sourceDid = data.contains("source_did") ? data["source_did"].integer : 0;
            long sourceScid = data.contains("source_scid") ? data["source_scid"].integer : 0;
            long targetSid = data.contains("target_sid") ? data["target_sid"].integer : 0;
            long targetDid = data.contains("target_did") ? data["target_did"].integer : 0;
            long targetScid = data.contains("target_scid") ? data["target_scid"].integer : 0;
            string schemaName = data.contains("schema_name") ? data["schema_name"].toString : "public";

            bool ignoreOwner = data.contains("ignore_owner") ? data["ignore_owner"].truthy : false;
            bool ignoreWhitespaces = data.contains("ignore_whitespaces") ? data["ignore_whitespaces"].truthy : false;
            bool ignoreTablespace = data.contains("ignore_tablespace") ? data["ignore_tablespace"].truthy : false;
            bool ignoreGrants = data.contains("ignore_grants") ? data["ignore_grants"].truthy : false;

            sio.emit("/schema_diff", "compare_status", Value.dictOf(
                "diff_percentage", 0,
                "compare_msg", gettext("Comparing schema objects...")
            ), client.sid);

            long count = 0;
            Value[] comparisonResult = compareSchemaObjects(
                sourceSid, sourceDid, sourceScid,
                targetSid, targetDid, targetScid,
                schemaName,
                ignoreOwner, ignoreWhitespaces,
                ignoreTablespace, ignoreGrants,
                count
            );

            sio.emit("/schema_diff", "compare_status", Value.dictOf(
                "diff_percentage", 100,
                "compare_msg", gettext("Comparison completed.")
            ), client.sid);

            sio.emit("/schema_diff", "compare_schema_success", Value(comparisonResult), client.sid);
        }
        catch (Exception e)
        {
            sio.emit("/schema_diff", "compare_schema_failed", Value(e.msg), client.sid);
        }
    });
}

