/// `databases/languages`: procedural languages.
module pgadmin.browser.server_groups.servers.databases.languages;

import std.regex : regex, matchFirst;
import pgadmin.browser.common;

final class LanguageModule : CollectionNodeModule
{
    enum NODE_TYPE = "language";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "Languages";
        minVer = Value(null);
        maxVer = Value(null);
        staticDir("browser/server_groups/servers/databases/languages");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => "database";
    override bool nodeInode() => false;
    override bool moduleUseTemplateJavascript() => false;

    override Value[] getNodes(Dict kwargs)
    {
        if (hasNodes(kwargs["sid"], kwargs["did"], Value(null), Value(null), Value(null), LanguageView.BASE_TEMPLATE_PATH))
            return [generateBrowserCollectionNode(kwargs["did"])];
        return null;
    }

    override void setup()
    {
        registerNodeView!LanguageView(this);
    }
}

final class LanguageView : PGChildNodeView
{
    enum BASE_TEMPLATE_PATH = "languages/sql/#{0}#";

    static string notFoundLangInformation() => gettext("Could not find the language information.");

    this()
    {
        super();
        nodeType = LanguageModule.NODE_TYPE;
        nodeLabel = "Language";
        parentIds = [IdSpec("int", "gid"), IdSpec("int", "sid"), IdSpec("int", "did")];
        ids = [IdSpec("int", "lid")];
        setAllOps([
            makeOp("obj", ["get": "properties", "delete": "delete", "put": "update"],
                    ["get": "list", "post": "create", "delete": "delete"]),
            makeOp("nodes", ["get": "node"], ["get": "nodes"]),
            makeOp("sql", ["get": "sql"]),
            makeOp("msql", ["get": "msql"], ["get": "msql"]),
            makeOp("stats", ["get": "statistics"]),
            makeOp("dependency", ["get": "dependencies"]),
            makeOp("dependent", ["get": "dependents"]),
            makeOp("get_functions", null, ["get": "get_functions"]),
            makeOp("get_templates", null, ["get": "get_templates"]),
            makeOp("delete", ["delete": "delete"], ["delete": "delete"]),
        ]);
    }

    private static Value secLabels(Value row)
    {
        Value[] l;
        if (row.contains("seclabels") && !row["seclabels"].isNone)
            foreach (sec; row["seclabels"].iterItems())
            {
                auto m = matchFirst(sec.toString, regex(`([^=]+)=(.*$)`));
                l ~= Value.dictOf("provider", m[1].idup, "label", m[2].idup);
            }
        return Value(l);
    }

    override Response callMethod(string name, Dict k)
    {
        if (!isAuthenticated())
            return unauthorisedResponse();
        auto err = standardPrecondition(k, name, BASE_TEMPLATE_PATH);
        if (err !is null)
            return err;
        auto did = k["did"];
        auto lid = k.has("lid") ? k["lid"] : Value(null);
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
                res ~= gbn(row["oid"], did, row["name"].toString, "icon-language", kwDict("description", row["description"]));
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        case "node":
        {
            auto r = conn.execute2darray(rt(PROPERTIES_SQL, tv("lid", lid, "conn", conn)));
            if (!r.ok)
                return internalServerError(r.error);
            foreach (row; r.value["rows"].list.items)
                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                        gbn(row["oid"], did, row["name"].toString, "icon-language"), 200);
            return gone(gettext("Could not find the specified language."));
        }
        case "properties":
        {
            Response e2;
            auto res = fetchProperties(did, lid, e2);
            if (e2 !is null)
                return e2;
            return makeResponse(res, 200);
        }
        case "create": return create(did);
        case "update": return update(did, lid);
        case "delete": return delete_(lid);
        case "msql":
        {
            auto data = msqlData("description");
            try
            {
                Response e2;
                string nm;
                auto sql = getSql(data, lid, nm, e2);
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
        case "get_functions":
        {
            auto r = conn.executeDict(rt(FUNCTIONS_SQL));
            if (!r.ok)
                return internalServerError(r.error);
            return makeJsonResponse(1, Value(""), Value(""), Value(null), r.value["rows"], 200);
        }
        case "get_templates":
        {
            Value data = Value.newList();
            if (manager.version_ < 130000)
            {
                auto r = conn.executeDict(rt("templates.sql"));
                if (!r.ok)
                    return internalServerError(r.error);
                data = r.value["rows"];
            }
            return makeJsonResponse(1, Value(""), Value(""), Value(null), data, 200);
        }
        case "sql": return sqlView(lid);
        case "dependents": return makeResponse(getDependents(conn, lid), 200);
        case "dependencies": return makeResponse(getDependencies(conn, lid), 200);
        default: return super.callMethod(name, k);
        }
    }

