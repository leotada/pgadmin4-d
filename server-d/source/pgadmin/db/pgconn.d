/// Low-level PostgreSQL connection over async libpq, cooperative with andaime's fibers (`awaitFd`).
///
/// This replaces psycopg3 for pgAdmin: queries use the simple protocol (so multi-statement scripts work, as psycopg3
/// does when there are no parameters), and the result values are converted exactly as pgAdmin's type casters make them
/// (see `convertCell`): ints stay ints, bigint/numeric/float/dates/json become strings, supported arrays become lists.
module pgadmin.db.pgconn;

import core.time : Duration, MonoTime, msecs, seconds;
import std.algorithm : canFind, startsWith, endsWith;
import std.array : appender, join;
import std.conv : to;
import std.string : toStringz, strip, toLower, indexOf, fromStringz;
import andaime.engine.fiberio : awaitFd, IoEvent;
import andaime.engine.offload : offload;
import pgadmin.core.value;
import pgadmin.db.libpq;

/// A server error (psycopg.Error): the pieces of the diagnostics, formatted like pgAdmin's `_formatted_exception_msg`.
class PgError : Exception
{
    string sqlstate;
    string severity;
    string primary;
    string detail;
    string hint;
    string position;
    string context;
    string fullMessage; /// libpq's `PQerrorMessage` text ("ERROR:  ...\n")
    bool connectionLost;

    this(string msg, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line);
        fullMessage = msg;
    }
}

/// Column metadata (a psycopg `Column` plus pgAdmin's `_WrapperColumn.to_dict()`).
struct Column
{
    string name;        /// unique display name (duplicates get "-1", "-2"...)
    string displayName; /// the name sent by the server
    uint typeCode;
    Value displaySize = Value(null);
    Value internalSize = Value(null);
    Value precision = Value(null);
    Value scale = Value(null);
    uint tableOid;
    int tableColumn;

    Value toDict()
    {
        auto d = new Dict;
        d["name"] = name;
        d["type_code"] = Value(typeCode);
        d["display_size"] = displaySize;
        d["internal_size"] = internalSize;
        d["precision"] = precision;
        d["scale"] = scale;
        d["null_ok"] = Value(null);
        d["table_oid"] = Value(tableOid);
        d["table_column"] = Value(tableColumn);
        d["display_name"] = displayName;
        return Value(d);
    }
}

/// One result set.
final class PgResult
{
    Column[] columns;
    Value[][] rows;       /// row-major, already converted
    bool hasDescription;  /// the statement returns rows (even when 0)
    long rowcount;        /// rows returned, or affected by INSERT/UPDATE/DELETE
    string statusMessage; /// "SELECT 3", "INSERT 0 1"
    ExecStatus status;
    /// the raw text of bytea cells (row * columns + column) when the connection shows them as 'binary data'
    string[size_t] rawCells;

    /// Rows as dicts keyed by column name (duplicates collapse to the last one, like psycopg's dict_row).
    Value[] asDicts()
    {
        Value[] r;
        r.reserve(rows.length);
        foreach (row; rows)
        {
            auto d = new Dict;
            foreach (i, c; columns)
                d[c.displayName] = row[i];
            r ~= Value(d);
        }
        return r;
    }

    /// Rows as lists of values.
    Value[] asLists()
    {
        Value[] r;
        r.reserve(rows.length);
        foreach (row; rows)
            r ~= Value(row.dup);
        return r;
    }
}

// ------------------------------------------------------------ type conversion

/// OIDs whose text value is passed through (pgAdmin registers TextLoaderpgAdmin for them) and arrays that stay strings.
private immutable uint[] toStringTypes = [
    17, 1186, 1082, 1114, 1184, 1083, // bytea, interval, date, timestamp, timestamptz, time
    700, 701, 1700, 20,               // float4, float8, numeric, int8
    3904, 3926, 3906, 3912, 3908, 3910,                 // ranges
    4535, 4451, 4536, 4532, 4533, 4534,                 // multiranges
    114, 3802, 2287,                                    // json, jsonb, record[]
    1001, 1016, 1022, 1021, 1561, 1563,                 // arrays kept as strings
];

