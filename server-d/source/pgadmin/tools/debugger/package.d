/// `pgadmin/tools/debugger`: Debugger tool for PostgreSQL and EDB Advanced Server functions and procedures.
module pgadmin.tools.debugger;

import std.algorithm : canFind, endsWith, startsWith;
import std.array : array, join, split;
import std.conv : to;
import std.random : uniform;
import std.regex : matchFirst, regex;
import std.string : format, indexOf, lastIndexOf, strip, stripLeft, stripRight;
import pgadmin.browser.common;
import pgadmin.browser.server_groups.servers.databases.extensions : getExtensionDetails;
import pgadmin.model : db;
import pgadmin.settings : getSetting;
import pgadmin.tools.debugger.instance : DebuggerInstance;
import pgadmin.utils.constants : SERVER_CONNECTION_CLOSED;
import pgadmin.utils.preferences : Preferences;
import pgadmin.db.driver : getServer;
import pgadmin.web.flask;

// Constants
private enum string MODULE_NAME = "debugger";
private enum string PLDBG_EXTN = "pldbgapi";
private enum long ASYNC_OK = 1;
private enum long BUSY = 3;
private enum string DEBUGGER_SQL_PATH = "debugger/sql";
private enum string DEBUGGER_SQL_V1_PATH = "debugger/sql/v1";
private enum string DEBUGGER_SQL_V3_PATH = "debugger/sql/v3";
private enum string SET_SEARCH_PATH = "SET search_path = %s;";

private Res executeDictSearchPath(Connection conn, string sql, string searchPath)
{
    if (cast(int) conn.transactionStatus() == 1)
        return Res(true, Value(BUSY));

    auto sqlSearch = format(SET_SEARCH_PATH, searchPath);
    auto resVoid = conn.executeVoid(sqlSearch);
    if (!resVoid.ok)
    {
        logDebug("Error setting the search path.");
        return resVoid;
    }

    return conn.executeDict(sql);
}

private Res executeAsyncSearchPath(Connection conn, string sql, string searchPath)
{
    if (cast(int) conn.transactionStatus() == 1)
        return Res(true, Value(BUSY));

    auto sqlSearch = format(SET_SEARCH_PATH, searchPath);
    auto resVoid = conn.executeVoid(sqlSearch);
    if (!resVoid.ok)
    {
        logDebug("Error setting the search path.");
        return resVoid;
    }

    if (conn.hasAsyncCursor)
        conn.releaseAsyncCursor();
    return conn.startAsync(sql, Value(null), true, null);
}

private struct CheckNodeResult
{
    bool isError;
    Response errResponse;
    Value rSet;
}

private CheckNodeResult checkNodeType(string nodeType, long fid, long trid, Connection conn, bool ppasServer, bool isProcSupported)
{
    CheckNodeResult res;
    if (nodeType == "trigger")
    {
        auto sql = renderTemplate(DEBUGGER_SQL_PATH ~ "/get_trigger_function_info.sql",
            tv("table_id", fid, "trigger_id", trid));
        auto trSet = conn.executeDict(sql);
        if (!trSet.ok)
        {
            logDebug("Error retrieving trigger function information from database");
            res.isError = true;
            res.errResponse = internalServerError(trSet.value.toString);
            return res;
        }
        if (trSet.value["rows"].length == 0)
        {
            res.isError = true;
            res.errResponse = gone(gettext("The specified trigger could not be found."));
            return res;
        }
        fid = trSet.value["rows"][0]["tgfoid"].integer;
    }

    if (nodeType == "edbfunc" || nodeType == "edbproc")
        fid = trid;

    auto sql = renderTemplate(DEBUGGER_SQL_PATH ~ "/get_function_debug_info.sql",
        tv("is_ppas_database", ppasServer,
           "hasFeatureFunctionDefaults", true,
           "fid", fid,
           "is_proc_supported", isProcSupported));
    auto rSet = conn.executeDict(sql);
    if (!rSet.ok)
    {
        logDebug("Error retrieving function information from database");
        res.isError = true;
        res.errResponse = internalServerError(rSet.value.toString);
        return res;
    }
    if (rSet.value["rows"].length == 0)
    {
        res.isError = true;
        res.errResponse = gone(format(gettext("The specified %s could not be found."), nodeType));
        return res;
    }

    res.isError = false;
    res.rSet = rSet.value;
    return res;
}

private bool checkDebuggerEnabled(Connection conn, out string msg)
{
    auto r1 = conn.executeScalar("SELECT count(*) FROM pg_catalog.pg_proc WHERE proname = 'pldbg_get_target_info'");
    if (!r1.ok)
    {
        logDebug("Failed to find the pldbgapi extension in this database.");
        msg = gettext("Failed to find the pldbgapi extension in this database.");
        return false;
    }
    auto r2 = conn.executeScalar("SELECT count(*) FROM pg_catalog.pg_proc WHERE proname = 'plpgsql_oid_debug'");
    if (!r2.ok)
    {
        logDebug("Failed to find the pldbgapi extension in this database.");
        msg = gettext("Failed to find the pldbgapi extension in this database.");
        return false;
    }
    if (r1.value.toString == "0" || r2.value.toString == "0")
    {
        msg = gettext("The debugger plugin is not enabled. Please create the pldbgapi extension in this database.");
        return false;
    }
    return true;
}

private bool checkUserIpReq(Value rSet)
{
    auto row0 = rSet["rows"][0];
    auto proargtypenames = row0["proargtypenames"].strOr("");
    if (proargtypenames.length == 0)
        return false;

    if (row0["pkg"].integer != 0 && row0["pkgconsoid"].integer != 0)
        return true;

    auto proargmodes = row0["proargmodes"].strOr("");
    if (proargmodes.length > 0)
    {
        auto modes = proargmodes.split(",");
        foreach (m; modes)
        {
            if (m != "o" && m != "t")
                return true;
        }
        return false;
    }

    return true;
}

private bool validateDebug(Connection conn, string debugType, bool isSuperuser, out string errorMsg)
{
    if (debugType == "indirect")
    {
        if (!isSuperuser)
        {
            errorMsg = gettext("You must be a superuser to set a global breakpoint and perform indirect debugging.");
            return false;
        }
        auto r = conn.executeScalar("SHOW shared_preload_libraries");
        if (!r.ok)
        {
            errorMsg = gettext("Could not fetch debugger plugin information.");
            return false;
        }
        if (!r.value.toString.canFind("plugin_debugger"))
        {
            errorMsg = gettext("The debugger plugin is not enabled. Please add the plugin to the shared_preload_libraries setting in the postgresql.conf file and restart the database server for indirect debugging.");
            return false;
        }
    }

    auto extVerRes = conn.executeScalar("SELECT installed_version FROM pg_catalog.pg_available_extensions WHERE name = 'pldbgapi'");
    if (!extVerRes.ok)
    {
        errorMsg = extVerRes.value.toString;
        return false;
    }
    if (conn.manager.serverType == "ppas" && conn.manager.sversion >= 110000)
    {
        try
        {
            if (to!double(extVerRes.value.toString) < 1.1)
            {
                errorMsg = gettext("Please upgrade the pldbgapi extension to 1.1 or above and try again.");
                return false;
            }
        }
        catch (Exception) {}
    }
    return true;
}

