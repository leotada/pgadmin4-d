/// `schemas/functions`: functions, procedures and trigger functions.
module pgadmin.browser.server_groups.servers.databases.schemas.functions;

import std.algorithm : filter;
import std.array : array;
import std.regex : regex, matchFirst, replaceAll;
import pgadmin.browser.common;
import pgadmin.browser.server_groups.servers.databases.schemas.utils;
import pgadmin.browser.server_groups.servers.databases.schemas.functions.utils;
import pgadmin.browser.server_groups.servers.databases.utils : parseSecLabelsFromDb, parseVariablesFromDb;

final class FunctionModule : SchemaChildModule
{
    enum NODE_TYPE = "function";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "Functions";
        minVer = Value(null);
        maxVer = Value(null);
        staticDir("browser/server_groups/servers/databases/schemas/functions");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => "database";
    override bool nodeInode() => false;

    override Value[] getNodes(Dict kwargs)
    {
        if (hasNodes(kwargs["sid"], kwargs["did"], kwargs["scid"], Value(null), Value(null), FunctionView.BASE_TEMPLATE_PATH))
            return [generateBrowserCollectionNode(kwargs["scid"])];
        return null;
    }

    override void setup()
    {
        registerNodeView!FunctionView(this);
    }
}

final class ProcedureModule : SchemaChildModule
{
    enum NODE_TYPE = "procedure";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "Procedures";
        minVer = Value(110000);
        maxVer = Value(null);
        minPpasVer = Value(90100);
        serverTypes = ["pg", "ppas"];
        staticDir("browser/server_groups/servers/databases/schemas/procedures");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => "database";
    override bool nodeInode() => false;

    override Value[] getNodes(Dict kwargs)
    {
        if (hasNodes(kwargs["sid"], kwargs["did"], kwargs["scid"], Value(null), Value(null), ProcedureView.BASE_TEMPLATE_PATH))
            return [generateBrowserCollectionNode(kwargs["scid"])];
        return null;
    }

    override void setup()
    {
        registerNodeView!ProcedureView(this);
    }
}

final class TriggerFunctionModule : SchemaChildModule
{
    enum NODE_TYPE = "trigger_function";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "Trigger Functions";
        minVer = Value(90100);
        maxVer = Value(null);
        staticDir("browser/server_groups/servers/databases/schemas/trigger_functions");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => "database";
    override bool nodeInode() => false;

    override Value[] getNodes(Dict kwargs)
    {
        if (hasNodes(kwargs["sid"], kwargs["did"], kwargs["scid"], Value(null), Value(null), TriggerFunctionView.BASE_TEMPLATE_PATH))
            return [generateBrowserCollectionNode(kwargs["scid"])];
        return null;
    }

    override void setup()
    {
        registerNodeView!TriggerFunctionView(this);
    }
}

class FunctionView : PGChildNodeView
{
    enum BASE_TEMPLATE_PATH = "functions/{0}/sql/#{1}#";

    private Value req_;

    string baseTemplate() => BASE_TEMPLATE_PATH;
    string[] requiredArgs() => ["name", "funcowner", "pronamespace", "prorettypename", "lanname", "prosrc", "probin"];
    string nodeTypeName() => FunctionModule.NODE_TYPE;

    this()
    {
        super();
        nodeType = nodeTypeName();
        parentIds = [IdSpec("int", "gid"), IdSpec("int", "sid"), IdSpec("int", "did"), IdSpec("int", "scid")];
        ids = [IdSpec("int", "fnid")];
        setAllOps([
            makeOp("obj", ["get": "properties", "delete": "delete", "put": "update"],
                    ["get": "list", "post": "create", "delete": "delete"]),
            makeOp("delete", ["delete": "delete"], ["delete": "delete"]),
            makeOp("children", ["get": "children"]),
            makeOp("nodes", ["get": "nodes"], ["get": "nodes"]),
            makeOp("sql", ["get": "sql"]),
            makeOp("msql", ["get": "msql"], ["get": "msql"]),
            makeOp("stats", ["get": "statistics"], ["get": "statistics"]),
            makeOp("dependency", ["get": "dependencies"]),
            makeOp("dependent", ["get": "dependents"]),
            makeOp("get_types", ["get": "types"], ["get": "types"]),
            makeOp("get_languages", ["get": "get_languages"], ["get": "get_languages"]),
            makeOp("vopts", null, ["get": "variable_options"]),
            makeOp("select_sql", ["get": "select_sql"]),
            makeOp("exec_sql", ["get": "exec_sql"]),
            makeOp("get_support_functions", ["get": "get_support_functions"], ["get": "get_support_functions"]),
        ]);
    }

