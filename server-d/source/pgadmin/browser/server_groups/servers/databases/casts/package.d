/// `databases/casts`: casts.
module pgadmin.browser.server_groups.servers.databases.casts;

import pgadmin.browser.common;

final class CastModule : CollectionNodeModule
{
    enum NODE_TYPE = "cast";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "Casts";
        staticDir("browser/server_groups/servers/databases/casts");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => "database";
    override bool nodeInode() => false;
    override bool moduleUseTemplateJavascript() => false;

    override Value[] getNodes(Dict kwargs)
    {
        if (hasNodes(kwargs["sid"], kwargs["did"], Value(null), Value(null), Value(null), CastView.BASE_TEMPLATE_PATH))
            return [generateBrowserCollectionNode(kwargs["did"])];
        return null;
    }

    override void setup()
    {
        registerNodeView!CastView(this);
    }
}

final class CastView : PGChildNodeView
{
    enum BASE_TEMPLATE_PATH = "casts/sql/#{0}#";

    this()
    {
        super();
        nodeType = CastModule.NODE_TYPE;
        nodeLabel = "Cast";
        parentIds = [IdSpec("int", "gid"), IdSpec("int", "sid"), IdSpec("int", "did")];
        ids = [IdSpec("int", "cid")];
        setAllOps([
            makeOp("obj", ["get": "properties", "delete": "delete", "put": "update"],
                    ["get": "list", "post": "create", "delete": "delete"]),
            makeOp("children", ["get": "children"]),
            makeOp("delete", ["delete": "delete"], ["delete": "delete"]),
            makeOp("nodes", ["get": "node"], ["get": "nodes"]),
            makeOp("sql", ["get": "sql"]),
            makeOp("msql", ["get": "msql"], ["get": "msql"]),
            makeOp("stats", ["get": "statistics"]),
            makeOp("dependency", ["get": "dependencies"]),
            makeOp("dependent", ["get": "dependents"]),
            makeOp("get_type", ["get": "get_src_and_trg_type"], ["get": "get_src_and_trg_type"]),
            makeOp("get_functions", ["post": "get_functions"], ["post": "get_functions"]),
            makeOp("compare", ["get": "compare"], ["get": "compare"]),
        ]);
    }

    private long lastSystemOid() => bpModule.showSystemObjectsFlag ? 0 : DATABASE_LAST_SYSTEM_OID_;