private bool getSearchPath(Connection conn, out string searchPath, out string errorMsg)
{
    auto extRes = getExtensionDetails(conn, Value(PLDBG_EXTN));
    if (!extRes.ok)
    {
        errorMsg = extRes.value.toString;
        return false;
    }
    string schemaName = extRes.value["schema"].toString;
    auto spRes = conn.executeScalar("SELECT current_setting('search_path')||'," ~ schemaName ~ "'");
    if (!spRes.ok)
    {
        errorMsg = spRes.value.toString;
        return false;
    }
    searchPath = spRes.value.toString;
    return true;
}

private bool getDebuggerVersion(Connection conn, string searchPath, out long dbgVersion, out string errorMsg)
{
    dbgVersion = 0;
    auto r1 = conn.executeVoid(format(SET_SEARCH_PATH, searchPath));
    if (!r1.ok)
    {
        errorMsg = r1.value.toString;
        return false;
    }
    auto r2 = conn.executeScalar("SELECT COUNT(*) FROM pg_catalog.pg_proc p " ~
        "LEFT JOIN pg_catalog.pg_namespace n ON p.pronamespace = n.oid " ~
        "WHERE n.nspname = ANY(current_schemas(false)) AND p.proname = 'pldbg_get_proxy_info';");
    if (!r2.ok)
    {
        errorMsg = r2.value.toString;
        return false;
    }
    if (r2.value.integer == 0)
        dbgVersion = 1;
    else
    {
        auto r3 = conn.executeScalar("SELECT proxyapiver FROM pldbg_get_proxy_info();");
        if (r3.ok && (r3.value.integer == 2 || r3.value.integer == 3))
            dbgVersion = r3.value.integer;
    }
    return true;
}

private Value filterParamsByDefault(Value paramsList, Value defaultValueStr, out string errorMsg)
{
    string[] defaultValues;
    if (defaultValueStr.type == VType.str && defaultValueStr.str.length > 0)
    {
        auto rawDefaults = defaultValueStr.str.split(",");
        foreach (idx, v; rawDefaults)
        {
            defaultValues ~= (idx == 0) ? v.strip : " " ~ v.strip;
        }
    }
    if (paramsList.isList)
    {
        auto items = paramsList.list.items;
        foreach (idx, param; items)
        {
            string paramVal = param.isDict ? param.dict.get("value", Value("")).toString : "";
            if (idx < defaultValues.length && paramVal == defaultValues[idx])
            {
                foreach (i, p; items[idx + 1 .. $])
                {
                    size_t defIdx = idx + 1 + i;
                    string subsequentVal = p.isDict ? p.dict.get("value", Value("")).toString : "";
                    if (defIdx >= defaultValues.length || subsequentVal != defaultValues[defIdx])
                    {
                        errorMsg = gettext("Once a default value is passed, no subsequent arguments should be provided.");
                        return Value(null);
                    }
                }
                return Value(items[0 .. idx].dup);
            }
        }
    }
    return paramsList;
}

private string getDebuggerTitle(string functionName, string args, string schema, string database)
{
    auto browserPref = Preferences.module_("browser").preference("debugger_tab_title_placeholder");
    string placeholders = "%FUNCTION%%ARGS% - [%DATABASE%]";
    if (browserPref !is null)
    {
        auto v = browserPref.get();
        if (v.type == VType.str)
            placeholders = v.str;
    }
    string title = placeholders.replace("%FUNCTION%", functionName);
    if (title.canFind("%ARGS%"))
    {
        auto openParen = args.lastIndexOf('(');
        if (openParen != -1 && args.endsWith(")"))
            args = args[openParen + 1 .. $ - 1];
        title = title.replace("%ARGS%", args);
    }
    title = title.replace("%SCHEMA%", schema);
    title = title.replace("%DATABASE%", database);
    return title;
}

private string getDebuggerTemplatePath(long debuggerVersion)
{
    return debuggerVersion <= 2 ? DEBUGGER_SQL_V1_PATH : DEBUGGER_SQL_V3_PATH;
}

private void convertDataToDict(Connection conn, ref Value columnsVal, ref Value resultVal)
{
    Value[] cols;
    auto ci = conn.getColumnInfo();
    if (ci.isList && ci.list.items.length > 0)
    {
        foreach (col; ci.list.items)
        {
            auto c = Value.dictOf(
                "name", col.dict.get("name", Value("")),
                "type_code", col.dict.get("type_code", Value(0L))
            );
            cols ~= c;
        }
    }
    columnsVal = Value(cols);

    if (resultVal.isList && resultVal.list.items.length > 0 && cols.length > 0)
    {
        Value[] rows;
        foreach (row; resultVal.list.items)
        {
            auto rowDict = Value.newDict();
            if (row.isList)
            {
                foreach (idx, item; row.list.items)
                {
                    if (idx < cols.length)
                    {
                        auto colName = cols[idx].dict.get("name", Value("")).toString;
                        rowDict[colName] = item;
                    }
                }
            }
            rows ~= rowDict;
        }
        resultVal = Value(rows);
    }
}

private void getAdditionalMsgs(Connection conn, ref string statusmsg)
{
    auto msgs = conn.messages();
    if (msgs.length > 0)
    {
        string[] stripped;
        foreach (m; msgs)
            stripped ~= m.strip("\n");
        auto joined = stripped.join("\n");
        if (statusmsg.length)
            statusmsg = joined ~ "\n" ~ statusmsg;
        else
            statusmsg = joined;
    }
}

private void releaseConnection(ServerManager manager, Value dbgObj)
{
    if (!dbgObj.isDict)
        return;
    auto did = dbgObj["database_id"].integer;
    auto connId = dbgObj["conn_id"].toString;
    auto conn = manager.connection(null, connId, true, Value(did));
    if (conn.connected())
        conn.cancelTransaction(connId, Value(did));
    manager.release(connId);

    if (dbgObj.dict.has("exe_conn_id"))
    {
        auto exeConnId = dbgObj["exe_conn_id"].toString;
        auto exeConn = manager.connection(null, exeConnId, true, Value(did));
        if (exeConn.connected())
            exeConn.cancelTransaction(exeConnId, Value(did));
        manager.release(exeConnId);
    }
}

private void closeDebuggerSession(long transId, bool closeAll = false)
{
    string[] transIds;
    if (closeAll)
        transIds = DebuggerInstance.getTransIds();
    else
        transIds = [to!string(transId)];

    foreach (tid; transIds)
    {
        auto deInst = new DebuggerInstance(tid);
        auto dbgObj = deInst.debuggerData;
        try
        {
            if (dbgObj.isDict)
            {
                auto sid = dbgObj["server_id"].integer;
                auto manager = getDriver().connectionManager(sid);
                if (manager !is null)
                    releaseConnection(manager, dbgObj);
            }
            deInst.clear();
        }
        catch (Exception)
        {
            deInst.clear();
        }
    }
}

private Value shortcutDefault(bool alt, bool shift, bool control, bool ctrlIsMeta, int keyCode, string char_)
{
    auto d = new Dict;
    d["alt"] = Value(alt);
    d["shift"] = Value(shift);
    d["control"] = Value(control);
    d["ctrl_is_meta"] = Value(ctrlIsMeta);
    d["key"] = Value.dictOf("key_code", Value(keyCode), "char", Value(char_));
    return Value(d);
}

