/// `databases/extensions`: extensions.
module pgadmin.browser.server_groups.servers.databases.extensions;

import pgadmin.browser.common;

/// `get_extension_details(conn, ename, properties_sql)`
Res getExtensionDetails(Connection conn, Value ename, string propertiesSql = null)
{
    if (propertiesSql.length == 0)
        propertiesSql = ExtensionView.EXT_TEMPLATE_PATH ~ "/properties.sql";
    auto r = conn.executeDict(renderTemplate(propertiesSql, tv("ename", ename, "conn", conn)));
    if (r.ok)
        return Res(true, r.value["rows"][0]);
    return r;
}

final class ExtensionModule : CollectionNodeModule
{
    enum NODE_TYPE = "extension";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "Extensions";
        staticDir("browser/server_groups/servers/databases/extensions");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => "database";
    override bool nodeInode() => false;
    override bool moduleUseTemplateJavascript() => false;

    override Value[] getNodes(Dict kwargs)
    {
        if (hasNodes(kwargs["sid"], kwargs["did"], Value(null), Value(null), Value(null), ExtensionView.EXT_TEMPLATE_PATH))
            return [generateBrowserCollectionNode(kwargs["did"])];
        return null;
    }

    override void setup()
    {
        registerNodeView!ExtensionView(this);
    }
}

final class ExtensionView : PGChildNodeView
{
    enum EXT_TEMPLATE_PATH = "extensions/sql";

