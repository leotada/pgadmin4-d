/// `pgadmin/tools/erd`: ERD (Entity Relationship Diagram) tool module.
module pgadmin.tools.erd;

import std.conv : to;
import std.string : strip;
import pgadmin.browser.server_groups.servers.databases.schemas.tables.utils : BaseTableView;
import fkeyUtils = pgadmin.browser.server_groups.servers.databases.schemas.tables.constraints.foreign_key.utils;
import pgadmin.browser.server_groups.servers.databases.schemas.utils : DataTypeReader, getSchemas;
import pgadmin.browser.utils : underscoreUnescape;
import pgadmin.core.i18n;
import pgadmin.core.templates : renderTemplate, tv;
import pgadmin.core.value;
import pgadmin.db.driver : Connection, ServerManager, getDriver, getServer, Res;
import pgadmin.utils.constants : PREF_LABEL_KEYBOARD_SHORTCUTS, PREF_LABEL_OPTIONS;
import pgadmin.utils.preferences : Preference, Preferences;
import pgadmin.web.auth;
import pgadmin.web.context;
import pgadmin.web.flask;
import pgadmin.web.http;
import pgadmin.web.socketio : SocketIoServer, SocketIoClient, getSocketIo;

enum MODULE_NAME = "erd";

class ERDTableView : BaseTableView
{
    this()
    {
        super();
        nodeType = "erd";
    }

    Res getTypes(Value sid, Value did, Value connId)
    {
        auto k = new Dict;
        k["sid"] = sid;
        k["did"] = did;
        k["conn_id"] = connId;
        auto err = tablePrecondition(k);
        if (err !is null)
            return Res(false, Value(err.body));

        auto condition = getTypesConditionSql(false);
        return DataTypeReader.getTypes(conn, condition, true, sid);
    }

    Res getGeometryTypes(Value sid, Value did, Value connId)
    {
        auto k = new Dict;
        k["sid"] = sid;
        k["did"] = did;
        k["conn_id"] = connId;
        auto err = tablePrecondition(k);
        if (err !is null)
            return Res(false, Value(err.body));

        return DataTypeReader.getGeometryTypes(conn);
    }

    string sql(Value sid, Value did, Value connId, Value data, bool withDrop = false)
    {
        auto k = new Dict;
        k["sid"] = sid;
        k["did"] = did;
        k["conn_id"] = connId;
        auto err = tablePrecondition(k);
        if (err !is null)
            return "";

        string name;
        return getSql(did, Value(null), Value(null), data, Value(null), name, true, withDrop);
    }

    Res fetchAllTables(Value sid, Value did, Value connId, Value scid = Value(null))
    {
        auto k = new Dict;
        k["sid"] = sid;
        k["did"] = did;
        k["conn_id"] = connId;
        auto err = tablePrecondition(k);
        if (err !is null)
            return Res(false, Value(err.body));

        Value[] allTables;
        Value schemasRows;
        if (scid.isNone || !scid.truthy)
        {
            auto sRes = getSchemas(conn, false);
            if (!sRes.ok)
                return sRes;
            schemasRows = sRes.value["rows"];
        }
        else
        {
            schemasRows = Value([Value.dictOf("oid", scid)]);
        }

        foreach (row; schemasRows.list.items)
        {
            auto tRes = fetchTables(sid, did, row["oid"], Value(null), true);
            if (!tRes.ok)
                return tRes;
            foreach (v; tRes.value.iterItems())
                allTables ~= v;
        }
        return Res(true, Value(allTables));
    }