private Dict shortcutKw(string catLabel)
{
    auto kw = new Dict;
    kw["category_label"] = Value(catLabel);
    kw["fields"] = Value(["key", "button", "alt", "shift", "control", "ctrl_is_meta"]);
    return kw;
}

final class DebuggerModule : Blueprint
{
    this()
    {
        super(MODULE_NAME);
        label = Value(gettext("Debugger"));
    }

    override string[] getExposedUrlEndpoints()
    {
        return [
            "debugger.index",
            "debugger.init_for_function",
            "debugger.init_for_trigger",
            "debugger.direct",
            "debugger.initialize_target_for_function",
            "debugger.initialize_target_for_trigger",
            "debugger.close",
            "debugger.restart",
            "debugger.start_listener",
            "debugger.execute_query",
            "debugger.messages",
            "debugger.start_execution",
            "debugger.set_breakpoint",
            "debugger.clear_all_breakpoint",
            "debugger.deposit_value",
            "debugger.select_frame",
            "debugger.get_arguments",
            "debugger.set_arguments",
            "debugger.clear_arguments",
            "debugger.poll_end_execution_result",
            "debugger.poll_result"
        ];
    }

    override void registerPreferences()
    {
        auto prefs = Preferences.module_(MODULE_NAME);
        if (prefs is null)
            return;

        auto skw = shortcutKw(PREF_LABEL_KEYBOARD_SHORTCUTS);
        prefs.register("keyboard_shortcuts", "btn_start", Value(gettext("Continue/Start")),
                       "keyboardshortcut", shortcutDefault(true, true, false, false, 67, "c"), skw);
        prefs.register("keyboard_shortcuts", "btn_stop", Value(gettext("Stop")),
                       "keyboardshortcut", shortcutDefault(true, true, false, false, 83, "s"), skw);
        prefs.register("keyboard_shortcuts", "btn_step_into", Value(gettext("Step into")),
                       "keyboardshortcut", shortcutDefault(true, true, false, false, 73, "i"), skw);
        prefs.register("keyboard_shortcuts", "btn_step_over", Value(gettext("Step over")),
                       "keyboardshortcut", shortcutDefault(true, true, false, false, 79, "o"), skw);
        prefs.register("keyboard_shortcuts", "btn_toggle_breakpoint", Value(gettext("Toggle breakpoint")),
                       "keyboardshortcut", shortcutDefault(true, true, false, false, 84, "t"), skw);
        prefs.register("keyboard_shortcuts", "btn_clear_breakpoints", Value(gettext("Clear all breakpoints")),
                       "keyboardshortcut", shortcutDefault(true, true, false, false, 88, "x"), skw);
        prefs.register("keyboard_shortcuts", "edit_grid_values", Value(gettext("Edit grid values")),
                       "keyboardshortcut", shortcutDefault(true, true, false, false, 81, "q"), skw);
        prefs.register("keyboard_shortcuts", "move_previous", Value(gettext("Previous tab")),
                       "keyboardshortcut", shortcutDefault(true, true, false, false, 219, "["), skw);
        prefs.register("keyboard_shortcuts", "move_next", Value(gettext("Next tab")),
                       "keyboardshortcut", shortcutDefault(true, true, false, false, 221, "]"), skw);
        prefs.register("keyboard_shortcuts", "switch_panel", Value(gettext("Switch panel")),
                       "keyboardshortcut", shortcutDefault(true, true, false, false, 9, "Tab"), skw);
    }

    override void onLogout()
    {
        closeDebuggerSession(0, true);
    }

