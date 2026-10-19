/// Background process bookkeeping (`BatchProcess` of `misc/bgprocess/processes.py`).
///
/// A process row lives in the `process` table of the configuration database; its output goes to files in a log directory
/// written by the executor (`executor.d`), which this module launches as a detached copy of the program.
module pgadmin.misc.bgprocess.processes;

import std.array : join;
import std.conv : to;
import std.datetime : Clock, DateTime, SysTime, UTC, dur;
import std.file : exists, isFile, mkdirRecurse, readText, rmdirRecurse, getSize;
import std.path : buildPath;
import std.file : thisExePath;
import std.process : environment, spawnProcess, wait, Config;
import std.regex : regex, matchFirst;
import std.stdio : File;
import std.string : strip, indexOf, startsWith;
import pgadmin.core.config;
import pgadmin.core.i18n;
import pgadmin.core.log;
import pgadmin.core.value;
import pgadmin.db.driver : ServerManager;
import pgadmin.misc.bgprocess.executor : currentTime;
import pgadmin.model : db;
import pgadmin.utils.constants;
import pgadmin.utils.preferences : Preferences;
import pgadmin.web.context;

enum PROCESS_NOT_STARTED = 0;
enum PROCESS_STARTED = 1;
enum PROCESS_FINISHED = 2;
enum PROCESS_TERMINATED = 3;

enum PROCESS_NOT_FOUND = "Could not find a process with the specified ID.";

/// Python's `LookupError`
class LookupError : Exception
{
    this(string msg)
    {
        super(msg);
    }
}

/// `get_error_msg(cmd, error_code)`
string getErrorMsg(string cmd, long errorCode)
{
    string s;
    foreach (u; UTILITIES_ARRAY)
        if (cmd.indexOf(u) >= 0)
        {
            s = u ~ gettext(": error: ");
            break;
        }
    if (errorCode == 3221225781)
        return s ~ gettext("Unable to find a dll needed by the utility. Ensure .dll files needed by the utility are in the same folder as your executable.");
    return s ~ gettext("utility failed with exit code: ") ~ to!string(errorCode);
}

/// Parses "YYYY-mm-dd HH:MM:SS.ffffff +0000" into a SysTime (UTC).
private SysTime parseTime(string t)
{
    auto m = matchFirst(t, regex(`^(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)(?:\.(\d+))?`));
    if (m.empty)
        return Clock.currTime(UTC());
    auto dt = DateTime(to!int(m[1]), to!int(m[2]), to!int(m[3]), to!int(m[4]), to!int(m[5]), to!int(m[6]));
    long usecs;
    if (m[7].length)
    {
        auto f = m[7].idup;
        while (f.length < 6)
            f ~= "0";
        usecs = to!long(f[0 .. 6]);
    }
    return SysTime(dt, dur!"usecs"(usecs), UTC());
}

private string isoformat(SysTime t)
{
    import std.format : format;
    auto us = cast(int) t.fracSecs.total!"usecs";
    auto s = format("%04d-%02d-%02dT%02d:%02d:%02d", t.year, cast(int) t.month, t.day, t.hour, t.minute, t.second);
    if (us)
        s ~= format(".%06d", us);
    return s ~ "+00:00";
}

private double secondsBetween(SysTime a, SysTime b)
{
    import std.math : round;
    return round(cast(double)(b - a).total!"usecs" / 10_000.0) / 100.0;
}

final class BatchProcess
{
    string id;
    Value desc;
    string cmd;
    string[] args;
    string logDir;
    string stdoutFile, stderrFile;
    string stime, etime;
    Value ecode = Value(null);
    long processState;
    string[string] env;

    private this() {}

    /// `BatchProcess(desc=..., cmd=..., args=[...])`
    static BatchProcess create(Value desc, string cmd, string[] args)
    {
        auto p = new BatchProcess;
        auto ctime = currentTime(true);
        auto logDir = buildPath(cfgStr("SESSION_DB_PATH"), "process_logs", ctime);
        mkdirRecurse(logDir);
        p.id = ctime;
        p.desc = desc;
        p.cmd = cmd;
        p.logDir = logDir;
        p.stdoutFile = buildPath(logDir, "out");
        p.stderrFile = buildPath(logDir, "err");
        p.args = args;
        p.processState = PROCESS_NOT_STARTED;
        db.exec("INSERT INTO process (pid, user_id, command, arguments, logdir, \"desc\", process_state, server_id) VALUES (?, ?, ?, ?, ?, ?, 0, NULL)",
                Value(ctime), Value(currentUserId()), Value(cmd), Value(csvLine(args)), Value(logDir), Value(desc.toJson));
        return p;
    }

