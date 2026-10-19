/// `pgadmin/tools/sqleditor` (the Query Tool and the View/Edit Data grid).
///
/// Python keeps each tab's command object (pickled) in `session['gridData']`; here the objects live in this process,
/// keyed by session id and transaction id, which is equivalent for a single worker.
module pgadmin.tools.sqleditor;

import std.algorithm : canFind, min;
import std.conv : to;
import std.math : ceil, floor;
import std.random : uniform;
import std.regex : regex, replaceAll;
import std.string : startsWith, strip;
import pgadmin.browser.common;
import pgadmin.browser.server_groups.servers : serverIconAndBackground, ServerNode;
import pgadmin.tools.sqleditor.command;
import pgadmin.tools.sqleditor.autocomplete : SQLAutoComplete;
import pgadmin.tools.sqleditor.macros;
import pgadmin.tools.sqleditor.csvlib;
import pgadmin.llm : isLlmEnabled;
import pgadmin.settings : getSetting;
import pgadmin.core.strutil : pyIntStrict;
import pgadmin.db.libpq : TxStatus;
import pgadmin.core.crypto : encrypt;
import pgadmin.utils.master_password : getCryptKey;
import pgadmin.tools.sqleditor.helpers;
import pgadmin.utils.paths : getCompleteFilePath;
import pgadmin.utils.preferences : Preferences;
import pgadmin.utils.server_access;
import pgadmin.web.flask;

// ------------------------------------------------------------ the per-session grid store

/// `session['gridData'][trans_id]`: the command object plus the `session_obj` dict entries.
final class GridTxn
{
    /// the stored ("pickled") command: requests work on a copy and store it back with `persist`
    BaseCommand cmd;
    Dict sess;
    /// the thread running the query (`thread_native_id` + `thread.is_alive()`) is alive
    bool running;

    this(BaseCommand cmd)
    {
        this.cmd = cmd;
        sess = new Dict;
    }

    /// `session_obj['command_obj'] = pickle.dumps(trans_obj)`
    void persist(BaseCommand trans)
    {
        cmd = cloneCommand(trans);
    }
}

private __gshared GridTxn[string][string] gridStore;

private GridTxn[string]* gridOfSession(bool create)
{
    auto sid = session().sid;
    if (auto p = sid in gridStore)
        return p;
    if (!create)
        return null;
    gridStore[sid] = null;
    return sid in gridStore;
}

private GridTxn findTxn(long transId)
{
    auto g = gridOfSession(false);
    if (g is null)
        return null;
    if (auto t = to!string(transId) in *g)
        return *t;
    return null;
}

private void storeTxn(string transId, GridTxn t)
{
    (*gridOfSession(true))[transId] = t;
}

private bool dropTxn(long transId)
{
    auto g = gridOfSession(false);
    if (g is null)
        return false;
    return (*g).remove(to!string(transId));
}

// ------------------------------------------------------------ helpers

private Preferences sqleditorPrefs() => Preferences.module_("sqleditor");

/// A preference of the sqleditor module (an error rather than a null dereference for a wrong name).
private Value sqlPref(string name)
{
    auto p = sqleditorPrefs().preference(name);
    if (p is null)
        throw new Exception("unknown preference sqleditor." ~ name);
    return p.get();
}

private Response jsonData(Value data, int status = 200)
    => makeJsonResponse(1, Value(""), Value(""), Value(null), data, status);

private Response transNotFound()
    => makeJsonResponse(0, Value(ERROR_MSG_TRANS_ID_NOT_FOUND), Value("DATAGRID_TRANSACTION_REQUIRED"), Value(null),
            Value(null), 404);

private Value argsDict()
{
    auto d = Value.newDict();
    foreach (k; request().args.keys)
        d[k] = Value(request().args.get(k));
    return d;
}

/// `json.loads(request.data) if request.data else (request.args or request.form)`
private Value dataOrArgs()
{
    auto req = request();
    if (req.text.length)
        return parseJson(req.text);
    if (!req.args.empty)
        return argsDict();
    return req.form.toDict;
}

private bool connectArg() => request().args.has("connect") && request().args.get("connect") == "1";

private string randomConnId() => to!string(1 + uniform(0, 9999998));

/// What `check_transaction_status` returns.
private struct TxnInfo
{
    bool status;
    string errorMsg;
    Response errorResponse;
    Connection conn;
    BaseCommand trans;
    GridTxn txn;
}

private Connection commandConnection(BaseCommand t, string connId, bool createWithBinary = true)
{
    auto mgr = getDriver().connectionManager(t.sid.integer);
    return mgr.connection(t.dbname.length ? t.dbname : null, connId, false, t.did, Value(null), createWithBinary,
            createWithBinary);
}

private TxnInfo checkTransactionStatus(long transId, bool autoComp = false)
{
    TxnInfo r;
    auto txn = findTxn(transId);
    if (txn is null)
    {
        r.errorMsg = ERROR_MSG_TRANS_ID_NOT_FOUND;
        return r;
    }
    auto trans = txn.cmd;
    string connId;
    bool connect;
    if (autoComp)
    {
        connId = trans.connIdAc;
        connect = true;
    }
    else
    {
        connId = trans.connId;
        connect = connectArg();
    }
    try
    {
        r.conn = commandConnection(trans, connId);
    }
    catch (ConnectionLost e)
        throw e;
    catch (SSHTunnelConnectionLost e)
        throw e;
    catch (CryptKeyMissing e)
        throw e;
    catch (Exception e)
    {
        logError(e.msg);
        r.errorResponse = internalServerError(e.msg);
        return r;
    }
    if (connect && r.conn !is null && !r.conn.connected())
        r.conn.connect();
    r.status = true;
    r.trans = cloneCommand(trans);
    r.txn = txn;
    return r;
}

/// `underscore_escape` of a JSON value
private Value uescape(Value v) => v.isString ? Value(underscoreEscape(v.str)) : v;

// ------------------------------------------------------------ connecting

private struct ConnectOutcome
{
    bool status;
    string msg;
    bool isAskPassword;
    string user;
}

/// `_connect(conn, **kwargs)`
private ConnectOutcome connectConn(Connection conn, Dict kwargs)
{
    ConnectOutcome o;
    string role, password, encpass;
    if (kwargs.has("user") && kwargs.has("role"))
    {
        o.user = kwargs["user"].strOr(null);
        role = kwargs["role"].truthy ? kwargs["role"].toString : null;
        password = kwargs.get("password").truthy ? kwargs["password"].toString : null;
        encpass = kwargs.get("encpass").truthy ? kwargs["encpass"].toString : null;
        o.isAskPassword = true;
    }
    Res r;
    if (o.user.length)
    {
        auto kw = new Dict;
        kw["user"] = o.user;
        kw["role"] = role is null ? Value(null) : Value(role);
        kw["password"] = password is null ? Value(null) : Value(password);
        kw["encpass"] = encpass is null ? Value(null) : Value(encpass);
        r = conn.connect(kw);
    }
    else
        r = conn.connect(kwargs);
    o.status = r.ok;
    o.msg = r.value.isNone ? "" : r.value.toString;
    return o;
}

private Response askPasswordResponse(Value server, string msg, string user)
{
    auto result = Value.dictOf("server_label", server["name"], "username",
            user.length ? Value(user) : server["username"], "errmsg", msg, "prompt_password", true, "allow_save_password",
            cfgBool("ALLOW_SAVE_PASSWORD") && session().get("allow_save_password").truthy);
    return makeJsonResponse(0, Value(""), Value(""), result, Value(null), 428);
}

private struct InitResult
{
    bool isError;
    Response errmsg;
    string connId;
    int version_;
}

/// `_init_sqleditor`
private InitResult initSqleditor(string transId, bool connect, Value sgid, Value sid, Value did, string dbname,
        Dict kwargs)
{
    InitResult res;
    string connId = kwargs.has("conn_id") ? kwargs["conn_id"].toString : randomConnId();
    kwargs.remove("conn_id");
    auto connIdAc = randomConnId();
    auto server = getServer(sid.integer);
    if (server.isNone)
    {
        res.isError = true;
        res.errmsg = internalServerError(gettext("Could not find the required server."));
        return res;
    }
    auto manager = getDriver().connectionManager(sid.integer);
    if (kwargs.get("password").isNone)
        kwargs["encpass"] = server.get("password").isNone ? Value(null) : Value(binaryColumn(server["password"]));
    else
        kwargs["encpass"] = Value(null);
    if (did.isNone)
        did = manager.did;
    BaseCommand commandObj;
    try
    {
        auto kw = new Dict;
        kw["conn_id"] = connId;
        kw["sgid"] = sgid;
        kw["sid"] = sid;
        kw["did"] = did;
        kw["conn_id_ac"] = connIdAc;
        foreach (k, v; kwargs)
            kw[k] = v;
        commandObj = createCommand("query_tool", kw);
    }
    catch (Exception e)
    {
        logError(e.msg);
        res.isError = true;
        res.errmsg = internalServerError(e.msg);
        return res;
    }
    auto pref = sqleditorPrefs();
    if (kwargs.get("auto_commit").isNone)
        kwargs["auto_commit"] = sqlPref("auto_commit");
    if (kwargs.get("auto_rollback").isNone)
        kwargs["auto_rollback"] = sqlPref("auto_rollback");
    if (kwargs.get("server_cursor").isNone)
        kwargs["server_cursor"] = sqlPref("server_cursor");
    try
    {
        auto dbOrNull = dbname.length ? dbname : null;
        auto conn = manager.connection(dbOrNull, connId, false, dbOrNull is null ? did : Value(null), Value(null), true,
                true);
        if (connect)
        {
            auto o = connectConn(conn, kwargs);
            if (!o.status)
            {
                logError(o.msg);
                res.isError = true;
                res.errmsg = o.isAskPassword ? askPasswordResponse(server, o.msg, o.user) : internalServerError(o.msg);
                return res;
            }
            if (sqlPref("autocomplete_on_key_press").truthy)
            {
                auto connAc = manager.connection(dbOrNull, connIdAc, false, dbOrNull is null ? did : Value(null),
                        Value(null), true, true);
                connectConn(connAc, kwargs);
            }
        }
    }
    catch (ConnectionLost e)
    {
        logError(e.msg);
        throw e;
    }
    catch (SSHTunnelConnectionLost e)
        throw e;
    catch (Exception e)
    {
        logError(e.msg);
        res.isError = true;
        res.errmsg = internalServerError(e.msg);
        return res;
    }
    commandObj.setAutoCommit(kwargs["auto_commit"]);
    commandObj.setAutoRollback(kwargs["auto_rollback"]);
    commandObj.setServerCursor(kwargs["server_cursor"]);
    commandObj.dbname = dbname.length ? dbname : null;
    commandObj.hasDbname = true;
    storeTxn(transId, new GridTxn(commandObj));
    res.connId = connId;
    res.version_ = manager.version_;
    return res;
}

