/// `foreign_data_wrappers/foreign_servers`: foreign servers.
module pgadmin.browser.server_groups.servers.databases.foreign_data_wrappers.foreign_servers;

import pgadmin.browser.common;
import pgadmin.browser.server_groups.servers.databases.foreign_data_wrappers.foreign_servers.user_mappings : UserMappingModule;

final class ForeignServerModule : CollectionNodeModule
{
    enum NODE_TYPE = "foreign_server";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "Foreign Servers";
        minVer = Value(null);
        maxVer = Value(null);
        staticDir("browser/server_groups/servers/databases/foreign_data_wrappers/foreign_servers");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => "database";
    override bool moduleUseTemplateJavascript() => false;

    override Value[] getNodes(Dict kwargs) => [generateBrowserCollectionNode(kwargs["fid"])];

    override void setup()
    {
        submodules ~= new UserMappingModule;
        registerNodeView!ForeignServerView(this);
    }
}

final class ForeignServerView : PGChildNodeView
{
    this()
    {
        super();
        nodeType = ForeignServerModule.NODE_TYPE;
        nodeLabel = "Foreign Server";
        parentIds = [IdSpec("int", "gid"), IdSpec("int", "sid"), IdSpec("int", "did"), IdSpec("int", "fid")];
        ids = [IdSpec("int", "fsid")];
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
        auto err = standardPrecondition(k, name, "foreign_servers/sql/#{0}#");
        if (err !is null)
            return err;
        auto gid = k.has("gid") ? k["gid"] : Value(null);
        auto sid = k["sid"];
        auto did = k["did"];
        auto fid = k["fid"];
        auto fsid = k.has("fsid") ? k["fsid"] : Value(null);
        switch (name)
        {
        case "list":
        {
            auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("fid", fid, "conn", conn)));
            if (!r.ok)
                return internalServerError(r.error);
            return makeResponse(r.value["rows"], 200);
        }
        case "nodes":
        {
            auto r = conn.execute2darray(rt(PROPERTIES_SQL, tv("fid", fid, "conn", conn)));
            if (!r.ok)
                return internalServerError(r.error);
            Value[] res;
            foreach (row; r.value["rows"].list.items)
                res ~= gbn(row["oid"], fid, row["name"].toString, "icon-foreign_server", kwDict("description", row["description"]));
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        case "node":
        {
            auto r = conn.execute2darray(rt(PROPERTIES_SQL, tv("fsid", fsid, "conn", conn)));
            if (!r.ok)
                return internalServerError(r.error);
            foreach (row; r.value["rows"].list.items)
                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                        gbn(row["oid"], fid, row["name"].toString, "icon-foreign_server"), 200);
            return gone(gettext("Could not find the specified foreign server."));
        }
        case "properties":
        {
            Response e2;
            auto res = fetchProperties(fsid, e2);
            if (e2 !is null)
                return e2;
            return makeResponse(res, 200);
        }
        case "create": return create(fid);
        case "update": return update(gid, sid, did, fid, fsid);
        case "delete": return delete_(fsid);
        case "msql":
        {
            auto data = msqlData("description");
            try
            {
                Response e2;
                string nm;
                auto sql = getSql(data, fid, fsid, nm, e2);
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
        case "sql": return sqlView(fid, fsid);
        case "dependents":
        {
            auto result = getDependents(conn, fsid);
            auto r = conn.executeDict(rt("dependents.sql", tv("fsid", fsid)));
            foreach (row; r.value["rows"].list.items)
                result.append(Value.dictOf("type", "user_mapping", "name", row["name"], "field",
                        row["deptype"] == Value("n") ? "normal" : ""));
            return makeResponse(result, 200);
        }
        case "dependencies": return makeResponse(getDependencies(conn, fsid), 200);
        default: return super.callMethod(name, k);
        }
    }

