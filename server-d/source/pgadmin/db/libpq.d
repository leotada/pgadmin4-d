/// libpq binding, loaded at run time (dlopen), for pgAdmin's database driver.
///
/// The function table lives in a struct held by a `__gshared` instance: loose `extern (C)` function-pointer variables
/// would become global symbols with libpq's names and the dynamic linker would bind libpq's own calls to them.
module pgadmin.db.libpq;

import core.sys.posix.dlfcn : dlopen, dlsym, RTLD_NOW;

struct PGconn;
struct PGresult;
struct PGcancel;

/// `PQconninfoOption`
struct PQconninfoOption
{
    char* keyword;
    char* envvar;
    char* compiled;
    char* val;
    char* label;
    char* dispchar;
    int dispsize;
}

struct PGnotify
{
    char* relname;
    int be_pid;
    char* extra;
    PGnotify* next;
}

enum ConnStatus : int
{
    ok = 0,
    bad = 1,
}

enum PollingStatus : int
{
    failed = 0,
    reading = 1,
    writing = 2,
    ok = 3,
}

enum ExecStatus : int
{
    emptyQuery = 0,
    commandOk = 1,
    tuplesOk = 2,
    copyOut = 3,
    copyIn = 4,
    badResponse = 5,
    nonfatalError = 6,
    fatalError = 7,
    copyBoth = 8,
    singleTuple = 9,
    pipelineSync = 10,
    pipelineAborted = 11,
    tuplesChunk = 12,
}

/// `PQtransactionStatus` (same numbering as psycopg's `TransactionStatus`).
enum TxStatus : int
{
    idle = 0,
    active = 1,
    inTrans = 2,
    inError = 3,
    unknown = 4,
}

enum : int
{
    PG_DIAG_SEVERITY = 'S',
    PG_DIAG_SEVERITY_NONLOCALIZED = 'V',
    PG_DIAG_SQLSTATE = 'C',
    PG_DIAG_MESSAGE_PRIMARY = 'M',
    PG_DIAG_MESSAGE_DETAIL = 'D',
    PG_DIAG_MESSAGE_HINT = 'H',
    PG_DIAG_STATEMENT_POSITION = 'P',
    PG_DIAG_INTERNAL_POSITION = 'p',
    PG_DIAG_INTERNAL_QUERY = 'q',
    PG_DIAG_CONTEXT = 'W',
    PG_DIAG_SCHEMA_NAME = 's',
    PG_DIAG_TABLE_NAME = 't',
    PG_DIAG_COLUMN_NAME = 'c',
    PG_DIAG_DATATYPE_NAME = 'd',
    PG_DIAG_CONSTRAINT_NAME = 'n',
}

alias NoticeReceiver = extern (C) void function(void* arg, const(PGresult)* res) nothrow;

struct LibPq
{
    extern (C) nothrow @nogc:

    PGconn* function(const(char)*) PQconnectStart;
    PGconn* function(const(char*)*, const(char*)*, int) PQconnectStartParams;
    int function(PGconn*) PQconnectPoll;
    int function(const(PGconn)*) PQstatus;
    int function(const(PGconn)*) PQsocket;
    int function(PGconn*, int) PQsetnonblocking;
    void function(PGconn*) PQfinish;
    char* function(const(PGconn)*) PQerrorMessage;
    int function(PGconn*, const(char)*) PQsendQuery;
    int function(PGconn*, const(char)*, int, const(uint)*, const(char*)*, const(int)*, const(int)*, int) PQsendQueryParams;
    int function(PGconn*) PQconsumeInput;
    int function(PGconn*) PQisBusy;
    int function(PGconn*) PQflush;
    PGresult* function(PGconn*) PQgetResult;
    void function(PGresult*) PQclear;
    int function(const(PGresult)*) PQresultStatus;
    char* function(const(PGresult)*) PQresultErrorMessage;
    char* function(const(PGresult)*, int) PQresultErrorField;
    int function(const(PGresult)*) PQntuples;
    int function(const(PGresult)*) PQnfields;
    char* function(const(PGresult)*, int) PQfname;
    uint function(const(PGresult)*, int) PQftype;
    int function(const(PGresult)*, int) PQfmod;
    int function(const(PGresult)*, int) PQfsize;
    uint function(const(PGresult)*, int) PQftable;
    int function(const(PGresult)*, int) PQftablecol;
    int function(const(PGresult)*, int, int) PQgetisnull;
    char* function(const(PGresult)*, int, int) PQgetvalue;
    int function(const(PGresult)*, int, int) PQgetlength;
    char* function(PGresult*) PQcmdStatus;
    char* function(PGresult*) PQcmdTuples;
    PGcancel* function(PGconn*) PQgetCancel;
    int function(PGcancel*, char*, int) PQcancel;
    void function(PGcancel*) PQfreeCancel;
    NoticeReceiver function(PGconn*, NoticeReceiver, void*) PQsetNoticeReceiver;
    PGnotify* function(PGconn*) PQnotifies;
    void function(void*) PQfreemem;
    int function(const(PGconn)*) PQtransactionStatus;
    int function(const(PGconn)*) PQserverVersion;
    const(char)* function(const(PGconn)*, const(char)*) PQparameterStatus;
    int function(const(PGconn)*) PQbackendPID;
    int function(const(PGconn)*) PQclientEncoding;
    const(char)* function(int) pg_encoding_to_char;
    char* function(const(PGconn)*) PQuser;
    char* function(const(PGconn)*) PQhost;
    char* function(const(PGconn)*) PQdb;
    char* function(const(PGconn)*) PQport;
    char* function(PGconn*, const(char)*, const(char)*, const(char)*) PQencryptPasswordConn;
    int function() PQlibVersion;
    PQconninfoOption* function(const(char)*, char**) PQconninfoParse;
    void function(PQconninfoOption*) PQconninfoFree;
    int function(const(PGconn)*) PQconnectionUsedPassword;
    int function(const(PGconn)*) PQsslInUse;
    int function(PGconn*, const(char)*, int) PQputCopyData;
    int function(PGconn*, const(char)*) PQputCopyEnd;
    int function(PGconn*, char**, int) PQgetCopyData;
}

__gshared LibPq pq;
private __gshared bool loaded;
private __gshared string loadError;
private __gshared Object loadLock;

shared static this()
{
    loadLock = new Object;
}

/// Loads libpq once; returns null on success or the error message.
string loadLibpq() @trusted
{
    synchronized (loadLock)
    {
        if (loaded)
            return null;
        if (loadError !is null)
            return loadError;
        void* h;
        foreach (name; ["libpq.so.5\0", "libpq.so\0", "libpq.5.dylib\0"])
            if ((h = dlopen(name.ptr, RTLD_NOW)) !is null)
                break;
        if (h is null)
            return loadError = "libpq not found (install libpq5 / postgresql-libs)";
        static foreach (m; __traits(allMembers, LibPq))
        {
            {
                auto p = dlsym(h, (m ~ "\0").ptr);
                if (p is null)
                    return loadError = "missing symbol in libpq: " ~ m;
                __traits(getMember, pq, m) = cast(typeof(__traits(getMember, pq, m))) p;
            }
        }
        loaded = true;
        return null;
    }
}

/// A C string as a D slice (no copy).
const(char)[] cstr(const(char)* p) nothrow @nogc
{
    if (p is null)
        return null;
    size_t n;
    while (p[n])
        n++;
    return p[0 .. n];
}

/// A C string copied to a D string; null stays null.
string dstr(const(char)* p) nothrow
{
    if (p is null)
        return null;
    return cstr(p).idup;
}
