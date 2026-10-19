/// `tables/partitions`: the partitions of a partitioned table.
module pgadmin.browser.server_groups.servers.databases.schemas.tables.partitions;

import std.regex : regex, replaceAll;
import pgadmin.browser.common;
import pgadmin.browser.server_groups.servers.databases.schemas.utils;
import pgadmin.browser.server_groups.servers.databases.schemas.tables.utils;

/// `backend_supported(module, manager, **kwargs)` of the partitions package (also used by the index module).
Value partitionsBackendSupported(CollectionNodeModule module_, ServerManager manager, Dict kwargs)
{
    if (!module_.backendSupportedBase(manager, kwargs))
        return Value(null);
    if (!kwargs.has("tid"))
        return Value(true);
    auto conn = manager.connection(null, null, true, kwargs["did"]);
    auto templatePath = "partitions/sql/" ~ manager.serverType ~ "/#" ~ manager.serverType ~ "#" ~ to!string(manager.version_) ~ "#";
    auto r = conn.executeScalar(renderTemplate(templatePath ~ "/backend_support.sql", tv("tid", kwargs["tid"])));
    if (!r.ok)
        throw new ExecuteError(r.error);
    return r.value;
}

final class PartitionsModule : CollectionNodeModule
{
    enum NODE_TYPE = "partition";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "Partitions";
        minVer = Value(100000);
        maxVer = Value(null);
        minPpasVer = Value(100000);
        maxPpasVer = Value(null);
        staticDir("browser/server_groups/servers/databases/schemas/tables/partitions");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => "schema";
    override bool moduleUseTemplateJavascript() => false;

    override Value[] getNodes(Dict kwargs) => [generateBrowserCollectionNode(kwargs["tid"])];

    override bool backendSupported(ServerManager manager, Dict kwargs)
    {
        auto r = partitionsBackendSupported(this, manager, kwargs);
        return r.truthy;
    }

    override string[] csssnippets()
    {
        string[] snippets = [renderTemplate("partitions/css/partition.css", ["node_type": Value(nodeType)])];
        foreach (m; submodules)
            if (auto b = cast(BrowserPluginModule) m)
                snippets ~= b.csssnippets;
        return snippets;
    }

    override void setup()
    {
        submodules = null;
        // the node modules of the parent table apply to a partition too, except the partitions and columns
        foreach (parent; parentmodules)
            if (auto p = cast(CollectionNodeModule) parent)
                if (p.nodeType == "table")
                    foreach (sub; p.submodules)
                        if (auto cm = cast(CollectionNodeModule) sub)
                            if (cm.nodeType != "partition" && cm.nodeType != "column")
                                submodules ~= sub;
        registerNodeView!PartitionsView(this);
    }
}

final class PartitionsView : BaseTableView
{
    this()
    {
        super();
        nodeType = PartitionsModule.NODE_TYPE;
        nodeLabel = "Partition";
        parentIds = [IdSpec("int", "gid"), IdSpec("int", "sid"), IdSpec("int", "did"), IdSpec("int", "scid"),
            IdSpec("int", "tid")];
        ids = [IdSpec("int", "ptid")];
        setAllOps([
            makeOp("obj", ["get": "properties", "delete": "delete", "put": "update"],
                    ["get": "list", "post": "create", "delete": "delete"]),
            makeOp("delete", ["delete": "delete"], ["delete": "delete"]),
            makeOp("nodes", ["get": "nodes"], ["get": "nodes"]),
            makeOp("children", ["get": "children"]),
            makeOp("sql", ["get": "sql"]),
            makeOp("msql", ["get": "msql"], null),
            makeOp("detach", ["put": "detach"]),
            makeOp("truncate", ["put": "truncate"]),
            makeOp("set_trigger", ["put": "enable_disable_triggers"]),
            makeOp("get_table_access_methods", null, ["get": "get_table_access_methods"]),
        ]);
    }

