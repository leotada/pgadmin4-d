/// `schemas/fts_templates`: full-text search templates.
module pgadmin.browser.server_groups.servers.databases.schemas.fts_templates;

import pgadmin.browser.common;
import pgadmin.browser.server_groups.servers.databases.schemas.utils;

final class FtsTemplateModule : SchemaChildModule
{
    enum NODE_TYPE = "fts_template";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "FTS Templates";
        minVer = Value(null);
        maxVer = Value(null);
        staticDir("browser/server_groups/servers/databases/schemas/fts_templates");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => "database";
    override bool nodeInode() => false;

    override Value[] getNodes(Dict kwargs)
    {
        if (hasNodes(kwargs["sid"], kwargs["did"], kwargs["scid"], Value(null), Value(null), FtsTemplateView.BASE_TEMPLATE_PATH))
            return [generateBrowserCollectionNode(kwargs["scid"])];
        return null;
    }

    override void setup()
    {
        registerNodeView!FtsTemplateView(this);
    }
}

final class FtsTemplateView : PGChildNodeView
{
    enum BASE_TEMPLATE_PATH = "fts_templates/sql/#{0}#";

    this()
    {
        super();
        nodeType = FtsTemplateModule.NODE_TYPE;
        nodeLabel = "FTS Template";
        parentIds = [IdSpec("int", "gid"), IdSpec("int", "sid"), IdSpec("int", "did"), IdSpec("int", "scid")];
        ids = [IdSpec("int", "tid")];
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
            makeOp("get_lexize", ["get": "get_lexize"], ["get": "get_lexize"]),
            makeOp("get_init", ["get": "get_init"], ["get": "get_init"]),
        ]);
    }

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
        auto scid = k["scid"];
        auto tid = k.has("tid") ? k["tid"] : Value(null);
        switch (name)
        {
        case "list":
        {
            auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("scid", scid, "conn", conn)));
            if (!r.ok)
                return internalServerError(r.error);
            return makeResponse(r.value["rows"], 200);
        }
        case "nodes":
        {
            auto r = conn.execute2darray(rt(NODES_SQL, tv("scid", scid)));
            if (!r.ok)
                return internalServerError(r.error);
            Value[] res;
            foreach (row; r.value["rows"].list.items)
                res ~= gbn(row["oid"], scid, row["name"].toString, "icon-fts_template",
                        kwDict("description", row["description"]));
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        case "node":
        {
            auto r = conn.execute2darray(rt(NODES_SQL, tv("tid", tid)));
            if (!r.ok)
                return internalServerError(r.error);
            foreach (row; r.value["rows"].list.items)
                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                        gbn(row["oid"], row["schema"], row["name"].toString, "icon-fts_template"), 200);
            return gone(notFoundErrorMsg());
        }
        case "properties":
        {
            Response e2;
            auto res = fetchProperties(scid, tid, e2);
            if (e2 !is null)
                return e2;
            return makeResponse(res, 200);
        }
        case "create": return create(scid);
        case "update": return update(gid, sid, did, scid, tid);
        case "delete": return delete_(scid, tid);
        case "msql": return msql(gid, sid, did, scid, tid);
        case "get_lexize": return functionOptions("lexize", Value(""));
        case "get_init": return functionOptions("init", Value("-"));
        case "sql": return sqlView(scid, tid);
        case "dependents": return makeResponse(getDependents(conn, tid), 200);
        case "dependencies": return makeResponse(getDependencies(conn, tid), 200);
        default: return super.callMethod(name, k);
        }
    }

    Value fetchProperties(Value scid, Value tid, out Response err)
    {
        auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("scid", scid, "tid", tid, "conn", conn)));
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
        auto row = r.value["rows"][0];
        row["is_sys_obj"] = Value(row["oid"].integer <= DATABASE_LAST_SYSTEM_OID_ || datistemplate);
        return row;
    }

    private Response create(Value scid)
    {
        auto data = formOrJson(request());
        auto miss = missingArg(data, ["tmpllexize", "schema", "name"]);
        if (miss !is null)
            return miss;
        auto s = conn.executeScalar(rt(SCHEMA_SQL, tv("data", data, "conn", conn)));
        if (!s.ok)
            return internalServerError(s.error);
        auto newData = Value(data.dict.copy());
        newData["schema"] = s.value;
        auto c = conn.executeScalar(rt(CREATE_SQL, tv("data", newData, "conn", conn)));
        if (!c.ok)
            return internalServerError(c.error);
        auto t = conn.executeScalar(rt(PROPERTIES_SQL, tv("name", data["name"], "scid", data["schema"], "conn", conn)));
        if (!t.ok)
            return internalServerError(t.error);
        return jsonify(Value.dictOf("node", gbn(t.value, data["schema"], data["name"].toString, "icon-fts_template")));
    }

    private Response update(Value gid, Value sid, Value did, Value scid, Value tid)
    {
        auto data = formOrJson(request());
        Response err;
        string name;
        auto sql = getSql(gid, sid, did, scid, data, tid, name, err);
        if (err !is null)
            return err;
        sql = sql.strip("\n").strip(" ");
        auto r = conn.executeScalar(sql);
        if (!r.ok)
            return internalServerError(r.error);
        auto n = conn.execute2darray(rt(NODES_SQL, tv("tid", tid)));
        if (!n.ok)
            return internalServerError(n.error);
        auto row = n.value["rows"][0];
        return jsonify(Value.dictOf("node", gbn(tid, row["schema"], row["name"].toString, "icon-" ~ nodeType,
                kwDict("description", row["description"]))));
    }

    Response delete_(Value scid, Value tidArg, bool onlySql = false)
    {
        Value data = tidArg.isNone ? formOrJson(request()) : Value.dictOf("ids", Value([tidArg]));
        bool cascade = checkCascadeOperation();
        foreach (tid; data["ids"].iterItems())
        {
            auto r = conn.executeDict(rt(DELETE_SQL, tv("tid", tid)));
            if (!r.ok)
                return internalServerError(r.error);
            if (r.value["rows"].length == 0)
                return makeJsonResponse(0, Value(gettext("Error: Object not found.")), Value(notFoundErrorMsg()),
                        Value(null), Value(null), 410);
            auto result = r.value["rows"][0];
            auto sql = rt(DELETE_SQL, tv("name", result["name"], "schema", result["schema"], "cascade", cascade));
            if (onlySql)
                return Response.sqlOnly(sql);
            auto x = conn.executeScalar(sql);
            if (!x.ok)
                return internalServerError(x.error);
        }
        return makeJsonResponse(1, Value(""), Value(gettext("FTS Template dropped")));
    }

    private Response msql(Value gid, Value sid, Value did, Value scid, Value tid)
    {
        auto data = msqlData("description");
        Response err;
        string name;
        auto sql = getSql(gid, sid, did, scid, data, tid, name, err);
        if (err !is null)
            return err;
        if (sql == "")
            sql = "--modified SQL";
        return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(sql), 200);
    }

    string getSql(Value gid, Value sid, Value did, Value scid, Value data, Value tid, out string name, out Response err)
    {
        if (!tid.isNone)
        {
            auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("tid", tid, "scid", scid, "conn", conn)));
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
            auto oldData = r.value["rows"][0];
            if (!data.contains("schema"))
                data["schema"] = oldData["schema"];
            auto s = conn.executeScalar(rt(SCHEMA_SQL, tv("data", data)));
            if (!s.ok)
            {
                err = internalServerError(s.error);
                return null;
            }
            auto newData = Value(data.dict.copy());
            if (newData.contains("schema"))
                newData["schema"] = s.value;
            auto o = conn.executeScalar(rt(SCHEMA_SQL, tv("data", oldData)));
            if (!o.ok)
            {
                err = internalServerError(o.error);
                return null;
            }
            oldData["schema"] = o.value;
            auto sql = rt(UPDATE_SQL, tv("data", newData, "o_data", oldData, "conn", conn));
            name = data.contains("name") ? data["name"].toString : oldData["name"].toString;
            return sql.strip("\n");
        }
        auto s = conn.executeScalar(rt(SCHEMA_SQL, tv("data", data)));
        if (!s.ok)
        {
            err = internalServerError(s.error);
            return null;
        }
        string sql;
        auto newData = Value(data.dict.copy());
        newData["schema"] = s.value;
        if (newData.contains("tmpllexize") && newData.contains("name") && newData.contains("schema"))
            sql = rt(CREATE_SQL, tv("data", newData, "conn", conn));
        else
            sql = "-- definition incomplete";
        name = data["name"].toString;
        return sql.strip("\n");
    }

    private Response sqlView(Value scid, Value tid, string targetSchema = null, bool jsonResp = true)
    {
        auto r = conn.executeScalar(rt("sql.sql", tv("tid", tid, "scid", scid, "conn", conn)));
        if (!r.ok)
            return internalServerError(gettext("Could not generate reverse-engineered query for the FTS Template.\n{0}")
                    .replace("{0}", r.value.toString));
        if (r.value.isNone)
            return gone(gettext("Could not generate reverse-engineered query for FTS Template node."));
        auto res = r.value.toString;
        if (targetSchema.length)
        {
            auto s = conn.executeScalar(rt(SCHEMA_SQL, tv("data", Value.dictOf("schema", scid), "conn", conn)));
            if (!s.ok)
                return internalServerError(s.error);
            res = res.replace(s.value.toString, targetSchema);
        }
        if (!jsonResp)
            return Response.sqlOnly(res);
        return makeResponse(Value(res));
    }
}