    override void setup()
    {
        route("/", "index", ["GET"], loginRequired((Dict a) {
            return badRequest(gettext("This URL cannot be called directly."));
        }));

        auto initFuncView = loginRequired((Dict a) {
            auto nodeType = a["node_type"].toString;
            auto sid = a["sid"].integer;
            auto did = a["did"].integer;
            auto scid = a["scid"].integer;
            auto fid = a["fid"].integer;
            long trid = a.has("trid") ? a["trid"].integer : 0L;

            auto manager = getDriver().connectionManager(sid);
            auto conn = manager.connection(null, null, true, Value(did));
            bool ppasServer = manager.serverType == "ppas";
            bool isProcSupported = ppasServer ? false : (manager.version_ >= 110000);

            auto chk = checkNodeType(nodeType, fid, trid, conn, ppasServer, isProcSupported);
            if (chk.isError)
                return chk.errResponse;

            auto rSet = chk.rSet;
            auto row0 = rSet["rows"][0];
            bool retStatus = true;
            string msg = "";

            if ((row0["pkgname"].strOr("").length > 0) && row0["prosrc"].strOr("").length == 0)
            {
                retStatus = false;
                msg = row0["name"].toString ~ " " ~ gettext("is not defined in package body.");
            }
            else if (row0["name"].toString.canFind(":"))
            {
                retStatus = false;
                msg = gettext("Functions with a colon in the name cannot be debugged.");
            }
            else if (ppasServer && row0["prosrc"].strOr("").stripLeft.startsWith("$__EDBwrapped__$"))
            {
                retStatus = false;
                msg = gettext("EDB Advanced Server wrapped functions cannot be debugged.");
            }
            else if (ppasServer && row0["lanname"].strOr("") == "edbspl" &&
                     row0["proargmodes"].strOr("").canFind("v"))
            {
                retStatus = false;
                msg = gettext("An 'edbspl' target with a variadic argument is not supported and cannot be debugged.");
            }
            else
            {
                retStatus = checkDebuggerEnabled(conn, msg);
            }

            if (!retStatus)
            {
                logDebug(msg);
                return internalServerError(msg);
            }

            bool reqInput = checkUserIpReq(rSet);
            rSet["rows"][0]["require_input"] = Value(reqInput);

            auto deInst = new DebuggerInstance();
            auto funcData = Value.dictOf(
                "oid", Value(fid),
                "name", row0["name"],
                "is_func", row0["isfunc"],
                "is_ppas_database", Value(ppasServer),
                "is_callable", Value(false),
                "schema", row0["schemaname"],
                "language", row0["lanname"],
                "return_type", row0["rettype"],
                "args_type", row0["proargtypenames"],
                "args_name", row0["proargnames"],
                "arg_mode", row0["proargmodes"],
                "use_default", row0["pronargdefaults"],
                "default_value", row0["proargdefaults"],
                "pkgname", row0["pkgname"],
                "pkg", row0["pkg"],
                "require_input", Value(reqInput),
                "args_value", Value("")
            );
            deInst.functionData = funcData;
            deInst.updateSession();

            return makeJsonResponse(1, Value(""), Value(""), Value(null),
                Value.dictOf("debug_info", rSet["rows"], "trans_id", Value(deInst.transId)));
        });

        route("/init/<node_type>/<int:sid>/<int:did>/<int:scid>/<int:fid>",
              "init_for_function", ["GET"], initFuncView);
        route("/init/<node_type>/<int:sid>/<int:did>/<int:scid>/<int:fid>/<int:trid>",
              "init_for_trigger", ["GET"], initFuncView);

        route("/direct/<int:trans_id>", "direct", ["GET"], loginRequired((Dict a) {
            auto transId = a["trans_id"].integer;
            auto deInst = new DebuggerInstance(transId);
            if (!deInst.debuggerData.isDict)
                return makeJsonResponse(1, Value(""), Value(""), Value(null), Value.dictOf("status", Value(true)));

            long debugType = (deInst.debuggerData["debug_type"].toString == "indirect") ? 0L : 1L;
            string funcArgs = "(";
            auto fd = deInst.functionData;
            if (fd.isDict && fd.dict.has("args_name") && fd["args_name"].strOr("").length > 0)
            {
                auto argNames = fd["args_name"].str.split(",");
                auto argTypes = fd.dict.has("args_type") ? fd["args_type"].str.split(",") : [];
                string[] pairs;
                foreach (i, name; argNames)
                {
                    string t = i < argTypes.length ? argTypes[i] : "";
                    pairs ~= name ~ " " ~ t;
                }
                funcArgs ~= pairs.join(", ");
            }
            funcArgs ~= ")";

            auto layout = getSetting("Debugger/Layout");
            string funcNameWithArgs = deInst.debuggerData["function_name"].toString ~ funcArgs;
            auto manager = getDriver().connectionManager(deInst.debuggerData["server_id"].integer);
            auto conn = manager.connection(null, deInst.debuggerData["conn_id"].toString, true, deInst.debuggerData["database_id"]);
            string title = getDebuggerTitle(deInst.debuggerData["function_name"].toString, funcArgs,
                fd["schema"].toString, conn.db);

            auto vars = tv(
                "function_name", deInst.debuggerData["function_name"],
                "title", Value(title),
                "uniqueId", Value(transId),
                "debug_type", Value(debugType),
                "is_desktop_mode", Value(false),
                "is_linux", Value(true),
                "client_platform", Value("Linux"),
                "function_name_with_arguments", Value(funcNameWithArgs),
                "layout", Value(layout)
            );
            return new Response(renderTemplate("debugger/direct.html", vars), 200, "text/html");
        }));

        auto initTargetView = loginRequired((Dict a) {
            auto debugType = a["debug_type"].toString;
            auto transId = a["trans_id"].integer;
            auto sid = a["sid"].integer;
            auto did = a["did"].integer;
            auto scid = a["scid"].integer;
            auto funcId = a["func_id"].integer;
            long triId = a.has("tri_id") ? a["tri_id"].integer : 0L;

            string connId = to!string(uniform(1, 9999999));
            auto manager = getDriver().connectionManager(sid);
            auto conn = manager.connection(null, connId, true, Value(did));

            auto cRes = conn.connect();
            if (!cRes.ok)
                return internalServerError(cRes.value.toString);

            bool isSuperuser = manager.userInfo["is_superuser"].truthy;
            string valErr;
            if (!validateDebug(conn, debugType, isSuperuser, valErr))
                return internalServerError(valErr);

            if (triId != 0)
            {
                auto sql = renderTemplate(DEBUGGER_SQL_PATH ~ "/get_trigger_function_info.sql",
                    tv("table_id", funcId, "trigger_id", triId));
                auto trSet = conn.executeDict(sql);
                if (!trSet.ok)
                {
                    logDebug("Error retrieving trigger function information from database");
                    return internalServerError(trSet.value.toString);
                }
                funcId = trSet.value["rows"][0]["tgfoid"].integer;
            }

            string searchPath, spErr;
            if (!getSearchPath(conn, searchPath, spErr))
                return internalServerError(spErr);

            long dbgVersion;
            string verErr;
            if (!getDebuggerVersion(conn, searchPath, dbgVersion, verErr))
                return internalServerError(verErr);

            logDebug(format("Debugger version is: %d", dbgVersion));

            auto deInst = new DebuggerInstance(transId);
            if (request().text.length > 0)
            {
                auto paramsList = tryParseJson(request().text, Value(null));
                string filtErr;
                paramsList = filterParamsByDefault(paramsList, deInst.functionData.dict.get("default_value", Value("")), filtErr);
                if (filtErr.length > 0)
                    return internalServerError(filtErr);
                deInst.functionData["args_value"] = paramsList;
            }

            deInst.debuggerData = Value.dictOf(
                "conn_id", Value(connId),
                "server_id", Value(sid),
                "database_id", Value(did),
                "schema_id", Value(scid),
                "function_id", Value(funcId),
                "function_name", deInst.functionData["name"],
                "debug_type", Value(debugType),
                "debugger_version", Value(dbgVersion),
                "search_path", Value(searchPath),
                "frame_id", Value(0L),
                "restart_debug", Value(0L)
            );
            deInst.updateSession();

            return makeJsonResponse(1, Value(""), Value(""), Value(null),
                Value.dictOf("status", Value(true), "debuggerTransId", Value(transId),
                             "data_obj", Value.dictOf("db_name", Value(conn.db))));
        });

        route("/initialize_target/<debug_type>/<int:trans_id>/<int:sid>/<int:did>/<int:scid>/<int:func_id>",
              "initialize_target_for_function", ["POST"], initTargetView);
        route("/initialize_target/<debug_type>/<int:trans_id>/<int:sid>/<int:did>/<int:scid>/<int:func_id>/<int:tri_id>",
              "initialize_target_for_trigger", ["POST"], initTargetView);

        route("/close/<int:trans_id>", "close", ["DELETE"], loginRequired((Dict a) {
            closeDebuggerSession(a["trans_id"].integer);
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value.dictOf("status", Value(true)));
        }));

