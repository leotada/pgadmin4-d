/// `schemas/fts_dictionaries`: full-text search dictionaries.
module pgadmin.browser.server_groups.servers.databases.schemas.fts_dictionaries;

import pgadmin.browser.common;
import pgadmin.browser.server_groups.servers.databases.schemas.utils;

final class FtsDictionaryModule : SchemaChildModule
{
    enum NODE_TYPE = "fts_dictionary";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "FTS Dictionaries";
        minVer = Value(null);
        maxVer = Value(null);
        staticDir("browser/server_groups/servers/databases/schemas/fts_dictionaries");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => "database";
    override bool nodeInode() => false;

    override Value[] getNodes(Dict kwargs)
    {
        if (hasNodes(kwargs["sid"], kwargs["did"], kwargs["scid"], Value(null), Value(null), FtsDictionaryView.BASE_TEMPLATE_PATH))
            return [generateBrowserCollectionNode(kwargs["scid"])];
        return null;
    }

    override void setup()
    {
        registerNodeView!FtsDictionaryView(this);
    }
}

final class FtsDictionaryView : PGChildNodeView
{
    enum BASE_TEMPLATE_PATH = "fts_dictionaries/sql/#{0}#";

    this()
    {
        super();
        nodeType = FtsDictionaryModule.NODE_TYPE;
        nodeLabel = "FTS Dictionary";
        parentIds = [IdSpec("int", "gid"), IdSpec("int", "sid"), IdSpec("int", "did"), IdSpec("int", "scid")];
        ids = [IdSpec("int", "dcid")];
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
            makeOp("fetch_templates", ["get": "fetch_templates"], ["get": "fetch_templates"]),
        ]);
    }

    /// `'a=1, b=2'` -> `[{option: a, value: 1}, ...]`
    static Value tokenizeOptions(Value optionValue)
    {
        if (optionValue.isNone)
            return Value(null);
        Value[] options;
        foreach (part; optionValue.toString.split(","))
        {
            auto idx = part.indexOf("=");
            if (idx < 0)
                throw new Exception("not enough values to unpack (expected 2, got 1)");
            options ~= Value.dictOf("option", part[0 .. idx].strip, "value", part[idx + 1 .. $].strip.strip("'"));
        }
        return Value(options);
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
        auto dcid = k.has("dcid") ? k["dcid"] : Value(null);
        switch (name)
        {
        case "list":
        {
            auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("scid", scid, "conn", conn)));
            if (!r.ok)
                return internalServerError(r.error);
            foreach (row; r.value["rows"].list.items)
                if (!row["options"].isNone)
                    row["options"] = tokenizeOptions(row["options"]);
            return makeResponse(r.value["rows"], 200);
        }
        case "nodes":
        {
            auto r = conn.execute2darray(rt(NODES_SQL, tv("scid", scid)));
            if (!r.ok)
                return internalServerError(r.error);
            Value[] res;
            foreach (row; r.value["rows"].list.items)
                res ~= gbn(row["oid"], scid, row["name"].toString, "icon-fts_dictionary",
                        kwDict("description", row["description"]));
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        case "node":
        {
            auto r = conn.execute2darray(rt(NODES_SQL, tv("dcid", dcid)));
            if (!r.ok)
                return internalServerError(r.error);
            if (r.value["rows"].length == 0)
                return gone(gettext("Could not find the FTS Dictionary node."));
            auto row = r.value["rows"][0];
            return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    gbn(dcid, row["schema"], row["name"].toString, "icon-fts_dictionary"), 200);
        }
        case "properties":
        {
            Response e2;
            auto res = fetchProperties(scid, dcid, e2);
            if (e2 !is null)
                return e2;
            return makeResponse(res, 200);
        }
        case "create": return create(scid);
        case "update": return update(gid, sid, did, scid, dcid);
        case "delete": return delete_(scid, dcid);
        case "msql": return msql(gid, sid, did, scid, dcid);
        case "fetch_templates": return fetchTemplates();
        case "sql": return sqlView(scid, dcid);
        case "dependents": return makeResponse(getDependents(conn, dcid), 200);
        case "dependencies": return makeResponse(getDependencies(conn, dcid), 200);
        default: return super.callMethod(name, k);
        }
    }

    private void qualifyTemplate(Value row)
    {
        if (!row["template_schema"].isNone && row["template_schema"].toString != "pg_catalog")
            row["template"] = Value(qtIdentStr(row["template_schema"].toString, row["template"].toString));
    }

    Value fetchProperties(Value scid, Value dcid, out Response err)
    {
        auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("scid", scid, "dcid", dcid, "conn", conn)));
        if (!r.ok)
        {
            err = internalServerError(r.error);
            return Value(null);
        }
        if (r.value["rows"].length == 0)
        {
            err = gone(gettext("Could not find the FTS Dictionary node in the database node."));
            return Value(null);
        }
        auto row = r.value["rows"][0];
        row["is_sys_obj"] = Value(row["oid"].integer <= DATABASE_LAST_SYSTEM_OID_ || datistemplate);
        qualifyTemplate(row);
        if (!row["options"].isNone)
            row["options"] = tokenizeOptions(row["options"]);
        return row;
    }

    private Response create(Value scid)
    {
        auto data = formOrJson(request());
        auto miss = missingArg(data, ["template", "schema", "name"]);
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
        return jsonify(Value.dictOf("node", gbn(t.value, data["schema"], data["name"].toString, "icon-fts_dictionary")));
    }

    private Response update(Value gid, Value sid, Value did, Value scid, Value dcid)
    {
        auto data = formOrJson(request());
        Response err;
        string name;
        auto sql = getSql(gid, sid, did, scid, data, dcid, name, err);
        if (err !is null)
            return err;
        sql = sql.strip("\n").strip(" ");
        auto r = conn.executeScalar(sql);
        if (!r.ok)
            return internalServerError(r.error);
        auto p = conn.executeDict(rt(PROPERTIES_SQL, tv("dcid", dcid, "conn", conn)));
        if (!p.ok)
            return internalServerError(p.error);
        if (p.value["rows"].length == 0)
            return gone(gettext("Could not find the FTS Dictionary node to update."));
        Dict other;
        if (data.contains("description"))
            other = kwDict("description", data["description"]);
        return jsonify(Value.dictOf("node", gbn(dcid, p.value["rows"][0]["schema"], name, "icon-" ~ nodeType, other)));
    }

    Response delete_(Value scid, Value dcidArg, bool onlySql = false)
    {
        Value data = dcidArg.isNone ? formOrJson(request()) : Value.dictOf("ids", Value([dcidArg]));
        bool cascade = checkCascadeOperation();
        try
        {
            foreach (dcid; data["ids"].iterItems())
            {
                auto r = conn.executeDict(rt(DELETE_SQL, tv("dcid", dcid)));
                if (!r.ok)
                    return internalServerError(r.error);
                if (r.value["rows"].length == 0)
                    return makeJsonResponse(0, Value(gettext("Error: Object not found.")),
                            Value(gettext("The specified FTS dictionary could not be found.\n")), Value(null), Value(null), 410);
                auto result = r.value["rows"][0];
                auto sql = rt(DELETE_SQL, tv("name", result["name"], "schema", result["schema"], "cascade", cascade));
                if (onlySql)
                    return Response.sqlOnly(sql);
                auto x = conn.executeScalar(sql);
                if (!x.ok)
                    return internalServerError(x.error);
            }
            return makeJsonResponse(1, Value(""), Value(gettext("FTS Dictionary dropped")));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response msql(Value gid, Value sid, Value did, Value scid, Value dcid)
    {
        auto data = msqlData("description");
        Response err;
        string name;
        auto sql = getSql(gid, sid, did, scid, data, dcid, name, err);
        if (err !is null)
            return err;
        if (sql == "")
            sql = "--modified SQL";
        return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(sql), 200);
    }

    string getSql(Value gid, Value sid, Value did, Value scid, Value data, Value dcid, out string name, out Response err)
    {
        if (!dcid.isNone)
        {
            auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("dcid", dcid, "scid", scid, "conn", conn)));
            if (!r.ok)
            {
                err = internalServerError(r.error);
                return null;
            }
            if (r.value["rows"].length == 0)
            {
                err = gone(gettext("Could not find the FTS Dictionary node."));
                return null;
            }
            auto oldData = r.value["rows"][0];
            if (!data.contains("schema"))
                data["schema"] = oldData["schema"];
            qualifyTemplate(oldData);
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
        if (newData.contains("template") && newData.contains("name") && newData.contains("schema"))
            sql = rt(CREATE_SQL, tv("data", newData, "conn", conn));
        else
            sql = "-- definition incomplete";
        name = data["name"].toString;
        return sql.strip("\n");
    }

    private Response fetchTemplates()
    {
        auto r = conn.executeDict(rt("templates.sql", tv("template", true)));
        if (!r.ok)
            return internalServerError(r.error);
        Value[] res;
        foreach (row; r.value["rows"].list.items)
        {
            if (row["nspname"].toString != "pg_catalog")
                row["tmplname"] = Value(qtIdentStr(row["nspname"].toString, row["tmplname"].toString));
            res ~= Value.dictOf("label", row["tmplname"], "value", row["tmplname"]);
        }
        return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
    }

    private Response sqlView(Value scid, Value dcid, string targetSchema = null, bool jsonResp = true)
    {
        auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("scid", scid, "dcid", dcid, "conn", conn)));
        if (!r.ok)
            return internalServerError(r.error);
        if (r.value["rows"].length == 0)
            return gone(gettext("Could not find the FTS Dictionary node in the database node."));
        auto row = r.value["rows"][0];
        qualifyTemplate(row);
        row["options"] = row["options"].isNone ? Value.newList() : tokenizeOptions(row["options"]);
        auto s = conn.executeScalar(rt(SCHEMA_SQL, tv("data", row)));
        if (!s.ok)
            return internalServerError(s.error);
        row["schema"] = s.value;
        if (targetSchema.length)
            row["schema"] = Value(targetSchema);
        auto sql = rt(CREATE_SQL, tv("data", row, "conn", conn, "is_displaying", true));
        auto header = "-- Text Search Dictionary: " ~ row["schema"].toString ~ "." ~ row["name"].toString ~ "\n\n";
        header ~= "-- DROP TEXT SEARCH DICTIONARY IF EXISTS "
            ~ qtIdentStr(row["schema"].toString, row["name"].toString) ~ ";\n\n";
        sql = header ~ sql;
        if (!jsonResp)
            return Response.sqlOnly(sql);
        return makeResponse(Value(sql.strip("\n")));
    }
}