/// `check_and_upgrade_to_qt`: promotes a View/Edit Data tab to a Query Tool.
private bool checkAndUpgradeToQt(long transId, bool connect, out string errmsg)
{
    auto txn = findTxn(transId);
    if (txn is null)
        return false;
    auto data = txn.cmd;
    if (!["table", "foreign_table", "view", "mview"].canFind(data.objectType))
        return false;
    auto mgr = getDriver().connectionManager(data.sid.integer);
    auto defaultConn = mgr.connection(null, data.connId, true, data.did);
    auto kwargs = new Dict;
    kwargs["user"] = defaultConn.manager.user is null ? Value(null) : Value(defaultConn.manager.user);
    kwargs["role"] = defaultConn.manager.role is null ? Value(null) : Value(defaultConn.manager.role);
    kwargs["password"] = defaultConn.manager.password is null ? Value(null) : Value(defaultConn.manager.password);
    kwargs["conn_id"] = data.connId;
    auto r = initSqleditor(to!string(transId), connect, data.sgid, data.sid, data.did, null, kwargs);
    if (r.isError)
    {
        errmsg = r.errmsg.body;
        return true;
    }
    return false;
}

private Response closeSqleditorSession(long transId)
{
    auto txn = findTxn(transId);
    if (txn is null)
        return null;
    auto cmd = txn.cmd;
    foreach (id; [cmd.connId, cmd.connIdAc])
    {
        if (id is null)
            continue;
        auto mgr = getDriver().connectionManagerOrNull(cmd.sid.integer);
        if (mgr !is null)
        {
            auto conn = mgr.connection(null, id, true, cmd.did);
            if (conn.connected())
            {
                conn.cancelTransaction(id, cmd.did);
                mgr.release(null, id, cmd.did);
            }
        }
    }
    return null;
}

private __gshared SQLAutoComplete[long] autoCompleteObjects;

// ------------------------------------------------------------ the module

final class SqlEditorModule : Blueprint
{
    this()
    {
        super("sqleditor");
    }

    enum LABEL = "Query Tool";

    override Value getOwnMenuItems()
    {
        auto item = Value.dictOf("name", "mnu_query_tool", "label", gettext("Query tool"), "priority", 100, "callback",
                "show_query_tool", "icon", "fa fa-question", "url", flaskApp().urlFor("help.static", kwDict("filename", Value("index.html"))));
        return Value.dictOf("tools", Value([item]));
    }

    override string[] getExposedUrlEndpoints() => [
        "sqleditor.initialize_viewdata", "sqleditor.initialize_sqleditor", "sqleditor.initialize_sqleditor_with_did",
        "sqleditor.filter_validate", "sqleditor.panel", "sqleditor.close", "sqleditor.update_sqleditor_connection",
        "sqleditor.view_data_start", "sqleditor.query_tool_start", "sqleditor.poll", "sqleditor.fetch_window",
        "sqleditor.fetch_all_from_start", "sqleditor.save", "sqleditor.inclusive_filter", "sqleditor.exclusive_filter",
        "sqleditor.remove_filter", "sqleditor.set_limit", "sqleditor.cancel_transaction", "sqleditor.get_object_name",
        "sqleditor.auto_commit", "sqleditor.auto_rollback", "sqleditor.autocomplete", "sqleditor.query_tool_download",
        "sqleditor.connection_status", "sqleditor.get_filter_data", "sqleditor.set_filter_data",
        "sqleditor.get_query_history", "sqleditor.add_query_history", "sqleditor.clear_query_history",
        "sqleditor.get_macro", "sqleditor.get_macros", "sqleditor.get_user_macros", "sqleditor.set_macros",
        "sqleditor.get_new_connection_data", "sqleditor.get_new_connection_servers",
        "sqleditor.get_new_connection_database", "sqleditor.get_new_connection_user",
        "sqleditor._check_server_connection_status", "sqleditor.get_new_connection_role", "sqleditor.connect_server",
        "sqleditor.server_cursor", "sqleditor.nlq_chat_stream", "sqleditor.explain_analyze_stream",
        "sqleditor.download_binary_data"];

    override bool hasLogoutHook() => true;

    override void onLogout()
    {
        auto g = gridOfSession(false);
        if (g is null)
            return;
        foreach (id, t; *g)
        {
            try
                closeSqleditorSession(to!long(id));
            catch (Exception e)
                logException(e);
        }
        gridStore.remove(session().sid);
    }

    override void setup()
    {
        setupRoutes();
        setupConnectionRoutes();
        setupMiscRoutes();
    }

    private void setupRoutes()
    {
        route("/", "index", ["GET"], loginRequired((Dict a) => badRequest(gettext("This URL cannot be requested directly."))));

        // ---------------------------------------------------------------- initialize
        route("/initialize/viewdata/<int:trans_id>/<int:cmd_type>/<obj_type>/<int:sgid>/<int:sid>/<int:did>/<int:obj_id>",
                "initialize_viewdata", ["PUT", "POST"], permissionsRequired(loginRequired((Dict a) => initializeViewdata(a)), "tools_query_tool"));
        route("/panel/<int:trans_id>", "panel", ["POST"], loginRequired((Dict a) => panel(a)), true);
        route("/initialize/sqleditor/<int:trans_id>/<int:sgid>/<int:sid>/<int:did>", "initialize_sqleditor_with_did",
                ["POST"], permissionsRequired(loginRequired((Dict a) => initializeSqleditor(a)), "tools_query_tool"), true);
        route("/initialize/sqleditor/<int:trans_id>/<int:sgid>/<int:sid>/<did>", "initialize_sqleditor_with_did",
                ["POST"], permissionsRequired(loginRequired((Dict a) => initializeSqleditor(a)), "tools_query_tool"), true);
        route("/initialize/sqleditor/<int:trans_id>/<int:sgid>/<int:sid>", "initialize_sqleditor", ["POST"],
                permissionsRequired(loginRequired((Dict a) => initializeSqleditor(a)), "tools_query_tool"), true);
        route("/initialize/sqleditor/update_connection/<int:trans_id>/<int:sgid>/<int:sid>/<int:did>",
                "update_sqleditor_connection", ["POST"], loginRequired((Dict a) => updateSqleditorConnection(a)));
        route("/close/<int:trans_id>", "close", ["DELETE"], loginRequired((Dict a) => closeView(a)));
        route("/filter/validate/<int:sid>/<int:did>/<int:obj_id>", "filter_validate", ["PUT", "POST"],
                loginRequired((Dict a) => validateFilter(a)));

        // ---------------------------------------------------------------- running queries
        route("/view_data/start/<int:trans_id>", "view_data_start", ["GET"], loginRequired((Dict a) => startViewData(a)));
        route("/query_tool/start/<int:trans_id>", "query_tool_start", ["PUT", "POST"], loginRequired((Dict a) => startQueryTool(a)));
        route("/poll/<int:trans_id>", "poll", ["GET"], loginRequired((Dict a) => poll(a)));
        route("/fetch_window/<int:trans_id>/<int:from_rownum>/<int:to_rownum>", "fetch_window", ["GET"],
                loginRequired((Dict a) => fetchWindow(a)));
        route("/fetch_all_from_start/<int:trans_id>/<int:limit>", "fetch_all_from_start", ["GET"],
                loginRequired((Dict a) => fetchAllFromStart(a)));
        route("/save/<int:trans_id>", "save", ["PUT", "POST"], loginRequired((Dict a) => save(a)));
        route("/filter/inclusive/<int:trans_id>", "inclusive_filter", ["PUT", "POST"],
                loginRequired((Dict a) => appendFilter(a, true)));
        route("/filter/exclusive/<int:trans_id>", "exclusive_filter", ["PUT", "POST"],
                loginRequired((Dict a) => appendFilter(a, false)));
        route("/filter/remove/<int:trans_id>", "remove_filter", ["PUT", "POST"], loginRequired((Dict a) => removeFilter(a)));
        route("/limit/<int:trans_id>", "set_limit", ["PUT", "POST"], loginRequired((Dict a) => setLimit(a)));
        route("/cancel/<int:trans_id>", "cancel_transaction", ["PUT", "POST"], loginRequired((Dict a) => cancelTransaction(a)));
        route("/object/get/<int:trans_id>", "get_object_name", ["GET"], loginRequired((Dict a) => getObjectName(a)));
        route("/auto_commit/<int:trans_id>", "auto_commit", ["PUT", "POST"],
                loginRequired((Dict a) => setPrefOptions(a, "auto_commit")));
        route("/auto_rollback/<int:trans_id>", "auto_rollback", ["PUT", "POST"],
                loginRequired((Dict a) => setPrefOptions(a, "auto_rollback")));
        route("/server_cursor/<int:trans_id>", "server_cursor", ["PUT", "POST"],
                loginRequired((Dict a) => setPrefOptions(a, "server_cursor")));
        route("/autocomplete/<int:trans_id>", "autocomplete", ["PUT", "POST"], loginRequired((Dict a) => autoComplete(a)));
        route("/status/<int:trans_id>", "connection_status", ["GET"], loginRequired((Dict a) => queryToolStatus(a)));
    }

