/// `tables/indexes`: indexes of tables, materialized views and partitions.
module pgadmin.browser.server_groups.servers.databases.schemas.tables.indexes;

import pgadmin.browser.common;
import pgadmin.browser.server_groups.servers.databases.schemas.utils : checkPgstattuple;
import pgadmin.browser.server_groups.servers.databases.schemas.tables.partitions : partitionsBackendSupported;
import indexUtils = pgadmin.browser.server_groups.servers.databases.schemas.tables.indexes.utils;

final class IndexesModule : CollectionNodeModule
{
    enum NODE_TYPE = "index";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "Indexes";
        minVer = Value(null);
        maxVer = Value(null);
        staticDir("browser/server_groups/servers/databases/schemas/tables/indexes");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => "database";
    override bool nodeInode() => false;
    override bool moduleUseTemplateJavascript() => false;

    override bool backendSupported(ServerManager manager, Dict kwargs)
    {
        if (!super.backendSupported(manager, kwargs))
            return false;
        auto conn = manager.connection(null, null, true, kwargs["did"]);
        if (kwargs.has("tid") && manager.version_ >= 100000 && manager.version_ < 110000)
            return !partitionsBackendSupported(this, manager, kwargs).truthy;
        if (!kwargs.has("vid"))
            return true;
        auto templatePath = "indexes/sql/#" ~ to!string(manager.version_) ~ "#";
        auto r = conn.executeScalar(renderTemplate(templatePath ~ "/backend_support.sql", tv("vid", kwargs["vid"])));
        if (!r.ok)
            throw new HTTPException(internalServerError(r.error));
        return r.value.truthy;
    }

    override Value[] getNodes(Dict kwargs)
    {
        auto parent = kwargs.has("tid") ? kwargs["tid"] : kwargs["vid"];
        if (hasNodes(kwargs["sid"], kwargs["did"], kwargs["scid"], parent, Value(null), IndexesView.BASE_TEMPLATE_PATH))
            return [generateBrowserCollectionNode(parent)];
        return null;
    }

    override void setup()
    {
        registerNodeView!IndexesView(this);
    }
}

final class IndexesView : PGChildNodeView
{
    enum BASE_TEMPLATE_PATH = "indexes/sql/#{0}#";

    string tableTemplatePath;
    string schema;
    string table;

