/// The database driver layer: `Connection`, `ServerManager` and `Driver`
/// (`pgadmin/utils/driver/psycopg3/{connection,server_manager,__init__}.py`).
///
/// The API mirrors the Python one so the node modules port almost line by line: `execute_dict` and friends return a
/// status and a value (rows, or the error message), `ConnectionLost` is thrown when the connection is gone, and the
/// SQL template version is `manager.version`.
module pgadmin.db.driver;

import core.time : seconds;
import std.algorithm : canFind, startsWith, endsWith;
import std.array : appender, join, split;
import std.conv : to;
import std.format : format;
import std.random : uniform;
import std.string : strip, toLower, indexOf, replace;
import pgadmin.core.config;
import pgadmin.core.crypto;
import pgadmin.core.log;
import pgadmin.core.value;
import pgadmin.db.libpq;
import pgadmin.db.pgconn;
import pgadmin.db.quoting;
import pgadmin.model;
import pgadmin.utils.exception;
import pgadmin.utils.master_password;
import pgadmin.web.context;

/// psycopg's `ProgrammingError` raised by the client-side parameter binding.
class ProgrammingError : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line);
    }
}

/// `(status, value)` as the Python functions return it.
struct Res
{
    bool ok;
    Value value;

    /// The error message (when `!ok`).
    string error() => value.isNone ? "" : value.toString;
}

private Res okRes(Value v = Value(null)) => Res(true, v);
private Res errRes(string msg) => Res(false, Value(msg));

enum CONN_STRING = "CONN:";
enum DB_STRING = "DB:";

// ------------------------------------------------------------ server types

/// `ServerType`: how a server is recognised and where its utilities live.
final class ServerType : Obj
{
    string stype;
    string desc;
    int priority;

    this(string stype, string desc, int priority)
    {
        this.stype = stype;
        this.desc = desc;
        this.priority = priority;
    }

    bool instanceOf(string ver) => stype == "ppas" ? ver.canFind("EnterpriseDB") : true;

    /// Attribute access from templates (`st.description`, `st.server_type`).
    override Value getAttr(string name)
    {
        switch (name)
        {
        case "stype", "server_type": return Value(stype);
        case "desc", "description": return Value(desc);
        case "priority", "spriority": return Value(priority);
        case "icon": return Value(stype ~ ".svg");
        default: return Value.undefined;
        }
    }

    override string typeName() const { return "ServerType"; }

    private __gshared ServerType[string] registry;

    static void register(ServerType t)
    {
        registry[t.stype] = t;
    }

    /// Highest priority first.
    static ServerType[] types()
    {
        import std.algorithm : sort;
        auto r = registry.values;
        sort!((a, b) => a.priority > b.priority)(r);
        return r;
    }

    static void registerDefaults()
    {
        register(new ServerType("pg", "PostgreSQL", -1));
        register(new ServerType("ppas", "EDB Advanced Server", 2));
    }
}

// ------------------------------------------------------------ Connection

final class Connection : Obj
{
    string connId;
    ServerManager manager;
    string db;
    PgConnection conn;
    bool autoReconnect = true;
    bool async_;
    bool wasConnected;
    bool reconnecting;
    bool useBinaryPlaceholder;
    bool arrayToString;
    bool executionAborted;
    long rowCount;
    string password;       /// encrypted password kept for reconnects
    string pythonEncoding = "utf-8";
    int backendPid;
    private string asyncQueryError;
    // async execution state (Query Tool)
    PgResult asyncResult;
    string asyncQueryId;
    string[] pendingNotices;
    Column[] columnInfo;

    this(ServerManager manager, string connId, string db, bool autoReconnect = true, bool async_ = false,
            bool useBinaryPlaceholder = false, bool arrayToString = false)
    {
        assert(manager !is null && connId !is null);
        this.manager = manager;
        this.connId = connId;
        this.db = db !is null ? db : manager.db;
        this.autoReconnect = autoReconnect;
        this.async_ = async_;
        this.useBinaryPlaceholder = useBinaryPlaceholder;
        this.arrayToString = arrayToString;
    }

    /// `conn.db` in templates
    override Value getAttr(string name)
    {
        switch (name)
        {
        case "db": return Value(db);
        case "conn_id": return Value(connId);
        case "manager": return Value(manager);
        default: return Value.undefined;
        }
    }

    override string typeName() const { return "Connection"; }

    Value asDict()
    {
        if (!autoReconnect && conn is null)
            return Value(null);
        auto d = new Dict;
        d["conn_id"] = connId;
        d["database"] = db;
        d["async_"] = Value(async_ ? 1 : 0);
        d["wasConnected"] = Value(wasConnected);
        d["auto_reconnect"] = Value(autoReconnect);
        d["use_binary_placeholder"] = Value(useBinaryPlaceholder);
        d["array_to_string"] = Value(arrayToString);
        return Value(d);
    }

    override string toString() const
    {
        return "PG Connection: " ~ connId ~ " (" ~ db ~ ") -> " ~ (conn !is null && !conn.closed ? "Connected" : "Disconnected")
            ~ " (ajax:" ~ (async_ ? "1" : "0") ~ ")";
    }

    private string connIdForError() => connId.startsWith("DB:") ? null : connId[5 .. $];

    private ConnectionLost lostException() => new ConnectionLost(manager.sid, db, connIdForError());

    // ------------------------------------------------------------ connect