    // ------------------------------------------------------------ views

    private static Response initializeViewdata(Dict a)
    {
        auto data = dataOrArgs();
        auto filterSql = data.get("sql_filter");
        auto sc = data.get("server_cursor");
        bool serverCursor = sc == Value("true") || sc == Value(true);
        auto dbnameV = data.get("dbname");
        string dbname = dbnameV.isNone ? null : dbnameV.toString;
        auto kwargs = new Dict;
        kwargs["user"] = data.get("user");
        kwargs["role"] = data.get("role");
        kwargs["password"] = data.get("password");
        auto sid = a["sid"];
        auto server = getServer(sid.integer);
        if (server.isNone)
            return makeJsonResponse(0, Value(gettext("Could not find the required server.")), Value(""), Value(null),
                    Value(null), 410);
        if (kwargs["password"].isNone)
            kwargs["encpass"] = server.get("password").isNone ? Value(null) : Value(binaryColumn(server["password"]));
        else
            kwargs["encpass"] = Value(null);
        auto connId = randomConnId();
        Connection conn;
        Connection defaultConn;
        auto did = a["did"];
        try
        {
            auto manager = getDriver().connectionManager(sid.integer);
            conn = manager.connection(dbname, connId, false, dbname is null ? did : Value(null), Value(null), true, true);
            auto o = connectConn(conn, kwargs);
            if (!o.status)
            {
                logError(o.msg);
                if (o.isAskPassword)
                    return askPasswordResponse(server, o.msg, o.user);
                return internalServerError(o.msg);
            }
            defaultConn = manager.connection(null, null, true, did);
        }
        catch (ConnectionLost e)
            throw e;
        catch (SSHTunnelConnectionLost e)
            throw e;
        catch (Exception e)
        {
            logError(e.msg);
            return internalServerError(e.msg);
        }
        auto r = defaultConn.connect();
        if (!r.ok)
        {
            logError(r.error);
            return internalServerError(r.error);
        }
        r = conn.connect();
        if (!r.ok)
        {
            logError(r.error);
            return internalServerError(r.error);
        }
        BaseCommand commandObj;
        try
        {
            auto objType = a["obj_type"].toString;
            if (objType == "partition")
                objType = "table";
            auto kw = new Dict;
            kw["conn_id"] = connId;
            kw["sgid"] = a["sgid"];
            kw["sid"] = sid;
            kw["did"] = did;
            kw["obj_id"] = a["obj_id"];
            kw["cmd_type"] = a["cmd_type"];
            kw["sql_filter"] = filterSql;
            kw["server_cursor"] = Value(serverCursor);
            commandObj = createCommand(objType, kw);
        }
        catch (ObjectGone e)
            throw e;
        catch (Exception e)
        {
            logError(e.msg);
            return internalServerError(e.msg);
        }
        auto transId = a["trans_id"].toString;
        auto old = findTxn(a["trans_id"].integer);
        if (old !is null)
        {
            auto oldGrid = cast(GridCommand) old.cmd;
            auto newGrid = cast(GridCommand) commandObj;
            if (oldGrid !is null && newGrid !is null && oldGrid.did == did && oldGrid.objId == a["obj_id"])
            {
                newGrid.setFilter(oldGrid.hasRowFilter ? Value(oldGrid.rowFilter) : Value(null));
                newGrid.setDataSorting(Value.dictOf("data_sorting", oldGrid.dataSorting), true);
            }
        }
        commandObj.dbname = conn.db.length ? conn.db : null;
        commandObj.hasDbname = true;
        storeTxn(transId, new GridTxn(commandObj));
        return jsonData(Value.dictOf("conn_id", connId));
    }

    private static Response panel(Dict a)
    {
        Value params;
        auto req = request();
        bool hasParams;
        if (!req.args.empty)
        {
            params = argsDict();
            hasParams = true;
        }
        if (!req.form.empty)
        {
            if (!hasParams)
                throw new Exception("'NoneType' object does not support item assignment");
            foreach (k; req.form.keys)
                params[k] = Value(req.form.get(k));
        }
        if (!hasParams)
            throw new Exception("'NoneType' object does not support item assignment");
        params["trans_id"] = a["trans_id"];
        params["client_platform"] = Value(null);
        params["is_linux"] = Value(true);
        params["bgcolor"] = Value(null);
        params["fgcolor"] = Value(null);
        if (!params.contains("sid"))
            throw new HTTPException(400);
        auto s = getServer(to!long(params["sid"].toString));
        if (!s.isNone)
        {
            if (s.get("bgcolor").truthy)
            {
                if (s["bgcolor"] != Value("#ffffff"))
                    params["bgcolor"] = s["bgcolor"];
                params["fgcolor"] = s.get("fgcolor").truthy ? s["fgcolor"] : Value("black");
            }
            params["server_name"] = uescape(s["name"]);
            if (!params.contains("user"))
                params["user"] = uescape(s["username"]);
            if (!params.contains("role") && s.get("role").truthy)
                params["role"] = uescape(s["role"]);
            params["layout"] = Value(getSetting("SQLEditor/Layout", ""));
            params["macros"] = getUserMacros();
            params["is_desktop_mode"] = Value(false);
            if (!params.contains("title"))
                throw new Exception("'title'");
            params["title"] = uescape(params["title"]);
            if (!params.contains("selectedNodeInfo"))
                throw new Exception("'selectedNodeInfo'");
            params["selectedNodeInfo"] = uescape(params["selectedNodeInfo"]);
            if (params.contains("database_name"))
                params["database_name"] = uescape(params["database_name"]);
            params["server_cursor"] = params.contains("server_cursor") ? params["server_cursor"] : Value(false);
            return new Response(renderTemplate("sqleditor/index.html", tv("title", uescape(params["title"]),
                    "params", params.toJsonSpaced(), "csp_nonce", reqctx().cspNonce)), 200);
        }
        params["error"] = Value("The server was not found.");
        return new Response(renderTemplate("sqleditor/index.html", tv("title", Value(null), "params", params.toJsonSpaced(),
                "csp_nonce", reqctx().cspNonce)), 200);
    }

    private static Response initializeSqleditor(Dict a)
    {
        bool connect = true;
        Value data = Value.newDict();
        if (request().text.length)
            data = parseJson(request().text);
        if (request().args.has("recreate") && request().args.get("recreate") == "1")
            connect = false;
        auto kwargs = new Dict;
        kwargs["user"] = data.get("user");
        kwargs["role"] = data.get("role");
        kwargs["password"] = data.get("password");
        auto did = a.has("did") ? a["did"] : Value(null);
        if (!data.contains("dbname"))
            throw new Exception("'dbname'");
        auto dbnameV = data["dbname"];
        auto r = initSqleditor(a["trans_id"].toString, connect, a["sgid"], a["sid"], did,
                dbnameV.isNone ? null : dbnameV.toString, kwargs);
        if (r.isError)
            return r.errmsg;
        return jsonData(Value.dictOf("connId", r.connId, "serverVersion", r.version_));
    }

    private static Response updateSqleditorConnection(Dict a)
    {
        auto data = parseJson(request().text);
        auto transId = a["trans_id"].integer;
        auto txn = findTxn(transId);
        if (txn is null)
            return jsonData(Value.dictOf("status", true));
        bool connect = true;
        if (request().args.has("recreate") && request().args.get("recreate") == "1")
            connect = false;
        auto info = checkTransactionStatus(transId);
        auto newTransId = randomConnId();
        auto kwargs = new Dict;
        kwargs["user"] = data["user"];
        kwargs["role"] = data.get("role");
        kwargs["password"] = data.get("password");
        kwargs["auto_commit"] = Value(info.trans.autoCommit);
        kwargs["auto_rollback"] = Value(info.trans.autoRollback);
        auto r = initSqleditor(newTransId, connect, a["sgid"], a["sid"], a["did"], data["database_name"].toString, kwargs);
        if (r.isError)
            return r.errmsg;
        try
        {
            auto newInfo = checkTransactionStatus(to!long(newTransId));
            foreach (k; ["primary_keys", "columns_info", "client_primary_key"])
                newInfo.txn.sess[k] = info.txn.sess.get(k, Value(null));
            closeSqleditorSession(transId);
            dropTxn(transId);
        }
        catch (Exception e)
            logError(e.msg);
        return jsonData(Value.dictOf("connId", r.connId, "serverVersion", r.version_, "trans_id", newTransId));
    }

    private static Response closeView(Dict a)
    {
        auto transId = a["trans_id"].integer;
        autoCompleteObjects.remove(transId);
        if (findTxn(transId) is null)
            return jsonData(Value.dictOf("status", true));
        try
        {
            closeSqleditorSession(transId);
            dropTxn(transId);
        }
        catch (Exception e)
        {
            logError(e.msg);
            return internalServerError(e.msg);
        }
        return jsonData(Value.dictOf("status", true));
    }

    private static Response validateFilter(Dict a)
    {
        auto filterData = dataOrArgs();
        try
        {
            auto f = new BareFilter(a["sid"], a["did"], a["obj_id"]);
            if (!filterData.contains("filter_sql"))
                throw new Exception("'filter_sql'");
            auto fs = filterData["filter_sql"];
            auto r = f.validateFilter(fs.isString ? fs.str : null);
            if (!r.ok)
                return internalServerError(r.error);
            return jsonData(Value.dictOf("status", r.ok, "result", r.value));
        }
        catch (ObjectGone e)
            throw e;
        catch (Exception e)
        {
            logError(e.msg);
            return internalServerError(e.msg);
        }
    }

    // ---------------------------------------------------------------- query execution

