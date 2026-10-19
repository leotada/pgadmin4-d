/// `schemas/foreign_tables`: foreign tables.
module pgadmin.browser.server_groups.servers.databases.schemas.foreign_tables;

import std.regex : regex, replaceAll;
import pgadmin.browser.common;
import pgadmin.browser.server_groups.servers.databases.schemas.utils;
import pgadmin.browser.server_groups.servers.databases.schemas.tables.utils;
import pgadmin.browser.server_groups.servers.databases.schemas.tables.columns : ForeignTableColumnsModule;
import pgadmin.browser.server_groups.servers.databases.schemas.tables.constraints : ConstraintsModule;
import pgadmin.browser.server_groups.servers.databases.schemas.tables.triggers : TriggerModule;
import pgadmin.browser.server_groups.servers.databases.utils : parseSecLabelsFromDb;
import columnUtils = pgadmin.browser.server_groups.servers.databases.schemas.tables.columns.utils;
import triggerUtils = pgadmin.browser.server_groups.servers.databases.schemas.tables.triggers.utils;

final class ForeignTableModule : SchemaChildModule
{
    enum NODE_TYPE = "foreign_table";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "Foreign Tables";
        minVer = Value(null);
        maxVer = Value(null);
        staticDir("browser/server_groups/servers/databases/schemas/foreign_tables");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => "database";

    override Value[] getNodes(Dict kwargs)
    {
        if (hasNodes(kwargs["sid"], kwargs["did"], kwargs["scid"], Value(null), Value(null), ForeignTableView.BASE_TEMPLATE_PATH))
            return [generateBrowserCollectionNode(kwargs["scid"])];
        return null;
    }

    override void setup()
    {
        submodules ~= sharedModule!TriggerModule();
        submodules ~= sharedModule!ConstraintsModule();
        submodules ~= sharedModule!ForeignTableColumnsModule();
        registerNodeView!ForeignTableView(this);
    }
}

final class ForeignTableView : BaseTableView
{
    enum BASE_FT_TEMPLATE_PATH = "foreign_tables/sql/#{0}#";
    alias BASE_TEMPLATE_PATH = BASE_FT_TEMPLATE_PATH;

    string foreignTableColumnTemplatePath;
    string[] allowedPrivileges;
    private Value req_;

    this()
    {
        super();
        nodeType = ForeignTableModule.NODE_TYPE;
        nodeLabel = "Foreign Table";
        parentIds = [IdSpec("int", "gid"), IdSpec("int", "sid"), IdSpec("int", "did"), IdSpec("int", "scid")];
        ids = [IdSpec("int", "foid")];
        setAllOps([
            makeOp("obj", ["get": "properties", "delete": "delete", "put": "update"],
                    ["get": "list", "post": "create", "delete": "delete"]),
            makeOp("delete", ["delete": "delete"], ["delete": "delete"]),
            makeOp("truncate", ["put": "truncate"]),
            makeOp("children", ["get": "children"]),
            makeOp("nodes", ["get": "node"], ["get": "nodes"]),
            makeOp("sql", ["get": "sql"]),
            makeOp("msql", ["get": "msql"], ["get": "msql"]),
            makeOp("stats", ["get": "statistics"]),
            makeOp("dependency", ["get": "dependencies"]),
            makeOp("dependent", ["get": "dependents"]),
            makeOp("get_collations", ["get": "get_collations"], ["get": "get_collations"]),
            makeOp("get_types", ["get": "types"], ["get": "types"]),
            makeOp("get_foreign_servers", ["get": "get_foreign_servers"], ["get": "get_foreign_servers"]),
            makeOp("get_tables", ["get": "get_tables"], ["get": "get_tables"]),
            makeOp("set_trigger", ["put": "enable_disable_triggers"]),
            makeOp("get_columns", ["get": "get_columns"], ["get": "get_columns"]),
            makeOp("select_sql", ["get": "select_sql"]),
            makeOp("insert_sql", ["get": "insert_sql"]),
            makeOp("update_sql", ["get": "update_sql"]),
            makeOp("delete_sql", ["get": "delete_sql"]),
            makeOp("compare", ["get": "compare"], ["get": "compare"]),
        ]);
    }