private immutable uint[] arrayToStringExtra = [
    1016, 1005, 1006, 1007, 1021, 1022, 1231, 1002, 1003, 1009, 1014, 1015, 1000, 1115, 1185, 1183, 1270, 1182, 1187,
    1001, 1028, 1013, 1041, 651, 1040, 199, 3807, 2951, 3905, 3927, 3907, 3913, 3909, 3911, 6155, 6150, 6157, 6151,
    6152, 6153, 1561, 1563,
];

/// array oid -> element oid (psycopg's builtin registry).
private immutable uint[2][] arrayElements = [
    [1000, 16], [1001, 17], [1002, 18], [1003, 19], [1016, 20], [1005, 21], [1006, 22], [1007, 23], [1008, 24],
    [1009, 25], [1028, 26], [1010, 27], [1011, 28], [1012, 29], [1013, 30], [199, 114], [143, 142], [1017, 600],
    [1018, 601], [1019, 602], [1020, 603], [1027, 604], [629, 628], [651, 650], [1021, 700], [1022, 701], [719, 718],
    [775, 774], [791, 790], [1040, 829], [1041, 869], [1034, 1033], [1014, 1042], [1015, 1043], [1182, 1082],
    [1183, 1083], [1115, 1114], [1185, 1184], [1187, 1186], [1270, 1266], [1561, 1560], [1563, 1562], [1231, 1700],
    [2201, 1790], [2207, 2202], [2208, 2203], [2209, 2204], [2210, 2205], [2211, 2206], [2287, 2249], [2951, 2950],
    [2949, 2970], [3221, 3220], [3643, 3614], [3645, 3615], [3644, 3642], [3735, 3734], [3770, 3769], [3807, 3802],
    [3905, 3904], [3907, 3906], [3909, 3908], [3911, 3910], [3913, 3912], [3927, 3926], [4073, 4072], [4090, 4089],
    [4097, 4096], [4192, 4191], [6150, 4451], [6151, 4532], [6152, 4533], [6153, 4534], [6155, 4535], [6157, 4536],
    [271, 5069],
];

private uint elementOf(uint arrayOid)
{
    foreach (p; arrayElements)
        if (p[0] == arrayOid)
            return p[1];
    return 0;
}

/// Converts the server text of one cell as pgAdmin's psycopg type casters do.
Value convertCell(uint oid, const(char)[] t, bool arrayToString = false, bool binaryPlaceholder = false)
{
    if (binaryPlaceholder && (oid == 17 || oid == 1001))
        return Value("binary data");
    auto elem = elementOf(oid);
    if (elem != 0)
    {
        if (toStringTypes.canFind(oid) || (arrayToString && arrayToStringExtra.canFind(oid)))
            return Value(t.idup);
        if (t.length && t[0] == '{')
        {
            size_t i;
            return parsePgArray(t, i, elem, oid);
        }
        return Value(t.idup);
    }
    return convertScalar(oid, t);
}

private Value convertScalar(uint oid, const(char)[] t)
{
    switch (oid)
    {
    case 16: // bool
        return Value(t.length && t[0] == 't');
    case 21, 23, 26: // int2, int4, oid
        try
            return Value(to!long(t));
        catch (Exception)
            return Value(t.idup);
    case 1266: // timetz: python's time isoformat has a full offset
        return Value(fixTimetz(t));
    case 2249: // record: psycopg returns a tuple of the fields as text
        return parseRecord(t);
    default:
        return Value(t.idup);
    }
}