    private static Response startViewData(Dict a)
    {
        auto transId = a["trans_id"].integer;
        Value limit = Value(-1);
        auto info = checkTransactionStatus(transId);
        if (info.errorMsg == ERROR_MSG_TRANS_ID_NOT_FOUND)
            return transNotFound();
        if (!info.status && info.errorResponse !is null)
            return info.errorResponse;
        auto trans = info.trans;
        auto conn = info.conn;
        bool connect = connectArg();
        Connection defaultConn;
        try
        {
            defaultConn = getDriver().connectionManager(trans.sid.integer).connection(trans.dbname.length ? trans.dbname : null,
                    null, true, trans.did);
        }
        catch (ConnectionLost e)
            throw e;
        catch (SSHTunnelConnectionLost e)
            throw e;
        catch (Exception e)
        {
            logError(e.msg);
            return internalServerError(e.msg);
        }
        bool status = info.status;
        Value result = Value(null);
        string sql;
        bool filterApplied, canEdit, canFilter;
        if (!conn.connected() || !defaultConn.connected())
        {
            if (connect)
            {
                auto chk = queryToolConnectionCheck(transId);
                if (chk.response !is null)
                    return chk.response;
                status = chk.status;
                info.errorMsg = chk.errmsg;
                if (chk.conn !is null)
                {
                    conn = chk.conn;
                    info.trans = chk.trans;
                    info.txn = chk.txn;
                    trans = chk.trans;
                }
            }
            auto r = defaultConn.connect();
            if (!r.ok)
                return serviceUnavailable(gettext("Connection to the server has been lost."), "CONNECTION_LOST");
        }
        if (status && conn !is null && trans !is null && info.txn !is null)
        {
            auto grid = cast(GridCommand) trans;
            trans.updateFetchedRowCnt(0);
            sql = trans.getSql(defaultConn);
            string pkn;
            auto primaryKeys = trans.getPrimaryKeys(pkn, defaultConn);
            info.txn.persist(trans);
            bool hasOids;
            if (trans.objectType == "table")
                hasOids = trans.hasOids(defaultConn);
            filterApplied = trans.isFilterApplied();
            limit = grid !is null ? grid.getLimit() : Value(-1);
            canEdit = trans.canEdit();
            canFilter = trans.canFilter();
            info.txn.sess["primary_keys"] = primaryKeys;
            info.txn.sess["has_oids"] = Value(hasOids);
            if (trans.serverCursor)
            {
                conn.releaseAsyncCursor();
                conn.executeVoid("BEGIN;");
            }
            auto r = conn.executeAsync(sql, Value(null), true, trans.serverCursor);
            status = r.ok;
            result = r.ok ? Value(null) : r.value;
        }
        else
        {
            status = false;
            result = Value(info.errorMsg);
            filterApplied = false;
            canEdit = false;
            canFilter = false;
            sql = null;
        }
        return jsonData(Value.dictOf("status", status, "result", result, "filter_applied", filterApplied, "limit", limit,
                "can_edit", canEdit, "can_filter", canFilter, "sql", sql is null ? Value(null) : Value(sql)));
    }

    private struct ConnCheck
    {
        bool status;
        string errmsg;
        Connection conn;
        BaseCommand trans;
        GridTxn txn;
        Response response;
    }

    /// `query_tool_connection_check(trans_id)`
    private static ConnCheck queryToolConnectionCheck(long transId)
    {
        ConnCheck c;
        auto txn = findTxn(transId);
        if (txn is null)
        {
            c.response = transNotFound();
            return c;
        }
        auto trans = txn.cmd;
        auto view = makeServerView();
        auto response = view.connect(trans.sgid, trans.sid, true);
        if (response.status == 428)
        {
            c.response = response;
            return c;
        }
        auto conn = commandConnection(trans, trans.connId);
        auto r = conn.connect();
        if (!r.ok)
        {
            logError(r.error);
            c.status = false;
            c.errmsg = r.error;
            return c;
        }
        c.status = true;
        c.conn = conn;
        c.trans = trans;
        c.txn = txn;
        return c;
    }

    private static Response startQueryTool(Dict a)
    {
        auto transId = a["trans_id"].integer;
        auto sqlParams = extractSqlFromNetworkParameters();
        bool connect = connectArg();
        string errmsg;
        if (checkAndUpgradeToQt(transId, connect, errmsg))
            return makeJsonResponse(0, Value(errmsg), Value(ERROR_MSG_FAIL_TO_PROMOTE_QT), Value(null), Value(null), 404);
        return executeQuery(sqlParams, transId, connect);
    }

    private static Value extractSqlFromNetworkParameters()
    {
        auto req = request();
        if (req.text.length)
        {
            auto p = parseJson(req.text);
            if (p.isString)
                return Value.dictOf("sql", p, "explain_plan", Value(null));
            return p;
        }
        if (!req.args.empty)
            return argsDict();
        return req.form.toDict;
    }

    /// `StartRunningQuery.execute`
    private static Response executeQuery(Value sql, long transId, bool connect)
    {
        auto txn = findTxn(transId);
        if (txn is null)
            return transNotFound();
        txn.sess.remove("primary_keys");
        txn.sess.remove("oids");
        auto trans = cloneCommand(txn.cmd);
        bool canEdit, canFilter;
        Value notifies = Value(null);
        long status = -1;
        Value result = Value(null);
        trans.updateFetchedRowCnt(0);
        string connectionId = trans.connId !is null ? trans.connId : randomConnId();
        Connection conn;
        ServerManager manager;
        try
        {
            manager = getDriver().connectionManager(trans.sid.integer);
            conn = manager.connection(trans.dbname.length ? trans.dbname : null, connectionId, false, trans.did, Value(null),
                    true, true);
        }
        catch (ConnectionLost e)
            throw e;
        catch (SSHTunnelConnectionLost e)
            throw e;
        catch (CryptKeyMissing e)
            throw e;
        catch (Exception e)
        {
            logError(e.msg);
            return internalServerError(e.msg);
        }
        if (connect && !conn.connected())
        {
            auto chk = queryToolConnectionCheck(transId);
            if (!chk.status && chk.response is null)
                result = Value(chk.errmsg);
            if (chk.response !is null)
                return chk.response;
        }
        string effectiveSql = applyExplainPlanWrapperIfNeeded(manager, sql);
        // __execute_query
        if (auto qt = cast(QueryToolCommand) trans)
            qt.setConnectionId(connectionId);
        txn.persist(trans);
        if (trans.serverCursor && effectiveSql != "COMMIT;" && effectiveSql != "ROLLBACK;")
            conn.releaseAsyncCursor();
        bool beginRequired = (trans.serverCursor && trans.autoCommit)
            || (!trans.autoCommit && conn.transactionStatus() == cast(TxStatus) TX_STATUS_IDLE && isBeginRequired(effectiveSql));
        if (beginRequired)
            conn.executeVoid("BEGIN;");
        bool rollbackReq = conn.transactionStatus() == cast(TxStatus) TX_STATUS_INERROR && trans.autoRollback;
        txn.running = true;
        bool serverCursorCommit = trans.serverCursor && (effectiveSql == "COMMIT;" || effectiveSql == "ROLLBACK;");
        if (serverCursorCommit)
        {
            // COMMIT/ROLLBACK of a server cursor run as plain statements
            try
                conn.executeVoid(effectiveSql);
            catch (Exception e)
                logError(e.msg);
            if (rollbackReq)
                conn.executeVoid("ROLLBACK;");
            txn.running = false;
        }
        else
        {
            auto r = conn.startAsync(effectiveSql, Value(null), true, (Res res) {
                if (rollbackReq)
                    conn.executeVoid("ROLLBACK;");
                txn.running = false;
            });
            if (!r.ok)
                txn.running = false;
        }
        txn.persist(trans);
        canEdit = trans.canEdit();
        canFilter = trans.canFilter();
        notifies = conn.getNotifies();
        return jsonData(Value.dictOf("status", status, "result", result, "can_edit", canEdit, "can_filter", canFilter,
                "notifies", notifies));
    }

    private static string applyExplainPlanWrapperIfNeeded(ServerManager manager, Value sql)
    {
        if (sql.contains("explain_plan") && sql["explain_plan"].truthy)
        {
            auto ep = sql["explain_plan"];
            auto ver = manager.version_;
            Value[string] vars;
            vars["sql"] = sql["sql"];
            foreach (k, v; ep.dict)
                vars[k] = v;
            return renderTemplate("sqleditor/sql/#" ~ to!string(ver) ~ "#/explain_plan.sql", vars);
        }
        return sql["sql"].toString;
    }

    private static string pyUnicodeEscape(string s)
    {
        import std.format : format;
        string r;
        foreach (dchar c; s)
        {
            if (c == '\\')
                r ~= "\\\\";
            else if (c == '\t')
                r ~= "\\t";
            else if (c == '\n')
                r ~= "\\n";
            else if (c == '\r')
                r ~= "\\r";
            else if (c < 0x20 || c == 0x7f)
                r ~= format("\\x%02x", cast(uint) c);
            else if (c < 0x7f)
                r ~= to!string(c);
            else if (c <= 0xff)
                r ~= format("\\x%02x", cast(uint) c);
            else if (c <= 0xffff)
                r ~= format("\\u%04x", cast(uint) c);
            else
                r ~= format("\\U%08x", cast(uint) c);
        }
        return r;
    }

    private static string generateClientPrimaryKeyName(Value columnsInfo)
    {
        string tempKey = "__temp_PK";
        if (columnsInfo.isNone || columnsInfo.length == 0)
            return tempKey;
        immutable initialLen = tempKey.length;
        long suffix = 1;
        for (;;)
        {
            bool duplicate;
            foreach (col; columnsInfo.iterItems())
                if (col["name"] == Value(tempKey))
                {
                    duplicate = true;
                    break;
                }
            if (!duplicate)
                break;
            if (initialLen == tempKey.length)
            {
                tempKey ~= to!string(suffix);
                suffix++;
            }
            else
            {
                tempKey = tempKey[0 .. $ - 1] ~ to!string(suffix);
                suffix++;
            }
        }
        return tempKey;
    }

