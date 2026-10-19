/// `tables/triggers`: triggers of tables, views and foreign tables.
module pgadmin.browser.server_groups.servers.databases.schemas.tables.triggers;

import pgadmin.browser.common;
import pgadmin.browser.server_groups.servers.databases.schemas.utils : triggerDefinition;
import triggerUtils = pgadmin.browser.server_groups.servers.databases.schemas.tables.triggers.utils;

final class TriggerModule : CollectionNodeModule
{
    enum NODE_TYPE = "trigger";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "Triggers";
        minVer = Value(null);
        maxVer = Value(null);
        staticDir("browser/server_groups/servers/databases/schemas/tables/triggers");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => "database";
    override bool nodeInode() => true;
    override bool moduleUseTemplateJavascript() => false;

    override bool backendSupported(ServerManager manager, Dict kwargs)
    {
        if (!super.backendSupported(manager, kwargs))
            return false;
        auto conn = manager.connection(null, null, true, kwargs["did"]);
        if (!kwargs.has("vid"))
            return true;
        auto templatePath = "triggers/sql/" ~ manager.serverType ~ "/#" ~ to!string(manager.version_) ~ "#";
        auto r = conn.executeScalar(renderTemplate(templatePath ~ "/backend_support.sql", tv("vid", kwargs["vid"])));
        if (!r.ok)
            throw new HTTPException(internalServerError(r.error));
        return r.value.truthy;
    }

    override Value[] getNodes(Dict kwargs)
    {
        auto tid = kwargs.has("tid") ? kwargs["tid"] : kwargs.has("vid") ? kwargs["vid"] : kwargs["foid"];
        if (hasNodes(kwargs["sid"], kwargs["did"], kwargs["scid"], tid, Value(null), TriggerView.BASE_TEMPLATE_PATH))
            return [generateBrowserCollectionNode(tid)];
        return null;
    }

    override string[] csssnippets()
    {
        string[] snippets = [renderTemplate("triggers/css/trigger.css", ["node_type": Value(nodeType)])];
        foreach (m; submodules)
            if (auto b = cast(BrowserPluginModule) m)
                snippets ~= b.csssnippets;
        return snippets;
    }

    override void setup()
    {
        registerNodeView!TriggerView(this);
    }
}

final class TriggerView : PGChildNodeView
{
    enum BASE_TEMPLATE_PATH = "triggers/sql/{0}/#{1}#";

    string tableTemplatePath;
    string triggerFunctionTemplatePath;
    string serverType;
    string schema;
    string table;