    this()
    {
        super();
        nodeType = IndexesModule.NODE_TYPE;
        nodeLabel = "Index";
        parentIds = [IdSpec("int", "gid"), IdSpec("int", "sid"), IdSpec("int", "did"), IdSpec("int", "scid"),
            IdSpec("int", "tid")];
        ids = [IdSpec("int", "idx")];
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
            makeOp("get_collations", ["get": "get_collations"], ["get": "get_collations"]),
            makeOp("get_access_methods", ["get": "get_access_methods"], ["get": "get_access_methods"]),
            makeOp("get_op_class", ["get": "get_op_class"], ["get": "get_op_class"]),
        ]);
    }

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
        tableTemplatePath = "tables/sql/#" ~ to!string(manager.version_) ~ "#";
        templatePath = BASE_TEMPLATE_PATH.replace("{0}", to!string(manager.version_));
        indexUtils.getParent(conn, k["tid"], schema, table);
        auto gid = k.has("gid") ? k["gid"] : Value(null);
        auto sid = k["sid"];
        auto did = k["did"];
        auto scid = k["scid"];
        auto tid = k["tid"];
        auto idx = k.has("idx") ? k["idx"] : Value(null);
        auto showSys = bpModule.showSystemObjectsFlag;
        switch (name)
        {
        case "get_collations":
        {
            try
            {
                auto r = conn.execute2darray(rt("get_collations.sql"));
                if (!r.ok)
                    return internalServerError("[]");
                Value[] res;
                foreach (row; r.value["rows"].list.items)
                    res ~= Value.dictOf("label", row["collation"], "value", row["collation"]);
                return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
            }
            catch (HTTPException e)
                throw e;
            catch (Exception e)
                return internalServerError(e.msg);
        }
        case "get_access_methods":
        {
            try
            {
                auto r = conn.execute2darray(rt("get_am.sql"));
                if (!r.ok)
                    return internalServerError("[]");
                Value[] res;
                foreach (row; r.value["rows"].list.items)
                    res ~= Value.dictOf("label", row["amname"], "value", row["amname"]);
                return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
            }
            catch (HTTPException e)
                throw e;
            catch (Exception e)
                return internalServerError(e.msg);
        }
        case "get_op_class":
        {
            try
            {
                auto r = conn.execute2darray(rt("get_am.sql"));
                if (!r.ok)
                    return internalServerError("{}");
                auto res = Value.newDict();
                foreach (row; r.value["rows"].list.items)
                {
                    auto o = conn.execute2darray(rt("get_op_class.sql", tv("oid", row["oid"])));
                    if (!o.ok)
                        return internalServerError("{}");
                    Value[] list;
                    foreach (x; o.value["rows"].list.items)
                        list ~= Value.dictOf("label", x["opcname"], "value", x["opcname"]);
                    res[row["amname"].toString] = Value(list);
                }
                return makeJsonResponse(1, Value(""), Value(""), Value(null), res, 200);
            }
            catch (HTTPException e)
                throw e;
            catch (Exception e)
                return internalServerError(e.msg);
        }
        case "list":
        {
            auto r = conn.executeDict(rt(NODES_SQL, tv("tid", tid, "show_sys_objects", showSys)));
            if (!r.ok)
                return internalServerError(r.error);
            return makeResponse(r.value["rows"], 200);
        }
        case "node":
        {
            auto r = conn.execute2darray(rt(NODES_SQL, tv("tid", tid, "idx", idx, "show_sys_objects", showSys)));
            if (!r.ok)
                return internalServerError(r.error);
            if (r.value["rows"].length == 0)
                return gone(notFoundErrorMsg());
            auto row = r.value["rows"][0];
            return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    gbn(row["oid"], tid, row["name"].toString, "icon-index"), 200);
        }
        case "nodes":
        {
            auto r = conn.execute2darray(rt(NODES_SQL, tv("tid", tid, "show_sys_objects", showSys)));
            if (!r.ok)
                return internalServerError(r.error);
            Value[] res;
            foreach (row; r.value["rows"].list.items)
                res ~= gbn(row["oid"], tid, row["name"].toString, "icon-index", kwDict("description", row["description"]));
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        case "properties":
        {
            Response err;
            auto data = fetchProperties(did, tid, idx, err);
            if (err !is null)
                return err;
            return makeResponse(data, 200);
        }
        case "create": return create(tid);
        case "delete": return delete_(did, tid, idx);
        case "update": return update(did, tid, idx);
        case "msql": return msql(did, tid, idx);
        case "sql":
        {
            auto sql = indexUtils.getReverseEngineeredSql(conn, schema, table, did, tid, idx,
                    Value(DATABASE_LAST_SYSTEM_OID_), null, true, true, showSys);
            return makeResponse(Value(sql));
        }
        case "dependents": return makeResponse(getDependents(conn, idx), 200);
        case "dependencies": return makeResponse(getDependencies(conn, idx), 200);
        case "statistics": return statistics(did, tid, idx);
        default: return super.callMethod(name, k);
        }
    }

    Value fetchProperties(Value did, Value tid, Value idx, out Response err)
    {
        auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("did", did, "tid", tid, "idx", idx,
                "datlastsysoid", DATABASE_LAST_SYSTEM_OID_, "show_sys_objects", bpModule.showSystemObjectsFlag)));
        if (!r.ok)
        {
            err = internalServerError(r.error);
            return Value(null);
        }
        if (r.value["rows"].length == 0)
        {
            err = gone(notFoundErrorMsg());
            return Value(null);
        }
        auto data = Value(r.value["rows"][0].dict.copy());
        data = indexUtils.getColumnDetails(conn, idx, data);
        if (manager.version_ >= 110000)
            data = indexUtils.getIncludeDetails(conn, idx, data);
        return data;
    }

    private Response create(Value tid)
    {
        auto data = loadJsonValues(formOrJson(request()), "description");
        // _check_for_error
        if (data["columns"].length < 1)
            return makeJsonResponse(0, Value(gettext("You must provide one or more column to create index.")), Value(""),
                    Value(null), Value(null), 410);
        if (!data.contains("columns"))
            return makeJsonResponse(0, Value(gettext("Could not find the required parameter (Columns).")), Value(""),
                    Value(null), Value(null), 410);
        data["schema"] = Value(schema);
        data["table"] = Value(table);
        data["storage_parameters"] = Value.newDict();
        foreach (param; indexUtils.getStorageParams(data["amname"].toString))
            if (data.contains(param) && data[param] != Value(""))
                data["storage_parameters"][param] = data[param];
        if (table.length == 0)
            return gone(gettext(notFoundErrorMsg("Table")));
        try
        {
            auto c = conn.executeScalar(rt(CREATE_SQL, tv("data", data, "conn", conn, "mode", "create")));
            if (!c.ok)
                return internalServerError(c.error);
            auto sql = rt(ALTER_SQL, tv("data", data, "conn", conn)).strip("\n").strip(" ");
            if (sql != "")
            {
                auto a = conn.executeScalar(sql);
                if (!a.ok)
                    return internalServerError(a.error);
            }
            Value idx = Value(0);
            if (data.dict.get("name", Value("")) == Value(""))
            {
                auto o = conn.executeDict(rt("get_oid_name.sql", tv("tid", tid, "conn", conn)));
                if (!o.ok)
                    return internalServerError(tid.toString);
                if (o.value.contains("rows") && o.value["rows"].length > 0)
                {
                    data["name"] = o.value["rows"][0]["relname"];
                    idx = o.value["rows"][0]["oid"];
                }
            }
            else
            {
                auto o = conn.executeScalar(rt(OID_SQL, tv("tid", tid, "data", data, "conn", conn)));
                if (!o.ok)
                    return internalServerError(tid.toString);
                idx = o.value;
            }
            return jsonify(Value.dictOf("node", gbn(idx, tid, data["name"].toString, "icon-index")));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    Response delete_(Value did, Value tid, Value idxArg, bool onlySql = false)
    {
        Value data = idxArg.isNone ? formOrJson(request()) : Value.dictOf("ids", Value([idxArg]));
        bool cascade = checkCascadeOperation();
        try
        {
            foreach (idx; data["ids"].iterItems())
            {
                auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("did", did, "tid", tid, "idx", idx,
                        "datlastsysoid", DATABASE_LAST_SYSTEM_OID_, "show_sys_objects", bpModule.showSystemObjectsFlag)));
                if (!r.ok)
                    return internalServerError(r.error);
                if (r.value["rows"].length == 0)
                    return makeJsonResponse(0, Value(gettext("Error: Object not found.")), Value(notFoundErrorMsg()));
                auto row = Value(r.value["rows"][0].dict.copy());
                auto sql = rt(DELETE_SQL, tv("data", row, "conn", conn, "cascade", cascade));
                if (onlySql)
                    return Response.sqlOnly(sql);
                auto x = conn.executeScalar(sql);
                if (!x.ok)
                    return internalServerError(x.error);
            }
            return makeJsonResponse(1, Value(""), Value(gettext("Index is dropped")));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response update(Value did, Value tid, Value idx)
    {
        auto data = formOrJson(request());
        data["schema"] = Value(schema);
        data["table"] = Value(table);
        try
        {
            Value name;
            auto sql = indexUtils.getSql(conn, data, did, tid, idx, Value(DATABASE_LAST_SYSTEM_OID_), name, Value(null), false,
                    bpModule.showSystemObjectsFlag);
            sql = sql.strip("\n").strip(" ");
            auto x = conn.executeScalar(sql);
            if (!x.ok)
                return internalServerError(x.error);
            Dict extra;
            if (data.contains("description"))
                extra = kwDict("description", data["description"]);
            return jsonify(Value.dictOf("node", gbn(idx, tid, name.toString, "icon-" ~ nodeType, extra)));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response msql(Value did, Value tid, Value idx)
    {
        auto data = msqlData("description");
        data["schema"] = Value(schema);
        data["table"] = Value(table);
        if (data.dict.get("amname", Value(null)).truthy)
        {
            data["storage_parameters"] = Value.newDict();
            foreach (param; indexUtils.getStorageParams(data["amname"].toString))
                if (data.contains(param) && data[param] != Value(""))
                    data["storage_parameters"][param] = data[param];
        }
        try
        {
            Value name;
            auto sql = indexUtils.getSql(conn, data, did, tid, idx, Value(DATABASE_LAST_SYSTEM_OID_), name, Value("create"),
                    false, bpModule.showSystemObjectsFlag);
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

    private Response statistics(Value did, Value tid, Value idx)
    {
        Res res;
        if (!idx.isNone)
        {
            auto p = checkPgstattuple(conn, tid);
            if (!p.ok)
                return internalServerError(p.error);
            Value index = Value(null);
            if (p.value.truthy)
            {
                auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("did", did, "tid", tid, "idx", idx,
                        "datlastsysoid", DATABASE_LAST_SYSTEM_OID_, "show_sys_objects", bpModule.showSystemObjectsFlag)));
                if (!r.ok)
                    return internalServerError(r.error);
                if (r.value["rows"].length == 0)
                    return gone(notFoundErrorMsg());
                index = r.value["rows"][0]["name"];
            }
            res = conn.executeDict(rt("stats.sql", tv("conn", conn, "schema", schema, "index", index, "idx", idx,
                    "is_pgstattuple", p.value)));
        }
        else
            res = conn.executeDict(rt("coll_stats.sql", tv("conn", conn, "schema", schema, "table", table)));
        if (!res.ok)
            return internalServerError(res.error);
        return makeJsonResponse(1, Value(""), Value(""), Value(null), res.value, 200);
    }
}
