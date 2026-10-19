/// `schemas/domains`: domains.
module pgadmin.browser.server_groups.servers.databases.schemas.domains;

import pgadmin.browser.common;
import pgadmin.browser.server_groups.servers.databases.schemas.utils;
import pgadmin.browser.server_groups.servers.databases.schemas.domains.domain_constraints : DomainConstraintModule;
import pgadmin.browser.server_groups.servers.databases.utils : parseSecLabelsFromDb;

final class DomainModule : SchemaChildModule
{
    enum NODE_TYPE = "domain";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "Domains";
        minVer = Value(null);
        maxVer = Value(null);
        staticDir("browser/server_groups/servers/databases/schemas/domains");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => "database";

    override Value[] getNodes(Dict kwargs)
    {
        if (hasNodes(kwargs["sid"], kwargs["did"], kwargs["scid"], Value(null), Value(null), DomainView.BASE_TEMPLATE_PATH))
            return [generateBrowserCollectionNode(kwargs["scid"])];
        return null;
    }

    override void setup()
    {
        submodules ~= new DomainConstraintModule;
        registerNodeView!DomainView(this);
    }
}

final class DomainView : PGChildNodeView
{
    enum BASE_TEMPLATE_PATH = "domains/sql/#{0}#";

    private Value req_; /// `self.request` set by `validate_request`