private Value parseRecord(const(char)[] t)
{
    if (t.length < 2 || t[0] != '(' || t[$ - 1] != ')')
        return Value(t.idup);
    auto list = new List;
    list.tuple = true;
    size_t i = 1;
    auto end = t.length - 1;
    for (;;)
    {
        if (i >= end || t[i] == ',')
        {
            list.items ~= Value(null);   // empty field = NULL
        }
        else if (t[i] == '"')
        {
            i++;
            auto a = appender!string;
            while (i < end)
            {
                if (t[i] == '"')
                {
                    if (i + 1 < end && t[i + 1] == '"')
                    {
                        a.put('"');
                        i += 2;
                        continue;
                    }
                    i++;
                    break;
                }
                if (t[i] == '\\' && i + 1 < end)
                    i++;
                a.put(t[i]);
                i++;
            }
            list.items ~= Value(a.data);
        }
        else
        {
            size_t st = i;
            while (i < end && t[i] != ',')
                i++;
            list.items ~= Value(t[st .. i].idup);
        }
        if (i < end && t[i] == ',')
        {
            i++;
            if (i >= end)
            {
                list.items ~= Value(null);
                break;
            }
            continue;
        }
        break;
    }
    return Value(list);
}

private string fixTimetz(const(char)[] t)
{
    // "03:04:00+01" -> "03:04:00+01:00"
    auto s = t.idup;
    foreach_reverse (i, c; s)
    {
        if (c == '+' || c == '-')
        {
            auto off = s[i + 1 .. $];
            if (off.length == 2)
                return s ~ ":00";
            if (off.length == 4 && off[2] != ':')
                return s[0 .. i + 3] ~ ":" ~ s[i + 3 .. $];
            break;
        }
    }
    return s;
}

private Value parsePgArray(const(char)[] t, ref size_t i, uint elemOid, uint arrayOid)
{
    // t[i] == '{'
    i++;
    auto list = new List;
    while (i < t.length)
    {
        char c = t[i];
        if (c == '}')
        {
            i++;
            return Value(list);
        }
        if (c == ',')
        {
            i++;
            continue;
        }
        if (c == '{')
        {
            list.items ~= parsePgArray(t, i, elemOid, arrayOid);
            continue;
        }
        if (c == '"')
        {
            i++;
            auto a = appender!string;
            while (i < t.length && t[i] != '"')
            {
                if (t[i] == '\\' && i + 1 < t.length)
                    i++;
                a.put(t[i]);
                i++;
            }
            i++;
            list.items ~= convertScalar(elemOid, a.data);
            continue;
        }
        size_t st = i;
        while (i < t.length && t[i] != ',' && t[i] != '}')
            i++;
        auto raw = t[st .. i];
        if (raw == "NULL")
            list.items ~= Value(null);
        else
            list.items ~= convertScalar(elemOid, raw);
    }
    return Value(list);
}

// ------------------------------------------------------------ type modifiers (psycopg _typemod)

private struct TypeMods
{
    Value displaySize = Value(null);
    Value precision = Value(null);
    Value scale = Value(null);
}

private TypeMods typeMods(uint oid, int fmod)
{
    TypeMods m;
    switch (oid)
    {
    case 1700: // numeric
        if (fmod >= 0)
        {
            m.precision = Value(fmod >> 16);
            int sc = (fmod - 4) & 0xFFFF;
            if (sc >= 0x400)
                sc -= 0x800;
            m.scale = Value(sc);
        }
        break;
    case 1042, 1043: // bpchar, varchar
        if (fmod >= 0)
            m.displaySize = Value(fmod - 4);
        break;
    case 1560, 1562: // bit, varbit
        if (fmod >= 0)
            m.displaySize = Value(fmod);
        break;
    case 1083, 1114, 1184, 1186, 1266: // time-related
        if (fmod >= 0)
            m.precision = Value(fmod & 0xFFFF);
        break;
    default:
        break;
    }
    return m;
}

// ------------------------------------------------------------ the connection

/// A libpq connection. Not thread-safe; one fiber uses it at a time.
final class PgConnection
{
    private PGconn* c;
    string[] notices;
    PgNotify[] notifies;
    bool arrayToString;
    /// bytea cells come back as the text 'binary data' (the Query Tool's `use_binary_placeholder`)
    bool binaryPlaceholder;
    /// each column reports its own table oid/column (the async cursor); the sync cursor repeats column 0's
    bool perColumnTableInfo;
    /// every result set of the last `execute`
    PgResult[] allResults;
    private bool inUse;