    /// `fetch_pg_types(columns_info, trans_obj)`
    private static Res fetchPgTypes(Value columns, BaseCommand trans)
    {
        auto manager = getDriver().connectionManager(trans.sid.integer);
        auto defaultConn = manager.connection(null, trans.connId, true, trans.did);
        if (!defaultConn.connected())
        {
            auto r = defaultConn.connect();
            if (!r.ok)
                return r;
        }
        string[] oids;
        foreach (k, col; columns.dict)
            oids ~= col["type_code"].toString;
        if (oids.length)
        {
            auto r = defaultConn.executeDict("SELECT oid, pg_catalog.format_type(oid, NULL) AS typname FROM "
                    ~ "pg_catalog.pg_type WHERE oid = ANY(ARRAY[" ~ oids.join(",") ~ "]::oid[]) ORDER BY oid;");
            if (!r.ok)
                return r;
            return Res(true, r.value["rows"]);
        }
        return Res(true, Value.newList());
    }

    private static Response poll(Dict a)
    {
        auto transId = a["trans_id"].integer;
        Value result = Value(null);
        long rowsAffected;
        long rowsFetchedFrom, rowsFetchedTo;
        Value columns = Value.newDict();
        Value columnsInfo = Value(null);
        Value primaryKeys = Value(null);
        Value types = Value.newDict();
        Value clientPrimaryKey = Value(null);
        bool hasOids;
        Value oids = Value(null);
        Value additionalMessages = Value(null);
        Value notifies = Value(null);
        auto dataObj = Value.newDict();
        auto perPage = sqlPref("data_result_rows_per_page").integer;
        auto info = checkTransactionStatus(transId);
        if (info.errorResponse !is null)
            return info.errorResponse;
        if (info.errorMsg == ERROR_MSG_TRANS_ID_NOT_FOUND)
            return transNotFound();
        auto conn = info.conn;
        auto trans = info.trans;
        auto sess = info.txn.sess;
        bool isThreadAlive = info.txn.running;
        if (cast(QueryToolCommand) trans)
        {
            auto ts = conn.transactionStatus();
            if (ts == cast(TxStatus) TX_STATUS_INERROR && trans.autoRollback)
                conn.executeVoid("ROLLBACK;");
        }
        string statusStr;
        if (isThreadAlive)
        {
            statusStr = "Busy";
            auto messages = conn.messages();
            if (messages.length)
                result = Value(messages.join(""));
        }
        else if (info.status && conn !is null)
        {
            auto p = conn.poll(true, true);
            if (!p.ok)
            {
                string errText = p.error;
                if (!conn.connected())
                    return serviceUnavailable(gettext("Connection to the server has been lost."), "CONNECTION_LOST");
                auto messages = conn.messages();
                if (messages.length)
                {
                    additionalMessages = Value(messages.join(""));
                    errText = additionalMessages.toString ~ "\n" ~ gettext("******* Error *******") ~ "\n\n" ~ errText;
                }
                auto txStatus = conn.connected() ? cast(long) conn.transactionStatus() : 0;
                auto queryLen = conn.hasAsyncCursor && conn.asyncQuery.startsWith("EXPLAIN") ? cast(long) conn.asyncQuery.length : 0;
                return internalServerError(errText, Value.dictOf("transaction_status", txStatus, "explain_query_length", queryLen));
            }
            else if (p.status == ASYNC_OK)
            {
                statusStr = "Success";
                rowsAffected = conn.rowsAffected();
                auto fetched = conn.asyncFetchmany(trans.serverCursor ? perPage + 1 : perPage);
                bool st = fetched.ok;
                result = fetched.value;
                auto messages = conn.messages();
                if (messages.length)
                    additionalMessages = Value(messages.join(""));
                notifies = conn.getNotifies();
                if (st)
                {
                    if (sess.has("primary_keys"))
                        primaryKeys = sess["primary_keys"];
                    columnsInfo = conn.getColumnInfo();
                    clientPrimaryKey = Value(generateClientPrimaryKeyName(columnsInfo));
                    sess["client_primary_key"] = clientPrimaryKey;
                    if (auto qt = cast(QueryToolCommand) trans)
                    {
                        if (qt.checkUpdatableResultsPkeysOids())
                        {
                            string pkn;
                            auto pk = qt.getPrimaryKeys(pkn);
                            sess["has_oids"] = Value(qt.hasOids());
                            if (!pk.isNone)
                                sess["primary_keys"] = pk;
                            primaryKeys = sess.get("primary_keys", primaryKeys);
                            info.txn.persist(trans);
                        }
                    }
                    if (sess.has("has_oids"))
                    {
                        hasOids = sess["has_oids"].truthy;
                        if (hasOids)
                            oids = Value.dictOf("oid", "oid");
                    }
                    if (!columnsInfo.isNone)
                    {
                        if (trans.hasObjId && trans.canEdit())
                            columns = trans.getColumnsTypes(conn);
                        else
                            foreach (col; columnsInfo.iterItems())
                                columns[col["name"].toString] = Value.dictOf("type_code", col["type_code"], "type_name",
                                        Value(null), "internal_size", col["internal_size"], "display_size", col["display_size"]);
                    }
                    if (columns.truthy)
                    {
                        auto tr = fetchPgTypes(columns, trans);
                        if (!tr.ok)
                            return internalServerError(tr.error);
                        types = tr.value;
                        foreach (colName, colInfo; columns.dict)
                        {
                            foreach (colType; types.iterItems())
                                if (colType["oid"] == colInfo["type_code"])
                                    colInfo["type_name"] = colType["typname"];
                            colInfo["pgadmin_alias"] = Value(pyUnicodeEscape(replaceAll(colName, regex("[%()]+"), "|")));
                        }
                        sess["columns_info"] = columns;
                    }
                    if (result.truthy && rowsAffected > -1)
                    {
                        long resLen = result.length;
                        if (resLen > 0)
                        {
                            rowsFetchedFrom = trans.getFetchedRowCnt();
                            trans.updateFetchedRowCnt(rowsFetchedFrom + resLen);
                            rowsFetchedFrom += 1;
                            rowsFetchedTo = trans.getFetchedRowCnt();
                            info.txn.persist(trans);
                        }
                    }
                }
                if (result.isNone)
                {
                    auto sm = conn.statusMessage();
                    result = Value(sm);
                    if (additionalMessages.isNone)
                        {}
                    else
                        result = Value(additionalMessages.toString ~ sm);
                }
            }
            else
            {
                statusStr = "Busy";
                auto messages = conn.messages();
                if (messages.length)
                    result = Value(messages.join(""));
            }
        }
        else
        {
            statusStr = "NotConnected";
            result = Value(info.errorMsg);
        }
        long transactionStatus = conn !is null ? cast(long) conn.transactionStatus() : 0;
        dataObj["db_name"] = conn !is null ? Value(conn.db) : Value(null);
        dataObj["db_id"] = trans !is null ? trans.did : Value(0);
        long pageSize = rowsFetchedTo - rowsFetchedFrom + 1;
        long nextPage;
        if (trans.serverCursor && result.isList && result.length > 0 && result.length > perPage)
        {
            result.list.items = result.list.items[0 .. $ - 1];
            nextPage = 1;
            rowsFetchedTo--;
        }
        auto pagination = Value.dictOf("page_size", pageSize, "page_count",
                cast(long) ceil(cast(double) conn.totalRows() / pageSize), "page_no",
                cast(long) floor(cast(double)(rowsFetchedFrom - 1) / pageSize) + 1, "rows_from", rowsFetchedFrom, "rows_to",
                rowsFetchedTo, "next_page", nextPage);
        return jsonData(Value.dictOf("status", statusStr, "result", result, "rows_affected", rowsAffected,
                "rows_fetched_from", rowsFetchedFrom, "rows_fetched_to", rowsFetchedTo, "additional_messages",
                additionalMessages, "notifies", notifies, "colinfo", columnsInfo, "primary_keys", primaryKeys, "types", types,
                "client_primary_key", clientPrimaryKey, "has_oids", hasOids, "oids", oids, "transaction_status",
                transactionStatus, "data_obj", dataObj, "pagination", pagination, "server_cursor", trans.serverCursor));
    }

    private static Response fetchWindow(Dict a)
    {
        auto transId = a["trans_id"].integer;
        long fromRownum = a["from_rownum"].integer, toRownum = a["to_rownum"].integer;
        Value result = Value(null);
        long rowsFetchedFrom, rowsFetchedTo;
        auto info = checkTransactionStatus(transId);
        if (info.errorMsg == ERROR_MSG_TRANS_ID_NOT_FOUND)
            return transNotFound();
        string statusStr;
        auto conn = info.conn;
        auto trans = info.trans;
        if (info.status && conn !is null && info.txn !is null)
        {
            auto r = conn.asyncFetchmany(-2, fromRownum - 1, trans.serverCursor ? toRownum : toRownum - 1);
            result = r.value;
            if (!r.ok)
                statusStr = "Error";
            else
            {
                statusStr = "Success";
                long resLen = result.isList ? result.length : 0;
                if (resLen)
                {
                    rowsFetchedFrom = fromRownum;
                    rowsFetchedTo = rowsFetchedFrom + resLen - 1;
                    info.txn.persist(trans);
                }
            }
        }
        else
        {
            statusStr = "NotConnected";
            result = Value(info.errorMsg);
        }
        long pageSize = toRownum - fromRownum + 1;
        long nextPage;
        if (trans.serverCursor && result.length > 0 && result.length > pageSize)
        {
            result.list.items = result.list.items[0 .. $ - 1];
            nextPage = 1;
            rowsFetchedTo--;
        }
        auto pagination = Value.dictOf("page_size", pageSize, "page_count",
                cast(long) ceil(cast(double) conn.totalRows() / pageSize), "page_no",
                cast(long) floor(cast(double)(rowsFetchedFrom - 1) / pageSize) + 1, "rows_from", rowsFetchedFrom, "rows_to",
                rowsFetchedTo, "next_page", nextPage);
        return jsonData(Value.dictOf("status", statusStr, "result", result, "pagination", pagination, "row_count",
                conn.rowCount));
    }

