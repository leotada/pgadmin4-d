/// `databases/subscriptions`: logical replication subscriptions.
module pgadmin.browser.server_groups.servers.databases.subscriptions;

import pgadmin.browser.common;
import pgadmin.db.pgconn : PgConnection, PgError;
import pgadmin.utils.paths : getCompleteFilePath;

final class SubscriptionModule : CollectionNodeModule
{
    enum NODE_TYPE = "subscription";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "Subscriptions";
        minVer = Value(100000);
        minPpasVer = Value(100000);
        maxVer = Value(null);
        staticDir("browser/server_groups/servers/databases/subscriptions");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => "database";
    override bool nodeInode() => false;
    override bool moduleUseTemplateJavascript() => false;

    override Value[] getNodes(Dict kwargs)
    {
        if (hasNodes(kwargs["sid"], kwargs["did"], Value(null), Value(null), Value(null), SubscriptionView.BASE_TEMPLATE_PATH))
            return [generateBrowserCollectionNode(kwargs["did"])];
        return null;
    }

    override void setup()
    {
        registerNodeView!SubscriptionView(this);
    }
}

final class SubscriptionView : PGChildNodeView
{
    enum BASE_TEMPLATE_PATH = "subscriptions/sql/#{0}#";

    this()
    {
        super();
        nodeType = SubscriptionModule.NODE_TYPE;
        parentIds = [IdSpec("int", "gid"), IdSpec("int", "sid"), IdSpec("int", "did")];
        ids = [IdSpec("int", "subid")];
        setAllOps([
            makeOp("obj", ["get": "properties", "delete": "delete", "put": "update"],
                    ["get": "list", "post": "create", "delete": "delete"]),
            makeOp("nodes", ["get": "node"], ["get": "nodes"]),
            makeOp("sql", ["get": "sql"]),
            makeOp("msql", ["get": "msql"], ["get": "msql"]),
            makeOp("stats", ["get": "statistics"], ["get": "statistics"]),
            makeOp("dependency", ["get": "dependencies"]),
            makeOp("dependent", ["get": "dependents"]),
            makeOp("get_publications", null, ["get": "get_publications"]),
            makeOp("delete", ["delete": "delete"], ["delete": "delete"]),
        ]);
    }

    private static string notFoundSub() => gettext("Could not find the subscription information.");

    /// `streaming_mapping` / `two_phase_mapping` (a KeyError carries the repr of the key).
    private static Value mapped(string which, Value v)
    {
        string k = v.isNone ? "None" : v.toString;
        if (which == "streaming")
        {
            switch (k)
            {
            case "p": return Value("parallel");
            case "t": return Value("on");
            case "f": return Value("off");
            default: break;
            }
        }
        else
        {
            switch (k)
            {
            case "p", "e": return Value(true);
            case "d": return Value(false);
            default: break;
            }
        }
        throw new Exception(v.isNone ? "None" : "'" ~ k ~ "'");
    }

    private void mapRow(Value row)
    {
        if (manager.version_ >= 150000)
            row["two_phase"] = mapped("two_phase", row["two_phase"]);
        if (manager.version_ >= 160000)
            row["streaming"] = mapped("streaming", row["streaming"]);
    }