        route("/restart/<int:trans_id>", "restart", ["GET"], loginRequired((Dict a) {
            auto transId = a["trans_id"].integer;
            auto deInst = new DebuggerInstance(transId);
            if (!deInst.debuggerData.isDict)
                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    Value.dictOf("status", Value(false), "result", Value(SERVER_CONNECTION_CLOSED)));

            auto manager = getDriver().connectionManager(deInst.debuggerData["server_id"].integer);
            auto conn = manager.connection(null, deInst.debuggerData["conn_id"].toString, true, deInst.debuggerData["database_id"]);

            if (conn.connected())
            {
                if (deInst.debuggerData["restart_debug"].integer == 0)
                {
                    deInst.debuggerData["restart_debug"] = Value(1L);
                    deInst.updateSession();
                }
                deInst.functionData["server_id"] = deInst.debuggerData["server_id"];
                deInst.functionData["database_id"] = deInst.debuggerData["database_id"];
                deInst.functionData["schema_id"] = deInst.debuggerData["schema_id"];
                deInst.functionData["function_id"] = deInst.debuggerData["function_id"];
                deInst.functionData["trans_id"] = Value(to!string(transId));
                deInst.functionData["proargmodes"] = deInst.functionData["arg_mode"];
                deInst.functionData["proargtypenames"] = deInst.functionData["args_type"];
                deInst.functionData["pronargdefaults"] = deInst.functionData["use_default"];
                deInst.functionData["proargdefaults"] = deInst.functionData["default_value"];
                deInst.functionData["proargnames"] = deInst.functionData["args_name"];
                deInst.functionData["require_input"] = deInst.functionData["require_input"];
                deInst.updateSession();

                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    Value.dictOf("status", Value(true), "restart_debug", Value(true), "result", deInst.functionData));
            }
            return makeJsonResponse(1, Value(""), Value(""), Value(null),
                Value.dictOf("status", Value(false), "result", Value(SERVER_CONNECTION_CLOSED)));
        }));

        route("/start_listener/<int:trans_id>", "start_listener", ["POST"], loginRequired((Dict a) {
            auto transId = a["trans_id"].integer;
            auto deInst = new DebuggerInstance(transId);
            if (!deInst.debuggerData.isDict)
                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    Value.dictOf("status", Value(false), "result", Value(SERVER_CONNECTION_CLOSED)));

            auto driver = getDriver();
            auto manager = driver.connectionManager(deInst.debuggerData["server_id"].integer);
            auto conn = manager.connection(null, deInst.debuggerData["conn_id"].toString, true, deInst.debuggerData["database_id"]);

            long dbgVersion = deInst.debuggerData["debugger_version"].integer;
            string templatePath = getDebuggerTemplatePath(dbgVersion);

            if (request().text.length > 0)
            {
                auto data = tryParseJson(request().text, Value(null));
                if (data.isList)
                {
                    deInst.functionData["args_value"] = data;
                    deInst.updateSession();
                }
            }

            if (!conn.connected())
            {
                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    Value.dictOf("status", Value(false), "result", Value(SERVER_CONNECTION_CLOSED)));
            }

            if (deInst.debuggerData["debug_type"].toString == "direct")
            {
                string funcName;
                if (deInst.functionData["pkg"].integer == 0)
                    funcName = qtIdentStr(deInst.functionData["schema"].toString, deInst.functionData["name"].toString);
                else
                    funcName = qtIdentStr(deInst.functionData["schema"].toString,
                        deInst.functionData["pkgname"].toString, deInst.functionData["name"].toString);

                if (deInst.debuggerData["restart_debug"].integer == 0)
                {
                    string sql;
                    if (deInst.functionData["language"].toString == "plpgsql")
                    {
                        sql = renderTemplate(templatePath ~ "/debug_plpgsql_execute_target.sql",
                            tv("packge_oid", deInst.functionData["pkg"],
                               "function_oid", deInst.debuggerData["function_id"]));
                    }
                    else
                    {
                        sql = renderTemplate(templatePath ~ "/debug_spl_execute_target.sql",
                            tv("packge_oid", deInst.functionData["pkg"],
                               "function_oid", deInst.debuggerData["function_id"]));
                    }
                    auto sRes = executeDictSearchPath(conn, sql, deInst.debuggerData["search_path"].toString);
                    if (!sRes.ok)
                        return internalServerError(sRes.value.toString);
                }

                Value[] debuggerArgsValues;
                if (deInst.functionData["args_value"].isList)
                {
                    foreach (arg; deInst.functionData["args_value"].list.items)
                    {
                        auto argDict = arg.isDict ? arg.dict.copy : null;
                        if (argDict !is null)
                        {
                            auto t = argDict.get("type", Value("")).toString;
                            auto val = argDict.get("value", Value("")).toString;
                            if (t.endsWith("[]") && val.length > 0 && val != "NULL")
                            {
                                if (val.startsWith("{") && val.endsWith("}"))
                                    val = val[1 .. $ - 1];
                                auto parts = val.split(",");
                                Value[] arrList;
                                foreach (p; parts)
                                    arrList ~= Value.dictOf("value", Value(p.strip));
                                argDict["value"] = Value(arrList);
                            }
                            debuggerArgsValues ~= Value(argDict);
                        }
                    }
                }

                auto strQuery = renderTemplate(DEBUGGER_SQL_PATH ~ "/execute_plpgsql.sql",
                    tv("func_name", funcName,
                       "is_func", deInst.functionData["is_func"],
                       "ret_type", deInst.functionData["return_type"],
                       "data", Value(debuggerArgsValues),
                       "is_ppas_database", deInst.functionData["is_ppas_database"],
                       "conn", conn));

                auto r = executeAsyncSearchPath(conn, strQuery, deInst.debuggerData["search_path"].toString);
                if (!r.ok)
                    return internalServerError(r.value.toString);

                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    Value.dictOf("status", Value(true), "result", r.value));
            }
            else
            {
                auto lSql = renderTemplate(templatePath ~ "/create_listener.sql");
                auto lRes = executeDictSearchPath(conn, lSql, deInst.debuggerData["search_path"].toString);
                if (!lRes.ok)
                    return internalServerError(lRes.value.toString);
                auto intSessionId = lRes.value["rows"][0]["pldbg_create_listener"].integer;

                auto bSql = renderTemplate(templatePath ~ "/add_breakpoint_pg.sql",
                    tv("session_id", intSessionId, "function_oid", deInst.debuggerData["function_id"]));
                auto bRes = executeDictSearchPath(conn, bSql, deInst.debuggerData["search_path"].toString);
                if (!bRes.ok)
                    return internalServerError(bRes.value.toString);

                auto wSql = renderTemplate(templatePath ~ "/wait_for_target.sql",
                    tv("session_id", intSessionId));
                deInst.debuggerData["exe_conn_id"] = deInst.debuggerData["conn_id"];
                deInst.debuggerData["restart_debug"] = Value(1L);
                deInst.debuggerData["frame_id"] = Value(0L);
                deInst.debuggerData["session_id"] = Value(intSessionId);
                deInst.updateSession();

                auto wRes = executeAsyncSearchPath(conn, wSql, deInst.debuggerData["search_path"].toString);
                if (!wRes.ok)
                    return internalServerError(wRes.value.toString);

                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    Value.dictOf("status", Value(true), "result", wRes.value));
            }
        }));

        route("/execute_query/<int:trans_id>/<query_type>", "execute_query", ["GET"], loginRequired((Dict a) {
            auto transId = a["trans_id"].integer;
            auto queryType = a["query_type"].toString;
            auto deInst = new DebuggerInstance(transId);
            if (!deInst.debuggerData.isDict)
                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    Value.dictOf("status", Value(false), "result", Value(SERVER_CONNECTION_CLOSED)));

            auto manager = getDriver().connectionManager(deInst.debuggerData["server_id"].integer);
            auto conn = manager.connection(null, deInst.debuggerData["exe_conn_id"].toString, true, deInst.debuggerData["database_id"]);
            if (!conn.connected())
                return internalServerError(SERVER_CONNECTION_CLOSED);

            string templatePath = getDebuggerTemplatePath(deInst.debuggerData["debugger_version"].integer);
            auto sql = renderTemplate(templatePath ~ "/" ~ queryType ~ ".sql",
                tv("session_id", deInst.debuggerData["session_id"]));

            if (queryType == "continue" || queryType == "step_into" || queryType == "step_over")
            {
                deInst.debuggerData["frame_id"] = Value(0L);
                deInst.updateSession();

                auto r = executeAsyncSearchPath(conn, sql, deInst.debuggerData["search_path"].toString);
                if (r.value.type == VType.integer && r.value.integer == BUSY)
                    return makeJsonResponse(1, Value(""), Value(""), Value(null),
                        Value.dictOf("status", Value("Busy"), "result", Value.newList()));

                if (r.value.type == VType.str && r.value.str.canFind("select() failed waiting for target"))
                    return makeJsonResponse(1, Value(""), Value(""), Value(null),
                        Value.dictOf("status", Value(true), "result", Value(null)));

                if (!r.ok)
                    return internalServerError(r.value.toString);

                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    Value.dictOf("status", Value(true), "result", r.value));
            }

            auto r = executeDictSearchPath(conn, sql, deInst.debuggerData["search_path"].toString);
            if (!r.ok)
                return internalServerError(r.value.toString);

            if (queryType == "abort_target")
            {
                return makeJsonResponse(1, Value(""), Value(gettext("Debugging aborted successfully.")), Value(null),
                    Value.dictOf("status", Value("Success"), "result", r.value));
            }

            if (r.value.type == VType.integer && r.value.integer == BUSY)
            {
                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    Value.dictOf("status", Value("Busy"), "result", Value.newList()));
            }

            return makeJsonResponse(1, Value(""), Value(""), Value(null),
                Value.dictOf("status", Value("Success"), "result", r.value["rows"]));
        }));

        auto messagesView = loginRequired((Dict a) {
            auto transId = a["trans_id"].integer;
            auto deInst = new DebuggerInstance(transId);
            if (!deInst.debuggerData.isDict)
                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    Value.dictOf("status", Value("NotConnected"), "result", Value(SERVER_CONNECTION_CLOSED)));

            auto manager = getDriver().connectionManager(deInst.debuggerData["server_id"].integer);
            auto conn = manager.connection(null, deInst.debuggerData["conn_id"].toString, true, deInst.debuggerData["database_id"]);

            if (conn.connected())
            {
                string status = "Busy";
                string portNumber = "";
                auto notify = conn.messages();
                foreach (x; notify)
                {
                    if (x.canFind("PLDBGBREAK"))
                    {
                        auto m = matchFirst(x, regex(`\d+`));
                        if (!m.empty)
                        {
                            status = "Success";
                            portNumber = m.hit;
                            break;
                        }
                    }
                }
                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    Value.dictOf("status", Value(status), "result", Value(portNumber)));
            }
            return internalServerError(SERVER_CONNECTION_CLOSED);
        });
        route("/messages/<int:trans_id>/", "messages", ["GET"], messagesView);
        route("/messages/<int:trans_id>", "messages_no_slash", ["GET"], messagesView);

        route("/start_execution/<int:trans_id>/<int:port_num>", "start_execution", ["GET"], loginRequired((Dict a) {
            auto transId = a["trans_id"].integer;
            auto portNum = a["port_num"].integer;
            auto deInst = new DebuggerInstance(transId);
            if (!deInst.debuggerData.isDict)
                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    Value.dictOf("status", Value("NotConnected"), "result", Value(SERVER_CONNECTION_CLOSED)));

            string exeConnId = to!string(uniform(1, 9999999));
            auto manager = getDriver().connectionManager(deInst.debuggerData["server_id"].integer);
            auto conn = manager.connection(null, exeConnId, true, deInst.debuggerData["database_id"]);

            auto cRes = conn.connect();
            if (!cRes.ok)
                return internalServerError(cRes.value.toString);

            long dbgVersion = deInst.debuggerData["debugger_version"].integer;
            string templatePath = getDebuggerTemplatePath(dbgVersion);
            auto sql = renderTemplate(templatePath ~ "/attach_to_port.sql", tv("port", portNum));
            auto resPort = executeDictSearchPath(conn, sql, deInst.debuggerData["search_path"].toString);
            if (!resPort.ok)
                return internalServerError(resPort.value.toString);

            if (resPort.value.type == VType.integer && resPort.value.integer == BUSY)
            {
                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    Value.dictOf("status", Value("Busy"), "result", Value.newList()));
            }

            auto sessionId = resPort.value["rows"][0]["pldbg_attach_to_port"];
            deInst.debuggerData["restart_debug"] = Value(0L);
            deInst.debuggerData["frame_id"] = Value(0L);
            deInst.debuggerData["exe_conn_id"] = Value(exeConnId);
            deInst.debuggerData["debugger_version"] = Value(dbgVersion);
            deInst.debuggerData["session_id"] = sessionId;
            deInst.updateSession();

            return makeJsonResponse(1, Value(""), Value(""), Value(null),
                Value.dictOf("status", Value("Success"), "result", sessionId));
        }));

        route("/set_breakpoint/<int:trans_id>/<int:line_no>/<int:set_type>", "set_breakpoint", ["GET"], loginRequired((Dict a) {
            auto transId = a["trans_id"].integer;
            auto lineNo = a["line_no"].integer;
            auto setType = a["set_type"].integer;
            auto deInst = new DebuggerInstance(transId);
            if (!deInst.debuggerData.isDict)
                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    Value.dictOf("status", Value(false), "result", Value(SERVER_CONNECTION_CLOSED)));

            auto manager = getDriver().connectionManager(deInst.debuggerData["server_id"].integer);
            auto conn = manager.connection(null, deInst.debuggerData["exe_conn_id"].toString, true, deInst.debuggerData["database_id"]);

            string templatePath = getDebuggerTemplatePath(deInst.debuggerData["debugger_version"].integer);
            auto sqlStack = renderTemplate(templatePath ~ "/get_stack_info.sql",
                tv("session_id", deInst.debuggerData["session_id"]));
            auto resStack = executeDictSearchPath(conn, sqlStack, deInst.debuggerData["search_path"].toString);
            if (!resStack.ok)
                return internalServerError(resStack.value.toString);

            if (resStack.value.type == VType.integer && resStack.value.integer == BUSY)
            {
                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    Value.dictOf("status", Value("Busy"), "result", Value.newList()));
            }

            auto frameId = deInst.debuggerData["frame_id"].integer;
            auto rows = resStack.value["rows"];
            if (rows.length == 0 || frameId < 0 || frameId >= rows.length)
            {
                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    Value.dictOf("status", Value(false), "result", Value("Empty stack info.")));
            }
            auto foid = rows[frameId]["func"].integer;

            if (conn.connected())
            {
                string queryType = (setType == 1) ? "set_breakpoint" : "clear_breakpoint";
                auto sql = renderTemplate(templatePath ~ "/" ~ queryType ~ ".sql",
                    tv("session_id", deInst.debuggerData["session_id"], "foid", foid, "line_number", lineNo));
                auto result = executeDictSearchPath(conn, sql, deInst.debuggerData["search_path"].toString);
                if (!result.ok)
                    return internalServerError(result.value.toString);
                if (result.value.type == VType.integer && result.value.integer == BUSY)
                {
                    return makeJsonResponse(1, Value(""), Value(""), Value(null),
                        Value.dictOf("status", Value("Busy"), "result", Value.newList()));
                }
                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    Value.dictOf("status", Value(true), "result", result.value["rows"]));
            }
            return makeJsonResponse(1, Value(""), Value(""), Value(null),
                Value.dictOf("status", Value(false), "result", Value(SERVER_CONNECTION_CLOSED)));
        }));

        route("/clear_all_breakpoint/<int:trans_id>", "clear_all_breakpoint", ["POST"], loginRequired((Dict a) {
            auto transId = a["trans_id"].integer;
            auto deInst = new DebuggerInstance(transId);
            if (!deInst.debuggerData.isDict)
                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    Value.dictOf("status", Value(false), "result", Value(SERVER_CONNECTION_CLOSED)));

            auto manager = getDriver().connectionManager(deInst.debuggerData["server_id"].integer);
            auto conn = manager.connection(null, deInst.debuggerData["exe_conn_id"].toString, true, deInst.debuggerData["database_id"]);
            if (!conn.connected())
                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    Value.dictOf("status", Value(false), "result", Value(SERVER_CONNECTION_CLOSED)));

            string templatePath = getDebuggerTemplatePath(deInst.debuggerData["debugger_version"].integer);
            auto bodyJson = tryParseJson(request().text, Value(null));
            Value resultRows = Value.newList();
            if (bodyJson.isDict && bodyJson.dict.has("breakpoint_list"))
            {
                auto bpListStr = bodyJson["breakpoint_list"].strOr("");
                if (bpListStr.length > 0)
                {
                    auto lineNumbers = bpListStr.split(",");
                    foreach (ln; lineNumbers)
                    {
                        auto sql = renderTemplate(templatePath ~ "/clear_breakpoint.sql",
                            tv("session_id", deInst.debuggerData["session_id"],
                               "foid", deInst.debuggerData["function_id"],
                               "line_number", to!long(ln.strip)));
                        auto r = executeDictSearchPath(conn, sql, deInst.debuggerData["search_path"].toString);
                        if (!r.ok)
                            return internalServerError(r.value.toString);
                        if (r.value.type == VType.integer && r.value.integer == BUSY)
                            return makeJsonResponse(1, Value(""), Value(""), Value(null),
                                Value.dictOf("status", Value("Busy"), "result", Value.newList()));
                        resultRows = r.value["rows"];
                    }
                }
            }
            else
            {
                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    Value.dictOf("status", Value(false)));
            }
            return makeJsonResponse(1, Value(""), Value(""), Value(null),
                Value.dictOf("status", Value(true), "result", resultRows));
        }));

        route("/deposit_value/<int:trans_id>", "deposit_value", ["POST"], loginRequired((Dict a) {
            auto transId = a["trans_id"].integer;
            auto deInst = new DebuggerInstance(transId);
            if (!deInst.debuggerData.isDict)
                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    Value.dictOf("status", Value(false), "result", Value(SERVER_CONNECTION_CLOSED)));

            auto manager = getDriver().connectionManager(deInst.debuggerData["server_id"].integer);
            auto conn = manager.connection(null, deInst.debuggerData["exe_conn_id"].toString, true, deInst.debuggerData["database_id"]);
            if (!conn.connected())
                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    Value.dictOf("status", Value(false), "result", Value(SERVER_CONNECTION_CLOSED)));

            string templatePath = getDebuggerTemplatePath(deInst.debuggerData["debugger_version"].integer);
            auto bodyJson = tryParseJson(request().text, Value(null));
            if (bodyJson.isList && bodyJson.list.items.length > 0)
            {
                auto firstItem = bodyJson.list.items[0];
                auto varName = firstItem["name"].toString;
                auto val = firstItem["value"].toString;
                auto sql = renderTemplate(templatePath ~ "/deposit_value.sql",
                    tv("session_id", deInst.debuggerData["session_id"],
                       "var_name", varName,
                       "line_number", -1,
                       "val", val,
                       "conn", conn));
                auto r = executeDictSearchPath(conn, sql, deInst.debuggerData["search_path"].toString);
                if (!r.ok)
                    return internalServerError(r.value.toString);
                if (r.value.type == VType.integer && r.value.integer == BUSY)
                    return makeJsonResponse(1, Value(""), Value(""), Value(null),
                        Value.dictOf("status", Value("Busy"), "result", Value.newList()));

                bool deposited = r.value["rows"][0]["pldbg_deposit_value"].truthy;
                string info = deposited ? gettext("Value deposited successfully") : gettext("Error setting the value");
                return makeJsonResponse(1, Value(""), Value(info), Value(null),
                    Value.dictOf("status", Value(true), "info", Value(info), "result", Value(deposited)));
            }
            return makeJsonResponse(1, Value(""), Value(""), Value(null),
                Value.dictOf("status", Value(false), "result", Value(SERVER_CONNECTION_CLOSED)));
        }));

        route("/select_frame/<int:trans_id>/<int:frame_id>", "select_frame", ["GET"], loginRequired((Dict a) {
            auto transId = a["trans_id"].integer;
            auto frameId = a["frame_id"].integer;
            auto deInst = new DebuggerInstance(transId);
            if (!deInst.debuggerData.isDict)
                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    Value.dictOf("status", Value(false), "result", Value(SERVER_CONNECTION_CLOSED)));

            auto manager = getDriver().connectionManager(deInst.debuggerData["server_id"].integer);
            auto conn = manager.connection(null, deInst.debuggerData["exe_conn_id"].toString, true, deInst.debuggerData["database_id"]);
            if (!conn.connected())
                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    Value.dictOf("status", Value(false), "result", Value(SERVER_CONNECTION_CLOSED)));

            string templatePath = getDebuggerTemplatePath(deInst.debuggerData["debugger_version"].integer);
            deInst.debuggerData["frame_id"] = Value(frameId);
            deInst.updateSession();

            auto sql = renderTemplate(templatePath ~ "/select_frame.sql",
                tv("session_id", deInst.debuggerData["session_id"], "frame_id", frameId));
            auto r = executeDictSearchPath(conn, sql, deInst.debuggerData["search_path"].toString);
            if (!r.ok)
                return internalServerError(r.value.toString);
            if (r.value.type == VType.integer && r.value.integer == BUSY)
                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    Value.dictOf("status", Value("Busy"), "result", Value.newList()));

            return makeJsonResponse(1, Value(""), Value(""), Value(null),
                Value.dictOf("status", Value(true), "result", r.value["rows"]));
        }));

        route("/get_arguments/<int:sid>/<int:did>/<int:scid>/<int:func_id>", "get_arguments", ["GET"], loginRequired((Dict a) {
            auto sid = a["sid"].integer;
            auto did = a["did"].integer;
            auto scid = a["scid"].integer;
            auto funcId = a["func_id"].integer;

            if (getServer(sid).isNone)
                return makeJsonResponse(0, Value(gettext("Could not find the required server.")), Value(""), Value(null), Value(null), 410);

            auto rows = db.query(
                "SELECT arg_id, is_null, is_expression, use_default, value FROM debugger_function_arguments " ~
                "WHERE server_id = ? AND database_id = ? AND schema_id = ? AND function_id = ? AND user_id = ?",
                Value(sid), Value(did), Value(scid), Value(funcId), Value(currentUserId()));

            if (rows.length > 0)
            {
                Value[] argsData;
                foreach (r; rows)
                {
                    argsData ~= Value.dictOf(
                        "arg_id", r["arg_id"],
                        "is_null", r["is_null"],
                        "is_expression", r["is_expression"],
                        "use_default", r["use_default"],
                        "value", r["value"]
                    );
                }
                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    Value.dictOf("result", Value(argsData), "args_count", Value(cast(long) rows.length)));
            }
            else
            {
                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    Value.dictOf("result", Value("result"), "args_count", Value(0L)));
            }
        }));

        route("/set_arguments/<int:sid>/<int:did>/<int:scid>/<int:func_id>", "set_arguments", ["POST"], loginRequired((Dict a) {
            auto sid = a["sid"].integer;
            auto did = a["did"].integer;
            auto scid = a["scid"].integer;
            auto funcId = a["func_id"].integer;

            if (getServer(sid).isNone)
                return makeJsonResponse(0, Value(gettext("Could not find the required server.")), Value(""), Value(null), Value(null), 410);

            auto bodyJson = tryParseJson(request().text, Value(null));
            if (bodyJson.isList)
            {
                try
                {
                    foreach (item; bodyJson.list.items)
                    {
                        auto itemSid = item["server_id"].integer;
                        auto itemDid = item["database_id"].integer;
                        auto itemScid = item["schema_id"].integer;
                        auto itemFuncId = item["function_id"].integer;
                        auto itemArgId = item["arg_id"].integer;
                        auto isNull = item["is_null"].integer;
                        auto isExpr = item["is_expression"].integer;
                        auto useDef = item["use_default"].integer;
                        string arrayStr = item.dict.has("value") ? item["value"].toString : "";

                        if (item.dict.has("is_array_value") && item["is_array_value"].truthy && arrayStr.length > 0)
                        {
                            if (arrayStr.startsWith("[") && arrayStr.endsWith("]"))
                                arrayStr = arrayStr[1 .. $ - 1];
                        }

                        auto existing = db.query(
                            "SELECT 1 FROM debugger_function_arguments WHERE server_id = ? AND database_id = ? AND schema_id = ? AND function_id = ? AND arg_id = ? AND user_id = ?",
                            Value(itemSid), Value(itemDid), Value(itemScid), Value(itemFuncId), Value(itemArgId), Value(currentUserId()));

                        if (existing.length > 0)
                        {
                            db.exec(
                                "UPDATE debugger_function_arguments SET is_null = ?, is_expression = ?, use_default = ?, value = ? WHERE server_id = ? AND database_id = ? AND schema_id = ? AND function_id = ? AND arg_id = ? AND user_id = ?",
                                Value(isNull), Value(isExpr), Value(useDef), Value(arrayStr),
                                Value(itemSid), Value(itemDid), Value(itemScid), Value(itemFuncId), Value(itemArgId), Value(currentUserId()));
                        }
                        else
                        {
                            db.exec(
                                "INSERT INTO debugger_function_arguments (user_id, server_id, database_id, schema_id, function_id, arg_id, is_null, is_expression, use_default, value) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                                Value(currentUserId()), Value(itemSid), Value(itemDid), Value(itemScid), Value(itemFuncId), Value(itemArgId),
                                Value(isNull), Value(isExpr), Value(useDef), Value(arrayStr));
                        }
                    }
                }
                catch (Exception e)
                {
                    return makeJsonResponse(0, Value(e.msg), Value(""), Value(null), Value(null), 410);
                }
            }
            return makeJsonResponse(1, Value(""), Value(""), Value(null),
                Value.dictOf("status", Value(true), "result", Value("Success")));
        }));

        route("/clear_arguments/<int:sid>/<int:did>/<int:scid>/<int:func_id>", "clear_arguments", ["POST"], loginRequired((Dict a) {
            auto sid = a["sid"].integer;
            auto did = a["did"].integer;
            auto scid = a["scid"].integer;
            auto funcId = a["func_id"].integer;

            if (getServer(sid).isNone)
                return makeJsonResponse(0, Value(gettext("Could not find the required server.")), Value(""), Value(null), Value(null), 410);

            try
            {
                db.exec(
                    "DELETE FROM debugger_function_arguments WHERE server_id = ? AND database_id = ? AND schema_id = ? AND function_id = ? AND user_id = ?",
                    Value(sid), Value(did), Value(scid), Value(funcId), Value(currentUserId()));
            }
            catch (Exception e)
            {
                return makeJsonResponse(0, Value(e.msg), Value(""), Value(null), Value(null), 410);
            }
            return makeJsonResponse(1, Value(""), Value(""), Value(null),
                Value.dictOf("status", Value(true), "result", Value("Success")));
        }));

        auto pollEndView = loginRequired((Dict a) {
            auto transId = a["trans_id"].integer;
            auto deInst = new DebuggerInstance(transId);
            if (!deInst.debuggerData.isDict)
                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    Value.dictOf("status", Value("NotConnected"), "result", Value(SERVER_CONNECTION_CLOSED)));

            auto manager = getDriver().connectionManager(deInst.debuggerData["server_id"].integer);
            auto conn = manager.connection(null, deInst.debuggerData["conn_id"].toString, true, deInst.debuggerData["database_id"]);

            if (conn.connected())
            {
                string statusmsg = conn.statusMessage();
                if (statusmsg == "SELECT 1")
                    statusmsg = "";

                auto pr = conn.poll();
                if (!pr.ok)
                {
                    return makeJsonResponse(1, Value(""), Value(gettext("Execution completed with an error.")), Value(null),
                        Value.dictOf("status", Value("ERROR"), "status_message", Value(pr.error)));
                }

                if (pr.status == ASYNC_OK &&
                    !deInst.functionData["is_func"].truthy &&
                    (deInst.functionData["language"].toString == "edbspl" || deInst.functionData["language"].toString == "plpgsql"))
                {
                    getAdditionalMsgs(conn, statusmsg);
                    return makeJsonResponse(1, Value(""), Value(gettext("Execution Completed.")), Value(null),
                        Value.dictOf("status", Value("Success"), "status_message", Value(statusmsg)));
                }

                if (!pr.result.isNone)
                {
                    getAdditionalMsgs(conn, statusmsg);
                    Value colsVal, rowsVal = pr.result;
                    convertDataToDict(conn, colsVal, rowsVal);
                    return makeJsonResponse(1, Value(""), Value(gettext("Execution Completed.")), Value(null),
                        Value.dictOf("status", Value("Success"),
                                     "result", rowsVal,
                                     "col_info", colsVal,
                                     "status_message", Value(statusmsg)));
                }
                else
                {
                    getAdditionalMsgs(conn, statusmsg);
                    return makeJsonResponse(1, Value(""), Value(""), Value(null),
                        Value.dictOf("status", Value("Busy"), "result", Value(null), "status_message", Value(statusmsg)));
                }
            }
            return makeJsonResponse(1, Value(""), Value(""), Value(null),
                Value.dictOf("status", Value("NotConnected"), "result", Value(SERVER_CONNECTION_CLOSED)));
        });
        route("/poll_end_execution_result/<int:trans_id>/", "poll_end_execution_result", ["GET"], pollEndView);
        route("/poll_end_execution_result/<int:trans_id>", "poll_end_execution_result_no_slash", ["GET"], pollEndView);

        auto pollResultView = loginRequired((Dict a) {
            auto transId = a["trans_id"].integer;
            auto deInst = new DebuggerInstance(transId);
            if (!deInst.debuggerData.isDict)
                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    Value.dictOf("status", Value("NotConnected"), "result", Value(SERVER_CONNECTION_CLOSED)));

            auto manager = getDriver().connectionManager(deInst.debuggerData["server_id"].integer);
            auto conn = manager.connection(null, deInst.debuggerData["exe_conn_id"].toString, true, deInst.debuggerData["database_id"]);

            if (conn.connected())
            {
                auto pr = conn.poll();
                string status;
                Value result = pr.result;
                if (!pr.ok)
                    status = "ERROR";
                else if (pr.status == ASYNC_OK && !result.isNone)
                {
                    status = "Success";
                    Value colsVal;
                    convertDataToDict(conn, colsVal, result);
                }
                else
                    status = "Busy";

                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    Value.dictOf("status", Value(status), "result", result));
            }
            return makeJsonResponse(1, Value(""), Value(""), Value(null),
                Value.dictOf("status", Value("NotConnected"), "result", Value(SERVER_CONNECTION_CLOSED)));
        });
        route("/poll_result/<int:trans_id>/", "poll_result", ["GET"], pollResultView);
        route("/poll_result/<int:trans_id>", "poll_result_no_slash", ["GET"], pollResultView);
    }
}