    /// `connect(**kwargs)`: kwargs may have `password`, `user`, `encpass`, `tunnel_password`, `role`, `auto_commit`.
    Res connect(Dict kwargs = null)
    {
        if (kwargs is null)
            kwargs = new Dict;
        if (conn !is null)
        {
            if (conn.closed)
                conn = null;
            else
                return okRes();
        }

        auto ck = getCryptKey();
        if (!ck.present)
            throw new CryptKeyMissing();

        // _check_user_password
        string pwd;
        string encpass;
        bool isUpdatePassword = true;
        if (kwargs.has("user") && kwargs.get("password").truthy)
        {
            pwd = kwargs["password"].toString;
            kwargs.pop("password");
            isUpdatePassword = false;
        }
        else if (kwargs.has("encpass"))
            encpass = kwargs.get("encpass").strOr(null);
        else
            encpass = kwargs.has("password") ? kwargs.get("password").strOr(null) : null;

        if (manager.useSshTunnel)
            return errRes("SSH tunnels are not supported by this build.");

        if (isUpdatePassword)
        {
            if (encpass is null)
                encpass = password !is null ? password : manager.password;
            password = encpass;
        }
        if (reconnecting)
            password = null;

        // _decode_password
        if (encpass.length)
        {
            auto user = userById(currentUserId());
            if (user.isNone)
                return errRes("Unauthorized request.");
            try
                pwd = decryptStr(encpass, ck.key);
            catch (Exception e)
            {
                logException(e);
                return errRes("Failed to decrypt the saved password.\nError: " ~ e.msg);
            }
        }

        // passexec: fall back to the command when there is no password
        if (!pwd.length && !encpass.length && manager.passexecCmd.length)
        {
            if (manager.connectionParam("passfile").isNone)
                pwd = manager.runPassexec();
        }

        string dbUser = kwargs.get("user").truthy ? kwargs["user"].toString : manager.user;
        string connStr = manager.createConnectionString(db, dbUser, pwd);

        try
            conn = PgConnection.connect(connStr, 30.seconds);
        catch (PgError e)
        {
            auto msg = e.fullMessage;
            logInfo("Failed to connect to the database server(#" ~ manager.sid.toString ~ ") for connection ("
                    ~ connId ~ ") with error message as below:" ~ msg);
            return errRes(msg);
        }
        conn.arrayToString = arrayToString;
        conn.perColumnTableInfo = async_;
        conn.binaryPlaceholder = useBinaryPlaceholder;
        wasConnected = true;

        Res r;
        try
            r = initialize(kwargs);
        catch (Exception e)
        {
            logException(e);
            conn = null;
            if (!reconnecting)
                wasConnected = false;
            throw e;
        }
        if (r.ok && isUpdatePassword)
            manager.updatePassword(encpass);
        else if (!reconnecting && isUpdatePassword)
            wasConnected = false;
        return r;
    }

    /// Runs a statement during initialisation; returns an error message or null.
    private string runInit(string sql, out PgResult last)
    {
        PgResult first;
        try
            conn.execute(sql, first, last);
        catch (PgError e)
            return e.fullMessage;
        return null;
    }

    private Res initialize(Dict kwargs)
    {
        executionAborted = false;
        backendPid = conn.backendPid;
        PgResult last;

        auto enc = conn.parameterStatus("client_encoding");
        auto pgEnc = encodingFor(enc);
        string status = runInit("SET DateStyle=ISO; SET client_min_messages=notice; "
                ~ "SELECT set_config('bytea_output','hex',false) FROM pg_show_all_settings() WHERE name = 'bytea_output'; "
                ~ "SET client_encoding='" ~ pgEnc ~ "';", last);
        if (status !is null)
        {
            conn.close();
            conn = null;
            return errRes(status);
        }

        // SET ROLE
        string role = kwargs.get("role").truthy ? kwargs["role"].toString : manager.role;
        if (role.length)
        {
            PgResult rr;
            auto err = runInit("SELECT rolname from pg_catalog.pg_roles WHERE rolname = " ~ qtLiteral(Value(role)), rr);
            string failure;
            if (err !is null)
                failure = err;
            else if (rr.rows.length)
            {
                PgResult x;
                auto e2 = runInit("SET ROLE TO " ~ qtLiteral(Value(role)), x);
                if (e2 !is null)
                    failure = e2;
            }
            else
                failure = role;
            if (failure !is null)
            {
                conn.close();
                conn = null;
                logError("Connect to the database server (#" ~ manager.sid.toString ~ ") for connection (" ~ connId
                        ~ "), but - failed to setup the role  " ~ failure);
                return errRes("Failed to setup the role \n" ~ failure);
            }
        }

        // version
        PgResult vr;
        auto verr = runInit("SELECT version()", vr);
        if (verr !is null)
        {
            conn.close();
            conn = null;
            wasConnected = false;
            logError("Failed to fetch the version information on the established connection to the database server (#"
                    ~ manager.sid.toString ~ ") for '" ~ connId ~ "' with below error message:" ~ verr);
            return errRes(verr);
        }
        if (vr.rows.length)
        {
            manager.ver = vr.rows[0][0].toString;
            manager.sversion = conn.serverVersion;
        }

        PgResult dr;
        auto derr = runInit("SELECT db.oid as did, db.datname, db.datallowconn, "
                ~ "pg_encoding_to_char(db.encoding) AS serverencoding, "
                ~ "has_database_privilege(db.oid, 'CREATE') as cancreate, datistemplate "
                ~ "FROM pg_catalog.pg_database db WHERE db.datname = current_database()", dr);
        if (derr is null && dr.rows.length)
        {
            auto row = dr.asDicts()[0];
            auto did = row["did"].integer;
            if (manager.dbInfo is null)
                manager.dbInfo = new Dict;
            manager.dbInfo[to!string(did)] = Value(row.dict.copy());
            if (manager.dbInfo.length == 1)
                manager.did = Value(did);
            if (manager.sversion >= 120000)
            {
                PgResult gr;
                auto gerr = runInit("SELECT gss_authenticated, encrypted FROM pg_catalog.pg_stat_gssapi "
                        ~ "WHERE pid = pg_backend_pid()", gr);
                if (gerr is null && gr.rows.length)
                {
                    auto g = gr.asDicts()[0];
                    auto entry = manager.dbInfo[to!string(did)];
                    entry["gss_authenticated"] = g["gss_authenticated"];
                    entry["gss_encrypted"] = g["encrypted"];
                    if (manager.dbInfo.length == 1)
                    {
                        manager.gssAuthenticated = g["gss_authenticated"].truthy;
                        manager.gssEncrypted = g["encrypted"].truthy;
                    }
                }
            }
        }

        // user info
        if (!kwargs.has("user"))
        {
            PgResult ur;
            auto uerr = runInit(userInfoSql, ur);
            manager.userInfo = new Dict;
            if (uerr is null && ur.rows.length)
                manager.userInfo = ur.asDicts()[0].dict;
        }

        // server type
        if (kwargs.has("password"))
            manager.password = kwargs["password"].strOr(null);
        auto types = ServerType.types();
        foreach (st; types)
        {
            if (st.stype == "ppas" ? st.instanceOf(manager.ver) : st.instanceOf(null))
            {
                manager.serverType = st.stype;
                manager.serverCls = st;
                break;
            }
        }

        // post connection SQL
        string errmsg;
        if (manager.postConnectionSql.length)
        {
            PgResult pr;
            auto perr = runInit(manager.postConnectionSql, pr);
            if (perr !is null)
            {
                logError("Failed to execute the post connection SQL with below error message:\n" ~ perr);
                errmsg = "Failed to execute the post connection SQL with below error message:\n" ~ sanitizeExternalText(perr);
            }
        }
        manager.updateSession();
        return okRes(errmsg.length ? Value(errmsg) : Value(null));
    }