    Res traverseRelatedTables(Value sid, Value did, Value connId, Value scid, Value tid,
                             ref Value[long] related, long maxdepth = 0, long currdepth = 0)
    {
        auto k = new Dict;
        k["sid"] = sid;
        k["did"] = did;
        k["conn_id"] = connId;
        auto err = tablePrecondition(k);
        if (err !is null)
            return Res(false, Value(err.body));

        auto tRes = fetchTables(sid, did, scid, tid, true);
        if (!tRes.ok)
            return tRes;

        long tidLong = tid.integer;
        related[tidLong] = tRes.value;

        // Max depth limit reached
        if (maxdepth >= 0 && currdepth == maxdepth)
        {
            Value[] newFks;
            auto curTable = related[tidLong];
            if (curTable.contains("foreign_key"))
            {
                foreach (fk; curTable["foreign_key"].iterItems())
                {
                    long confrelid = fk["confrelid"].integer;
                    if (confrelid in related)
                        newFks ~= fk;
                }
            }
            curTable["foreign_key"] = Value(newFks);
            related[tidLong] = curTable;
            return Res(true, Value(null));
        }

        auto depRes = getFkRefTables(tid);
        if (!depRes.ok)
            return depRes;

        Value[] toCheck;
        if (tRes.value.contains("foreign_key"))
            foreach (fk; tRes.value["foreign_key"].iterItems())
                toCheck ~= fk;
        if (depRes.value.isList)
            foreach (fk; depRes.value.list.items)
                toCheck ~= fk;

        foreach (fk; toCheck)
        {
            long confrelid = fk["confrelid"].integer;
            if (confrelid in related)
                continue;
            auto subRes = traverseRelatedTables(sid, did, connId, fk["refnspoid"], fk["confrelid"],
                                                related, maxdepth, currdepth + 1);
            if (!subRes.ok)
                return subRes;
        }

        return Res(true, Value(null));
    }
}

class ERDHelper
{
    string connId;
    long sid;
    long did;
    ERDTableView tableView;

    this(string connId, long sid, long did)
    {
        this.connId = connId;
        this.sid = sid;
        this.did = did;
        this.tableView = new ERDTableView();
    }

    Res getTypes()
    {
        return tableView.getTypes(Value(sid), Value(did), Value(connId));
    }

    Res getGeometryTypes()
    {
        return tableView.getGeometryTypes(Value(sid), Value(did), Value(connId));
    }

    string getTableSql(Value data, bool withDrop = false)
    {
        return tableView.sql(Value(sid), Value(did), Value(connId), data, withDrop);
    }

    Res getAllTables(Value scid, Value tid)
    {
        if (tid.isNone && scid.isNone)
        {
            return tableView.fetchAllTables(Value(sid), Value(did), Value(connId));
        }
        else if (tid.isNone)
        {
            return tableView.fetchAllTables(Value(sid), Value(did), Value(connId), scid);
        }
        else
        {
            auto prefs = Preferences.module_("erd");
            long depth = -1;
            if (prefs !is null)
            {
                auto p = prefs.preference("table_relation_depth");
                if (p !is null)
                    depth = p.get().integer;
            }
            Value[long] related;
            auto status = tableView.traverseRelatedTables(Value(sid), Value(did), Value(connId),
                                                          scid, tid, related, depth, 0);
            if (!status.ok)
                return status;
            Value[] res;
            foreach (v; related.byValue)
                res ~= v;
            return Res(true, Value(res));
        }
    }
}

Value[] translateForeignKeys(Value tabFks, Value tabData, Value allNodes)
{
    Value[] result;
    if (!tabFks.isList)
        return result;

    foreach (tabFk; tabFks.list.items)
    {
        if (!tabFk.contains("columns") || tabFk["columns"].length == 0)
            continue;

        auto refKey = tabFk["columns"][0]["references"].toString;
        if (!allNodes.contains(refKey))
            continue;

        auto remoteTable = allNodes[refKey];
        tabFk["schema"] = tabData["schema"];
        tabFk["table"] = tabData["name"];
        tabFk["remote_schema"] = remoteTable["schema"];
        tabFk["remote_table"] = remoteTable["name"];

        auto newCol = Value.dictOf(
            "local_column", tabFk["columns"][0]["local_column"],
            "referenced", tabFk["columns"][0]["referenced"]
        );
        tabFk["columns"] = Value([newCol]);
        result ~= tabFk;
    }
    return result;
}

private Value shortcutDefault(bool alt, bool shift, bool control, bool ctrlIsMeta, int keyCode, string char_)
{
    auto d = new Dict;
    d["alt"] = Value(alt);
    d["shift"] = Value(shift);
    d["control"] = Value(control);
    d["ctrl_is_meta"] = Value(ctrlIsMeta);
    d["key"] = Value.dictOf("key_code", Value(keyCode), "char", Value(char_));
    return Value(d);
}

private Dict shortcutKw(string catLabel)
{
    auto kw = new Dict;
    kw["category_label"] = Value(catLabel);
    kw["fields"] = Value(["key", "button", "alt", "shift", "control", "ctrl_is_meta"]);
    return kw;
}

final class ERDModule : Blueprint
{
    this()
    {
        super(MODULE_NAME);
        label = Value(gettext("ERD tool"));
    }

    override string[] getExposedUrlEndpoints()
    {
        return [
            "erd.panel",
            "erd.initialize",
            "erd.prequisite",
            "erd.sql",
            "erd.close"
        ];
    }