    struct PgNotify
    {
        string channel;
        string payload;
        int pid;
    }

    private this(PGconn* c)
    {
        this.c = c;
    }

    ~this()
    {
        close();
    }

    bool closed() const => c is null || pq.PQstatus(c) != ConnStatus.ok;

    void close() @trusted
    {
        if (c !is null)
        {
            pq.PQfinish(c);
            c = null;
        }
    }

    /// Opens a connection without blocking the worker. `conninfo` is a libpq keyword/value string.
    static PgConnection connect(string conninfo, Duration timeout = 30.seconds) @trusted
    {
        if (auto err = loadLibpq())
            throw new PgError(err);
        auto z = conninfo ~ '\0';
        // PQconnectStart resolves the host name synchronously: do it on a pool thread
        PGconn* h = offload(() @trusted => pq.PQconnectStart(z.ptr));
        if (h is null)
            throw new PgError("out of memory");
        auto conn = new PgConnection(h);
        scope (failure)
            conn.close();
        if (pq.PQstatus(h) == ConnStatus.bad)
            throw new PgError(conn.lastError());
        pq.PQsetnonblocking(h, 1);
        pq.PQsetNoticeReceiver(h, &noticeReceiver, cast(void*) conn);

        immutable deadline = MonoTime.currTime + timeout;
        int state = PollingStatus.writing;
        for (;;)
        {
            auto left = deadline - MonoTime.currTime;
            if (left <= Duration.zero)
                throw new PgError("timeout expired");
            auto fd = pq.PQsocket(h);
            if (fd < 0)
                throw new PgError(conn.lastError());
            if (state == PollingStatus.reading)
            {
                if (awaitFd(fd, IoEvent.readable, left) == 0)
                    throw new PgError("timeout expired");
            }
            else if (state == PollingStatus.writing)
            {
                if (awaitFd(fd, IoEvent.writable, left) == 0)
                    throw new PgError("timeout expired");
            }
            state = pq.PQconnectPoll(h);
            if (state == PollingStatus.ok)
                break;
            if (state == PollingStatus.failed)
                throw new PgError(conn.connectFailedMessage());
        }
        return conn;
    }

    /// psycopg's "connection failed: connection to server at "host", port N failed: ..." (older libpq versions omit
    /// the middle part for errors reported by the server).
    private string connectFailedMessage() @trusted
    {
        import std.algorithm : startsWith;
        auto m = lastError();
        if (!m.startsWith("connection to server"))
        {
            auto host = dstr(pq.PQhost(c));
            auto port = dstr(pq.PQport(c));
            m = "connection to server at \"" ~ host ~ "\", port " ~ port ~ " failed: " ~ m;
        }
        return "connection failed: " ~ m;
    }

    /// psycopg's `pgconn.error_message`
    string lastErrorMessage() @trusted => c is null ? "" : lastError();

    private string lastError() @trusted
    {
        return stripEol(dstr(pq.PQerrorMessage(c)));
    }

    // ------------------------------------------------------------ info

    int backendPid() @trusted => pq.PQbackendPID(c);
    int serverVersion() @trusted => pq.PQserverVersion(c);
    TxStatus transactionStatus() @trusted => c is null ? TxStatus.unknown : cast(TxStatus) pq.PQtransactionStatus(c);
    string user() @trusted => dstr(pq.PQuser(c));
    string host() @trusted => dstr(pq.PQhost(c));
    string dbname() @trusted => dstr(pq.PQdb(c));
    string port() @trusted => dstr(pq.PQport(c));
    string parameterStatus(string name) @trusted => dstr(pq.PQparameterStatus(c, name.toStringz));
    string clientEncoding() @trusted => dstr(pq.pg_encoding_to_char(pq.PQclientEncoding(c)));
    bool busy() @trusted => pq.PQisBusy(c) != 0;