    this()
    {
        super();
        nodeType = ExtensionModule.NODE_TYPE;
        nodeLabel = "Extension";
        parentIds = [IdSpec("int", "gid"), IdSpec("int", "sid"), IdSpec("int", "did")];
        ids = [IdSpec("int", "eid")];
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
            makeOp("avails", null, ["get": "avails"]),
            makeOp("schemas", null, ["get": "schemas"]),
            makeOp("children", ["get": "children"]),
        ]);
    }

    override Response callMethod(string name, Dict k)
    {
        if (!isAuthenticated())
            return unauthorisedResponse();
        if (name == "children")
            return children(k);
        auto err = standardPrecondition(k, name, EXT_TEMPLATE_PATH);
        if (err !is null)
            return err;
        auto gid = k.has("gid") ? k["gid"] : Value(null);
        auto sid = k["sid"];
        auto did = k["did"];
        auto eid = k.has("eid") ? k["eid"] : Value(null);
        switch (name)
        {
        case "list":
        {
            auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("conn", conn)));
            if (!r.ok)
                return internalServerError(r.error);
            return makeResponse(r.value["rows"], 200);
        }
        case "nodes":
        {
            auto r = conn.execute2darray(rt(PROPERTIES_SQL, tv("conn", conn)));
            if (!r.ok)
                return internalServerError(r.error);
            Value[] res;
            foreach (row; r.value["rows"].list.items)
                res ~= gbn(row["oid"], did, row["name"].toString, "icon-extension", kwDict("description", row["comment"]));
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        case "node":
        {
            auto r = conn.execute2darray(rt(PROPERTIES_SQL, tv("eid", eid, "conn", conn)));
            if (!r.ok)
                return internalServerError(r.error);
            foreach (row; r.value["rows"].list.items)
                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                        gbn(row["oid"], did, row["name"].toString, "icon-extension"), 200);
            return gone(gettext("Could not find the specified extension."));
        }
        case "properties":
        {
            Response e2;
            auto res = fetchProperties(did, eid, e2);
            if (e2 !is null)
                return e2;
            return makeResponse(res, 200);
        }
        case "create": return create(did);
        case "update": return update(gid, sid, did, eid);
        case "delete": return delete_(eid);
        case "msql":
        {
            auto data = Value.newDict();
            foreach (key; request().args.keys)
            {
                auto v = request().args.get(key);
                data[key] = tryParseJson(v, Value(v));
            }
            try
            {
                Response e2;
                string nm;
                auto sql = getSql(data, eid, nm, e2);
                if (e2 !is null)
                    return e2;
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
        case "avails":
        {
            auto r = conn.executeDict(rt("extensions.sql"));
            if (!r.ok)
                return internalServerError(r.error);
            return makeJsonResponse(1, Value(""), Value(""), Value(null), r.value["rows"], 200);
        }
        case "schemas":
        {
            auto r = conn.executeDict(rt("schemas.sql"));
            if (!r.ok)
                return internalServerError(r.error);
            return makeJsonResponse(1, Value(""), Value(""), Value(null), r.value["rows"], 200);
        }
        case "sql":
        {
            auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("eid", eid, "conn", conn)));
            if (!r.ok)
                return internalServerError(r.error);
            if (r.value["rows"].length == 0)
                return gone(gettext("Could not find the extension on the server."));
            auto sql = rt(CREATE_SQL, tv("data", r.value["rows"][0], "conn", conn, "display_comments", true,
                    "add_not_exists_clause", true));
            return makeResponse(Value(sql));
        }
        case "dependents": return makeResponse(getDependents(conn, eid), 200);
        case "dependencies": return makeResponse(getDependencies(conn, eid), 200);
        default: return super.callMethod(name, k);
        }
    }

    Value fetchProperties(Value did, Value eid, out Response err)
    {
        auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("eid", eid, "conn", conn)));
        if (!r.ok)
        {
            err = internalServerError(r.error);
            return Value(null);
        }
        if (r.value["rows"].length == 0)
        {
            err = gone(gettext("Could not find the extension information."));
            return Value(null);
        }
        auto row = r.value["rows"][0];
        row["is_sys_obj"] = Value(row["oid"].integer <= DATABASE_LAST_SYSTEM_OID_ || datistemplate);
        return row;
    }

    private Response create(Value did)
    {
        auto data = formOrJson(request());
        auto miss = missingArg(data, ["name"]);
        if (miss !is null)
            return miss;
        auto c = conn.executeDict(rt(CREATE_SQL, tv("data", data)));
        if (!c.ok)
            return internalServerError(c.error);
        auto d = getExtensionDetails(conn, data["name"], EXT_TEMPLATE_PATH ~ "/" ~ PROPERTIES_SQL);
        if (!d.ok)
            return internalServerError(d.error);
        return jsonify(Value.dictOf("node", gbn(d.value["oid"], did, d.value["name"].toString, "icon-extension")));
    }

    private Response update(Value gid, Value sid, Value did, Value eid)
    {
        auto data = formOrJson(request());
        try
        {
            Response e2;
            string name;
            auto sql = getSql(data, eid, name, e2);
            if (e2 !is null)
                return e2;
            sql = sql.strip("\n").strip(" ");
            auto x = conn.executeDict(sql);
            if (!x.ok)
                return internalServerError(x.error);
            Dict extra;
            if (data.contains("comment"))
                extra = kwDict("description", data["comment"]);
            return jsonify(Value.dictOf("node", gbn(eid, did, name, "icon-" ~ nodeType, extra)));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    Response delete_(Value eidArg, bool onlySql = false)
    {
        Value data = eidArg.isNone ? formOrJson(request()) : Value.dictOf("ids", Value([eidArg]));
        bool cascade = checkCascadeOperation();
        try
        {
            foreach (eid; data["ids"].iterItems())
            {
                auto n = conn.executeScalar(rt(DELETE_SQL, tv("eid", eid)));
                if (!n.ok)
                    return internalServerError(n.error);
                if (n.value.isNone)
                    return makeJsonResponse(0, Value(gettext("Error: Object not found.")),
                            Value(gettext("The specified extension could not be found.\n")), Value(null), Value(null), 410);
                auto sql = rt(DELETE_SQL, tv("name", n.value, "cascade", cascade));
                if (onlySql)
                    return Response.sqlOnly(sql);
                auto x = conn.executeScalar(sql);
                if (!x.ok)
                    return internalServerError(x.error);
            }
            return makeJsonResponse(1, Value(""), Value(gettext("Extension dropped")));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    string getSql(Value data, Value eid, out string name, out Response err)
    {
        if (!eid.isNone)
        {
            auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("eid", eid, "conn", conn)));
            if (!r.ok)
            {
                err = internalServerError(r.error);
                return null;
            }
            if (r.value["rows"].length == 0)
            {
                err = gone(gettext("Could not find the extension information."));
                return null;
            }
            auto oldData = r.value["rows"][0];
            if (!data.contains("name"))
                data["name"] = oldData["name"];
            auto sql = rt(UPDATE_SQL, tv("data", data, "o_data", oldData));
            name = data.contains("name") ? data["name"].toString : oldData["name"].toString;
            return sql;
        }
        auto sql = rt(CREATE_SQL, tv("data", data));
        name = data["name"].toString;
        return sql;
    }
}