    private enum userInfoSql = "SELECT roles.oid as id, roles.rolname as name, roles.rolsuper as is_superuser, "
        ~ "CASE WHEN roles.rolsuper THEN true ELSE roles.rolcreaterole END as can_create_role, "
        ~ "CASE WHEN roles.rolsuper THEN true ELSE roles.rolcreatedb END as can_create_db, "
        ~ "CASE WHEN 'pg_signal_backend'=ANY(ARRAY(WITH RECURSIVE cte AS (SELECT pg_roles.oid,pg_roles.rolname "
        ~ "FROM pg_catalog.pg_roles WHERE pg_roles.oid = roles.oid UNION ALL SELECT m.roleid,pgr.rolname FROM cte cte_1 "
        ~ "JOIN pg_catalog.pg_auth_members m ON m.member = cte_1.oid JOIN pg_catalog.pg_roles pgr ON pgr.oid = m.roleid) "
        ~ "SELECT rolname FROM cte)) THEN True ELSE False END as can_signal_backend "
        ~ "FROM pg_catalog.pg_roles as roles WHERE rolname = current_user";

    // ------------------------------------------------------------ state

    bool connected()
    {
        if (conn !is null)
        {
            if (!conn.closed)
                return true;
            conn = null;
        }
        return false;
    }

    TxStatus transactionStatus() => conn is null ? TxStatus.unknown : conn.transactionStatus;

    /// A real round trip: detects connections dropped without notice.
    bool ping()
    {
        if (!connected())
            return false;
        try
        {
            if (conn.transactionStatus != TxStatus.idle)
                return true;
            PgResult a, b;
            conn.execute("SELECT 1", a, b);
            return true;
        }
        catch (Exception)
        {
            try
                conn.close();
            catch (Exception)
            {
            }
            conn = null;
            return false;
        }
    }

    void release()
    {
        if (wasConnected)
        {
            if (conn !is null)
            {
                conn.close();
                conn = null;
            }
            password = null;
            wasConnected = false;
        }
    }

    Res reset()
    {
        if (conn !is null && conn.closed)
            conn = null;
        string pwd;
        if (manager.password.length)
        {
            if (userById(currentUserId()).isNone)
                return errRes("Unauthorized request.");
            auto ck = getCryptKey();
            if (!ck.present)
                return errRes(ck.key);
            pwd = decryptStr(manager.password, ck.key);
        }
        try
            conn = PgConnection.connect(manager.createConnectionString(db, manager.user, pwd), 30.seconds);
        catch (PgError e)
        {
            logError("Failed to reset the connection to the server due to following error:\n" ~ e.fullMessage);
            return errRes(e.fullMessage);
        }
        backendPid = conn.backendPid;
        return okRes();
    }

    // ------------------------------------------------------------ execution

    /// Reconnects once when the connection is gone and `autoReconnect` is on, otherwise throws ConnectionLost.
    private void ensureConnected()
    {
        if (!wasConnected)
            throw lostException();
        if (!connected())
        {
            logWarning("Connection to database server (#" ~ manager.sid.toString ~ ") for the connection - '" ~ connId
                    ~ "' has been lost.");
            if (autoReconnect && !reconnecting)
                attemptReconnect();
            else
                throw lostException();
        }
        if (executionAborted)
            executionAborted = false;
    }

    private void attemptReconnect()
    {
        reconnecting = true;
        try
        {
            auto r = connect();
            reconnecting = false;
            if (r.ok)
                return;
        }
        catch (Exception e)
        {
            logException(e);
            logWarning("Failed to reconnect the database server (Server #" ~ manager.sid.toString ~ ", Connection #"
                    ~ connId ~ ")");
        }
        reconnecting = false;
        throw lostException();
    }

    private void logQuery(string kind, string sql)
    {
        if (conn is null)
            return;
        logSql("Execute (" ~ kind ~ ") by " ~ currentUserAttr("email").strOr("") ~ " on " ~ conn.user ~ "@" ~ conn.host
                ~ "/" ~ conn.dbname ~ " #" ~ manager.sid.toString ~ " - " ~ connId ~ ":\n" ~ sql);
    }

    /// Runs `sql`; `params` (a dict or list) are substituted client-side like psycopg's `%s`/`%(name)s`.
    private Res run(string kind, string sql, Value params, bool formatted, out PgResult first, out PgResult last,
            bool retried = false)
    {
        ensureConnected();
        if (params.isDict || params.isList)
            if (params.length)
            {
                try
                    sql = mogrifyQuery(sql, params);
                catch (ProgrammingError e)
                    return errRes(e.msg);
            }
        logQuery(kind, sql);
        try
        {
            conn.execute(sql, first, last);
        }
        catch (PgError e)
        {
            if (!connected() || e.connectionLost)
            {
                conn = null;
                if (autoReconnect && !reconnecting && !retried)
                {
                    attemptReconnect();
                    return run(kind, sql, Value(null), formatted, first, last, true);
                }
                throw lostException();
            }
            auto msg = formattedExceptionMsg(e, formatted);
            logError("Failed to execute query (" ~ kind ~ ") for the server #" ~ manager.sid.toString ~ " - " ~ connId
                    ~ ":\nError Message:" ~ msg);
            return errRes(msg);
        }
        return okRes();
    }

    Res executeScalar(string sql, Value params = Value(null), bool formatted = false)
    {
        rowCount = 0;
        PgResult first, last;
        auto r = run("scalar", sql, params, formatted, first, last);
        if (!r.ok)
            return r;
        rowCount = last is null ? 0 : last.rowcount;
        if (last !is null && last.hasDescription && last.rows.length && last.rows[0].length)
            return okRes(last.rows[0][0]);
        return okRes();
    }

    Res executeVoid(string sql, Value params = Value(null), bool formatted = false)
    {
        PgResult first, last;
        auto r = run("void", sql, params, formatted, first, last);
        return r.ok ? okRes() : r;
    }

