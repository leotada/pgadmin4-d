/// `tables/columns`: the columns of tables, views and (via `ForeignTableColumnsView`) foreign tables.
module pgadmin.browser.server_groups.servers.databases.schemas.tables.columns;

import pgadmin.browser.common;
import pgadmin.browser.server_groups.servers.databases.schemas.utils;
import columnUtils = pgadmin.browser.server_groups.servers.databases.schemas.tables.columns.utils;

private __gshared ColumnsModule columnsModuleInstance;

/// The one `ColumnsModule` shared by tables and views (the Python blueprint is appended to both).
ColumnsModule columnsModule()
{
    if (columnsModuleInstance is null)
        columnsModuleInstance = new ColumnsModule;
    return columnsModuleInstance;
}

final class ColumnsModule : CollectionNodeModule
{
    enum NODE_TYPE = "column";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "Columns";
        minVer = Value(null);
        maxVer = Value(null);
        staticDir("browser/server_groups/servers/databases/schemas/tables/columns");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => "database";
    override bool nodeInode() => false;
    override bool moduleUseTemplateJavascript() => false;

    override Value[] getNodes(Dict kwargs)
    {
        auto parent = kwargs.has("tid") ? kwargs["tid"] : kwargs["vid"];
        if (hasNodes(kwargs["sid"], kwargs["did"], kwargs["scid"], parent, Value(null), ColumnsView.BASE_TEMPLATE_PATH))
            return [generateBrowserCollectionNode(parent)];
        return null;
    }

    override void setup()
    {
        registerNodeView!ColumnsView(this);
    }
}

/// `ColParamsJSONDecoder`: JSON-decodes strings, but keeps the text when it decodes to a string or is not JSON.
Value colParamsLoad(Value v)
{
    if (!v.isString)
        return v;
    auto r = tryParseJson(v.str, v);
    return r.isString ? v : r;
}

class ColumnsView : PGChildNodeView
{
    enum BASE_TEMPLATE_PATH = "columns/sql/#{0}#";

    string foreignTableColumnTemplatePath;
    string schema;
    string table;
    string[] acl;

    string nodeTypeName() => ColumnsModule.NODE_TYPE;

    this()
    {
        super();
        nodeType = nodeTypeName();
        nodeLabel = "Column";
        parentIds = [IdSpec("int", "gid"), IdSpec("int", "sid"), IdSpec("int", "did"), IdSpec("int", "scid"),
            IdSpec("int", "tid")];
        ids = [IdSpec("string", "clid")];
        setAllOps([
            makeOp("obj", ["get": "properties", "delete": "delete", "put": "update"],
                    ["get": "list", "post": "create", "delete": "delete"]),
            makeOp("children", ["get": "children"]),
            makeOp("nodes", ["get": "nodes"], ["get": "nodes"]),
            makeOp("sql", ["get": "sql"]),
            makeOp("msql", ["get": "msql"], ["get": "msql"]),
            makeOp("stats", ["get": "statistics"]),
            makeOp("dependency", ["get": "dependencies"]),
            makeOp("dependent", ["get": "dependents"]),
        ]);
    }

    private string tplPath() => nodeType == "foreign_table_column" ? foreignTableColumnTemplatePath : templatePath;