    override Response callMethod(string name, Dict k)
    {
        if (!isAuthenticated())
            return unauthorisedResponse();
        auto err = standardPrecondition(k, name, BASE_TEMPLATE_PATH);
        if (err !is null)
            return err;
        auto did = k["did"];
        auto subid = k.has("subid") ? k["subid"] : Value(null);
        switch (name)
        {
        case "list":
        {
            auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("did", did)));
            if (!r.ok)
                return internalServerError(r.error);
            return makeResponse(r.value["rows"], 200);
        }
        case "nodes":
        {
            auto r = conn.execute2darray(rt(NODES_SQL, tv("did", did)));
            if (!r.ok)
                return internalServerError(r.error);
            Value[] res;
            foreach (row; r.value["rows"].list.items)
                res ~= gbn(row["oid"], did, row["name"].toString, "icon-subscription");
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        case "node":
        {
            auto r = conn.execute2darray(rt(PROPERTIES_SQL, tv("subid", subid)));
            if (!r.ok)
                return internalServerError(r.error);
            foreach (row; r.value["rows"].list.items)
                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                        gbn(row["oid"], did, row["name"].toString, "icon-subscription"), 200);
            return gone(gettext("Could not find the specified subscription."));
        }
        case "properties":
        {
            Response e2;
            auto res = fetchProperties(did, subid, e2);
            if (e2 !is null)
                return e2;
            return makeResponse(res, 200);
        }
        case "statistics":
        {
            auto r = conn.executeDict(rt("stats.sql", tv("subid", subid, "did", did, "conn", conn)));
            return makeJsonResponse(1, Value(""), Value(""), Value(null), r.ok ? r.value : Value(r.error), 200);
        }
        case "create": return create(did);
        case "update": return update(did, subid);
        case "delete": return delete_(subid);
        case "msql":
        {
            auto data = msqlData("description");
            try
            {
                Response e2;
                string nm;
                auto sql = getSql(data, subid, "msql", nm, e2);
                if (e2 !is null)
                    return e2;
                if (sql == "")
                    sql = "--modified SQL";
                return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(sql), 200);
            }
            catch (HTTPException e)
                throw e;
            catch (Exception e)
                return internalServerError(e.msg);
        }
        case "sql": return sqlView(subid);
        case "dependents": return makeResponse(getDependents(conn, subid), 200);
        case "dependencies":
        {
            auto n = conn.executeScalar(rt(DELETE_SQL, tv("subid", subid, "conn", conn)));
            auto t = conn.executeDict(rt("dependencies.sql", tv("subname", n.value, "conn", conn)));
            if (!t.ok)
                return internalServerError(t.error);
            Value[] res;
            foreach (p; t.value["rows"][0]["pub"].iterItems())
                res ~= Value.dictOf("type", "publication", "name", p, "field", "normal");
            return makeResponse(Value(res), 200);
        }
        case "get_publications": return getPublications(did);
        default: return super.callMethod(name, k);
        }
    }

    Value fetchProperties(Value did, Value subid, out Response err)
    {
        auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("subid", subid, "did", did)));
        if (!r.ok)
        {
            err = internalServerError(r.error);
            return Value(null);
        }
        if (r.value["rows"].length == 0)
        {
            err = gone(notFoundSub());
            return Value(null);
        }
        mapRow(r.value["rows"][0]);
        return r.value["rows"][0];
    }

    private Response create(Value did)
    {
        auto data = formOrJson(request());
        auto miss = missingArg(data, ["name"]);
        if (miss !is null)
            return miss;
        try
        {
            auto c = conn.executeDict(rt(CREATE_SQL, tv("data", data, "dummy", false, "conn", conn)));
            if (!c.ok)
                return internalServerError(c.error);
            auto p = conn.executeDict(rt("get_position.sql", tv("conn", conn, "subname", data["name"], "did", did)));
            if (!p.ok)
                return internalServerError(p.error);
            auto row = p.value["rows"][0];
            return jsonify(Value.dictOf("node", gbn(row["oid"], did, row["name"].toString, "icon-subscription")));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response update(Value did, Value subid)
    {
        auto data = formOrJson(request());
        try
        {
            Response e2;
            string name;
            auto sql = getSql(data, subid, null, name, e2);
            if (e2 !is null)
                return e2;
            sql = sql.strip("\n").strip(" ");
            auto x = conn.executeDict(sql);
            if (!x.ok)
                return internalServerError(x.error);
            return jsonify(Value.dictOf("node", gbn(subid, did, name, "icon-" ~ nodeType)));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    Response delete_(Value subidArg, bool onlySql = false)
    {
        Value data = subidArg.isNone ? formOrJson(request()) : Value.dictOf("ids", Value([subidArg]));
        bool cascade = checkCascadeOperation();
        try
        {
            foreach (subid; data["ids"].iterItems())
            {
                auto n = conn.executeScalar(rt(DELETE_SQL, tv("subid", subid, "conn", conn)));
                if (!n.ok)
                    return internalServerError(n.error);
                auto sql = rt(DELETE_SQL, tv("subname", n.value, "cascade", cascade, "conn", conn));
                if (onlySql)
                    return Response.sqlOnly(sql);
                auto x = conn.executeScalar(sql);
                if (!x.ok)
                    return internalServerError(x.error);
            }
            return makeJsonResponse(1, Value(""), Value(gettext("Subscription dropped")));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    string getSql(Value data, Value subid, string operation, out string name, out Response err)
    {
        bool dummy = operation == "msql";
        if (!subid.isNone)
        {
            auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("subid", subid)));
            if (!r.ok)
            {
                err = internalServerError(r.error);
                return null;
            }
            if (r.value["rows"].length == 0)
            {
                err = gone(notFoundSub());
                return null;
            }
            mapRow(r.value["rows"][0]);
            auto oldData = r.value["rows"][0];
            // get_required_details
            if (data.contains("connect_timeout") && data["connect_timeout"] == Value(""))
                data["connect_timeout"] = Value(0);
            if (!data.contains("name"))
                data["name"] = oldData["name"];
            foreach (arg; ["host", "port", "username", "db", "connect_timeout", "passfile", "sslmode"])
                if (data.contains(arg))
                    oldData[arg] = data[arg];
            if (data.contains("slot_name") && data["slot_name"] == Value(""))
                data["slot_name"] = Value("None");
            auto sql = rt(UPDATE_SQL, tv("data", data, "o_data", oldData, "conn", conn, "dummy", dummy));
            name = data.contains("name") ? data["name"].toString : oldData["name"].toString;
            return sql.strip("\n");
        }
        auto sql = rt(CREATE_SQL, tv("data", data, "dummy", dummy, "conn", conn));
        name = data["name"].toString;
        return sql.strip("\n");
    }

    /// `get_publications`: connects to the publisher and lists its publications.
    private Response getPublications(Value did)
    {
        auto args = request().args;
        if (args.empty)
            throw new Exception("argument of type 'NoneType' is not iterable");
        auto url = Value.newDict();
        foreach (key; args.keys)
            url[key] = Value(args.get(key));
        if (url.contains("oid"))
        {
            Response e2;
            auto params = fetchProperties(did, url["oid"], e2);
            if (e2 is null)
                foreach (arg; ["host", "port", "username", "db", "connect_timeout", "passfile", "sslmode", "sslcompression",
                        "sslcert", "sslkey", "sslrootcert", "sslcrl"])
                    if (!url.contains(arg) && params.contains(arg))
                        url[arg] = params[arg];
        }
        string errMsg;
        Value[] pubs;
        try
        {
            string need(string key)
            {
                if (!url.contains(key))
                    throw new Exception(key);
                return url[key].isNone ? null : url[key].toString;
            }

            auto passfile = url.contains("passfile") && url["passfile"] != Value("") ? url["passfile"].toString : null;
            passfile = getCompleteFilePath(passfile);
            auto host = need("host");
            auto db = need("db");
            auto user = need("username");
            string password = url.contains("password") ? url["password"].toString : null;
            auto port = need("port");
            if (port.length == 0)
                port = null;
            string timeout = url.contains("connect_timeout") && url["connect_timeout"].truthy ? url["connect_timeout"].toString : "0";
            auto sslmode = need("sslmode");
            auto sslcert = getCompleteFilePath(need("sslcert"));
            auto sslkey = getCompleteFilePath(need("sslkey"));
            auto sslrootcert = getCompleteFilePath(need("sslrootcert"));
            bool sslcompression = need("sslcompression").length > 0;
            import pgadmin.db.pgconn : makeConninfo;
            auto info = makeConninfo([
                ["host", host], ["dbname", db], ["user", user], ["password", password], ["port", port],
                ["passfile", passfile], ["connect_timeout", timeout], ["sslmode", sslmode], ["sslcert", sslcert],
                ["sslkey", sslkey], ["sslrootcert", sslrootcert], ["sslcompression", sslcompression ? "1" : "0"]
            ]);
            auto c = PgConnection.connect(info);
            scope (exit)
                c.close();
            import pgadmin.db.pgconn : PgResult;
            PgResult first, last;
            c.execute("SELECT pubname from pg_catalog.pg_publication", first, last);
            foreach (row; last.rows)
                pubs ~= row[0];
        }
        catch (PgError e)
            errMsg = e.msg;
        catch (Exception e)
            errMsg = e.msg;
        if (errMsg !is null)
            return makeJsonResponse(1, Value(errMsg), Value(""), Value(null), Value(null), 200);
        Value[] result;
        foreach (p; pubs)
            result ~= Value.dictOf("value", p, "label", p);
        return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(result), 200);
    }

    private Response sqlView(Value subid, bool jsonResp = true)
    {
        auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("subid", subid)));
        if (!r.ok)
            return internalServerError(r.error);
        if (r.value["rows"].length == 0)
            return gone(notFoundSub());
        auto oldData = r.value["rows"][0].shallowCopy();
        oldData["create_slot"] = Value(false);
        oldData["connect"] = Value(oldData["enabled"].truthy);
        mapRow(oldData);
        auto sql = rt(CREATE_SQL, tv("data", oldData, "conn", conn, "dummy", true));
        sql ~= "\n\n";
        auto header = "-- Subscription: " ~ oldData["name"].toString ~ "\n\n-- DROP SUBSCRIPTION IF EXISTS "
            ~ oldData["name"].toString ~ ";";
        header ~= rt(DELETE_SQL, tv("sname", oldData["name"]));
        header ~= "\n";
        sql = header ~ sql;
        if (!jsonResp)
            return Response.sqlOnly(sql);
        return makeResponse(Value(sql));
    }
}
