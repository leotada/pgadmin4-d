/// `schemas/domains/domain_constraints`: CHECK constraints of a domain.
module pgadmin.browser.server_groups.servers.databases.schemas.domains.domain_constraints;

import pgadmin.browser.common;

final class DomainConstraintModule : CollectionNodeModule
{
    enum NODE_TYPE = "domain_constraints";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "Domain Constraints";
        minVer = Value(null);
        maxVer = Value(null);
        staticDir("browser/server_groups/servers/databases/schemas/domains/domain_constraints");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => "domain";
    override bool nodeInode() => false;
    override bool moduleUseTemplateJavascript() => false;

    override Value[] getNodes(Dict kwargs) => [generateBrowserCollectionNode(kwargs["doid"])];

    override string[] csssnippets() => [
        renderTemplate("domain_constraints/css/domain_constraints.css", ["node_type": Value(nodeType)])
    ];

    override void setup()
    {
        registerNodeView!DomainConstraintView(this);
    }
}

final class DomainConstraintView : PGChildNodeView
{
    private Value req_;
    private enum BASE = "domain_constraints/sql/#{0}#";

    this()
    {
        super();
        nodeType = DomainConstraintModule.NODE_TYPE;
        nodeLabel = "Domain Constraint";
        parentIds = [IdSpec("int", "gid"), IdSpec("int", "sid"), IdSpec("int", "did"), IdSpec("int", "scid"),
            IdSpec("int", "doid")];
        ids = [IdSpec("int", "coid")];
        setAllOps([
            makeOp("obj", ["get": "properties", "delete": "delete", "put": "update"],
                    ["get": "list", "post": "create", "delete": "delete"]),
            makeOp("children", ["get": "children"]),
            makeOp("nodes", ["get": "node"], ["get": "nodes"]),
            makeOp("sql", ["get": "sql"]),
            makeOp("msql", ["get": "msql"], ["get": "msql"]),
            makeOp("stats", ["get": "statistics"]),
            makeOp("dependency", ["get": "dependencies"]),
            makeOp("dependent", ["get": "dependents"]),
        ]);
    }

    private Response validateRequest(Dict k)
    {
        auto req = argsOrJson();
        if (!k.has("coid"))
            foreach (arg; ["name", "consrc"])
                if (!req.contains(arg) || req[arg] == Value(""))
                    return makeJsonResponse(0, Value(gettext("Could not find the required parameter ({}).").replace("{}", arg)),
                            Value(""), Value(null), Value(null), 410);
        auto data = Value.newDict();
        foreach (key, v; req.dict)
            data[key] = key == "convalidated" ? Value(v == Value("true") || (v.type == VType.boolean && v.boolean)) : v;
        req_ = data;
        return null;
    }

    private static string iconFor(Value row)
    {
        if (!row.contains("convalidated") || row["convalidated"].truthy)
            return "icon-domain_constraints";
        return "icon-domain_constraints-bad";
    }