    private static Response fetchAllFromStart(Dict a)
    {
        auto transId = a["trans_id"].integer;
        auto info = checkTransactionStatus(transId);
        if (info.errorMsg == ERROR_MSG_TRANS_ID_NOT_FOUND)
            return transNotFound();
        string statusStr;
        Value result;
        auto conn = info.conn;
        if (info.status && conn !is null && info.txn !is null)
        {
            conn.resetCursorAt(0);
            auto r = conn.asyncFetchmany(a["limit"].integer);
            statusStr = r.ok ? "Success" : "Error";
            result = r.value;
            conn.resetCursorAt(info.trans.getFetchedRowCnt());
        }
        else
        {
            statusStr = "NotConnected";
            result = Value(info.errorMsg);
        }
        return jsonData(Value.dictOf("status", statusStr, "result", result));
    }

    private static Response save(Dict a)
    {
        auto transId = a["trans_id"].integer;
        auto changedData = dataOrArgs();
        bool connect = connectArg();
        auto info = checkTransactionStatus(transId);
        if (info.errorMsg == ERROR_MSG_TRANS_ID_NOT_FOUND)
            return transNotFound();
        bool status;
        Value res;
        Value queryResults = Value(null), rowid = Value(null);
        auto conn = info.conn;
        if (info.status && conn !is null && info.trans !is null && info.txn !is null)
        {
            auto sess = info.txn.sess;
            if ((!sess.has("primary_keys") || sess["primary_keys"].length <= 0 || changedData.length <= 0)
                    && !sess.has("has_oids"))
                return jsonData(Value.dictOf("status", false, "result",
                        gettext("No primary key found for this object, so unable to save records.")));
            if (connect)
            {
                auto chk = queryToolConnectionCheck(transId);
                if (chk.response !is null)
                    return chk.response;
            }
            // _check_and_connect
            auto mgr = getDriver().connectionManager(info.trans.sid.integer);
            auto saveConn = mgr.connection(null, info.trans.connId, true, info.trans.did);
            if (!saveConn.connected())
            {
                auto r = saveConn.connect();
                if (!r.ok)
                    return serviceUnavailable(gettext("Connection to the server has been lost."), "CONNECTION_LOST");
            }
            conn = saveConn;
            auto sr = info.trans.save(changedData, sess.get("columns_info"), sess.get("client_primary_key").toString, conn);
            status = sr.status;
            res = sr.res;
            queryResults = sr.queryResults;
            rowid = sr.rowid;
        }
        else
        {
            status = false;
            res = Value(info.errorMsg);
        }
        return jsonData(Value.dictOf("status", status, "result", res, "query_results", queryResults, "_rowid", rowid,
                "transaction_status", cast(long) conn.transactionStatus()));
    }

    private static Response appendFilter(Dict a, bool inclusive)
    {
        auto transId = a["trans_id"].integer;
        auto filterData = dataOrArgs();
        auto info = checkTransactionStatus(transId);
        if (info.errorMsg == ERROR_MSG_TRANS_ID_NOT_FOUND)
            return transNotFound();
        bool status = info.status;
        Value res = Value(null);
        if (info.status && info.conn !is null && info.trans !is null && info.txn !is null)
        {
            string filterSql = "";
            foreach (columnName, columnValue; filterData.dict)
            {
                if (columnValue.isNone)
                    filterSql = qtIdentStr(columnName) ~ (inclusive ? " IS NULL " : " IS NOT NULL ");
                else
                    filterSql = qtIdentStr(columnName) ~ (inclusive ? " = " : " IS DISTINCT FROM ") ~ qtLiteral(columnValue);
            }
            (cast(GridCommand) info.trans).appendFilter(filterSql);
            info.txn.persist(info.trans);
        }
        else
        {
            status = false;
            res = Value(info.errorMsg);
        }
        return jsonData(Value.dictOf("status", status, "result", res));
    }

    private static Response removeFilter(Dict a)
    {
        auto info = checkTransactionStatus(a["trans_id"].integer);
        if (info.errorMsg == ERROR_MSG_TRANS_ID_NOT_FOUND)
            return transNotFound();
        bool status = info.status;
        Value res = Value(null);
        if (info.status && info.conn !is null && info.trans !is null && info.txn !is null)
        {
            (cast(GridCommand) info.trans).removeFilter();
            info.txn.persist(info.trans);
        }
        else
        {
            status = false;
            res = Value(info.errorMsg);
        }
        return jsonData(Value.dictOf("status", status, "result", res));
    }

    private static Response setLimit(Dict a)
    {
        auto limit = dataOrArgs();
        auto info = checkTransactionStatus(a["trans_id"].integer);
        if (info.errorMsg == ERROR_MSG_TRANS_ID_NOT_FOUND)
            return transNotFound();
        bool status = info.status;
        Value res = Value(null);
        if (info.status && info.conn !is null && info.trans !is null && info.txn !is null)
        {
            (cast(GridCommand) info.trans).setLimit(limit);
            info.txn.persist(info.trans);
        }
        else
        {
            status = false;
            res = Value(info.errorMsg);
        }
        return jsonData(Value.dictOf("status", status, "result", res));
    }

    private static Response cancelTransaction(Dict a)
    {
        auto transId = a["trans_id"].integer;
        auto txn = findTxn(transId);
        if (txn is null)
            return transNotFound();
        auto trans = txn.cmd;
        bool status;
        Value result;
        Connection conn;
        ServerManager manager;
        try
        {
            manager = getDriver().connectionManager(trans.sid.integer);
            conn = manager.connection(trans.dbname.length ? trans.dbname : null, null, true,
                    trans.dbname.length ? Value(null) : trans.did);
        }
        catch (Exception e)
            return internalServerError(e.msg);
        bool deleteConnection;
        if (!conn.connected())
        {
            auto r = conn.connect();
            if (!r.ok)
                return internalServerError(r.error);
            deleteConnection = true;
        }
        // _check_and_cancel_transaction
        if (conn.connected())
        {
            auto r = conn.cancelTransaction(trans.connId, trans.did);
            status = r.ok;
            result = r.value;
            if (deleteConnection)
                manager.release(null, null, trans.did);
        }
        else
        {
            status = false;
            result = Value(SERVER_CONNECTION_CLOSED);
        }
        if (!status)
            return internalServerError(result.isNone ? "" : result.toString);
        return jsonData(Value.dictOf("status", status, "result", result));
    }

    private static Response getObjectName(Dict a)
    {
        auto info = checkTransactionStatus(a["trans_id"].integer);
        if (info.errorMsg == ERROR_MSG_TRANS_ID_NOT_FOUND)
            return transNotFound();
        bool status = info.status;
        Value res;
        if (info.status && info.conn !is null && info.trans !is null && info.txn !is null)
        {
            if (info.trans.objectName is null)
                throw new Exception("'QueryToolCommand' object has no attribute 'object_name'");
            res = Value(info.trans.objectName);
        }
        else
        {
            status = false;
            res = Value(info.errorMsg);
        }
        return jsonData(Value.dictOf("status", status, "result", res));
    }

    private static Response setPrefOptions(Dict a, string operation)
    {
        auto transId = a["trans_id"].integer;
        auto data = dataOrArgs();
        bool connect = connectArg();
        string errmsg;
        if (checkAndUpgradeToQt(transId, connect, errmsg))
            return makeJsonResponse(0, Value(errmsg), Value(ERROR_MSG_FAIL_TO_PROMOTE_QT), Value(null), Value(null), 404);
        auto info = checkTransactionStatus(transId);
        if (info.errorMsg == ERROR_MSG_TRANS_ID_NOT_FOUND)
            return transNotFound();
        bool status = info.status;
        Value res = Value(null);
        if (info.status && info.conn !is null && info.trans !is null && info.txn !is null)
        {
            switch (operation)
            {
            case "auto_commit": info.trans.setAutoCommit(data); break;
            case "auto_rollback": info.trans.setAutoRollback(data); break;
            default: info.trans.setServerCursor(data); break;
            }
            info.txn.persist(info.trans);
        }
        else
        {
            status = false;
            res = Value(info.errorMsg);
        }
        return jsonData(Value.dictOf("status", status, "result", res));
    }

    private static Response autoComplete(Dict a)
    {
        auto transId = a["trans_id"].integer;
        auto data = dataOrArgs();
        bool connect = connectArg();
        string errmsg;
        if (checkAndUpgradeToQt(transId, connect, errmsg))
            return makeJsonResponse(0, Value(errmsg), Value(ERROR_MSG_FAIL_TO_PROMOTE_QT), Value(null), Value(null), 404);
        auto info = checkTransactionStatus(transId, true);
        if (info.errorMsg == ERROR_MSG_TRANS_ID_NOT_FOUND)
            return transNotFound();
        bool status = info.status;
        Value res = Value(null);
        if (info.status && info.conn !is null && info.trans !is null && info.txn !is null)
        {
            string fullSql = "";
            string textBeforeCursor = "";
            if (data.isList && data.list.items.length >= 2)
            {
                fullSql = data.list.items[0].toString;
                textBeforeCursor = data.list.items[1].toString;
            }
            else if (data.isDict)
            {
                auto d = data.dict;
                if (d.has("0")) fullSql = d.get("0").toString;
                if (d.has("1")) textBeforeCursor = d.get("1").toString;
                if (d.has("sql")) fullSql = d.get("sql").toString;
            }

            if (transId !in autoCompleteObjects)
                autoCompleteObjects[transId] = new SQLAutoComplete(info.trans.sid.integer, info.trans.did.integer, info.conn);
            auto ac = autoCompleteObjects[transId];
            res = ac.getCompletions(fullSql, textBeforeCursor);
        }
        else
        {
            status = false;
            res = Value(info.errorMsg);
        }
        return jsonData(Value.dictOf("status", status, "result", res));
    }