    /// `BatchProcess(id=...)`
    static BatchProcess retrieve(string id)
    {
        auto row = db.queryOne("SELECT * FROM process WHERE user_id = ? AND pid = ?", Value(currentUserId()), Value(id));
        if (row.isNone)
            throw new LookupError(gettext(PROCESS_NOT_FOUND));
        auto p = new BatchProcess;
        p.id = id;
        p.desc = tryParseJson(row["desc"].toString, Value(row["desc"].toString));
        p.cmd = row["command"].toString;
        p.args = csvParse(row.get("arguments").isNone ? "" : row["arguments"].toString);
        p.logDir = row["logdir"].toString;
        p.stdoutFile = buildPath(p.logDir, "out");
        p.stderrFile = buildPath(p.logDir, "err");
        p.stime = row.get("start_time").isNone ? null : row["start_time"].toString;
        p.etime = row.get("end_time").isNone ? null : row["end_time"].toString;
        p.ecode = row.get("exit_code");
        p.processState = row.get("process_state").isInt ? row["process_state"].integer : 0;
        return p;
    }

    /// `set_env_variables(server, env=...)`: SSL files, service, password file, connect timeout and password.
    void setEnvVariables(Value server, ServerManager manager, string[string] extra = null)
    {
        import pgadmin.utils.paths : getCompleteFilePath;
        if (server.isDict)
        {
            auto cp = server.get("connection_params");
            if (cp.isDict && cp.contains("sslcert") && cp.contains("sslkey") && cp.contains("sslrootcert"))
            {
                auto sslcert = getCompleteFilePath(cp["sslcert"].toString);
                auto sslkey = getCompleteFilePath(cp["sslkey"].toString);
                auto sslroot = getCompleteFilePath(cp["sslrootcert"].toString);
                env["PGSSLMODE"] = cp.contains("sslmode") ? cp["sslmode"].toString : "prefer";
                env["PGSSLCERT"] = sslcert is null ? "" : sslcert;
                env["PGSSLKEY"] = sslkey is null ? "" : sslkey;
                env["PGSSLROOTCERT"] = sslroot is null ? "" : sslroot;
            }
            if (server.get("service").truthy)
                env["PGSERVICE"] = server["service"].toString;
        }
        if (manager !is null)
        {
            auto cp = manager.connectionParams;
            if (cp.isDict && cp.contains("passfile") && cp["passfile"].truthy)
            {
                auto pgpass = getCompleteFilePath(cp["passfile"].toString);
                if (pgpass !is null)
                    env["PGPASSFILE"] = pgpass;
            }
            auto timeout = manager.connectionParam("connect_timeout");
            if (timeout.truthy && to!long(timeout.toString) > 0)
                env["PGCONNECT_TIMEOUT"] = timeout.toString;
            manager.exportPasswordEnv(id, env);
        }
        foreach (k, v; extra)
            env[k] = v;
    }

    private void checkStartEndTime()
    {
        if (stime !is null)
        {
            if (etime is null)
                throw new Exception(gettext("The process has already been started."));
            throw new Exception(gettext("The process has already finished and cannot be restarted."));
        }
    }

    /// `start()`: runs the executor detached from this server.
    void start()
    {
        checkStartEndTime();
        auto environ = environment.toAA();
        environ["PROCID"] = id;
        environ["OUTDIR"] = logDir;
        environ["PGA_BGP_FOREGROUND"] = "1";
        foreach (k, v; env)
            environ[k] = v;
        string[] cmdline = ["/bin/sh", "-c", `"$0" "$@" </dev/null >/dev/null 2>&1 &`, thisExePath(), "--bg-executor", cmd];
        foreach (a; args)
            cmdline ~= a.length >= 2 && a[0] == '"' && a[$ - 1] == '"' ? "#DQ#" ~ a ~ "#DQ#" : a;
        logInfo("Executing the process executor with the arguments: " ~ cmdline.join(" "));
        long ecodeNow = 0;
        try
        {
            auto pid = spawnProcess(cmdline, environ, Config.none);
            ecodeNow = wait(pid);
        }
        catch (Exception e)
        {
            logException(e);
            ecodeNow = 1;
        }
        if (ecodeNow != 0)
        {
            auto now = currentTime();
            db.exec("UPDATE process SET start_time = ?, end_time = ?, exit_code = ?, process_state = ? WHERE pid = ? AND user_id = ?",
                    Value(now), Value(now), Value(ecodeNow), Value(PROCESS_FINISHED), Value(id), Value(currentUserId()));
        }
        else
            db.exec("UPDATE process SET process_state = ? WHERE pid = ? AND user_id = ?", Value(PROCESS_STARTED), Value(id),
                    Value(currentUserId()));
    }