    /// `{'columns': [...], 'rows': [[...]]}`
    Res execute2darray(string sql, Value params = Value(null), bool formatted = false)
    {
        rowCount = 0;
        PgResult first, last;
        auto r = run("2darray", sql, params, formatted, first, last);
        if (!r.ok)
            return r;
        auto d = new Dict;
        Value[] cols;
        if (first !is null)
            foreach (c; first.columns)
                cols ~= c.toDict();
        d["columns"] = Value(cols);
        rowCount = first is null ? 0 : first.rowcount;
        // psycopg's DictCursor returns dicts here too (the "2d array" name is historical)
        d["rows"] = first !is null && first.rowcount > 0 && first.hasDescription ? Value(first.asDicts()) : Value.newList();
        return okRes(Value(d));
    }

    /// `{'columns': [...], 'rows': [{col: value}]}`: columns of the first statement, rows of the last (a pgAdmin quirk).
    Res executeDict(string sql, Value params = Value(null), bool formatted = false)
    {
        rowCount = 0;
        PgResult first, last;
        auto r = run("dict", sql, params, formatted, first, last);
        if (!r.ok)
            return r;
        auto d = new Dict;
        Value[] cols;
        if (first !is null)
            foreach (c; first.columns)
                cols ~= c.toDict();
        d["columns"] = Value(cols);
        rowCount = first is null ? 0 : first.rowcount;
        d["rows"] = last !is null && last.rowcount > 0 && last.hasDescription ? Value(last.asDicts()) : Value.newList();
        return okRes(Value(d));
    }

    long rowsAffected() => rowCount;

    // ------------------------------------------------------------ async execution (Query Tool)

    enum CURSOR_NOT_FOUND = "Cursor could not be found for the async connection.";
    enum ASYNC_BUSY = "Asynchronous query execution/operation underway.";

    /// Every result set of the last async query; `asyncResult` is the one the "cursor" is on (the last).
    PgResult[] asyncResults;
    bool hasAsyncCursor;
    /// the SQL text of the last async query (`cursor._query`)
    string asyncQuery;
    bool asyncCursorClosed;
    /// A query started with `startAsync` has not finished.
    bool asyncRunning;
    private long asyncPos;
    private Value columnInfoValue = Value(null);
    private PgConnection.PgNotify[] notifyList;
    private bool notifyListIsNone = true;

    /// `async_query_error()`
    string asyncError() => asyncQueryError;

    string statusMessage() => !hasAsyncCursor ? CURSOR_NOT_FOUND : (asyncResult is null ? "" : asyncResult.statusMessage);

    /// `total_rows`: psycopg's `rowcount` of the cursor's current result.
    long totalRows() => !hasAsyncCursor || asyncResult is null ? 0 : asyncResult.rowcount;

    Value getColumnInfo() => columnInfoValue;

    private void resetAsyncState(bool formatted, string sql, Value params, out string finalSql)
    {
        asyncResult = null;
        asyncResults = null;
        asyncQueryError = null;
        hasAsyncCursor = false;
        asyncCursorClosed = false;
        asyncPos = 0;
        ensureConnected();
        finalSql = sql;
        if (params.isDict || params.isList)
            if (params.length)
                finalSql = mogrifyQuery(sql, params);
    }

    /// The part of `execute_async` that waits for the server (safe to run in a background fiber).
    private Res asyncBody(string sql, bool formatted)
    {
        conn.perColumnTableInfo = true;
        conn.binaryPlaceholder = useBinaryPlaceholder;
        conn.notices = null;
        notifyList = null;
        notifyListIsNone = true;
        executionAborted = false;
        try
        {
            PgResult first, last;
            conn.execute(sql, first, last);
            asyncResults = conn.allResults;
            asyncResult = last;
            asyncPos = 0;
            pullNotifies();
        }
        catch (PgError e)
        {
            auto msg = formattedExceptionMsg(e, formatted);
            logError("Failed to execute query (execute_async) for the server #" ~ manager.sid.toString ~ " - " ~ connId
                    ~ " (Query-id: " ~ asyncQueryId ~ "):\nError Message:" ~ msg);
            asyncQueryError = msg;
            pullNotifies();
            return errRes(msg);
        }
        return okRes();
    }

    /// `execute_async(query, params, formatted_exception_msg, server_cursor)`: waits for the result.
    Res executeAsync(string sql, Value params = Value(null), bool formatted = true, bool serverCursor = false)
    {
        string finalSql;
        resetAsyncState(formatted, sql, params, finalSql);
        asyncQueryId = to!string(1 + uniform(0, 9999998));
        hasAsyncCursor = true;
        asyncQuery = finalSql;
        logQuery("async", finalSql);
        return asyncBody(finalSql, formatted);
    }

    /// Starts the query in a background fiber (`QueryThread`); `done` runs when it finishes.
    Res startAsync(string sql, Value params, bool formatted, void delegate(Res) done)
    {
        import andaime : spawn;
        string finalSql;
        resetAsyncState(formatted, sql, params, finalSql);
        asyncQueryId = to!string(1 + uniform(0, 9999998));
        hasAsyncCursor = true;
        asyncQuery = finalSql;
        logQuery("async", finalSql);
        asyncRunning = true;
        auto self = this;
        spawn(cast(void delegate() @safe) () {
            Res r;
            try
                r = self.asyncBody(finalSql, formatted);
            catch (Exception e)
            {
                logException(e);
                self.asyncQueryError = e.msg;
                r = errRes(e.msg);
            }
            try
            {
                if (done !is null)
                    done(r);
            }
            catch (Exception e)
            {
                logException(e);
            }
            self.asyncRunning = false;
        });
        return okRes();
    }

    void releaseAsyncCursor()
    {
        if (hasAsyncCursor && !asyncCursorClosed)
            asyncCursorClosed = true;
    }

    /// `poll(formatted_exception_msg, no_result)`: `status` is 1 (ASYNC_OK) or 3 (still running); `ok` false on error.
    struct PollResult
    {
        bool ok;
        long status;
        Value result;
        string error;
    }

    PollResult poll(bool formatted = false, bool noResult = false)
    {
        PollResult p;
        long status;
        if (asyncRunning)
            status = 3;
        else if (asyncQueryError.length)
        {
            p.error = asyncQueryError;
            return p;
        }
        else if (conn !is null && conn.lastErrorMessage.length)
        {
            p.error = conn.lastErrorMessage;
            return p;
        }
        else
            status = 1;
        if (!hasAsyncCursor || asyncCursorClosed)
        {
            p.error = CURSOR_NOT_FOUND;
            return p;
        }
        Value result = Value(null);
        rowCount = 0;
        columnInfoValue = Value(null);
        if (conn !is null && !asyncRunning)
        {
            foreach (set; asyncResults)
            {
                if (set.hasDescription && set.columns.length)
                {
                    Value[] cols;
                    foreach (i, c; set.columns)
                    {
                        auto d = c.toDict();
                        d["pos"] = Value(cast(long) i);
                        cols ~= d;
                    }
                    columnInfoValue = Value(cols);
                }
                else
                    columnInfoValue = Value(null);
                rowCount = set.hasDescription ? set.rowcount : 0;
                if (!noResult && rowCount > 0)
                {
                    Value[] rows;
                    rows.reserve(set.rows.length);
                    foreach (row; set.rows)
                        rows ~= Value(row.dup);
                    result = Value(rows);
                }
            }
        }
        p.ok = true;
        p.status = status;
        p.result = result;
        return p;
    }

