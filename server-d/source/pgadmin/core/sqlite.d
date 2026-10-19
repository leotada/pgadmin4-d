/// Minimal SQLite binding (dlopen) for pgAdmin's configuration database.
///
/// Rows come back as `Value` dicts keyed by column name, which is how the ported code uses SQLAlchemy model objects.
/// Calls block; they are short (local file) and pgAdmin does the same.
module pgadmin.core.sqlite;

import core.sys.posix.dlfcn : dlopen, dlsym, RTLD_NOW;
import std.conv : to;
import std.string : toStringz;
import pgadmin.core.value;

private struct sqlite3;
private struct sqlite3_stmt;

private enum
{
    SQLITE_OK = 0,
    SQLITE_ROW = 100,
    SQLITE_DONE = 101,
    SQLITE_INTEGER = 1,
    SQLITE_FLOAT = 2,
    SQLITE_TEXT = 3,
    SQLITE_BLOB = 4,
    SQLITE_NULL = 5,
    SQLITE_OPEN_READWRITE = 0x02,
    SQLITE_OPEN_CREATE = 0x04,
    SQLITE_OPEN_FULLMUTEX = 0x00010000,
}

private struct Api
{
    extern (C) nothrow @nogc:
    int function(const(char)*, sqlite3**, int, const(char)*) sqlite3_open_v2;
    int function(sqlite3*) sqlite3_close_v2;
    int function(sqlite3*, const(char)*, int, sqlite3_stmt**, const(char)**) sqlite3_prepare_v2;
    int function(sqlite3_stmt*) sqlite3_step;
    int function(sqlite3_stmt*) sqlite3_finalize;
    int function(sqlite3_stmt*) sqlite3_reset;
    int function(sqlite3_stmt*, int, long) sqlite3_bind_int64;
    int function(sqlite3_stmt*, int, double) sqlite3_bind_double;
    int function(sqlite3_stmt*, int, const(char)*, int, void*) sqlite3_bind_text;
    int function(sqlite3_stmt*, int) sqlite3_bind_null;
    int function(sqlite3_stmt*) sqlite3_column_count;
    const(char)* function(sqlite3_stmt*, int) sqlite3_column_name;
    const(char)* function(sqlite3_stmt*, int) sqlite3_column_decltype;
    int function(sqlite3_stmt*, int) sqlite3_column_type;
    long function(sqlite3_stmt*, int) sqlite3_column_int64;
    double function(sqlite3_stmt*, int) sqlite3_column_double;
    const(char)* function(sqlite3_stmt*, int) sqlite3_column_text;
    int function(sqlite3_stmt*, int) sqlite3_column_bytes;
    const(char)* function(sqlite3*) sqlite3_errmsg;
    long function(sqlite3*) sqlite3_last_insert_rowid;
    int function(sqlite3*) sqlite3_changes;
    int function(sqlite3*, int) sqlite3_busy_timeout;
}

private __gshared Api api;
private __gshared bool apiLoaded;

private void loadApi() @trusted
{
    if (apiLoaded)
        return;
    void* h;
    foreach (n; ["libsqlite3.so.0\0", "libsqlite3.so\0", "libsqlite3.dylib\0"])
        if ((h = dlopen(n.ptr, RTLD_NOW)) !is null)
            break;
    if (h is null)
        throw new SqliteError("libsqlite3 not found");
    static foreach (m; __traits(allMembers, Api))
    {
        {
            auto p = dlsym(h, (m ~ "\0").ptr);
            if (p is null)
                throw new SqliteError("missing symbol in libsqlite3: " ~ m);
            __traits(getMember, api, m) = cast(typeof(__traits(getMember, api, m))) p;
        }
    }
    apiLoaded = true;
}

class SqliteError : Exception
{
    int code;
    this(string msg, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line);
    }
}

/// A constraint violation (UNIQUE, FOREIGN KEY, NOT NULL), `sqlalchemy.exc.IntegrityError`.
class SqliteIntegrity : SqliteError
{
    this(string msg, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line);
    }
}

private enum SQLITE_TRANSIENT = cast(void*)-1;

/// A connection to the configuration database.
final class SqliteDb
{
    private sqlite3* db;
    string path;
    /// Columns declared as JSON are parsed into dicts/lists; BOOLEAN columns become bools.
    bool convertTypes = true;

    this(string path, int busyTimeoutMs = 500) @trusted
    {
        loadApi();
        this.path = path;
        if (api.sqlite3_open_v2(path.toStringz, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                null) != SQLITE_OK)
            throw new SqliteError("could not open " ~ path ~ ": " ~ errmsg());
        api.sqlite3_busy_timeout(db, busyTimeoutMs);
        exec("PRAGMA foreign_keys = ON");
    }

    void close() @trusted
    {
        if (db !is null)
        {
            api.sqlite3_close_v2(db);
            db = null;
        }
    }

    private string errmsg() @trusted
    {
        import std.string : fromStringz;
        return db is null ? "out of memory" : api.sqlite3_errmsg(db).fromStringz.idup;
    }