    override Value[] getChildrenNodesFor(ServerManager mgr, Dict kwargs)
    {
        Value[] nodes;
        if (kwargs.has("ptid"))
        {
            kwargs = kwargs.copy();
            kwargs["tid"] = kwargs["ptid"];
            kwargs.pop("ptid");
        }
        foreach (m; bpModule.submodules)
        {
            auto cm = cast(CollectionNodeModule) m;
            if (cm !is null)
            {
                if (mgr !is null && cm.backendSupported(mgr, kwargs))
                    nodes ~= cm.getNodes(kwargs);
            }
            else if (auto b = cast(BrowserPluginModule) m)
                nodes ~= b.getNodes(kwargs);
        }
        auto self = cast(CollectionNodeModule) bpModule;
        if (mgr !is null && self.backendSupported(mgr, kwargs))
            nodes ~= self.getNodes(kwargs);
        return nodes;
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
        auto scid = k["scid"];
        auto tid = k["tid"];
        auto ptid = k.has("ptid") ? k["ptid"] : Value(null);
        switch (name)
        {
        case "list":
        {
            auto r = conn.executeDict(renderTemplate(partitionTemplatePath ~ "/" ~ PROPERTIES_SQL,
                    tv("did", did, "scid", scid, "tid", tid, "datlastsysoid", DATABASE_LAST_SYSTEM_OID_)));
            if (!r.ok)
                return internalServerError(r.error);
            return makeResponse(r.value["rows"], 200);
        }
        case "nodes": return nodes(scid, tid, ptid, did);
        case "properties":
        {
            Response e2;
            auto res = fetchPartitionProperties(did, scid, tid, ptid, e2);
            if (e2 !is null)
                return e2;
            if (res["rows"].length == 0)
                return gone(notFoundErrorMsg());
            return makeResponse(baseProperties(gid, sid, did, scid, ptid, res), 200);
        }
        case "sql":
        {
            string[] mainSql;
            Response e2;
            auto res = fetchPartitionProperties(did, scid, tid, ptid, e2);
            if (e2 !is null)
                return e2;
            if (res["rows"].length == 0)
                return gone(notFoundErrorMsg());
            string sqlOut;
            return getReverseEngineeredSql(did, scid, ptid, mainSql, res["rows"][0], true, false, false, sqlOut);
        }
        case "detach": return detach(scid, tid, ptid);
        case "msql": return msql(did, scid, tid, ptid);
        case "update": return update(gid, sid, did, scid, tid, ptid);
        case "truncate":
        {
            try
            {
                auto r = conn.executeDict(renderTemplate(partitionTemplatePath ~ "/" ~ PROPERTIES_SQL,
                        tv("did", did, "scid", scid, "tid", tid, "ptid", ptid, "datlastsysoid", DATABASE_LAST_SYSTEM_OID_)));
                if (!r.ok)
                    return internalServerError(r.error);
                return baseTruncate(gid, sid, did, scid, ptid, r.value);
            }
            catch (HTTPException e)
                throw e;
            catch (Exception e)
                return internalServerError(e.msg);
        }
        case "delete": return delete_(did, scid, tid, ptid);
        case "enable_disable_triggers": return enableDisableTriggers(did, scid, tid, ptid);
        case "get_table_access_methods":
            return makeJsonResponse(1, Value(""), Value(""), Value(null), getAccessMethods(), 200);
        default: return super.callMethod(name, k);
        }
    }

    private Response nodes(Value scid, Value tid, Value ptid, Value did)
    {
        auto r = conn.execute2darray(renderTemplate(partitionTemplatePath ~ "/" ~ NODES_SQL,
                tv("scid", scid, "tid", tid, "ptid", ptid, "did", did)));
        if (!r.ok)
            return internalServerError(r.error);
        Value browserNode(Value row)
        {
            auto icon = getPartitionIconCssClass(row);
            return gbn(row["oid"], tid, row["name"].toString, icon, kwDict("tigger_count", row["triggercount"],
                    "has_enable_triggers", row["has_enable_triggers"], "is_partitioned", row["is_partitioned"],
                    "parent_schema_id", scid, "schema_id", row["schema_id"], "schema_name", row["schema_name"],
                    "description", row["description"],
                    "is_detach_pending", row.contains("inhdetachpending") ? row["inhdetachpending"] : Value(false)));
        }

        if (!ptid.isNone)
        {
            if (r.value["rows"].length == 0)
                return gone(notFoundErrorMsg());
            return makeJsonResponse(1, Value(""), Value(""), Value(null), browserNode(r.value["rows"][0]), 200);
        }
        Value[] res;
        foreach (row; r.value["rows"].list.items)
            res ~= browserNode(row);
        return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
    }

