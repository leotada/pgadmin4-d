/// `tables/compound_triggers`: compound triggers (EDB Postgres Advanced Server 12+).
module pgadmin.browser.server_groups.servers.databases.schemas.tables.compound_triggers;

import pgadmin.browser.common;
import pgadmin.browser.server_groups.servers.databases.schemas.utils : triggerDefinition;
import ctUtils = pgadmin.browser.server_groups.servers.databases.schemas.tables.compound_triggers.utils;

final class CompoundTriggerModule : CollectionNodeModule
{
    enum NODE_TYPE = "compound_trigger";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "Compound Triggers";
        minVer = Value(120000);
        minPpasVer = Value(120000);
        maxVer = Value(null);
        serverTypes = ["ppas"];
        staticDir("browser/server_groups/servers/databases/schemas/tables/compound_triggers");
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
        if (!kwargs.has("vid"))
            return true;
        auto templatePath = "compound_triggers/sql/" ~ manager.serverType ~ "/#" ~ to!string(manager.version_) ~ "#";
        auto r = conn.executeScalar(renderTemplate(templatePath ~ "/backend_support.sql", tv("vid", kwargs["vid"])));
        if (!r.ok)
            throw new HTTPException(internalServerError(r.error));
        return r.value.truthy;
    }

    override Value[] getNodes(Dict kwargs)
    {
        auto parent = kwargs.has("tid") ? kwargs["tid"] : kwargs["vid"];
        if (hasNodes(kwargs["sid"], kwargs["did"], kwargs["scid"], parent, Value(null), CompoundTriggerView.BASE_TEMPLATE_PATH))
            return [generateBrowserCollectionNode(parent)];
        return null;
    }

    override string[] csssnippets()
    {
        string[] snippets = [renderTemplate("compound_triggers/css/compound_trigger.css", ["node_type": Value(nodeType)])];
        foreach (m; submodules)
            if (auto b = cast(BrowserPluginModule) m)
                snippets ~= b.csssnippets;
        return snippets;
    }

    override void setup()
    {
        registerNodeView!CompoundTriggerView(this);
    }
}

final class CompoundTriggerView : PGChildNodeView
{
    enum BASE_TEMPLATE_PATH = "compound_triggers/sql/{0}/#{1}#";

    string schema;
    string table;

    this()
    {
        super();
        nodeType = CompoundTriggerModule.NODE_TYPE;
        nodeLabel = "Compound Trigger";
        parentIds = [IdSpec("int", "gid"), IdSpec("int", "sid"), IdSpec("int", "did"), IdSpec("int", "scid"),
            IdSpec("int", "tid")];
        ids = [IdSpec("int", "trid")];
        setAllOps([
            makeOp("obj", ["get": "properties", "delete": "delete", "put": "update"],
                    ["get": "list", "post": "create", "delete": "delete"]),
            makeOp("delete", ["delete": "delete"], ["delete": "delete"]),
            makeOp("children", ["get": "children"]),
            makeOp("nodes", ["get": "node"], ["get": "nodes"]),
            makeOp("sql", ["get": "sql"]),
            makeOp("msql", ["get": "msql"], ["get": "msql"]),
            makeOp("stats", ["get": "statistics"]),
            makeOp("dependency", ["get": "dependencies"]),
            makeOp("dependent", ["get": "dependents"]),
            makeOp("enable", ["put": "enable_disable_trigger"]),
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
        templatePath = "compound_triggers/sql/" ~ manager.serverType ~ "/#" ~ to!string(manager.version_) ~ "#";
        ctUtils.getParent(conn, k["tid"], schema, table);
        auto scid = k["scid"];
        auto tid = k["tid"];
        auto trid = k.has("trid") ? k["trid"] : Value(null);
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
            auto r = conn.execute2darray(rt(NODES_SQL, tv("tid", tid, "trid", trid)));
            if (!r.ok)
                return internalServerError(r.error);
            if (r.value["rows"].length == 0)
                return gone(notFoundErrorMsg());
            auto row = r.value["rows"][0];
            return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    gbn(row["oid"], tid, row["name"].toString,
                    row["is_enable_trigger"] == Value("D") ? "icon-compound_trigger-bad" : "icon-compound_trigger"), 200);
        }
        case "nodes":
        {
            auto r = conn.execute2darray(rt(NODES_SQL, tv("tid", tid)));
            if (!r.ok)
                return internalServerError(r.error);
            Value[] res;
            foreach (row; r.value["rows"].list.items)
                res ~= gbn(row["oid"], tid, row["name"].toString,
                        row["is_enable_trigger"] == Value("D") ? "icon-compound_trigger-bad" : "icon-compound_trigger",
                        kwDict("description", row["description"]));
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        case "properties":
        {
            auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("tid", tid, "trid", trid,
                    "datlastsysoid", DATABASE_LAST_SYSTEM_OID_)));
            if (!r.ok)
                return internalServerError(r.error);
            if (r.value["rows"].length == 0)
                return gone(notFoundErrorMsg());
            auto data = Value(r.value["rows"][0].dict.copy());
            if (data["tgattr"].toString.length >= 1)
                data["columns"] = ctUtils.getColumnDetails(conn, tid, data["tgattr"].toString.split(" ").join(", "));
            return makeResponse(triggerDefinition(data), 200);
        }
        case "create": return create(tid);
        case "delete": return delete_(tid, trid);
        case "update": return update(tid, trid);
        case "msql":
        {
            auto data = msqlData("description");
            data["schema"] = Value(schema);
            data["table"] = Value(table);
            try
            {
                Value nm;
                auto sql = ctUtils.getSql(conn, data, tid, trid, Value(DATABASE_LAST_SYSTEM_OID_), nm);
                if (sql == gettext("-- definition incomplete"))
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
        case "sql":
        {
            try
            {
                auto sql = ctUtils.getReverseEngineeredSql(conn, schema, table, tid, trid, Value(DATABASE_LAST_SYSTEM_OID_));
                return makeResponse(Value(sql));
            }
            catch (HTTPException e)
                throw e;
            catch (Exception e)
                return internalServerError(e.msg);
        }
        case "enable_disable_trigger": return enableDisableTrigger(scid, tid, trid);
        case "dependents": return makeResponse(getDependents(conn, trid), 200);
        case "dependencies": return makeResponse(getDependencies(conn, trid), 200);
        default: return super.callMethod(name, k);
        }
    }