    /// `async_fetchmany_2darray(records, from_rownum, to_rownum)`; `records == -2` stands for Python's `None` (window).
    Res asyncFetchmany(long records = 2000, long fromRownum = 0, long toRownum = 0)
    {
        if (!hasAsyncCursor)
            return errRes(CURSOR_NOT_FOUND);
        if (conn is null)
            throw lostException();
        if (asyncRunning)
            return errRes(ASYNC_BUSY);
        auto rs = asyncResult;
        if (rs is null || !rs.hasDescription || rs.rowcount <= 0)
            return okRes();
        Value[] result;
        long n = rs.rows.length;
        void scrollTo(long pos)
        {
            if (pos < 0 || pos > n)
                throw new Exception("position out of bound");
            asyncPos = pos;
        }
        void take(long count)
        {
            long end = asyncPos + count;
            if (count < 0 || end > n)
                end = n;
            foreach (row; rs.rows[asyncPos .. end])
                result ~= Value(row.dup);
            asyncPos = end;
        }
        if (records == -1)
        {
            scrollTo(0);
            take(rs.rowcount);
        }
        else if (records == -2)
        {
            scrollTo(fromRownum);
            take(toRownum - fromRownum + 1);
        }
        else
            take(records);
        return okRes(Value(result));
    }

    /// `reset_cursor_at(position)`
    void resetCursorAt(long position)
    {
        if (!hasAsyncCursor || asyncResult is null)
        {
            logWarning("Cursor not found in reset_cursor_at method");
            return;
        }
        if (position < 0 || position > asyncResult.rows.length)
            return;
        asyncPos = position;
    }

    /// The cell at (`row`, `col`) of the current result, for the binary download.
    bool cellAt(long row, long col, out Value cell)
    {
        if (asyncResult is null || row < 0 || row >= asyncResult.rows.length)
            return false;
        if (col < 0 || col >= asyncResult.rows[row].length)
            return false;
        cell = asyncResult.rows[row][col];
        return true;
    }

    private void pullNotifies()
    {
        if (conn is null)
            return;
        foreach (n; conn.takeNotifies())
        {
            notifyList ~= n;
            notifyListIsNone = false;
        }
    }

    /// `get_notifies()`: the received notifications as dicts, or None (and forgets them).
    Value getNotifies()
    {
        if (!asyncRunning)
            pullNotifies();
        if (notifyListIsNone || notifyList.length == 0)
            return Value(null);
        Value[] r;
        foreach (n; notifyList)
            r ~= Value.dictOf("recorded_time", nowString(), "channel", n.channel, "payload",
                    n.payload.length ? Value(n.payload) : Value(null), "pid", n.pid);
        notifyList = null;
        notifyListIsNone = true;
        return Value(r);
    }

    private static string nowString()
    {
        import std.datetime : Clock;
        auto t = Clock.currTime();
        return format("%04d-%02d-%02d %02d:%02d:%02d.%06d", t.year, cast(int) t.month, t.day, t.hour, t.minute, t.second,
                cast(int) t.fracSecs.total!"usecs");
    }

    // ------------------------------------------------------------ errors and notices

    /// `_formatted_exception_msg`
    string formattedExceptionMsg(PgError e, bool formatted)
    {
        string errmsg = e.fullMessage;
        if (e.sqlstate.length == 0 && e.primary.length == 0)
        {
            // a driver-level error
        }
        else if (e.detail.length)
            errmsg = e.primary ~ "\n" ~ e.detail;
        if (!formatted)
        {
            auto n = getNotices();
            return n.length == 0 ? errmsg : n ~ "\n" ~ errmsg;
        }
        if (!errmsg.startsWith("ERROR:"))
            errmsg = "ERROR:  " ~ errmsg ~ " \n\n";
        if (e.severity.length && e.primary.length)
        {
            auto diag = e.severity ~ ":  " ~ e.primary;
            if (!errmsg.strip.toLower.canFind(diag.strip.toLower))
                errmsg ~= diag;
        }
        else if (e.primary.length)
        {
            if (!errmsg.toLower.canFind(e.primary.toLower))
                errmsg ~= e.primary;
        }
        void line(string label, string v)
        {
            if (v.length && !errmsg.toLower.canFind(label.toLower))
            {
                if (!errmsg.endsWith("\n"))
                    errmsg ~= "\n";
                errmsg ~= label ~ " " ~ v;
            }
        }

        if (e.sqlstate.length)
        {
            if (!errmsg.endsWith("\n"))
                errmsg ~= "\n";
            errmsg ~= "SQL state: " ~ e.sqlstate;
        }
        line("Detail:", e.detail);
        line("Hint:", e.hint);
        line("Character:", e.position);
        line("Context:", e.context);
        auto n = getNotices();
        return n.length == 0 ? errmsg : n ~ "\n" ~ errmsg;
    }

    /// `get_notices()`: the accumulated notices as a string (and clears them).
    string getNotices()
    {
        string s;
        if (conn is null)
            return s;
        foreach (n; conn.notices)
            s ~= n;
        conn.notices = null;
        return s;
    }

    /// `messages()`: notices and notifications as text lines.
    string[] messages()
    {
        string[] resp;
        if (conn is null)
            return resp;
        resp ~= conn.notices;
        conn.notices = null;
        if (!asyncRunning)
            pullNotifies();
        foreach (n; notifyList)
        {
            if (n.payload.length)
                resp ~= "Asynchronous notification \"" ~ n.channel ~ "\" with payload \"" ~ n.payload
                    ~ "\" received from server process with PID " ~ to!string(n.pid) ~ "\n";
            else
                resp ~= "Asynchronous notification \"" ~ n.channel ~ "\" received from server process with PID "
                    ~ to!string(n.pid) ~ "\n";
        }
        return resp;
    }

