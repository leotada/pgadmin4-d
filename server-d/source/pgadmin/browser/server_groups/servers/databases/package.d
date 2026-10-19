/// `pgadmin/browser/server_groups/servers/databases`: databases of a server.
module pgadmin.browser.server_groups.servers.databases;

import std.algorithm : canFind;
import std.array : join, replace, split;
import std.conv : to;
import std.regex : regex, replaceAll;
import std.string : strip, stripRight, stripLeft;
import pgadmin.browser.server_groups.servers.databases.utils;
import pgadmin.browser.server_groups.servers.utils;
import pgadmin.browser.utils;
import pgadmin.core.i18n;
import pgadmin.core.log;
import pgadmin.core.templates;
import pgadmin.core.value;
import pgadmin.db.driver;
import pgadmin.model;
import pgadmin.tools.sqleditor.utils.query_history : updateHistoryDbname;
import pgadmin.utils.constants;
import pgadmin.utils.exception;
import pgadmin.utils.server_access;
import pgadmin.web.auth;
import pgadmin.web.context;
import pgadmin.web.flask;
import pgadmin.web.http;

final class DatabaseModule : CollectionNodeModule
{
    enum NODE_TYPE = "database";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "Databases";
        minVer = Value(null);
        maxVer = Value(null);
        staticDir("browser/server_groups/servers/databases");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => "server";

    override Value[] getNodes(Dict kwargs)
    {
        if (showNode)
            return [generateBrowserCollectionNode(kwargs["sid"])];
        return null;
    }

    override string[] csssnippets()
    {
        string[] snippets = [
            renderTemplate("browser/css/collection.css", tv("node_type", nodeType)),
            renderTemplate("databases/css/database.css", tv("node_type", nodeType)),
        ];
        foreach (m; submodules)
            if (auto b = cast(BrowserPluginModule) m)
                snippets ~= b.csssnippets;
        return snippets;
    }

    override void setup()
    {
        import pgadmin.browser.server_groups.servers.databases.registry : registerDatabaseSubmodules;
        registerDatabaseSubmodules(this);
        registerNodeView!DatabaseView(this);
    }
}

final class DatabaseView : PGChildNodeView
{
    ServerManager manager;
    Connection conn;
    string templatePath;
    bool datistemplate;
    bool dbAllowConnection = true;
    Value _db = Value(null);

    this()
    {
        super();
        nodeType = DatabaseModule.NODE_TYPE;
        nodeLabel = "Database";
        parentIds = [IdSpec("int", "gid"), IdSpec("int", "sid")];
        ids = [IdSpec("int", "did")];
        setAllOps([
            makeOp("obj", ["get": "properties", "delete": "delete", "put": "update"],
                    ["get": "list", "post": "create", "delete": "delete"]),
            makeOp("nodes", ["get": "node"], ["get": "nodes"]),
            makeOp("get_databases", ["get": "get_databases"], ["get": "get_databases"]),
            makeOp("sql", ["get": "sql"]),
            makeOp("msql", ["get": "msql"], ["get": "msql"]),
            makeOp("stats", ["get": "statistics"], ["get": "statistics"]),
            makeOp("dependency", ["get": "dependencies"]),
            makeOp("dependent", ["get": "dependents"]),
            makeOp("children", ["get": "children"]),
            makeOp("connect", ["get": "connect_status", "post": "connect", "delete": "disconnect"]),
            makeOp("get_encodings", ["get": "get_encodings"], ["get": "get_encodings"]),
            makeOp("get_ctypes", ["get": "get_ctypes"], ["get": "get_ctypes"]),
            makeOp("get_icu_locale", ["get": "get_icu_locale"], ["get": "get_icu_locale"]),
            makeOp("get_builtin_locale", ["get": "get_builtin_locale"], ["get": "get_builtin_locale"]),
            makeOp("vopts", cast(string[string]) null, ["get": "variable_options"]),
            makeOp("delete", ["delete": "delete"], ["delete": "delete"]),
        ]);
    }