    /// The foreign table precondition (not `BaseTableView.check_precondition`).
    private Response ftPrecondition(Dict k)
    {
        manager = getDriver().connectionManagerOrNull(k["sid"].integer);
        if (manager is null)
            return gone(gettext("Could not find the server."));
        conn = manager.connection(null, null, true, k["did"]);
        datistemplate = false;
        if (manager.dbInfo !is null && manager.dbInfo.has(k["did"].toString))
            datistemplate = manager.dbInfo[k["did"].toString]["datistemplate"].truthy;
        immutable ver = to!string(manager.version_);
        templatePath = BASE_FT_TEMPLATE_PATH.replace("{0}", ver);
        tableTemplatePath = "tables/sql/#" ~ ver ~ "#";
        foreignTableColumnTemplatePath = "foreign_table_columns/sql/#" ~ ver ~ "#";
        columnTemplatePath = "columns/sql/#" ~ ver ~ "#";
        triggerTemplatePath = "triggers/sql/" ~ manager.serverType ~ "/#" ~ ver ~ "#";
        allowedPrivileges = ["a", "r", "w", "d", "D", "x", "t"];
        if (manager.version_ >= 170000)
            allowedPrivileges = ["a", "r", "w", "d", "D", "x", "t", "m"];
        return null;
    }

    // ---------------------------------------------------------------- request validation

