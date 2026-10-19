/// `schemas/fts_configurations`: full-text search configurations.
module pgadmin.browser.server_groups.servers.databases.schemas.fts_configurations;

import pgadmin.browser.common;
import pgadmin.browser.server_groups.servers.databases.schemas.utils;

final class FtsConfigurationModule : SchemaChildModule
{
    enum NODE_TYPE = "fts_configuration";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "FTS Configurations";
        minVer = Value(null);
        maxVer = Value(null);
        staticDir("browser/server_groups/servers/databases/schemas/fts_configurations");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => "database";
    override bool nodeInode() => false;

    override Value[] getNodes(Dict kwargs)
    {
        if (hasNodes(kwargs["sid"], kwargs["did"], kwargs["scid"], Value(null), Value(null), FtsConfigurationView.BASE_TEMPLATE_PATH))
            return [generateBrowserCollectionNode(kwargs["scid"])];
        return null;
    }

    override void setup()
    {
        registerNodeView!FtsConfigurationView(this);
    }
}

final class FtsConfigurationView : PGChildNodeView
{
    enum BASE_TEMPLATE_PATH = "fts_configurations/sql/#{0}#";

    this()
    {
        super();
        nodeType = FtsConfigurationModule.NODE_TYPE;
        nodeLabel = "None"; // the Python view has no node_label: its messages say "the specified none"
        parentIds = [IdSpec("int", "gid"), IdSpec("int", "sid"), IdSpec("int", "did"), IdSpec("int", "scid")];
        ids = [IdSpec("int", "cfgid")];
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
            makeOp("parsers", ["get": "parsers"], ["get": "parsers"]),
            makeOp("copyConfig", ["get": "copyConfig"], ["get": "copyConfig"]),
            makeOp("tokens", ["get": "tokens"], ["get": "tokens"]),
            makeOp("dictionaries", null, ["get": "dictionaries"]),
            makeOp("compare", ["get": "compare"], ["get": "compare"]),
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
        auto cfgid = k.has("cfgid") ? k["cfgid"] : Value(null);
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
                res ~= gbn(row["oid"], scid, row["name"].toString, "icon-fts_configuration",
                        kwDict("description", row["description"]));
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        case "node":
        {
            auto r = conn.execute2darray(rt(NODES_SQL, tv("cfgid", cfgid)));
            if (!r.ok)
                return internalServerError(r.error);
            if (r.value["rows"].length == 0)
                return gone(gettext("Could not find the FTS Configuration node."));
            auto row = r.value["rows"][0];
            return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    gbn(row["oid"], did, row["name"].toString, "icon-fts_configuration"), 200);
        }
        case "properties":
        {
            Response e2;
            auto res = fetchProperties(scid, cfgid, e2);
            if (e2 !is null)
                return e2;
            return makeResponse(res, 200);
        }
        case "create": return create(scid);
        case "update": return update(gid, sid, did, scid, cfgid);
        case "delete": return delete_(scid, cfgid);
        case "msql": return msql(gid, sid, did, scid, cfgid);
        case "parsers": return parsers();
        case "copyConfig": return copyConfig();
        case "tokens": return tokens(cfgid);
        case "dictionaries": return dictionaries();
        case "sql": return sqlView(scid, cfgid);
        case "dependents": return makeResponse(getDependents(conn, cfgid), 200);
        case "dependencies": return makeResponse(getDependencies(conn, cfgid), 200);
        default: return super.callMethod(name, k);
        }
    }

    Value fetchProperties(Value scid, Value cfgid, out Response err)
    {
        auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("scid", scid, "cfgid", cfgid, "conn", conn)));
        if (!r.ok)
        {
            err = internalServerError(r.error);
            return Value(null);
        }
        if (r.value["rows"].length == 0)
        {
            err = gone(gettext("Could not find the FTS Configuration node in the database node."));
            return Value(null);
        }
        auto row = r.value["rows"][0];
        row["is_sys_obj"] = Value(row["oid"].integer <= DATABASE_LAST_SYSTEM_OID_ || datistemplate);
        auto t = conn.executeDict(rt("tokenDictList.sql", tv("cfgid", cfgid)));
        if (!t.ok)
        {
            err = internalServerError(t.error);
            return Value(null);
        }
        row["tokens"] = t.value["rows"];
        return row;
    }

    private Response create(Value scid)
    {
        auto data = formOrJson(request());
        auto miss = missingArg(data, ["schema", "name"]);
        if (miss !is null)
            return miss;
        if (!data.contains("copy_config") && !data.contains("prsname"))
            return makeJsonResponse(0, Value(gettext("Provide at least copy config or parser.")), Value(""), Value(null),
                    Value(null), 410);
        auto s = conn.executeScalar(rt(SCHEMA_SQL, tv("data", data, "conn", conn)));
        if (!s.ok)
            return internalServerError(s.error);
        auto newData = Value(data.dict.copy());
        newData["schema"] = s.value;
        auto c = conn.executeScalar(rt(CREATE_SQL, tv("data", newData, "conn", conn)));
        if (!c.ok)
            return internalServerError(c.error);
        auto t = conn.execute2darray(rt(PROPERTIES_SQL, tv("name", data["name"], "scid", data["schema"], "conn", conn)));
        if (!t.ok)
            return internalServerError(t.error);
        auto res = t.value["rows"][0];
        return jsonify(Value.dictOf("node", gbn(res["oid"], data["schema"], data["name"].toString,
                "icon-fts_configuration")));
    }

    private Response update(Value gid, Value sid, Value did, Value scid, Value cfgid)
    {
        auto data = formOrJson(request());
        if (cfgid.isNone || cfgid.integer == 0)
            return gone(gettext("Could not find the FTS Configuration node to update."));
        Response err;
        string name;
        auto sql = getSql(gid, sid, did, scid, data, cfgid, name, err);
        if (err !is null)
            return err;
        sql = sql.strip("\n").strip(" ");
        auto r = conn.executeScalar(sql);
        if (!r.ok)
            return internalServerError(r.error);
        auto schemaOrScid = data.contains("schema") ? data["schema"] : scid;
        auto p = conn.executeDict(rt(NODES_SQL, tv("cfgid", cfgid, "scid", schemaOrScid)));
        if (!p.ok)
            return internalServerError(p.error);
        if (p.value["rows"].length == 0)
            return gone(gettext("Could not find the FTS Configuration node to update."));
        Dict other;
        if (data.contains("description"))
            other = kwDict("description", data["description"]);
        return jsonify(Value.dictOf("node", gbn(cfgid, schemaOrScid, name, "icon-" ~ nodeType, other)));
    }

    Response delete_(Value scid, Value cfgidArg, bool onlySql = false)
    {
        Value data = cfgidArg.isNone ? formOrJson(request()) : Value.dictOf("ids", Value([cfgidArg]));
        bool cascade = checkCascadeOperation();
        try
        {
            foreach (cfgid; data["ids"].iterItems())
            {
                auto r = conn.executeDict(rt("get_name.sql", tv("cfgid", cfgid)));
                if (!r.ok)
                    return internalServerError(r.error);
                if (r.value["rows"].length == 0)
                    return makeJsonResponse(0, Value(gettext("Error: Object not found.")),
                            Value(gettext("The specified FTS configuration could not be found.\n")), Value(null), Value(null),
                            410);
                auto result = r.value["rows"][0];
                auto sql = rt(DELETE_SQL, tv("name", result["name"], "schema", result["schema"], "cascade", cascade));
                if (onlySql)
                    return Response.sqlOnly(sql);
                auto x = conn.executeScalar(sql);
                if (!x.ok)
                    return internalServerError(x.error);
            }
            return makeJsonResponse(1, Value(""), Value(gettext("FTS Configuration dropped")));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response msql(Value gid, Value sid, Value did, Value scid, Value cfgid)
    {
        auto data = msqlData("description");
        Response err;
        string name;
        auto sql = getSql(gid, sid, did, scid, data, cfgid, name, err);
        if (err !is null)
            return err;
        if (sql == "")
            sql = "-- No change";
        return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(sql), 200);
    }

    string getSql(Value gid, Value sid, Value did, Value scid, Value data, Value cfgid, out string name, out Response err)
    {
        if (!cfgid.isNone)
        {
            auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("cfgid", cfgid, "scid", scid, "conn", conn)));
            if (!r.ok)
            {
                err = internalServerError(r.error);
                return null;
            }
            if (r.value["rows"].length == 0)
            {
                err = gone(gettext("Could not find the FTS Configuration node."));
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
        auto newData = Value(data.dict.copy());
        newData["schema"] = s.value;
        string sql;
        if (newData.contains("name") && newData.contains("schema"))
            sql = rt(CREATE_SQL, tv("data", newData, "conn", conn));
        else
            sql = "-- definition incomplete";
        name = data["name"].toString;
        return sql.strip("\n");
    }

    private Response parsers()
    {
        auto r = conn.executeDict(rt("parser.sql", tv("parser", true)));
        if (!r.ok)
            return internalServerError(r.error);
        Value[] res = [Value.dictOf("label", "", "value", "")];
        foreach (row; r.value["rows"].list.items)
        {
            if (row["schemaoid"].integer > DATABASE_LAST_SYSTEM_OID_)
                row["prsname"] = Value(row["nspname"].toString ~ "." ~ row["prsname"].toString);
            res ~= Value.dictOf("label", row["prsname"], "value", row["prsname"]);
        }
        return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
    }

    private Response copyConfig()
    {
        auto r = conn.executeDict(rt("copy_config.sql", tv("copy_config", true)));
        if (!r.ok)
            return internalServerError(r.error);
        Value[] res = [Value.dictOf("label", "", "value", "")];
        foreach (row; r.value["rows"].list.items)
        {
            if (row["oid"].integer > DATABASE_LAST_SYSTEM_OID_)
                row["cfgname"] = Value(row["nspname"].toString ~ "." ~ row["cfgname"].toString);
            res ~= Value.dictOf("label", row["cfgname"], "value", row["cfgname"]);
        }
        return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
    }

    private Response tokens(Value cfgid)
    {
        try
        {
            Value[] res;
            if (!cfgid.isNone)
            {
                auto p = conn.executeScalar(rt("parser.sql", tv("cfgid", cfgid)));
                if (!p.ok)
                    return internalServerError(p.error);
                auto t = conn.executeDict(rt("tokens.sql", tv("parseroid", p.value)));
                foreach (row; t.value["rows"].list.items)
                    res ~= Value.dictOf("label", row["alias"], "value", row["alias"]);
            }
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response dictionaries()
    {
        auto r = conn.executeDict(rt("dictionaries.sql"));
        if (!r.ok)
            return internalServerError(r.error);
        Value[] res;
        foreach (row; r.value["rows"].list.items)
            res ~= Value.dictOf("label", row["dictname"], "value", row["dictname"]);
        return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
    }

    private Response sqlView(Value scid, Value cfgid, string targetSchema = null, bool jsonResp = true)
    {
        try
        {
            auto r = conn.executeScalar(rt("sql.sql", tv("cfgid", cfgid, "scid", scid, "conn", conn)));
            if (!r.ok)
                return internalServerError(gettext("Could not generate reverse-engineered query for the FTS Configuration.\n{0}")
                        .replace("{0}", r.value.toString));
            if (r.value.isNone)
                return gone(gettext("Could not generate reverse-engineered query for FTS Configuration node."));
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
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }
}
