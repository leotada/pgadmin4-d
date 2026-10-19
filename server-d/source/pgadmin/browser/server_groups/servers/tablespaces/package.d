/// `servers/tablespaces`: tablespaces.
module pgadmin.browser.server_groups.servers.tablespaces;

import std.regex : regex, replaceAll;
import pgadmin.browser.common;

final class TablespaceModule : CollectionNodeModule
{
    enum NODE_TYPE = "tablespace";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "Tablespaces";
        staticDir("browser/server_groups/servers/tablespaces");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => "server";
    override bool moduleUseTemplateJavascript() => false;
    override bool nodeInode() => false;

    override Value[] getNodes(Dict kwargs) => [generateBrowserCollectionNode(kwargs["sid"])];

    override void setup()
    {
        registerNodeView!TablespaceView(this);
    }
}

/// `k, v = s.split('=')`
private string[2] splitPair(string s)
{
    import std.array : split;
    import std.conv : to;
    auto parts = s.split("=");
    if (parts.length > 2)
        throw new Exception("too many values to unpack (expected 2)");
    if (parts.length < 2)
        throw new Exception("not enough values to unpack (expected 2, got " ~ to!string(parts.length) ~ ")");
    return [parts[0], parts[1]];
}

final class TablespaceView : PGChildNodeView
{
    this()
    {
        super();
        nodeType = TablespaceModule.NODE_TYPE;
        parentIds = [IdSpec("int", "gid"), IdSpec("int", "sid")];
        ids = [IdSpec("int", "tsid")];
        setAllOps([
            makeOp("obj", ["get": "properties", "delete": "delete", "put": "update"],
                    ["get": "list", "post": "create", "delete": "delete"]),
            makeOp("nodes", ["get": "node"], ["get": "nodes"]),
            makeOp("children", ["get": "children"]),
            makeOp("sql", ["get": "sql"]),
            makeOp("msql", ["get": "msql"], ["get": "msql"]),
            makeOp("stats", ["get": "statistics"], ["get": "statistics"]),
            makeOp("dependency", ["get": "dependencies"]),
            makeOp("dependent", ["get": "dependents"]),
            makeOp("vopts", null, ["get": "variable_options"]),
            makeOp("move_objects", ["put": "move_objects"]),
            makeOp("move_objects_sql", ["get": "move_objects_sql"]),
        ]);
    }

    private enum ACL = ["C"];