    private DatabaseModule dm() => cast(DatabaseModule) bpModule;

    /// `check_precondition(action)`: sets manager, conn and the template path; returns an error response or null.
    Response checkPrecondition(string action, Dict kwargs)
    {
        manager = getDriver().connectionManagerOrNull(kwargs["sid"].integer);
        if (manager is null)
            return gone(gettext("Could not find the server."));
        datistemplate = false;
        if (action == "drop")
            conn = manager.connection();
        else if (kwargs.has("did"))
        {
            conn = manager.connection(null, null, true, kwargs["did"]);
            dbAllowConnection = true;
            if (manager.dbInfo.has(kwargs["did"].toString))
            {
                _db = manager.dbInfo[kwargs["did"].toString];
                auto a = getAttributesFromDbInfo(manager, kwargs);
                datistemplate = a.datistemplate;
                if (!a.datallowconn)
                {
                    conn = manager.connection();
                    dbAllowConnection = false;
                }
            }
        }
        else
            conn = manager.connection();
        templatePath = "databases/sql/#" ~ to!string(manager.version_) ~ "#";
        return null;
    }

    private enum noPre = "";

    override Response callMethod(string name, Dict k)
    {
        if (!isAuthenticated() && name != "connect" && name != "disconnect")
            return unauthorisedResponse();
        auto gid = k.has("gid") ? k["gid"] : Value(null);
        auto sid = k.has("sid") ? k["sid"] : Value(null);
        auto did = k.has("did") ? k["did"] : Value(null);
        string action = name;
        // the action used by check_precondition for each method (decorator argument)
        switch (name)
        {
        case "connect_status", "connect", "disconnect":
            return name == "connect" ? connect(gid, sid, did) : name == "disconnect" ? disconnect(gid, sid, did)
                : connectStatus(gid, sid, did);
        case "children": return children(k);
        default: break;
        }
        string pre = name;
        if (name == "delete")
            pre = "drop";
        else if (name == "statistics" || name == "dependencies" || name == "dependents")
            pre = "";
        else if (name == "update")
            pre = "update";
        else if (name == "list")
            pre = "list";
        auto err = checkPrecondition(pre, k);
        if (err !is null)
            return err;
        switch (name)
        {
        case "list": return list(gid, sid);
        case "nodes": return nodes(gid, sid);
        case "node": return node(gid, sid, did);
        case "get_databases": return getDatabases(gid, sid);
        case "properties": return properties(gid, sid, did);
        case "get_encodings": return getEncodings();
        case "get_ctypes": return getCtypes();
        case "get_icu_locale": return getIcuLocale();
        case "get_builtin_locale": return getBuiltinLocale();
        case "create": return create(gid, sid);
        case "update": return update(gid, sid, did);
        case "delete": return delete_(gid, sid, did);
        case "msql": return msql(gid, sid, did);
        case "variable_options": return variableOptions();
        case "statistics": return statistics(gid, sid, did);
        case "sql": return sql(gid, sid, did);
        case "dependents": return dependentsView(did);
        case "dependencies": return dependenciesView(did);
        default: return super.callMethod(name, k);
        }
    }

    // ---- list / nodes

    long retrieveLastSystemOid() => dm.showSystemObjects ? 0 : DATABASE_LAST_SYSTEM_OID;

    private Response list(Value gid, Value sid)
    {
        auto lastSystemOid = retrieveLastSystemOid();
        auto dr = getDbDispRestriction(manager);
        auto sql = renderTemplate(templatePath ~ "/" ~ PROPERTIES_SQL, tv("conn", conn, "last_system_oid", lastSystemOid,
                "db_restrictions", dr.expr));
        auto r = conn.executeDict(sql, dr.params);
        if (!r.ok)
            return internalServerError(r.error);
        Value[] resultSet;
        foreach (row; r.value["rows"].list.items)
        {
            row["is_sys_obj"] = Value(row["did"].integer <= DATABASE_LAST_SYSTEM_OID || datistemplate);
            if (skipDb(row))
                continue;
            row["canDrop"] = Value(manager.db != row["name"].toString);
            resultSet ~= row;
        }
        return makeResponse(Value(resultSet), 200);
    }

