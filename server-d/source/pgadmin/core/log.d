/// Logging with Python's levels and pgAdmin's format (`%(asctime)s: %(levelname)s\t%(name)s:\t%(message)s`).
///
/// Level 25 is pgAdmin's `SQL` level: every query is logged at it. Console and file handlers have their own levels
/// (CONSOLE_LOG_LEVEL, FILE_LOG_LEVEL).
module pgadmin.core.log;

import core.sync.mutex : Mutex;
import std.datetime.systime : Clock, SysTime;
import std.format : format;
import std.stdio : File, stderr;

enum LogLevel : int
{
    debug_ = 10,
    info = 20,
    sql = 25,
    warning = 30,
    error = 40,
    critical = 50,
}

private __gshared int consoleLevel = LogLevel.warning;
private __gshared int fileLevel = LogLevel.warning;
private __gshared File logFile;
private __gshared bool hasFile;
private __gshared Mutex lock;
private __gshared bool jsonFormat;

shared static this()
{
    lock = new Mutex;
}

/// Configures the handlers (called once at startup, before the server starts).
void configureLogging(int console, int file, string logPath, bool json = false) @trusted
{
    consoleLevel = console;
    fileLevel = file;
    jsonFormat = json;
    if (logPath.length)
    {
        try
        {
            import std.file : mkdirRecurse, exists;
            import std.path : dirName;
            auto d = dirName(logPath);
            if (!d.exists)
                mkdirRecurse(d);
            logFile = File(logPath, "a");
            hasFile = true;
        }
        catch (Exception e)
        {
            stderr.writeln("could not open log file ", logPath, ": ", e.msg);
        }
    }
}

string levelName(int level)
{
    switch (level)
    {
    case LogLevel.debug_: return "DEBUG";
    case LogLevel.info: return "INFO";
    case LogLevel.sql: return "SQL";
    case LogLevel.warning: return "WARNING";
    case LogLevel.error: return "ERROR";
    case LogLevel.critical: return "CRITICAL";
    default: return format("Level %d", level);
    }
}

private string asctime()
{
    auto t = Clock.currTime;
    return format("%04d-%02d-%02d %02d:%02d:%02d,%03d", t.year, cast(int) t.month, t.day, t.hour, t.minute, t.second,
            cast(int)(t.fracSecs.total!"msecs"));
}

void log(int level, string msg, string name = "pgadmin") @trusted nothrow
{
    try
    {
        if (level < consoleLevel && (!hasFile || level < fileLevel))
            return;
        string line;
        if (jsonFormat)
        {
            import pgadmin.core.value : Value;
            line = Value.dictOf("time", asctime(), "level", levelName(level), "message", msg).toJsonSpaced();
        }
        else
            line = asctime() ~ ": " ~ levelName(level) ~ "\t" ~ name ~ ":\t" ~ msg;
        synchronized (lock)
        {
            if (level >= consoleLevel)
                stderr.writeln(line);
            if (hasFile && level >= fileLevel)
            {
                logFile.writeln(line);
                logFile.flush();
            }
        }
    }
    catch (Exception)
    {
    }
}

void logDebug(string msg) nothrow => log(LogLevel.debug_, msg);
void logInfo(string msg) nothrow => log(LogLevel.info, msg);
void logSql(string msg) nothrow => log(LogLevel.sql, msg);
void logWarning(string msg) nothrow => log(LogLevel.warning, msg);
void logError(string msg) nothrow => log(LogLevel.error, msg);

/// `logger.exception(e)`: the message and the stack trace at ERROR.
void logException(Throwable e) nothrow
{
    try
        log(LogLevel.error, e.msg ~ "\n" ~ e.toString());
    catch (Exception)
    {
    }
}