    private Response create(Value tid)
    {
        auto data = loadJsonValues(formOrJson(request()), "description");
        if (!data.contains("name"))
            return makeJsonResponse(0, Value(gettext("Could not find the required parameter ({}).").replace("{}", "Name")),
                    Value(""), Value(null), Value(null), 410);
        data["schema"] = Value(schema);
        data["table"] = Value(table);
        try
        {
            auto c = conn.executeScalar(rt(CREATE_SQL, tv("data", data, "conn", conn)));
            if (!c.ok)
                return internalServerError(c.error);
            auto o = conn.executeScalar(rt(OID_SQL, tv("tid", tid, "data", data, "conn", conn)));
            if (!o.ok)
                return internalServerError(tid.toString);
            return jsonify(Value.dictOf("node", gbn(o.value, tid, data["name"].toString, "icon-compound_trigger")));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    Response delete_(Value tid, Value tridArg, bool onlySql = false)
    {
        Value data = tridArg.isNone ? formOrJson(request()) : Value.dictOf("ids", Value([tridArg]));
        bool cascade = checkCascadeOperation();
        try
        {
            foreach (trid; data["ids"].iterItems())
            {
                auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("tid", tid, "trid", trid, "datlastsysoid", DATABASE_LAST_SYSTEM_OID_)));
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
            return makeJsonResponse(1, Value(""), Value(gettext("Compound Trigger is dropped")));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response update(Value tid, Value trid)
    {
        auto data = formOrJson(request());
        try
        {
            data["schema"] = Value(schema);
            data["table"] = Value(table);
            Value name;
            auto sql = ctUtils.getSql(conn, data, tid, trid, Value(DATABASE_LAST_SYSTEM_OID_), name).strip("\n").strip(" ");
            auto x = conn.executeScalar(sql);
            if (!x.ok)
                return internalServerError(x.error);
            auto o = conn.executeScalar(rt(OID_SQL, tv("tid", tid, "data", data, "conn", conn)));
            if (!o.ok)
                return internalServerError(o.error);
            auto newTrid = o.value;
            auto p = conn.executeDict(rt(PROPERTIES_SQL, tv("tid", tid, "trid", newTrid, "datlastsysoid", DATABASE_LAST_SYSTEM_OID_)));
            if (!p.ok)
                return internalServerError(p.error);
            if (p.value["rows"].length == 0)
                return gone(notFoundErrorMsg());
            auto d = p.value["rows"][0];
            return jsonify(Value.dictOf("node", gbn(newTrid, tid, name.toString,
                    d["is_enable_trigger"] == Value("D") ? "icon-compound_trigger-bad" : "icon-compound_trigger",
                    kwDict("description", d["description"]))));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response enableDisableTrigger(Value scid, Value tid, Value trid)
    {
        auto data = formOrJson(request());
        auto isEnableTrigger = data["is_enable_trigger"];
        try
        {
            auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("tid", tid, "trid", trid, "datlastsysoid", DATABASE_LAST_SYSTEM_OID_)));
            if (!r.ok)
                return internalServerError(r.error);
            if (r.value["rows"].length == 0)
                return gone(notFoundErrorMsg());
            auto oData = Value(r.value["rows"][0].dict.copy());
            oData["is_enable_trigger"] = isEnableTrigger;
            oData["schema"] = Value(schema);
            oData["table"] = Value(table);
            auto x = conn.executeScalar(rt("enable_disable_trigger.sql", tv("data", oData, "conn", conn)));
            if (!x.ok)
                return internalServerError(x.error);
            return makeJsonResponse(1, Value(""), Value("Compound Trigger updated"), Value(null),
                    Value.dictOf("id", trid, "tid", tid, "scid", scid), 200);
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }
}
