/// `tables/row_security_policies`: row level security policies.
module pgadmin.browser.server_groups.servers.databases.schemas.tables.row_security_policies;

import pgadmin.browser.common;
import policyUtils = pgadmin.browser.server_groups.servers.databases.schemas.tables.row_security_policies.utils;

final class RowSecurityModule : CollectionNodeModule
{
    enum NODE_TYPE = "row_security_policy";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "RLS Policies";
        minVer = Value(90500);
        maxVer = Value(null);
        staticDir("browser/server_groups/servers/databases/schemas/tables/row_security_policies");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => "database";
    override bool nodeInode() => false;
    override bool moduleUseTemplateJavascript() => false;

    override Value[] getNodes(Dict kwargs)
    {
        auto parent = kwargs.has("tid") ? kwargs["tid"] : kwargs["vid"];
        if (hasNodes(kwargs["sid"], kwargs["did"], kwargs["scid"], parent, Value(null), RowSecurityView.BASE_TEMPLATE_PATH))
            return [generateBrowserCollectionNode(parent)];
        return null;
    }

    override void setup()
    {
        registerNodeView!RowSecurityView(this);
    }
}

final class RowSecurityView : PGChildNodeView
{
    enum BASE_TEMPLATE_PATH = "row_security_policies/sql/#{0}#";

    string schema;
    string table;

    this()
    {
        super();
        nodeType = RowSecurityModule.NODE_TYPE;
        nodeLabel = "RLS Policy";
        parentIds = [IdSpec("int", "gid"), IdSpec("int", "sid"), IdSpec("int", "did"), IdSpec("int", "scid"),
            IdSpec("int", "tid")];
        ids = [IdSpec("int", "plid")];
        setAllOps([
            makeOp("obj", ["get": "properties", "delete": "delete", "put": "update"],
                    ["get": "list", "post": "create", "delete": "delete"]),
            makeOp("delete", ["delete": "delete"], ["delete": "delete"]),
            makeOp("nodes", ["get": "node"], ["get": "nodes"]),
            makeOp("sql", ["get": "sql"]),
            makeOp("msql", ["get": "msql"], ["get": "msql"]),
            makeOp("stats", ["get": "statistics"]),
            makeOp("dependency", ["get": "dependencies"]),
            makeOp("dependent", ["get": "dependents"]),
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
        policyUtils.getParent(conn, k["tid"], schema, table);
        templatePath = BASE_TEMPLATE_PATH.replace("{0}", to!string(manager.version_));
        auto scid = k["scid"];
        auto did = k["did"];
        auto tid = k["tid"];
        auto plid = k.has("plid") ? k["plid"] : Value(null);
        switch (name)
        {
        case "list":
        {
            auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("schema", schema, "tid", tid)));
            if (!r.ok)
                return internalServerError(r.error);
            return makeResponse(r.value["rows"], 200);
        }
        case "node":
        {
            auto r = conn.execute2darray(rt(NODES_SQL, tv("plid", plid)));
            if (!r.ok)
                return internalServerError(r.error);
            if (r.value["rows"].length == 0)
                return gone(notFoundErrorMsg());
            auto row = r.value["rows"][0];
            return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    gbn(row["oid"], tid, row["name"].toString, "icon-row_security_policy"), 200);
        }
        case "nodes":
        {
            auto r = conn.execute2darray(rt(NODES_SQL, tv("tid", tid)));
            if (!r.ok)
                return internalServerError(r.error);
            Value[] res;
            foreach (row; r.value["rows"].list.items)
                res ~= gbn(row["oid"], tid, row["name"].toString, "icon-row_security_policy");
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        case "properties":
        {
            Response err;
            auto data = fetchProperties(did, scid, tid, plid, err);
            if (err !is null)
                return err;
            return makeResponse(data, 200);
        }
        case "create": return create(tid);
        case "update": return update(scid, tid, plid);
        case "delete": return delete_(tid, plid);
        case "msql":
        {
            auto data = request().args.toDict;
            if (data.contains("policyowner") && data["policyowner"].isString)
                data["policyowner"] = parseJson(data["policyowner"].str);
            Value polName;
            auto sql = policyUtils.getSql(conn, data, scid, plid, tid, schema, table, polName);
            sql = sql.strip("\n").strip(" ");
            if (sql == "")
                sql = "--modified sql";
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(sql), 200);
        }
        case "sql":
        {
            auto sql = policyUtils.getReverseEngineeredSql(conn, schema, table, scid, plid, tid,
                    Value(DATABASE_LAST_SYSTEM_OID_));
            return makeResponse(Value(sql));
        }
        case "dependents": return makeResponse(getDependents(conn, plid), 200);
        case "dependencies": return makeResponse(getDependencies(conn, plid), 200);
        default: return super.callMethod(name, k);
        }
    }

    Value fetchProperties(Value did, Value scid, Value tid, Value plid, out Response err)
    {
        auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("plid", plid, "scid", scid, "policy_table_id", tid,
                "datlastsysoid", DATABASE_LAST_SYSTEM_OID_)));
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
        foreach (key; ["using", "withcheck"])
            if (data.contains(key) && !data[key].isNone)
            {
                auto s = data[key].toString;
                if (s.startsWith("(") && s.endsWith(")"))
                    data[key] = Value(s[1 .. $ - 1]);
            }
        return data;
    }

    private Response create(Value tid)
    {
        auto data = loadJsonValues(formOrJson(request()), "description");
        data["schema"] = Value(schema);
        data["table"] = Value(table);
        auto miss = missingArg(data, ["name"]);
        if (miss !is null)
            return miss;
        try
        {
            auto c = conn.executeScalar(rt(CREATE_SQL, tv("data", data, "conn", conn)));
            if (!c.ok)
                return internalServerError(c.error);
            auto p = conn.executeScalar(rt("get_position.sql", tv("tid", tid, "data", data, "conn", conn)));
            if (!p.ok)
                return internalServerError(tid.toString);
            return jsonify(Value.dictOf("node", gbn(p.value, tid, data["name"].toString, "icon-row_security_policy")));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response update(Value scid, Value tid, Value plid)
    {
        auto data = formOrJson(request());
        try
        {
            Value name;
            auto sql = policyUtils.getSql(conn, data, scid, plid, tid, schema, table, name);
            auto x = conn.executeScalar(sql);
            if (!x.ok)
                return internalServerError(x.error);
            Dict extra;
            if (data.contains("description"))
                extra = kwDict("description", data["description"]);
            return jsonify(Value.dictOf("node", gbn(plid, tid, name.toString, "icon-row_security_policy", extra)));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    Response delete_(Value tid, Value plidArg, bool onlySql = false)
    {
        bool cascade = checkCascadeOperation();
        Value data = plidArg.isNone ? formOrJson(request()) : Value.dictOf("ids", Value([plidArg]));
        foreach (plid; data["ids"].iterItems())
        {
            try
            {
                auto r = conn.executeDict(rt("get_policy_name.sql", tv("plid", plid)));
                if (!r.ok)
                    return internalServerError(r.error);
                if (r.value["rows"].length == 0)
                    return makeJsonResponse(0, Value(gettext("Error: Object not found.")), Value(notFoundErrorMsg()),
                            Value(null), Value(null), 410);
                auto result = r.value["rows"][0];
                result["schema"] = Value(schema);
                result["table"] = Value(table);
                auto sql = rt(DELETE_SQL, tv("policy_name", result["name"], "cascade", cascade, "result", result));
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
        return makeJsonResponse(1, Value(""), Value(gettext("policy dropped")));
    }
}
