/// `databases/foreign_data_wrappers`: foreign data wrappers.
module pgadmin.browser.server_groups.servers.databases.foreign_data_wrappers;

import pgadmin.browser.common;
import pgadmin.browser.server_groups.servers.databases.foreign_data_wrappers.foreign_servers : ForeignServerModule;

final class ForeignDataWrapperModule : CollectionNodeModule
{
    enum NODE_TYPE = "foreign_data_wrapper";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "Foreign Data Wrappers";
        minVer = Value(null);
        maxVer = Value(null);
        staticDir("browser/server_groups/servers/databases/foreign_data_wrappers");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => "database";
    override bool moduleUseTemplateJavascript() => false;

    override Value[] getNodes(Dict kwargs)
    {
        if (hasNodes(kwargs["sid"], kwargs["did"], Value(null), Value(null), Value(null), ForeignDataWrapperView.BASE_TEMPLATE_PATH))
            return [generateBrowserCollectionNode(kwargs["did"])];
        return null;
    }

    override void setup()
    {
        submodules ~= new ForeignServerModule;
        registerNodeView!ForeignDataWrapperView(this);
    }
}

final class ForeignDataWrapperView : PGChildNodeView
{
    enum BASE_TEMPLATE_PATH = "foreign_data_wrappers/sql/#{0}#";

