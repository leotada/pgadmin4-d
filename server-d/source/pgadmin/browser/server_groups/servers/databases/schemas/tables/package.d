/// `schemas/tables`: tables.
module pgadmin.browser.server_groups.servers.databases.schemas.tables;

import std.regex : regex, replaceAll;
import pgadmin.browser.common;
import pgadmin.browser.server_groups.servers.databases.schemas.utils;
import pgadmin.browser.server_groups.servers.databases.schemas.tables.utils;
import columnUtils = pgadmin.browser.server_groups.servers.databases.schemas.tables.columns.utils;
import fkeyUtils = pgadmin.browser.server_groups.servers.databases.schemas.tables.constraints.foreign_key.utils;
import exclusionUtils = pgadmin.browser.server_groups.servers.databases.schemas.tables.constraints.exclusion_constraint.utils;

final class TableModule : SchemaChildModule
{
    enum NODE_TYPE = "table";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "Tables";
        minVer = Value(null);
        maxVer = Value(null);
        staticDir("browser/server_groups/servers/databases/schemas/tables");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => "database";

    override Value[] getNodes(Dict kwargs)
    {
        if (hasNodes(kwargs["sid"], kwargs["did"], kwargs["scid"], Value(null), Value(null), BaseTableView.BASE_TEMPLATE_PATH))
            return [generateBrowserCollectionNode(kwargs["scid"])];
        return null;
    }

    override string[] csssnippets()
    {
        string[] snippets = [
            renderTemplate("browser/css/collection.css", ["node_type": Value(nodeType)]),
            renderTemplate("browser/css/node.css", ["node_type": Value(nodeType)]),
            renderTemplate("browser/css/node.css", ["node_type": Value("table"), "file_name": Value("table-inherited")]),
            renderTemplate("browser/css/node.css", ["node_type": Value("table"), "file_name": Value("table-inherits")]),
            renderTemplate("browser/css/node.css", ["node_type": Value("table"), "file_name": Value("table-multi-inherit")]),
        ];
        foreach (m; submodules)
            if (auto b = cast(BrowserPluginModule) m)
                snippets ~= b.csssnippets;
        return snippets;
    }

    override void setup()
    {
        import pgadmin.browser.server_groups.servers.databases.schemas.tables.registry : registerTableSubmodules;
        registerTableSubmodules(this);
        registerNodeView!TableView(this);
    }
}

class TableView : BaseTableView
{
    this()
    {
        super();
        nodeType = TableModule.NODE_TYPE;
        nodeLabel = "Table";
        parentIds = [IdSpec("int", "gid"), IdSpec("int", "sid"), IdSpec("int", "did"), IdSpec("int", "scid")];
        ids = [IdSpec("int", "tid")];
        setAllOps([
            makeOp("obj", ["get": "properties", "delete": "delete", "put": "update"],
                    ["get": "list", "post": "create", "delete": "delete"]),
            makeOp("delete", ["delete": "delete"], ["delete": "delete"]),
            makeOp("children", ["get": "children"]),
            makeOp("nodes", ["get": "node"], ["get": "nodes"]),
            makeOp("sql", ["get": "sql"]),
            makeOp("msql", ["get": "msql"], ["get": "msql"]),
            makeOp("stats", ["get": "statistics"], ["get": "statistics"]),
            makeOp("dependency", ["get": "dependencies"]),
            makeOp("dependent", ["get": "dependents"]),
            makeOp("get_oftype", ["get": "get_oftype"], ["get": "get_oftype"]),
            makeOp("get_inherits", ["get": "get_inherits"], ["get": "get_inherits"]),
            makeOp("get_relations", ["get": "get_relations"], ["get": "get_relations"]),
            makeOp("truncate", ["put": "truncate"]),
            makeOp("reset", ["delete": "reset"]),
            makeOp("set_trigger", ["put": "enable_disable_triggers"]),
            makeOp("get_types", ["get": "types"], ["get": "types"]),
            makeOp("get_columns", ["get": "get_columns"], ["get": "get_columns"]),
            makeOp("get_table_vacuum", null, ["get": "get_table_vacuum"]),
            makeOp("get_toast_table_vacuum", null, ["get": "get_toast_table_vacuum"]),
            makeOp("all_tables", null, ["get": "get_all_tables"]),
            makeOp("get_access_methods", null, ["get": "get_access_methods"]),
            makeOp("get_table_access_methods", null, ["get": "get_table_access_methods"]),
            makeOp("get_oper_class", null, ["get": "get_oper_class"]),
            makeOp("get_operator", null, ["get": "get_operator"]),
            makeOp("get_attach_tables", ["get": "get_attach_tables"], ["get": "get_attach_tables"]),
            makeOp("select_sql", ["get": "select_sql"]),
            makeOp("insert_sql", ["get": "insert_sql"]),
            makeOp("update_sql", ["get": "update_sql"]),
            makeOp("delete_sql", ["get": "delete_sql"]),
            makeOp("count_rows", ["get": "count_rows"]),
            makeOp("compare", ["get": "compare"], ["get": "compare"]),
            makeOp("get_op_class", ["get": "get_op_class"], ["get": "get_op_class"]),
            makeOp("get_geometry_types", ["get": "geometry_types"], ["get": "geometry_types"]),
        ]);
    }