    /// `PQencryptPasswordConn`.
    string encryptPassword(string password, string user, string algorithm) @trusted
    {
        auto r = pq.PQencryptPasswordConn(c, password.toStringz, user.toStringz, algorithm is null ? null : algorithm.toStringz);
        if (r is null)
            return null;
        auto s = dstr(r);
        pq.PQfreemem(r);
        return s;
    }

    // ------------------------------------------------------------ execution

    /// Waiting for results of a query started with `send`.
    private void flush(MonoTime deadline) @trusted
    {
        for (;;)
        {
            immutable f = pq.PQflush(c);
            if (f == 0)
                return;
            if (f < 0)
                throw lost(lastError());
            auto left = remaining(deadline);
            if (awaitFd(pq.PQsocket(c), IoEvent.writable | IoEvent.readable, left) == 0)
                throw new PgError("query timed out");
            if (!pq.PQconsumeInput(c))
                throw lost(lastError());
        }
    }

    private void waitResult(MonoTime deadline) @trusted
    {
        while (pq.PQisBusy(c))
        {
            if (awaitFd(pq.PQsocket(c), IoEvent.readable, remaining(deadline)) == 0)
                throw new PgError("query timed out");
            if (!pq.PQconsumeInput(c))
                throw lost(lastError());
        }
    }

    private static Duration remaining(MonoTime deadline)
    {
        if (deadline == MonoTime.max)
            return Duration.max;
        auto d = deadline - MonoTime.currTime;
        return d <= Duration.zero ? Duration.zero : d;
    }

    private PgError lost(string msg)
    {
        auto e = new PgError(msg);
        e.connectionLost = true;
        return e;
    }

    /// Sends `sql` with the simple query protocol; results are read with `nextResult`.
    void send(string sql) @trusted
    {
        if (closed)
            throw lost("the connection is closed");
        auto z = sql ~ '\0';
        if (!pq.PQsendQuery(c, z.ptr))
            throw lost(lastError());
        flush(MonoTime.max);
    }

    /// Reads the next result of a started query; null when there are no more.
    PgResult nextResult(MonoTime deadline = MonoTime.max) @trusted
    {
        waitResult(deadline);
        auto r = pq.PQgetResult(c);
        if (r is null)
            return null;
        scope (exit)
            pq.PQclear(r);
        return buildResult(r);
    }

    /// Runs `sql` to completion. Returns the first and the last result sets (equal for a single statement).
    /// Throws `PgError` for a failed statement (after draining the remaining results).
    void execute(string sql, out PgResult first, out PgResult last, Duration timeout = Duration.max) @trusted
    {
        immutable deadline = timeout == Duration.max ? MonoTime.max : MonoTime.currTime + timeout;
        send(sql);
        allResults = null;
        PgError err;
        bool clean;
        scope (exit)
            if (!clean)
                abortQuery();
        for (;;)
        {
            waitResult(deadline);
            auto r = pq.PQgetResult(c);
            if (r is null)
                break;
            auto st = cast(ExecStatus) pq.PQresultStatus(r);
            if (st == ExecStatus.fatalError || st == ExecStatus.badResponse)
            {
                if (err is null)
                    err = errorFrom(r);
                pq.PQclear(r);
                continue;
            }
            if (st == ExecStatus.copyIn || st == ExecStatus.copyOut || st == ExecStatus.copyBoth)
            {
                pq.PQclear(r);
                continue;
            }
            auto res = buildResult(r);
            pq.PQclear(r);
            allResults ~= res;
            if (first is null)
                first = res;
            last = res;
        }
        clean = true;
        collectNotifies();
        if (err !is null)
            throw err;
    }

    /// Cancels a query that was interrupted midway and closes the connection (it cannot be reused).
    private void abortQuery() @trusted
    {
        if (c is null)
            return;
        auto cancel = pq.PQgetCancel(c);
        if (cancel !is null)
        {
            char[256] buf;
            offload(() @trusted { pq.PQcancel(cancel, buf.ptr, cast(int) buf.length); });
            pq.PQfreeCancel(cancel);
        }
        close();
    }