    // ---------------------------------------------------------------- request validation

    private static void createWrapData(Value req, string key, Value data)
    {
        string[] listParams;
        if (request().method == "GET")
            listParams = ["arguments", "variables", "proacl", "seclabels", "acl", "args", "dependsonextensions"];
        auto v = req[key];
        if (listParams.canFind(key) && v != Value("") && !v.isNone)
            data[key] = parseJson(v.toString);
        else if (["proretset", "proisstrict", "prosecdef", "proiswindow", "proleakproof"].canFind(key))
        {
            if (v == Value("true") || (v.type == VType.boolean && v.boolean))
                data[key] = Value(true);
            else
                data[key] = (v == Value("false") || (v.type == VType.boolean && !v.boolean)) ? Value(false) : Value("");
        }
        else
            data[key] = v;
    }

    private Response validateRequest(Dict k)
    {
        auto req = argsOrJson();
        if (!k.has("fnid"))
        {
            auto reqArgs = requiredArgs();
            if (!req.contains("lanname"))
            {
                // `req['lanname']`: a missing key of request.args/form is a 400, of a JSON body a KeyError (500)
                if (request().data.length)
                    throw new Exception("'lanname'");
                throw new HTTPException(400);
            }
            if (req["lanname"] == Value("c"))
                reqArgs = reqArgs.filter!(a => a != "prosrc").array;
            foreach (arg; reqArgs)
                if (!req.contains(arg) || req[arg] == Value("")
                        || (arg == "probin" && req["lanname"] == Value("c") && (!req.contains(arg) || req[arg] == Value(""))))
                    return makeJsonResponse(0, Value(gettext("Could not find the required parameter ({}).").replace("{}", arg)),
                            Value(""), Value(null), Value(null), 410);
        }
        auto data = Value.newDict();
        foreach (key, _; req.dict)
            createWrapData(req, key, data);
        req_ = data;
        return null;
    }

    // ---------------------------------------------------------------- dispatch