    private Value fetchPartitionProperties(Value did, Value scid, Value tid, Value ptid, out Response err)
    {
        try
        {
            auto r = conn.executeDict(renderTemplate(partitionTemplatePath ~ "/" ~ PROPERTIES_SQL,
                    tv("did", did, "scid", scid, "tid", tid, "ptid", ptid, "datlastsysoid", DATABASE_LAST_SYSTEM_OID_)));
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
            updateAutovacuumProperties(r.value["rows"][0]);
            return r.value;
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
        {
            err = internalServerError(e.msg);
            return Value(null);
        }
    }

    private Response detach(Value scid, Value tid, Value ptid)
    {
        auto data = formOrJson(request());
        auto mode = data.dict.get("mode", Value(null));
        auto parentSchema = conn.executeScalar(tt("get_schema.sql", tv("conn", conn, "scid", scid)));
        if (!parentSchema.ok)
            return internalServerError(parentSchema.error);
        auto tableName = conn.executeScalar(tt("get_table.sql", tv("conn", conn, "scid", scid, "tid", tid)));
        if (!tableName.ok)
            return internalServerError(tableName.error);
        auto pscid = conn.executeScalar(tt(GET_SCHEMA_OID_SQL, tv("tid", ptid, "conn", conn)));
        if (!pscid.ok)
            return internalServerError(scid.toString);
        auto partitionSchema = conn.executeScalar(tt("get_schema.sql", tv("conn", conn, "scid", pscid.value)));
        if (!partitionSchema.ok)
            return internalServerError(partitionSchema.error);
        auto partitionName = conn.executeScalar(tt("get_table.sql", tv("conn", conn, "scid", pscid.value, "tid", ptid)));
        if (!partitionName.ok)
            return internalServerError(partitionName.error);
        try
        {
            auto temp = Value.dictOf("parent_schema", parentSchema.value, "partitioned_table_name", tableName.value,
                    "schema", partitionSchema.value, "name", partitionName.value, "mode", mode);
            auto x = conn.executeScalar(renderTemplate(partitionTemplatePath ~ "/detach.sql", tv("data", temp, "conn", conn)));
            if (!x.ok)
                return internalServerError(x.error);
            return makeJsonResponse(1, Value(""), Value(gettext("Partition detached.")), Value(null),
                    Value.dictOf("id", ptid, "scid", scid), 200);
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response msql(Value did, Value scid, Value tid, Value ptid)
    {
        auto data = Value.newDict();
        foreach (key; request().args.keys)
        {
            auto v = request().args.get(key);
            data[key] = key == "description" ? Value(v) : tryParseJson(v, Value(v));
        }
        Value res = Value(null);
        if (!ptid.isNone)
        {
            Response err;
            res = fetchPartitionProperties(did, scid, tid, ptid, err);
            if (err !is null)
                return err;
        }
        string name;
        auto sql = getSql(did, scid, ptid, data, res, name);
        sql = replaceAll(sql, regex("\n{2,}"), "\n\n").strip("\n");
        if (sql == "")
            sql = "--modified SQL";
        return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(sql), 200);
    }

    private Response update(Value gid, Value sid, Value did, Value scid, Value tid, Value ptid)
    {
        auto data = loadJsonValues(formOrJson(request()), "description");
        try
        {
            Response err;
            auto res = fetchPartitionProperties(did, scid, tid, ptid, err);
            if (err !is null)
                return err;
            return baseUpdate(gid, sid, did, scid, ptid, data, res, tid);
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response delete_(Value did, Value scid, Value tid, Value ptidArg)
    {
        Value data = ptidArg.isNone ? formOrJson(request()) : Value.dictOf("ids", Value([ptidArg]));
        try
        {
            foreach (ptid; data["ids"].iterItems())
            {
                auto r = conn.executeDict(renderTemplate(partitionTemplatePath ~ "/" ~ PROPERTIES_SQL,
                        tv("did", did, "scid", scid, "tid", tid, "ptid", ptid, "datlastsysoid", DATABASE_LAST_SYSTEM_OID_)));
                if (!r.ok)
                    return internalServerError(r.error);
                if (r.value["rows"].length == 0)
                    return makeJsonResponse(0, Value(gettext("Error: Object not found.")),
                            Value(gettext("The specified partition could not be found.\n")));
                auto err = baseDelete(r.value);
                if (err !is null)
                    return internalServerError(err);
            }
            return makeJsonResponse(1, Value(""), Value(gettext("Partition dropped")));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response enableDisableTriggers(Value did, Value scid, Value tid, Value ptid)
    {
        auto data = formOrJson(request());
        auto isEnableTrigger = data["is_enable_trigger"];
        try
        {
            auto r = conn.executeDict(renderTemplate(partitionTemplatePath ~ "/" ~ PROPERTIES_SQL,
                    tv("did", did, "scid", scid, "tid", tid, "ptid", ptid, "datlastsysoid", DATABASE_LAST_SYSTEM_OID_)));
            if (!r.ok)
                return internalServerError(r.error);
            auto row = r.value["rows"][0];
            auto x = conn.executeScalar(tt("enable_disable_trigger.sql", tv("data", row, "is_enable_trigger", isEnableTrigger)));
            if (!x.ok)
                return internalServerError(x.error);
            return makeJsonResponse(1, Value(""), Value(isEnableTrigger == Value("D")
                    ? gettext("Trigger(s) have been disabled") : gettext("Trigger(s) have been enabled")), Value(null),
                    Value.dictOf("id", ptid, "scid", scid), 200);
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }
}
