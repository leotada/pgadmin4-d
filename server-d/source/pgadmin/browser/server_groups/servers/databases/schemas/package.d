/// `pgadmin/browser/server_groups/servers/databases/schemas`: the Schema and Catalog nodes.
///
/// One module for both, as in the original: catalogs behave like schemas but cannot be modified, and both share the
/// same child modules.
module pgadmin.browser.server_groups.servers.databases.schemas;

import std.algorithm : canFind;
import std.array : join, replace, split;
import std.conv : to;
import std.regex : regex, matchFirst;
import std.string : strip;
import pgadmin.browser.server_groups.servers.utils;
import pgadmin.browser.utils;
import pgadmin.core.i18n;
import pgadmin.core.log;
import pgadmin.core.templates;
import pgadmin.core.value;
import pgadmin.db.driver;
import pgadmin.model;
import pgadmin.web.auth;
import pgadmin.web.context;
import pgadmin.web.flask;
import pgadmin.web.http;

final class SchemaModule : CollectionNodeModule
{
    enum NODE_TYPE = "schema";
    string nodeTypeName = NODE_TYPE;

    this(string nodeTypeName_ = NODE_TYPE, string label = "Schemas")
    {
        super(nodeTypeName_);
        nodeTypeName = nodeTypeName_;
        collectionLabelText = label;
        minVer = Value(null);
        maxVer = Value(null);
        staticDir("browser/server_groups/servers/databases/schemas");
    }

    override string nodeType() => nodeTypeName;
    override string scriptLoad() => "server";

    override Value[] getNodes(Dict kwargs)
    {
        if (nodeTypeName == "catalog")
            return [generateBrowserCollectionNode(kwargs["did"])];
        if (hasNodes(kwargs["sid"], kwargs["did"], Value(null), Value(null), Value(null),
                SchemaView.BASE_TEMPLATE_PATH_STATIC ~ "/" ~ SchemaView.SQL_PREFIX))
            return [generateBrowserCollectionNode(kwargs["did"])];
        return null;
    }

    override void setup()
    {
        import pgadmin.browser.server_groups.servers.databases.schemas.registry : registerSchemaSubmodules;
        registerSchemaSubmodules(this);
        if (nodeTypeName == "catalog")
            registerNodeView!CatalogView(this);
        else
            registerNodeView!SchemaView(this);
    }
}

/// `SchemaView` (and the base of `CatalogView`)
class SchemaView : PGChildNodeView
{
    enum SQL_PREFIX = "sql/";
    enum BASE_TEMPLATE_PATH_STATIC = "schemas/{0}/#{1}#";

    string baseTemplatePath = BASE_TEMPLATE_PATH_STATIC;
    ServerManager manager;
    Connection conn;
    string templatePath;
    bool datistemplate;

    this()
    {
        super();
        nodeType = "schema";
        nodeLabel = "Schema";
        parentIds = [IdSpec("int", "gid"), IdSpec("int", "sid"), IdSpec("int", "did")];
        ids = [IdSpec("int", "scid")];
        setAllOps([
            makeOp("obj", ["get": "properties", "delete": "delete", "put": "update"],
                    ["get": "list", "post": "create", "delete": "delete"]),
            makeOp("children", ["get": "children"]),
            makeOp("nodes", ["get": "nodes"], ["get": "nodes"]),
            makeOp("sql", ["get": "sql"]),
            makeOp("msql", ["get": "msql"], ["get": "msql"]),
            makeOp("stats", ["get": "statistics"]),
            makeOp("dependency", ["get": "dependencies"]),
            makeOp("dependent", ["get": "dependents"]),
            makeOp("delete", ["delete": "delete"], ["delete": "delete"]),
        ]);
    }

    /// Python computes this once from the schema blueprint, so catalogs use the schema icon too.
    string nodeIcon() => "icon-schema";

    /// `@check_precondition`
    Response checkPrecondition(Dict kwargs)
    {
        manager = getDriver().connectionManagerOrNull(kwargs["sid"].integer);
        if (manager is null)
            return gone(gettext("Could not find the server."));
        conn = manager.connection(null, null, true, kwargs["did"]);
        datistemplate = false;
        if (manager.dbInfo !is null && manager.dbInfo.has(kwargs["did"].toString)
                && manager.dbInfo[kwargs["did"].toString].contains("datistemplate"))
            datistemplate = manager.dbInfo[kwargs["did"].toString]["datistemplate"].truthy;
        templatePath = baseTemplatePath.replace("{0}", manager.serverType).replace("{1}", to!string(manager.version_));
        return null;
    }