    private static Response queryToolStatus(Dict a)
    {
        auto info = checkTransactionStatus(a["trans_id"].integer);
        if (!info.status && info.errorMsg.length)
            return internalServerError(info.errorMsg);
        if (info.conn !is null && info.trans !is null && info.txn !is null)
        {
            auto st = info.conn.transactionStatus();
            static immutable string[] msgs = [
                "The session is idle and there is no current transaction.", "A command is currently in progress.",
                "The session is idle in a valid transaction block.",
                "The session is idle in a failed transaction block.", "The connection with the server is bad."];
            auto notifies = info.conn.getNotifies();
            return jsonData(Value.dictOf("status", cast(long) st, "message", gettext(msgs[min(cast(size_t) st, msgs.length - 1)]),
                    "notifies", notifies));
        }
        return internalServerError(gettext("Transaction status check failed."));
    }

    private static Value requestValues()
    {
        auto req = request();
        auto d = Value.newDict();
        foreach (k; req.args.keys)
            d[k] = Value(req.args.get(k));
        foreach (k; req.form.keys)
            if (!d.contains(k))
                d[k] = Value(req.form.get(k));
        return d;
    }

    private static Response startQueryDownload(Dict a)
    {
        auto transId = a["trans_id"].integer;
        auto info = checkTransactionStatus(transId);
        if (!info.status || info.conn is null || info.trans is null || info.txn is null)
            return internalServerError(gettext("Transaction status check failed."));
        auto conn = info.conn;
        auto trans = info.trans;
        auto data = requestValues();
        if (!data.truthy)
        {
            auto j = request().text.length ? tryParseJson(request().text, Value(null)) : Value(null);
            if (j.isNone || !j.isDict)
                return makeJsonResponse(0, Value(gettext("Could not find the required parameter (query).")), Value(""),
                        Value(null), Value(null), 410);
            data = j;
        }
        try
        {
            Value sql = Value(null);
            auto committed = data.get("query_commited", Value(false));
            foreach (key, value; data.dict)
            {
                if (key == "query")
                    sql = value;
                if (key == "query_commited")
                    committed = value.isString ? Value(["true", "1"].canFind(value.str.toLower)) : value;
            }
            if (!sql.truthy)
            {
                auto gs = trans.getSql(conn);
                sql = gs is null ? Value(null) : Value(gs);
            }
            if (sql.truthy && committed.truthy)
            {
                if (trans.serverCursor)
                {
                    conn.releaseAsyncCursor();
                    conn.executeVoid("BEGIN;");
                }
                conn.executeAsync(sql.toString, Value(null), true, trans.serverCursor);
            }
            // execute_on_server_as_csv
            string failure;
            if (!conn.hasAsyncCursor || conn.asyncCursorClosed)
                failure = Connection.CURSOR_NOT_FOUND;
            else if (conn.asyncRunning)
                failure = Connection.ASYNC_BUSY;
            else if (conn.asyncResult is null || !conn.asyncResult.hasDescription)
                failure = gettext("The query executed did not return any data.");
            if (trans.serverCursor && committed.truthy)
                conn.executeVoid("COMMIT;");
            if (failure !is null)
                throw new Exception("not enough values to unpack (expected 3, got 2)");
            auto prefs = sqleditorPrefs();
            CsvDialect d;
            d.quoting = sqlPref("csv_quoting").toString;
            d.quoteChar = sqlPref("csv_quote_char").toString;
            d.delimiter = sqlPref("csv_field_separator").toString;
            d.replaceNullsWith = sqlPref("csv_replace_nulls_with");
            auto rs = conn.asyncResult;
            string text;
            if (rs.rows.length == 0)
                text = gettext("The query executed did not return any data.");
            else
            {
                string[] header;
                uint[] types;
                foreach (c; rs.columns)
                {
                    header ~= c.name;
                    types ~= c.typeCode;
                }
                text = csvText(d, header, types, rs.rows, true);
            }
            conn.resetCursorAt(trans.getFetchedRowCnt());
            auto r = new Response(text, 200, d.delimiter == "," ? "text/csv" : "text/plain");
            import std.datetime : Clock;
            string extn = d.delimiter == "," ? "csv" : "txt";
            string filename = data.get("filename").isString && data["filename"].str != ""
                ? data["filename"].str : to!string(Clock.currTime().toUnixTime()) ~ "." ~ extn;
            foreach (char c; filename)
                if (cast(ubyte) c > 127)
                {
                    filename = "download.csv";
                    break;
                }
            r.headers ~= ["Content-Disposition", "attachment;filename=" ~ filename];
            return r;
        }
        catch (ConnectionLost e)
            throw e;
        catch (SSHTunnelConnectionLost e)
            throw e;
        catch (Exception e)
        {
            logError(e.msg);
            return internalServerError("Error: " ~ e.msg);
        }
    }

    private static Response downloadBinaryData(Dict a)
    {
        auto transId = a["trans_id"].integer;
        auto info = checkTransactionStatus(transId);
        if (info.errorResponse !is null)
            return info.errorResponse;
        if (info.errorMsg == ERROR_MSG_TRANS_ID_NOT_FOUND)
            return transNotFound();
        if (!info.status || info.conn is null || info.trans is null || info.txn is null)
            return internalServerError(gettext("Transaction status check failed."));
        auto conn = info.conn;
        if (!conn.hasAsyncCursor || conn.asyncCursorClosed)
            return internalServerError(gettext("No active result cursor."));
        auto data = requestValues();
        if (!data.truthy)
        {
            auto j = request().text.length ? tryParseJson(request().text, Value(null)) : Value(null);
            if (j.isNone || !j.isDict)
                return makeJsonResponse(0, Value(gettext("Could not find the required parameters (rowpos, colpos).")),
                        Value(""), Value(null), Value(null), 410);
            data = j;
        }
        long rowPos, colPos;
        if (!data.contains("rowpos"))
            throw new Exception("'rowpos'");
        if (!data.contains("colpos"))
            throw new Exception("'colpos'");
        try
        {
            rowPos = pyIntStrict(data["rowpos"]);
            colPos = pyIntStrict(data["colpos"]);
            if (rowPos < 0 || colPos < 0)
                throw new Exception("ValueError");
        }
        catch (Exception e)
            return internalServerError("a bytes-like object is required, not 'Response'");
        auto rs = conn.asyncResult;
        if (rs is null || rowPos >= rs.rows.length || colPos >= rs.columns.length)
            return internalServerError("a bytes-like object is required, not 'Response'");
        auto cell = rs.rows[rowPos][colPos];
        if (cell.isNone)
            return badRequest(gettext("The selected cell contains NULL."));
        auto raw = rs.rawCells.get(cast(size_t) rowPos * rs.columns.length + colPos, cell.toString);
        string bytes;
        if (raw.length >= 2 && raw[0 .. 2] == "\\x")
        {
            import std.conv : parse;
            for (size_t i = 2; i + 1 < raw.length; i += 2)
                bytes ~= cast(char) to!ubyte(raw[i .. i + 2], 16);
        }
        else
            bytes = raw;
        auto r = new Response(bytes, 200, "application/octet-stream");
        r.headers ~= ["Content-Disposition", "attachment; filename=binary_data"];
        return r;
    }

    // ------------------------------------------------------------ connection dialog data