    this()
    {
        super();
        nodeType = TriggerModule.NODE_TYPE;
        nodeLabel = "Trigger";
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
            makeOp("get_triggerfunctions", ["get": "get_trigger_functions"], ["get": "get_trigger_functions"]),
            makeOp("enable", ["put": "enable_disable_trigger"]),
        ]);
    }

    private void setUp(Dict k)
    {
        manager = getDriver().connectionManager(k["sid"].integer);
        conn = manager.connection(null, null, true, k["did"]);
        tableTemplatePath = "tables/sql/#" ~ to!string(manager.version_) ~ "#";
        templatePath = "triggers/sql/" ~ manager.serverType ~ "/#" ~ to!string(manager.version_) ~ "#";
        triggerFunctionTemplatePath = "trigger_functions/" ~ manager.serverType ~ "/sql/#" ~ to!string(manager.version_) ~ "#";
        serverType = manager.serverType;
        triggerUtils.getParent(conn, k["tid"], schema, table);
    }

    /// The trigger function a trigger calls (the only child of a trigger node).
    override Value[] getChildrenNodesFor(ServerManager mgr, Dict kwargs)
    {
        setUp(kwargs);
        Value[] nodes;
        auto scid = kwargs.has("scid") ? kwargs["scid"] : Value(null);
        auto tid = kwargs.has("tid") ? kwargs["tid"] : Value(null);
        auto trid = kwargs.has("trid") ? kwargs["trid"] : Value(null);
        try
        {
            auto r = conn.execute2darray(rt("get_function_oid.sql", tv("tid", tid, "trid", trid)));
            if (!r.ok)
                throw new HTTPException(internalServerError(r.error));
            if (r.value["rows"].length == 0)
                throw new HTTPException(gone(gettext("Could not find the specified trigger function")));
            auto fRow = r.value["rows"][0];
            auto funcSchemaOid = fRow["tfuncschoid"];
            auto f = conn.execute2darray(renderTemplate(triggerFunctionTemplatePath ~ "/" ~ NODE_SQL,
                    tv("scid", funcSchemaOid, "fnid", fRow["tfuncoid"], "conn", conn)));
            if (!f.ok)
                throw new HTTPException(internalServerError(f.error));
            if (f.value["rows"].length == 0)
                throw new HTTPException(gone(gettext("Could not find the specified trigger function")));
            auto row = f.value["rows"][0];
            auto funcName = row["name"].toString;
            if (scid != funcSchemaOid)
                funcName = fRow["tfuncschema"].toString ~ "." ~ row["name"].toString;
            auto triggerFunc = cast(CollectionNodeModule) bpModule.app.blueprints["NODE-trigger_function"];
            nodes ~= triggerFunc.generateBrowserNode(row["oid"], funcSchemaOid, gettext(funcName), "icon-trigger_function",
                    kwDict("funcowner", row["funcowner"], "language", row["lanname"], "inode", false));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            throw new HTTPException(internalServerError(e.msg));
        return nodes;
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
        setUp(k);
        auto scid = k["scid"];
        auto tid = k["tid"];
        auto trid = k.has("trid") ? k["trid"] : Value(null);
        auto showSys = bpModule.showSystemObjectsFlag;
        switch (name)
        {
        case "get_trigger_functions": return getTriggerFunctions();
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
                    gbn(row["oid"], tid, row["name"].toString, row["is_enable_trigger"] == Value("D") ? "icon-trigger-bad" : "icon-trigger"),
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
                        row["is_enable_trigger"] == Value("D") ? "icon-trigger-bad" : "icon-trigger",
                        kwDict("description", row["description"]));
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        case "properties":
        {
            Response err;
            auto data = fetchProperties(tid, trid, false, err);
            if (err !is null)
                return err;
            return makeResponse(data, 200);
        }
        case "create": return create(tid);
        case "delete": return delete_(tid, trid);
        case "update": return update(tid, trid);
        case "msql": return msql(tid, trid);
        case "sql":
        {
            auto sql = triggerUtils.getReverseEngineeredSql(conn, schema, table, tid, trid, Value(DATABASE_LAST_SYSTEM_OID_), showSys);
            return makeResponse(Value(sql));
        }
        case "enable_disable_trigger": return enableDisableTrigger(scid, tid, trid);
        case "dependents": return makeResponse(getDependents(conn, trid), 200);
        case "dependencies": return makeResponse(getDependencies(conn, trid), 200);
        default: return super.callMethod(name, k);
        }
    }

    private Response getTriggerFunctions()
    {
        Value[] res = [Value.dictOf("label", "", "value", "")];
        if (serverType == "ppas")
            res ~= Value.dictOf("label", "Inline EDB-SPL", "value", "Inline EDB-SPL");
        try
        {
            auto r = conn.execute2darray(rt("get_triggerfunctions.sql", tv("show_system_objects", bpModule.showSystemObjectsFlag)));
            if (!r.ok)
                return internalServerError(Value(res).toString);
            foreach (row; r.value["rows"].list.items)
                res ~= Value.dictOf("label", row["tfunctions"], "value", row["tfunctions"]);
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    Value fetchProperties(Value tid, Value trid, bool withoutSchema, out Response err)
    {
        auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("tid", tid, "trid", trid, "datlastsysoid", DATABASE_LAST_SYSTEM_OID_)));
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
        data = triggerUtils.getTriggerFunctionAndColumns(conn, data, tid, bpModule.showSystemObjectsFlag, withoutSchema);
        return triggerDefinition(data);
    }

    private Response create(Value tid)
    {
        auto data = loadJsonValues(formOrJson(request()), "description");
        foreach (arg; [["name", "Name"], ["tfunction", "Trigger function"]])
            if (!data.contains(arg[0]))
                return makeJsonResponse(0, Value(gettext("Could not find the required parameter ({}).").replace("{}", arg[1])),
                        Value(""), Value(null), Value(null), 410);
        data["schema"] = Value(schema);
        data["table"] = Value(table);
        if (table.length == 0)
            return gone(notFoundErrorMsg());
        try
        {
            auto c = conn.executeScalar(rt(CREATE_SQL, tv("data", data, "conn", conn)));
            if (!c.ok)
                return internalServerError(c.error);
            auto o = conn.executeScalar(rt(OID_SQL, tv("tid", tid, "data", data, "conn", conn)));
            if (!o.ok)
                return internalServerError(tid.toString);
            return jsonify(Value.dictOf("node", gbn(o.value, tid, data["name"].toString, "icon-trigger")));
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
            return makeJsonResponse(1, Value(""), Value(gettext("Trigger is dropped")));
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
            auto sql = triggerUtils.getSql(conn, data, tid, trid, Value(DATABASE_LAST_SYSTEM_OID_), bpModule.showSystemObjectsFlag, name);
            sql = sql.strip("\n").strip(" ");
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
                    d["is_enable_trigger"] == Value("D") ? "icon-trigger-bad" : "icon-trigger",
                    kwDict("description", d["description"]))));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response msql(Value tid, Value trid)
    {
        auto data = msqlData("description");
        data["schema"] = Value(schema);
        data["table"] = Value(table);
        try
        {
            Value name;
            auto sql = triggerUtils.getSql(conn, data, tid, trid, Value(DATABASE_LAST_SYSTEM_OID_), bpModule.showSystemObjectsFlag, name);
            if (sql == gettext("-- definition incomplete")) // Python: a bare string where a tuple is unpacked
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
            auto t = conn.executeScalar(rt("get_enabled_triggers.sql", tv("tid", tid)));
            if (!t.ok)
                return internalServerError(x.error);
            return makeJsonResponse(1, Value(""), Value("Trigger updated"), Value(null),
                    Value.dictOf("id", trid, "tid", tid, "scid", scid, "has_enable_triggers", t.value), 200);
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }
}