    override Response callMethod(string name, Dict k)
    {
        if (!isAuthenticated())
            return unauthorisedResponse();
        auto err = checkPrecondition(k);
        if (err !is null)
            return err;
        auto gid = k.has("gid") ? k["gid"] : Value(null);
        auto sid = k["sid"];
        auto did = k["did"];
        auto scid = k.has("scid") ? k["scid"] : Value(null);
        switch (name)
        {
        case "list": return list(gid, sid, did);
        case "nodes": return nodes(gid, sid, did, scid);
        case "node": return node(gid, sid, did, scid);
        case "properties": return properties(gid, sid, did, scid);
        case "create": return create(gid, sid, did);
        case "update": return update(gid, sid, did, scid);
        case "delete": return delete_(gid, sid, did, scid);
        case "msql": return msql(gid, sid, did, scid);
        case "sql": return sqlView(gid, sid, did, scid);
        case "dependents": return makeResponse(getDependents(conn, scid), 200);
        case "dependencies": return makeResponse(getDependencies(conn, scid), 200);
        case "children": return childrenView(k);
        default: return super.callMethod(name, k);
        }
    }

    // ---- acl helpers

    Value formatRequestAcls(Value data, bool modified = false, string[] specific = null)
    {
        Value acls = Value.newDict();
        try
            acls = parseJson(renderTemplate(templatePath ~ "/allowed_privs.json"));
        catch (Exception e)
            logException(e);
        foreach (aclcol, allowed; acls.dict)
        {
            if (specific.length && !specific.canFind(aclcol))
                continue;
            if (!data.contains(aclcol))
                continue;
            string[] a;
            foreach (x; allowed["acl"].iterItems())
                a ~= x.toString;
            if (modified)
            {
                foreach (modifier; ["added", "changed", "deleted"])
                    if (data[aclcol].contains(modifier))
                        data[aclcol][modifier] = parsePrivToDb(data[aclcol][modifier], a);
            }
            else
                data[aclcol] = parsePrivToDb(data[aclcol], a);
        }
        return acls;
    }

    static Value formatDbAcl(Value acl)
    {
        auto data = Value.newDict();
        foreach (row; acl["rows"].list.items)
        {
            auto priv = parsePrivFromDb(row);
            auto t = row["deftype"].toString;
            if (data.contains(t))
                data[t].append(priv);
            else
                data[t] = Value([priv]);
        }
        return data;
    }

    Value formatterNoDefacl(Value data, Value scid, out Response err)
    {
        Value[] seclabels;
        if (data.contains("seclabels") && !data["seclabels"].isNone)
            foreach (sec; data["seclabels"].iterItems())
            {
                auto m = matchFirst(sec.toString, regex(`([^=]+)=(.*$)`));
                seclabels ~= Value.dictOf("provider", m[1].idup, "label", m[2].idup);
            }
        data["seclabels"] = Value(seclabels);
        auto sql = renderTemplate(templatePath ~ "/sql/acl.sql", tv("scid", scid, "conn", conn));
        auto r = conn.executeDict(sql);
        if (!r.ok)
        {
            err = internalServerError(r.error);
            return data;
        }
        data.dict.update(formatDbAcl(r.value).dict);
        return data;
    }

    Value formatter(Value data, Value scid, out Response err)
    {
        formatterNoDefacl(data, scid, err);
        if (err !is null)
            return data;
        auto sql = renderTemplate(templatePath ~ "/sql/defacl.sql", tv("scid", scid));
        auto r = conn.executeDict(sql);
        if (!r.ok)
        {
            err = internalServerError(r.error);
            return data;
        }
        data.dict.update(formatDbAcl(r.value).dict);
        return data;
    }

    private Value schemaRestrictions(Value did, Value sid)
    {
        auto database = db.queryOne("SELECT schema_res FROM \"database\" WHERE id = ? AND server = ?", did, sid);
        if (database.isDict && database["schema_res"].truthy)
        {
            string[] ps;
            foreach (p; database["schema_res"].toString.split(","))
                ps ~= "'" ~ p ~ "'";
            return Value(ps.join(","));
        }
        return Value(null);
    }

    // ---- views