    Value fetchProperties(Value did, Value lid, out Response err)
    {
        auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("lid", lid, "conn", conn)));
        if (!r.ok)
        {
            err = internalServerError(r.error);
            return Value(null);
        }
        if (r.value["rows"].length == 0)
        {
            err = gone(notFoundLangInformation());
            return Value(null);
        }
        auto row = r.value["rows"][0];
        row["is_sys_obj"] = Value(row["oid"].integer <= DATABASE_LAST_SYSTEM_OID_ || datistemplate);
        auto a = conn.executeDict(rt(ACL_SQL, tv("lid", lid, "conn", conn)));
        if (!a.ok)
        {
            err = internalServerError(a.error);
            return Value(null);
        }
        foreach (aclRow; a.value["rows"].list.items)
        {
            auto priv = parsePrivFromDb(aclRow);
            auto t = aclRow["deftype"].toString;
            if (row.contains(t))
                row[t].append(priv);
            else
                row[t] = Value([priv]);
        }
        row["seclabels"] = secLabels(row);
        return row;
    }

    private Response create(Value did)
    {
        auto data = formOrJson(request());
        auto miss = missingArg(data, ["name"]);
        if (miss !is null)
            return miss;
        try
        {
            if (data.contains("lanacl"))
                data["lanacl"] = parsePrivToDb(data["lanacl"], ["U"]);
            auto c = conn.executeDict(rt(CREATE_SQL, tv("data", data, "conn", conn)));
            if (!c.ok)
                return internalServerError(c.error);
            auto p = conn.executeDict(rt(PROPERTIES_SQL, tv("lanname", data["name"], "conn", conn)));
            if (!p.ok)
                return internalServerError(p.error);
            foreach (row; p.value["rows"].list.items)
                return jsonify(Value.dictOf("node", gbn(row["oid"], did, row["name"].toString, "icon-language")));
            throw new ViewReturnedNone;
        }
        catch (HTTPException e)
            throw e;
        catch (ViewReturnedNone e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response update(Value did, Value lid)
    {
        auto data = formOrJson(request());
        try
        {
            Response e2;
            string name;
            auto sql = getSql(data, lid, name, e2);
            if (e2 !is null)
                return e2;
            sql = sql.strip("\n").strip(" ");
            auto x = conn.executeDict(sql);
            if (!x.ok)
                return internalServerError(x.error);
            Dict extra;
            if (data.contains("description"))
                extra = kwDict("description", data["description"]);
            return jsonify(Value.dictOf("node", gbn(lid, did, name, "icon-" ~ nodeType, extra)));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    Response delete_(Value lidArg, bool onlySql = false)
    {
        Value data = lidArg.isNone ? formOrJson(request()) : Value.dictOf("ids", Value([lidArg]));
        bool cascade = checkCascadeOperation();
        try
        {
            foreach (lid; data["ids"].iterItems())
            {
                auto n = conn.executeScalar(rt(DELETE_SQL, tv("lid", lid, "conn", conn)));
                if (!n.ok)
                    return internalServerError(n.error);
                auto sql = rt(DELETE_SQL, tv("lname", n.value, "cascade", cascade, "conn", conn));
                if (onlySql)
                    return Response.sqlOnly(sql);
                auto x = conn.executeScalar(sql);
                if (!x.ok)
                    return internalServerError(x.error);
            }
            return makeJsonResponse(1, Value(""), Value(gettext("Language dropped")));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private static void parsePrivileges(Value data)
    {
        if (data.contains("lanacl") && !data["lanacl"].isNone)
            foreach (key; ["added", "changed", "deleted"])
                if (data["lanacl"].contains(key))
                    data["lanacl"][key] = parsePrivToDb(data["lanacl"][key], ["U"]);
    }

    string getSql(Value data, Value lid, out string name, out Response err)
    {
        if (!lid.isNone)
        {
            auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("lid", lid, "conn", conn)));
            if (!r.ok)
            {
                err = internalServerError(r.error);
                return null;
            }
            if (r.value["rows"].length == 0)
            {
                err = gone(notFoundLangInformation());
                return null;
            }
            parsePrivileges(data);
            auto oldData = r.value["rows"][0];
            foreach (arg; ["name", "lanowner", "description"])
                if (!data.contains(arg))
                    data[arg] = oldData[arg];
            auto sql = rt(UPDATE_SQL, tv("data", data, "o_data", oldData, "conn", conn));
            name = data.contains("name") ? data["name"].toString : oldData["name"].toString;
            return sql.strip("\n");
        }
        if (data.contains("lanacl"))
            data["lanacl"] = parsePrivToDb(data["lanacl"], ["U"]);
        auto sql = rt(CREATE_SQL, tv("data", data, "conn", conn));
        name = data["name"].toString;
        return sql.strip("\n");
    }

    private Response sqlView(Value lid, bool jsonResp = true)
    {
        auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("lid", lid, "conn", conn)));
        if (!r.ok)
            return internalServerError(r.error);
        if (r.value["rows"].length == 0)
            return gone(notFoundLangInformation());
        auto oldData = Value(r.value["rows"][0].dict.copy());
        auto a = conn.executeDict(rt(ACL_SQL, tv("lid", lid, "conn", conn)));
        if (!a.ok)
            return internalServerError(a.error);
        foreach (row; a.value["rows"].list.items)
        {
            auto priv = parsePrivFromDb(row);
            auto t = row["deftype"].toString;
            if (oldData.contains(t))
                oldData[t].append(priv);
            else
                oldData[t] = Value([priv]);
        }
        if (oldData.contains("lanacl"))
            oldData["lanacl"] = parsePrivToDb(oldData["lanacl"], ["U"]);
        oldData["seclabels"] = secLabels(oldData);
        auto sql = rt("sqlpane.sql", tv("data", oldData, "conn", conn, "add_replace_clause", true));
        if (!jsonResp)
            return Response.sqlOnly(sql.strip("\n"));
        return makeResponse(Value(sql.strip("\n")));
    }
}