    static string getIcon(Value res, bool connected)
    {
        bool tmpl = res["is_template"].truthy;
        if (!connected && !tmpl)
            return "icon-database-not-connected";
        if (!connected && tmpl)
            return "icon-database-template-not-connected";
        if (connected && tmpl)
            return "icon-database-template-connected";
        return "pg-icon-database";
    }

    private bool skipDb(Value row)
    {
        auto name = row["name"].toString;
        bool sys = row["is_sys_obj"].truthy;
        bool pgdb = name == "postgres" || name == "edb";
        if ((!dm.showSystemObjects && sys && !pgdb) || (!dm.showDatabaseTemplate && sys && !pgdb))
            return true;
        if (!dm.showDatabaseTemplate && row["is_template"].truthy && !sys && !pgdb)
            return true;
        return false;
    }

    /// `get_nodes(gid, sid, is_schema_diff)`: the tree nodes (also used by schema diff).
    Value[] getNodes(Value gid, Value sid, out Response err, bool isSchemaDiff = false)
    {
        Value[] res;
        auto lastSystemOid = retrieveLastSystemOid();
        if (isSchemaDiff && manager.dbInfo !is null && manager.did.isInt && manager.dbInfo.has(manager.did.toString))
            lastSystemOid = DATABASE_LAST_SYSTEM_OID;
        auto dr = getDbDispRestriction(manager);
        auto sql = renderTemplate(templatePath ~ "/" ~ NODES_SQL, tv("last_system_oid", lastSystemOid, "db_restrictions", dr.expr));
        auto r = conn.executeDict(sql, dr.params);
        if (!r.ok)
        {
            err = internalServerError(r.error);
            return null;
        }
        foreach (row; r.value["rows"].list.items)
        {
            auto dbname = row["name"].toString;
            row["is_sys_obj"] = Value(row["did"].integer <= DATABASE_LAST_SYSTEM_OID || datistemplate);
            if (skipDb(row))
                continue;
            bool connected, canDrop, canDisConn;
            if (manager.db == dbname)
            {
                connected = true;
                canDrop = canDisConn = false;
            }
            else
            {
                auto c = manager.connection(dbname, null, true, row["did"]);
                connected = c.connected();
                canDrop = canDisConn = true;
            }
            auto icon = getIcon(row, connected);
            res ~= bpModule.generateBrowserNode(row["did"], sid, row["name"].toString, icon, row["datallowconn"].truthy,
                    nodeType, kwDict("connected", connected, "tablespace", row["spcname"], "allowConn", row["datallowconn"],
                        "canCreate", row["cancreate"], "canDisconn", canDisConn, "canDrop", canDrop, "isTemplate",
                        row["is_template"], "description", row["description"]));
        }
        return res;
    }

    private Response nodes(Value gid, Value sid)
    {
        Response err;
        auto res = getNodes(gid, sid, err);
        if (err !is null)
            return err;
        return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
    }

    private Response getDatabases(Value gid, Value sid)
    {
        auto sql = renderTemplate(templatePath ~ "/" ~ NODES_SQL, tv("last_system_oid", 0, "show_system_objects", true));
        auto r = conn.executeDict(sql);
        if (!r.ok)
            return internalServerError(r.error);
        Value[] res;
        foreach (row; r.value["rows"].list.items)
            res ~= row["name"];
        return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
    }