    /// `read_log(logfile, log, pos, ctime, ecode)`: returns the new position and whether the log is complete.
    private long readLog(string logfile, ref Value[] log, long pos, string ctime, Value ecode, out bool completed)
    {
        completed = true;
        if (!logfile.exists || !logfile.isFile)
            return 0;
        import std.file : readFile = read;
        auto data = cast(ubyte[]) readFile(logfile);
        immutable eofs = cast(long) data.length;
        if (pos == eofs && ecode.isNone)
            completed = false;
        long idx;
        auto re = regex(`(\d+),(.*$)`);
        while (pos < eofs)
        {
            idx++;
            long nl = pos;
            while (nl < eofs && data[nl] != '\n')
                nl++;
            auto lineEnd = nl < eofs ? nl + 1 : nl;
            auto line = cast(string) data[pos .. lineEnd].idup;
            line = line.length && line[$ - 1] == '\n' ? line[0 .. $ - 1] : line;
            auto m = matchFirst(line, re);
            if (m.empty)
            {
                pos = lineEnd;
                continue;
            }
            if (m[1] > ctime)
            {
                completed = false;
                break;
            }
            log ~= Value([Value(m[1].idup), Value(m[2].idup)]);
            pos = lineEnd;
            if (idx >= 1024)
            {
                completed = false;
                break;
            }
            if (pos == eofs)
            {
                if (ecode.isNone)
                    completed = false;
                break;
            }
        }
        return pos;
    }

    /// `update_process_info(p)`: copies the executor's `status` file into the row. (status, updated)
    static bool updateProcessInfo(Value p)
    {
        if (p["start_time"].isNone || p["end_time"].isNone)
        {
            auto statusFile = buildPath(p["logdir"].toString, "status");
            if (!statusFile.exists || !statusFile.isFile)
                return false;
            auto data = tryParseJson(readText(statusFile), Value(null));
            if (!data.isDict)
                return false;
            bool changed;
            if (data.get("start_time").truthy)
            {
                p["start_time"] = data["start_time"];
                if (!data.get("exit_code").isNone)
                {
                    p["exit_code"] = data["exit_code"];
                    if (data.get("end_time").truthy)
                        p["end_time"] = data["end_time"];
                }
            }
            if (data.contains("pid"))
                p["utility_pid"] = data["pid"];
            db.exec("UPDATE process SET start_time = ?, end_time = ?, exit_code = ?, utility_pid = ? WHERE pid = ? AND user_id = ?",
                    p["start_time"], p["end_time"], p["exit_code"], p["utility_pid"], p["pid"], Value(currentUserId()));
            return true;
        }
        return false;
    }

    /// `status(out, err)`
    Value status(long outPos = 0, long errPos = 0)
    {
        auto ctime = currentTime(true);
        Value[] stdoutLines, stderrLines;
        bool outCompleted, errCompleted;
        bool processOutput = outPos != -1 && errPos != -1;
        auto j = db.queryOne("SELECT * FROM process WHERE user_id = ? AND pid = ?", Value(currentUserId()), Value(id));
        Value executionTime = Value(null);
        if (!j.isNone)
        {
            updateProcessInfo(j);
            stime = j["start_time"].isNone ? null : j["start_time"].toString;
            etime = j["end_time"].isNone ? null : j["end_time"].toString;
            ecode = j["exit_code"];
            if (stime !is null)
            {
                auto st = parseTime(stime);
                auto et = etime !is null ? parseTime(etime) : parseTime(currentTime());
                executionTime = Value(secondsBetween(st, et));
            }
            if (processOutput)
            {
                outPos = readLog(stdoutFile, stdoutLines, outPos, ctime, ecode, outCompleted);
                errPos = readLog(stderrFile, stderrLines, errPos, ctime, ecode, errCompleted);
            }
        }
        if (outPos == -1 || errPos == -1)
            return Value.dictOf("start_time", stime is null ? Value(null) : Value(stime), "exit_code", ecode,
                    "execution_time", executionTime, "process_state", processState);
        if (errCompleted && !ecode.isNone && ecode != Value(0))
            stderrLines ~= Value([Value("Z"), Value(getErrorMsg(cmd, ecode.integer))]);
        return Value.dictOf("out", Value.dictOf("pos", outPos, "lines", Value(stdoutLines), "done", outCompleted), "err",
                Value.dictOf("pos", errPos, "lines", Value(stderrLines), "done", errCompleted), "start_time",
                stime is null ? Value(null) : Value(stime), "exit_code", ecode, "execution_time", executionTime);
    }

