/// `databases/event_triggers`: event triggers.
module pgadmin.browser.server_groups.servers.databases.event_triggers;

import std.regex : regex, matchFirst, replaceAll;
import pgadmin.browser.common;

final class EventTriggerModule : CollectionNodeModule
{
    enum NODE_TYPE = "event_trigger";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "Event Triggers";
        minVer = Value(90300);
        maxVer = Value(null);
        staticDir("browser/server_groups/servers/databases/event_triggers");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => "database";
    override bool nodeInode() => false;
    override bool moduleUseTemplateJavascript() => false;

    override Value[] getNodes(Dict kwargs)
    {
        if (hasNodes(kwargs["sid"], kwargs["did"], Value(null), Value(null), Value(null), EventTriggerView.BASE_TEMPLATE_PATH))
            return [generateBrowserCollectionNode(kwargs["sid"])]; // sic: the Python code passes the server id
        return null;
    }

    override void setup()
    {
        registerNodeView!EventTriggerView(this);
    }
}

final class EventTriggerView : PGChildNodeView
{
    enum BASE_TEMPLATE_PATH = "event_triggers/sql/#{0}#";
    enum NODE_ICON = "icon-event_trigger";

    private static immutable string[2][] requiredArgs = [["name", "Name"], ["eventowner", "Owner"],
        ["eventfunname", "Trigger function"], ["enabled", "Enabled status"], ["eventname", "Events"]];

    this()
    {
        super();
        nodeType = EventTriggerModule.NODE_TYPE;
        nodeLabel = "Event Trigger";
        parentIds = [IdSpec("int", "gid"), IdSpec("int", "sid"), IdSpec("int", "did")];
        ids = [IdSpec("int", "etid")];
        setAllOps([
            makeOp("obj", ["get": "properties", "delete": "delete", "put": "update"],
                    ["get": "list", "post": "create", "delete": "delete"]),
            makeOp("nodes", ["get": "node"], ["get": "nodes"]),
            makeOp("children", ["get": "children"]),
            makeOp("sql", ["get": "sql"]),
            makeOp("msql", ["get": "msql"], ["get": "msql"]),
            makeOp("stats", ["get": "statistics"]),
            makeOp("dependency", ["get": "dependencies"]),
            makeOp("dependent", ["get": "dependents"]),
            makeOp("fopts", ["get": "get_event_funcs"], ["get": "get_event_funcs"]),
        ]);
    }

    private static Value formatter(Value result)
    {
        Value[] l;
        if (result.contains("seclabels") && !result["seclabels"].isNone)
            foreach (sec; result["seclabels"].iterItems())
            {
                auto m = matchFirst(sec.toString, regex(`([^=]+)=(.*$)`));
                l ~= Value.dictOf("provider", m[1].idup, "label", m[2].idup);
            }
        result["seclabels"] = Value(l);
        return result;
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
        auto etid = k.has("etid") ? k["etid"] : Value(null);
        switch (name)
        {
        case "list":
        {
            auto r = conn.executeDict(rt(PROPERTIES_SQL));
            if (!r.ok)
                return internalServerError(r.error);
            return makeResponse(r.value["rows"], 200);
        }
        case "nodes":
        {
            auto r = conn.execute2darray(rt(NODES_SQL));
            if (!r.ok)
                return internalServerError(r.error);
            Value[] res;
            foreach (row; r.value["rows"].list.items)
                res ~= gbn(row["oid"], did, row["name"].toString, NODE_ICON, kwDict("description", row["comment"]));
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        case "node":
        {
            auto r = conn.execute2darray(rt(NODES_SQL, tv("etid", etid)));
            if (!r.ok)
                return internalServerError(r.error);
            foreach (row; r.value["rows"].list.items)
                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                        gbn(row["oid"], did, row["name"].toString, NODE_ICON), 200);
            return gone(gettext("Could not find the specified event trigger."));
        }
        case "properties":
        {
            Response e2;
            auto res = fetchProperties(did, etid, e2);
            if (e2 !is null)
                return e2;
            return makeResponse(res, 200);
        }
        case "create": return create(did);
        case "update": return update(gid, sid, did, etid);
        case "delete": return delete_(etid);
        case "msql":
        {
            auto data = Value.newDict();
            foreach (key; request().args.keys)
                data[key] = tryParseJson(request().args.get(key), Value(request().args.get(key)));
            try
            {
                Response e2;
                auto sql = getSql(data, etid, e2);
                if (e2 !is null)
                    return e2;
                sql = replaceAll(sql, regex("\n{2,}"), "\n\n");
                if (sql == "")
                    sql = "--modified SQL";
                return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(sql), 200);
            }
            catch (HTTPException e)
                throw e;
            catch (Exception e)
                return internalServerError(e.msg);
        }
        case "sql": return sqlView(did, etid);
        case "get_event_funcs":
        {
            Value[] res = [Value.dictOf("label", "", "value", "")];
            auto r = conn.execute2darray(rt("eventfunctions.sql"));
            if (!r.ok)
                return internalServerError(r.error);
            foreach (row; r.value["rows"].list.items)
                res ~= Value.dictOf("label", row["tfname"], "value", row["tfname"]);
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        case "dependents": return makeResponse(getDependents(conn, etid), 200);
        case "dependencies": return makeResponse(getDependencies(conn, etid), 200);
        default: return super.callMethod(name, k);
        }
    }