    private sqlite3_stmt* prepare(string sql, Value[] params) @trusted
    {
        sqlite3_stmt* st;
        if (api.sqlite3_prepare_v2(db, sql.ptr, cast(int) sql.length, &st, null) != SQLITE_OK)
            throw new SqliteError(errmsg() ~ " [" ~ sql ~ "]");
        foreach (i, p; params)
        {
            int idx = cast(int) i + 1;
            int rc;
            final switch (p.type)
            {
            case VType.none:
                rc = api.sqlite3_bind_null(st, idx);
                break;
            case VType.boolean:
                rc = api.sqlite3_bind_int64(st, idx, p.boolean ? 1 : 0);
                break;
            case VType.integer:
                rc = api.sqlite3_bind_int64(st, idx, p.integer);
                break;
            case VType.floating:
                rc = api.sqlite3_bind_double(st, idx, p.floating);
                break;
            case VType.str:
                auto s = p.str;
                rc = api.sqlite3_bind_text(st, idx, s.ptr, cast(int) s.length, SQLITE_TRANSIENT);
                break;
            case VType.list, VType.dict:
                auto s = p.toJsonSpaced();
                rc = api.sqlite3_bind_text(st, idx, s.ptr, cast(int) s.length, SQLITE_TRANSIENT);
                break;
            case VType.func, VType.object:
                auto s = p.toString();
                rc = api.sqlite3_bind_text(st, idx, s.ptr, cast(int) s.length, SQLITE_TRANSIENT);
                break;
            }
            if (rc != SQLITE_OK)
            {
                api.sqlite3_finalize(st);
                throw new SqliteError(errmsg());
            }
        }
        return st;
    }

    /// Runs a statement; returns the number of changed rows.
    int exec(string sql, Value[] params...) @trusted
    {
        auto st = prepare(sql, params.dup);
        scope (exit)
            api.sqlite3_finalize(st);
        int rc;
        while ((rc = api.sqlite3_step(st)) == SQLITE_ROW)
        {
        }
        if (rc != SQLITE_DONE)
            throw makeError(rc, sql);
        return api.sqlite3_changes(db);
    }

    /// Runs several `;`-separated statements without parameters.
    void execScript(string sql) @trusted
    {
        import std.array : split;
        import std.string : strip;
        foreach (s; sql.split(";\n"))
            if (s.strip.length)
                exec(s.strip);
    }

    private SqliteError makeError(int rc, string sql) @trusted
    {
        // extended result codes are off: the primary code of a constraint failure is SQLITE_CONSTRAINT (19)
        auto msg = errmsg() ~ " [" ~ sql ~ "]";
        if ((rc & 0xff) == 19)
            return new SqliteIntegrity(msg);
        return new SqliteError(msg);
    }

    long lastInsertId() @trusted => api.sqlite3_last_insert_rowid(db);

    /// All rows as dicts.
    Value[] query(string sql, Value[] params...) @trusted
    {
        import std.string : fromStringz, toLower, indexOf;
        auto st = prepare(sql, params.dup);
        scope (exit)
            api.sqlite3_finalize(st);
        Value[] rows;
        immutable n = api.sqlite3_column_count(st);
        string[] names;
        string[] decl;
        foreach (c; 0 .. n)
        {
            names ~= api.sqlite3_column_name(st, c).fromStringz.idup;
            auto dt = api.sqlite3_column_decltype(st, c);
            decl ~= dt is null ? "" : dt.fromStringz.idup.toLower;
        }
        int rc;
        while ((rc = api.sqlite3_step(st)) == SQLITE_ROW)
        {
            auto d = new Dict;
            foreach (c; 0 .. n)
            {
                Value v;
                switch (api.sqlite3_column_type(st, c))
                {
                case SQLITE_INTEGER:
                    auto i = api.sqlite3_column_int64(st, c);
                    if (convertTypes && decl[c] == "boolean")
                        v = Value(i != 0);
                    else
                        v = Value(i);
                    break;
                case SQLITE_FLOAT:
                    v = Value(api.sqlite3_column_double(st, c));
                    break;
                case SQLITE_TEXT, SQLITE_BLOB:
                    auto p = api.sqlite3_column_text(st, c);
                    auto len = api.sqlite3_column_bytes(st, c);
                    auto s = p is null ? "" : p[0 .. len].idup;
                    if (convertTypes && decl[c] == "json")
                        v = tryParseJson(s, Value(s));
                    else if (convertTypes && decl[c] == "boolean")
                        v = Value(s == "1" || s == "true");
                    else
                        v = Value(s);
                    break;
                default:
                    v = Value(null);
                }
                d[names[c]] = v;
            }
            rows ~= Value(d);
        }
        if (rc != SQLITE_DONE)
            throw new SqliteError(errmsg() ~ " [" ~ sql ~ "]");
        return rows;
    }

    /// First row or None.
    Value queryOne(string sql, Value[] params...)
    {
        auto r = query(sql, params);
        return r.length ? r[0] : Value(null);
    }

    /// First column of the first row, or None.
    Value scalar(string sql, Value[] params...)
    {
        auto r = query(sql, params);
        if (r.length == 0)
            return Value(null);
        foreach (k, v; r[0].dict)
            return v;
        return Value(null);
    }

    /// Runs `fn` in a transaction (rolled back if it throws).
    void transaction(scope void delegate() fn)
    {
        exec("BEGIN");
        try
        {
            fn();
            exec("COMMIT");
        }
        catch (Throwable t)
        {
            try
                exec("ROLLBACK");
            catch (Exception)
            {
            }
            throw t;
        }
    }
}