    private Response node(Value gid, Value sid, Value did)
    {
        auto sql = renderTemplate(templatePath ~ "/" ~ NODES_SQL, tv("did", did, "conn", conn, "last_system_oid", 0,
                "show_system_objects", dm.showSystemObjects));
        auto r = conn.execute2darray(sql);
        if (!r.ok)
            return internalServerError(r.error);
        foreach (row; r.value["rows"].list.items)
        {
            bool connected;
            if (manager.db == row["name"].toString)
                connected = true;
            else
                connected = manager.connection(row["name"].toString).connected();
            auto icon = connected ? "pg-icon-database" : "icon-database-not-connected";
            return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    bpModule.generateBrowserNode(row["did"], sid, row["name"].toString, icon, true, nodeType,
                        kwDict("connected", connected, "spcname", row["spcname"], "allowConn", row["datallowconn"],
                            "canCreate", row["cancreate"])), 200);
        }
        return gone(notFoundErrorMsg());
    }

    // ---- properties

    private static Value formatDbAcl(Value res, Value dbacl)
    {
        foreach (row; dbacl.list.items)
        {
            auto priv = parsePrivFromDb(row);
            auto first = res["rows"][0];
            auto t = row["deftype"].toString;
            if (!first.contains(t))
                first[t] = Value.newList();
            first[t].append(priv);
        }
        return res;
    }

    private Response properties(Value gid, Value sid, Value did)
    {
        auto sql = renderTemplate(templatePath ~ "/" ~ PROPERTIES_SQL, tv("did", did, "conn", conn, "last_system_oid", 0,
                "show_system_objects", dm.showSystemObjects));
        auto r = conn.executeDict(sql);
        if (!r.ok)
            return internalServerError(r.error);
        auto res = r.value;
        if (res["rows"].length == 0)
            return gone(notFoundErrorMsg());
        auto a = conn.executeDict(renderTemplate(templatePath ~ "/" ~ ACL_SQL, tv("did", did, "conn", conn)));
        if (!a.ok)
            return internalServerError(res.toString);
        res = formatDbAcl(res, a.value["rows"]);
        auto d = conn.executeDict(renderTemplate(templatePath ~ "/defacl.sql", tv("did", did, "conn", conn,
                "grant_reovke_sql", false)));
        if (!d.ok)
            return internalServerError(res.toString);
        res = formatDbAcl(res, d.value["rows"]);
        auto result = res["rows"][0];
        result["is_sys_obj"] = Value(result["oid"].integer <= DATABASE_LAST_SYSTEM_OID);
        auto v = conn.executeDict(renderTemplate(templatePath ~ "/get_variables.sql", tv("did", did, "conn", conn)));
        auto database = db.queryOne("SELECT * FROM \"database\" WHERE id = ? AND server = ?", did, sid);
        if (database.isDict)
        {
            Value[] sr;
            if (database["schema_res"].truthy)
                foreach (p; database["schema_res"].toString.split(","))
                    sr ~= Value(p);
            result["schema_res"] = Value(sr);
        }
        if (!v.ok)
            return internalServerError(v.error);
        if (result.contains("seclabels"))
            result.dict.update(parseSecLabelsFromDb(result["seclabels"]));
        result.dict.update(parseVariablesFromDb(v.value["rows"]));
        return makeResponse(result, 200);
    }

    // ---- connect / disconnect

    private Response connectStatus(Value gid, Value sid, Value did)
    {
        auto m = getDriver().connectionManager(sid.integer);
        auto c = m.connection(null, null, true, did);
        return makeJsonResponse(1, Value(""), Value(""), Value(null), Value.dictOf("connected", c.connected()));
    }

    Response connect(Value gid, Value sid, Value did)
    {
        auto m = getDriver().connectionManager(sid.integer);
        auto c = m.connection(null, null, true, did);
        bool already = c.connected();
        if (!already)
        {
            auto st = c.connect();
            if (!st.ok)
            {
                logError("Could not connected to database(#" ~ did.toString ~ ").\nError: " ~ st.error);
                return internalServerError(st.error);
            }
            logInfo("Connection Established for Database Id: " ~ did.toString);
        }
        auto srv = getServer(sid.integer);
        auto sname = srv.isDict && srv["name"].truthy ? srv["name"].toString : gettext("Unknown");
        return makeJsonResponse(1, Value(""), Value(gettext("Database connected.")), Value(null), Value.dictOf("icon",
                "pg-icon-database", "already_connected", already, "connected", true, "info_prefix", sname ~ "/" ~ c.db));
    }

    Response disconnect(Value gid, Value sid, Value did)
    {
        auto m = getDriver().connectionManager(sid.integer);
        auto c = m.connection(null, null, true, did);
        auto status = m.release(null, null, did);
        if (!status)
            return unauthorized(gettext("Database could not be disconnected."));
        auto srv = getServer(sid.integer);
        auto sname = srv.isDict && srv["name"].truthy ? srv["name"].toString : gettext("Unknown");
        return makeJsonResponse(1, Value(""), Value(gettext("Database disconnected.")), Value(null), Value.dictOf("icon",
                "icon-database-not-connected", "connected", false, "info_prefix", sname ~ "/" ~ c.db));
    }

    // ---- option lists

    private Response simpleList(string tmpl, string col, bool withDefaults = false, string[] defaults = null)
    {
        Value[] res;
        foreach (v; defaults)
            res ~= Value.dictOf("label", v, "value", v);
        auto r = conn.executeDict(renderTemplate(templatePath ~ "/" ~ tmpl));
        if (!r.ok)
            return internalServerError(r.error);
        foreach (row; r.value["rows"].list.items)
        {
            if (defaults.canFind(row[col].toString))
                continue;
            res ~= Value.dictOf("label", row[col], "value", row[col]);
        }
        return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
    }

    private Response getEncodings() => simpleList("get_encodings.sql", "encoding");
    private Response getCtypes() => simpleList("get_ctypes.sql", "cname", true, ["C", "POSIX"]);
    private Response getIcuLocale() => simpleList("get_icu_locale.sql", "colliculocale");
    private Response getBuiltinLocale() => simpleList("get_builtin_locale.sql", "collbuiltinlocale");

    // ---- create / update / delete

    private Response create(Value gid, Value sid)
    {
        auto data = formOrJson(request());
        foreach (arg; ["name"])
            if (!data.contains(arg))
                return makeJsonResponse(0, Value(gettext("Could not find the required parameter ({}).").replace("{}", arg)),
                        Value(""), Value(null), Value(null), 410);
        auto sql = renderTemplate(templatePath ~ "/" ~ CREATE_SQL, tv("data", data, "conn", conn));
        auto r = conn.executeScalar(sql);
        if (!r.ok)
            return internalServerError(r.error);
        if (data.contains("datacl"))
            data["datacl"] = parsePrivToDb(data["datacl"], ["C", "T", "c"]);
        sql = renderTemplate(templatePath ~ "/" ~ GRANT_SQL, tv("data", data, "conn", conn)).strip("\n").strip(" ");
        if (sql.length)
        {
            auto g = conn.executeScalar(sql);
            if (!g.ok)
                return internalServerError(g.error);
        }
        sql = renderTemplate(templatePath ~ "/" ~ PROPERTIES_SQL, tv("name", data["name"], "conn", conn, "last_system_oid", 0,
                "show_system_objects", dm.showSystemObjects)).strip("\n").strip(" ");
        Value res;
        if (sql.length)
        {
            auto p = conn.executeDict(sql);
            if (!p.ok)
                return internalServerError(p.error);
            res = p.value;
        }
        auto response = res["rows"][0];
        string schemaRes;
        if (data.contains("schema_res"))
        {
            string[] ps;
            foreach (x; data["schema_res"].iterItems())
                ps ~= x.toString;
            schemaRes = ps.join(",");
        }
        db.exec("INSERT INTO \"database\" (id, server, schema_res) VALUES (?, ?, ?)", response["did"], sid, Value(schemaRes));
        return jsonify(Value.dictOf("node", bpModule.generateBrowserNode(response["did"], sid, response["name"].toString,
                "icon-database-not-connected", true, nodeType, kwDict("connected", false, "tablespace",
                    response["default_tablespace"], "allowConn", true, "canCreate", response["cancreate"], "canDisconn", true,
                    "canDrop", true, "isTemplate", response["is_template"]))));
    }

    private void updateDbSchemaRes(Value data, Value did, Value sid)
    {
        auto database = db.queryOne("SELECT * FROM \"database\" WHERE id = ? AND server = ?", did, sid);
        if (data.contains("schema_res"))
        {
            string[] ps;
            foreach (x; data["schema_res"].iterItems())
                ps ~= x.toString;
            data["schema_res"] = Value(ps.join(","));
            if (database.isDict)
                db.exec("UPDATE \"database\" SET schema_res = ? WHERE id = ? AND server = ?", data["schema_res"], did, sid);
            else
                db.exec("INSERT INTO \"database\" (id, server, schema_res) VALUES (?, ?, ?)", did, sid, data["schema_res"]);
        }
    }

    private Response update(Value gid, Value sid, Value did)
    {
        auto data = formOrJson(request());
        updateDbSchemaRes(data, did, sid);
        auto offline = manager.connection(null, "db_offline_update");
        auto st = offline.connect();
        if (!st.ok)
        {
            logError("Could not create database connection for offline updates\nErr: " ~ st.error);
            return internalServerError(st.error);
        }
        // _fetch_db_details
        if (!did.isNone)
        {
            auto rs = conn.executeDict(renderTemplate(templatePath ~ "/" ~ NODES_SQL, tv("did", did, "conn", conn,
                    "last_system_oid", 0, "show_system_objects", dm.showSystemObjects)));
            if (!rs.ok)
                return internalServerError(rs.error);
            if (rs.value["rows"].length == 0)
                return gone(gettext("Could not find the database on the server."));
            data["old_name"] = rs.value["rows"][0]["name"];
            if (!data.contains("name"))
                data["name"] = data["old_name"];
        }
        manager.release(null, null, did);
        // _check_rename_db_or_change_table_space
        foreach (action; ["rename_database", "tablespace"])
        {
            auto sql = getOfflineSql(data, action).strip("\n").strip(" ");
            if (sql.length)
            {
                auto r = offline.executeScalar(sql);
                if (!r.ok)
                {
                    conn = manager.connection(data["old_name"].toString);
                    auto c2 = conn.connect();
                    if (!c2.ok)
                        logError("Could not reconnected to database(#" ~ did.toString ~ ").\nError: " ~ c2.error);
                    return internalServerError(r.error);
                }
                updateHistoryDbname(currentUserId(), sid.integer, data["old_name"].toString, data["name"].toString);
            }
        }
        // _reconnect_connect_db
        if (_db.isDict && _db["datallowconn"].truthy)
        {
            conn = manager.connection(data["name"].toString);
            auto c3 = conn.connect();
            if (!c3.ok)
            {
                logError("Could not connected to database(#" ~ did.toString ~ ").\nError: " ~ c3.error);
                return internalServerError(c3.error);
            }
        }
        auto sql = getOnlineSql(data).strip("\n").strip(" ");
        if (sql.length)
        {
            auto r = conn.executeScalar(sql);
            if (!r.ok)
                return internalServerError(r.error);
        }
        manager.release(null, "db_offline_update");
        auto rs = conn.executeDict(renderTemplate(templatePath ~ "/" ~ NODES_SQL, tv("did", did, "conn", conn,
                "last_system_oid", 0, "show_system_objects", dm.showSystemObjects)));
        if (!rs.ok)
            return internalServerError(rs.error);
        if (rs.value["rows"].length == 0)
            return gone(notFoundErrorMsg());
        auto res = rs.value["rows"][0];
        bool canDrop = manager.db != res["name"].toString;
        bool allow = _db.isDict && _db["datallowconn"].truthy;
        bool connected = allow ? conn.connected() : false;
        auto icon = getIcon(res, connected);
        return jsonify(Value.dictOf("node", bpModule.generateBrowserNode(did, sid, res["name"].toString, icon, allow,
                nodeType, kwDict("connected", connected, "tablespace", res["spcname"], "allowConn", res["datallowconn"],
                    "canCreate", res["cancreate"], "canDisconn", canDrop, "canDrop", canDrop, "isTemplate",
                    res["is_template"]))));
    }

    private Response delete_(Value gid, Value sid, Value didArg)
    {
        Value data = didArg.isNone ? formOrJson(request()) : Value.dictOf("ids", Value([didArg]));
        foreach (did; data["ids"].iterItems())
        {
            auto defaultConn = manager.connection();
            auto sql = renderTemplate(templatePath ~ "/" ~ DELETE_SQL, tv("did", did, "conn", conn));
            auto r = defaultConn.executeScalar(sql);
            if (!r.ok)
                return internalServerError(r.error);
            if (r.value.isNone)
                return makeJsonResponse(0, Value(gettext("Error: Object not found.")),
                        Value(gettext("The specified database could not be found.\n")), Value(null), Value(null), 410);
            if (conn.connected())
            {
                auto m = getDriver().connectionManager(sid.integer);
                m.connection(null, null, true, did);
                if (!m.release(null, null, did))
                    return unauthorized(gettext("Database could not be deleted."));
            }
            sql = renderTemplate(templatePath ~ "/" ~ DELETE_SQL, tv("datname", r.value, "conn", conn, "with_force", cmd == "delete"));
            auto d = defaultConn.executeScalar(sql);
            if (!d.ok)
            {
                auto c2 = manager.connection(null, null, true, did);
                c2.connect();
                return internalServerError(underscoreEscape(d.error));
            }
        }
        return makeJsonResponse(1);
    }

    // ---- sql

    private Response msql(Value gid, Value sid, Value did)
    {
        auto data = Value.newDict();
        foreach (k; request().args.keys)
        {
            auto v = request().args.get(k);
            data[k] = k == "comments" ? Value(v) : tryParseJson(v, Value(v));
        }
        Response err;
        auto sql = getSql(gid, sid, data, did, err);
        if (err !is null)
            return err;
        sql = replaceAll(sql, regex("\n{2,}"), "\n\n").strip("\n").strip(" ");
        return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(sql), 200);
    }

    string getSql(Value gid, Value sid, Value data, Value did, out Response err)
    {
        string sql;
        if (!did.isNone)
        {
            auto c = manager.connection();
            auto rs = c.executeDict(renderTemplate(templatePath ~ "/" ~ NODES_SQL, tv("did", did, "conn", c,
                    "last_system_oid", 0, "show_system_objects", dm.showSystemObjects)));
            if (!rs.ok)
            {
                err = internalServerError(rs.error);
                return null;
            }
            if (rs.value["rows"].length == 0)
            {
                err = gone(notFoundErrorMsg());
                return null;
            }
            data["old_name"] = rs.value["rows"][0]["name"];
            if (!data.contains("name"))
                data["name"] = data["old_name"];
            foreach (action; ["rename_database", "tablespace"])
                sql ~= getOfflineSql(data, action);
            sql ~= getOnlineSql(data);
        }
        else
            sql ~= getNewSql(data);
        return sql;
    }

    private Value allowedAcls()
    {
        try
            return parseJson(renderTemplate(templatePath ~ "/allowed_privs.json"));
        catch (Exception e)
        {
            logException(e);
            return Value.newDict();
        }
    }

    string getNewSql(Value data)
    {
        if (!data.contains("name"))
            return gettext(" -- definition incomplete");
        auto acls = allowedAcls();
        foreach (aclcol, allowed; acls.dict)
            if (data.contains(aclcol))
            {
                string[] a;
                foreach (x; allowed["acl"].iterItems())
                    a ~= x.toString;
                data[aclcol] = parsePrivToDb(data[aclcol], a);
            }
        auto sqlAcl = renderTemplate(templatePath ~ "/" ~ GRANT_SQL, tv("data", data, "conn", conn));
        auto sql = renderTemplate(templatePath ~ "/" ~ CREATE_SQL, tv("data", data, "conn", conn));
        return sql ~ "\n" ~ sqlAcl;
    }

    string getOnlineSql(Value data)
    {
        auto acls = allowedAcls();
        foreach (aclcol, allowed; acls.dict)
            if (data.contains(aclcol))
                foreach (key; ["added", "changed", "deleted"])
                    if (data[aclcol].contains(key))
                    {
                        string[] a;
                        foreach (x; allowed["acl"].iterItems())
                            a ~= x.toString;
                        data[aclcol][key] = parsePrivToDb(data[aclcol][key], a);
                    }
        return renderTemplate(templatePath ~ "/alter_online.sql", tv("data", data, "conn", conn));
    }

    string getOfflineSql(Value data, string action)
    {
        return renderTemplate(templatePath ~ "/alter_offline.sql", tv("data", data, "conn", conn, "action", action));
    }

    private Response variableOptions()
    {
        auto r = conn.executeDict(renderTemplate(templatePath ~ "/variables.sql"));
        if (!r.ok)
            return internalServerError(r.error);
        return makeJsonResponse(1, Value(""), Value(""), Value(null), r.value["rows"], 200);
    }

    private Response statistics(Value gid, Value sid, Value did)
    {
        auto lastSystemOid = retrieveLastSystemOid();
        auto dr = getDbDispRestriction(manager);
        auto c = manager.connection();
        auto r = c.executeDict(renderTemplate(templatePath ~ "/stats.sql", tv("did", did, "conn", c, "last_system_oid",
                lastSystemOid, "db_restrictions", dr.expr)), dr.params);
        if (!r.ok)
            return internalServerError(r.error);
        return makeJsonResponse(1, Value(""), Value(""), Value(null), r.value, 200);
    }

    private Response sql(Value gid, Value sid, Value did)
    {
        auto c = manager.connection(null, null, true, did);
        auto sqlText = renderTemplate(templatePath ~ "/" ~ PROPERTIES_SQL, tv("did", did, "conn", c, "last_system_oid", 0,
                "show_system_objects", false));
        if (!c.connected())
            c.connect();
        auto r = c.executeDict(sqlText);
        if (!r.ok)
            return internalServerError(r.error);
        auto res = r.value;
        if (res["rows"].length == 0)
            return gone(notFoundErrorMsg());
        auto a = conn.executeDict(renderTemplate(templatePath ~ "/" ~ ACL_SQL, tv("did", did, "conn", conn)));
        if (!a.ok)
            return internalServerError(a.error);
        res = formatDbAcl(res, a.value["rows"]);
        auto d = conn.executeDict(renderTemplate(templatePath ~ "/defacl.sql", tv("did", did, "conn", conn, "grant_reovke_sql", true)));
        if (!d.ok)
            return internalServerError(d.error);
        res = formatDbAcl(res, d.value["rows"]);
        auto result = res["rows"][0];
        auto v = conn.executeDict(renderTemplate(templatePath ~ "/get_variables.sql", tv("did", did, "conn", conn)));
        if (!v.ok)
            return internalServerError(v.error);
        if (result.contains("seclabels"))
            result.dict.update(parseSecLabelsFromDb(result["seclabels"]));
        result.dict.update(parseVariablesFromDb(v.value["rows"]));
        auto header = "-- Database: " ~ result["name"].toString ~ "\n\n-- ";
        header ~= renderTemplate(templatePath ~ "/" ~ DELETE_SQL, tv("datname", result["name"], "conn", c));
        auto sqlOut = getNewSql(result);
        sqlOut = replaceAll(sqlOut, regex("\n{2,}"), "\n\n");
        sqlOut = (header ~ "\n" ~ sqlOut).strip("\n");
        return makeResponse(Value(sqlOut));
    }

    private Response dependentsView(Value did)
    {
        auto r = conn.connected() ? getDependents(conn, did) : Value.newList();
        return makeResponse(r, 200);
    }

    private Response dependenciesView(Value did)
    {
        auto r = conn.connected() ? getDependencies(conn, did) : Value.newList();
        return makeResponse(r, 200);
    }
}