    Value fetchProperties(Value did, Value etid, out Response err)
    {
        auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("etid", etid, "conn", conn)));
        if (!r.ok)
        {
            err = internalServerError(r.error);
            return Value(null);
        }
        if (r.value["rows"].length == 0)
        {
            err = gone(gettext("Could not find the event trigger information."));
            return Value(null);
        }
        auto result = r.value["rows"][0];
        result["is_sys_obj"] = Value(result["oid"].integer <= DATABASE_LAST_SYSTEM_OID_ || datistemplate);
        return formatter(result);
    }

    private static string pyListRepr(string[] items)
    {
        string[] q;
        foreach (i; items)
            q ~= "'" ~ i ~ "'";
        return "[" ~ q.join(", ") ~ "]";
    }

    private Response create(Value did)
    {
        auto data = formOrJson(request());
        string[] missing;
        foreach (a; requiredArgs)
            if (!data.contains(a[0]))
                missing ~= a[1];
        if (missing.length)
            return makeJsonResponse(0, Value(gettext("Could not find the required parameter ({}).").replace("{}", pyListRepr(missing))),
                    Value(""), Value(null), Value(null), 400);
        try
        {
            auto c = conn.executeScalar(rt(CREATE_SQL, tv("data", data, "conn", conn)));
            if (!c.ok)
                return internalServerError(c.error);
            auto g = conn.executeScalar(rt(GRANT_SQL, tv("data", data, "conn", conn)).strip("\n").strip(" "));
            if (!g.ok)
                return internalServerError(g.error);
            auto o = conn.executeScalar(rt(OID_SQL, tv("data", data, "conn", conn)));
            if (!o.ok)
                return internalServerError(o.error);
            return jsonify(Value.dictOf("node", gbn(o.value, did, data["name"].toString, NODE_ICON)));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response update(Value gid, Value sid, Value did, Value etid)
    {
        auto data = formOrJson(request());
        try
        {
            Response e2;
            auto sql = getSql(data, etid, e2);
            if (e2 !is null)
                return e2;
            if (sql != "")
            {
                auto x = conn.executeScalar(sql);
                if (!x.ok)
                    return internalServerError(x.error);
                auto o = conn.executeScalar(rt(OID_SQL, tv("data", data, "conn", conn)));
                auto newId = o.value;
                Dict extra;
                if (data.contains("comment"))
                    extra = kwDict("description", data["comment"]);
                return jsonify(Value.dictOf("node", gbn(newId, did, data["name"].toString, NODE_ICON, extra)));
            }
            return makeJsonResponse(1, Value(""), Value("Nothing to update"), Value(null),
                    Value.dictOf("id", etid, "sid", sid, "gid", gid, "did", did), 200);
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    Response delete_(Value etidArg, bool onlySql = false)
    {
        bool cascade = cmd == "delete";
        Value data = etidArg.isNone ? formOrJson(request()) : Value.dictOf("ids", Value([etidArg]));
        try
        {
            foreach (etid; data["ids"].iterItems())
            {
                auto n = conn.executeScalar(rt(DELETE_SQL, tv("etid", etid)));
                if (!n.ok)
                    return internalServerError(n.error);
                if (n.value.isNone)
                    return makeJsonResponse(0, Value(gettext("Error: Object not found.")),
                            Value(gettext("The specified event trigger could not be found.\n")), Value(null), Value(null), 410);
                auto sql = rt(DELETE_SQL, tv("name", n.value, "cascade", cascade));
                if (onlySql)
                    return Response.sqlOnly(sql);
                auto x = conn.executeScalar(sql);
                if (!x.ok)
                    return internalServerError(x.error);
            }
            return makeJsonResponse(1, Value(""), Value(gettext("Event trigger dropped")));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    string getSql(Value data, Value etid, out Response err)
    {
        string sql;
        if (!etid.isNone)
        {
            auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("etid", etid)));
            if (!r.ok)
            {
                err = internalServerError(r.error);
                return null;
            }
            if (r.value["rows"].length == 0)
            {
                err = gone(gettext("Could not find the event trigger information."));
                return null;
            }
            auto oldData = formatter(r.value["rows"][0]);
            if (!data.contains("name"))
                data["name"] = oldData["name"];
            sql = rt(UPDATE_SQL, tv("data", data, "o_data", oldData, "conn", conn));
        }
        else
        {
            bool miss;
            foreach (a; requiredArgs)
                if (!data.contains(a[0]))
                    miss = true;
            if (miss) // Python then calls `.strip()` on the error response
                throw new Exception("'Response' object has no attribute 'strip'");
            sql = rt(CREATE_SQL, tv("data", data));
            sql ~= "\n";
            sql ~= rt(GRANT_SQL, tv("data", data));
            sql = sql.strip("\n").strip(" ");
        }
        return sql.strip("\n");
    }

    private Response sqlView(Value did, Value etid, bool jsonResp = true)
    {
        auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("etid", etid)));
        if (!r.ok)
            return internalServerError(r.error);
        if (r.value["rows"].length == 0)
            return gone(gettext("Could not find the specified event trigger on the server."));
        auto result = formatter(r.value["rows"][0]);
        auto sql = rt(CREATE_SQL, tv("data", result, "conn", conn));
        sql ~= "\n\n";
        sql ~= rt(GRANT_SQL, tv("data", result, "conn", conn));
        auto d = conn.executeScalar(rt("get_db.sql", tv("did", did)));
        if (!d.ok)
            return internalServerError(d.error);
        auto header = "-- Event Trigger: " ~ result["name"].toString ~ " on database " ~ d.value.toString ~ "\n\n-- ";
        header ~= rt(DELETE_SQL, tv("name", result["name"]));
        header ~= "\n";
        sql = replaceAll(header ~ sql, regex("\n{2,}"), "\n\n");
        if (!jsonResp)
            return Response.sqlOnly(sql);
        return makeResponse(Value(sql));
    }
}