    /// `cancel_transaction(conn_id, did)`: cancels the query running on another connection of this server.
    Res cancelTransaction(string otherConnId, Value did = Value(null))
    {
        auto other = manager.connection(null, otherConnId, true, did);
        auto query = "SELECT pg_cancel_backend(" ~ to!string(other.backendPid) ~ ");";
        if (other.backendPid == backendPid)
        {
            // the same backend: cancel from a fresh connection
            string pwd;
            if (manager.password.length)
            {
                auto ck = getCryptKey();
                if (!ck.present)
                    return errRes(ck.key);
                pwd = decryptStr(manager.password, ck.key);
            }
            try
            {
                auto c = PgConnection.connect(manager.createConnectionString(db, manager.user, pwd), 30.seconds);
                scope (exit)
                    c.close();
                PgResult a, b;
                c.execute(query, a, b);
            }
            catch (PgError e)
                return errRes(e.fullMessage);
            return okRes(Value(""));
        }
        if (connected())
        {
            auto r = executeVoid(query);
            if (r.ok)
                other.executionAborted = true;
            return r;
        }
        return errRes("Not connected to the database server.");
    }

    /// `pq_encrypt_password_conn(password, user)`
    string pqEncryptPasswordConn(string pwd, string user)
    {
        if (!connected())
            return null;
        auto r = executeScalar("SHOW password_encryption");
        if (!r.ok)
            return null;
        return conn.encryptPassword(pwd, user, r.value.toString);
    }

    /// `mogrify(query, parameters)`
    string mogrify(string query, Value params)
    {
        if (params.isDict || params.isList)
            return mogrifyQuery(query, params);
        return query;
    }
}

/// psycopg's client-side binding: `%s` (positional), `%(name)s` (named), `%%` for a percent sign.
/// How psycopg's client-side binding writes a parameter (negative numbers get a leading space).
private string paramLiteral(Value v)
{
    auto t = qtLiteral(v);
    if ((v.isInt || v.type == VType.floating) && t.length && t[0] == '-')
        return " " ~ t;
    return t;
}

string mogrifyQuery(string sql, Value params)
{
    auto a = appender!string;
    size_t pos;
    size_t i;
    bool named, positional;
    string[] missing;
    while (i < sql.length)
    {
        char c = sql[i];
        if (c != '%')
        {
            a.put(c);
            i++;
            continue;
        }
        if (i + 1 < sql.length && sql[i + 1] == '%')
        {
            a.put('%');
            i += 2;
            continue;
        }
        if (i + 1 < sql.length && sql[i + 1] == '(')
        {
            auto e = sql.indexOf(')', i);
            if (e < 0)
                throw new ProgrammingError("incomplete placeholder: '" ~ sql[i .. $] ~ "'");
            auto key = sql[i + 2 .. e];
            if (key.length == 0)
                throw new ProgrammingError("incomplete placeholder: '%()s'");
            if (positional)
                throw new ProgrammingError("positional and named placeholders cannot be mixed");
            named = true;
            if (params.isDict && !params.dict.has(key))
            {
                if (!missing.canFind(key))
                    missing ~= key;
                a.put("NULL");
            }
            else
                a.put(paramLiteral(params.isDict ? params.dict.get(key) : Value(null)));
            // skip the type letter
            i = e + 2;
            continue;
        }
        if (i + 1 < sql.length && (sql[i + 1] == 's' || sql[i + 1] == 't' || sql[i + 1] == 'b'))
        {
            if (named)
                throw new ProgrammingError("positional and named placeholders cannot be mixed");
            positional = true;
            if (params.isList && pos >= params.list.items.length)
            {
                // count the remaining placeholders for the message
                size_t total = pos + 1;
                for (size_t j = i + 2; j + 1 < sql.length; j++)
                    if (sql[j] == '%' && (sql[j + 1] == 's' || sql[j + 1] == 't' || sql[j + 1] == 'b'))
                        total++;
                throw new ProgrammingError("the query has " ~ to!string(total) ~ " placeholders but "
                        ~ to!string(params.list.items.length) ~ " parameters were passed");
            }
            a.put(paramLiteral(params.isList ? params.list.items[pos++] : Value(null)));
            i += 2;
            continue;
        }
        a.put(c);
        i++;
    }
    if (missing.length)
    {
        import std.algorithm : sort;
        missing.sort();
        throw new ProgrammingError("query parameter missing: " ~ missing.join(", "));
    }
    return a.data;
}

/// `sanitize_external_text`: escapes HTML-significant characters of text from an external source.
string sanitizeExternalText(string s)
{
    import pgadmin.jinja.runtime : htmlEscape;
    return htmlEscape(s);
}

/// Maps a libpq client encoding name to the name used in `SET client_encoding`.
private string encodingFor(string e)
{
    if (e.length == 0)
        return "UTF8";
    switch (e.toLower)
    {
    case "utf8", "utf-8": return "UTF8";
    case "sql_ascii": return "SQL_ASCII";
    default: return e;
    }
}

// ------------------------------------------------------------ ServerManager

final class ServerManager : Obj
{
    Value sid;
    string host;
    Value port;
    string db;
    Value did;
    string user;
    string password;       /// encrypted
    string role;
    bool isShared;
    string name;
    string ver;
    int sversion;
    string serverType;
    ServerType serverCls;
    Dict dbInfo;
    Dict userInfo;
    string dbRes;
    string dbResType;
    string passexecCmd;
    long passexecExpiration;
    string service;
    bool useSshTunnel;
    bool kerberosConn;
    bool gssAuthenticated, gssEncrypted;
    Value connectionParams;
    Value prepareThreshold;
    string postConnectionSql;
    string displayConnectionString;
    Connection[string] connections;
    string[] connectionOrder;
    long pinged;

    this(Value server)
    {
        update(server);
    }

    override Value getAttr(string name)
    {
        switch (name)
        {
        case "version": return Value(sversion);
        case "server_type": return Value(serverType);
        case "ver": return Value(ver);
        case "sversion": return Value(sversion);
        case "db": return Value(db);
        default: return Value.undefined;
        }
    }

    override string typeName() const { return "ServerManager"; }

