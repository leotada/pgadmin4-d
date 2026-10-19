/// `schemas/views`: views and materialized views (one file, as in Python, because they share their submodules).
module pgadmin.browser.server_groups.servers.databases.schemas.views;

import std.algorithm : canFind;
import std.regex : regex, replaceAll, matchFirst;
import pgadmin.browser.common;
import pgadmin.browser.server_groups.servers.databases.schemas.utils;
import pgadmin.browser.server_groups.servers.databases.schemas.tables.columns : columnsModule;
import pgadmin.browser.server_groups.servers.databases.schemas.tables.compound_triggers : CompoundTriggerModule;
import pgadmin.browser.server_groups.servers.databases.schemas.tables.indexes : IndexesModule;
import pgadmin.browser.server_groups.servers.databases.schemas.tables.rules : RuleModule;
import pgadmin.browser.server_groups.servers.databases.schemas.tables.triggers : TriggerModule;

class ViewModule : SchemaChildModule
{
    enum NODE_TYPE = "view";

    this()
    {
        this(NODE_TYPE);
        collectionLabelText = "Views";
        minVer = Value(null);
        maxVer = Value(null);
    }

    protected this(string nodeTypeName)
    {
        super(nodeTypeName);
        staticDir("browser/server_groups/servers/databases/schemas/views");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => "database";

    string baseTemplate() => ViewNode.BASE_TEMPLATE_PATH ~ "/" ~ ViewNode.SQL_PREFIX;

    override Value[] getNodes(Dict kwargs)
    {
        if (hasNodes(kwargs["sid"], kwargs["did"], kwargs["scid"], Value(null), Value(null), baseTemplate()))
            return [generateBrowserCollectionNode(kwargs["scid"])];
        return null;
    }

    override string[] csssnippets()
    {
        string[] snippets = [
            renderTemplate("browser/css/collection.css", ["node_type": Value(nodeType)]),
            renderTemplate("views/css/view.css", ["node_type": Value(nodeType)]),
            renderTemplate("mviews/css/mview.css", ["node_type": Value("mview")]),
        ];
        foreach (m; submodules)
            if (auto b = cast(BrowserPluginModule) m)
                snippets ~= b.csssnippets;
        return snippets;
    }

    override void setup()
    {
        submodules ~= columnsModule();
        submodules ~= sharedModule!IndexesModule();
        submodules ~= sharedModule!TriggerModule();
        submodules ~= sharedModule!RuleModule();
        submodules ~= sharedModule!CompoundTriggerModule();
        registerView();
    }

    protected void registerView()
    {
        registerNodeView!ViewNode(this);
    }
}

final class MViewModule : ViewModule
{
    enum NODE_TYPE = "mview";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "Materialized Views";
        minVer = Value(90300);
        maxVer = Value(null);
    }

    override string nodeType() => NODE_TYPE;
    override string baseTemplate() => MViewNode.BASE_TEMPLATE_PATH ~ "/" ~ ViewNode.SQL_PREFIX;

    override protected void registerView()
    {
        registerNodeView!MViewNode(this);
    }
}

class ViewNode : PGChildNodeView
{
    enum SQL_PREFIX = "sql/";
    enum ALLOWED_PRIVS_JSON = "sql/allowed_privs.json";
    enum PROPERTIES_PATH = "sql/{0}/#{1}#/properties.sql";
    enum BASE_TEMPLATE_PATH = "views/{0}/#{1}#";

    string columnTemplatePath;
    string triggerTemplatePath;
    string compoundTriggerTemplatePath;
    string rulesTemplatePath;
    string indexTemplatePath;
    string[] viewSubModules;
    Value allowedAcls;
    string viewSchema;

    string nodeTypeName() => ViewModule.NODE_TYPE;
    string baseTemplate() => BASE_TEMPLATE_PATH;
    string iconName() => nodeType == "view" ? "icon-view" : "icon-mview";

    this()
    {
        super();
        nodeType = nodeTypeName();
        parentIds = [IdSpec("int", "gid"), IdSpec("int", "sid"), IdSpec("int", "did"), IdSpec("int", "scid")];
        ids = [IdSpec("int", "vid")];
        allowedAcls = Value.newDict();
        setAllOps(operationTable());
    }

    Operation[] operationTable()
    {
        return [
            makeOp("obj", ["get": "properties", "delete": "delete", "put": "update"],
                    ["get": "list", "post": "create", "delete": "delete"]),
            makeOp("children", ["get": "children"]),
            makeOp("delete", ["delete": "delete"], ["delete": "delete"]),
            makeOp("nodes", ["get": "node"], ["get": "nodes"]),
            makeOp("sql", ["get": "sql"]),
            makeOp("msql", ["get": "msql"], ["get": "msql"]),
            makeOp("stats", ["get": "statistics"], ["get": "statistics"]),
            makeOp("dependency", ["get": "dependencies"]),
            makeOp("dependent", ["get": "dependents"]),
            makeOp("configs", ["get": "configs"]),
            makeOp("get_tblspc", ["get": "get_tblspc"], ["get": "get_tblspc"]),
            makeOp("select_sql", ["get": "select_sql"], ["get": "select_sql"]),
            makeOp("insert_sql", ["get": "insert_sql"], ["get": "insert_sql"]),
            makeOp("get_table_vacuum", ["get": "get_table_vacuum"], ["get": "get_table_vacuum"]),
            makeOp("get_toast_table_vacuum", ["get": "get_toast_table_vacuum"], ["get": "get_toast_table_vacuum"]),
        ];
    }

    /// `check_precondition`
    protected Response viewPrecondition(Dict k)
    {
        manager = getDriver().connectionManagerOrNull(k["sid"].integer);
        if (manager is null)
            return gone(gettext("Could not find the server."));
        conn = manager.connection(null, null, true, k["did"]);
        immutable ver = to!string(manager.version_);
        templatePath = baseTemplate().replace("{0}", manager.serverType).replace("{1}", ver);
        columnTemplatePath = "columns/sql/#" ~ ver ~ "#";
        triggerTemplatePath = "triggers/sql/" ~ manager.serverType ~ "/#" ~ ver ~ "#";
        compoundTriggerTemplatePath = "compound_triggers/sql/" ~ manager.serverType ~ "/#" ~ ver ~ "#";
        rulesTemplatePath = "rules/sql";
        indexTemplatePath = "indexes/sql/#" ~ ver ~ "#";
        viewSubModules = ["rule", "trigger", "index"];
        if (manager.serverType == "ppas" && manager.version_ >= 120000)
            viewSubModules ~= "compound_trigger";
        try
            allowedAcls = parseJson(rt(ALLOWED_PRIVS_JSON));
        catch (Exception e)
        {
            logException(e);
            allowedAcls = Value.newList();
        }
        return null;
    }