    override Response callMethod(string name, Dict k)
    {
        if (!isAuthenticated())
            return unauthorisedResponse();
        if (name == "children")
            return children(k);
        auto err = standardPrecondition(k, name, BASE);
        if (err !is null)
            return err;
        auto gid = k.has("gid") ? k["gid"] : Value(null);
        auto sid = k["sid"];
        auto did = k["did"];
        auto scid = k["scid"];
        auto doid = k["doid"];
        auto coid = k.has("coid") ? k["coid"] : Value(null);
        if (name == "create" || name == "update" || name == "msql")
        {
            auto ve = validateRequest(k);
            if (ve !is null)
                return ve;
        }
        switch (name)
        {
        case "list":
        {
            auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("doid", doid)));
            if (!r.ok)
                return internalServerError(r.error);
            return makeResponse(r.value["rows"], 200);
        }
        case "nodes":
        {
            auto r = conn.execute2darray(rt(PROPERTIES_SQL, tv("doid", doid)));
            if (!r.ok)
                return internalServerError(r.error);
            Value[] res;
            foreach (row; r.value["rows"].list.items)
                res ~= gbn(row["oid"], doid, row["name"].toString, iconFor(row),
                        kwDict("description", row["description"]));
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        case "node":
        {
            auto r = conn.execute2darray(rt(PROPERTIES_SQL, tv("coid", coid)));
            if (!r.ok)
                return internalServerError(r.error);
            foreach (row; r.value["rows"].list.items)
                return makeJsonResponse(1, Value(""), Value(""), Value(null), gbn(row["oid"], doid,
                        row["name"].toString, iconFor(row)), 200);
            return gone(notFoundErrorMsg());
        }
        case "properties":
        {
            auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("doid", doid, "coid", coid)));
            if (!r.ok)
                return internalServerError(r.error);
            if (r.value["rows"].length == 0)
                return gone(notFoundErrorMsg());
            auto data = r.value["rows"][0];
            data["is_sys_obj"] = Value(data["oid"].integer <= DATABASE_LAST_SYSTEM_OID_ || datistemplate);
            return makeResponse(data, 200);
        }
        case "create": return create(gid, sid, scid, doid);
        case "delete": return delete_(doid, coid);
        case "update": return update(gid, sid, did, scid, doid, coid);
        case "sql": return sqlView(doid, coid);
        case "msql":
        {
            bool ok;
            Response e2;
            string nm;
            auto sql = getSql(req_, scid, doid, coid, ok, nm, e2);
            if (ok && sql.length)
                return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(sql), 200);
            return e2 !is null ? e2 : new Response("", 200);
        }
        case "dependents": return makeResponse(getDependents(conn, coid), 200);
        case "dependencies": return makeResponse(getDependencies(conn, coid), 200);
        default: return super.callMethod(name, k);
        }
    }

    private Response create(Value gid, Value sid, Value scid, Value doid)
    {
        auto data = req_;
        try
        {
            bool ok;
            Response err;
            string nm;
            auto sql = getSql(data, scid, doid, Value(null), ok, nm, err);
            if (!ok)
                return err;
            auto r = conn.executeScalar(sql);
            if (!r.ok)
                return internalServerError(r.error);
            auto o = conn.executeScalar(rt(OID_SQL, tv("doid", doid, "name", data["name"], "conn", conn)));
            if (!o.ok)
                return internalServerError(o.error);
            auto icon = (!data.contains("convalidated") || data["convalidated"].truthy)
                ? "icon-domain_constraints" : "icon-domain_constraints-bad";
            return jsonify(Value.dictOf("node", gbn(o.value, doid, data["name"].toString, icon)));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response delete_(Value doid, Value coidArg)
    {
        Value data = coidArg.isNone ? formOrJson(request()) : Value.dictOf("ids", Value([coidArg]));
        try
        {
            foreach (coid; data["ids"].iterItems())
            {
                auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("doid", doid, "coid", coid)));
                if (!r.ok)
                    return internalServerError(r.error);
                if (r.value["rows"].length == 0)
                    return makeJsonResponse(0, Value(gettext("Error: Object not found.")), Value(notFoundErrorMsg()),
                            Value(null), Value(null), 410);
                auto x = conn.executeScalar(rt(DELETE_SQL, tv("data", r.value["rows"][0])));
                if (!x.ok)
                    return internalServerError(x.error);
            }
            return makeJsonResponse(1, Value(""), Value(gettext("Domain Constraint dropped")));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response update(Value gid, Value sid, Value did, Value scid, Value doid, Value coid)
    {
        auto data = req_;
        bool ok;
        Response err;
        string name;
        auto sql = getSql(data, scid, doid, coid, ok, name, err);
        if (!ok)
            return err;
        try
        {
            if (sql.length)
            {
                auto r = conn.executeScalar(sql);
                if (!r.ok)
                    return internalServerError(r.error);
                string icon;
                if (data.contains("convalidated"))
                    icon = data["convalidated"].truthy ? "icon-domain_constraints" : "icon-domain_constraints-bad";
                Dict other;
                if (data.contains("description"))
                    other = kwDict("description", data["description"]);
                return jsonify(Value.dictOf("node", gbn(coid, doid, name, icon,
                        other)));
            }
            return makeJsonResponse(1, Value(""), Value("Nothing to update"), Value(null),
                    Value.dictOf("id", coid, "doid", doid, "scid", scid, "sid", sid, "gid", gid, "did", did));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response sqlView(Value doid, Value coid)
    {
        string schema, domain;
        getDomain(doid, schema, domain);
        auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("doid", doid, "coid", coid)));
        if (!r.ok)
            return internalServerError(r.error);
        if (r.value["rows"].length == 0)
            return gone(notFoundErrorMsg());
        auto data = r.value["rows"][0];
        auto sql = rt(CREATE_SQL, tv("data", data, "domain", domain, "schema", schema, "conn", conn));
        auto header = "-- CHECK: " ~ qtIdentStr(schema, domain) ~ "." ~ qtIdentStr(data["name"].toString) ~ "\n\n"
            ~ "-- ALTER DOMAIN " ~ qtIdentStr(schema, domain) ~ " DROP CONSTRAINT " ~ qtIdentStr(data["name"].toString)
            ~ ";\n\n";
        return makeResponse(Value(header ~ sql));
    }

    /// `get_sql`: `ok` false means `err` holds the response.
    string getSql(Value data, Value scid, Value doid, Value coid, out bool ok, out string name, out Response err)
    {
        Value oldData;
        try
        {
            string sql;
            if (!coid.isNone)
            {
                auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("doid", doid, "coid", coid)));
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
                oldData = r.value["rows"][0];
                sql = rt(UPDATE_SQL, tv("data", data, "o_data", oldData, "conn", conn));
            }
            else
            {
                string schema, domain;
                getDomain(doid, schema, domain);
                sql = rt(CREATE_SQL, tv("data", data, "domain", domain, "schema", schema, "conn", conn));
            }
            name = data.contains("name") ? data["name"].toString : oldData["name"].toString;
            ok = true;
            return sql.strip("\n");
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
        {
            err = internalServerError(e.msg);
            return null;
        }
    }

    private void getDomain(Value doid, out string schema, out string domain)
    {
        auto r = conn.execute2darray(rt("get_domain.sql", tv("doid", doid)));
        if (!r.ok)
            throw new Exception(r.error);
        if (r.value["rows"].length == 0)
            throw new ObjectGone(notFoundErrorMsg("Domain"));
        schema = r.value["rows"][0]["schema"].toString;
        domain = r.value["rows"][0]["domain"].toString;
    }
}