    private Response validateRequest(Dict k)
    {
        auto req = argsOrJson();
        if (!k.has("foid"))
            foreach (arg; ["name", "ftsrvname"])
                if (!req.contains(arg) || req[arg] == Value(""))
                    return makeJsonResponse(0, Value(gettext("Could not find the required parameter ({}).").replace("{}", arg)),
                            Value(""), Value(null), Value(null), 410);
        try
        {
            string[] listParams = request().method == "GET"
                ? ["constraints", "columns", "ftoptions", "seclabels", "inherits", "acl"] : ["inherits"];
            auto data = Value.newDict();
            foreach (key, v; req.dict)
            {
                if (listParams.canFind(key) && v != Value("") && !v.isNone)
                {
                    data[key] = Value.newList();
                    if (!v.isList && v.truthy)
                        data[key] = parseJson(v.toString);
                    else if (v.truthy)
                        data[key] = v;
                    if (key == "inherits")
                    {
                        string[] ids;
                        foreach (x; data[key].iterItems())
                            ids ~= to!string(pyInt(x));
                        if (ids.length)
                        {
                            auto attrelid = "(" ~ ids.join(", ") ~ ")";
                            if (ids.length == 1)
                                attrelid = "(" ~ ids[0] ~ ")";
                            auto r = conn.executeDict(rt(GET_TABLES_SQL, tv("attrelid", attrelid)));
                            if (!r.ok)
                                return internalServerError(r.error);
                            data[key] = r.value["rows"][0].contains("inherits") ? r.value["rows"][0]["inherits"] : Value.newList();
                        }
                    }
                }
                else if (key == "typnotnull")
                {
                    if (v == Value("true") || (v.type == VType.boolean && v.boolean))
                        data[key] = Value(true);
                    else if (v == Value("false") || (v.type == VType.boolean && !v.boolean))
                        data[key] = Value(false);
                    else
                        data[key] = Value("");
                }
                else
                    data[key] = v;
            }
            req_ = data;
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
        {
            logException(e);
            return internalServerError(e.msg);
        }
        return null;
    }

    override Response callMethod(string name, Dict k)
    {
        if (!isAuthenticated())
            return unauthorisedResponse();
        if (name == "children")
            return children(k);
        auto err = ftPrecondition(k);
        if (err !is null)
            return err;
        auto gid = k.has("gid") ? k["gid"] : Value(null);
        auto sid = k["sid"];
        auto did = k["did"];
        auto scid = k["scid"];
        auto foid = k.has("foid") ? k["foid"] : Value(null);
        if (name == "create" || name == "update" || name == "msql")
        {
            auto ve = validateRequest(k);
            if (ve !is null)
                return ve;
        }
        switch (name)
        {
        case "list":
        {
            auto r = conn.executeDict(rt(NODE_SQL, tv("scid", scid)));
            if (!r.ok)
                return internalServerError(r.error);
            return makeResponse(r.value["rows"], 200);
        }
        case "nodes":
        {
            auto r = conn.execute2darray(rt(NODE_SQL, tv("scid", scid)));
            if (!r.ok)
                return internalServerError(r.error);
            Value[] res;
            foreach (row; r.value["rows"].list.items)
                res ~= gbn(row["oid"], scid, row["name"].toString, "icon-foreign_table",
                        kwDict("description", row["description"], "tigger_count", row["triggercount"],
                        "has_enable_triggers", row["has_enable_triggers"]));
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        case "node":
        {
            auto r = conn.execute2darray(rt(NODE_SQL, tv("foid", foid)));
            if (!r.ok)
                return internalServerError(r.error);
            foreach (row; r.value["rows"].list.items)
                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                        gbn(row["oid"], scid, row["name"].toString, "icon-foreign_table"), 200);
            return gone(notFoundErrorMsg());
        }
        case "properties":
        {
            Response e2;
            bool found;
            auto data = fetchProperties(gid, sid, did, scid, foid, false, found, e2);
            if (e2 !is null)
                return e2;
            if (!found)
                return gone(notFoundErrorMsg());
            return makeResponse(data, 200);
        }
        case "get_collations":
        {
            Value[] res = [Value.dictOf("label", "", "value", "")];
            try
            {
                auto r = conn.execute2darray(rt("get_collations.sql"));
                if (!r.ok)
                    return internalServerError(Value(res).toString);
                foreach (row; r.value["rows"].list.items)
                    res ~= Value.dictOf("label", row["copy_collation"], "value", row["copy_collation"]);
                return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
            }
            catch (HTTPException e)
                throw e;
            catch (Exception e)
                return internalServerError(e.msg);
        }
        case "types":
        {
            auto condition = rt("types_condition.sql", tv("server_type", manager.serverType,
                    "show_sys_objects", bpModule.showSystemObjectsFlag));
            auto r = DataTypeReader.getTypes(conn, condition);
            if (!r.ok)
                return internalServerError(r.error);
            return makeJsonResponse(1, Value(""), Value(""), Value(null), r.value, 200);
        }
        case "get_foreign_servers":
        {
            Value[] res = [Value.dictOf("label", "", "value", "")];
            try
            {
                auto r = conn.execute2darray(rt("get_foreign_servers.sql"));
                if (!r.ok)
                    return internalServerError(Value(res).toString);
                foreach (row; r.value["rows"].list.items)
                    res ~= Value.dictOf("label", row["srvname"], "value", row["srvname"]);
                return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
            }
            catch (HTTPException e)
                throw e;
            catch (Exception e)
                return internalServerError(e.msg);
        }
        case "get_tables":
        {
            try
            {
                auto r = conn.executeDict(rt(GET_TABLES_SQL, tv("foid", foid, "server_type", manager.serverType,
                        "show_sys_objects", bpModule.showSystemObjectsFlag)));
                if (!r.ok)
                    return internalServerError("[]");
                return makeJsonResponse(1, Value(""), Value(""), Value(null), r.value["rows"], 200);
            }
            catch (HTTPException e)
                throw e;
            catch (Exception e)
                return internalServerError(e.msg);
        }
        case "get_columns":
        {
            auto data = request().args;
            try
            {
                if (!data.empty && data.has("attrelid"))
                {
                    auto r = conn.executeDict(rt("get_table_columns.sql", tv("attrelid", data.get("attrelid"))));
                    if (!r.ok)
                        return internalServerError(r.error);
                    return makeJsonResponse(1, Value(""), Value(""), Value(null), r.value["rows"], 200);
                }
                throw new ViewReturnedNone;
            }
            catch (ViewReturnedNone e)
                throw e;
            catch (HTTPException e)
                throw e;
            catch (Exception e)
                return internalServerError(e.msg);
        }
        case "create": return create(gid, sid, did, scid);
        case "delete": return delete_(scid, foid);
        case "update": return update(gid, sid, did, scid, foid);
        case "truncate":
        {
            try
            {
                auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("did", did, "scid", scid, "foid", foid,
                        "datlastsysoid", DATABASE_LAST_SYSTEM_OID_)));
                if (!r.ok)
                    return internalServerError(r.error);
                if (r.value["rows"].length == 0)
                    return gone(gettext(notFoundErrorMsg()));
                return baseTruncate(gid, sid, did, scid, foid, r.value);
            }
            catch (HTTPException e)
                throw e;
            catch (Exception e)
                return internalServerError(e.msg);
        }
        case "sql": return sqlView(gid, sid, did, scid, foid);
        case "msql": return msql(gid, sid, did, scid, foid);
        case "dependents": return makeResponse(getDependents(conn, foid), 200);
        case "dependencies": return makeResponse(getDependencies(conn, foid), 200);
        case "select_sql": return selectSql(gid, sid, did, scid, foid);
        case "insert_sql": return insertSql(gid, sid, did, scid, foid);
        case "update_sql": return updateSql(gid, sid, did, scid, foid);
        case "delete_sql": return deleteSql(gid, sid, did, scid, foid);
        case "enable_disable_triggers": return enableDisableTriggers(gid, sid, did, scid, foid);
        default: return super.callMethod(name, k);
        }
    }

    // ---------------------------------------------------------------- properties

    private static Value formatProaclFromDb(Value proacl)
    {
        Value[] privileges;
        foreach (row; proacl.iterItems())
            privileges ~= parsePrivFromDb(row);
        return Value.dictOf("relacl", Value(privileges));
    }

    private static Dict parseVariablesFromDbFt(Value dbVariables)
    {
        Value[] lst;
        if (!dbVariables.isNone)
            foreach (row; dbVariables.iterItems())
            {
                auto s = row.toString;
                auto idx = s.indexOf("=");
                if (idx < 0)
                    throw new Exception("not enough values to unpack (expected 2, got 1)");
                lst ~= Value.dictOf("option", s[0 .. idx], "value", s[idx + 1 .. $]);
            }
        return kwDict("ftoptions", Value(lst));
    }

    private void getEditTypes(Value cols)
    {
        List[string] editTypes;
        string[] keys;
        foreach (col; cols.iterItems())
        {
            auto key = col["atttypid"].toString;
            if (!(key in editTypes))
                keys ~= key;
            editTypes[key] = new List;
        }
        if (cols.length > 0)
        {
            auto r = conn.execute2darray(rt("edit_mode_types_multi.sql", tv("type_ids", keys.join(","))));
            foreach (row; r.value["rows"].list.items)
            {
                auto sorted = row["edit_types"].list.items.dup;
                sorted.sort!((x, y) => x.toString < y.toString);
                auto l = new List;
                l.items = sorted;
                editTypes[row["main_oid"].toString] = l;
            }
            foreach (column; cols.iterItems())
            {
                auto list = editTypes[column["atttypid"].toString];
                list.items ~= column["cltype"];
                auto sorted = list.items.dup;
                sorted.sort!((x, y) => x.toString < y.toString);
                column["edit_types"] = Value(sorted);
                column["cltype"] = Value(DataTypeReader.parseTypeName(column["cltype"].toString));
            }
        }
    }

    Value fetchProperties(Value gid, Value sid, Value did, Value scid, Value foid, bool inherits, out bool found, out Response err)
    {
        auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("scid", scid, "foid", foid)));
        if (!r.ok)
        {
            err = internalServerError(r.error);
            return Value(null);
        }
        if (r.value["rows"].length == 0)
        {
            found = false;
            return Value(false);
        }
        found = true;
        auto data = r.value["rows"][0];
        data["is_sys_obj"] = Value(data["oid"].integer <= DATABASE_LAST_SYSTEM_OID_ || datistemplate);
        if (manager.version_ >= 90200)
        {
            auto a = conn.executeDict(rt(ACL_SQL, tv("foid", foid)));
            if (!a.ok)
            {
                err = internalServerError(a.error);
                return Value(null);
            }
            data.dict.update(formatProaclFromDb(a.value["rows"]).dict);
        }
        if (data.contains("seclabels"))
            data.dict.update(parseSecLabelsFromDb(data["seclabels"]));
        if (data.contains("ftoptions"))
        {
            data["strftoptions"] = data["ftoptions"];
            data.dict.update(parseVariablesFromDbFt(data["ftoptions"]));
        }
        auto c = conn.executeDict(rt(GET_CONSTRAINTS_SQL, tv("foid", foid)));
        if (!c.ok)
        {
            err = internalServerError(c.error);
            return Value(null);
        }
        if (c.value.truthy && c.value.contains("rows"))
            data["constraints"] = c.value["rows"];
        auto cc = conn.executeDict(rt(GET_COLUMNS_SQL, tv("foid", foid)));
        if (!cc.ok)
        {
            err = internalServerError(cc.error);
            return Value(null);
        }
        foreach (col; cc.value["rows"].list.items)
        {
            columnUtils.fetchLengthPrecision(col);
            if (col.contains("attoptions") && col["attoptions"] != Value(""))
                col["attoptions"] = columnUtils.parseColumnVariables(col["attoptions"]);
            if (col.contains("attfdwoptions") && col["attfdwoptions"] != Value(""))
                col["coloptions"] = columnUtils.parseOptionsForColumn(col["attfdwoptions"]);
        }
        getEditTypes(cc.value["rows"]);
        if (cc.value.contains("rows"))
            data["columns"] = cc.value["rows"];
        if (inherits && data.contains("inherits") && data["inherits"].truthy)
        {
            string[] ids;
            foreach (x; data["inherits"].iterItems())
                ids ~= to!string(pyInt(x));
            auto attrelid = "(" ~ ids.join(", ") ~ ")";
            if (ids.length == 1)
                attrelid = "(" ~ ids[0] ~ ")";
            auto t = conn.executeDict(rt(GET_TABLES_SQL, tv("attrelid", attrelid)));
            if (!t.ok)
            {
                err = internalServerError(t.error);
                return Value(null);
            }
            if (t.value["rows"][0].contains("inherits"))
                data["inherits"] = t.value["rows"][0]["inherits"];
        }
        return data;
    }

    // ---------------------------------------------------------------- create / update / delete

    private Response create(Value gid, Value sid, Value did, Value scid)
    {
        try
        {
            string name;
            Response err;
            auto sql = getFtSql(gid, sid, did, scid, req_, Value(null), name, err);
            if (err !is null)
                return err;
            auto x = conn.executeScalar(sql);
            if (!x.ok)
                return internalServerError(x.error);
            auto basensp = req_.contains("basensp") ? req_["basensp"] : Value(null);
            auto o = conn.execute2darray(rt(OID_SQL, tv("basensp", basensp, "name", req_["name"], "conn", conn)));
            if (!o.ok)
                return internalServerError(o.error);
            auto foid = o.value["rows"][0]["oid"];
            auto newScid = o.value["rows"][0]["scid"];
            return jsonify(Value.dictOf("node", gbn(foid, newScid, req_["name"].toString, "icon-foreign_table")));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    Response delete_(Value scid, Value foidArg, bool onlySql = false)
    {
        Value data = foidArg.isNone ? formOrJson(request()) : Value.dictOf("ids", Value([foidArg]));
        bool cascade = checkCascadeOperation();
        try
        {
            foreach (foid; data["ids"].iterItems())
            {
                auto r = conn.execute2darray(rt(DELETE_SQL, tv("scid", scid, "foid", foid)));
                if (!r.ok)
                    return internalServerError(r.error);
                if (r.value["rows"].length == 0)
                    return makeJsonResponse(0, Value(gettext("Error: Object not found.")), Value(notFoundErrorMsg()));
                auto sql = rt(DELETE_SQL, tv("name", r.value["rows"][0]["name"], "basensp", r.value["rows"][0]["basensp"],
                        "cascade", cascade));
                if (onlySql)
                    return Response.sqlOnly(sql);
                auto x = conn.executeScalar(sql);
                if (!x.ok)
                    return internalServerError(x.error);
            }
            return makeJsonResponse(1, Value(""), Value(gettext("Foreign Table dropped")));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response update(Value gid, Value sid, Value did, Value scid, Value foid)
    {
        try
        {
            string name;
            Response err;
            auto sql = getFtSql(gid, sid, did, scid, req_, foid, name, err);
            if (err !is null)
                return err;
            sql = sql.strip("\n").strip(" ");
            auto x = conn.executeScalar(sql);
            if (!x.ok)
                return internalServerError(x.error);
            auto o = conn.execute2darray(rt(OID_SQL, tv("foid", foid, "conn", conn)));
            if (!o.ok)
                return internalServerError(o.error);
            auto newScid = o.value["rows"][0]["scid"];
            Dict extra;
            if (req_.contains("description"))
                extra = kwDict("description", req_["description"]);
            return jsonify(Value.dictOf("node", gbn(foid, newScid, name, "icon-" ~ nodeType, extra)));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response msql(Value gid, Value sid, Value did, Value scid, Value foid)
    {
        auto data = Value.newDict();
        foreach (k, v; req_.dict)
            data[k] = (k == "description" || !v.isString) ? v : tryParseJson(v.str, v);
        try
        {
            string name;
            Response err;
            auto sql = getFtSql(gid, sid, did, scid, data, foid, name, err);
            if (err !is null)
                return err;
            if (sql == "")
                sql = "--modified SQL";
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(sql), 200);
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    // ---------------------------------------------------------------- SQL generation

    private void parsePrivileges(Value data)
    {
        if (data.contains("relacl"))
            foreach (key; ["added", "changed", "deleted"])
                if (data["relacl"].contains(key))
                    data["relacl"][key] = parsePrivToDb(data["relacl"][key], allowedPrivileges);
    }

    private static void checkOldColOps(Dict oldColFrmtOptions, Value option, Value col)
    {
        auto opt = option["option"].toString;
        if (oldColFrmtOptions.has(opt) && option["value"] != oldColFrmtOptions[opt])
            col["coloptions_updated"]["changed"].append(option);
        else if (!oldColFrmtOptions.has(opt))
            col["coloptions_updated"]["added"].append(option);
        if (oldColFrmtOptions.has(opt))
            oldColFrmtOptions.pop(opt);
    }

    private static void parseColumnOptions(Value data)
    {
        foreach (c; data["columns"]["changed"].iterItems())
        {
            Value oldColOptions = Value.newList();
            if (c.contains("coloptions") && c["coloptions"].truthy)
                oldColOptions = c["coloptions"];
            auto oldColFrmtOptions = new Dict;
            foreach (o; oldColOptions.iterItems())
            {
                auto parts = o.toString.split("=");
                oldColFrmtOptions[parts[0]] = Value(parts[1]);
            }
            c["coloptions_updated"] = Value.dictOf("added", Value.newList(), "changed", Value.newList(), "deleted", Value.newList());
            if (c.contains("coloptions") && c["coloptions"].length > 0)
                foreach (o; c["coloptions"].iterItems())
                    checkOldColOps(oldColFrmtOptions, o, c);
            foreach (o, _; oldColFrmtOptions)
                c["coloptions_updated"]["deleted"].append(Value.dictOf("option", o));
        }
    }

    private Value formatColumns(Value columns)
    {
        Value[] cols;
        foreach (c; columns.iterItems())
            if (c.length > 0 && c.contains("cltype"))
            {
                if (c["cltype"].toString.canFind("[]"))
                {
                    c["cltype"] = Value(c["cltype"].toString.replace("[]", ""));
                    c["isArrayType"] = Value(true);
                }
                else
                    c["isArrayType"] = Value(false);
                cols ~= c;
            }
        return cols.length ? Value(cols) : columns;
    }

    private static void normaliseColumnCollation(Value columns)
    {
        if (!columns.isDict)
            return;
        foreach (action; ["added", "changed"])
            if (columns.contains(action) && columns[action].truthy)
                foreach (column; columns[action].iterItems())
                    if (!column.dict.get("collspcname", Value(null)).truthy && column.dict.get("collname", Value(null)).truthy)
                        column["collspcname"] = column["collname"];
    }

    private string ftCheckForColumnDelete(Value columns, Value data, string columnSql)
    {
        if (columns.contains("deleted"))
            foreach (c; columns["deleted"].iterItems())
            {
                c["schema"] = data["schema"];
                c["table"] = data["name"];
                if (c.dict.get("inheritedfrom", Value(null)).isNone)
                    columnSql ~= renderTemplate(foreignTableColumnTemplatePath ~ "/" ~ DELETE_SQL,
                            tv("data", c, "conn", conn)).strip("\n") ~ doubleNewline;
            }
        return columnSql;
    }

    private string ftCheckForColumnUpdate(Value columns, Value data, string columnSql, Value tid)
    {
        if (!columns.contains("changed"))
            return columnSql;
        foreach (c; columns["changed"].iterItems())
        {
            c["schema"] = data["schema"];
            c["table"] = data["name"];
            auto r = conn.executeDict(renderTemplate(columnTemplatePath ~ "/" ~ PROPERTIES_SQL, tv("tid", tid,
                    "clid", c.contains("attnum") ? c["attnum"] : Value(null), "show_sys_objects", bpModule.showSystemObjectsFlag)));
            if (!r.ok)
                throw new ExecuteError(r.error);
            auto oldColData = r.value["rows"][0];
            bool sqr;
            oldColData["cltype"] = Value(columnUtils.typeFormatter(oldColData["cltype"].toString, sqr));
            oldColData["hasSqrBracket"] = Value(sqr);
            oldColData = columnUtils.convertLengthPrecisionToString(oldColData);
            oldColData = columnUtils.fetchLengthPrecision(oldColData);
            oldColData["cltype"] = Value(DataTypeReader.parseTypeName(oldColData["cltype"].toString));
            if (c.dict.get("inheritedfrom", Value(null)).isNone && c.dict.get("inheritedfromtable", Value(null)).isNone)
                columnSql ~= renderTemplate(foreignTableColumnTemplatePath ~ "/" ~ UPDATE_SQL,
                        tv("data", c, "o_data", oldColData, "conn", conn)).strip("\n") ~ doubleNewline;
        }
        return columnSql;
    }

    private string ftCheckForColumnAdd(Value columns, Value data, string columnSql)
    {
        if (columns.contains("added"))
            foreach (c; columns["added"].iterItems())
            {
                c["schema"] = data["schema"];
                c["table"] = data["name"];
                c = columnUtils.convertLengthPrecisionToString(c);
                if (c.dict.get("inheritedfrom", Value(null)).isNone && c.dict.get("inheritedfromtable", Value(null)).isNone)
                    columnSql ~= renderTemplate(foreignTableColumnTemplatePath ~ "/" ~ CREATE_SQL,
                            tv("data", c, "conn", conn)).strip("\n") ~ doubleNewline;
            }
        return columnSql;
    }

    string getFtSql(Value gid, Value sid, Value did, Value scid, Value data, Value foid, out string name, out Response err,
            bool isSchemaDiff = false)
    {
        if (!foid.isNone)
        {
            bool found;
            auto oldData = fetchProperties(gid, sid, did, scid, foid, true, found, err);
            if (err !is null)
                return null;
            if (!found)
            {
                err = gone(notFoundErrorMsg());
                return null;
            }
            if (isSchemaDiff)
            {
                data["is_schema_diff"] = Value(true);
                oldData["columns_for_schema_diff"] = oldData["columns"];
            }
            if (!data.contains("name"))
                data["name"] = oldData["name"];
            if (!data.contains("schema"))
                data["schema"] = oldData["basensp"];
            parsePrivileges(data);
            string sql;
            sql = rt(UPDATE_SQL, tv("data", data, "o_data", oldData, "conn", conn));
            if (sql.length)
                sql = sql.strip("\n") ~ doubleNewline;
            if (data.contains("columns"))
            {
                data = columnUtils.parseFormatColumns(data, "edit");
                normaliseColumnCollation(data["columns"]);
                auto columns = data["columns"];
                string columnSql = "\n";
                columnSql = ftCheckForColumnDelete(columns, data, columnSql);
                columnSql = ftCheckForColumnUpdate(columns, data, columnSql, foid);
                columnSql = ftCheckForColumnAdd(columns, data, columnSql);
                sql ~= columnSql.strip("\n");
            }
            sql = replaceAll(sql, regex(pattern), doubleNewline).strip("\n");
            name = data.contains("name") ? data["name"].toString : oldData["name"].toString;
            return sql;
        }
        data["columns"] = formatColumns(data["columns"]);
        if (data.contains("relacl"))
            data["relacl"] = parsePrivToDb(data["relacl"], allowedPrivileges);
        auto sql = rt(CREATE_SQL, tv("data", data, "conn", conn));
        name = data["name"].toString;
        return sql;
    }

    private string getResqlForFtTriggers(Value tid, string schema, string table)
    {
        auto r = conn.execute2darray(renderTemplate(triggerTemplatePath ~ "/" ~ NODES_SQL, tv("tid", tid)));
        if (!r.ok)
            throw new HTTPException(internalServerError(r.error));
        string triggerSql;
        foreach (row; r.value["rows"].list.items)
        {
            triggerSql = triggerUtils.getReverseEngineeredSql(conn, schema, table, tid, row["oid"],
                    Value(DATABASE_LAST_SYSTEM_OID_), bpModule.showSystemObjectsFlag);
            triggerSql = "\n" ~ triggerSql;
            triggerSql = replaceAll(triggerSql, regex(pattern), doubleNewline);
        }
        return triggerSql;
    }

    private Response sqlView(Value gid, Value sid, Value did, Value scid, Value foid, string targetSchema = null,
            bool jsonResp = true)
    {
        Response err;
        bool found;
        auto data = fetchProperties(gid, sid, did, scid, foid, true, found, err);
        if (err !is null)
            return err;
        if (!found)
            return gone(notFoundErrorMsg());
        Value[] colData;
        foreach (c; data["columns"].iterItems())
            if (c.dict.get("inheritedfrom", Value(null)).isNone)
                colData ~= c;
        data["columns"] = Value(colData);
        if (targetSchema.length)
            data["basensp"] = Value(targetSchema);
        if (data.contains("relacl"))
            data["relacl"] = parsePrivToDb(data["relacl"], allowedPrivileges);
        auto sql = rt(CREATE_SQL, tv("data", data, "is_sql", true, "add_not_exists_clause", true, "conn", conn));
        if (!jsonResp)
            return Response.sqlOnly(sql.strip("\n"));
        auto header = "-- FOREIGN TABLE: " ~ data["basensp"].toString ~ "." ~ data["name"].toString ~ "\n\n";
        header ~= "-- DROP FOREIGN TABLE IF EXISTS " ~ qtIdentStr(data["basensp"].toString, data["name"].toString) ~ ";\n\n";
        sql = header ~ sql;
        sql ~= getResqlForFtTriggers(foid, data["basensp"].toString, data["name"].toString);
        return makeResponse(Value(sql.strip("\n")));
    }

    private Value propertiesOrGone(Value gid, Value sid, Value did, Value scid, Value foid, out Response err)
    {
        bool found;
        auto data = fetchProperties(gid, sid, did, scid, foid, false, found, err);
        if (err !is null)
            return Value(null);
        if (!found)
        {
            err = gone(notFoundErrorMsg());
            return Value(null);
        }
        return data;
    }

    private Response selectSql(Value gid, Value sid, Value did, Value scid, Value foid)
    {
        Response err;
        auto data = propertiesOrGone(gid, sid, did, scid, foid, err);
        if (err !is null)
            return err;
        string[] columns;
        foreach (c; data["columns"].iterItems())
            columns ~= qtIdentStr(c["name"].toString);
        auto cols = columns.length ? columns.join(", ") : "*";
        return makeResponse(Value("SELECT " ~ cols ~ "\n\tFROM " ~ qtIdentStr(data["basensp"].toString, data["name"].toString) ~ ";"));
    }

    private Response insertSql(Value gid, Value sid, Value did, Value scid, Value foid)
    {
        Response err;
        auto data = propertiesOrGone(gid, sid, did, scid, foid, err);
        if (err !is null)
            return err;
        string[] columns, values;
        if (data.contains("columns"))
            foreach (c; data["columns"].iterItems())
            {
                columns ~= qtIdentStr(c["name"].toString);
                values ~= "?";
            }
        string sql;
        if (columns.length)
            sql = "INSERT INTO " ~ qtIdentStr(data["basensp"].toString, data["name"].toString) ~ "(\n\t" ~ columns.join(", ")
                ~ ")\n\tVALUES (" ~ values.join(", ") ~ ");";
        else
            sql = gettext("-- Please create column(s) first...");
        return makeResponse(Value(sql));
    }

    private Response updateSql(Value gid, Value sid, Value did, Value scid, Value foid)
    {
        Response err;
        auto data = propertiesOrGone(gid, sid, did, scid, foid, err);
        if (err !is null)
            return err;
        string[] columns;
        if (data.contains("columns"))
            foreach (c; data["columns"].iterItems())
                columns ~= qtIdentStr(c["name"].toString);
        string sql;
        if (columns.length)
        {
            auto cols = columns.length == 1 ? columns[0] ~ "=?" : columns.join("=?, ") ~ "=?";
            sql = "UPDATE " ~ qtIdentStr(data["basensp"].toString, data["name"].toString) ~ "\n\tSET " ~ cols
                ~ "\n\tWHERE <condition>;";
        }
        else
            sql = gettext("-- Please create column(s) first...");
        return makeResponse(Value(sql));
    }

    private Response deleteSql(Value gid, Value sid, Value did, Value scid, Value foid)
    {
        Response err;
        auto data = propertiesOrGone(gid, sid, did, scid, foid, err);
        if (err !is null)
            return err;
        return makeResponse(Value("DELETE FROM " ~ qtIdentStr(data["basensp"].toString, data["name"].toString)
                ~ "\n\tWHERE <condition>;"));
    }

    private Response enableDisableTriggers(Value gid, Value sid, Value did, Value scid, Value foid)
    {
        auto data = formOrJson(request());
        auto isEnableTrigger = data["is_enable_trigger"];
        try
        {
            if (!foid.isNone)
            {
                bool found;
                Response err;
                data = fetchProperties(gid, sid, did, scid, foid, true, found, err);
                if (err !is null)
                    return err;
                if (!found)
                    return gone(notFoundErrorMsg());
            }
            auto x = conn.executeScalar(rt("enable_disable_trigger.sql", tv("data", data, "is_enable_trigger", isEnableTrigger)));
            if (!x.ok)
                return internalServerError(x.error);
            auto t = conn.executeScalar(rt("get_enabled_triggers.sql", tv("tid", foid)));
            if (!t.ok)
                return internalServerError(x.error);
            return makeJsonResponse(1, Value(""), Value(isEnableTrigger == Value("D")
                    ? gettext("Trigger(s) have been disabled") : gettext("Trigger(s) have been enabled")), Value(null),
                    Value.dictOf("id", foid, "scid", scid, "has_enable_triggers", t.value), 200);
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }
}
