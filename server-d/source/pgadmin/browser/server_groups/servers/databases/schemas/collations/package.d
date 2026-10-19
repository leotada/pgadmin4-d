/// `schemas/collations`: collations.
module pgadmin.browser.server_groups.servers.databases.schemas.collations;

import std.array : replace;
import std.conv : to;
import std.string : strip;
import pgadmin.browser.server_groups.servers.databases.schemas.utils;
import pgadmin.browser.utils;
import pgadmin.core.i18n;
import pgadmin.core.templates;
import pgadmin.core.value;
import pgadmin.db.driver;
import pgadmin.web.auth;
import pgadmin.web.context;
import pgadmin.web.http;

final class CollationModule : SchemaChildModule
{
    enum NODE_TYPE = "collation";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "Collations";
        minVer = Value(90100);
        maxVer = Value(null);
        staticDir("browser/server_groups/servers/databases/schemas/collations");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => "database";
    override bool nodeInode() => false;

    override Value[] getNodes(Dict kwargs)
    {
        if (hasNodes(kwargs["sid"], kwargs["did"], kwargs["scid"], Value(null), Value(null), CollationView.BASE_TEMPLATE_PATH))
            return [generateBrowserCollectionNode(kwargs["scid"])];
        return null;
    }

    override void setup()
    {
        registerNodeView!CollationView(this);
    }
}

final class CollationView : PGChildNodeView
{
    enum BASE_TEMPLATE_PATH = "collations/sql/#{0}#";

    this()
    {
        super();
        nodeType = CollationModule.NODE_TYPE;
        nodeLabel = "Collation";
        parentIds = [IdSpec("int", "gid"), IdSpec("int", "sid"), IdSpec("int", "did"), IdSpec("int", "scid")];
        ids = [IdSpec("int", "coid")];
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
            makeOp("get_collations", ["get": "get_collation"], ["get": "get_collation"]),
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
        auto scid = k["scid"];
        auto coid = k.has("coid") ? k["coid"] : Value(null);
        switch (name)
        {
        case "list": return list(scid);
        case "nodes": return nodes(scid);
        case "node": return node(scid, coid);
        case "properties": return properties(scid, coid);
        case "get_collation": return getCollation();
        case "create": return create(scid);
        case "delete": return delete_(scid, coid);
        case "update": return update(gid, sid, scid, coid);
        case "msql": return msql(gid, sid, scid, coid);
        case "sql": return sqlView(scid, coid);
        case "dependents": return makeResponse(getDependents(conn, coid), 200);
        case "dependencies": return makeResponse(getDependencies(conn, coid), 200);
        default: return super.callMethod(name, k);
        }
    }