    /// Asks the server to cancel the running query (from another thread/fiber).
    bool cancel() @trusted
    {
        if (c is null)
            return false;
        auto cancel = pq.PQgetCancel(c);
        if (cancel is null)
            return false;
        char[256] buf;
        auto ok = offload(() @trusted => pq.PQcancel(cancel, buf.ptr, cast(int) buf.length));
        pq.PQfreeCancel(cancel);
        return ok != 0;
    }

    private PgError errorFrom(PGresult* r) @trusted
    {
        // psycopg's `str(error)`: the server message without the severity header
        auto full = stripEol(dstr(pq.PQresultErrorMessage(r)));
        {
            import std.string : indexOf, strip;
            auto colon = full.indexOf(':');
            if (colon >= 0)
                full = full[colon + 1 .. $].strip;
        }
        auto e = new PgError(full);
        e.sqlstate = dstr(pq.PQresultErrorField(r, PG_DIAG_SQLSTATE));
        e.severity = dstr(pq.PQresultErrorField(r, PG_DIAG_SEVERITY));
        e.primary = dstr(pq.PQresultErrorField(r, PG_DIAG_MESSAGE_PRIMARY));
        e.detail = dstr(pq.PQresultErrorField(r, PG_DIAG_MESSAGE_DETAIL));
        e.hint = dstr(pq.PQresultErrorField(r, PG_DIAG_MESSAGE_HINT));
        e.position = dstr(pq.PQresultErrorField(r, PG_DIAG_STATEMENT_POSITION));
        e.context = dstr(pq.PQresultErrorField(r, PG_DIAG_CONTEXT));
        if (e.sqlstate.length == 0 && transactionStatus() == TxStatus.unknown)
            e.connectionLost = true;
        return e;
    }

    private PgResult buildResult(PGresult* r) @trusted
    {
        auto res = new PgResult;
        res.status = cast(ExecStatus) pq.PQresultStatus(r);
        res.statusMessage = dstr(pq.PQcmdStatus(r));
        auto tuples = dstr(pq.PQcmdTuples(r));
        immutable nf = pq.PQnfields(r);
        immutable nt = pq.PQntuples(r);
        res.hasDescription = res.status == ExecStatus.tuplesOk || res.status == ExecStatus.singleTuple
            || res.status == ExecStatus.tuplesChunk;
        if (res.hasDescription)
        {
            res.rowcount = nt;
            // unique names, as _WrapperColumn does
            int[string] od;
            foreach (i; 0 .. nf)
            {
                auto n = dstr(pq.PQfname(r, i));
                od[n] = 0;
            }
            foreach (i; 0 .. nf)
            {
                Column col;
                col.displayName = dstr(pq.PQfname(r, i));
                if (col.displayName.length == 0)
                    col.displayName = "column_" ~ to!string(i + 1);
                col.name = col.displayName;
                int idx = od[col.displayName];
                if (idx == 0)
                    od[col.displayName] = 1;
                else
                {
                    string nm = col.displayName;
                    while (nm in od)
                    {
                        idx++;
                        nm = col.displayName ~ "-" ~ to!string(idx);
                        od[col.displayName] = idx;
                    }
                    col.name = nm;
                }
                col.typeCode = pq.PQftype(r, i);
                auto fsize = pq.PQfsize(r, i);
                col.internalSize = fsize >= 0 ? Value(fsize) : Value(null);
                auto mods = typeMods(col.typeCode, pq.PQfmod(r, i));
                col.displaySize = mods.displaySize;
                col.precision = mods.precision;
                col.scale = mods.scale;
                // pgAdmin's cursor never advances its column counter, so every column reports column 0's table info
                col.tableOid = pq.PQftable(r, perColumnTableInfo ? i : 0);
                col.tableColumn = pq.PQftablecol(r, perColumnTableInfo ? i : 0);
                res.columns ~= col;
            }
            res.rows.reserve(nt);
            foreach (row; 0 .. nt)
            {
                auto vals = new Value[nf];
                foreach (col; 0 .. nf)
                {
                    if (pq.PQgetisnull(r, row, col))
                        vals[col] = Value(null);
                    else
                    {
                        auto p = pq.PQgetvalue(r, row, col);
                        auto len = pq.PQgetlength(r, row, col);
                        vals[col] = convertCell(res.columns[col].typeCode, p[0 .. len], arrayToString, binaryPlaceholder);
                        if (binaryPlaceholder && (res.columns[col].typeCode == 17 || res.columns[col].typeCode == 1001))
                            res.rawCells[cast(size_t) row * nf + col] = p[0 .. len].idup;
                    }
                }
                res.rows ~= vals;
            }
        }
        else
            res.rowcount = tuples.length ? to!long(tuples) : -1;
        return res;
    }