    private string vt(string name, Value[string] vars = null) => rt(SQL_PREFIX ~ name, vars);

    private string[] aclFor(string aclcol) => aclStrings(allowedAcls[aclcol]["acl"]);

    private static string[] aclStrings(Value v)
    {
        string[] r;
        foreach (x; v.iterItems())
            r ~= x.toString;
        return r;
    }

    override Response callMethod(string name, Dict k)
    {
        if (!isAuthenticated())
            return unauthorisedResponse();
        if (name == "children")
            return children(k);
        auto err = viewPrecondition(k);
        if (err !is null)
            return err;
        auto gid = k.has("gid") ? k["gid"] : Value(null);
        auto sid = k["sid"];
        auto did = k["did"];
        auto scid = k["scid"];
        auto vid = k.has("vid") ? k["vid"] : Value(null);
        switch (name)
        {
        case "list":
        {
            auto r = conn.executeDict(vt(PROPERTIES_SQL, tv("did", did, "scid", scid)));
            if (!r.ok)
                return internalServerError(r.error);
            return makeResponse(r.value["rows"], 200);
        }
        case "node":
        {
            auto r = conn.execute2darray(vt(NODES_SQL, tv("vid", vid, "datlastsysoid", DATABASE_LAST_SYSTEM_OID_)));
            if (!r.ok)
                return internalServerError(r.error);
            if (r.value["rows"].length == 0)
                return gone(notFoundErrorMsg());
            auto row = r.value["rows"][0];
            return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    gbn(row["oid"], scid, row["name"].toString, iconName, kwDict("description", row["comment"])), 200);
        }
        case "nodes":
        {
            auto r = conn.execute2darray(vt(NODES_SQL, tv("scid", scid)));
            if (!r.ok)
                return internalServerError(r.error);
            Value[] res;
            foreach (row; r.value["rows"].list.items)
                res ~= gbn(row["oid"], scid, row["name"].toString, iconName, kwDict("description", row["comment"]));
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        case "properties": return propertiesResponse(did, scid, vid);
        case "create": return create(gid, sid, did);
        case "update": return update(gid, sid, did, vid);
        case "delete": return delete_(did, vid);
        case "msql":
        {
            auto data = msqlData("comment");
            Response e2;
            string nm;
            auto sql = getSql(gid, sid, did, data, vid, nm, e2);
            if (e2 !is null)
                return e2;
            sql = sql.strip("\n").strip(" ");
            if (sql == "")
                sql = "--modified SQL";
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(sql), 200);
        }
        case "sql": return sqlView(did, vid);
        case "get_tblspc":
        {
            try
            {
                auto r = conn.executeDict(rt("sql/get_tblspc.sql"));
                if (!r.ok)
                    return internalServerError("[]");
                Value[] res;
                foreach (row; r.value["rows"].list.items)
                    res ~= Value.dictOf("label", row["spcname"], "value", row["spcname"]);
                return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
            }
            catch (HTTPException e)
                throw e;
            catch (Exception e)
            {
                logException(e);
                return internalServerError(e.msg);
            }
        }
        case "dependents": return makeResponse(getDependents(conn, vid), 200);
        case "dependencies": return makeResponse(getDependencies(conn, vid), 200);
        case "select_sql": return selectSql(did, scid, vid);
        case "insert_sql": return insertSql(did, scid, vid);
        default: return super.callMethod(name, k);
        }
    }

    protected Response propertiesResponse(Value did, Value scid, Value vid)
    {
        Response err;
        auto res = fetchProperties(scid, vid, err);
        if (err !is null)
            return err;
        return makeResponse(res, 200);
    }

    // ---------------------------------------------------------------- properties

    private static Dict formatter(Value result)
    {
        Value[] secLbls;
        if (result.contains("seclabels") && !result["seclabels"].isNone)
            foreach (sec; result["seclabels"].iterItems())
            {
                auto m = matchFirst(sec.toString, regex(`([^=]+)=(.*$)`));
                secLbls ~= Value.dictOf("provider", m[1].idup, "label", m[2].idup);
            }
        auto d = new Dict;
        d["seclabels"] = Value(secLbls);
        return d;
    }

    Value fetchProperties(Value scid, Value vid, out Response err)
    {
        auto r = conn.executeDict(vt(PROPERTIES_SQL, tv("vid", vid, "datlastsysoid", DATABASE_LAST_SYSTEM_OID_)));
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
        auto a = conn.executeDict(vt(ACL_SQL, tv("vid", vid)));
        if (!a.ok)
        {
            err = internalServerError(r.error);
            return Value(null);
        }
        auto result = r.value["rows"][0];
        foreach (row; a.value["rows"].list.items)
        {
            auto priv = parsePrivFromDb(row);
            auto t = row["deftype"].toString;
            if (!result.contains(t))
                result[t] = Value.newList();
            result[t].append(priv);
        }
        result.dict.update(formatter(result));
        return result;
    }

    // ---------------------------------------------------------------- create / update / delete

    private Response create(Value gid, Value sid, Value did)
    {
        auto data = formOrJson(request());
        auto miss = missingArg(data, ["name", "definition"]);
        if (miss !is null)
            return miss;
        try
        {
            Response e2;
            string nameOrError;
            auto sql = getSql(gid, sid, did, data, Value(null), nameOrError, e2);
            if (e2 !is null)
                return e2;
            sql = sql.strip("\n").strip(" ");
            auto x = conn.executeScalar(sql);
            if (!x.ok)
                return internalServerError(x.error);
            auto v = conn.executeScalar(rt("sql/view_id.sql", tv("data", data, "conn", conn)));
            if (!v.ok)
                return internalServerError(x.error);
            auto s = conn.executeScalar(vt(OID_SQL, tv("vid", v.value)));
            if (!s.ok)
                return internalServerError(s.error);
            Dict extra;
            if (data.contains("comment"))
                extra = kwDict("description", data["comment"]);
            return jsonify(Value.dictOf("node", gbn(v.value, s.value, data["name"].toString, iconName, extra)));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
        {
            logException(e);
            return internalServerError(e.msg);
        }
    }

    private Response update(Value gid, Value sid, Value did, Value vid)
    {
        auto data = formOrJson(request());
        try
        {
            Response e2;
            string name;
            auto sql = getSql(gid, sid, did, data, vid, name, e2);
            if (e2 !is null)
                return e2;
            sql = sql.strip("\n").strip(" ");
            auto x = conn.executeVoid(sql);
            if (!x.ok)
                return internalServerError(x.error);
            auto v = conn.executeDict(rt("sql/view_id.sql", tv("data", data, "conn", conn)));
            if (!v.ok)
                return internalServerError(x.error);
            auto viewId = v.value["rows"][0]["oid"];
            auto newViewName = v.value["rows"][0]["relname"];
            auto s = conn.executeScalar(vt(OID_SQL, tv("vid", viewId)));
            if (!s.ok)
                return internalServerError(s.error);
            Dict extra;
            if (data.contains("comment"))
                extra = kwDict("description", data["comment"]);
            return jsonify(Value.dictOf("node", gbn(viewId, s.value, newViewName.toString, iconName, extra)));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
        {
            logException(e);
            return internalServerError(e.msg);
        }
    }

    Response delete_(Value did, Value vidArg, bool onlySql = false)
    {
        Value data = vidArg.isNone ? formOrJson(request()) : Value.dictOf("ids", Value([vidArg]));
        bool cascade = checkCascadeOperation();
        try
        {
            foreach (vid; data["ids"].iterItems())
            {
                auto r = conn.executeDict(vt(PROPERTIES_SQL, tv("did", did, "vid", vid, "datlastsysoid", DATABASE_LAST_SYSTEM_OID_)));
                if (!r.ok)
                    return internalServerError(r.error);
                if (r.value["rows"].length == 0)
                    return makeJsonResponse(0, Value(gettext("Error: Object not found.")), Value(notFoundErrorMsg()));
                auto row = r.value["rows"][0];
                auto sql = vt(DELETE_SQL, tv("nspname", row["schema"], "name", row["name"], "cascade", cascade));
                if (onlySql)
                    return Response.sqlOnly(sql);
                auto x = conn.executeScalar(sql);
                if (!x.ok)
                    return internalServerError(x.error);
            }
            return makeJsonResponse(1, Value(""), Value(gettext("View dropped")));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
        {
            logException(e);
            return internalServerError(e.msg);
        }
    }

    private Value getSchemaName(Value scid)
    {
        auto r = conn.executeScalar(rt("sql/get_schema.sql", tv("scid", scid)));
        if (!r.ok)
            throw new HTTPException(internalServerError(r.error));
        return r.value;
    }

    // ---------------------------------------------------------------- SQL generation

    private void parsePrivilegeData(Value data)
    {
        foreach (aclcol, spec; allowedAcls.dict)
            if (data.contains(aclcol))
                foreach (key; ["added", "changed", "deleted"])
                    if (data[aclcol].contains(key))
                        data[aclcol][key] = parsePrivToDb(data[aclcol][key], aclStrings(spec["acl"]));
    }

    private void parsePrivData(Value data)
    {
        foreach (aclcol, spec; allowedAcls.dict)
            if (data.contains(aclcol))
                data[aclcol] = parsePrivToDb(data[aclcol], aclStrings(spec["acl"]));
    }

    /// `getSQL(gid, sid, did, data, vid)`: the SQL, or (with `err` set) the response to return. `name` is the name.
    string getSql(Value gid, Value sid, Value did, Value data, Value vid, out string name, out Response err)
    {
        if (!vid.isNone)
        {
            auto r = conn.executeDict(vt(PROPERTIES_SQL, tv("vid", vid, "datlastsysoid", DATABASE_LAST_SYSTEM_OID_)));
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
            if (!data.contains("name"))
                data["name"] = r.value["rows"][0]["name"];
            if (!data.contains("schema"))
                data["schema"] = r.value["rows"][0]["schema"];
            parsePrivilegeData(data);
            data["del_sql"] = Value(false);
            oldData["acl_sql"] = Value("");
            Response e3;
            if (getDefinitionData(vid, data, oldData, r.value, e3))
            {
                err = e3;
                return null;
            }
            viewSchema = oldData["schema"].toString;
            string sql;
            try
                sql = getUpdateSql(did, vid, data, oldData);
            catch (HTTPException e)
                throw e;
            catch (Exception e)
            {
                logException(e);
                err = internalServerError(e.msg);
                return null;
            }
            name = data.contains("name") ? data["name"].toString : oldData["name"].toString;
            return sql;
        }
        foreach (arg; ["name", "schema", "definition"])
            if (!data.contains(arg))
            {
                err = makeJsonResponse(1, Value(""), Value(""), Value(null), Value(gettext(" -- definition incomplete")), 200);
                return null;
            }
        if (data["schema"].isInt)
            data["schema"] = getSchemaName(data["schema"]);
        parsePrivData(data);
        auto sql = vt(CREATE_SQL, tv("data", data, "conn", conn));
        if (data["definition"].truthy)
        {
            sql ~= "\n";
            sql ~= vt(GRANT_SQL, tv("data", data));
        }
        name = data["name"].toString;
        return sql;
    }

    private string getUpdateSql(Value did, Value vid, Value data, Value oldData)
    {
        auto sql = vt(UPDATE_SQL, tv("data", data, "o_data", oldData, "conn", conn));
        if (data.contains("definition") && data["definition"].truthy)
            sql ~= getColumnsSql(did, vid);
        return sql;
    }

    /// `_get_definition_data`: returns true (with `err`) on a database error.
    private bool getDefinitionData(Value vid, Value data, Value oldData, Value res, out Response err)
    {
        if (data.contains("definition") && manager.serverType == "pg")
        {
            auto newDef = replaceAll(data["definition"].toString, regex(`\W`, "g"), "").split("FROM");
            auto oldDef = replaceAll(res["rows"][0]["definition"].toString, regex(`\W`, "g"), "").split("FROM");
            if ((oldDef.length > 1 || newDef.length > 1) && oldDef[0] != newDef[0] && !newDef[0].canFind(oldDef[0]))
            {
                data["del_sql"] = Value(true);
                auto a = conn.executeDict(vt(ACL_SQL, tv("vid", vid)));
                if (!a.ok)
                {
                    err = internalServerError(res.toString);
                    return true;
                }
                foreach (row; a.value["rows"].list.items)
                {
                    auto priv = parsePrivFromDb(row);
                    auto t = row["deftype"].toString;
                    if (!res["rows"][0].contains(t))
                        res["rows"][0][t] = Value.newList();
                    res["rows"][0][t].append(priv);
                }
                oldData.dict.update(res["rows"][0].dict);
                parsePrivData(oldData);
                oldData["acl_sql"] = Value(vt(GRANT_SQL, tv("data", oldData)));
            }
        }
        return false;
    }

    private string indexColumnDetails(Value idx, Value data)
    {
        return null;
    }

    private Value getIndexColumnDetails(Value idx, Value data)
    {
        auto r = conn.execute2darray(renderTemplate("indexes/sql/#" ~ to!string(manager.version_) ~ "#/column_details.sql",
                tv("idx", idx)));
        if (!r.ok)
            throw new HTTPException(internalServerError(r.error));
        Value[] columns;
        string[] cols;
        foreach (row; r.value["rows"].list.items)
        {
            auto colsData = Value.dictOf("colname", row["attdef"], "collspcname", row["collnspname"], "op_class", row["opcname"]);
            if (row["options"][0] == Value("DESC"))
                colsData["sort_order"] = Value(true);
            columns ~= colsData;
            auto colsStr = row["attdef"].toString;
            if (row["collnspname"].truthy)
                colsStr ~= " COLLATE " ~ row["collnspname"].toString;
            if (row["opcname"].truthy)
                colsStr ~= " " ~ row["opcname"].toString;
            if (row["options"][0] == Value("DESC"))
                colsStr ~= " DESC";
            cols ~= colsStr;
        }
        data["columns"] = Value(columns);
        data["cols"] = Value(cols.join(", "));
        return data;
    }

    private Value getTriggerColumnDetails(Value tid, string clist)
    {
        // 'schemas/triggers' + _GET_COLUMNS_SQL: a path that does not exist, as in the Python code
        auto r = conn.execute2darray(renderTemplate("schemas/triggers/" ~ GET_COLUMNS_SQL, tv("tid", tid, "clist", clist)));
        if (!r.ok)
            throw new HTTPException(internalServerError(r.error));
        Value[] columns;
        foreach (row; r.value["rows"].list.items)
            columns ~= Value.dictOf("column", row["name"]);
        return Value(columns);
    }

    string getRuleSql(Value vid, bool displayComments = true)
    {
        string sqlData;
        auto r = conn.executeDict(renderTemplate("rules/sql/properties.sql", tv("tid", vid)));
        if (!r.ok)
            throw new HTTPException(internalServerError(r.error));
        foreach (rule; r.value["rows"].list.items)
        {
            if (rule["name"] == Value("_RETURN"))
                continue;
            auto p = conn.executeDict(renderTemplate("rules/sql/properties.sql", tv("rid", rule["oid"])));
            auto res = parseRuleDefinition(p.value);
            auto sql = renderTemplate("rules/sql/create.sql", tv("data", res, "display_comments", displayComments, "conn", conn));
            sqlData ~= "\n";
            sqlData ~= sql;
        }
        return sqlData;
    }

    private string generateTriggerSql(Value vid, Value data, bool displayComments, string sqlData)
    {
        foreach (trigger; data["rows"].list.items)
        {
            auto r = conn.executeDict(renderTemplate("compound_triggers/" ~ replaceVer(PROPERTIES_PATH),
                    tv("tid", vid, "trid", trigger["oid"])));
            if (!r.ok)
                throw new HTTPException(internalServerError(r.error));
            if (r.value["rows"].length == 0)
                continue;
            auto resRows = Value(r.value["rows"][0].dict.copy());
            resRows["table"] = resRows["relname"];
            resRows["schema"] = Value(viewSchema);
            if (resRows["tgattr"].toString.length > 1)
            {
                auto columns = resRows["tgattr"].toString.split(" ").join(", ");
                auto c = conn.execute2darray(renderTemplate("compound_triggers/" ~ replaceVer(
                        "sql/{0}/#{1}#/get_columns.sql"), tv("tid", trigger["oid"], "clist", columns)));
                if (!c.ok)
                    throw new HTTPException(internalServerError(c.error));
                Value[] cols;
                foreach (colRow; c.value["rows"].list.items)
                    cols ~= colRow["name"];
                resRows["columns"] = Value(cols);
            }
            resRows = triggerDefinition(resRows);
            auto sql = renderTemplate("compound_triggers/" ~ replaceVer("sql/{0}/#{1}#/create.sql"),
                    tv("data", resRows, "display_comments", displayComments, "conn", conn));
            sqlData ~= "\n";
            sqlData ~= sql;
        }
        return sqlData;
    }

    private string replaceVer(string path) => path.replace("{0}", manager.serverType).replace("{1}", to!string(manager.version_));

    string getCompoundTriggerSql(Value vid, bool displayComments = true)
    {
        string sqlData;
        if (manager.serverType == "ppas" && manager.version_ >= 120000)
        {
            auto r = conn.executeDict(renderTemplate("compound_triggers/" ~ replaceVer("sql/{0}/#{1}#/nodes.sql"), tv("tid", vid)));
            if (!r.ok)
                throw new HTTPException(internalServerError(r.error));
            sqlData = generateTriggerSql(vid, r.value, displayComments, sqlData);
        }
        return sqlData;
    }

    string getTriggerSql(Value vid, bool displayComments = true)
    {
        string sqlData;
        auto r = conn.executeDict(renderTemplate("triggers/" ~ replaceVer(PROPERTIES_PATH), tv("tid", vid)));
        if (!r.ok)
            throw new HTTPException(internalServerError(r.error));
        foreach (trigger; r.value["rows"].list.items)
        {
            auto p = conn.executeDict(renderTemplate("triggers/" ~ replaceVer(PROPERTIES_PATH),
                    tv("tid", vid, "trid", trigger["oid"])));
            auto resRows = Value(p.value["rows"][0].dict.copy());
            if (resRows["tgnargs"].integer > 1)
            {
                string[] a;
                foreach (x; resRows["tgargs"].iterItems())
                    a ~= x.toString;
                resRows["tgargs"] = Value(a.join(", "));
            }
            if (resRows["tgattr"].toString.length > 1)
                resRows["columns"] = getTriggerColumnDetails(trigger["oid"], resRows["tgattr"].toString.split(" ").join(", "));
            resRows = triggerDefinition(resRows);
            resRows["table"] = resRows["relname"];
            resRows["schema"] = Value(viewSchema);
            auto f = conn.executeDict(renderTemplate("triggers/" ~ replaceVer("sql/{0}/#{1}#/get_triggerfunctions.sql"),
                    tv("tgfoid", resRows["tgfoid"], "show_system_objects", bpModule.showSystemObjectsFlag)));
            if (!f.ok)
                throw new HTTPException(internalServerError(f.error));
            if (f.value.contains("rows") && f.value["rows"].length > 0 && f.value["rows"][0].contains("tfunctions"))
                resRows["tfunction"] = f.value["rows"][0]["tfunctions"];
            if (resRows["custom_tgargs"].length > 0)
            {
                string[] formatted;
                foreach (arg; resRows["custom_tgargs"].iterItems())
                    formatted ~= qtLiteral(arg, false);
                resRows["tgargs"] = Value(formatted.join(", "));
            }
            else
                resRows["tgargs"] = Value(null);
            auto sql = renderTemplate("triggers/" ~ replaceVer("sql/{0}/#{1}#/create.sql"),
                    tv("data", resRows, "display_comments", displayComments, "conn", conn));
            sqlData ~= "\n";
            sqlData ~= sql;
        }
        return sqlData;
    }

    string getIndexSql(Value did, Value vid, bool displayComments = true)
    {
        string sqlData;
        immutable ver = to!string(manager.version_);
        auto r = conn.executeDict(renderTemplate("indexes/sql/#" ~ ver ~ "#/properties.sql", tv("did", did, "tid", vid)));
        if (!r.ok)
            throw new HTTPException(internalServerError(r.error));
        foreach (index; r.value["rows"].list.items)
        {
            auto p = conn.executeDict(renderTemplate("indexes/sql/#" ~ ver ~ "#/properties.sql",
                    tv("idx", index["oid"], "did", did, "tid", vid)));
            auto data = Value(p.value["rows"][0].dict.copy());
            data["schema"] = data["nspname"];
            data["table"] = data["tabname"];
            data = getIndexColumnDetails(index["oid"], data);
            auto sql = renderTemplate("indexes/sql/#" ~ ver ~ "#/create.sql",
                    tv("data", data, "display_comments", displayComments, "conn", conn));
            sqlData ~= "\n";
            sqlData ~= sql;
        }
        return sqlData;
    }

    string getColumnsSql(Value did, Value vid)
    {
        string sqlData;
        auto r = conn.executeDict(renderTemplate(columnTemplatePath ~ "/" ~ PROPERTIES_SQL, tv("did", did, "tid", vid)));
        if (!r.ok)
            throw new HTTPException(internalServerError(r.error));
        foreach (rows; r.value["rows"].list.items)
        {
            auto res = Value.dictOf("name", rows["name"], "atttypid", rows["atttypid"], "attlen", rows["attlen"],
                    "typnspname", rows["typnspname"], "defval", Value(null), "description", Value(null),
                    "table", rows["relname"], "schema", viewSchema);
            auto oData = rows.deepCopy();
            if (rows.contains("defval") && !rows["defval"].isNone)
            {
                res["defval"] = rows["defval"];
                oData["defval"] = Value(null);
            }
            if (rows.contains("description") && (!rows["description"].isNone || rows["description"] != Value("")))
            {
                res["description"] = rows["description"];
                oData["description"] = Value(null);
            }
            sqlData ~= renderTemplate(columnTemplatePath ~ "/" ~ UPDATE_SQL, tv("o_data", oData, "data", res,
                    "is_view_only", true, "conn", conn));
        }
        foreach (rows; r.value["rows"].list.items)
        {
            auto res = Value.dictOf("name", rows["name"], "table", rows["relname"], "schema", viewSchema);
            if (rows.contains("attacl") && rows["attacl"].truthy)
            {
                auto a = conn.executeDict(renderTemplate(columnTemplatePath ~ "/acl.sql", tv("tid", vid, "clid", rows["attnum"])));
                if (!a.ok)
                    throw new HTTPException(internalServerError(a.error));
                string[] allowed;
                if (allowedAcls.truthy && allowedAcls.contains("datacl") && allowedAcls["datacl"].contains("acl"))
                    allowed = aclStrings(allowedAcls["datacl"]["acl"]);
                string[] deftypes;
                foreach (row; a.value["rows"].list.items)
                {
                    auto priv = parsePrivFromDb(row);
                    auto t = row["deftype"].toString;
                    if (!res.contains(t))
                        res[t] = Value.newList();
                    res[t].append(priv);
                    if (!deftypes.canFind(t))
                        deftypes ~= t;
                }
                foreach (dt; deftypes)
                    res[dt] = parsePrivToDb(res[dt], allowed);
                sqlData ~= vt(GRANT_SQL, tv("data", res));
            }
        }
        return sqlData;
    }

    protected Response sqlView(Value did, Value vid, string targetSchema = null, bool jsonResp = true)
    {
        bool displayComments = jsonResp;
        string sqlData;
        auto r = conn.executeDict(vt(PROPERTIES_SQL, tv("vid", vid, "datlastsysoid", DATABASE_LAST_SYSTEM_OID_)));
        if (!r.ok)
            return internalServerError(r.error);
        if (r.value["rows"].length == 0)
            return gone(notFoundErrorMsg());
        auto result = r.value["rows"][0];
        if (targetSchema.length)
        {
            result["definition"] = Value(result["definition"].toString.replace(result["schema"].toString, targetSchema));
            result["schema"] = Value(targetSchema);
        }
        result.dict.update(formatter(result));
        viewSchema = result.dict.get("schema", Value(null)).isNone ? null : result["schema"].toString;
        auto a = conn.executeDict(vt(ACL_SQL, tv("vid", vid)));
        if (!a.ok)
            return internalServerError(r.error);
        foreach (row; a.value["rows"].list.items)
        {
            auto priv = parsePrivFromDb(row);
            auto t = row["deftype"].toString;
            if (!r.value["rows"][0].contains(t))
                r.value["rows"][0][t] = Value.newList();
            r.value["rows"][0][t].append(priv);
        }
        result.dict.update(r.value["rows"][0].dict);
        foreach (aclcol, spec; allowedAcls.dict)
            if (result.contains(aclcol))
                result[aclcol] = parsePrivToDb(result[aclcol], aclStrings(spec["acl"]));
        auto sql = vt(CREATE_SQL, tv("data", result, "conn", conn, "display_comments", displayComments,
                "add_replace_clause", true));
        sql ~= "\n";
        sql ~= vt(GRANT_SQL, tv("data", result));
        if ((result.contains("seclabels") && result["seclabels"].length > 0) || (result.contains("datacl") && result["datacl"].length > 0))
            sql ~= "\n";
        sqlData ~= sql;
        sqlData ~= getRuleSql(vid, displayComments);
        sqlData ~= getTriggerSql(vid, displayComments);
        sqlData ~= getCompoundTriggerSql(vid, displayComments);
        sqlData ~= getIndexSql(did, vid, displayComments);
        sqlData ~= getColumnsSql(did, vid);
        if (!jsonResp)
            return Response.sqlOnly(sqlData);
        return makeResponse(Value(sqlData));
    }

    private Response selectSql(Value did, Value scid, Value vid)
    {
        if (vid.isNone)
            throw new Exception("ViewNode.select_sql() missing 1 required positional argument: 'vid'");
        auto r = conn.executeDict(vt(PROPERTIES_SQL, tv("scid", scid, "vid", vid, "did", did,
                "datlastsysoid", DATABASE_LAST_SYSTEM_OID_)));
        if (!r.ok)
            return internalServerError(r.error);
        if (r.value["rows"].length == 0)
            return gone(notFoundErrorMsg());
        auto dataView = r.value["rows"][0];
        auto c = conn.executeDict(renderTemplate(columnTemplatePath ~ "/" ~ PROPERTIES_SQL, tv("scid", scid, "tid", vid,
                "datlastsysoid", DATABASE_LAST_SYSTEM_OID_)));
        if (!c.ok)
            return internalServerError(r.error);
        string[] columns;
        foreach (col; c.value["rows"].list.items)
            columns ~= qtIdentStr(col["name"].toString);
        auto cols = columns.length ? columns.join(", ") : "*";
        auto sql = "SELECT " ~ cols ~ "\n\tFROM " ~ qtIdentStr(dataView["schema"].toString, dataView["name"].toString) ~ ";";
        return makeResponse(Value(sql));
    }

    private Response insertSql(Value did, Value scid, Value vid)
    {
        if (vid.isNone)
            throw new Exception("ViewNode.insert_sql() missing 1 required positional argument: 'vid'");
        auto r = conn.executeDict(vt(PROPERTIES_SQL, tv("scid", scid, "vid", vid, "did", did,
                "datlastsysoid", DATABASE_LAST_SYSTEM_OID_)));
        if (!r.ok)
            return internalServerError(r.error);
        if (r.value["rows"].length == 0)
            return gone(notFoundErrorMsg());
        auto dataView = r.value["rows"][0];
        auto c = conn.executeDict(renderTemplate(columnTemplatePath ~ "/" ~ PROPERTIES_SQL, tv("scid", scid, "tid", vid,
                "datlastsysoid", DATABASE_LAST_SYSTEM_OID_)));
        if (!c.ok)
            return internalServerError(c.error);
        string[] columns, values;
        foreach (col; c.value["rows"].list.items)
        {
            columns ~= qtIdentStr(col["name"].toString);
            values ~= "?";
        }
        string sql;
        if (columns.length)
            sql = "INSERT INTO " ~ qtIdentStr(dataView["schema"].toString, dataView["name"].toString) ~ "(\n\t"
                ~ columns.join(", ") ~ ")\n\tVALUES (" ~ values.join(", ") ~ ");";
        else
            sql = gettext("-- Please create column(s) first...");
        return makeResponse(Value(sql));
    }
}

final class MViewNode : ViewNode
{
    enum BASE_TEMPLATE_PATH = "mviews/{0}/#{1}#";
    enum TOAST_STR = "toast.";

    override string nodeTypeName() => MViewModule.NODE_TYPE;
    override string baseTemplate() => BASE_TEMPLATE_PATH;

    override Operation[] operationTable()
    {
        auto base = super.operationTable();
        return [makeOp("refresh_data", ["put": "refresh_data"], null),
            makeOp("check_utility_exists", ["get": "check_utility_exists"], null),
            makeOp("get_access_methods", null, ["get": "get_access_methods"])] ~ base;
    }

    override Response callMethod(string name, Dict k)
    {
        if (name == "properties" || name == "sql" || name == "statistics" || name == "get_table_vacuum"
                || name == "get_toast_table_vacuum" || name == "refresh_data" || name == "check_utility_exists"
                || name == "get_access_methods")
        {
            if (!isAuthenticated())
                return unauthorisedResponse();
            auto err = viewPrecondition(k);
            if (err !is null)
                return err;
            auto did = k["did"];
            auto scid = k["scid"];
            auto vid = k.has("vid") ? k["vid"] : Value(null);
            switch (name)
            {
            case "properties":
            {
                Response e2;
                auto res = fetchMviewProperties(did, scid, vid, e2);
                if (e2 !is null)
                    return e2;
                return makeResponse(res, 200);
            }
            case "sql": return mviewSql(did, scid, vid);
            case "get_table_vacuum":
                return makeResponse(fetchDefaultVacuumSettings(conn, k["sid"].integer, "table"), 200);
            case "get_toast_table_vacuum":
                return makeResponse(fetchDefaultVacuumSettings(conn, k["sid"].integer, "toast"), 200);
            case "statistics": return statistics(scid, vid);
            case "get_access_methods":
            {
                auto r = conn.execute2darray(rt("sql/get_access_methods.sql"));
                if (!r.ok)
                    return internalServerError(r.error);
                Value[] res;
                foreach (row; r.value["rows"].list.items)
                    res ~= Value.dictOf("label", row["amname"], "value", row["amname"]);
                return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
            }
            case "refresh_data": return refreshData(k["sid"], did, scid, vid);
            case "check_utility_exists": return checkUtilityExists(k["sid"]);
            default: break;
            }
        }
        return super.callMethod(name, k);
    }

    override protected Response propertiesResponse(Value did, Value scid, Value vid)
    {
        Response err;
        auto res = fetchMviewProperties(did, scid, vid, err);
        if (err !is null)
            return err;
        return makeResponse(res, 200);
    }

    private static void mergeToVacuumData(Value oldData, Value data, string vacuumKey)
    {
        if (!data.contains(vacuumKey) || !data[vacuumKey].contains("changed"))
            return;
        foreach (item; data[vacuumKey]["changed"].iterItems())
        {
            auto oldKey = item["name"].toString;
            if (vacuumKey == "vacuum_toast")
            {
                oldKey = "toast_" ~ item["name"].toString;
                item["name"] = Value("toast." ~ item["name"].toString);
            }
            if (!item.contains("value"))
                continue;
            if (item["value"].isNone)
            {
                if (oldData[oldKey] != item["value"])
                    data["vacuum_data"]["reset"].append(item);
            }
            else if (oldData[oldKey].isNone || oldData[oldKey].floating != item["value"].floating)
                data["vacuum_data"]["changed"].append(item);
        }
    }

    override string getSql(Value gid, Value sid, Value did, Value data, Value vid, out string name, out Response err)
    {
        if (!vid.isNone)
        {
            Response e2;
            auto old = fetchMviewProperties(did, Value(null), vid, e2);
            if (e2 !is null)
            {
                err = e2;
                return null;
            }
            auto oldData = old;
            if (!data.contains("name"))
                data["name"] = old["name"];
            if (!data.contains("schema"))
                data["schema"] = old["schema"];
            if (nodeType == "mview" && (oldData.dict.get("dependsonextensions", Value(null)).isNone
                    || data.dict.get("dependsonextensions", Value(null)).isNone))
            {
                auto o = oldData.dict.get("dependsonextensions", Value(null));
                oldData["dependsonextensions"] = o.truthy ? o : Value.newList();
                auto d = data.dict.get("dependsonextensions", Value(null));
                data["dependsonextensions"] = d.truthy ? d : Value.newList();
            }
            data["vacuum_data"] = Value.newDict();
            data["vacuum_data"]["changed"] = Value.newList();
            data["vacuum_data"]["reset"] = Value.newList();
            mergeToVacuumData(oldData, data, "vacuum_table");
            mergeToVacuumData(oldData, data, "vacuum_toast");
            foreach (aclcol, spec; allowedAcls.dict)
                if (data.contains(aclcol))
                    foreach (key; ["added", "changed", "deleted"])
                        if (data[aclcol].contains(key))
                            data[aclcol][key] = parsePrivToDb(data[aclcol][key], aclStrings(spec["acl"]));
            try
            {
                auto sql = vt(UPDATE_SQL, tv("data", data, "o_data", oldData, "conn", conn));
                name = oldData["name"].toString;
                return sql;
            }
            catch (HTTPException e)
                throw e;
            catch (Exception e)
            {
                logException(e);
                err = internalServerError(e.msg);
                return null;
            }
        }
        foreach (arg; ["name", "schema", "definition"])
            if (!data.contains(arg))
            {
                err = makeJsonResponse(1, Value(""), Value(""), Value(null), Value(gettext(" -- definition incomplete")), 200);
                return null;
            }
        if (data["schema"].isInt)
            data["schema"] = getSchemaName(data["schema"]);
        Value[] vacuumTable, vacuumToast;
        foreach (item; data.dict.get("vacuum_table", Value.newList()).iterItems())
            if (item.contains("value") && !item["value"].isNone)
                vacuumTable ~= item;
        foreach (item; data.dict.get("vacuum_toast", Value.newList()).iterItems())
            if (item.contains("value") && !item["value"].isNone)
                vacuumToast ~= Value.dictOf("name", TOAST_STR ~ item["name"].toString, "value", item["value"]);
        data["vacuum_data"] = Value.newList();
        if (data.dict.get("autovacuum_custom", Value(false)).truthy)
            data["vacuum_data"] = Value(vacuumTable);
        if (data.dict.get("toast_autovacuum", Value(false)).truthy)
            data["vacuum_data"] = Value(data["vacuum_data"].list.items ~ vacuumToast);
        if (nodeType == "mview" && data.dict.get("dependsonextensions", Value(null)).isNone)
        {
            auto d = data.dict.get("dependsonextensions", Value(null));
            data["dependsonextensions"] = d.truthy ? d : Value.newList();
        }
        foreach (aclcol, spec; allowedAcls.dict)
            if (data.contains(aclcol))
                data[aclcol] = parsePrivToDb(data[aclcol], aclStrings(spec["acl"]));
        auto sql = vt(CREATE_SQL, tv("data", data, "conn", conn));
        if (data["definition"].truthy)
        {
            sql ~= "\n";
            sql ~= vt(GRANT_SQL, tv("data", data));
        }
        name = data["name"].toString;
        return sql;
    }

    private Value fetchMviewProperties(Value did, Value scid, Value vid, out Response err)
    {
        auto r = conn.executeDict(vt(PROPERTIES_SQL, tv("did", did, "vid", vid, "datlastsysoid", DATABASE_LAST_SYSTEM_OID_)));
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
        row["autovacuum_enabled"] = row["autovacuum_enabled"].isNone ? Value("x")
            : Value(row["autovacuum_enabled"].truthy ? "t" : "f");
        row["toast_autovacuum_enabled"] = row["toast_autovacuum_enabled"].isNone ? Value("x")
            : Value(row["toast_autovacuum_enabled"].truthy ? "t" : "f");
        bool any(string[] keys)
        {
            foreach (key; keys)
                if (row[key].truthy)
                    return true;
            return false;
        }

        auto en = row["autovacuum_enabled"].toString;
        row["autovacuum_custom"] = Value(any(["autovacuum_vacuum_threshold", "autovacuum_vacuum_scale_factor",
                "autovacuum_analyze_threshold", "autovacuum_analyze_scale_factor", "autovacuum_vacuum_cost_delay",
                "autovacuum_vacuum_cost_limit", "autovacuum_freeze_min_age", "autovacuum_freeze_max_age",
                "autovacuum_freeze_table_age"]) || en == "t" || en == "f");
        auto ten = row["toast_autovacuum_enabled"].toString;
        row["toast_autovacuum"] = Value(any(["toast_autovacuum_vacuum_threshold", "toast_autovacuum_vacuum_scale_factor",
                "toast_autovacuum_analyze_threshold", "toast_autovacuum_analyze_scale_factor",
                "toast_autovacuum_vacuum_cost_delay", "toast_autovacuum_vacuum_cost_limit", "toast_autovacuum_freeze_min_age",
                "toast_autovacuum_freeze_max_age", "toast_autovacuum_freeze_table_age"]) || ten == "t" || ten == "f");
        string vs;
        if (!row["reloptions"].isNone)
        {
            string[] o;
            foreach (x; row["reloptions"].iterItems())
                o ~= x.toString;
            vs ~= o.join("\n");
        }
        if (!row["toast_reloptions"].isNone)
        {
            vs ~= vs != "" ? "\n" : "";
            string[] o;
            foreach (x; row["toast_reloptions"].iterItems())
                o ~= TOAST_STR ~ x.toString;
            vs ~= o.join("\n");
        }
        row["vacuum_settings_str"] = Value(vs.replace("=", " = "));
        auto a = conn.executeDict(vt(ACL_SQL, tv("vid", vid)));
        if (!a.ok)
        {
            err = internalServerError(r.error);
            return Value(null);
        }
        foreach (aclRow; a.value["rows"].list.items)
        {
            auto priv = parsePrivFromDb(aclRow);
            auto t = aclRow["deftype"].toString;
            if (!row.contains(t))
                row[t] = Value.newList();
            row[t].append(priv);
        }
        row.dict.update(formatter(row));
        viewSchema = row.dict.get("schema", Value(null)).isNone ? null : row["schema"].toString;
        row["vacuum_table"] = parseVacuumData(conn, row, "table");
        row["vacuum_toast"] = parseVacuumData(conn, row, "toast");
        return row;
    }

    private Response mviewSql(Value did, Value scid, Value vid, bool jsonResp = true)
    {
        bool displayComments = jsonResp;
        Response err;
        auto result = fetchMviewProperties(did, scid, vid, err);
        if (err !is null)
            return err;
        Value[] vacuumTable, vacuumToast;
        foreach (item; result["vacuum_table"].iterItems())
            if (item.contains("value") && !item["value"].isNone)
                vacuumTable ~= item;
        foreach (item; result["vacuum_toast"].iterItems())
            if (item.contains("value") && !item["value"].isNone)
                vacuumToast ~= Value.dictOf("name", TOAST_STR ~ item["name"].toString, "value", item["value"]);
        result["vacuum_data"] = Value(vacuumTable ~ vacuumToast);
        foreach (aclcol, spec; allowedAcls.dict)
            if (result.contains(aclcol))
                result[aclcol] = parsePrivToDb(result[aclcol], aclStrings(spec["acl"]));
        auto sql = vt(CREATE_SQL, tv("data", result, "conn", conn, "display_comments", displayComments,
                "add_not_exists_clause", true));
        sql ~= "\n";
        sql ~= vt(GRANT_SQL, tv("data", result));
        string sqlData = sql;
        sqlData ~= getRuleSql(vid, displayComments);
        sqlData ~= getTriggerSql(vid, displayComments);
        sqlData ~= getIndexSql(did, vid, displayComments);
        sqlData ~= getColumnsSql(did, vid);
        sqlData = sqlData.strip("\n");
        if (!jsonResp)
            return Response.sqlOnly(sqlData);
        return makeResponse(Value(sqlData));
    }

    private Response statistics(Value scid, Value vid)
    {
        auto s = conn.executeScalar(vt("get_schema.sql", tv("conn", conn, "scid", scid)));
        if (!s.ok)
            return internalServerError(s.error);
        Res res;
        if (vid.isNone)
            res = conn.executeDict(vt("coll_mview_stats.sql", tv("conn", conn, "schema_name", s.value)));
        else
        {
            auto p = checkPgstattuple(conn, vid);
            if (!p.ok)
                return internalServerError(p.error);
            auto n = conn.executeScalar(vt("get_view_name.sql", tv("conn", conn, "scid", scid, "vid", vid)));
            if (!n.ok)
                return internalServerError(n.error);
            res = conn.executeDict(vt("stats.sql", tv("conn", conn, "schema_name", s.value, "mview_name", n.value,
                    "is_pgstattuple", p.value, "vid", vid)));
        }
        if (!res.ok)
            return internalServerError(res.error);
        return makeJsonResponse(1, Value(""), Value(""), Value(null), res.value, 200);
    }

    private Response checkUtilityExists(Value sid)
    {
        // TODO: needs the binary path support (`manager.utility('sql')`) shared with the maintenance tools
        return makeJsonResponse(0, Value(gettext("Could not find the given server")));
    }

    private Response refreshData(Value sid, Value did, Value scid, Value vid)
    {
        // TODO: runs psql through a background process (BatchProcess), not ported yet
        return makeJsonResponse(0, Value(gettext("Could not find the given server")));
    }
}