    Value fetchProperties(Value fsid, out Response err)
    {
        auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("fsid", fsid, "conn", conn)));
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
        if (!row["fsrvoptions"].isNone)
            row["fsrvoptions"] = tokenizeOptions(row["fsrvoptions"], "fsrvoption", "fsrvvalue");
        auto a = conn.executeDict(rt(ACL_SQL, tv("fsid", fsid, "conn", conn)));
        if (!a.ok)
        {
            err = internalServerError(a.error);
            return Value(null);
        }
        foreach (aclRow; a.value["rows"].list.items)
        {
            auto privilege = parsePrivFromDb(aclRow);
            auto t = aclRow["deftype"].toString;
            if (row.contains(t))
                row[t].append(privilege);
            else
                row[t] = Value([privilege]);
        }
        return row;
    }

    private Response create(Value fid)
    {
        auto data = formOrJson(request());
        auto miss = missingArg(data, ["name"]);
        if (miss !is null)
            return miss;
        try
        {
            if (data.contains("fsrvacl"))
                data["fsrvacl"] = parsePrivToDb(data["fsrvacl"], ["U"]);
            auto f = conn.executeDict(rt(PROPERTIES_SQL, tv("fdwid", fid, "conn", conn)));
            if (!f.ok)
                return internalServerError(f.error);
            if (f.value["rows"].length == 0)
                return gone(gettext("The specified foreign server could not be found."));
            auto fdwData = f.value["rows"][0];
            bool isValid;
            if (data.contains("fsrvoptions"))
            {
                auto v = validateOptions(data["fsrvoptions"], "fsrvoption", "fsrvvalue");
                isValid = v.isValid;
                data["fsrvoptions"] = v.options;
            }
            auto c = conn.executeScalar(rt(CREATE_SQL, tv("data", data, "fdwdata", fdwData, "is_valid_options", isValid,
                    "conn", conn)));
            if (!c.ok)
                return internalServerError(c.error);
            auto p = conn.executeDict(rt(PROPERTIES_SQL, tv("data", data, "fdwdata", fdwData, "conn", conn)));
            if (!p.ok)
                return internalServerError(p.error);
            return jsonify(Value.dictOf("node", gbn(p.value["rows"][0]["oid"], fid, p.value["rows"][0]["name"].toString,
                    "icon-foreign_server")));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response update(Value gid, Value sid, Value did, Value fid, Value fsid)
    {
        auto data = formOrJson(request());
        try
        {
            Response e2;
            string name;
            auto sql = getSql(data, fid, fsid, name, e2);
            if (e2 !is null)
                return e2;
            sql = sql.strip("\n").strip(" ");
            auto x = conn.executeScalar(sql);
            if (!x.ok)
                return internalServerError(x.error);
            Dict extra;
            if (data.contains("description"))
                extra = kwDict("description", data["description"]);
            return jsonify(Value.dictOf("node", gbn(fsid, fid, name, "icon-" ~ nodeType, extra)));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    Response delete_(Value fsidArg, bool onlySql = false)
    {
        bool cascade = cmd == "delete";
        Value data = fsidArg.isNone ? formOrJson(request()) : Value.dictOf("ids", Value([fsidArg]));
        try
        {
            foreach (fsid; data["ids"].iterItems())
            {
                auto n = conn.executeScalar(rt(DELETE_SQL, tv("fsid", fsid, "conn", conn)));
                if (!n.ok)
                    return internalServerError(n.error);
                if (n.value.isNone)
                    return makeJsonResponse(0, Value(gettext("Error: Object not found.")),
                            Value(gettext("The specified foreign server could not be found.\n")), Value(null), Value(null), 410);
                auto sql = rt(DELETE_SQL, tv("name", n.value, "cascade", cascade, "conn", conn));
                if (onlySql)
                    return Response.sqlOnly(sql.strip("\n"));
                auto x = conn.executeScalar(sql);
                if (!x.ok)
                    return internalServerError(x.error);
            }
            return makeJsonResponse(1, Value(""), Value(gettext("Foreign Server dropped")));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    string getSql(Value data, Value fid, Value fsid, out string name, out Response err)
    {
        if (!fsid.isNone)
        {
            auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("fsid", fsid, "conn", conn)));
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
            if (!r.value["rows"][0]["fsrvoptions"].isNone)
                r.value["rows"][0]["fsrvoptions"] = tokenizeOptions(r.value["rows"][0]["fsrvoptions"], "fsrvoption", "fsrvvalue");
            if (data.contains("fsrvacl") && !data["fsrvacl"].isNone)
                foreach (key; ["added", "changed", "deleted"])
                    if (data["fsrvacl"].contains(key))
                        data["fsrvacl"][key] = parsePrivToDb(data["fsrvacl"][key], ["U"]);
            auto oldData = r.value["rows"][0];
            if (!data.contains("name"))
                data["name"] = oldData["name"];
            bool validAdded, validChanged;
            if (data.contains("fsrvoptions") && !data["fsrvoptions"].isNone && data["fsrvoptions"].contains("added"))
            {
                auto v = validateOptions(data["fsrvoptions"]["added"], "fsrvoption", "fsrvvalue");
                validAdded = v.isValid;
                data["fsrvoptions"]["added"] = v.options;
            }
            if (data.contains("fsrvoptions") && !data["fsrvoptions"].isNone && data["fsrvoptions"].contains("changed"))
            {
                auto v = validateOptions(data["fsrvoptions"]["changed"], "fsrvoption", "fsrvvalue");
                validChanged = v.isValid;
                data["fsrvoptions"]["changed"] = v.options;
            }
            auto sql = rt(UPDATE_SQL, tv("data", data, "o_data", oldData, "is_valid_added_options", validAdded,
                    "is_valid_changed_options", validChanged, "conn", conn));
            name = data.contains("name") ? data["name"].toString : oldData["name"].toString;
            return sql.strip("\n");
        }
        auto f = conn.executeDict(rt(PROPERTIES_SQL, tv("fdwid", fid, "conn", conn)));
        if (!f.ok)
        {
            err = internalServerError(f.error);
            return null;
        }
        auto fdwData = f.value["rows"][0];
        if (data.contains("fsrvacl") && !data["fsrvacl"].isNone)
            data["fsrvacl"] = parsePrivToDb(data["fsrvacl"], ["U"]);
        bool isValid;
        if (data.contains("fsrvoptions"))
        {
            auto v = validateOptions(data["fsrvoptions"], "fsrvoption", "fsrvvalue");
            isValid = v.isValid;
            data["fsrvoptions"] = v.options;
        }
        auto sql = rt(CREATE_SQL, tv("data", data, "fdwdata", fdwData, "is_valid_options", isValid, "conn", conn));
        sql ~= "\n";
        name = data["name"].toString;
        return sql;
    }

    private Response sqlView(Value fid, Value fsid, bool jsonResp = true)
    {
        auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("fsid", fsid, "conn", conn)));
        if (!r.ok)
            return internalServerError(r.error);
        if (r.value["rows"].length == 0)
            return gone(notFoundErrorMsg());
        auto row = r.value["rows"][0];
        if (fid.isNone && row.contains("fdwid"))
            fid = row["fdwid"];
        bool isValid;
        if (!row["fsrvoptions"].isNone)
        {
            row["fsrvoptions"] = tokenizeOptions(row["fsrvoptions"], "fsrvoption", "fsrvvalue");
            if (row["fsrvoptions"].length > 0)
                isValid = true;
        }
        auto a = conn.executeDict(rt(ACL_SQL, tv("fsid", fsid, "conn", conn)));
        if (!a.ok)
            return internalServerError(a.error);
        foreach (aclRow; a.value["rows"].list.items)
        {
            auto privilege = parsePrivFromDb(aclRow);
            auto t = aclRow["deftype"].toString;
            if (row.contains(t))
                row[t].append(privilege);
            else
                row[t] = Value([privilege]);
        }
        if (row.contains("fsrvacl"))
            row["fsrvacl"] = parsePrivToDb(row["fsrvacl"], ["U"]);
        auto f = conn.executeDict(rt(PROPERTIES_SQL, tv("fdwid", fid, "conn", conn)));
        if (!f.ok)
            return internalServerError(f.error);
        auto fdwData = f.value["rows"][0];
        auto sql = rt(CREATE_SQL, tv("data", row, "fdwdata", fdwData, "is_valid_options", isValid, "conn", conn));
        sql ~= "\n";
        auto header = "-- Foreign Server: " ~ row["name"].toString ~ "\n\n-- DROP SERVER IF EXISTS " ~ row["name"].toString ~ "\n\n";
        sql = header ~ sql;
        if (!jsonResp)
            return Response.sqlOnly(sql.strip("\n"));
        return makeResponse(Value(sql.strip("\n")));
    }
}
