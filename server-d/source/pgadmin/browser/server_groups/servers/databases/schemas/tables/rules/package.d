/// `tables/rules`: rewrite rules of tables and views.
module pgadmin.browser.server_groups.servers.databases.schemas.tables.rules;

import pgadmin.browser.common;
import pgadmin.browser.server_groups.servers.databases.schemas.utils : parseRuleDefinition;

final class RuleModule : CollectionNodeModule
{
    enum NODE_TYPE = "rule";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "Rules";
        minVer = Value(null);
        maxVer = Value(null);
        staticDir("browser/server_groups/servers/databases/schemas/tables/rules");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => "schema";
    override bool nodeInode() => false;
    override bool moduleUseTemplateJavascript() => false;

    override bool backendSupported(ServerManager manager, Dict kwargs)
    {
        if (!super.backendSupported(manager, kwargs))
            return false;
        auto conn = manager.connection(null, null, true, kwargs["did"]);
        if (!kwargs.has("vid"))
            return true;
        auto r = conn.executeScalar(renderTemplate("rules/sql/backend_support.sql", tv("vid", kwargs["vid"])));
        if (!r.ok)
            throw new HTTPException(internalServerError(r.error));
        return r.value.truthy;
    }

    override Value[] getNodes(Dict kwargs)
    {
        auto parent = kwargs.has("tid") ? kwargs["tid"] : kwargs["vid"];
        if (hasNodes(kwargs["sid"], kwargs["did"], kwargs["scid"], parent, Value(null), RuleView.BASE_TEMPLATE_PATH))
            return [generateBrowserCollectionNode(parent)];
        return null;
    }

    override string[] csssnippets()
    {
        string[] snippets = [
            renderTemplate("browser/css/collection.css", ["node_type": Value(nodeType)]),
            renderTemplate("rules/css/rule.css", ["node_type": Value(nodeType)]),
        ];
        foreach (m; submodules)
            if (auto b = cast(BrowserPluginModule) m)
                snippets ~= b.csssnippets;
        return snippets;
    }

    override void setup()
    {
        registerNodeView!RuleView(this);
    }
}

final class RuleView : PGChildNodeView
{
    enum BASE_TEMPLATE_PATH = "rules/sql";