    override Response callMethod(string name, Dict k)
    {
        if (!isAuthenticated())
            return unauthorisedResponse();
        if (name == "children")
            return children(k);
        auto err = standardPrecondition(k, name, BASE_TEMPLATE_PATH);
        if (err !is null)
            return err;
        auto gid = k.has("gid") ? k["gid"] : Value(null);
        auto sid = k["sid"];
        auto did = k["did"];
        auto cid = k.has("cid") ? k["cid"] : Value(null);
        auto showSys = bpModule.showSystemObjectsFlag;
        switch (name)
        {
        case "list":
        {
            auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("datlastsysoid", lastSystemOid, "showsysobj", showSys)));
            if (!r.ok)
                return internalServerError(r.error);
            foreach (row; r.value["rows"].list.items)
                row["castcontext"] = Value(row["castcontext"] == Value("IMPLICIT"));
            return makeResponse(r.value["rows"], 200);
        }
        case "nodes":
        {
            auto r = conn.execute2darray(rt(NODES_SQL, tv("datlastsysoid", lastSystemOid, "showsysobj", showSys)));
            if (!r.ok)
                return internalServerError(r.error);
            Value[] res;
            foreach (row; r.value["rows"].list.items)
                res ~= gbn(row["oid"], did, row["name"].toString, "icon-cast", kwDict("description", row["description"]));
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        case "node":
        {
            auto r = conn.execute2darray(rt(NODES_SQL, tv("cid", cid)));
            if (!r.ok)
                return internalServerError(r.error);
            foreach (row; r.value["rows"].list.items)
                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                        gbn(row["oid"], did, row["name"].toString, "icon-cast"), 200);
            return gone(gettext("Could not find the specified cast."));
        }
        case "properties":
        {
            Response e2;
            auto res = fetchProperties(did, cid, e2);
            if (e2 !is null)
                return e2;
            return makeResponse(res, 200);
        }
        case "create": return create(did);
        case "update": return update(gid, sid, did, cid);
        case "delete": return delete_(cid);
        case "msql":
        {
            Response e2;
            string nm;
            bool bare;
            auto sql = getSql(request().args.toDict, cid, nm, e2, bare);
            if (e2 !is null)
                return e2;
            sql = sql.strip("\n").strip(" ");
            if (sql == "")
                sql = "--modified SQL";
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(sql), 200);
        }
        case "get_functions":
        {
            auto data = formOrJson(request());
            auto r = conn.executeDict(rt(FUNCTIONS_SQL, tv("srctyp", data["srctyp"], "trgtyp", data["trgtyp"], "conn", conn)));
            if (!r.ok)
                return internalServerError(r.error);
            Value[] res = [Value.dictOf("label", "", "value", "")];
            foreach (row; r.value["rows"].list.items)
                res ~= Value.dictOf("label", row["proname"], "value", row["proname"]);
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        case "get_src_and_trg_type":
        {
            auto r = conn.executeDict(rt("getsrcandtrgttype.sql", tv("cid", cid)));
            if (!r.ok)
                return internalServerError(r.error);
            Value[] res = [Value.dictOf("label", "", "value", "")];
            foreach (row; r.value["rows"].list.items)
                res ~= Value.dictOf("label", row["typname"], "value", row["typname"]);
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        case "sql":
        {
            try
            {
                auto r = conn.executeScalar(rt("sql.sql", tv("cid", cid, "conn", conn)));
                if (!r.ok)
                    return internalServerError(gettext("Could not generate reverse-engineered SQL for the cast.")
                            ~ "\n\n" ~ r.value.toString);
                if (r.value.isNone)
                    return gone(gettext("Could not generate reverse-engineered SQL for the cast node."));
                return makeResponse(r.value);
            }
            catch (HTTPException e)
                throw e;
            catch (Exception e)
                return internalServerError(e.msg);
        }
        case "dependents": return makeResponse(getDependents(conn, cid), 200);
        case "dependencies": return makeResponse(getDependencies(conn, cid), 200);
        default: return super.callMethod(name, k);
        }
    }

    Value fetchProperties(Value did, Value cid, out Response err)
    {
        auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("cid", cid, "datlastsysoid", bpModule.showSystemObjectsFlag
                ? DATABASE_LAST_SYSTEM_OID_ : 0, "showsysobj", bpModule.showSystemObjectsFlag, "conn", conn)));
        if (!r.ok)
        {
            err = internalServerError(r.error);
            return Value(null);
        }
        if (r.value["rows"].length == 0)
        {
            err = gone(gettext("Could not find the cast information."));
            return Value(null);
        }
        return r.value["rows"][0];
    }

    private Response create(Value did)
    {
        auto data = formOrJson(request());
        auto miss = missingArg(data, ["srctyp", "trgtyp"]);
        if (miss !is null)
            return miss;
        try
        {
            auto c = conn.executeScalar(rt(CREATE_SQL, tv("data", data, "conn", conn)));
            if (!c.ok)
                return internalServerError(c.error);
            auto p = conn.executeScalar(rt(PROPERTIES_SQL, tv("srctyp", data["srctyp"], "trgtyp", data["trgtyp"],
                    "datlastsysoid", lastSystemOid, "showsysobj", bpModule.showSystemObjectsFlag, "conn", conn)));
            if (!p.ok)
                return internalServerError(p.error);
            return jsonify(Value.dictOf("node", gbn(p.value, did, data["name"].toString, "icon-cast")));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response update(Value gid, Value sid, Value did, Value cid)
    {
        auto data = formOrJson(request());
        try
        {
            Response e2;
            string name;
            bool bare;
            auto sql = getSql(data, cid, name, e2, bare);
            if (e2 !is null)
                return e2;
            auto x = conn.executeScalar(sql);
            if (!x.ok)
                return internalServerError(x.error);
            Dict extra;
            if (data.contains("description"))
                extra = kwDict("description", data["description"]);
            return jsonify(Value.dictOf("node", gbn(cid, did, name, "icon-cast", extra)));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    Response delete_(Value cidArg, bool onlySql = false)
    {
        bool cascade = cmd == "delete";
        Value data = cidArg.isNone ? formOrJson(request()) : Value.dictOf("ids", Value([cidArg]));
        foreach (cid; data["ids"].iterItems())
        {
            try
            {
                auto r = conn.executeDict(rt(DELETE_SQL, tv("cid", cid)));
                if (!r.ok)
                    return internalServerError(r.error);
                if (r.value["rows"].length == 0)
                    return makeJsonResponse(0, Value(gettext("Error: Object not found.")),
                            Value(gettext("The specified cast object could not be found.\n")), Value(null), Value(null), 410);
                auto result = r.value["rows"][0];
                auto sql = rt(DELETE_SQL, tv("castsource", result["castsource"], "casttarget", result["casttarget"],
                        "cascade", cascade));
                if (onlySql)
                    return Response.sqlOnly(sql);
                auto x = conn.executeScalar(sql);
                if (!x.ok)
                    return internalServerError(x.error);
            }
            catch (HTTPException e)
                throw e;
            catch (Exception e)
                return internalServerError(e.msg);
        }
        return makeJsonResponse(1, Value(""), Value(gettext("Cast dropped")));
    }

    string getSql(Value data, Value cid, out string name, out Response err, out bool bare)
    {
        if (!cid.isNone)
        {
            auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("cid", cid, "datlastsysoid", lastSystemOid,
                    "showsysobj", bpModule.showSystemObjectsFlag, "conn", conn)));
            if (!r.ok)
            {
                err = internalServerError(r.error);
                return null;
            }
            if (r.value["rows"].length == 0)
            {
                err = gone(gettext("Could not find the specified cast on the server."));
                return null;
            }
            auto oldData = r.value["rows"][0];
            auto sql = rt(UPDATE_SQL, tv("data", data, "o_data", oldData, "conn", conn));
            name = data.contains("name") ? data["name"].toString : oldData["name"].toString;
            return sql;
        }
        if (data.contains("srctyp") && data.contains("trgtyp"))
        {
            auto sql = rt(CREATE_SQL, tv("data", data, "conn", conn));
            name = data["srctyp"].toString ~ "->" ~ data["trgtyp"].toString;
            return sql;
        }
        bare = true;
        return gettext("-- definition incomplete");
    }
}