    Response list(Value gid, Value sid, Value did)
    {
        auto param = schemaRestrictions(did, sid);
        auto sql = renderTemplate(templatePath ~ "/" ~ SQL_PREFIX ~ PROPERTIES_SQL, tv("show_sysobj",
                bpModule.showSystemObjectsFlag, "schema_restrictions", param));
        auto r = conn.executeDict(sql);
        if (!r.ok)
            return internalServerError(r.error);
        return makeResponse(r.value["rows"], 200);
    }

    Response nodes(Value gid, Value sid, Value did, Value scid, bool isSchemaDiff = false)
    {
        auto param = schemaRestrictions(did, sid);
        bool showSystem = bpModule.showSystemObjectsFlag;
        if (isSchemaDiff)
            showSystem = false;
        auto sql = renderTemplate(templatePath ~ "/" ~ SQL_PREFIX ~ NODES_SQL, tv("show_sysobj", showSystem, "scid", scid,
                "schema_restrictions", param, "conn", conn));
        auto r = conn.execute2darray(sql);
        if (!r.ok)
            return internalServerError(r.error);
        if (!scid.isNone)
        {
            if (r.value["rows"].length == 0)
                return gone(gettext("Could not find the schema in the database.\n                    It may have been removed by another user."));
            auto row = r.value["rows"][0];
            return makeJsonResponse(1, Value(""), Value(""), Value(null), bpModule.generateBrowserNode(row["oid"], did,
                    row["name"].toString, nodeIcon, true, nodeType, kwDict("can_create", row["can_create"], "has_usage",
                        row["has_usage"], "description", row["description"])), 200);
        }
        Value[] res;
        foreach (row; r.value["rows"].list.items)
            res ~= bpModule.generateBrowserNode(row["oid"], did, row["name"].toString, nodeIcon, true, nodeType,
                    kwDict("can_create", row["can_create"], "has_usage", row["has_usage"], "description", row["description"]));
        return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
    }

    Response node(Value gid, Value sid, Value did, Value scid)
    {
        auto sql = renderTemplate(templatePath ~ "/" ~ SQL_PREFIX ~ NODES_SQL, tv("show_sysobj", bpModule.showSystemObjectsFlag,
                "scid", scid, "conn", conn));
        auto r = conn.execute2darray(sql);
        if (!r.ok)
            return internalServerError(r.error);
        if (!scid.isNone && r.value["rows"].length == 0)
            return gone(gettext("\nCould not find the schema in the database.\nIt may have been removed by another user.\n"));
        foreach (row; r.value["rows"].list.items)
            return makeJsonResponse(1, Value(""), Value(""), Value(null), bpModule.generateBrowserNode(row["oid"], did,
                    row["name"].toString, nodeIcon, true, nodeType, kwDict("can_create", row["can_create"], "has_usage",
                        row["has_usage"])), 200);
        return makeJsonResponse(1);
    }

    Response properties(Value gid, Value sid, Value did, Value scid)
    {
        auto sql = renderTemplate(templatePath ~ "/" ~ SQL_PREFIX ~ PROPERTIES_SQL, tv("scid", scid, "show_sysobj",
                bpModule.showSystemObjectsFlag));
        auto r = conn.executeDict(sql);
        if (!r.ok)
            return internalServerError(r.error);
        if (r.value["rows"].length == 0)
            return gone(gettext("Could not find the schema in the database. It may have been removed by another user."));
        auto copyData = Value(r.value["rows"][0].dict.copy());
        copyData["is_sys_obj"] = Value(copyData["oid"].integer <= DATABASE_LAST_SYSTEM_OID_ || datistemplate);
        Response err;
        copyData = formatterFor2(copyData, scid, err);
        if (err !is null)
            return err;
        return makeResponse(copyData, 200);
    }