    override Response callMethod(string name, Dict k)
    {
        if (!isAuthenticated())
            return unauthorisedResponse();
        if (name == "children")
            return children(k);
        manager = getDriver().connectionManagerOrNull(k["sid"].integer);
        if (manager is null)
            return gone(gettext("Could not find the server."));
        conn = manager.connection(null, null, true, k["did"]);
        templatePath = BASE_TEMPLATE_PATH.replace("{0}", to!string(manager.version_));
        foreignTableColumnTemplatePath = "foreign_table_columns/sql/#" ~ to!string(manager.version_) ~ "#";
        acl = ["a", "r", "w", "x"];
        columnUtils.getParent(conn, k["tid"], schema, table);
        auto gid = k.has("gid") ? k["gid"] : Value(null);
        auto scid = k["scid"];
        auto tid = k["tid"];
        auto clid = k.has("clid") ? k["clid"] : Value(null);
        auto showSys = bpModule.showSystemObjectsFlag;
        switch (name)
        {
        case "list":
        {
            auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("tid", tid, "show_sys_objects", showSys)));
            if (!r.ok)
                return internalServerError(r.error);
            foreach (column; r.value["rows"].list.items)
                columnUtils.columnFormatter(conn, tid, column["attnum"], column);
            return makeResponse(r.value["rows"], 200);
        }
        case "nodes":
        {
            auto r = conn.execute2darray(rt(NODES_SQL, tv("tid", tid, "clid", clid, "show_sys_objects", showSys, "conn", conn)));
            if (!r.ok)
                return internalServerError(r.error);
            Dict extra(Value row) => kwDict("datatype", row["datatype"], "description", row["description"],
                    "displaytypname", row["displaytypname"]);
            if (!clid.isNone)
            {
                if (r.value["rows"].length == 0)
                    return gone(notFoundErrorMsg());
                auto row = r.value["rows"][0];
                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                        gbn(row["oid"], tid, row["name"].toString, "icon-column", extra(row)), 200);
            }
            Value[] res;
            foreach (row; r.value["rows"].list.items)
                res ~= gbn(row["oid"], tid, row["name"].toString, "icon-column", extra(row));
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        case "properties":
        {
            auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("tid", tid, "clid", clid, "show_sys_objects", showSys)));
            if (!r.ok)
                return internalServerError(r.error);
            if (r.value["rows"].length == 0)
                return gone(notFoundErrorMsg());
            auto data = Value(r.value["rows"][0].dict.copy());
            data = columnUtils.columnFormatter(conn, tid, clid, data);
            return makeResponse(data, 200);
        }
        case "create": return create(tid);
        case "delete": return delete_(tid, clid);
        case "update": return update(scid, tid, clid);
        case "msql": return msql(scid, tid, clid);
        case "sql": return sqlView(scid, tid, clid);
        case "dependents": return dependentsOf(tid, clid);
        case "dependencies":
        {
            auto where = "WHERE dep.objid=" ~ tid.toString ~ "::OID AND dep.objsubid=" ~ clid.toString;
            return makeResponse(getDependencies(conn, clid, where), 200);
        }
        case "statistics":
        {
            auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("tid", tid, "clid", clid, "show_sys_objects", showSys)));
            if (!r.ok)
                return internalServerError(r.error);
            if (r.value["rows"].length == 0)
                return gone(notFoundErrorMsg());
            auto column = r.value["rows"][0]["name"];
            auto s = conn.executeDict(rt("stats.sql", tv("conn", conn, "schema", schema, "table", table, "column", column)));
            if (!s.ok)
                return internalServerError(s.error);
            return makeJsonResponse(1, Value(""), Value(""), Value(null), s.value, 200);
        }
        default: return super.callMethod(name, k);
        }
    }

    private Response dependentsOf(Value tid, Value clid)
    {
        auto where = "WHERE dep.refobjid=" ~ tid.toString ~ "::OID AND dep.refobjsubid=" ~ clid.toString;
        auto result = getDependents(conn, clid, where);
        auto r = conn.executeDict(rt("depend.sql", tv("where", where)));
        if (!r.ok)
            return internalServerError(r.error);
        foreach (row; r.value["rows"].list.items)
        {
            if (row["refname"].isNone)
                continue;
            string depType;
            auto ds = row["deptype"].toString;
            if (ds == "a")
                depType = "auto";
            else if (ds == "n")
                depType = "normal";
            else if (ds == "i")
                depType = "internal";
            result.append(Value.dictOf("type", "sequence", "name", row["refname"], "field", depType));
        }
        return makeResponse(result, 200);
    }

    private Response create(Value tid)
    {
        auto data = formOrJson(request());
        foreach (k, v; data.dict)
            if (k != "description")
                data[k] = colParamsLoad(v);
        foreach (arg; [["name", "Name"], ["cltype", "Type"]])
            if (!data.contains(arg[0]))
                return makeJsonResponse(0, Value(gettext("Could not find the required parameter ({}).").replace("{}", arg[1])),
                        Value(""), Value(null), Value(null), 410);
        if (data.contains("attacl"))
            data["attacl"] = parsePrivToDb(data["attacl"], acl);
        data["schema"] = Value(schema);
        data["table"] = Value(table);
        if (table.length == 0)
            return gone(gettext(notFoundErrorMsg("Table")));
        bool sqr;
        data["cltype"] = Value(columnUtils.typeFormatter(data["cltype"].toString, sqr));
        data["hasSqrBracket"] = Value(sqr);
        data = columnUtils.convertLengthPrecisionToString(data);
        auto x = conn.executeScalar(renderTemplate(tplPath() ~ "/" ~ CREATE_SQL, tv("data", data, "conn", conn)));
        if (!x.ok)
            return internalServerError(x.error);
        auto p = conn.executeScalar(rt("get_position.sql", tv("tid", tid, "data", data, "conn", conn)));
        if (!p.ok)
            return internalServerError(tid.toString);
        return jsonify(Value.dictOf("node", gbn(p.value, tid, data["name"].toString, "icon-column")));
    }

    private Response delete_(Value tid, Value clidArg)
    {
        Value data = clidArg.isNone ? formOrJson(request()) : Value.dictOf("ids", Value([clidArg]));
        try
        {
            Value clid;
            foreach (id; data["ids"].iterItems())
            {
                clid = id;
                auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("tid", tid, "clid", clid,
                        "show_sys_objects", bpModule.showSystemObjectsFlag)));
                if (!r.ok)
                    return internalServerError(r.error);
                if (r.value["rows"].length == 0)
                    return makeJsonResponse(0, Value(gettext("Error: Object not found.")), Value(notFoundErrorMsg()));
                auto row = Value(r.value["rows"][0].dict.copy());
                row["schema"] = Value(schema);
                row["table"] = Value(table);
                auto x = conn.executeScalar(renderTemplate(tplPath() ~ "/" ~ DELETE_SQL, tv("data", row, "conn", conn)));
                if (!x.ok)
                    return internalServerError(x.error);
            }
            return makeJsonResponse(1, Value(""), Value(gettext("Column is dropped")), Value(null),
                    Value.dictOf("id", clid, "tid", tid));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response update(Value scid, Value tid, Value clid)
    {
        auto data = formOrJson(request());
        data["schema"] = Value(schema);
        data["table"] = Value(table);
        if (data.contains("cltype"))
        {
            bool sqr;
            data["cltype"] = Value(columnUtils.typeFormatter(data["cltype"].toString, sqr));
            data["hasSqrBracket"] = Value(sqr);
        }
        Response err;
        string name;
        auto sql = getSql(scid, tid, clid, data, name, err);
        if (err !is null)
            return err;
        sql = sql.strip("\n").strip(" ");
        auto x = conn.executeScalar(sql);
        if (!x.ok)
            return internalServerError(x.error);
        Dict extra;
        if (data.contains("description"))
            extra = kwDict("description", data["description"]);
        return jsonify(Value.dictOf("node", gbn(clid, tid, name, "icon-" ~ nodeType, extra)));
    }

    private Response msql(Value scid, Value tid, Value clid)
    {
        auto data = Value.newDict();
        foreach (key; request().args.keys)
            data[key] = colParamsLoad(Value(request().args.get(key)));
        data["schema"] = Value(schema);
        data["table"] = Value(table);
        if (data.contains("cltype"))
        {
            bool sqr;
            data["cltype"] = Value(columnUtils.typeFormatter(data["cltype"].toString, sqr));
            data["hasSqrBracket"] = Value(sqr);
        }
        try
        {
            Response err;
            string name;
            auto sql = getSql(scid, tid, clid, data, name, err);
            if (err !is null)
                return err;
            if (name is null) // get_sql returned a bare string instead of (sql, name)
                throw new Exception("too many values to unpack (expected 2)");
            sql = sql.strip("\n").strip(" ");
            if (sql == "")
                sql = "--modified SQL";
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(sql), 200);
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private void parseAclToDbParsing(Value data, Value oldData)
    {
        if (!data.contains("name"))
            data["name"] = oldData["name"];
        if (data.contains("attacl") && !data["attacl"].isNone)
            foreach (k; ["added", "changed", "deleted"])
                if (data["attacl"].contains(k))
                    data["attacl"][k] = parsePrivToDb(data["attacl"][k], acl);
    }

    private void checkType(Value data, Value oldData)
    {
        if (oldData.contains("cltype"))
        {
            bool sqr;
            oldData["cltype"] = Value(columnUtils.typeFormatter(oldData["cltype"].toString, sqr));
            oldData["hasSqrBracket"] = Value(sqr);
            if (data.contains("cltype") && data["cltype"] != oldData["cltype"])
            {
                bool length, precision;
                string typeval;
                DataTypeReader.getLengthPrecision(data["cltype"], null, length, precision, typeval);
                if (!length)
                    oldData["attlen"] = Value(-1);
                if (!precision)
                    oldData["attprecision"] = Value(null);
            }
        }
    }

    string getSql(Value scid, Value tid, Value clid, Value data, out string name, out Response err, bool isSql = false)
    {
        data = columnUtils.convertLengthPrecisionToString(data);
        Value oldData;
        string sql;
        if (!clid.isNone)
        {
            auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("tid", tid, "clid", clid,
                    "show_sys_objects", bpModule.showSystemObjectsFlag)));
            if (!r.ok)
            {
                err = internalServerError(r.error);
                return null;
            }
            if (r.value["rows"].length == 0)
            {
                err = gone(notFoundErrorMsg());
                return null;
            }
            oldData = Value(r.value["rows"][0].dict.copy());
            bool isViewOnly = oldData.contains("is_view_only") && oldData["is_view_only"].truthy;
            if (oldData.contains("seqcycle") && oldData["seqcycle"] == Value(false))
                oldData["seqcycle"] = Value(null);
            oldData = columnUtils.columnFormatter(conn, tid, clid, oldData);
            checkType(data, oldData);
            parseAclToDbParsing(data, oldData);
            sql = renderTemplate(tplPath() ~ "/" ~ UPDATE_SQL, tv("data", data, "o_data", oldData, "conn", conn,
                    "is_view_only", isViewOnly));
        }
        else
        {
            foreach (arg; ["name", "cltype"])
                if (!data.contains(arg))
                {
                    name = null;
                    sql = gettext("-- definition incomplete");
                    return sql;
                }
            if (data.contains("attacl"))
                data["attacl"] = parsePrivToDb(data["attacl"], acl);
            sql = renderTemplate(tplPath() ~ "/" ~ CREATE_SQL, tv("data", data, "conn", conn, "is_sql", isSql));
        }
        name = data.contains("name") ? data["name"].toString : oldData["name"].toString;
        return sql;
    }

    private Response sqlView(Value scid, Value tid, Value clid)
    {
        try
        {
            auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("tid", tid, "clid", clid,
                    "show_sys_objects", bpModule.showSystemObjectsFlag)));
            if (!r.ok)
                return internalServerError(r.error);
            if (r.value["rows"].length == 0)
                return gone(notFoundErrorMsg());
            auto data = Value(r.value["rows"][0].dict.copy());
            if (data.contains("attlen") && data["attlen"] == Value(-1))
                data["attlen"] = Value("");
            data["schema"] = Value(schema);
            data["table"] = Value(table);
            if (data.contains("cltype"))
            {
                bool sqr;
                data["cltype"] = Value(columnUtils.typeFormatter(data["cltype"].toString, sqr));
                data["hasSqrBracket"] = Value(sqr);
            }
            data = columnUtils.columnFormatter(conn, tid, clid, data, new List);
            Response err;
            string name;
            auto sql = getSql(scid, tid, Value(null), data, name, err, true);
            if (err !is null)
                return err;
            auto header = "-- Column: " ~ qtIdentStr(data["schema"].toString, data["table"].toString, data["name"].toString)
                ~ "\n\n-- ";
            header ~= renderTemplate(tplPath() ~ "/" ~ DELETE_SQL, tv("data", data, "conn", conn));
            sql = header ~ "\n\n" ~ sql;
            return makeResponse(Value(sql.strip("\n")));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }
}

final class ForeignTableColumnsModule : CollectionNodeModule
{
    enum NODE_TYPE = "foreign_table_column";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "Columns";
        minVer = Value(null);
        maxVer = Value(null);
        staticDir("browser/server_groups/servers/databases/schemas/foreign_tables/foreign_table_columns");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => "database";
    override bool nodeInode() => false;
    override bool moduleUseTemplateJavascript() => false;

    override Value[] getNodes(Dict kwargs)
    {
        if (hasNodes(kwargs["sid"], kwargs["did"], kwargs["scid"], kwargs["foid"], Value(null),
                ForeignTableColumnsView.BASE_TEMPLATE_PATH))
            return [generateBrowserCollectionNode(kwargs["foid"])];
        return null;
    }

    override void setup()
    {
        registerNodeView!ForeignTableColumnsView(this);
    }
}

final class ForeignTableColumnsView : ColumnsView
{
    override string nodeTypeName() => ForeignTableColumnsModule.NODE_TYPE;
}