    this()
    {
        super();
        nodeType = ForeignDataWrapperModule.NODE_TYPE;
        nodeLabel = "Foreign Data Wrapper";
        parentIds = [IdSpec("int", "gid"), IdSpec("int", "sid"), IdSpec("int", "did")];
        ids = [IdSpec("int", "fid")];
        setAllOps([
            makeOp("obj", ["get": "properties", "delete": "delete", "put": "update"],
                    ["get": "list", "post": "create", "delete": "delete"]),
            makeOp("delete", ["delete": "delete"], ["delete": "delete"]),
            makeOp("nodes", ["get": "node"], ["get": "nodes"]),
            makeOp("children", ["get": "children"]),
            makeOp("sql", ["get": "sql"]),
            makeOp("msql", ["get": "msql"], ["get": "msql"]),
            makeOp("stats", ["get": "statistics"]),
            makeOp("dependency", ["get": "dependencies"]),
            makeOp("dependent", ["get": "dependents"]),
            makeOp("get_handlers", null, ["get": "get_handlers"]),
            makeOp("get_validators", null, ["get": "get_validators"]),
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
        auto fid = k.has("fid") ? k["fid"] : Value(null);
        switch (name)
        {
        case "list":
        {
            auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("conn", conn)));
            if (!r.ok)
                return internalServerError(r.error);
            foreach (row; r.value["rows"].list.items)
                if (!row["fdwoptions"].isNone)
                    row["fdwoptions"] = tokenizeOptions(row["fdwoptions"], "fdwoption", "fdwvalue");
            return makeResponse(r.value["rows"], 200);
        }
        case "nodes":
        {
            auto r = conn.execute2darray(rt(PROPERTIES_SQL, tv("conn", conn)));
            if (!r.ok)
                return internalServerError(r.error);
            Value[] res;
            foreach (row; r.value["rows"].list.items)
                res ~= gbn(row["oid"], did, row["name"].toString, "icon-foreign_data_wrapper",
                        kwDict("description", row["description"]));
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        case "node":
        {
            auto r = conn.execute2darray(rt(PROPERTIES_SQL, tv("conn", conn, "fid", fid)));
            if (!r.ok)
                return internalServerError(r.error);
            foreach (row; r.value["rows"].list.items)
                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                        gbn(row["oid"], did, row["name"].toString, "icon-foreign_data_wrapper"), 200);
            return gone(gettext("Could not find the specified foreign data wrapper."));
        }
        case "properties":
        {
            Response e2;
            auto res = fetchProperties(fid, e2);
            if (e2 !is null)
                return e2;
            return makeResponse(res, 200);
        }
        case "create": return create(did);
        case "update": return update(gid, sid, did, fid);
        case "delete": return delete_(fid);
        case "msql":
        {
            auto data = msqlData("description");
            try
            {
                Response e2;
                string nm;
                auto sql = getSql(data, fid, nm, e2);
                if (e2 !is null)
                    return e2;
                if (sql == "")
                    sql = "--modified SQL";
                return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(sql.strip("\n")), 200);
            }
            catch (HTTPException e)
                throw e;
            catch (Exception e)
                return internalServerError(e.msg);
        }
        case "sql": return sqlView(fid);
        case "get_validators":
        {
            try
            {
                auto r = conn.execute2darray(rt("validators.sql", tv("conn", conn)));
                if (!r.ok)
                    return internalServerError(r.error);
                Value[] res;
                foreach (row; r.value["rows"].list.items)
                    res ~= Value.dictOf("label", row["schema_prefix_fdw_val"], "value", row["schema_prefix_fdw_val"]);
                return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
            }
            catch (HTTPException e)
                throw e;
            catch (Exception e)
                return internalServerError(e.msg);
        }
        case "get_handlers":
        {
            try
            {
                auto r = conn.execute2darray(rt("handlers.sql", tv("conn", conn)));
                if (!r.ok)
                    return internalServerError(r.error);
                Value[] res;
                foreach (row; r.value["rows"].list.items)
                    res ~= Value.dictOf("label", row["schema_prefix_fdw_hand"], "value", row["schema_prefix_fdw_hand"]);
                return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
            }
            catch (HTTPException e)
                throw e;
            catch (Exception e)
                return internalServerError(e.msg);
        }
        case "dependents": return makeResponse(getDependents(conn, fid), 200);
        case "dependencies": return makeResponse(getDependencies(conn, fid), 200);
        default: return super.callMethod(name, k);
        }
    }

    private void addAcl(Value row, Value aclRes)
    {
        foreach (a; aclRes["rows"].list.items)
        {
            auto privilege = parsePrivFromDb(a);
            auto t = a["deftype"].toString;
            if (row.contains(t))
                row[t].append(privilege);
            else
                row[t] = Value([privilege]);
        }
    }

    Value fetchProperties(Value fid, out Response err)
    {
        auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("fid", fid, "conn", conn)));
        if (!r.ok)
        {
            err = internalServerError(r.error);
            return Value(null);
        }
        if (r.value["rows"].length == 0)
        {
            err = gone(gettext("Could not find the foreign data wrapper information."));
            return Value(null);
        }
        auto row = r.value["rows"][0];
        row["is_sys_obj"] = Value(row["oid"].integer <= DATABASE_LAST_SYSTEM_OID_ || datistemplate);
        if (!row["fdwoptions"].isNone)
            row["fdwoptions"] = tokenizeOptions(row["fdwoptions"], "fdwoption", "fdwvalue");
        auto a = conn.executeDict(rt(ACL_SQL, tv("fid", fid, "conn", conn)));
        if (!a.ok)
        {
            err = internalServerError(a.error);
            return Value(null);
        }
        addAcl(row, a.value);
        return row;
    }

    private string createSql(Value data)
    {
        if (data.contains("fdwacl") && !data["fdwacl"].isNone)
            data["fdwacl"] = parsePrivToDb(data["fdwacl"], ["U"]);
        bool isValid;
        if (data.contains("fdwoptions"))
        {
            auto v = validateOptions(data["fdwoptions"], "fdwoption", "fdwvalue");
            isValid = v.isValid;
            data["fdwoptions"] = v.options;
        }
        return rt(CREATE_SQL, tv("data", data, "conn", conn, "is_valid_options", isValid));
    }

    private Response create(Value did)
    {
        auto data = formOrJson(request());
        auto miss = missingArg(data, ["name"]);
        if (miss !is null)
            return miss;
        try
        {
            if (data.contains("fdwacl"))
                data["fdwacl"] = parsePrivToDb(data["fdwacl"], ["U"]);
            bool isValid;
            if (data.contains("fdwoptions"))
            {
                auto v = validateOptions(data["fdwoptions"], "fdwoption", "fdwvalue");
                isValid = v.isValid;
                data["fdwoptions"] = v.options;
            }
            auto c = conn.executeDict(rt(CREATE_SQL, tv("data", data, "conn", conn, "is_valid_options", isValid)));
            if (!c.ok)
                return internalServerError(c.error);
            auto p = conn.executeDict(rt(PROPERTIES_SQL, tv("fname", data["name"], "conn", conn)));
            if (!p.ok)
                return internalServerError(p.error);
            foreach (row; p.value["rows"].list.items)
                return jsonify(Value.dictOf("node", gbn(row["oid"], did, row["name"].toString, "icon-foreign_data_wrapper")));
            throw new ViewReturnedNone;
        }
        catch (HTTPException e)
            throw e;
        catch (ViewReturnedNone e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response update(Value gid, Value sid, Value did, Value fid)
    {
        auto data = formOrJson(request());
        try
        {
            Response e2;
            string name;
            auto sql = getSql(data, fid, name, e2);
            if (e2 !is null)
                return e2;
            auto x = conn.executeScalar(sql);
            if (!x.ok)
                return internalServerError(x.error);
            Dict extra;
            if (data.contains("description"))
                extra = kwDict("description", data["description"]);
            return jsonify(Value.dictOf("node", gbn(fid, did, name, "icon-" ~ nodeType, extra)));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    Response delete_(Value fidArg, bool onlySql = false)
    {
        bool cascade = cmd == "delete";
        Value data = fidArg.isNone ? formOrJson(request()) : Value.dictOf("ids", Value([fidArg]));
        foreach (fid; data["ids"].iterItems())
        {
            try
            {
                auto n = conn.executeScalar(rt(DELETE_SQL, tv("fid", fid, "conn", conn)));
                if (!n.ok)
                    return internalServerError(n.error);
                if (n.value.isNone)
                    return makeJsonResponse(0, Value(gettext("Error: Object not found.")),
                            Value(gettext("The specified foreign data wrapper could not be found.\n")), Value(null),
                            Value(null), 410);
                auto sql = rt(DELETE_SQL, tv("name", n.value, "cascade", cascade, "conn", conn));
                if (onlySql)
                    return Response.sqlOnly(sql);
                auto x = conn.executeScalar(sql);
                if (!x.ok)
                    return internalServerError(x.error);
            }
            catch (HTTPException e)
                throw e;
            catch (Exception e)
                return internalServerError(e.msg);
        }
        return makeJsonResponse(1, Value(""), Value(gettext("Foreign Data Wrapper dropped")));
    }

    string getSql(Value data, Value fid, out string name, out Response err)
    {
        if (!fid.isNone)
        {
            auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("fid", fid, "conn", conn)));
            if (!r.ok)
            {
                err = internalServerError(r.error);
                return null;
            }
            if (r.value["rows"].length == 0)
            {
                err = gone(gettext("Could not find the foreign data wrapper information."));
                return null;
            }
            auto oldData = r.value["rows"][0];
            if (!oldData["fdwoptions"].isNone)
                oldData["fdwoptions"] = tokenizeOptions(oldData["fdwoptions"], "fdwoption", "fdwvalue");
            if (data.contains("fdwacl") && !data["fdwacl"].isNone)
                foreach (key; ["added", "changed", "deleted"])
                    if (data["fdwacl"].contains(key))
                        data["fdwacl"][key] = parsePrivToDb(data["fdwacl"][key], ["U"]);
            if (!data.contains("name"))
                data["name"] = oldData["name"];
            bool validAdded, validChanged;
            if (data.contains("fdwoptions") && !data["fdwoptions"].isNone && data["fdwoptions"].contains("added"))
            {
                auto v = validateOptions(data["fdwoptions"]["added"], "fdwoption", "fdwvalue");
                validAdded = v.isValid;
                data["fdwoptions"]["added"] = v.options;
            }
            if (data.contains("fdwoptions") && !data["fdwoptions"].isNone && data["fdwoptions"].contains("changed"))
            {
                auto v = validateOptions(data["fdwoptions"]["changed"], "fdwoption", "fdwvalue");
                validChanged = v.isValid;
                data["fdwoptions"]["changed"] = v.options;
            }
            auto sql = rt(UPDATE_SQL, tv("data", data, "o_data", oldData, "is_valid_added_options", validAdded,
                    "is_valid_changed_options", validChanged, "conn", conn));
            name = data.contains("name") ? data["name"].toString : oldData["name"].toString;
            return sql.strip("\n");
        }
        auto sql = createSql(data);
        name = data["name"].toString;
        return sql.strip("\n");
    }

    private Response sqlView(Value fid, bool jsonResp = true)
    {
        auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("fid", fid, "conn", conn)));
        if (!r.ok)
            return internalServerError(r.error);
        if (r.value["rows"].length == 0)
            return gone(gettext("Could not find the foreign data wrapper on the server."));
        auto row = r.value["rows"][0];
        bool isValid;
        if (!row["fdwoptions"].isNone)
        {
            row["fdwoptions"] = tokenizeOptions(row["fdwoptions"], "fdwoption", "fdwvalue");
            if (row["fdwoptions"].length > 0)
                isValid = true;
        }
        auto a = conn.executeDict(rt(ACL_SQL, tv("fid", fid, "conn", conn)));
        if (!a.ok)
            return internalServerError(a.error);
        addAcl(row, a.value);
        if (row.contains("fdwacl"))
            row["fdwacl"] = parsePrivToDb(row["fdwacl"], ["U"]);
        auto sql = rt(CREATE_SQL, tv("data", row, "conn", conn, "is_valid_options", isValid));
        sql ~= "\n";
        auto header = "-- Foreign Data Wrapper: " ~ row["name"].toString ~ "\n\n";
        header ~= "-- DROP FOREIGN DATA WRAPPER IF EXISTS " ~ qtIdentStr(row["name"].toString) ~ "\n\n";
        sql = header ~ sql;
        if (!jsonResp)
            return Response.sqlOnly(sql.strip("\n"));
        return makeResponse(Value(sql.strip("\n")));
    }
}