    /// `BatchProcess.list()`
    static Value list()
    {
        auto retain = Preferences.module_("browser").preference("process_retain_days").get();
        long days = retain.truthy ? retain.integer : 1;
        Value[] res;
        foreach (p; db.query("SELECT * FROM process WHERE user_id = ?", Value(currentUserId())))
        {
            if (!p["start_time"].isNone)
            {
                auto expiry = parseTime(p["start_time"].toString) + dur!"days"(days);
                if (Clock.currTime(UTC()) >= expiry)
                {
                    try
                        rmdirRecurse(p["logdir"].toString);
                    catch (Exception)
                    {
                    }
                    db.exec("DELETE FROM process WHERE pid = ?", p["pid"]);
                    continue;
                }
            }
            updateProcessInfo(p);
            if (p["start_time"].isNone || (!p["acknowledge"].isNone && p["end_time"].isNone))
                continue;
            auto st = parseTime(p["start_time"].toString);
            auto et = p["end_time"].isNone ? parseTime(currentTime()) : parseTime(p["end_time"].toString);
            auto d = tryParseJson(p["desc"].toString, Value(p["desc"].toString));
            string message = d.isDict ? (d.contains("list_message") ? d["list_message"].toString : d.get("message").toString) : d.toString;
            Value details = d.isDict ? d.get("details") : d;
            res ~= Value.dictOf("id", p["pid"], "desc", message, "type_desc", d.isDict ? d.get("type_desc", Value("")) : Value(""),
                    "details", details, "stime", isoformat(st), "etime", p["end_time"], "exit_code", p["exit_code"],
                    "acknowledge", p["acknowledge"], "execution_time", secondsBetween(st, et), "process_state",
                    p["process_state"], "utility_pid", p["utility_pid"], "server_id", p["server_id"], "current_storage_dir",
                    d.isDict ? d.get("current_storage_dir") : Value(null));
        }
        return Value(res);
    }

    /// `BatchProcess.acknowledge(pid)`
    static void acknowledge(string pid)
    {
        auto p = db.queryOne("SELECT * FROM process WHERE user_id = ? AND pid = ?", Value(currentUserId()), Value(pid));
        if (p.isNone)
            throw new LookupError(gettext(PROCESS_NOT_FOUND));
        if (!p["end_time"].isNone)
        {
            db.exec("DELETE FROM process WHERE pid = ?", Value(pid));
            try
                rmdirRecurse(p["logdir"].toString);
            catch (Exception)
            {
            }
        }
        else
            db.exec("UPDATE process SET acknowledge = ? WHERE pid = ?", Value(currentTime()), Value(pid));
    }

    /// `BatchProcess.stop_process(pid)`
    static void stopProcess(string pid)
    {
        import core.sys.posix.signal : kill, SIGTERM;
        auto p = db.queryOne("SELECT * FROM process WHERE user_id = ? AND pid = ?", Value(currentUserId()), Value(pid));
        if (p.isNone)
            throw new LookupError(gettext(PROCESS_NOT_FOUND));
        if (p["utility_pid"].isInt)
            kill(cast(int) p["utility_pid"].integer, SIGTERM);
        db.exec("UPDATE process SET process_state = ? WHERE pid = ?", Value(PROCESS_TERMINATED), Value(pid));
    }

    /// `BatchProcess.update_server_id(pid, sid)`
    static void updateServerId(string pid, Value sid)
    {
        auto p = db.queryOne("SELECT pid FROM process WHERE user_id = ? AND pid = ?", Value(currentUserId()), Value(pid));
        if (p.isNone)
            throw new LookupError(gettext(PROCESS_NOT_FOUND));
        db.exec("UPDATE process SET server_id = ? WHERE pid = ?", sid, Value(pid));
    }
}

/// One CSV record the way Python's `csv.writer(delimiter=',', quoting=QUOTE_MINIMAL)` writes it.
string csvLine(string[] fields)
{
    string[] out_;
    foreach (f; fields)
    {
        bool needs = f.length == 0 && fields.length == 1;
        foreach (char c; f)
            if (c == ',' || c == '"' || c == '\n' || c == '\r')
                needs = true;
        if (needs)
        {
            string q = "\"";
            foreach (char c; f)
            {
                if (c == '"')
                    q ~= '"';
                q ~= c;
            }
            out_ ~= q ~ "\"";
        }
        else
            out_ ~= f;
    }
    return out_.join(",");
}

/// Parses one CSV record.
string[] csvParse(string line)
{
    string[] fields;
    string cur;
    bool inQ, hasField = line.length > 0;
    for (size_t i = 0; i < line.length; i++)
    {
        char c = line[i];
        if (inQ)
        {
            if (c == '"')
            {
                if (i + 1 < line.length && line[i + 1] == '"')
                {
                    cur ~= '"';
                    i++;
                }
                else
                    inQ = false;
            }
            else
                cur ~= c;
        }
        else if (c == '"')
            inQ = true;
        else if (c == ',')
        {
            fields ~= cur;
            cur = "";
        }
        else
            cur ~= c;
    }
    if (hasField)
        fields ~= cur;
    return fields;
}
