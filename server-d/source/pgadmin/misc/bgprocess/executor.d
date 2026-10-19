/// The background process executor (`process_executor.py`): runs a utility, copies its output to timestamped log files and
/// keeps a `status` file up to date. It runs as a separate (detached) copy of this program (`--bg-executor`).
module pgadmin.misc.bgprocess.executor;

import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.sys.posix.unistd : getpid;
import std.datetime : Clock, UTC;
import std.file : append, exists, write;
import std.format : format;
import std.json : JSONValue, toJSON;
import std.path : buildPath;
import std.process : environment, pipeProcess, Redirect, wait, ProcessException;
import std.stdio : File, KeepTerminator;
import std.string : startsWith, endsWith;

/// `get_current_time(format)`: the two formats pgAdmin uses.
string currentTime(bool compact = false)
{
    auto t = Clock.currTime(UTC());
    immutable us = cast(int) t.fracSecs.total!"usecs";
    if (compact)
        return format("%02d%02d%02d%02d%02d%02d%06d", t.year % 100, cast(int) t.month, t.day, t.hour, t.minute, t.second, us);
    return format("%04d-%02d-%02d %02d:%02d:%02d.%06d +0000", t.year, cast(int) t.month, t.day, t.hour, t.minute, t.second, us);
}

private string unescapeDquotes(string arg)
{
    enum dq = "#DQ#";
    if (arg.startsWith(dq) && arg.endsWith(dq) && arg.length >= 2 * dq.length)
        return arg[dq.length .. $ - dq.length];
    return arg;
}

private final class StreamLogger
{
    File logger;
    Mutex mtx;

    this(string outDir, string name)
    {
        logger = File(buildPath(outDir, name), "wb");
        mtx = new Mutex;
    }

    void log(const(char)[] msg)
    {
        if (msg.length == 0)
            return;
        mtx.lock();
        scope (exit)
            mtx.unlock();
        while (msg.length && msg[0] == '\n')
            msg = msg[1 .. $];
        logger.rawWrite(cast(const(ubyte)[]) currentTime(true));
        logger.rawWrite(cast(const(ubyte)[]) ",");
        logger.rawWrite(cast(const(ubyte)[]) msg);
        logger.rawWrite(cast(const(ubyte)[]) "\n");
        logger.flush();
    }

    void close()
    {
        if (logger.isOpen)
            logger.close();
    }
}

private void updateStatus(string outDir, string[string] kw, long pid, long exitCode, bool hasExit)
{
    JSONValue j = JSONValue.emptyObject;
    foreach (k; ["start_time", "end_time"])
        if (k in kw)
            j[k] = kw[k];
    if (hasExit)
        j["exit_code"] = exitCode;
    if (pid)
        j["pid"] = pid;
    write(buildPath(outDir, "status"), toJSON(j));
}

/// Runs `argv[0]` with `argv[1 ..]` (the arguments after `--bg-executor`). Returns the process exit status of the executor.
int runExecutor(string[] argv)
{
    auto outDir = environment.get("OUTDIR", "");
    if (outDir.length == 0)
        return 2;
    auto command = new string[argv.length];
    foreach (i, a; argv)
        command[i] = unescapeDquotes(a);
    string[string] kw;
    long pid = getpid();
    long exitCode;
    bool hasExit;
    auto outLog = new StreamLogger(outDir, "out");
    auto errLog = new StreamLogger(outDir, "err");
    try
    {
        kw["start_time"] = currentTime();
        updateStatus(outDir, kw, pid, 0, false);
        auto env = environment.toAA();
        auto procId = environment.get("PROCID", "");
        if (procId.length && environment.get(procId, "").length)
            env["PGPASSWORD"] = environment[procId];
        auto p = pipeProcess(command, Redirect.stdout | Redirect.stderr, env);
        kw["start_time"] = currentTime();
        updateStatus(outDir, kw, p.pid.processID, 0, false);
        pid = p.pid.processID;
        auto t1 = new Thread({
            foreach (line; p.stdout.byLine(KeepTerminator.yes))
                outLog.log(line);
        });
        auto t2 = new Thread({
            foreach (line; p.stderr.byLine(KeepTerminator.yes))
                errLog.log(line);
        });
        t1.start();
        t2.start();
        t1.join();
        t2.join();
        exitCode = wait(p.pid);
        hasExit = true;
        kw["end_time"] = currentTime();
    }
    catch (ProcessException e)
    {
        errLog.log("EXCEPTION::\n[Errno 2] No such file or directory: '" ~ command[0] ~ "'\n");
        kw["end_time"] = currentTime();
        exitCode = 2;
        hasExit = true;
    }
    catch (Exception e)
    {
        errLog.log("EXCEPTION::\n" ~ e.msg ~ "\n");
        kw["end_time"] = currentTime();
        exitCode = -1;
        hasExit = true;
    }
    updateStatus(outDir, kw, pid, exitCode, hasExit);
    outLog.close();
    errLog.close();
    return 0;
}