    override void registerPreferences()
    {
        auto prefs = Preferences.module_(MODULE_NAME);
        if (prefs is null)
            return;

        auto skw = shortcutKw(PREF_LABEL_KEYBOARD_SHORTCUTS);

        prefs.register("keyboard_shortcuts", "open_project", Value(gettext("Open project")),
                       "keyboardshortcut", shortcutDefault(false, false, true, true, 79, "o"), skw);

        prefs.register("keyboard_shortcuts", "save_project", Value(gettext("Save project")),
                       "keyboardshortcut", shortcutDefault(false, false, true, true, 83, "s"), skw);

        prefs.register("keyboard_shortcuts", "save_project_as", Value(gettext("Save project as")),
                       "keyboardshortcut", shortcutDefault(false, true, true, false, 83, "s"), skw);

        prefs.register("keyboard_shortcuts", "generate_sql", Value(gettext("Generate SQL")),
                       "keyboardshortcut", shortcutDefault(true, false, true, false, 83, "s"), skw);

        prefs.register("keyboard_shortcuts", "download_image", Value(gettext("Download image")),
                       "keyboardshortcut", shortcutDefault(true, false, true, false, 73, "i"), skw);

        prefs.register("keyboard_shortcuts", "search_table", Value(gettext("Search table")),
                       "keyboardshortcut", shortcutDefault(true, false, true, false, 70, "f"), skw);

        prefs.register("keyboard_shortcuts", "add_table", Value(gettext("Add table")),
                       "keyboardshortcut", shortcutDefault(true, false, true, false, 65, "a"), skw);

        prefs.register("keyboard_shortcuts", "edit_table", Value(gettext("Edit table")),
                       "keyboardshortcut", shortcutDefault(true, false, true, false, 69, "e"), skw);

        prefs.register("keyboard_shortcuts", "clone_table", Value(gettext("Clone table")),
                       "keyboardshortcut", shortcutDefault(true, false, true, false, 67, "c"), skw);

        prefs.register("keyboard_shortcuts", "drop_table", Value(gettext("Drop table")),
                       "keyboardshortcut", shortcutDefault(true, false, true, false, 68, "d"), skw);

        prefs.register("keyboard_shortcuts", "add_edit_note", Value(gettext("Add/Edit note")),
                       "keyboardshortcut", shortcutDefault(true, false, true, false, 78, "n"), skw);

        prefs.register("keyboard_shortcuts", "one_to_one", Value(gettext("One to one link")),
                       "keyboardshortcut", shortcutDefault(true, false, true, false, 66, "b"), skw);

        prefs.register("keyboard_shortcuts", "one_to_many", Value(gettext("One to many link")),
                       "keyboardshortcut", shortcutDefault(true, false, true, false, 79, "o"), skw);

        prefs.register("keyboard_shortcuts", "many_to_many", Value(gettext("Many to many link")),
                       "keyboardshortcut", shortcutDefault(true, false, true, false, 77, "m"), skw);

        prefs.register("keyboard_shortcuts", "auto_align", Value(gettext("Auto align")),
                       "keyboardshortcut", shortcutDefault(true, false, true, false, 76, "l"), skw);

        prefs.register("keyboard_shortcuts", "show_details", Value(gettext("Show more/fewer details")),
                       "keyboardshortcut", shortcutDefault(true, false, true, false, 84, "t"), skw);

        prefs.register("keyboard_shortcuts", "zoom_to_fit", Value(gettext("Zoom to fit")),
                       "keyboardshortcut", shortcutDefault(true, true, false, false, 70, "f"), skw);

        prefs.register("keyboard_shortcuts", "zoom_in", Value(gettext("Zoom in")),
                       "keyboardshortcut", shortcutDefault(true, true, false, false, 187, "+"), skw);

        prefs.register("keyboard_shortcuts", "zoom_out", Value(gettext("Zoom out")),
                       "keyboardshortcut", shortcutDefault(true, true, false, false, 189, "-"), skw);

        // Options
        auto okwDrop = new Dict;
        okwDrop["category_label"] = Value(PREF_LABEL_OPTIONS);
        okwDrop["help_str"] = Value(gettext("If enabled, the SQL generated by the ERD Tool will add DROP table DDL before each CREATE table DDL."));
        prefs.register("options", "sql_with_drop", Value(gettext("SQL With DROP Table")),
                       "boolean", Value(false), okwDrop);

        auto okwDepth = new Dict;
        okwDepth["category_label"] = Value(PREF_LABEL_OPTIONS);
        okwDepth["help_str"] = Value(gettext("The maximum depth pgAdmin should traverse to find related tables when generating an ERD for a table. Use -1 for no limit."));
        prefs.register("options", "table_relation_depth", Value(gettext("Table Relation Depth")),
                       "integer", Value(-1), okwDepth);

        auto okwInsert = new Dict;
        okwInsert["category_label"] = Value(PREF_LABEL_OPTIONS);
        okwInsert["help_str"] = Value(gettext("Whether inserting a table via drag and drop should also insert its relations to the existing tables in the diagram."));
        prefs.register("options", "insert_table_with_relations", Value(gettext("Insert Table With Relations")),
                       "boolean", Value(false), okwInsert);

        auto okwNotation = new Dict;
        okwNotation["category_label"] = Value(PREF_LABEL_OPTIONS);
        okwNotation["help_str"] = Value(gettext("Notation to be used to present cardinality."));
        okwNotation["options"] = Value([
            Value.dictOf("label", gettext("Crow's foot"), "value", "crows"),
            Value.dictOf("label", gettext("Chen"), "value", "chen"),
        ]);
        prefs.register("options", "cardinality_notation", Value(gettext("Cardinality Notation")),
                       "radioModern", Value("crows"), okwNotation);

        auto okwRes = new Dict;
        okwRes["category_label"] = Value(PREF_LABEL_OPTIONS);
        okwRes["help_str"] = Value(gettext("Higher values will use higher memory and slower rendering."));
        okwRes["options"] = Value([
            Value.dictOf("label", gettext("Good"), "value", "1"),
            Value.dictOf("label", gettext("High"), "value", "3"),
            Value.dictOf("label", gettext("Very High"), "value", "5"),
        ]);
        prefs.register("options", "image_pixel_ratio", Value(gettext("Image Download Resolution")),
                       "radioModern", Value("1"), okwRes);

        auto okwFormat = new Dict;
        okwFormat["category_label"] = Value(PREF_LABEL_OPTIONS);
        okwFormat["help_str"] = Value(gettext("If enabled, the .pgerd project file of the ERD tool will be formatted before saving."));
        prefs.register("options", "format_pgerd", Value(gettext("Format ERD Project File?")),
                       "boolean", Value(false), okwFormat);
    }