    void update(Value server)
    {
        ver = null;
        sversion = 0;
        serverType = null;
        serverCls = null;
        password = null;
        sid = server["id"];
        host = server.get("host").strOr(null);
        port = server.get("port");
        db = server.get("maintenance_db").strOr(null);
        isShared = server.get("shared").truthy;
        did = Value(null);
        user = server.get("username").strOr(null);
        password = binaryColumn(server.get("password"));
        role = server.get("role").strOr(null);
        dbInfo = new Dict;
        dbRes = server.get("db_res").strOr(null);
        dbResType = server.get("db_res_type").strOr(null);
        name = server.get("name").strOr(null);
        passexecCmd = server.get("passexec_cmd").strOr(null);
        passexecExpiration = server.get("passexec_expiration").isInt ? server.get("passexec_expiration").integer : 0;
        service = server.get("service").strOr(null);
        useSshTunnel = cfgBool("SUPPORT_SSH_TUNNEL") && server.get("use_ssh_tunnel").truthy;
        kerberosConn = server.get("kerberos_conn").truthy;
        gssAuthenticated = gssEncrypted = false;
        connectionParams = server.get("connection_params");
        prepareThreshold = server.get("prepare_threshold");
        postConnectionSql = server.get("post_connection_sql").strOr(null);
        createConnectionString(db, user);
        foreach (k, c; connections)
            c.release();
        connections = null;
        connectionOrder = null;
        updateSession();
    }
    private void setPassword(string p)
    {
        password = p;
    }

    void updatePassword(string p)
    {
        password = p;
        foreach (k, c; connections)
            if (c.conn !is null || c.wasConnected)
                c.password = p;
    }

    Value asDict()
    {
        if (ver.length == 0 || connections.length == 0)
            return Value(null);
        auto res = new Dict;
        res["sid"] = sid;
        res["ver"] = ver;
        res["sversion"] = Value(sversion);
        res["password"] = password.length ? Value(password) : Value(null);
        auto conns = new Dict;
        foreach (k, c; connections)
        {
            auto d = c.asDict();
            if (!d.isNone)
                conns[k] = d;
        }
        res["connections"] = Value(conns);
        return Value(res);
    }

    /// `manager.version` (the numeric server version used in template paths).
    int version_() => sversion;

    /// `manager.version` as JSON: None until a connection has read the server version
    Value versionValue() => sversion == 0 ? Value(null) : Value(sversion);

    int majorVersion()
    {
        if (sversion == 0)
            throw new ExecuteError("Information is not available.");
        return sversion / 10000;
    }

    int minorVersion() => (sversion / 100) % 100;

    /// `connection(**kwargs)`: the (possibly not yet connected) Connection for a database or a dedicated id.
    Connection connection(string database = null, string connId = null, bool autoReconnect = true,
            Value didArg = Value(null), Value async_ = Value(null), bool useBinaryPlaceholder = false,
            bool arrayToString = false)
    {
        if (database !is null)
        {
            if (!didArg.isNone && dbInfo.has(didArg.toString))
                dbInfo[didArg.toString]["datname"] = database;
        }
        else
        {
            auto connStr = CONN_STRING ~ (connId is null ? "None" : connId);
            if (didArg.isNone)
                database = db;
            else if (dbInfo.has(didArg.toString))
                database = dbInfo[didArg.toString]["datname"].toString;
            else if (connId !is null && connStr in connections)
                database = connections[connStr].db;
            else
            {
                auto maintenanceId = DB_STRING ~ db;
                if (auto mc = maintenanceId in connections)
                {
                    if (!mc.connected())
                        mc.connect();
                    if (mc.connected())
                    {
                        auto r = mc.executeDict("SELECT db.oid as did, db.datname, db.datallowconn, "
                                ~ "pg_catalog.pg_encoding_to_char(db.encoding) AS serverencoding, "
                                ~ "pg_catalog.has_database_privilege(db.oid, 'CREATE') as cancreate, datistemplate "
                                ~ "FROM pg_catalog.pg_database db WHERE db.oid = " ~ didArg.toString);
                        if (r.ok && r.value["rows"].length > 0)
                        {
                            foreach (row; r.value["rows"].list.items)
                            {
                                dbInfo[didArg.toString] = row;
                                database = row["datname"].toString;
                            }
                        }
                        if (!dbInfo.has(didArg.toString))
                            throw new ObjectGone("Could not find the specified database.");
                    }
                }
            }
        }
        auto ck = getCryptKey();
        if (!ck.present && (cfgBool("SERVER_MODE") || !cfgBool("USE_OS_SECRET_STORAGE")))
            throw new CryptKeyMissing();
        if (database is null)
            throw new ConnectionLost(sid, null, null);

        auto myId = connId !is null ? CONN_STRING ~ connId : DB_STRING ~ database;
        pinged = nowSeconds();
        if (auto p = myId in connections)
            return *p;
        bool isAsync = async_.isNone ? connId !is null : async_.truthy;
        auto c = new Connection(this, myId, database, autoReconnect, isAsync, useBinaryPlaceholder, arrayToString);
        connections[myId] = c;
        connectionOrder ~= myId;
        return c;
    }

    /// `release(database, conn_id, did)`
    bool release(string database = null, string connId = null, Value didArg = Value(null))
    {
        string myId;
        if (!didArg.isNone)
        {
            if (dbInfo.has(didArg.toString) && dbInfo[didArg.toString].contains("datname"))
            {
                database = dbInfo[didArg.toString]["datname"].strOr(null);
                if (database is null)
                    return true;
            }
            else
                return true;
        }
        if (connId !is null)
            myId = CONN_STRING ~ connId;
        else if (database !is null)
            myId = DB_STRING ~ database;

        if (myId !is null)
        {
            if (auto p = myId in connections)
            {
                (*p).release();
                connections.remove(myId);
                if (!didArg.isNone)
                    dbInfo.pop(didArg.toString);
                if (connections.length == 0)
                    resetState();
                updateSession();
                return true;
            }
            return false;
        }
        foreach (k; connections.keys)
        {
            auto c = connections[k];
            if (c.connected() && c.connId.startsWith(CONN_STRING))
            {
                try
                    c.cancelTransaction(c.connId[CONN_STRING.length .. $]);
                catch (Exception)
                {
                }
            }
            c.release();
        }
        connections = null;
        resetState();
        updateSession();
        return true;
    }

    private void resetState()
    {
        ver = null;
        sversion = 0;
        serverType = null;
        serverCls = null;
        password = null;
    }

    void updateSession()
    {
        // Connections live in this process; nothing is persisted in the session (see README).
    }

    /// `utility(operation)`: the path of pg_dump & co. for this server.
    string utility(string operation)
    {
        import pgadmin.utils.binary_paths : utilityPath;
        return serverCls is null ? null : utilityPath(serverType, operation, sversion);
    }