    override Response callMethod(string name, Dict k)
    {
        if (!isAuthenticated())
            return unauthorisedResponse();
        if (name == "children")
            return children(k);
        auto err = serverPrecondition(k, name, "tablespaces/sql/#{0}#");
        if (err !is null)
            return err;
        auto gid = k.has("gid") ? k["gid"] : Value(null);
        auto sid = k["sid"];
        auto tsid = k.has("tsid") ? k["tsid"] : Value(null);
        switch (name)
        {
        case "list":
        {
            auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("conn", conn)));
            if (!r.ok)
                return internalServerError(r.error);
            return makeResponse(r.value["rows"], 200);
        }
        case "node":
        {
            auto r = conn.execute2darray(rt(NODES_SQL, tv("tsid", tsid, "conn", conn)));
            if (!r.ok)
                return internalServerError(r.error);
            if (r.value["rows"].length == 0)
                return gone(gettext("Could not find the tablespace."));
            auto row = r.value["rows"][0];
            return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    gbn(row["oid"], sid, row["name"].toString, "icon-tablespace"), 200);
        }
        case "nodes":
        {
            auto r = conn.execute2darray(rt(NODES_SQL, tv("tsid", tsid, "conn", conn)));
            if (!r.ok)
                return internalServerError(r.error);
            Value[] res;
            foreach (row; r.value["rows"].list.items)
                res ~= gbn(row["oid"], sid, row["name"].toString, "icon-tablespace",
                        kwDict("description", row["description"]));
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        case "properties":
        {
            auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("tsid", tsid, "conn", conn)));
            if (!r.ok)
                return internalServerError(r.error);
            if (r.value["rows"].length == 0)
                return gone(gettext("Could not find the tablespace information."));
            auto data = r.value["rows"][0].shallowCopy();
            data["is_sys_obj"] = Value(data["oid"].integer <= DATABASE_LAST_SYSTEM_OID_ || datistemplate);
            Response e2;
            data = formatter(data, tsid, e2);
            if (e2 !is null)
                return e2;
            return makeResponse(data, 200);
        }
        case "create": return create(sid);
        case "update": return update(gid, sid, tsid);
        case "delete": return delete_(tsid);
        case "msql":
        {
            auto data = msqlData("description");
            Response e2;
            string nm;
            auto sql = getSql(data, tsid, nm, e2);
            if (e2 !is null)
                return e2;
            sql = sql.strip("\n").strip(" ");
            if (sql == "")
                sql = "--modified SQL";
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(sql), 200);
        }
        case "sql": return sqlView(tsid);
        case "variable_options":
        {
            string sql;
            if (manager.version_ >= 90600)
                sql = renderTemplate("tablespaces/sql/default/variables.sql");
            else
                sql = rt("variables.sql");
            auto r = conn.executeDict(sql);
            if (!r.ok)
                return internalServerError(r.error);
            return makeJsonResponse(1, Value(""), Value(""), Value(null), r.value["rows"], 200);
        }
        case "statistics":
        {
            auto r = conn.executeDict(rt("stats.sql", tv("tsid", tsid, "conn", conn)));
            if (!r.ok)
                return internalServerError(r.error);
            return makeJsonResponse(1, Value(""), Value(""), Value(null), r.value, 200);
        }
        case "dependencies": return makeResponse(getDependencies(conn, tsid), 200);
        case "dependents": return makeResponse(tsDependents(sid, tsid), 200);
        default: return super.callMethod(name, k);
        }
    }

    /// `_formatter`: options/labels to dicts and the ACL entries.
    private Value formatter(Value data, Value tsid, out Response err)
    {
        if (data.contains("spcoptions") && !data["spcoptions"].isNone)
        {
            Value[] opts;
            foreach (o; data["spcoptions"].iterItems())
            {
                auto kv = splitPair(o.toString);
                opts ~= Value.dictOf("name", kv[0], "value", kv[1]);
            }
            data["spcoptions"] = Value(opts);
        }
        if (data.contains("seclabels") && !data["seclabels"].isNone)
        {
            Value[] labels;
            foreach (o; data["seclabels"].iterItems())
            {
                auto kv = splitPair(o.toString);
                labels ~= Value.dictOf("provider", kv[0], "label", kv[1]);
            }
            data["seclabels"] = Value(labels);
        }
        auto a = conn.executeDict(rt(ACL_SQL, tv("tsid", tsid, "conn", conn)));
        if (!a.ok)
        {
            err = internalServerError(a.error);
            return Value(null);
        }
        data["spcacl"] = Value.newList();
        foreach (row; a.value["rows"].list.items)
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

    private Response create(Value sid)
    {
        auto data = formOrJson(request());
        auto miss = missingArg(data, ["name", "spclocation"]);
        if (miss !is null)
            return miss;
        if (data.contains("spcacl"))
            data["spcacl"] = parsePrivToDb(data["spcacl"], ACL);
        try
        {
            auto c = conn.executeScalar(rt(CREATE_SQL, tv("data", data, "conn", conn)));
            if (!c.ok)
                return internalServerError(c.error);
            auto t = conn.executeScalar(rt(ALTER_SQL, tv("tablespace", data["name"], "conn", conn)));
            if (!t.ok)
                return internalServerError(t.error);
            auto tsid = t.value;
            auto sql = rt(ALTER_SQL, tv("data", data, "conn", conn));
            if (sql.length && sql.strip("\n").length && sql.strip(" ").length)
            {
                auto x = conn.executeScalar(sql);
                if (!x.ok)
                    return jsonify(Value.dictOf("node", gbn(tsid, sid, data["name"].toString, "icon-tablespace"),
                            "success", 0, "errormsg", "Tablespace created successfully, Set parameter fail: " ~ x.error,
                            "info", x.error));
            }
            Dict extra;
            if (data.contains("description"))
                extra = kwDict("description", data["description"]);
            return jsonify(Value.dictOf("node", gbn(tsid, sid, data["name"].toString, "icon-tablespace", extra)));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response update(Value gid, Value sid, Value tsid)
    {
        auto data = formOrJson(request());
        try
        {
            Response e2;
            string name;
            auto sql = getSql(data, tsid, name, e2);
            if (e2 !is null)
                return e2;
            sql = sql.strip("\n").strip(" ");
            auto x = conn.executeScalar(sql);
            if (!x.ok)
                return internalServerError(x.error);
            Dict extra;
            if (data.contains("description"))
                extra = kwDict("description", data["description"]);
            return jsonify(Value.dictOf("node", gbn(tsid, sid, name, "icon-" ~ nodeType, extra)));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response delete_(Value tsidArg)
    {
        Value data = tsidArg.isNone ? formOrJson(request()) : Value.dictOf("ids", Value([tsidArg]));
        try
        {
            foreach (tsid; data["ids"].iterItems())
            {
                auto r = conn.executeDict(rt(NODES_SQL, tv("tsid", tsid, "conn", conn)));
                if (!r.ok)
                    return internalServerError(r.error);
                if (r.value["rows"].length == 0)
                    return makeJsonResponse(0, Value(gettext("Error: Object not found.")),
                            Value(gettext("The specified tablespace could not be found.\n")));
                auto x = conn.executeScalar(rt(DELETE_SQL, tv("tsname", r.value["rows"][0]["name"], "conn", conn)));
                if (!x.ok)
                    return internalServerError(x.error);
            }
            return makeJsonResponse(1, Value(""), Value(gettext("Tablespace dropped")));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private void formatPrivilegeData(Value data)
    {
        if (data.contains("spcacl") && !data["spcacl"].isNone)
            foreach (key; ["added", "changed", "deleted"])
                if (data["spcacl"].contains(key))
                    data["spcacl"][key] = parsePrivToDb(data["spcacl"][key], ACL);
    }

    string getSql(Value data, Value tsid, out string name, out Response err)
    {
        string sql;
        Value oldData;
        if (!tsid.isNone)
        {
            auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("tsid", tsid, "conn", conn)));
            if (!r.ok)
            {
                err = internalServerError(r.error);
                return null;
            }
            if (r.value["rows"].length == 0)
            {
                err = gone(gettext("Could not find the tablespace on the server."));
                return null;
            }
            oldData = r.value["rows"][0].shallowCopy();
            oldData = formatter(oldData, tsid, err);
            if (err !is null)
                return null;
            formatPrivilegeData(data);
            if (!data.contains("name"))
                data["name"] = oldData["name"];
            sql = rt(UPDATE_SQL, tv("data", data, "o_data", oldData, "conn", conn));
        }
        else
        {
            if (data.contains("spcacl"))
                data["spcacl"] = parsePrivToDb(data["spcacl"], ACL);
            sql = rt(CREATE_SQL, tv("data", data, "conn", conn));
            sql ~= "\n";
            sql ~= rt(ALTER_SQL, tv("data", data, "conn", conn));
        }
        sql = replaceAll(sql, regex("\n{2,}"), "\n\n");
        if (!data.contains("name") && oldData.isNone)
            throw new Exception("cannot access local variable 'old_data' where it is not associated with a value");
        name = data.contains("name") ? data["name"].toString : oldData["name"].toString;
        return sql;
    }

    private Response sqlView(Value tsid)
    {
        auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("tsid", tsid, "conn", conn)));
        if (!r.ok)
            return internalServerError(r.error);
        if (r.value["rows"].length == 0)
            return gone(gettext("Could not find the tablespace on the server."));
        auto oldData = r.value["rows"][0].shallowCopy();
        Response e2;
        oldData = formatter(oldData, tsid, e2);
        if (e2 !is null)
            return e2;
        if (oldData.contains("spcacl"))
            oldData["spcacl"] = parsePrivToDb(oldData["spcacl"], ACL);
        string sql;
        import std.algorithm : startsWith;
        if (!oldData["name"].toString.startsWith("pg_"))
        {
            sql = rt(CREATE_SQL, tv("data", oldData, "conn", conn));
            sql ~= "\n";
        }
        sql ~= rt(ALTER_SQL, tv("data", oldData, "conn", conn));
        auto nm = oldData["name"].toString;
        auto header = "\n-- Tablespace: " ~ nm ~ "\n\n-- DROP TABLESPACE IF EXISTS " ~ nm ~ ";\n\n";
        sql = replaceAll(header ~ sql, regex("\n{2,}"), "\n\n");
        return makeResponse(Value(sql.strip("\n")));
    }

    /// `get_dependents(conn, sid, tsid)`: scans every connectable database.
    private Value tsDependents(Value sid, Value tsid)
    {
        static immutable string[string] types = [
            "r": "table", "i": null, "S": "sequence", "v": "view", "x": "external_table", "p": "function",
            "n": "schema", "y": "type", "d": "domain", "T": "trigger_function", "C": "conversion", "o": null
        ];
        auto q = conn.executeDict(rt("dependents.sql", tv("fetch_database", true)));
        auto dependents = Value.newList();
        auto mgr = getDriver().connectionManager(sid.integer);
        foreach (dbRow; q.value["rows"].list.items)
        {
            if (tsid == dbRow["dattablespace"])
                dependents.append(Value.dictOf("type", "database", "name", "", "field", dbRow["datname"]));
            if (!dbRow["datallowconn"].truthy)
                continue;
            bool isConnected = true;
            Connection temp;
            try
            {
                temp = mgr.connection(dbRow["datname"].toString);
                isConnected = temp.connected();
                if (!isConnected)
                    temp.connect();
            }
            catch (Exception)
            {
            }
            if (temp !is null && temp.connected())
            {
                auto res = temp.executeDict(rt("dependents.sql", tv("fetch_dependents", true, "tsid", tsid)));
                foreach (row; res.value["rows"].list.items)
                {
                    string relName = row["nspname"].isNone ? null : row["nspname"].toString ~ ".";
                    relName = relName is null ? row["relname"].toString : relName ~ row["relname"].toString;
                    auto typeStr = row["relkind"].toString;
                    auto key = typeStr[0 .. 1];
                    if (key !in types)
                        continue;
                    string typeName;
                    if (types[key] is null)
                    {
                        if (key == "i")
                        {
                            typeName = "index";
                            relName = row["indname"].toString ~ " ON " ~ relName;
                        }
                        else if (key == "o")
                        {
                            typeName = "operator";
                            relName = row["relname"].toString;
                        }
                    }
                    else
                        typeName = types[key];
                    dependents.append(Value.dictOf("type", typeName, "name", relName, "field", dbRow["datname"]));
                }
                if (!isConnected)
                    mgr.release(dbRow["datname"].toString);
            }
        }
        return dependents;
    }
}