    this()
    {
        super();
        nodeType = DomainModule.NODE_TYPE;
        nodeLabel = "Domain";
        parentIds = [IdSpec("int", "gid"), IdSpec("int", "sid"), IdSpec("int", "did"), IdSpec("int", "scid")];
        ids = [IdSpec("int", "doid")];
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
            makeOp("get_types", ["get": "types"], ["get": "types"]),
            makeOp("get_collations", ["get": "get_collations"], ["get": "get_collations"]),
            makeOp("compare", ["get": "compare"], ["get": "compare"]),
        ]);
    }

    /// `validate_request`: parses the body/query into `req_`; returns an error response or null.
    private Response validateRequest(Dict k)
    {
        auto req = argsOrJson();
        if (!k.has("doid"))
            foreach (arg; ["name", "basetype"])
                if (!req.contains(arg) || req[arg] == Value(""))
                    return makeJsonResponse(0, Value(gettext("Could not find the required parameter ({}).").replace("{}", arg)),
                            Value(""), Value(null), Value(null), 410);
        try
        {
            auto data = Value.newDict();
            bool isGet = request().method == "GET";
            foreach (key, v; req.dict)
            {
                if (isGet && (key == "constraints" || key == "seclabels") && v != Value("") && !v.isNone)
                    data[key] = parseJson(v.toString);
                else if (key == "typnotnull")
                {
                    if (v == Value("true") || (v.type == VType.boolean && v.boolean))
                        data[key] = Value(true);
                    else if (v == Value("false") || (v.type == VType.boolean && !v.boolean))
                        data[key] = Value(false);
                    else
                        data[key] = Value("");
                }
                else
                    data[key] = v;
            }
            req_ = data;
        }
        catch (Exception e)
            return internalServerError(e.msg);
        return null;
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
        auto doid = k.has("doid") ? k["doid"] : Value(null);
        if (name == "create" || name == "update" || name == "msql")
        {
            auto ve = validateRequest(k);
            if (ve !is null)
                return ve;
        }
        switch (name)
        {
        case "list": return list(scid);
        case "nodes": return nodes(scid);
        case "node": return node(scid, doid);
        case "properties": return properties(scid, doid);
        case "get_collations": return getCollations();
        case "types": return types();
        case "create": return create(gid, sid, scid);
        case "delete": return delete_(scid, doid);
        case "update": return update(gid, sid, scid, doid);
        case "msql": return msql(gid, sid, scid, doid);
        case "sql": return sqlView(scid, doid);
        case "dependents": return makeResponse(getDependents(conn, doid), 200);
        case "dependencies": return makeResponse(getDependencies(conn, doid), 200);
        default: return super.callMethod(name, k);
        }
    }

    private Response list(Value scid)
    {
        auto r = conn.executeDict(rt(NODE_SQL, tv("scid", scid)));
        if (!r.ok)
            return internalServerError(r.error);
        return makeResponse(r.value["rows"], 200);
    }

    private Response nodes(Value scid)
    {
        auto r = conn.execute2darray(rt(NODE_SQL, tv("scid", scid)));
        if (!r.ok)
            return internalServerError(r.error);
        Value[] res;
        foreach (row; r.value["rows"].list.items)
            res ~= gbn(row["oid"], scid, row["name"].toString, "icon-domain",
                    kwDict("description", row["description"]));
        return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
    }

    private Response node(Value scid, Value doid)
    {
        auto r = conn.execute2darray(rt(NODE_SQL, tv("doid", doid)));
        if (!r.ok)
            return internalServerError(r.error);
        foreach (row; r.value["rows"].list.items)
            return makeJsonResponse(1, Value(""), Value(""), Value(null), gbn(row["oid"], scid,
                    row["name"].toString, "icon-domain"), 200);
        return gone(notFoundErrorMsg());
    }

    private Response properties(Value scid, Value doid)
    {
        Response err;
        auto res = fetchProperties(scid, doid, err);
        if (err !is null)
            return err;
        return makeResponse(res, 200);
    }

    private static Dict parseType(string basetype)
    {
        string typLen, typPrecision;
        auto idx = basetype.indexOf("(");
        if (basetype != "" && idx > 0)
        {
            auto substr = basetype[idx + 1 .. basetype.length - 1];
            auto parts = substr.split(",");
            typLen = parts[0];
            typPrecision = parts.length > 1 ? parts[1] : "";
        }
        auto d = new Dict;
        d["typlen"] = Value(typLen);
        d["precision"] = Value(typPrecision);
        return d;
    }

    Value fetchProperties(Value scid, Value doid, out Response err)
    {
        auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("scid", scid, "doid", doid)));
        if (!r.ok)
        {
            err = internalServerError(r.error);
            return Value(null);
        }
        if (r.value["rows"].length == 0)
        {
            err = gone(gettext("\nCould not find the domain in the database.\n"
                    ~ "It may have been removed by another user or moved to another schema.\n"));
            return Value(null);
        }
        auto data = r.value["rows"][0];
        data.dict.update(parseType(data["fulltype"].toString));
        auto c = conn.executeDict(rt(GET_CONSTRAINTS_SQL, tv("doid", doid)));
        if (!c.ok)
        {
            err = internalServerError(c.error);
            return Value(null);
        }
        data["constraints"] = c.value["rows"];
        if (data.contains("seclabels"))
            data.dict.update(parseSecLabelsFromDb(data["seclabels"]));
        data["sysdomain"] = Value(false);
        if (doid.integer <= DATABASE_LAST_SYSTEM_OID_ || datistemplate)
            data["sysdomain"] = Value(true);
        return data;
    }

    private Response getCollations()
    {
        Value[] res = [Value.dictOf("label", "", "value", "")];
        try
        {
            auto r = conn.execute2darray(rt("get_collations.sql"));
            if (!r.ok)
                return internalServerError(r.error);
            foreach (row; r.value["rows"].list.items)
                res ~= Value.dictOf("label", row["copy_collation"], "value", row["copy_collation"]);
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response types()
    {
        string condition = "typisdefined AND typtype IN ('b', 'c', 'd', 'e', 'r')\n"
            ~ "AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_class\n"
            ~ "WHERE relnamespace=typnamespace AND relname = typname AND relkind != 'c') AND\n"
            ~ "(typname NOT LIKE '_%' OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_class WHERE\n"
            ~ "relnamespace=typnamespace AND relname = substring(typname FROM 2)::name\n"
            ~ "AND relkind != 'c'))";
        if (!bpModule.showSystemObjectsFlag)
            condition ~= " AND nsp.nspname != 'information_schema'";
        auto r = DataTypeReader.getTypes(conn, condition);
        if (!r.ok)
            return internalServerError(r.value.toString);
        return makeJsonResponse(1, Value(""), Value(""), Value(null), r.value, 200);
    }

    private Response create(Value gid, Value sid, Value scid)
    {
        auto data = req_;
        Response err;
        string name;
        auto sql = getSql(gid, sid, data, scid, Value(null), name, err);
        if (err !is null)
            return err;
        auto r = conn.executeScalar(sql);
        if (!r.ok)
            return internalServerError(r.error);
        auto o = conn.executeScalar(rt(OID_SQL, tv("basensp", data["basensp"], "name", data["name"], "conn", conn)));
        if (!o.ok)
            return internalServerError(o.error);
        auto doid = o.value;
        auto s = conn.executeScalar(rt(OID_SQL, tv("doid", doid, "conn", conn)));
        if (!s.ok)
            return internalServerError(s.error);
        return jsonify(Value.dictOf("node", gbn(doid, s.value, data["name"].toString,
                "icon-domain")));
    }

    Response delete_(Value scid, Value doidArg, bool onlySql = false)
    {
        Value data = doidArg.isNone ? formOrJson(request()) : Value.dictOf("ids", Value([doidArg]));
        bool cascade = checkCascadeOperation(onlySql);
        foreach (doid; data["ids"].iterItems())
        {
            auto r = conn.execute2darray(rt(DELETE_SQL, tv("scid", scid, "doid", doid)));
            if (!r.ok)
                return internalServerError(r.error);
            if (r.value["rows"].length == 0)
                return makeJsonResponse(0, Value(gettext("Error: Object not found.")), Value(notFoundErrorMsg()),
                        Value(null), Value(null), 410);
            auto row = r.value["rows"][0];
            auto sql = rt(DELETE_SQL, tv("name", row["name"], "basensp", row["basensp"], "cascade", cascade));
            if (onlySql)
                return Response.sqlOnly(sql);
            auto x = conn.executeScalar(sql);
            if (!x.ok)
                return internalServerError(x.error);
        }
        return makeJsonResponse(1, Value(""), Value(gettext("Domain dropped")));
    }

    private Response update(Value gid, Value sid, Value scid, Value doid)
    {
        Response err;
        string name;
        auto sql = getSql(gid, sid, req_, scid, doid, name, err);
        if (err !is null)
            return err;
        auto r = conn.executeScalar(sql);
        if (!r.ok)
            return internalServerError(r.error);
        auto s = conn.executeScalar(rt(OID_SQL, tv("doid", doid, "conn", conn)));
        if (!s.ok)
            return internalServerError(s.error);
        Dict other;
        if (req_.contains("description"))
            other = kwDict("description", req_["description"]);
        return jsonify(Value.dictOf("node", gbn(doid, s.value, name, "icon-" ~ nodeType, other)));
    }

    private Response sqlView(Value scid, Value doid, string targetSchema = null, bool jsonResp = true)
    {
        auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("scid", scid, "doid", doid)));
        if (!r.ok)
            return internalServerError(r.error);
        if (r.value["rows"].length == 0)
            return gone(notFoundErrorMsg());
        auto data = r.value["rows"][0];
        if (targetSchema.length)
            data["basensp"] = Value(targetSchema);
        data.dict.update(parseType(data["fulltype"].toString));
        auto c = conn.executeDict(rt(GET_CONSTRAINTS_SQL, tv("doid", doid)));
        if (!c.ok)
            return internalServerError(c.error);
        data["constraints"] = c.value["rows"];
        if (data.contains("seclabels"))
            data.dict.update(parseSecLabelsFromDb(data["seclabels"]));
        auto sql = rt(CREATE_SQL, tv("data", data, "conn", conn));
        auto header = "-- DOMAIN: " ~ data["basensp"].toString ~ "." ~ data["name"].toString ~ "\n\n";
        header ~= "-- DROP DOMAIN IF EXISTS " ~ qtIdentStr(data["basensp"].toString, data["name"].toString) ~ ";\n\n";
        sql = (header ~ sql).strip("\n");
        if (!jsonResp)
            return Response.sqlOnly(sql);
        return makeResponse(Value(sql));
    }

    private Response msql(Value gid, Value sid, Value scid, Value doid)
    {
        try
        {
            Response err;
            string name;
            auto sql = getSql(gid, sid, req_, scid, doid, name, err);
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

    private string checkDomainType(Value data, Value oldData, bool isSchemaDiff)
    {
        if (data.contains("fulltype") || data.contains("basetype") || data.contains("collname"))
            return rt("domain_schema_diff.sql", tv("data", data, "o_data", oldData, "conn", conn));
        if (isSchemaDiff)
            data["is_schema_diff"] = Value(true);
        return rt(UPDATE_SQL, tv("data", data, "o_data", oldData, "conn", conn));
    }

    string getSql(Value gid, Value sid, Value data, Value scid, Value doid, out string name, out Response err,
            bool isSchemaDiff = false)
    {
        if (!doid.isNone)
        {
            auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("scid", scid, "doid", doid)));
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
            auto c = conn.executeDict(rt(GET_CONSTRAINTS_SQL, tv("doid", doid)));
            if (!c.ok)
            {
                err = internalServerError(c.error);
                return null;
            }
            auto conData = Value.newDict();
            foreach (row; c.value["rows"].list.items)
                conData[row["conoid"].toString] = row;
            oldData["constraints"] = conData;
            auto sql = checkDomainType(data, oldData, isSchemaDiff);
            name = data.contains("name") ? data["name"].toString : oldData["name"].toString;
            return sql.strip("\n");
        }
        auto sql = rt(CREATE_SQL, tv("data", data, "conn", conn));
        name = data["name"].toString;
        return sql.strip("\n");
    }

    /// The domain's dependencies plus those of its constraints.
    override Value getDependencies(Connection c, Value objectId, string where = null,
            Value showSystemObjects = Value(null), bool isSchemaDiff = false)
    {
        auto result = Value.newList();
        foreach (d; super.getDependencies(c, objectId, null, Value(null), true).iterItems())
            result.append(d);
        auto r = conn.executeDict(rt(GET_CONSTRAINTS_SQL, tv("doid", objectId)));
        if (!r.ok)
            return Value(false);
        foreach (row; r.value["rows"].list.items)
            foreach (d; super.getDependencies(c, row["conoid"], null, Value(null), true).iterItems())
                result.append(d);
        return result;
    }
}