    override void setup()
    {
        registerPreferences();

        route("/panel/<int:trans_id>", "panel", ["POST"], permissionsRequired(loginRequired((Dict a) => panelEndpoint(a)), "tools_erd_tool"));
        route("/initialize/<int:trans_id>/<int:sgid>/<int:sid>/<int:did>", "initialize", ["POST"], permissionsRequired(loginRequired((Dict a) => initializeEndpoint(a)), "tools_erd_tool"));
        route("/prequisite/<int:trans_id>/<int:sgid>/<int:sid>/<int:did>", "prequisite", ["GET"], permissionsRequired(loginRequired((Dict a) => prequisiteEndpoint(a)), "tools_erd_tool"));
        route("/sql/<int:trans_id>/<int:sgid>/<int:sid>/<int:did>", "sql", ["POST"], permissionsRequired(loginRequired((Dict a) => sqlEndpoint(a)), "tools_erd_tool"));
        route("/close/<int:trans_id>/<int:sgid>/<int:sid>/<int:did>", "close", ["DELETE"], loginRequired((Dict a) => closeEndpoint(a)));
        route("/tables/<int:trans_id>/<int:sgid>/<int:sid>/<int:did>", "tables", ["GET", "POST"], permissionsRequired(loginRequired((Dict a) => tablesEndpoint(a)), "tools_erd_tool"));

        registerErdSocketHandlers(getSocketIo());
    }