    private void collectNotifies() @trusted
    {
        if (c is null)
            return;
        pq.PQconsumeInput(c);
        while (auto n = pq.PQnotifies(c))
        {
            notifies ~= PgNotify(dstr(n.relname), dstr(n.extra), n.be_pid);
            pq.PQfreemem(n);
        }
    }

    /// Drains the notifications that arrived (without blocking).
    PgNotify[] takeNotifies() @trusted
    {
        collectNotifies();
        auto r = notifies;
        notifies = null;
        return r;
    }
}

private string stripEol(string s)
{
    while (s.length && (s[$ - 1] == '\n' || s[$ - 1] == '\r'))
        s = s[0 .. $ - 1];
    return s;
}

private extern (C) void noticeReceiver(void* arg, const(PGresult)* res) nothrow
{
    try
    {
        auto conn = cast(PgConnection) arg;
        auto sev = dstr(pq.PQresultErrorField(res, PG_DIAG_SEVERITY));
        auto msg = dstr(pq.PQresultErrorField(res, PG_DIAG_MESSAGE_PRIMARY));
        conn.notices ~= sev ~ ":  " ~ msg ~ "\n";
        if (conn.notices.length > 10_000)
            conn.notices = conn.notices[$ - 10_000 .. $];
    }
    catch (Throwable)
    {
    }
}

/// libpq keyword/value connection string (psycopg `make_conninfo`): values are quoted when needed.
string makeConninfo(string[2][] pairs)
{
    string[] parts;
    foreach (p; pairs)
    {
        if (p[1] is null)
            continue;
        parts ~= p[0] ~ "=" ~ quoteConninfoValue(p[1]);
    }
    return parts.join(" ");
}

private string quoteConninfoValue(string v)
{
    if (v.length == 0)
        return "''";
    bool needs;
    foreach (c; v)
        if (c == ' ' || c == '\'' || c == '\\' || c == '\t' || c == '\n' || c == '\r' || c == '=')
            needs = true;
    if (!needs)
        return v;
    string r = "'";
    foreach (c; v)
    {
        if (c == '\'' || c == '\\')
            r ~= '\\';
        r ~= c;
    }
    return r ~ "'";
}


/// `psycopg.conninfo.conninfo_to_dict`: the keywords set in `conninfo`, in libpq's own option order.
string[2][] conninfoToDict(string conninfo) @trusted
{
    if (auto err = loadLibpq())
        throw new PgError(err);
    char* errmsg;
    auto z = conninfo ~ '\0';
    auto opts = pq.PQconninfoParse(z.ptr, &errmsg);
    if (opts is null)
    {
        string m = errmsg is null ? "invalid connection string" : dstr(errmsg);
        if (errmsg !is null)
            pq.PQfreemem(errmsg);
        throw new PgError(m);
    }
    scope (exit)
        pq.PQconninfoFree(opts);
    string[2][] r;
    for (auto o = opts; o.keyword !is null; o++)
        if (o.val !is null)
            r ~= [dstr(o.keyword), dstr(o.val)];
    return r;
}