    private void setupConnectionRoutes()
    {
        View dialog = loginRequired((Dict a) {
            try
            {
                auto driver = getDriver();
                auto groupData = new Dict;
                foreach (g; getServerGroupsForUser())
                    groupData[g["name"].str] = Value.newList();
                foreach (server; getUserServers("is_adhoc = 0"))
                {
                    auto manager = driver.connectionManager(server["id"].integer);
                    auto conn = manager.connection();
                    bool connected = conn.connected();
                    auto sg = getServerGroup(server["servergroup_id"]);
                    auto name = sg.isNone ? "" : sg["name"].str;
                    if (!groupData.has(name))
                        groupData[name] = Value.newList();
                    groupData[name].append(Value.dictOf("label", server["name"], "value", server["id"], "image",
                            serverIconAndBackground(connected, manager, server), "fgcolor", server["fgcolor"], "bgcolor",
                            server["bgcolor"], "host", server["host"], "port", server["port"], "service", server["service"],
                            "connection_params", convertConnectionParameter(server["connection_params"]),
                            "connected", connected));
                }
                return jsonData(Value.dictOf("status", true, "msg", "Success", "result",
                        Value.dictOf("server_list", Value(groupData))));
            }
            catch (ConnectionLost e)
                throw e;
            catch (SSHTunnelConnectionLost e)
                throw e;
            catch (CryptKeyMissing e)
                throw e;
            catch (Exception e)
            {
                logException(e);
                return jsonData(Value.dictOf("status", false, "msg", ERROR_FETCHING_DATA, "result",
                        Value.dictOf("server_list", Value.newList())));
            }
        });
        route("/new_connection_dialog/<int:sgid>/<int:sid>", "get_new_connection_data", ["GET"], dialog);
        route("/new_connection_dialog", "get_new_connection_servers", ["GET"], dialog);

        route("/get_server_connection/<int:sgid>/<int:sid>", "_check_server_connection_status", ["GET"],
                loginRequired((Dict a) {
            try
            {
                auto server = getServer(a["sid"].integer);
                if (server.isNone)
                    return makeJsonResponse(0, Value(gettext("Could not find the required server.")), Value(""), Value(null),
                            Value(null), 410);
                auto manager = getDriver().connectionManager(server["id"].integer);
                auto conn = manager.connection();
                return jsonData(Value.dictOf("status", true, "msg", "Success", "result",
                        Value.dictOf("server", conn.connected())));
            }
            catch (ConnectionLost e)
                throw e;
            catch (SSHTunnelConnectionLost e)
                throw e;
            catch (CryptKeyMissing e)
                throw e;
            catch (Exception e)
            {
                logException(e);
                return jsonData(Value.dictOf("status", false, "msg", ERROR_FETCHING_DATA, "result",
                        Value.dictOf("server", false)));
            }
        }));

        route("/new_connection_database/<int:sgid>/<int:sid>", "get_new_connection_database", ["GET"],
                loginRequired((Dict a) {
            try
            {
                Value[] databaseList;
                auto manager = getDriver().connectionManager(a["sid"].integer);
                auto conn = manager.connection();
                if (conn.connected())
                {
                    bool status = true;
                    auto templatePath = "databases/sql/#" ~ to!string(manager.version_) ~ "#";
                    auto restr = getDbDispRestriction(manager);
                    auto r = conn.executeDict(renderTemplate(templatePath ~ "/nodes.sql", tv("last_system_oid", 0,
                            "db_restrictions", restr.expr)), restr.params);
                    status = r.ok;
                    foreach (database; r.value["rows"].list.items)
                        databaseList ~= Value.dictOf("label", database["name"], "value", database["did"], "selected",
                                database["name"] == Value(manager.db));
                    return jsonData(Value.dictOf("status", status, "msg", "Success", "result",
                            Value.dictOf("data", Value(databaseList))));
                }
                return jsonData(Value.dictOf("status", false, "msg", SERVER_CONNECTION_CLOSED, "result",
                        Value.dictOf("database_list", Value.newList())));
            }
            catch (ConnectionLost e)
                throw e;
            catch (SSHTunnelConnectionLost e)
                throw e;
            catch (CryptKeyMissing e)
                throw e;
            catch (Exception e)
            {
                logException(e);
                return jsonData(Value.dictOf("status", false, "msg", ERROR_FETCHING_DATA, "result",
                        Value.dictOf("database_list", Value.newList())));
            }
        }));

        View roles(bool users) => loginRequired((Dict a) {
            try
            {
                auto manager = getDriver().connectionManager(a["sid"].integer);
                auto conn = manager.connection();
                Value[] list;
                if (conn.connected())
                {
                    auto sqlPath = "roles/sql/#" ~ to!string(manager.version_) ~ "#";
                    auto r = conn.execute2darray(renderTemplate(sqlPath ~ "/nodes.sql"));
                    foreach (row; r.value["rows"].list.items)
                    {
                        if (users)
                        {
                            if (row["rolcanlogin"].truthy)
                                list ~= Value.dictOf("value", row["rolname"], "label", row["rolname"], "selected",
                                        row["rolname"] == Value(manager.user));
                        }
                        else
                            list ~= Value.dictOf("value", row["rolname"], "label", row["rolname"]);
                    }
                    return jsonData(Value.dictOf("status", r.ok, "msg", "Success", "result", Value.dictOf("data", Value(list))));
                }
                return jsonData(Value.dictOf("status", false, "msg", SERVER_CONNECTION_CLOSED, "result",
                        Value.dictOf("user_list", Value.newList())));
            }
            catch (ConnectionLost e)
                throw e;
            catch (SSHTunnelConnectionLost e)
                throw e;
            catch (CryptKeyMissing e)
                throw e;
            catch (Exception e)
            {
                logException(e);
                return jsonData(Value.dictOf("status", false, "msg", "Unable to fetch data.", "result",
                        Value.dictOf("user_list", Value.newList())));
            }
        });
        route("/new_connection_user/<int:sgid>/<int:sid>", "get_new_connection_user", ["GET"], roles(true));
        route("/new_connection_role/<int:sgid>/<int:sid>", "get_new_connection_role", ["GET"], roles(false));

        route("/connect_server/<int:sid>", "connect_server", ["POST"], loginRequired((Dict a) {
            auto sid = a["sid"];
            auto server = getServer(sid.integer);
            if (server.isNone)
                return makeJsonResponse(0, Value(gettext("Could not find the required server.")), Value(""), Value(null),
                        Value(null), 410);
            auto manager = getDriver().connectionManager(sid.integer);
            auto conn = manager.connection();
            if (conn.connected())
            {
                cachePasswordFromRequest(manager);
                return makeJsonResponse(1, Value(""), Value(gettext("Server connected.")), Value(null), Value.newDict());
            }
            return makeServerView().connect(server["servergroup_id"], sid, false);
        }));
    }

    private static void cachePasswordFromRequest(ServerManager manager)
    {
        try
        {
            Value data;
            if (!request().form.empty)
                data = request().form.toDict;
            else if (request().text.length)
                data = parseJson(request().text);
            else
                return;
            auto password = data.get("password");
            if (!password.truthy)
                return;
            auto ck = getCryptKey();
            if (!ck.present)
                return;
            manager.updatePassword(encrypt(password.toString, ck.key));
            manager.updateSession();
        }
        catch (Exception e)
            logException(e);
    }

    // ------------------------------------------------------------ filter dialog, history, macros

    private void setupMiscRoutes()
    {
        route("/filter_dialog/<int:trans_id>", "get_filter_data", ["GET"], loginRequired((Dict a) {
            auto info = checkTransactionStatus(a["trans_id"].integer);
            if (info.errorMsg == ERROR_MSG_TRANS_ID_NOT_FOUND)
                return transNotFound();
            Value columnList = Value.newList();
            Value columns = Value(null), sql = Value(null);
            bool status = info.status;
            string msg;
            if (info.status && info.conn !is null && info.trans !is null && info.txn !is null)
            {
                msg = gettext("Success");
                auto grid = cast(GridCommand) info.trans;
                columns = grid !is null ? grid.getAllColumnsWithOrder() : Value(null);
                Value[] names;
                auto ci = info.txn.sess.get("columns_info");
                if (!ci.isDict)
                    throw new Exception("'NoneType' object has no attribute 'keys'");
                foreach (k, v; ci.dict)
                    names ~= Value(k);
                columnList = Value(names);
                auto f = grid !is null ? grid.getFilter() : null;
                sql = f is null ? Value(null) : Value(f);
            }
            else
            {
                status = false;
                msg = info.errorMsg;
            }
            return jsonData(Value.dictOf("status", status, "msg", msg, "result", Value.dictOf("data_sorting", columns,
                    "column_list", columnList, "sql", sql)));
        }));

        route("/filter_dialog/<int:trans_id>", "set_filter_data", ["PUT"], loginRequired((Dict a) {
            auto info = checkTransactionStatus(a["trans_id"].integer);
            auto data = dataOrArgs();
            if (info.errorMsg == ERROR_MSG_TRANS_ID_NOT_FOUND)
                return transNotFound();
            if (info.status && info.conn !is null && info.trans !is null && info.txn !is null)
            {
                auto grid = cast(GridCommand) info.trans;
                grid.setDataSorting(data, true);
                auto r = grid.setFilter(data.get("sql"));
                Value res = r.value;
                if (r.ok)
                {
                    info.txn.persist(info.trans);
                    res = Value(gettext("Data sorting object updated successfully"));
                }
                return jsonData(Value.dictOf("status", r.ok, "result", res));
            }
            return internalServerError(gettext("Failed to update the data on server."));
        }));

        route("/query_history/<int:trans_id>", "add_query_history", ["POST"], loginRequired((Dict a) {
            auto info = checkTransactionStatus(a["trans_id"].integer);
            if (info.trans is null)
                return jsonData(Value.dictOf("status", false));
            return queryHistorySave(currentUserId(), info.trans.sid, info.conn.db);
        }));
        route("/query_history/<int:trans_id>", "clear_query_history", ["DELETE"], loginRequired((Dict a) {
            auto info = checkTransactionStatus(a["trans_id"].integer);
            Value filterJson = Value(null);
            if (request().text.length)
                filterJson = tryParseJson(request().text, Value(null));
            if (info.trans is null)
                throw new Exception("'NoneType' object has no attribute 'sid'");
            queryHistoryClear(currentUserId(), info.trans.sid, info.conn.db, filterJson);
            return jsonData(Value.dictOf("status", true, "msg", "Success"));
        }));
        route("/query_history/<int:trans_id>", "get_query_history", ["GET"], loginRequired((Dict a) {
            auto info = checkTransactionStatus(a["trans_id"].integer);
            if (info.trans is null)
                throw new Exception("'NoneType' object has no attribute 'sid'");
            auto rows = db.query("SELECT query_info FROM query_history WHERE uid = ? AND sid = ? AND dbname = ?",
                    Value(currentUserId()), info.trans.sid, Value(info.conn.db));
            Value[] result;
            foreach (r; rows)
                result ~= r["query_info"];
            return jsonData(Value.dictOf("status", true, "msg", "", "result", Value(result)));
        }));

        route("/query_tool/download/<int:trans_id>", "query_tool_download", ["POST"],
                loginRequired((Dict a) => startQueryDownload(a)));
        route("/download_binary_data/<int:trans_id>", "download_binary_data", ["POST"],
                loginRequired((Dict a) => downloadBinaryData(a)));
        View llmStream = loginRequired((Dict a) {
            if (!isLlmEnabled())
                return makeJsonResponse(0, Value(gettext("AI features are not configured. Please configure an LLM provider in Preferences > AI.")),
                        Value(""), Value(null), Value(null), 200);
            return makeJsonResponse(0, Value(gettext("AI features are not available in this build.")), Value(""),
                    Value(null), Value(null), 200);
        });
        route("/nlq/chat/<int:trans_id>/stream", "nlq_chat_stream", ["POST"], llmStream, true);
        route("/explain/analyze/<int:trans_id>/stream", "explain_analyze_stream", ["POST"], llmStream, true);

        auto macrosView = loginRequired((Dict a) {
            checkTransactionStatus(a["trans_id"].integer);
            return getMacros(a.has("macro_id") ? a["macro_id"] : Value(null));
        });
        route("/get_macros/<int:trans_id>", "get_macros", ["GET"], macrosView);
        route("/get_macros/<int:macro_id>/<int:trans_id>", "get_macro", ["GET"], macrosView);
        route("/set_macros/<int:trans_id>", "set_macros", ["PUT"], loginRequired((Dict a) {
            checkTransactionStatus(a["trans_id"].integer);
            return setMacros();
        }));
        route("/get_user_macros", "get_user_macros", ["GET"], loginRequired((Dict a) => makeResponse(getUserMacros(), 200)));
    }

    private static ServerNode makeServerView()
    {
        return makeView!ServerNode();
    }
}