    private static Response panelEndpoint(Dict a)
    {
        long transId = a["trans_id"].integer;
        auto params = Value.newDict();
        params["trans_id"] = Value(transId);

        if (request().text.length)
        {
            try
            {
                auto parsed = parseJson(request().text);
                if (parsed.isDict)
                    foreach (k; parsed.dict.keys)
                        params[k] = parsed[k];
            }
            catch (Exception) {}
        }

        foreach (k; request().args.keys)
            params[k] = Value(request().args.get(k));

        if (params.contains("gen"))
            params["gen"] = Value(params["gen"] == Value("true") || params["gen"] == Value(true));

        long sid = params.contains("sid") ? params["sid"].integer : 0;
        auto s = getServer(sid);

        if (!s.isNone)
        {
            params["bgcolor"] = s.get("bgcolor");
            params["fgcolor"] = s.get("fgcolor");
            params["client_platform"] = Value("Linux");
            params["is_desktop_mode"] = Value(false);
            params["is_linux"] = Value(true);
            auto connectionTitle = params.contains("connectionTitle") ? underscoreUnescape(params["connectionTitle"].toString) : "";
            return new Response(renderTemplate("erd/index.html", tv(
                "connectionTitle", Value(connectionTitle),
                "title", Value(connectionTitle),
                "params", Value(params.toJsonSpaced()),
                "csp_nonce", reqctx().cspNonce
            )), 200);
        }

        params["error"] = Value("Server did not find.");
        return new Response(renderTemplate("erd/index.html", tv(
            "title", Value(null),
            "params", Value(params.toJsonSpaced()),
            "csp_nonce", reqctx().cspNonce
        )), 200);
    }

    private static Response initializeEndpoint(Dict a)
    {
        long transId = a["trans_id"].integer;
        long sid = a["sid"].integer;
        long did = a["did"].integer;

        Value reqData = Value.newDict();
        if (request().text.length)
        {
            try { reqData = parseJson(request().text); } catch (Exception) {}
        }

        string dbName = reqData.isDict && reqData.contains("db_name") ? reqData["db_name"].toString : null;
        auto manager = getDriver().connectionManagerOrNull(sid);
        if (manager is null)
            return gone(gettext("Could not find the server."));

        auto conn = manager.connection(dbName, to!string(transId), true, Value(did));
        auto r = conn.connect();
        if (!r.ok)
        {
            auto res = Value.newDict();
            res["server_label"] = reqData.isDict ? reqData.get("server_name") : Value(null);
            res["username"] = reqData.isDict ? reqData.get("user") : Value(null);
            res["server_type"] = reqData.isDict ? reqData.get("server_type") : Value(null);
            res["errmsg"] = Value(r.error);
            res["prompt_password"] = Value(true);
            res["allow_save_password"] = Value(true);
            return makeJsonResponse(0, Value(""), Value(""), Value(null), res, 428);
        }

        auto resData = Value.dictOf(
            "connId", Value(to!string(transId)),
            "database", Value(conn.db),
            "serverVersion", Value(conn.manager.version_)
        );
        return makeJsonResponse(1, Value(""), Value(""), Value(null), resData, 200);
    }

    private static Response prequisiteEndpoint(Dict a)
    {
        long transId = a["trans_id"].integer;
        long sid = a["sid"].integer;
        long did = a["did"].integer;

        auto manager = getDriver().connectionManagerOrNull(sid);
        if (manager is null)
            return gone(gettext("Could not find the server."));

        auto conn = manager.connection(null, to!string(transId), true, Value(did));
        if (!conn.connected())
        {
            auto r = conn.connect();
            if (!r.ok)
                return internalServerError(r.error);
        }

        auto helper = new ERDHelper(to!string(transId), sid, did);
        auto colTypesRes = helper.getTypes();
        if (!colTypesRes.ok)
            return internalServerError(colTypesRes.error);

        auto schemasRes = getSchemas(conn, false);
        if (!schemasRes.ok)
            return internalServerError(schemasRes.error);

        auto geomTypesRes = helper.getGeometryTypes();
        if (!geomTypesRes.ok)
            return internalServerError(geomTypesRes.error);

        auto data = Value.dictOf(
            "col_types", colTypesRes.value,
            "schemas", schemasRes.value["rows"],
            "geometry_types", geomTypesRes.value
        );
        return makeJsonResponse(1, Value(""), Value(""), Value(null), data, 200);
    }

