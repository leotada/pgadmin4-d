/// `foreign_servers/user_mappings`: user mappings.
module pgadmin.browser.server_groups.servers.databases.foreign_data_wrappers.foreign_servers.user_mappings;

import pgadmin.browser.common;

final class UserMappingModule : CollectionNodeModule
{
    enum NODE_TYPE = "user_mapping";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "User Mappings";
        minVer = Value(null);
        maxVer = Value(null);
        staticDir("browser/server_groups/servers/databases/foreign_data_wrappers/foreign_servers/user_mappings");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => "server";
    override bool nodeInode() => false;
    override bool moduleUseTemplateJavascript() => false;

    override Value[] getNodes(Dict kwargs) => [generateBrowserCollectionNode(kwargs["fsid"])];

    override void setup()
    {
        registerNodeView!UserMappingView(this);
    }
}

final class UserMappingView : PGChildNodeView
{
    this()
    {
        super();
        nodeType = UserMappingModule.NODE_TYPE;
        nodeLabel = "User Mapping";
        parentIds = [IdSpec("int", "gid"), IdSpec("int", "sid"), IdSpec("int", "did"), IdSpec("int", "fid"), IdSpec("int", "fsid")];
        ids = [IdSpec("int", "umid")];
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
        ]);
    }

    override Response callMethod(string name, Dict k)
    {
        if (!isAuthenticated())
            return unauthorisedResponse();
        if (name == "children")
            return children(k);
        auto err = standardPrecondition(k, name, "user_mappings/sql/#{0}#");
        if (err !is null)
            return err;
        auto did = k["did"];
        auto fid = k["fid"];
        auto fsid = k["fsid"];
        auto umid = k.has("umid") ? k["umid"] : Value(null);
        switch (name)
        {
        case "list":
        {
            auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("fsid", fsid, "conn", conn)));
            if (!r.ok)
                return internalServerError(r.error);
            return makeResponse(r.value["rows"], 200);
        }
        case "nodes":
        {
            auto r = conn.execute2darray(rt(PROPERTIES_SQL, tv("fsid", fsid, "conn", conn)));
            if (!r.ok)
                return internalServerError(r.error);
            Value[] res;
            foreach (row; r.value["rows"].list.items)
                res ~= gbn(row["oid"], fsid, row["name"].toString, "icon-user_mapping");
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        case "node":
        {
            auto r = conn.execute2darray(rt(PROPERTIES_SQL, tv("conn", conn, "umid", umid)));
            if (!r.ok)
                return internalServerError(r.error);
            foreach (row; r.value["rows"].list.items)
                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                        gbn(row["oid"], fsid, row["name"].toString, "icon-user_mapping"), 200);
            return gone(gettext("Could not find the specified user mapping."));
        }
        case "properties":
        {
            Response e2;
            auto res = fetchProperties(umid, e2);
            if (e2 !is null)
                return e2;
            return makeResponse(res, 200);
        }
        case "create": return create(fsid);
        case "update": return update(fsid, umid);
        case "delete": return delete_(fsid, umid);
        case "msql":
        {
            auto data = Value.newDict();
            foreach (key; request().args.keys)
                data[key] = tryParseJson(request().args.get(key), Value(request().args.get(key)));
            try
            {
                Response e2;
                string nm;
                auto sql = getSql(data, fsid, umid, nm, e2);
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
        case "sql": return sqlView(fsid, umid);
        case "dependents": return makeResponse(getDependents(conn, umid), 200);
        case "dependencies": return makeResponse(getDependencies(conn, umid), 200);
        default: return super.callMethod(name, k);
        }
    }

    Value fetchProperties(Value umid, out Response err)
    {
        auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("umid", umid, "conn", conn)));
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
        if (!row["umoptions"].isNone)
            row["umoptions"] = tokenizeOptions(row["umoptions"], "umoption", "umvalue");
        return row;
    }

    private Response create(Value fsid)
    {
        auto data = formOrJson(request());
        auto miss = missingArg(data, ["name"]);
        if (miss !is null)
            return miss;
        try
        {
            auto f = conn.executeDict(rt(PROPERTIES_SQL, tv("fserid", fsid, "conn", conn)));
            if (!f.ok)
                return internalServerError(f.error);
            if (f.value["rows"].length == 0)
                return gone(gettext("The specified user mappings could not be found."));
            auto fdwData = f.value["rows"][0];
            bool isValid;
            if (data.contains("umoptions"))
            {
                auto v = validateOptions(data["umoptions"], "umoption", "umvalue");
                isValid = v.isValid;
                data["umoptions"] = v.options;
            }
            auto c = conn.executeScalar(rt(CREATE_SQL, tv("data", data, "fdwdata", fdwData, "is_valid_options", isValid,
                    "conn", conn)));
            if (!c.ok)
                return internalServerError(c.error);
            auto p = conn.executeDict(rt(PROPERTIES_SQL, tv("fsid", fsid, "data", data, "conn", conn)));
            if (!p.ok)
                return internalServerError(p.error);
            foreach (row; p.value["rows"].list.items)
                return jsonify(Value.dictOf("node", gbn(row["oid"], fsid, row["name"].toString, "icon-user_mapping")));
            throw new ViewReturnedNone;
        }
        catch (HTTPException e)
            throw e;
        catch (ViewReturnedNone e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response update(Value fsid, Value umid)
    {
        auto data = formOrJson(request());
        try
        {
            Response e2;
            string name;
            auto sql = getSql(data, fsid, umid, name, e2);
            if (e2 !is null)
                return e2;
            sql = sql.strip("\n").strip(" ");
            auto x = conn.executeScalar(sql);
            if (!x.ok)
                return internalServerError(x.error);
            return jsonify(Value.dictOf("node", gbn(umid, fsid, name, "icon-" ~ nodeType)));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    Response delete_(Value fsid, Value umidArg, bool onlySql = false)
    {
        bool cascade = cmd == "delete";
        Value data = umidArg.isNone ? formOrJson(request()) : Value.dictOf("ids", Value([umidArg]));
        try
        {
            foreach (umid; data["ids"].iterItems())
            {
                auto n = conn.executeScalar(rt(DELETE_SQL, tv("fsid", fsid, "conn", conn)));
                if (!n.ok)
                    return internalServerError(n.error);
                if (n.value.isNone)
                    return makeJsonResponse(0, Value(gettext("Error: Object not found.")),
                            Value(gettext("The specified foreign server could not be found.\n")), Value(null), Value(null), 410);
                auto p = conn.executeDict(rt(PROPERTIES_SQL, tv("umid", umid, "conn", conn)));
                if (!p.ok)
                    return internalServerError(p.error);
                if (p.value["rows"].length == 0)
                    return makeJsonResponse(0, Value(gettext("The specified user mapping could not be found.\n")), Value(""),
                            Value(null), Value(null), 410);
                auto sql = rt(DELETE_SQL, tv("data", p.value["rows"][0], "name", n.value, "cascade", cascade, "conn", conn));
                if (onlySql)
                    return Response.sqlOnly(sql);
                auto x = conn.executeScalar(sql);
                if (!x.ok)
                    return internalServerError(x.error);
            }
            return makeJsonResponse(1, Value(""), Value(gettext("User Mapping dropped")));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    string getSql(Value data, Value fsid, Value umid, out string name, out Response err)
    {
        if (!umid.isNone)
        {
            auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("umid", umid, "conn", conn)));
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
            if (!r.value["rows"][0]["umoptions"].isNone)
                r.value["rows"][0]["umoptions"] = tokenizeOptions(r.value["rows"][0]["umoptions"], "umoption", "umvalue");
            auto oldData = r.value["rows"][0];
            auto f = conn.executeDict(rt(PROPERTIES_SQL, tv("fserid", fsid, "conn", conn)));
            if (!f.ok)
            {
                err = internalServerError(f.error);
                return null;
            }
            auto fdwData = f.value["rows"][0];
            if (!data.contains("name"))
                data["name"] = oldData["name"];
            bool validAdded, validChanged;
            if (data.contains("umoptions") && !data["umoptions"].isNone && data["umoptions"].contains("added"))
            {
                auto v = validateOptions(data["umoptions"]["added"], "umoption", "umvalue");
                validAdded = v.isValid;
                data["umoptions"]["added"] = v.options;
            }
            if (data.contains("umoptions") && !data["umoptions"].isNone && data["umoptions"].contains("changed"))
            {
                auto v = validateOptions(data["umoptions"]["changed"], "umoption", "umvalue");
                validChanged = v.isValid;
                data["umoptions"]["changed"] = v.options;
            }
            auto sql = rt(UPDATE_SQL, tv("data", data, "o_data", oldData, "is_valid_added_options", validAdded,
                    "is_valid_changed_options", validChanged, "fdwdata", fdwData, "conn", conn));
            name = data.contains("name") ? data["name"].toString : oldData["name"].toString;
            return sql;
        }
        auto f = conn.executeDict(rt(PROPERTIES_SQL, tv("fserid", fsid, "conn", conn)));
        if (!f.ok)
        {
            err = internalServerError(f.error);
            return null;
        }
        auto fdwData = f.value["rows"][0];
        bool isValid;
        if (data.contains("umoptions"))
        {
            auto v = validateOptions(data["umoptions"], "umoption", "umvalue");
            isValid = v.isValid;
            data["umoptions"] = v.options;
        }
        auto sql = rt(CREATE_SQL, tv("data", data, "fdwdata", fdwData, "is_valid_options", isValid, "conn", conn));
        sql ~= "\n";
        name = data["name"].toString;
        return sql;
    }

    private Response sqlView(Value fsid, Value umid, bool jsonResp = true)
    {
        auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("umid", umid, "conn", conn)));
        if (!r.ok)
            return internalServerError(r.error);
        if (r.value["rows"].length == 0)
            return gone(notFoundErrorMsg());
        auto row = r.value["rows"][0];
        bool isValid;
        if (!row["umoptions"].isNone)
        {
            row["umoptions"] = tokenizeOptions(row["umoptions"], "umoption", "umvalue");
            if (row["umoptions"].length > 0)
                isValid = true;
        }
        auto f = conn.executeDict(rt(PROPERTIES_SQL, tv("fserid", fsid, "conn", conn)));
        if (!f.ok)
            return internalServerError(f.error);
        auto fdwData = f.value["rows"][0];
        auto sql = rt(CREATE_SQL, tv("data", row, "fdwdata", fdwData, "is_valid_options", isValid, "conn", conn));
        sql ~= "\n";
        auto header = "-- User Mapping : " ~ row["name"].toString ~ "\n\n-- DROP USER MAPPING IF EXISTS FOR "
            ~ row["name"].toString ~ " SERVER " ~ fdwData["name"].toString ~ "\n\n";
        sql = header ~ sql;
        if (!jsonResp)
            return Response.sqlOnly(sql.strip("\n"));
        return makeResponse(Value(sql.strip("\n")));
    }
}