    private Response list(Value scid)
    {
        auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("scid", scid)));
        if (!r.ok)
            return internalServerError(r.error);
        return makeResponse(r.value["rows"], 200);
    }

    private Response nodes(Value scid)
    {
        auto r = conn.execute2darray(rt(NODES_SQL, tv("scid", scid)));
        if (!r.ok)
            return internalServerError(r.error);
        Value[] res;
        foreach (row; r.value["rows"].list.items)
            res ~= gbn(row["oid"], scid, row["name"].toString, "icon-collation",
                    kwDict("description", row["description"]));
        return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
    }

    private Response node(Value scid, Value coid)
    {
        auto r = conn.execute2darray(rt(NODES_SQL, tv("coid", coid)));
        if (!r.ok)
            return internalServerError(r.error);
        foreach (row; r.value["rows"].list.items)
            return makeJsonResponse(1, Value(""), Value(""), Value(null), gbn(row["oid"], scid,
                    row["name"].toString, "icon-collation"), 200);
        return gone(notFoundErrorMsg());
    }

    private Value fetchProperties(Value scid, Value coid, out Response err)
    {
        auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("scid", scid, "coid", coid, "datlastsysoid", DATABASE_LAST_SYSTEM_OID_)));
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
        auto row = r.value["rows"][0];
        row["is_sys_obj"] = Value(row["oid"].integer <= DATABASE_LAST_SYSTEM_OID_ || datistemplate);
        return row;
    }

    private Response properties(Value scid, Value coid)
    {
        Response err;
        auto res = fetchProperties(scid, coid, err);
        if (err !is null)
            return err;
        return makeResponse(res, 200);
    }

    private Response getCollation()
    {
        try
        {
            auto r = conn.execute2darray(rt("get_collations.sql"));
            if (!r.ok)
                return internalServerError("");
            Value[] res;
            foreach (row; r.value["rows"].list.items)
                res ~= Value.dictOf("label", row["copy_collation"], "value", row["copy_collation"]);
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private static bool checkDefinition(Value data)
    {
        bool missing;
        bool hasKey(string k) => data.contains(k);
        foreach (arg; ["locale", "copy_collation", "lc_collate", "lc_type"])
        {
            bool emptyArg = !hasKey(arg) || data[arg] == Value("");
            if (arg == "locale" && emptyArg && !hasKey("copy_collation") && !hasKey("lc_collate") && !hasKey("lc_type"))
                missing = true;
            if (arg == "copy_collation" && emptyArg && !hasKey("locale") && !hasKey("lc_collate") && !hasKey("lc_type"))
                missing = true;
            if ((arg == "lc_collate" || arg == "lc_type") && emptyArg && !hasKey("copy_collation") && !hasKey("locale"))
                missing = true;
        }
        return missing;
    }

    private Response create(Value scid)
    {
        auto data = formOrJson(request());
        auto miss = missingArg(data, ["schema", "name"]);
        if (miss !is null)
            return miss;
        if (checkDefinition(data))
            return makeJsonResponse(0, Value(gettext("Definition incomplete. Please provide Locale OR Copy Collation OR LC_TYPE/LC_COLLATE.")),
                    Value(""), Value(null), Value(null), 410);
        auto r = conn.executeScalar(rt(CREATE_SQL, tv("data", data, "conn", conn)));
        if (!r.ok)
            return internalServerError(r.error);
        auto o = conn.executeScalar(rt(OID_SQL, tv("data", data, "conn", conn)));
        if (!o.ok)
            return internalServerError(o.error);
        auto coid = o.value;
        auto n = conn.executeScalar(rt(OID_SQL, tv("coid", coid, "conn", conn)));
        if (!n.ok)
            return internalServerError(o.error);
        return jsonify(Value.dictOf("node", gbn(coid, n.value, data["name"].toString,
                "icon-collation")));
    }

    Response delete_(Value scid, Value coidArg, bool onlySql = false)
    {
        Value data = coidArg.isNone ? parseJson(request().text) : Value.dictOf("ids", Value([coidArg]));
        bool cascade = checkCascadeOperation();
        try
        {
            foreach (coid; data["ids"].iterItems())
            {
                auto r = conn.executeDict(rt("get_name.sql", tv("scid", scid, "coid", coid)));
                if (!r.ok)
                    return internalServerError(r.error);
                if (r.value["rows"].length == 0)
                    return gone(notFoundErrorMsg());
                auto d = r.value["rows"][0];
                auto sql = rt(DELETE_SQL, tv("name", d["name"], "nspname", d["schema"], "cascade", cascade, "conn", conn));
                if (onlySql)
                    return Response.sqlOnly(sql);
                auto x = conn.executeScalar(sql);
                if (!x.ok)
                    return internalServerError(x.error);
            }
            return makeJsonResponse(1, Value(""), Value(gettext("Collation dropped")));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response update(Value gid, Value sid, Value scid, Value coid)
    {
        auto data = formOrJson(request());
        Response err;
        string name;
        auto sql = getSql(gid, sid, data, scid, coid, name, err);
        if (err !is null)
            return err;
        sql = sql.strip("\n").strip(" ");
        auto r = conn.executeScalar(sql);
        if (!r.ok)
            return internalServerError(r.error);
        auto o = conn.execute2darray(rt(OID_SQL, tv("coid", coid)));
        if (!o.ok)
            return internalServerError(o.error);
        auto newScid = o.value["rows"][0]["scid"];
        Dict other;
        if (data.contains("description"))
            other = kwDict("description", data["description"]);
        return jsonify(Value.dictOf("node", gbn(coid, newScid, name, "icon-" ~ nodeType, other)));
    }

    private Response msql(Value gid, Value sid, Value scid, Value coid)
    {
        auto data = msqlData("description");
        try
        {
            Response err;
            string name;
            auto sql = getSql(gid, sid, data, scid, coid, name, err);
            if (err !is null)
                return err;
            if (sql == "")
                sql = "--modified SQL";
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(sql), 200);
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    /// `get_sql`: when `err` is null the result is the SQL; a bare string for an incomplete definition is returned as
    /// the SQL with an empty name (the Python code returns a bare string there, and callers treat it as SQL).
    string getSql(Value gid, Value sid, Value data, Value scid, Value coid, out string name, out Response err)
    {
        if (!coid.isNone)
        {
            auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("scid", scid, "coid", coid)));
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
            auto oldData = r.value["rows"][0];
            auto sql = rt(UPDATE_SQL, tv("data", data, "o_data", oldData, "conn", conn));
            name = data.contains("name") ? data["name"].toString : oldData["name"].toString;
            return sql.strip("\n");
        }
        foreach (arg; ["name"])
            if (!data.contains(arg))
                return gettext("-- missing definition");
        if (checkDefinition(data))
            return gettext("-- missing definition");
        auto sql = rt(CREATE_SQL, tv("data", data, "conn", conn));
        name = data["name"].toString;
        return sql.strip("\n");
    }

    private Response sqlView(Value scid, Value coid, string targetSchema = null, bool jsonResp = true)
    {
        auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("scid", scid, "coid", coid)));
        if (!r.ok)
            return internalServerError(r.error);
        if (r.value["rows"].length == 0)
            return gone(notFoundErrorMsg());
        auto data = r.value["rows"][0];
        if (targetSchema.length)
            data["schema"] = Value(targetSchema);
        auto sql = rt(CREATE_SQL, tv("data", data, "conn", conn, "add_not_exists_clause", true));
        auto header = "-- Collation: " ~ data["name"].toString ~ ";\n\n-- ";
        header ~= rt(DELETE_SQL, tv("name", data["name"], "nspname", data["schema"]));
        sql = header ~ "\n\n" ~ sql.strip("\n");
        if (!jsonResp)
            return Response.sqlOnly(sql);
        return makeResponse(Value(sql));
    }
}