    Response create(Value gid, Value sid, Value did)
    {
        auto data = formOrJson(request());
        foreach (k; data.dict.keys)
            if (k != "comment" && data[k].isString)
                data[k] = tryParseJson(data[k].str, data[k]);
        foreach (arg; ["name"])
            if (!data.contains(arg))
                return makeJsonResponse(0, Value(gettext("Could not find the required parameter ({}).").replace("{}", arg)),
                        Value(""), Value(null), Value(null), 410);
        try
        {
            formatRequestAcls(data);
            auto sql = renderTemplate(templatePath ~ "/" ~ SQL_PREFIX ~ CREATE_SQL, tv("data", data, "conn", conn));
            auto r = conn.executeScalar(sql);
            if (!r.ok)
                return makeJsonResponse(0, r.value, Value(""), Value(null), Value(null), 410);
            sql = renderTemplate(templatePath ~ "/sql/oid.sql", tv("schema", data["name"], "conn", conn));
            auto o = conn.executeScalar(sql);
            if (!o.ok)
                return internalServerError(o.error);
            return jsonify(Value.dictOf("node", bpModule.generateBrowserNode(o.value, did, data["name"].toString,
                    nodeIcon, true, nodeType)));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
        {
            logException(e);
            return internalServerError(e.msg);
        }
    }

    Response update(Value gid, Value sid, Value did, Value scid)
    {
        auto data = formOrJson(request());
        try
        {
            Response err;
            string name;
            auto sql = getSql(gid, sid, data, scid, name, err);
            if (err !is null)
                return err;
            sql = sql.strip("\n").strip(" ");
            auto r = conn.executeScalar(sql);
            if (!r.ok)
                return internalServerError(r.error);
            Dict other;
            if (data.contains("description"))
                other = kwDict("description", data["description"]);
            return jsonify(Value.dictOf("node", bpModule.generateBrowserNode(scid, did, name, nodeIcon, true, nodeType, other)));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    Response delete_(Value gid, Value sid, Value did, Value scidArg)
    {
        Value data = scidArg.isNone ? formOrJson(request()) : Value.dictOf("ids", Value([scidArg]));
        foreach (scid; data["ids"].iterItems())
        {
            try
            {
                auto n = conn.executeScalar(renderTemplate(templatePath ~ "/sql/get_name.sql", tv("scid", scid, "conn", conn)));
                if (!n.ok)
                    return internalServerError(n.error);
                if (n.value.isNone)
                    return makeJsonResponse(0, Value(gettext("Error: Object not found.")),
                            Value(gettext("The specified schema could not be found.\n")), Value(null), Value(null), 410);
                auto sql = renderTemplate(templatePath ~ "/" ~ SQL_PREFIX ~ DELETE_SQL, tv("name", n.value, "conn", conn,
                        "cascade", checkCascadeOperation()));
                auto r = conn.executeScalar(sql);
                if (!r.ok)
                    return internalServerError(r.error);
            }
            catch (HTTPException e)
                throw e;
            catch (Exception e)
            {
                logException(e);
                return internalServerError(e.msg);
            }
        }
        return makeJsonResponse(1, Value(""), Value(gettext("Schema dropped")));
    }

    Response msql(Value gid, Value sid, Value did, Value scid)
    {
        auto data = Value.newDict();
        foreach (k; request().args.keys)
        {
            auto v = request().args.get(k);
            data[k] = k == "description" ? Value(v) : tryParseJson(v, Value(v));
        }
        try
        {
            Response err;
            string name;
            auto sql = getSql(gid, sid, data, scid, name, err);
            if (err !is null)
                return err;
            if (sql.strip("\n").length && sql.strip(" ").length)
                return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(sql.strip("\n")), 200);
            return internalServerError("The view function did not return a valid response.");
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    string formatterFor(Value oldData, Value scid, out Response err)
    {
        formatter(oldData, scid, err);
        return null;
    }

    /// `get_sql(gid, sid, data, scid)`: the SQL and the name of the schema.
    string getSql(Value gid, Value sid, Value data, Value scid, out string name, out Response err)
    {
        if (!scid.isNone)
        {
            auto sql = renderTemplate(templatePath ~ "/" ~ SQL_PREFIX ~ PROPERTIES_SQL, tv("scid", scid, "show_sysobj",
                    bpModule.showSystemObjectsFlag));
            auto r = conn.executeDict(sql);
            if (!r.ok)
            {
                err = internalServerError(r.error);
                return null;
            }
            auto oldData = r.value["rows"][0];
            oldData = formatterFor2(oldData, scid, err);
            if (err !is null)
                return null;
            if (!data.contains("name"))
                data["name"] = oldData["name"];
            formatRequestAcls(data, true);
            sql = renderTemplate(templatePath ~ "/" ~ SQL_PREFIX ~ UPDATE_SQL, tv("data", data, "o_data", oldData, "conn", conn));
            name = data.contains("name") ? data["name"].toString : oldData["nam"].toString;
            return sql;
        }
        foreach (arg; ["name"])
            if (!data.contains(arg))
                throw new Exception("too many values to unpack (expected 2)");
        formatRequestAcls(data);
        auto sql = renderTemplate(templatePath ~ "/" ~ SQL_PREFIX ~ CREATE_SQL, tv("data", data, "conn", conn));
        name = data["name"].toString;
        return sql;
    }

    /// Hook so that catalogs skip the default ACL part.
    Value formatterFor2(Value data, Value scid, out Response err) => formatter(data, scid, err);

    Response sqlView(Value gid, Value sid, Value did, Value scid)
    {
        auto sql = renderTemplate(templatePath ~ "/" ~ SQL_PREFIX ~ PROPERTIES_SQL, tv("scid", scid));
        auto r = conn.executeDict(sql);
        if (!r.ok)
            return internalServerError(r.error);
        if (r.value["rows"].length == 0)
            return gone(gettext("Could not find the schema in the database."));
        auto data = r.value["rows"][0];
        Response err;
        data = formatterFor2(data, scid, err);
        if (err !is null)
            return err;
        formatRequestAcls(data);
        sql = renderTemplate(templatePath ~ "/" ~ SQL_PREFIX ~ CREATE_SQL, tv("data", data, "conn", conn,
                "add_not_exists_clause", true));
        auto header = "-- SCHEMA: " ~ data["name"].toString ~ "\n\n-- ";
        header ~= renderTemplate(templatePath ~ "/" ~ SQL_PREFIX ~ DELETE_SQL, tv("name", data["name"], "conn", conn,
                "cascade", false));
        sql = header ~ "\n\n" ~ sql;
        return makeResponse(Value(sql.strip("\n")));
    }

    Response childrenView(Dict kwargs)
    {
        auto sql = renderTemplate(templatePath ~ "/sql/is_catalog.sql", tv("scid", kwargs["scid"], "conn", conn));
        auto r = conn.executeDict(sql);
        if (!r.ok)
            return internalServerError(r.error);
        if (r.value["rows"].length == 0)
            return gone(gettext("Could not find the schema in the database.\n                It may have been removed by another user."));
        auto data = r.value["rows"][0];
        auto support = kwargs.copy();
        support["is_catalog"] = data["is_catalog"];
        support["db_support"] = data["db_support"];
        support["schema_name"] = data["schema_name"];
        Value[] nodes;
        foreach (m; bpModule.submodules)
        {
            auto cm = cast(CollectionNodeModule) m;
            if (cm !is null)
            {
                if (manager !is null && cm.backendSupported(manager, support))
                    nodes ~= cm.getNodes(kwargs);
            }
            else if (auto b = cast(BrowserPluginModule) m)
                nodes ~= b.getNodes(kwargs);
        }
        return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(nodes));
    }
}

final class CatalogView : SchemaView
{
    this()
    {
        super();
        nodeType = "catalog";
        baseTemplatePath = "catalog/{0}/#{1}#";
    }

    override Value formatterFor2(Value data, Value scid, out Response err)
    {
        formatterNoDefacl(data, scid, err);
        return data;
    }

    override string getSql(Value gid, Value sid, Value data, Value scid, out string name, out Response err)
    {
        if (scid.isNone)
        {
            err = badRequest("Cannot create a catalog schema!");
            return null;
        }
        return super.getSql(gid, sid, data, scid, name, err);
    }

    override Response sqlView(Value gid, Value sid, Value did, Value scid)
    {
        auto sql = renderTemplate(templatePath ~ "/" ~ SQL_PREFIX ~ PROPERTIES_SQL, tv("scid", scid));
        auto r = conn.executeDict(sql);
        if (!r.ok)
            return internalServerError(r.error);
        if (r.value["rows"].length == 0)
            return gone(gettext("\nCould not find the schema in the database.\nIt may have been removed by another user.\n"));
        auto oldData = r.value["rows"][0];
        Response err;
        oldData = formatterFor2(oldData, scid, err);
        formatRequestAcls(oldData, false, ["nspacl"]);
        sql = renderTemplate(templatePath ~ "/" ~ SQL_PREFIX ~ CREATE_SQL, tv("data", oldData, "conn", conn,
                "add_not_exists_clause", true));
        auto header = "\n-- CATALOG: " ~ oldData["name"].toString ~ "\n\n-- DROP SCHEMA IF EXISTS " ~ oldData["name"].toString ~ ";\n\n";
        return makeResponse(Value((header ~ sql).strip("\n")));
    }
}