    this()
    {
        super();
        nodeType = RuleModule.NODE_TYPE;
        nodeLabel = "Rule";
        parentIds = [IdSpec("int", "gid"), IdSpec("int", "sid"), IdSpec("int", "did"), IdSpec("int", "scid"),
            IdSpec("int", "tid")];
        ids = [IdSpec("int", "rid")];
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
            makeOp("configs", ["get": "configs"]),
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
        templatePath = BASE_TEMPLATE_PATH;
        auto gid = k.has("gid") ? k["gid"] : Value(null);
        auto sid = k["sid"];
        auto tid = k["tid"];
        auto rid = k.has("rid") ? k["rid"] : Value(null);
        switch (name)
        {
        case "list":
        {
            auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("tid", tid)));
            if (!r.ok)
                return internalServerError(r.error);
            return makeResponse(r.value["rows"], 200);
        }
        case "node":
        {
            auto r = conn.execute2darray(rt(NODES_SQL, tv("rid", rid)));
            if (!r.ok)
                return internalServerError(r.error);
            if (r.value["rows"].length == 0)
                return gone(notFoundErrorMsg());
            auto row = r.value["rows"][0];
            return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    gbn(row["oid"], tid, row["name"].toString, row["is_enable_rule"] == Value("D") ? "icon-rule" : "icon-rule-bad"),
                    200);
        }
        case "nodes":
        {
            auto r = conn.execute2darray(rt(NODES_SQL, tv("tid", tid)));
            if (!r.ok)
                return internalServerError(r.error);
            Value[] res;
            foreach (row; r.value["rows"].list.items)
                res ~= gbn(row["oid"], tid, row["name"].toString,
                        row.contains("is_enable_rule") && row["is_enable_rule"] == Value("D") ? "icon-rule-bad" : "icon-rule",
                        kwDict("description", row["comment"]));
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        case "properties":
        {
            Response err;
            auto data = fetchProperties(rid, err);
            if (err !is null)
                return err;
            return makeResponse(data, 200);
        }
        case "create": return create(tid);
        case "update": return update(gid, sid, tid, rid);
        case "delete": return delete_(tid, rid);
        case "msql":
        {
            Response err;
            string nm;
            auto sql = getSql(request().args.toDict, tid, rid, nm, err);
            if (err !is null)
                return err;
            sql = sql.strip("\n").strip(" ");
            if (sql == "")
                sql = "--modified SQL";
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(sql), 200);
        }
        case "sql":
        {
            auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("rid", rid)));
            if (!r.ok)
                return internalServerError(r.error);
            if (r.value["rows"].length == 0)
                return gone(notFoundErrorMsg());
            auto resData = parseRuleDefinition(r.value);
            auto sql = rt(CREATE_SQL, tv("data", resData, "display_comments", true, "add_replace_clause", true, "conn", conn));
            return makeResponse(Value(sql));
        }
        case "dependents": return makeResponse(getDependents(conn, rid), 200);
        case "dependencies": return makeResponse(getDependencies(conn, rid), 200);
        default: return super.callMethod(name, k);
        }
    }

    Value fetchProperties(Value rid, out Response err)
    {
        auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("rid", rid, "datlastsysoid", DATABASE_LAST_SYSTEM_OID_)));
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
        return parseRuleDefinition(r.value);
    }

    private Response create(Value tid)
    {
        auto data = formOrJson(request());
        auto miss = missingArg(data, ["name"]);
        if (miss !is null)
            return miss;
        try
        {
            auto c = conn.executeScalar(rt(CREATE_SQL, tv("data", data, "conn", conn)));
            if (!c.ok)
                return internalServerError(c.error);
            auto id = conn.executeScalar(rt("rule_id.sql", tv("rule_name", data["name"], "conn", conn)));
            if (!id.ok)
                return internalServerError(id.error);
            return jsonify(Value.dictOf("node", gbn(id.value, tid, data["name"].toString, "icon-rule")));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response update(Value gid, Value sid, Value tid, Value rid)
    {
        auto data = formOrJson(request());
        try
        {
            Response err;
            string name;
            auto sql = getSql(data, tid, rid, name, err);
            if (err !is null)
                return err;
            sql = sql.strip("\n").strip(" ");
            auto x = conn.executeScalar(sql);
            if (!x.ok)
                return internalServerError(x.error);
            auto extra = new Dict;
            if (data.contains("comment"))
                extra["description"] = data["comment"];
            auto icon = data.contains("is_enable_rule") && data["is_enable_rule"] == Value("D") ? "icon-rule-bad" : "icon-rule";
            return jsonify(Value.dictOf("node", gbn(rid, tid, name, icon, extra)));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    Response delete_(Value tid, Value ridArg, bool onlySql = false)
    {
        Value data = ridArg.isNone ? formOrJson(request()) : Value.dictOf("ids", Value([ridArg]));
        bool cascade = checkCascadeOperation();
        try
        {
            foreach (rid; data["ids"].iterItems())
            {
                auto r = conn.executeDict(rt(DELETE_SQL, tv("rid", rid)));
                if (!r.ok)
                    return internalServerError(r.error);
                if (r.value["rows"].length == 0)
                    return makeJsonResponse(0, Value(gettext("Error: Object not found.")), Value(notFoundErrorMsg()));
                auto rset = r.value["rows"][0];
                auto sql = rt(DELETE_SQL, tv("rulename", rset["rulename"], "relname", rset["relname"], "nspname", rset["nspname"],
                        "cascade", cascade));
                if (onlySql)
                    return Response.sqlOnly(sql);
                auto x = conn.executeScalar(sql);
                if (!x.ok)
                    return internalServerError(x.error);
            }
            return makeJsonResponse(1, Value(""), Value(gettext("Rule dropped")));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    string getSql(Value data, Value tid, Value rid, out string name, out Response err)
    {
        Value oldData;
        string sql;
        if (!rid.isNone)
        {
            auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("rid", rid)));
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
            oldData = parseRuleDefinition(r.value);
            sql = rt(UPDATE_SQL, tv("data", data, "o_data", oldData, "conn", conn));
        }
        else
            sql = rt(CREATE_SQL, tv("data", data, "conn", conn));
        if (!data.contains("name") && oldData.isNone)
            throw new Exception("cannot access local variable 'old_data' where it is not associated with a value");
        name = data.contains("name") ? data["name"].toString : oldData["name"].toString;
        return sql;
    }
}