    override Response callMethod(string name, Dict k)
    {
        if (!isAuthenticated())
            return unauthorisedResponse();
        if (name == "children")
            return children(k);
        auto err = standardPrecondition(k, name, baseTemplate());
        if (err !is null)
            return err;
        auto gid = k.has("gid") ? k["gid"] : Value(null);
        auto sid = k["sid"];
        auto did = k["did"];
        auto scid = k["scid"];
        auto fnid = k.has("fnid") ? k["fnid"] : Value(null);
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
            auto r = conn.executeDict(rt(NODE_SQL, tv("scid", scid, "conn", conn)));
            if (!r.ok)
                return internalServerError(r.error);
            return makeResponse(r.value["rows"], 200);
        }
        case "nodes": return nodes(scid, fnid);
        case "properties":
        {
            Response e2;
            auto resp = fetchProperties(gid, sid, did, scid, fnid, e2);
            if (e2 !is null)
                return e2;
            if (resp.length == 0)
                return gone(gettext("Could not find the function node in the database."));
            return makeResponse(resp, 200);
        }
        case "types": return types(scid);
        case "get_languages": return getLanguages();
        case "variable_options":
        {
            auto r = conn.executeDict(rt("variables.sql"));
            if (!r.ok)
                return internalServerError(r.error);
            return makeJsonResponse(1, Value(""), Value(""), Value(null), r.value["rows"], 200);
        }
        case "create": return create(gid, sid, did, scid);
        case "update": return update(gid, sid, did, scid, fnid);
        case "delete": return delete_(scid, fnid);
        case "sql": return sqlView(gid, sid, did, scid, fnid);
        case "msql":
        {
            bool ok;
            auto sql = getSql(gid, sid, did, scid, req_, fnid, ok);
            if (!ok)
                return internalServerError(sql);
            sql = replaceAll(sql, regex("\n{2,}"), "\n\n");
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(sql), 200);
        }
        case "get_support_functions": return getSupportFunctions();
        case "dependents": return makeResponse(getDependents(conn, fnid), 200);
        case "dependencies": return makeResponse(getDependencies(conn, fnid), 200);
        case "select_sql": return selectSql(scid, fnid);
        case "exec_sql": return execSql(gid, sid, did, scid, fnid);
        case "statistics": return statistics(scid, fnid);
        default: return super.callMethod(name, k);
        }
    }

    private Response nodes(Value scid, Value fnid)
    {
        auto r = conn.execute2darray(rt(NODE_SQL, tv("scid", scid, "fnid", fnid, "conn", conn)));
        if (!r.ok)
            return internalServerError(r.error);
        Dict extra(Value row) => kwDict("funcowner", row["funcowner"], "language", row["lanname"],
                "description", row["description"]);
        if (!fnid.isNone)
        {
            if (r.value["rows"].length == 0)
                return gone(gettext("Could not find the specified %s.").replace("{}", nodeType));
            auto row = r.value["rows"][0];
            return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    gbn(row["oid"], scid, row["name"].toString, "icon-" ~ nodeType, extra(row)));
        }
        Value[] res;
        foreach (row; r.value["rows"].list.items)
            res ~= gbn(row["oid"], scid, row["name"].toString, "icon-" ~ nodeType, extra(row));
        return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
    }

    private Response types(Value scid)
    {
        string condition = "(typtype IN ('b', 'c', 'd', 'e', 'p', 'r') AND "
            ~ "typname NOT IN ('any', 'trigger', 'language_handler', 'event_trigger'))";
        if (!bpModule.showSystemObjectsFlag)
            condition ~= " AND nspname NOT LIKE E'pg\\\\_toast%' AND nspname NOT LIKE E'pg\\\\_temp%' AND "
                ~ "nspname != 'information_schema'";
        auto r = DataTypeReader.getTypes(conn, condition, false, scid);
        if (!r.ok)
            return internalServerError(r.error);
        return makeJsonResponse(1, Value(""), Value(""), Value(null), r.value, 200);
    }

    private Response getLanguages()
    {
        try
        {
            auto r = conn.executeDict(rt("get_languages.sql"));
            if (!r.ok)
                return internalServerError("[]");
            return makeJsonResponse(1, Value(""), Value(""), Value(null), r.value["rows"], 200);
        }
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response getSupportFunctions()
    {
        Value[] res = [Value.dictOf("label", "", "value", "")];
        try
        {
            auto r = conn.execute2darray(rt("get_support_functions.sql", tv("show_system_objects", bpModule.showSystemObjectsFlag)));
            if (!r.ok)
                return internalServerError(Value(res).toString);
            foreach (row; r.value["rows"].list.items)
                res ~= Value.dictOf("label", row["sfunctions"], "value", row["sfunctions"]);
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        catch (Exception e)
            return internalServerError(e.msg);
    }

    // ---------------------------------------------------------------- properties

    Value fetchProperties(Value gid, Value sid, Value did, Value scid, Value fnid, out Response err)
    {
        auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("scid", scid, "fnid", fnid)));
        if (!r.ok)
        {
            err = internalServerError(r.error);
            return Value(null);
        }
        if (r.value["rows"].length == 0)
        {
            err = gone(gettext("Could not find the function in the database."));
            return Value(null);
        }
        auto resp = r.value["rows"][0];
        Value params, proargs;
        try
            formatArgumentsFromDb(templatePath, conn, resp, params, proargs);
        catch (Exception e)
        {
            err = internalServerError(e.msg);
            return Value(null);
        }
        resp.dict.update(params.dict);
        resp.dict.update(proargs.dict);
        auto a = conn.executeDict(rt(ACL_SQL, tv("fnid", fnid)));
        if (!a.ok)
        {
            err = internalServerError(r.error);
            return Value(null);
        }
        Value[] privileges;
        foreach (row; a.value["rows"].list.items)
            privileges ~= parsePrivFromDb(row);
        resp["acl"] = Value(privileges);
        resp["sysfunc"] = Value(fnid.integer <= DATABASE_LAST_SYSTEM_OID_);
        resp["sysproc"] = Value(fnid.integer <= DATABASE_LAST_SYSTEM_OID_);
        if (resp.contains("seclabels"))
            resp.dict.update(parseSecLabelsFromDb(resp["seclabels"]));
        resp.dict.update(parseVariablesFromDb(Value([Value.dictOf("setconfig", resp["proconfig"])])));
        if (manager.sversion >= 110000 && resp.contains("prokind") && resp["prokind"] == Value("p")
                && resp.contains("lanname") && resp["lanname"] != Value("edbspl"))
        {
            resp["procost"] = Value(null);
            resp["provolatile"] = Value(null);
            resp["proparallel"] = Value(null);
        }
        formatProsrcForPureSql(resp);
        return resp;
    }

    private Value getSchema(Value scid)
    {
        auto r = conn.executeScalar(rt("get_schema.sql", tv("scid", scid)));
        if (!r.ok)
            throw new Exception(r.error);
        return r.value;
    }

    private static bool setRevokeAll(Value privileges)
    {
        bool revokeAll = privileges.length > 0;
        foreach (p; privileges.iterItems())
            if (p["grantee"] == Value("PUBLIC"))
                return false;
        return revokeAll;
    }

    private void formatProsrcForPureSql(Value data, bool viewOnly = true, string lanname = "sql")
    {
        if (manager.sversion < 140000)
            return;
        if (viewOnly)
        {
            if (data.contains("is_pure_sql") && data["is_pure_sql"] == Value(true))
            {
                data["prosrc"] = data["prosrc_sql"];
                if (!data["prosrc"].toString.endsWith(";"))
                    data["prosrc"] = Value(data["prosrc"].toString ~ ";");
            }
            else
                data["is_pure_sql"] = Value(false);
        }
        else if (lanname == "sql" && isFunctionDefSqlStandard(data))
        {
            data["is_pure_sql"] = Value(true);
            if (!data["prosrc"].toString.endsWith(";"))
                data["prosrc"] = Value(data["prosrc"].toString ~ ";");
        }
    }

    private static bool isFunctionDefSqlStandard(Value resp)
    {
        if (resp.contains("lanname") && resp["lanname"] != Value("sql"))
            return false;
        if (resp.contains("prosrc") && !resp["prosrc"].isNone && resp["prosrc"] != Value(""))
        {
            import std.uni : toLower;
            auto prosrc = resp["prosrc"].toString.toLower.strip("\n").strip("\t");
            foreach (invalid; [`^.*(?:'|")?.*(?=.*?atomic).*(?:'|").*$`, `^.*(?:"|')(?=.*(atomic)).*$`])
                if (!matchFirst(prosrc, regex(invalid, "m")).empty)
                    return false;
            foreach (valid; [`(?=.*begin)(.+?(\n)+)(?=.*atomic)|(?=.*begin)(?=.*atomic)`, `\A\s*return\b`])
                if (!matchFirst(prosrc, regex(valid, "m")).empty)
                    return true;
        }
        return false;
    }

    private void reformatProsrcCode(Value data)
    {
        if (data.contains("prosrc") && !data["prosrc"].isNone)
        {
            bool lessThan11 = nodeType == "procedure" && manager.sversion <= 110000;
            if (!lessThan11)
            {
                auto s = data["prosrc"].toString;
                if (!s.startsWith("\n"))
                    s = "\n" ~ s;
                if (!s.endsWith("\n"))
                    s ~= "\n";
                data["prosrc"] = Value(s);
            }
        }
    }

    // ---------------------------------------------------------------- create / update / delete

    private Response create(Value gid, Value sid, Value did, Value scid)
    {
        bool ok;
        auto sql = getSql(gid, sid, did, scid, req_, Value(null), ok, false, false, false);
        if (!ok)
            return internalServerError(sql);
        auto r = conn.executeScalar(sql);
        if (!r.ok)
            return internalServerError(r.error);
        auto o = conn.executeDict(rt(OID_SQL, tv("nspname", req_["pronamespace"], "name", req_["name"], "conn", conn)));
        if (!o.ok)
            return internalServerError(o.error);
        auto res = o.value["rows"][0];
        return jsonify(Value.dictOf("node", gbn(res["oid"], res["nsp"], res["name"].toString, "icon-" ~ nodeType,
                kwDict("language", res["lanname"], "funcowner", res["funcowner"]))));
    }

    Response delete_(Value scid, Value fnidArg, bool onlySql = false)
    {
        Value data = fnidArg.isNone ? formOrJson(request()) : Value.dictOf("ids", Value([fnidArg]));
        bool cascade = checkCascadeOperation();
        try
        {
            foreach (fnid; data["ids"].iterItems())
            {
                auto r = conn.execute2darray(rt(DELETE_SQL, tv("scid", scid, "fnid", fnid)));
                if (!r.ok)
                    return internalServerError(r.error);
                if (r.value["rows"].length == 0)
                    return makeJsonResponse(0, Value(gettext("Error: Object not found.")),
                            Value(gettext("The specified function could not be found.\n")));
                auto row = r.value["rows"][0];
                auto sql = rt(DELETE_SQL, tv("name", row["name"], "func_args", row["func_args"], "nspname", row["nspname"],
                        "cascade", cascade));
                if (onlySql)
                    return Response.sqlOnly(sql);
                auto x = conn.executeScalar(sql);
                if (!x.ok)
                    return internalServerError(x.error);
            }
            return makeJsonResponse(1, Value(""), Value(gettext("Function dropped.")));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response update(Value gid, Value sid, Value did, Value scid, Value fnid)
    {
        bool ok;
        auto sql = getSql(gid, sid, did, scid, req_, fnid, ok, false, false, false);
        if (!ok)
            return internalServerError(sql);
        if (sql.length && sql.strip("\n").length && sql.strip(" ").length)
        {
            auto r = conn.executeScalar(sql);
            if (!r.ok)
                return internalServerError(r.error);
            Response e2;
            auto resp = fetchProperties(gid, sid, did, scid, fnid, e2);
            if (e2 !is null)
                return e2;
            string objName;
            if (nodeType == "procedure")
                objName = resp["name_with_args"].toString;
            else if (nodeType == "function")
                objName = resp["name"].toString ~ "(" ~ (resp["proargs"].truthy ? resp["proargs"].toString : "") ~ ")";
            else
                objName = resp["name"].toString ~ "()";
            return jsonify(Value.dictOf("node", gbn(fnid, resp["pronamespace"], objName, "icon-" ~ nodeType,
                    kwDict("language", resp["lanname"], "funcowner", resp["funcowner"], "description", resp["description"]))));
        }
        return makeJsonResponse(1, Value(""), Value("Nothing to update."), Value(null),
                Value.dictOf("id", fnid, "scid", scid, "sid", sid, "gid", gid, "did", did));
    }

    // ---------------------------------------------------------------- SQL generation

    /// `_get_arguments`: returns the types of the arguments that are not OUT. (The `args` string the Python code builds
    /// is lost there because strings are immutable, so `func_args` is always empty; only the types survive.)
    private static string[] argumentTypes(Value argsList)
    {
        string[] withoutName;
        foreach (a; argsList.iterItems())
        {
            bool include = !a.contains("argmode") || (a["argmode"] != Value("OUT") && !a["argmode"].isNone);
            if (include && a.contains("argtype"))
                withoutName ~= a["argtype"].toString;
        }
        return withoutName;
    }

    private void parsePrivilegeData(Value resp)
    {
        if (resp.contains("acl"))
        {
            resp["acl"] = parsePrivToDb(resp["acl"], ["X"]);
            resp["revoke_all"] = Value(setRevokeAll(resp["acl"]));
        }
    }

    private void getSchemaNameFromOid(Value resp)
    {
        if (resp.contains("pronamespace"))
            resp["pronamespace"] = getSchema(resp["pronamespace"]);
    }

    private Value definitionFor(bool isProcedure, Value scid, Value fnid, Value resp, string targetSchema, out Response err)
    {
        auto r = conn.execute2darray(rt(GET_DEFINITION_SQL, tv("data", resp, "fnid", fnid, "scid", scid)));
        if (!r.ok)
        {
            err = internalServerError(r.error);
            return Value(null);
        }
        auto row = r.value["rows"][0];
        if (targetSchema.length)
        {
            row["nspname"] = Value(targetSchema);
            if (!isProcedure)
                resp["pronamespace"] = Value(targetSchema);
        }
        auto nameWithDefaultArgs = qtIdentStr(row["nspname"].toString, row["proname"].toString) ~ "(\n\t"
            ~ row["func_args"].toString.replace(", ", ",\n\t") ~ ")";
        auto vars = tv("data", resp, "query_type", "create", "func_def", nameWithDefaultArgs, "query_for", "sql_panel",
                "conn", conn);
        if (!isProcedure)
            vars["add_replace_clause"] = Value(true);
        return Value(rt(CREATE_SQL, vars));
    }

    Response sqlView(Value gid, Value sid, Value did, Value scid, Value fnid, string targetSchema = null, bool jsonResp = true,
            bool allowCodeFormatting = true)
    {
        Response err;
        auto resp = fetchProperties(gid, sid, did, scid, fnid, err);
        if (err !is null)
            return err;
        string[] argsWithoutName;
        if (resp.contains("arguments") && resp["arguments"].length > 0)
        {
            resp["args"] = resp["arguments"];
            argsWithoutName = argumentTypes(resp["arguments"]);
        }
        resp["func_args"] = Value("");
        resp["func_args_without"] = Value(argsWithoutName.join(", "));
        if (allowCodeFormatting)
            reformatProsrcCode(resp);
        string objectType;
        Value funcDef;
        if (nodeType == "procedure")
        {
            objectType = "procedure";
            if (resp.contains("provolatile"))
            {
                static immutable vol = ["v": "VOLATILE", "s": "STABLE", "i": "IMMUTABLE"];
                auto key = resp["provolatile"].toString;
                resp["provolatile"] = Value(key in vol ? vol[key] : "");
            }
            getSchemaNameFromOid(resp);
            parsePrivilegeData(resp);
            funcDef = definitionFor(true, scid, fnid, resp, targetSchema, err);
        }
        else
        {
            objectType = "function";
            if (nodeType == "trigger_function" && scid != resp["pronamespace"])
                scid = resp["pronamespace"];
            getSchemaNameFromOid(resp);
            parsePrivilegeData(resp);
            funcDef = definitionFor(false, scid, fnid, resp, targetSchema, err);
        }
        if (err !is null)
            return err;
        auto typeNames = resp["proargtypenames"].toString.stripLeft("(").stripRight(")");
        auto up = objectType.toUpper;
        auto header = "-- " ~ up ~ ": " ~ resp["pronamespace"].toString ~ "." ~ resp["proname"].toString ~ "(" ~ typeNames ~ ")\n\n";
        header ~= "-- DROP " ~ up ~ " IF EXISTS " ~ qtIdentStr(resp["pronamespace"].toString, resp["proname"].toString)
            ~ "(" ~ typeNames ~ ");\n\n";
        auto pattern = regex("\n{2,}");
        if (!jsonResp)
            return Response.sqlOnly(replaceAll(funcDef.toString, pattern, "\n\n"));
        auto sql = replaceAll(header ~ funcDef.toString, pattern, "\n\n");
        return makeResponse(Value(sql));
    }

    /// `_get_sql`: returns the SQL, or (with `ok` false) the error message.
    string getSql(Value gid, Value sid, Value did, Value scid, Value data, Value fnid, out bool ok, bool isSql = false,
            bool isSchemaDiff = false, bool allowCodeFormatting = true)
    {
        static immutable vol = ["v": "VOLATILE", "s": "STABLE", "i": "IMMUTABLE"];
        static immutable parallel = ["u": "UNSAFE", "s": "SAFE", "r": "RESTRICTED"];
        getSchemaNameFromOid(data);
        string sql;
        if (!fnid.isNone)
        {
            if (data.contains("provolatile"))
                data["provolatile"] = data["provolatile"].truthy ? Value(vol[data["provolatile"].toString]) : Value("");
            string errmsg;
            if (!getSqlForEditMode(data, parallel, gid, sid, did, scid, fnid, isSchemaDiff, errmsg, sql, allowCodeFormatting))
            {
                ok = false;
                return errmsg;
            }
        }
        else
        {
            parsePrivilegeData(data);
            Value argsList = Value.newList();
            if (data.contains("arguments") && data["arguments"].length > 0)
                argsList = data["arguments"];
            else if (data.contains("args") && data["args"].length > 0)
                argsList = data["args"];
            data["func_args"] = Value("");
            data["func_args_without"] = Value(argumentTypes(argsList).join(", "));
            formatProsrcForPureSql(data, false);
            if (allowCodeFormatting)
                reformatProsrcCode(data);
            sql = rt(CREATE_SQL, tv("data", data, "is_sql", isSql, "conn", conn));
        }
        ok = true;
        return sql.strip("\n");
    }

    private bool getSqlForEditMode(Value data, immutable string[string] parallelDict, Value gid, Value sid, Value did, Value scid,
            Value fnid, bool isSchemaDiff, out string errmsg, out string sql, bool allowCodeFormatting)
    {
        static immutable vol = ["v": "VOLATILE", "s": "STABLE", "i": "IMMUTABLE"];
        if (data.contains("proparallel") && data["proparallel"].truthy)
            data["proparallel"] = Value(parallelDict[data["proparallel"].toString]);
        Response perr;
        auto oldData = fetchProperties(gid, sid, did, scid, fnid, perr);
        if (perr !is null)
        {
            errmsg = gettext("Could not find the function in the database.");
            return false;
        }
        oldData["pronamespace"] = getSchema(oldData["pronamespace"]);
        if (oldData.contains("provolatile") && !oldData["provolatile"].isNone)
            oldData["provolatile"] = Value(vol[oldData["provolatile"].toString]);
        if (oldData.contains("proparallel") && !oldData["proparallel"].isNone)
            oldData["proparallel"] = Value(parallelDict[oldData["proparallel"].toString]);
        if ((nodeType == "function" || nodeType == "procedure")
                && (oldData.dict.get("dependsonextensions", Value(null)).isNone
                    || data.dict.get("dependsonextensions", Value(null)).isNone))
        {
            auto o = oldData.dict.get("dependsonextensions", Value(null));
            oldData["dependsonextensions"] = o.truthy ? o : Value.newList();
            auto d = data.dict.get("dependsonextensions", Value(null));
            data["dependsonextensions"] = d.truthy ? d : Value.newList();
        }
        data["change_func"] = Value(false);
        foreach (arg; ["lanname", "prosrc", "probin", "prosrc_c", "provolatile", "proisstrict", "prosecdef", "proparallel",
                "procost", "proleakproof", "arguments", "prorows", "prosupportfunc", "prorettypename"])
            if ((arg == "arguments" && data.contains(arg) && data[arg].length > 0) || data.contains(arg))
                data["change_func"] = Value(true);
        if (data.contains("arguments") && data["arguments"].isDict && data["arguments"].dict.get("added", Value(null)).truthy)
        {
            bool anyNotOut;
            foreach (a; data["arguments"]["added"].iterItems())
            {
                auto mode = a.dict.get("argmode", Value(null));
                if ((mode.truthy ? mode.toString : "IN") != "OUT")
                    anyNotOut = true;
            }
            errmsg = anyNotOut
                ? gettext("Adding a new IN/INOUT/VARIADIC argument to an existing function/procedure is not supported, as "
                        ~ "PostgreSQL would create a separate, overloaded routine rather than replacing this one. Please "
                        ~ "create a new function/procedure instead.")
                : gettext("Adding a new OUT argument to an existing function/procedure is not supported, as it would "
                        ~ "change the shape of the returned row. Please create a new function/procedure instead.");
            return false;
        }
        // _update_arguments_for_get_sql
        if (data.contains("arguments") && data["arguments"].length > 0)
        {
            if (data["arguments"].isDict)
                foreach (arg; data["arguments"].dict.get("changed", Value.newList()).iterItems())
                    foreach (oldArg; oldData["arguments"].iterItems())
                        if (arg["argid"] == oldArg["argid"])
                        {
                            oldArg.dict.update(arg.dict);
                            break;
                        }
            data["arguments"] = oldData["arguments"];
        }
        else if (data["change_func"].truthy)
            data["arguments"] = oldData["arguments"];
        // _parser_privilege
        if (data.contains("acl"))
            foreach (key; ["added", "deleted", "changed"])
                if (data["acl"].contains(key))
                    data["acl"][key] = parsePrivToDb(data["acl"][key], ["X"]);
        auto chngdVariables = Value.newDict();
        data["merged_variables"] = Value.newList();
        oldData["chngd_variables"] = Value.newDict();
        auto delVariables = Value.newDict();
        bool hasVars(string key) => data.contains("variables") && data["variables"].contains(key);
        if (data["change_func"].truthy)
        {
            if (hasVars("deleted"))
                foreach (v; data["variables"]["deleted"].iterItems())
                    delVariables[v["name"].toString] = v["value"];
            if (hasVars("changed"))
                foreach (v; data["variables"]["changed"].iterItems())
                    chngdVariables[v["name"].toString] = v["value"];
            if (hasVars("added"))
                foreach (v; data["variables"]["added"].iterItems())
                    chngdVariables[v["name"].toString] = v["value"];
            if (!isSchemaDiff)
                foreach (v; oldData["variables"].iterItems())
                    oldData["chngd_variables"][v["name"].toString] = v["value"];
            foreach (name, val; oldData["chngd_variables"].dict)
                if (!chngdVariables.contains(name) && !delVariables.contains(name))
                    chngdVariables[name] = val;
            foreach (name, val; chngdVariables.dict)
                data["merged_variables"].append(Value.dictOf("name", name, "value", val));
        }
        else
        {
            if (hasVars("changed"))
                foreach (v; data["variables"]["changed"].iterItems())
                    data["merged_variables"].append(v);
            if (hasVars("added"))
                foreach (v; data["variables"]["added"].iterItems())
                    data["merged_variables"].append(v);
        }
        formatProsrcForPureSql(data, false, oldData["lanname"].toString);
        if (allowCodeFormatting)
            reformatProsrcCode(data);
        sql = rt(UPDATE_SQL, tv("data", data, "o_data", oldData, "conn", conn));
        return true;
    }

    private Response selectSql(Value scid, Value fnid)
    {
        auto r = conn.execute2darray(rt(GET_DEFINITION_SQL, tv("fnid", fnid, "scid", scid)));
        if (!r.ok)
            return internalServerError(r.error);
        if (r.value["rows"].length == 0)
            return gone(gettext("The specified function could not be found."));
        auto row = r.value["rows"][0];
        auto argString = row["func_with_identity_arguments"].toString;
        auto name = qtIdentStr(row["nspname"].toString, row["proname"].toString) ~ "(" ~ argPlaceholders(argString) ~ ")";
        return makeResponse(Value("SELECT " ~ name));
    }

    private static string argPlaceholders(string argString)
    {
        if (argString.length == 0)
            return "";
        string[] parts;
        foreach (arg; argString.split(","))
            parts ~= "\n\t<" ~ arg.strip(" ") ~ ">";
        return parts.join(",") ~ "\n";
    }

    private Response execSql(Value gid, Value sid, Value did, Value scid, Value fnid)
    {
        Response err;
        auto resp = fetchProperties(gid, sid, did, scid, fnid, err);
        if (err !is null)
            return err;
        if (resp.contains("pronamespace"))
            resp["pronamespace"] = getSchema(resp["pronamespace"]);
        auto name = qtIdentStr(resp["pronamespace"].toString, resp["proname"].toString) ~ "("
            ~ argPlaceholders(resp["proargs"].toString) ~ ")";
        auto sql = (manager.serverType == "pg" ? "CALL " : "EXEC ") ~ name;
        return makeResponse(Value(sql));
    }

    private Response statistics(Value scid, Value fnid)
    {
        string sqlName = "stats.sql";
        Value schemaName = Value(null);
        if (fnid.isNone)
        {
            sqlName = "coll_stats.sql";
            auto r = conn.executeScalar(renderTemplate("schemas/pg/#" ~ to!string(manager.version_) ~ "#/sql/get_name.sql",
                    tv("scid", scid, "conn", conn)));
            if (!r.ok)
                return internalServerError(r.error);
            schemaName = r.value;
        }
        auto r = conn.executeDict(rt(sqlName, tv("conn", conn, "fnid", fnid, "scid", scid, "schema_name", schemaName)));
        if (!r.ok)
            return internalServerError(r.error);
        return makeJsonResponse(1, Value(""), Value(""), Value(null), r.value, 200);
    }
}

final class ProcedureView : FunctionView
{
    enum BASE_TEMPLATE_PATH = "procedures/{0}/sql/#{1}#";

    override string baseTemplate() => BASE_TEMPLATE_PATH;
    override string[] requiredArgs() => ["name", "pronamespace", "lanname", "prosrc"];
    override string nodeTypeName() => ProcedureModule.NODE_TYPE;
}

final class TriggerFunctionView : FunctionView
{
    enum BASE_TEMPLATE_PATH = "trigger_functions/{0}/sql/#{1}#";

    override string baseTemplate() => BASE_TEMPLATE_PATH;
    override string[] requiredArgs() => ["name", "pronamespace", "lanname", "prosrc"];
    override string nodeTypeName() => TriggerFunctionModule.NODE_TYPE;
}