    /// `export_password_env(env)`: the decrypted password (or the passexec output) under the variable `envName`.
    void exportPasswordEnv(string envName, ref string[string] env)
    {
        if (password.length)
        {
            auto ck = getCryptKey();
            if (!ck.present)
                return;
            env[envName] = decryptStr(password, ck.key);
        }
        else if (passexecCmd.length)
            env[envName] = runPassexec();
    }

    Value connectionParam(string pname)
    {
        if (connectionParams.isDict && connectionParams.dict.has(pname))
            return connectionParams.dict[pname];
        return Value(null);
    }

    string runPassexec()
    {
        import pgadmin.utils.passexec : getPassexecPassword;
        return getPassexecPassword(passexecCmd, host, port.toString, user, passexecExpiration);
    }

    /// `create_connection_string`
    string createConnectionString(string database, string dbUser, string pwd = null)
    {
        string[2][] args;
        string[2][] display;
        void add(string k, string v)
        {
            args ~= [k, v];
            display ~= [k, v];
        }

        add("host", host);
        add("port", port.isNone ? null : port.toString);
        add("dbname", database);
        add("user", dbUser);
        if (service.length)
            add("service", service);
        if (pwd.length)
        {
            display ~= ["password", "xxxxxxx"];
            args ~= ["password", pwd];
        }
        if (connectionParams.isDict)
        {
            foreach (k, v; connectionParams.dict)
            {
                Value value = v;
                bool withPath;
                if (["passfile", "sslcert", "sslkey", "sslcrl", "sslcrldir"].canFind(k) || (k == "sslrootcert" && v.toString != "system"))
                {
                    withPath = true;
                    import pgadmin.utils.paths : getCompleteFilePath;
                    auto fp = getCompleteFilePath(v.toString);
                    value = fp is null ? Value(null) : Value(fp);
                }
                if (k == "sslcompression" || k == "sslsni")
                    value = Value(v.truthy ? 1 : 0);
                string sv = value.isNone ? null : (value.isBool ? (value.boolean ? "1" : "0") : value.toString);
                setPair(args, k, sv);
                setPair(display, k, withPath ? v.toString : sv);
            }
        }
        foreach (kd; [["keepalives", "1"], ["keepalives_idle", "30"], ["keepalives_interval", "10"], ["keepalives_count", "3"]])
        {
            bool has;
            foreach (p; args)
                if (p[0] == kd[0])
                    has = true;
            if (!has)
                args ~= [kd[0], kd[1]];
        }
        displayConnectionString = makeConninfo(display);
        return makeConninfo(args);
    }

    private static void setPair(ref string[2][] list, string k, string v)
    {
        foreach (ref p; list)
            if (p[0] == k)
            {
                p[1] = v;
                return;
            }
        list ~= [k, v];
    }
}

private long nowSeconds()
{
    import std.datetime : Clock;
    return Clock.currTime.toUnixTime;
}

// ------------------------------------------------------------ Driver

/// `get_driver(PG_DEFAULT_DRIVER)`: connection managers per web session.
final class Driver
{
    private ServerManager[string][string] managers; // session sid -> server id -> manager

    /// `connection_manager(sid)`. Python returns None for an unknown server in desktop mode and the callers then fail
    /// with an AttributeError (a 500); a null dereference would crash the whole process here, so this throws the same
    /// error. Callers that handle the None case use `connectionManagerOrNull`.
    ServerManager connectionManager(long sid)
    {
        auto m = connectionManagerOrNull(sid);
        if (m is null)
            throw new Exception("'NoneType' object has no attribute 'connection'");
        return m;
    }

    ServerManager connectionManagerOrNull(long sid)
    {
        import pgadmin.web.context : session;
        Value serverData;
        if (cfgBool("SERVER_MODE"))
        {
            if (!isAuthenticated())
                throw new ObjectGone("Server not found.");
            serverData = getServer(sid);
            if (serverData.isNone)
                throw new ObjectGone("Server not found.");
        }
        else
        {
            serverData = serverById(sid);
            if (serverData.isNone)
                return null;
        }
        auto ssid = session().sid;
        auto per = ssid in managers;
        if (per is null)
        {
            managers[ssid] = null;
            per = ssid in managers;
        }
        auto key = to!string(sid);
        if (auto m = key in *per)
        {
            (*m).pinged = nowSeconds();
            return *m;
        }
        auto m = new ServerManager(serverData);
        if (cfgBool("SERVER_MODE") && serverData.get("shared").truthy && serverData["user_id"].integer != currentUserId())
            m.passexecCmd = null;
        (*per)[key] = m;
        return m;
    }

    Connection getConnection(long sid, string database = null, string connId = null, bool autoReconnect = true)
    {
        return connectionManager(sid).connection(database, connId, autoReconnect);
    }

    bool releaseConnection(long sid, string database = null, string connId = null)
    {
        return connectionManager(sid).release(database, connId);
    }

    void deleteManager(long sid)
    {
        auto m = connectionManagerOrNull(sid);
        if (m !is null)
            m.release();
        if (auto per = session().sid in managers)
            (*per).remove(to!string(sid));
    }

    /// Releases the connections of sessions idle for more than MAX_SESSION_IDLE_TIME.
    void gcTimeout()
    {
        long maxIdle = cfgInt("MAX_SESSION_IDLE_TIME");
        if (maxIdle == 0)
            maxIdle = 60;
        if (maxIdle < 20)
            maxIdle = 20;
        auto now = nowSeconds();
        foreach (ssid, per; managers)
        {
            if (ssid == session().sid)
                continue;
            foreach (k, m; per)
                if (now - m.pinged >= maxIdle * 60)
                    m.release();
        }
    }

    /// Releases every connection of the current session (logout).
    void gcOwn()
    {
        if (auto per = session().sid in managers)
            foreach (k, m; *per)
                m.release();
    }

    string libpqVersion()
    {
        loadLibpq();
        return to!string(pq.PQlibVersion());
    }
}

private __gshared Driver driver_;

Driver getDriver()
{
    if (driver_ is null)
        driver_ = new Driver;
    return driver_;
}

/// `server_access.get_server(sid, only_owned)`
Value getServer(long sid, bool onlyOwned = false)
{
    if (!cfgBool("SERVER_MODE"))
        return serverById(sid);
    if (onlyOwned)
        return db.queryOne("SELECT * FROM server WHERE id = ? AND user_id = ?", Value(sid), Value(currentUserId()));
    return db.queryOne("SELECT * FROM server WHERE id = ? AND (user_id = ? OR shared)", Value(sid), Value(currentUserId()));
}