    override string getIconCssClass(Value tableInfo, string defaultVal = "icon-table")
    {
        bool isInherits = (tableInfo.contains("is_inherits") && tableInfo["is_inherits"].toString > "0")
            || (tableInfo.contains("coll_inherits") && tableInfo["coll_inherits"].length > 0);
        bool isInherited = (tableInfo.contains("is_inherited") && tableInfo["is_inherited"].toString > "0")
            || (tableInfo.contains("relhassubclass") && tableInfo["relhassubclass"].truthy);
        if (isInherits)
            defaultVal = isInherited ? "icon-table-multi-inherit" : "icon-table-inherits";
        else if (isInherited)
            defaultVal = "icon-table-inherited";
        return super.getIconCssClass(tableInfo, defaultVal);
    }

    override Response callMethod(string name, Dict k)
    {
        if (!isAuthenticated())
            return unauthorisedResponse();
        if (name == "children")
            return children(k);
        auto err = tablePrecondition(k);
        if (err !is null)
            return err;
        auto gid = k.has("gid") ? k["gid"] : Value(null);
        auto sid = k["sid"];
        auto did = k["did"];
        auto scid = k.has("scid") ? k["scid"] : Value(null);
        auto tid = k.has("tid") ? k["tid"] : Value(null);
        switch (name)
        {
        case "list":
        {
            auto r = conn.executeDict(tt(PROPERTIES_SQL, tv("did", did, "scid", scid, "datlastsysoid", DATABASE_LAST_SYSTEM_OID_)));
            if (!r.ok)
                return internalServerError(r.error);
            return makeResponse(r.value["rows"], 200);
        }
        case "node": return node(scid, tid);
        case "nodes": return nodes(scid);
        case "get_all_tables":
        {
            try
            {
                auto r = conn.executeDict(tt("get_tables_for_constraints.sql", tv("show_sysobj", bpModule.showSystemObjectsFlag)));
                if (!r.ok)
                    return internalServerError(r.error);
                return makeJsonResponse(1, Value(""), Value(""), Value(null), r.value["rows"], 200);
            }
            catch (HTTPException e)
                throw e;
            catch (Exception e)
                return internalServerError(e.msg);
        }
        case "get_table_vacuum":
            return makeResponse(fetchDefaultVacuumSettings(conn, sid.integer, "table"), 200);
        case "get_toast_table_vacuum":
            return makeResponse(fetchDefaultVacuumSettings(conn, sid.integer, "toast"), 200);
        case "get_access_methods":
            return makeJsonResponse(1, Value(""), Value(""), Value(null), exclusionUtils.getAccessMethods(conn), 200);
        case "get_table_access_methods":
            return makeJsonResponse(1, Value(""), Value(""), Value(null), getAccessMethods(), 200);
        case "get_oper_class":
        {
            auto data = request().args;
            try
            {
                if (!data.empty && data.has("indextype"))
                    return makeJsonResponse(1, Value(""), Value(""), Value(null),
                            exclusionUtils.getOperClass(conn, Value(data.get("indextype"))), 200);
                throw new ViewReturnedNone;
            }
            catch (ViewReturnedNone e)
                throw e;
            catch (HTTPException e)
                throw e;
            catch (Exception e)
                return internalServerError(e.msg);
        }
        case "get_operator":
        {
            try
            {
                auto ct = request().args.has("col_type") ? Value(request().args.get("col_type")) : Value(null);
                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                        exclusionUtils.getOperator(conn, ct, bpModule.showSystemObjectsFlag), 200);
            }
            catch (HTTPException e)
                throw e;
            catch (Exception e)
                return internalServerError(e.msg);
        }
        case "properties":
        {
            Response e2;
            auto res = fetchTableProperties(did, scid, tid, e2);
            if (e2 !is null)
                return e2;
            if (res["rows"].length == 0)
                return gone(gettext(notFoundErrorMsg()));
            return makeResponse(baseProperties(gid, sid, did, scid, tid, res), 200);
        }
        case "get_op_class":
        {
            try
            {
                auto r = conn.execute2darray(tt("get_op_class.sql"));
                if (!r.ok)
                    return internalServerError("{}");
                Value[] list;
                foreach (row; r.value["rows"].list.items)
                    list ~= Value.dictOf("label", row["opcname"], "value", row["opcname"]);
                return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(list), 200);
            }
            catch (HTTPException e)
                throw e;
            catch (Exception e)
                return internalServerError(e.msg);
        }
        case "types":
        {
            auto condition = getTypesConditionSql(bpModule.showSystemObjectsFlag);
            auto r = DataTypeReader.getTypes(conn, condition, true, sid);
            if (!r.ok)
                return internalServerError(r.error);
            return makeJsonResponse(1, Value(""), Value(""), Value(null), r.value, 200);
        }
        case "geometry_types":
        {
            auto r = DataTypeReader.getGeometryTypes(conn);
            if (!r.ok)
                return internalServerError(r.error);
            return makeJsonResponse(1, Value(""), Value(""), Value(null), r.value, 200);
        }
        case "get_columns": return getColumns();
        case "get_oftype": return getOftype(scid);
        case "get_inherits": return getInherits(scid, tid);
        case "get_attach_tables": return getAttachTables(tid);
        case "get_relations": return getRelations();
        case "create": return create(scid);
        case "update": return update(gid, sid, did, scid, tid);
        case "delete": return delete_(gid, sid, did, scid, tid);
        case "truncate":
        {
            try
            {
                auto r = conn.executeDict(tt(PROPERTIES_SQL, tv("did", did, "scid", scid, "tid", tid,
                        "datlastsysoid", DATABASE_LAST_SYSTEM_OID_)));
                if (!r.ok)
                    return internalServerError(r.error);
                if (r.value["rows"].length == 0)
                    return gone(gettext(notFoundErrorMsg()));
                return baseTruncate(gid, sid, did, scid, tid, r.value);
            }
            catch (HTTPException e)
                throw e;
            catch (Exception e)
                return internalServerError(e.msg);
        }
        case "enable_disable_triggers": return enableDisableTriggers(did, scid, tid);
        case "reset": return resetStatistics(scid, tid);
        case "msql":
        {
            auto data = Value.newDict();
            foreach (key; request().args.keys)
            {
                auto v = request().args.get(key);
                data[key] = key == "description" ? Value(v) : tryParseJson(v, Value(v));
            }
            return fetchSql(did, scid, tid, data);
        }
        case "dependents": return getTableDependents(tid);
        case "dependencies": return getTableDependencies(tid);
        case "sql": return sqlView(did, scid, tid);
        case "select_sql": return selectSql(did, scid, tid);
        case "insert_sql": return insertSql(did, scid, tid);
        case "update_sql": return updateSql(did, scid, tid);
        case "delete_sql": return deleteSql(did, scid, tid);
        case "statistics": return getTableStatistics(scid, tid);
        case "count_rows":
        {
            string schemaName, tableName;
            getSchemaAndTableName(tid, schemaName, tableName);
            if (tableName is null)
                return gone(gettext(notFoundErrorMsg()));
            auto data = Value.dictOf("schema", schemaName, "name", tableName);
            auto c = conn.executeScalar(tt("get_table_row_count.sql", tv("data", data)));
            if (!c.ok)
                return internalServerError(c.error);
            return makeJsonResponse(1, Value(""), Value(gettext("Table rows counted: {}").replace("{}", c.value.toString)),
                    Value(null), Value.dictOf("total_rows", c.value), 200);
        }
        default: return super.callMethod(name, k);
        }
    }

    private Response node(Value scid, Value tid)
    {
        auto r = conn.execute2darray(tt(NODES_SQL, tv("scid", scid, "tid", tid)));
        if (!r.ok)
            return internalServerError(r.error);
        if (r.value["rows"].length == 0)
            return gone(gettext("Could not find the table."));
        auto info = r.value["rows"][0];
        auto extra = kwDict("tigger_count", info["triggercount"], "has_enable_triggers", info["has_enable_triggers"],
                "is_partitioned", isTablePartitioned(info));
        return makeJsonResponse(1, Value(""), Value(""), Value(null),
                gbn(info["oid"], scid, info["name"].toString, getIconCssClass(info), extra), 200);
    }

    private Response nodes(Value scid)
    {
        auto r = conn.execute2darray(tt(NODES_SQL, tv("scid", scid)));
        if (!r.ok)
            return internalServerError(r.error);
        Value[] res;
        foreach (row; r.value["rows"].list.items)
            res ~= gbn(row["oid"], scid, row["name"].toString, getIconCssClass(row),
                    kwDict("tigger_count", row["triggercount"], "has_enable_triggers", row["has_enable_triggers"],
                    "is_partitioned", isTablePartitioned(row), "description", row["description"]));
        return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
    }

    private Response getColumns()
    {
        Value res = Value.newList();
        auto data = request().args;
        try
        {
            string sql;
            if (!data.empty && data.has("tid"))
                sql = tt(GET_COLUMNS_FOR_TABLE_SQL, tv("tid", data.get("tid"), "conn", conn));
            else if (!data.empty && data.has("tname"))
                sql = tt(GET_COLUMNS_FOR_TABLE_SQL, tv("tname", data.get("tname"), "conn", conn));
            else
                throw new Exception("cannot access local variable 'SQL' where it is not associated with a value");
            if (sql.length)
            {
                auto r = conn.executeDict(sql);
                if (!r.ok)
                    return internalServerError(r.error);
                res = r.value["rows"];
            }
            return makeJsonResponse(1, Value(""), Value(""), Value(null), res, 200);
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response getOftype(Value scid)
    {
        Value[] res;
        try
        {
            auto r = conn.execute2darray(tt("get_oftype.sql", tv("scid", scid, "server_type", manager.serverType,
                    "show_sys_objects", bpModule.showSystemObjectsFlag)));
            if (!r.ok)
                return internalServerError("[]");
            foreach (row; r.value["rows"].list.items)
            {
                auto c = conn.executeDict(tt(GET_COLUMNS_FOR_TABLE_SQL, tv("tid", row["oid"], "conn", conn)));
                if (!c.ok)
                    return internalServerError(c.error);
                foreach (col; c.value["rows"].list.items)
                {
                    if (col.contains("inheritedfrom"))
                        col["inheritedfromtype"] = col["inheritedfrom"];
                    col["original_defval"] = col.dict.get("defval", Value(null));
                    col["original_attnotnull"] = col.dict.get("attnotnull", Value(false));
                }
                res ~= Value.dictOf("label", row["typname"], "value", row["typname"], "tid", row["oid"],
                        "oftype_columns", c.value["rows"]);
            }
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response getInherits(Value scid, Value tid)
    {
        try
        {
            auto r = conn.execute2darray(tt("get_inherits.sql", tv("show_system_objects", bpModule.showSystemObjectsFlag,
                    "tid", tid, "scid", scid, "server_type", manager.serverType)));
            if (!r.ok)
                return internalServerError("[]");
            Value[] res;
            foreach (row; r.value["rows"].list.items)
                res ~= Value.dictOf("label", row["inherits"], "value", row["inherits"], "tid", row["oid"]);
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response getAttachTables(Value tid)
    {
        try
        {
            auto r = conn.execute2darray(renderTemplate(partitionTemplatePath ~ "/get_attach_tables.sql", tv("tid", tid)));
            if (!r.ok)
                return internalServerError("[]");
            Value[] res;
            foreach (row; r.value["rows"].list.items)
                res ~= Value.dictOf("label", row["table_name"], "value", row["oid"]);
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response getRelations()
    {
        try
        {
            auto r = conn.execute2darray(tt("get_relations.sql", tv("show_sys_objects", bpModule.showSystemObjectsFlag,
                    "server_type", manager.serverType)));
            if (!r.ok)
                return internalServerError("[]");
            Value[] res;
            foreach (row; r.value["rows"].list.items)
                res ~= Value.dictOf("label", row["like_relation"], "value", row["like_relation"]);
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private static Value jsonLoadValues(Value data)
    {
        foreach (k, v; data.dict)
        {
            if (k == "description")
                continue;
            if (v.isString)
                data[k] = tryParseJson(v.str, v);
        }
        return data;
    }

    private void parserDataInputFromClient(Value data)
    {
        if (data.contains("relacl"))
            data["relacl"] = parsePrivToDb(data["relacl"], acl);
        data = columnUtils.parseFormatColumns(data);
        data = checkAndConvertNameToString(data);
        if (data.contains("coll_inherits") && data["coll_inherits"].isString)
            data["coll_inherits"] = parseJson(data["coll_inherits"].str);
        if (data.contains("foreign_key"))
            foreach (c; data["foreign_key"].iterItems())
            {
                string schema, table;
                fkeyUtils.getParent(conn, c["columns"][0]["references"], schema, table);
                c["remote_schema"] = Value(schema);
                c["remote_table"] = Value(table);
            }
    }

    private Response create(Value scid)
    {
        auto data = jsonLoadValues(formOrJson(request()));
        auto miss = missingArg(data, ["name"]);
        if (miss !is null)
            return miss;
        parserDataInputFromClient(data);
        try
        {
            string partitionsSql;
            if (isTablePartitioned(data))
            {
                data["relkind"] = Value("p");
                data["partition_scheme"] = Value(getPartitionScheme(data));
                partitionsSql = getPartitionsSql(data);
            }
            updateVacuumSettings("vacuum_table", data);
            updateVacuumSettings("vacuum_toast", data);
            auto sql = tt(CREATE_SQL, tv("data", data, "conn", conn));
            sql ~= "\n" ~ partitionsSql;
            auto x = conn.executeScalar(sql);
            if (!x.ok)
                return internalServerError(x.error);
            enum CONST_MAX_CHAR_COUNT = 63;
            if (data["name"].toString.length > CONST_MAX_CHAR_COUNT)
                data["name"] = Value(data["name"].toString[0 .. CONST_MAX_CHAR_COUNT]);
            auto s = conn.executeScalar(tt(GET_SCHEMA_OID_SQL, tv("tname", data["name"], "sname", data["schema"], "conn", conn)));
            if (!s.ok)
                return internalServerError(s.error);
            auto t = conn.executeScalar(tt(OID_SQL, tv("scid", s.value, "data", data, "conn", conn)));
            if (!t.ok)
                return internalServerError(t.error);
            return jsonify(Value.dictOf("node", gbn(t.value, s.value, data["name"].toString, getIconCssClass(data),
                    kwDict("is_partitioned", isTablePartitioned(data)))));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response update(Value gid, Value sid, Value did, Value scid, Value tid)
    {
        auto data = jsonLoadValues(formOrJson(request()));
        try
        {
            Response e2;
            auto res = fetchTableProperties(did, scid, tid, e2);
            if (e2 !is null)
                return e2;
            auto lock = getTableLocks(did, res["rows"][0]);
            if (lock !is null)
                throw new ViewReturnedNone; // Python returns an ExecuteError object here, which Flask rejects
            return baseUpdate(gid, sid, did, scid, tid, data, res);
        }
        catch (HTTPException e)
            throw e;
        catch (ViewReturnedNone e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response delete_(Value gid, Value sid, Value did, Value scid, Value tidArg)
    {
        Value data = tidArg.isNone ? formOrJson(request()) : Value.dictOf("ids", Value([tidArg]));
        try
        {
            foreach (tid; data["ids"].iterItems())
            {
                auto r = conn.executeDict(tt(PROPERTIES_SQL, tv("did", did, "scid", scid, "tid", tid,
                        "datlastsysoid", DATABASE_LAST_SYSTEM_OID_)));
                if (!r.ok)
                    return internalServerError(r.error);
                if (r.value["rows"].length == 0)
                    return makeJsonResponse(0, Value(gettext("Error: Object not found.")),
                            Value(gettext(notFoundErrorMsg() ~ "\n")));
                auto lock = getTableLocks(did, r.value["rows"][0]);
                if (lock !is null)
                    return lock;
                auto err = baseDelete(r.value);
                if (err !is null)
                    return internalServerError(err);
            }
            return makeJsonResponse(1, Value(""), Value(gettext("Table dropped")));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response enableDisableTriggers(Value did, Value scid, Value tid)
    {
        auto data = formOrJson(request());
        auto isEnableTrigger = data["is_enable_trigger"];
        try
        {
            auto r = conn.executeDict(tt(PROPERTIES_SQL, tv("did", did, "scid", scid, "tid", tid,
                    "datlastsysoid", DATABASE_LAST_SYSTEM_OID_)));
            if (!r.ok)
                return internalServerError(r.error);
            auto row = r.value["rows"][0];
            auto x = conn.executeScalar(tt("enable_disable_trigger.sql", tv("data", row, "is_enable_trigger", isEnableTrigger)));
            if (!x.ok)
                return internalServerError(x.error);
            auto t = conn.executeScalar(renderTemplate(triggerTemplatePath ~ "/get_enabled_triggers.sql", tv("tid", tid)));
            if (!t.ok)
                return internalServerError(t.error);
            return makeJsonResponse(1, Value(""), Value(isEnableTrigger == Value("D")
                    ? gettext("Trigger(s) have been disabled") : gettext("Trigger(s) have been enabled")), Value(null),
                    Value.dictOf("id", tid, "scid", scid, "has_enable_triggers", t.value), 200);
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response fetchSql(Value did, Value scid, Value tid, Value data, bool jsonResp = true)
    {
        Value res = Value(null);
        if (!tid.isNone)
        {
            Response err;
            res = fetchTableProperties(did, scid, tid, err);
            if (err !is null)
                return err;
        }
        string name;
        auto sql = getSql(did, scid, tid, data, res, name);
        sql = replaceAll(sql, regex(pattern), doubleNewline);
        sql = sql.strip("\n");
        if (!jsonResp)
            return Response.sqlOnly(sql);
        if (sql == "")
            sql = "--modified SQL";
        return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(sql), 200);
    }

    private Response sqlView(Value did, Value scid, Value tid)
    {
        string[] mainSql;
        Response err;
        auto res = fetchTableProperties(did, scid, tid, err);
        if (err !is null)
            return err;
        if (res["rows"].length == 0)
            return gone(gettext(notFoundErrorMsg()));
        auto data = res["rows"][0];
        string sqlOut;
        return getReverseEngineeredSql(did, scid, tid, mainSql, data, true, false, true, sqlOut);
    }

    private Value tablePropertiesRow(Value did, Value scid, Value tid, out Response err)
    {
        auto r = conn.executeDict(tt(PROPERTIES_SQL, tv("did", did, "scid", scid, "tid", tid,
                "datlastsysoid", DATABASE_LAST_SYSTEM_OID_)));
        if (!r.ok)
        {
            err = internalServerError(r.error);
            return Value(null);
        }
        if (r.value["rows"].length == 0)
        {
            err = gone(gettext(notFoundErrorMsg()));
            return Value(null);
        }
        return r.value["rows"][0];
    }

    private Response selectSql(Value did, Value scid, Value tid)
    {
        Response err;
        auto data = tablePropertiesRow(did, scid, tid, err);
        if (err !is null)
            return err;
        data = formatter(did, scid, tid, data);
        string[] columns;
        if (data.contains("columns"))
            foreach (c; data["columns"].iterItems())
                columns ~= qtIdentStr(c["name"].toString);
        auto cols = columns.length ? columns.join(", ") : "*";
        auto sql = "SELECT " ~ cols ~ "\n\tFROM " ~ qtIdentStr(data["schema"].toString, data["name"].toString) ~ ";";
        return makeResponse(Value(sql));
    }

    private Response insertSql(Value did, Value scid, Value tid)
    {
        Response err;
        auto data = tablePropertiesRow(did, scid, tid, err);
        if (err !is null)
            return err;
        data = formatter(did, scid, tid, data);
        string[] columns, values;
        if (data.contains("columns"))
            foreach (c; data["columns"].iterItems())
            {
                columns ~= qtIdentStr(c["name"].toString);
                values ~= "?";
            }
        string sql;
        if (columns.length)
            sql = "INSERT INTO " ~ qtIdentStr(data["schema"].toString, data["name"].toString) ~ "(\n\t" ~ columns.join(", ")
                ~ ")\n\tVALUES (" ~ values.join(", ") ~ ");";
        else
            sql = gettext("-- Please create column(s) first...");
        return makeResponse(Value(sql));
    }

    private Response updateSql(Value did, Value scid, Value tid)
    {
        auto r = conn.executeDict(tt(PROPERTIES_SQL, tv("did", did, "scid", scid, "tid", tid,
                "datlastsysoid", DATABASE_LAST_SYSTEM_OID_, "conn", conn)));
        if (!r.ok)
            return internalServerError(r.error);
        if (r.value["rows"].length == 0)
            return gone(gettext(notFoundErrorMsg()));
        auto data = formatter(did, scid, tid, r.value["rows"][0]);
        string[] columns;
        if (data.contains("columns"))
            foreach (c; data["columns"].iterItems())
                columns ~= qtIdentStr(c["name"].toString);
        string sql;
        if (columns.length)
        {
            auto cols = columns.length == 1 ? columns[0] : columns.join("=?, ");
            cols ~= "=?";
            sql = "UPDATE " ~ qtIdentStr(data["schema"].toString, data["name"].toString) ~ "\n\tSET " ~ cols
                ~ "\n\tWHERE <condition>;";
        }
        else
            sql = gettext("-- Please create column(s) first...");
        return makeResponse(Value(sql));
    }

    Response deleteSql(Value did, Value scid, Value tid, bool jsonResp = true)
    {
        Response err;
        auto data = tablePropertiesRow(did, scid, tid, err);
        if (err !is null)
            return err;
        auto sql = "DELETE FROM " ~ qtIdentStr(data["schema"].toString, data["name"].toString) ~ "\n\tWHERE <condition>;";
        if (!jsonResp)
            return Response.sqlOnly(sql);
        return makeResponse(Value(sql));
    }
}