    private static Response sqlEndpoint(Dict a)
    {
        long transId = a["trans_id"].integer;
        long sid = a["sid"].integer;
        long did = a["did"].integer;

        Value data = Value.newDict();
        if (request().text.length)
        {
            try { data = parseJson(request().text); } catch (Exception) {}
        }

        bool withDrop = false;
        if (request().args.has("with_drop"))
            withDrop = request().args.get("with_drop") == "true";

        auto helper = new ERDHelper(to!string(transId), sid, did);
        auto manager = getDriver().connectionManagerOrNull(sid);
        if (manager is null)
            return gone(gettext("Could not find the server."));

        auto conn = manager.connection(null, to!string(transId), true, Value(did));
        if (!conn.connected())
        {
            auto r = conn.connect();
            if (!r.ok)
                return internalServerError(r.error);
        }

        string sqlText = "";
        Value[] tabForeignKeys;
        auto allNodes = data.isDict && data.contains("nodes") ? data["nodes"] : Value.newDict();

        string tableSql = "";
        if (allNodes.isDict)
        {
            foreach (tabKey; allNodes.dict.keys)
            {
                auto tabData = allNodes[tabKey];
                Value tabFks = Value.newList();
                if (tabData.contains("foreign_key"))
                {
                    tabFks = tabData["foreign_key"];
                    tabData.dict.remove("foreign_key");
                }
                auto translated = translateForeignKeys(tabFks, tabData, allNodes);
                foreach (fk; translated)
                    tabForeignKeys ~= fk;

                tableSql ~= "\n\n" ~ helper.getTableSql(tabData, withDrop);
            }
        }

        if (withDrop)
        {
            foreach (tabFk; tabForeignKeys)
            {
                auto fkSql = fkeyUtils.getDeleteSql(conn, tabFk);
                sqlText ~= "\n\n" ~ fkSql;
            }
        }

        if (sqlText.length != 0)
            sqlText ~= "\n\n";

        sqlText ~= tableSql;
        foreach (tabFk; tabForeignKeys)
        {
            Value outName;
            auto fkSql = fkeyUtils.getSql(conn, tabFk, Value(null), Value(null), outName);
            sqlText ~= "\n\n" ~ fkSql;
        }

        return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(sqlText), 200);
    }

    private static Response closeEndpoint(Dict a)
    {
        long transId = a["trans_id"].integer;
        long sid = a["sid"].integer;
        long did = a["did"].integer;

        auto manager = getDriver().connectionManagerOrNull(sid);
        if (manager !is null)
        {
            auto conn = manager.connection(null, to!string(transId), false, Value(did));
            if (conn !is null && conn.connected())
            {
                try { conn.cancelTransaction(to!string(transId), Value(did)); } catch (Exception) {}
                manager.release(null, to!string(transId), Value(did));
            }
        }
        return makeJsonResponse(1, Value(""), Value(""), Value(null), Value.dictOf("status", Value(true)), 200);
    }

    private static Response tablesEndpoint(Dict a)
    {
        long transId = a["trans_id"].integer;
        long sid = a["sid"].integer;
        long did = a["did"].integer;

        Value scid = Value(null);
        Value tid = Value(null);
        if (request().args.has("scid"))
            scid = Value(to!long(request().args.get("scid")));
        if (request().args.has("tid"))
            tid = Value(to!long(request().args.get("tid")));

        if (request().text.length)
        {
            auto body_ = parseJson(request().text);
            if (body_.isDict)
            {
                if (body_.contains("scid") && !body_["scid"].isNone)
                    scid = body_["scid"];
                if (body_.contains("tid") && !body_["tid"].isNone)
                    tid = body_["tid"];
            }
        }

        auto helper = new ERDHelper(to!string(transId), sid, did);
        auto tRes = helper.getAllTables(scid, tid);
        if (!tRes.ok)
            return internalServerError(tRes.error);
        return makeJsonResponse(1, Value(""), Value(""), Value(null), tRes.value, 200);
    }
}

void registerErdSocketHandlers(SocketIoServer sio)
{
    sio.on("/erd", "connect", (SocketIoClient client, Value data) {
        sio.emit("/erd", "connected", Value.dictOf("sid", client.sid), client.sid);
    });

    sio.on("/erd", "tables", (SocketIoClient client, Value data) {
        try
        {
            long transId = data.contains("trans_id") ? data["trans_id"].integer : 0;
            long sid = data.contains("sid") ? data["sid"].integer : 0;
            long did = data.contains("did") ? data["did"].integer : 0;

            Value scid = data.contains("scid") ? data["scid"] : Value(null);
            Value tid = data.contains("tid") ? data["tid"] : Value(null);

            auto helper = new ERDHelper(to!string(transId), sid, did);
            auto tRes = helper.getAllTables(scid, tid);
            if (!tRes.ok)
            {
                sio.emit("/erd", "tables_failed", Value(tRes.error), client.sid);
                return;
            }
            sio.emit("/erd", "tables_success", tRes.value, client.sid);
        }
        catch (Exception e)
        {
            sio.emit("/erd", "tables_failed", Value(e.msg), client.sid);
        }
    });
}

