/// `pgadmin/tools/psql`: Interactive PSQL terminal over Socket.IO and POSIX PTY.
module pgadmin.tools.psql;

import core.sync.mutex : Mutex;
import core.thread : Thread;
version (Posix)
{
    import core.sys.posix.stdlib : setenv;
}
import core.thread : Thread;
import std.algorithm : canFind;
import std.array : split;
import std.conv : to;
import std.file : exists;
import std.path : buildPath;
import std.process : environment;
import std.string : fromStringz, strip, toStringz;

version (Posix)
{
    import core.sys.posix.fcntl;
    import core.sys.posix.poll;
    import core.sys.posix.signal;
    import core.sys.posix.sys.ioctl : ioctl, winsize, TIOCSWINSZ;
    import core.sys.posix.sys.wait;
    import core.sys.posix.unistd;

    extern (C) int openpty(int* amaster, int* aslave, char* name, const void* termp, const void* winp) nothrow @nogc;
    enum TIOCSCTTY = 0x540E;

    void setTermSize(int fd, ushort rows, ushort cols)
    {
        winsize ws;
        ws.ws_row = rows;
        ws.ws_col = cols;
        ws.ws_xpixel = 0;
        ws.ws_ypixel = 0;
        ioctl(fd, TIOCSWINSZ, &ws);
    }
}
else
{
    void setTermSize(int fd, ushort rows, ushort cols) {}
}

import pgadmin.core.config;
import pgadmin.core.i18n : gettext;
import pgadmin.core.log : logError, logInfo;
import pgadmin.core.templates : renderTemplate, tv;
import pgadmin.core.value;
import pgadmin.db.driver : getServer, getDriver;
import pgadmin.utils.constants;
import pgadmin.web.context;
import pgadmin.web.flask;
import pgadmin.web.http;
import pgadmin.web.socketio;

private string htmlEscape(string s)
{
    import std.array : replace;
    return s.replace("&", "&amp;")
            .replace("<", "&lt;")
            .replace(">", "&gt;")
            .replace("\"", "&quot;")
            .replace("'", "&#x27;")
            .replace("`", "&#x60;");
}

final class PtySession
{
    string clientSid;
    long serverId;
    int masterFd = -1;
    int pid = -1;
    bool running = false;
    Mutex lock;

    this(string clientSid, long serverId, int masterFd, int pid)
    {
        this.clientSid = clientSid;
        this.serverId = serverId;
        this.masterFd = masterFd;
        this.pid = pid;
        this.running = true;
        this.lock = new Mutex();
    }
}

private __gshared Mutex ptyLock;
private __gshared PtySession[string] ptySessions;

shared static this()
{
    ptyLock = new Mutex();
}

void registerPtySession(PtySession session)
{
    synchronized (ptyLock)
    {
        ptySessions[session.clientSid] = session;
    }
}

PtySession getPtySession(string clientSid)
{
    synchronized (ptyLock)
    {
        if (auto s = clientSid in ptySessions)
            return *s;
        return null;
    }
}

void closePtySession(string clientSid)
{
    PtySession session = null;
    synchronized (ptyLock)
    {
        if (auto s = clientSid in ptySessions)
        {
            session = *s;
            ptySessions.remove(clientSid);
        }
    }

    if (session !is null)
    {
        synchronized (session.lock)
        {
            session.running = false;
            version (Posix)
            {
                if (session.masterFd >= 0)
                {
                    auto quitCmd = "\\q\n";
                    write(session.masterFd, quitCmd.ptr, quitCmd.length);
                    close(session.masterFd);
                    session.masterFd = -1;
                }
                if (session.pid > 0)
                {
                    kill(session.pid, SIGTERM);
                    int status;
                    waitpid(session.pid, &status, WNOHANG);
                    session.pid = -1;
                }
            }
        }
    }
}

string findPsqlPath()
{
    if (ConfigAccess.has("PSQL_PATH"))
    {
        auto p = cfgStr("PSQL_PATH");
        if (p.length && exists(p))
            return p;
    }

    string[] candidates = [
        "/usr/bin/psql",
        "/usr/local/bin/psql",
        "/usr/pgsql-17/bin/psql",
        "/usr/pgsql-16/bin/psql",
        "/usr/pgsql-15/bin/psql",
        "/usr/pgsql-14/bin/psql",
        "/usr/lib/postgresql/17/bin/psql",
        "/usr/lib/postgresql/16/bin/psql",
        "/usr/lib/postgresql/15/bin/psql",
        "/usr/lib/postgresql/14/bin/psql",
    ];
    foreach (c; candidates)
    {
        if (exists(c))
            return c;
    }

    auto pathEnv = environment.get("PATH", "");
    foreach (dir; pathEnv.split(":"))
    {
        auto full = buildPath(dir, "psql");
        if (exists(full))
            return full;
    }

    return null;
}

private void runPtyReader(string clientSid, int masterFd, int pid)
{
    version (Posix)
    {
        ubyte[4096] buf;
        while (true)
        {
            auto s = getPtySession(clientSid);
            if (s is null || !s.running || masterFd < 0)
                break;

            pollfd pfd;
            pfd.fd = masterFd;
            pfd.events = POLLIN;
            int ret = poll(&pfd, 1, 100);
            if (ret > 0)
            {
                if (pfd.revents & (POLLIN | POLLPRI))
                {
                    ssize_t n = read(masterFd, buf.ptr, buf.length);
                    if (n > 0)
                    {
                        auto text = cast(string) buf[0 .. n].idup;
                        getSocketIo().emit("/pty", "pty-output", Value.dictOf("result", text, "error", false), clientSid);
                    }
                    else if (n <= 0)
                    {
                        break;
                    }
                }
                if (pfd.revents & (POLLHUP | POLLERR | POLLNVAL))
                {
                    break;
                }
            }
            else if (ret < 0)
            {
                import core.stdc.errno : errno, EINTR;
                if (errno == EINTR)
                    continue;
                break;
            }

            int status;
            int wp = waitpid(pid, &status, WNOHANG);
            if (wp > 0)
            {
                // Process finished. Read any residual output.
                while (true)
                {
                    pollfd pfd2;
                    pfd2.fd = masterFd;
                    pfd2.events = POLLIN;
                    if (poll(&pfd2, 1, 20) > 0 && (pfd2.revents & POLLIN))
                    {
                        ssize_t n = read(masterFd, buf.ptr, buf.length);
                        if (n > 0)
                        {
                            auto text = cast(string) buf[0 .. n].idup;
                            getSocketIo().emit("/pty", "pty-output", Value.dictOf("result", text, "error", false), clientSid);
                        }
                        else
                            break;
                    }
                    else
                        break;
                }
                break;
            }
        }

        closePtySession(clientSid);
    }
}

void registerPsqlSocketHandlers(SocketIoServer sio)
{
    sio.on("/pty", "connect", (SocketIoClient client, Value data) {
        sio.emit("/pty", "connected", Value.dictOf("sid", client.sid), client.sid);
    });

    sio.on("/pty", "start_process", (SocketIoClient client, Value data) {
        long sid = data.contains("sid") ? data["sid"].integer : 0;
        string db = data.contains("db") ? data["db"].toString : "";
        string user = data.contains("user") ? data["user"].toString : "";

        auto psqlPath = findPsqlPath();
        if (!psqlPath.length)
        {
            sio.emit("/pty", "pty-output", Value.dictOf(
                "result", gettext("PSQL utility not found. Specify the valid binary path in the preferences for the appropriate server version, or select \"Set as default\" to use an existing binary path."),
                "error", true
            ), client.sid);
            return;
        }

        auto server = getServer(sid);
        if (server.isNone)
        {
            sio.emit("/pty", "conn_error", Value.dictOf("error", "Server is not connected."), client.sid);
            return;
        }

        string host = server.contains("host") ? server["host"].toString : "127.0.0.1";
        long port = server.contains("port") ? server["port"].integer : 5432;
        if (!user.length && server.contains("username"))
            user = server["username"].toString;
        if (!db.length && server.contains("maintenance_db"))
            db = server["maintenance_db"].toString;
        if (!db.length)
            db = "postgres";

        string[string] env;
        try
        {
            auto mgr = getDriver().connectionManager(sid);
            mgr.exportPasswordEnv("PGPASSWORD", env);
        }
        catch (Exception)
        {
            if (server.contains("password") && server["password"].toString.length)
                env["PGPASSWORD"] = server["password"].toString;
        }

        version (Posix)
        {
            int masterFd = -1;
            int slaveFd = -1;
            if (openpty(&masterFd, &slaveFd, null, null, null) != 0)
            {
                sio.emit("/pty", "conn_error", Value.dictOf("error", "Failed to allocate pseudo-terminal."), client.sid);
                return;
            }
            setTermSize(masterFd, 50, 50);

            string[] cmdArgs = [psqlPath];
            if (host.length)
            {
                cmdArgs ~= "-h";
                cmdArgs ~= host;
            }
            if (port > 0)
            {
                cmdArgs ~= "-p";
                cmdArgs ~= to!string(port);
            }
            if (user.length)
            {
                cmdArgs ~= "-U";
                cmdArgs ~= user;
            }
            if (db.length)
            {
                cmdArgs ~= "-d";
                cmdArgs ~= db;
            }

            int pid = fork();
            if (pid < 0)
            {
                close(masterFd);
                close(slaveFd);
                sio.emit("/pty", "conn_error", Value.dictOf("error", "Failed to fork process."), client.sid);
                return;
            }

            if (pid == 0)
            {
                close(masterFd);
                setsid();
                ioctl(slaveFd, TIOCSCTTY, 0);
                dup2(slaveFd, 0);
                dup2(slaveFd, 1);
                dup2(slaveFd, 2);
                if (slaveFd > 2)
                    close(slaveFd);

                setenv("TERM", "xterm-256color", 1);
                if ("PGPASSWORD" in env)
                    setenv("PGPASSWORD", toStringz(env["PGPASSWORD"]), 1);
                if (user.length)
                    setenv("PGUSER", toStringz(user), 1);
                if (host.length)
                    setenv("PGHOST", toStringz(host), 1);
                if (port > 0)
                    setenv("PGPORT", toStringz(to!string(port)), 1);
                if (db.length)
                    setenv("PGDATABASE", toStringz(db), 1);

                const(char)*[] cArgs;
                foreach (arg; cmdArgs)
                    cArgs ~= toStringz(arg);
                cArgs ~= null;

                execvp(cArgs[0], cast(char**) cArgs.ptr);
                _exit(127);
            }

            close(slaveFd);

            auto session = new PtySession(client.sid, sid, masterFd, pid);
            registerPtySession(session);

            auto readerThread = new Thread({
                runPtyReader(client.sid, masterFd, pid);
            });
            readerThread.isDaemon = true;
            readerThread.start();
        }
        else
        {
            sio.emit("/pty", "conn_error", Value.dictOf("error", "PTY is not supported on this platform."), client.sid);
        }
    });

    sio.on("/pty", "socket_input", (SocketIoClient client, Value data) {
        auto session = getPtySession(client.sid);
        if (session is null || session.masterFd < 0)
        {
            sio.emit("/pty", "pty-output", Value.dictOf(
                "result", gettext("Invalid session.\r\n"),
                "error", true
            ), client.sid);
            return;
        }

        string keyName = data.contains("key_name") ? data["key_name"].toString : "";
        string input = data.contains("input") ? data["input"].toString : "";

        if (keyName == "Enter" && (input == "\\q" || input == "q\\q" || input == "\\quit" || input == "exit" || input == "exit;"))
        {
            sio.emit("/pty", "pty-output", Value.dictOf(
                "result", gettext("Connection terminated. To create a new connection, please open another psql tool."),
                "error", true
            ), client.sid);
            version (Posix)
            {
                write(session.masterFd, "\n".ptr, 1);
            }
            closePtySession(client.sid);
        }
        else
        {
            version (Posix)
            {
                if (input.length)
                    write(session.masterFd, input.ptr, input.length);
            }
        }
    });

    sio.on("/pty", "socket_set_role", (SocketIoClient client, Value data) {
        auto session = getPtySession(client.sid);
        if (session is null || session.masterFd < 0)
            return;

        string role = data.contains("role") ? data["role"].toString : "";
        if (role.length)
        {
            import std.array : replace;
            role = role.replace("\"", "\"\"");
            string cmd = "SET ROLE \"" ~ role ~ "\";\n";
            version (Posix)
            {
                write(session.masterFd, cmd.ptr, cmd.length);
            }
        }
    });

    sio.on("/pty", "resize", (SocketIoClient client, Value data) {
        auto session = getPtySession(client.sid);
        if (session is null || session.masterFd < 0)
            return;

        ushort rows = data.contains("rows") ? cast(ushort) data["rows"].integer : 24;
        ushort cols = data.contains("cols") ? cast(ushort) data["cols"].integer : 80;
        setTermSize(session.masterFd, rows, cols);
    });

    sio.on("/pty", "disconnect", (SocketIoClient client, Value data) {
        closePtySession(client.sid);
    });

    sio.on("/pty", "server-disconnect", (SocketIoClient client, Value data) {
        closePtySession(client.sid);
    });
}

final class PSQLModule : Blueprint
{
    this()
    {
        super("psql");
    }

    override string[] getExposedUrlEndpoints() => ["psql.panel"];

    override void setup()
    {
        route("/panel/<int:trans_id>", "panel", ["POST"], (Dict a) => panelEndpoint(a));
        registerPsqlSocketHandlers(getSocketIo());
    }

    private static Response panelEndpoint(Dict a)
    {
        long transId = a["trans_id"].integer;
        auto params = Value.newDict();
        params["trans_id"] = Value(transId);
        params["is_enable"] = Value(true);
        params["platform"] = Value("linux");
        params["client_platform"] = Value("Linux");
        params["is_desktop_mode"] = Value(false);
        params["is_linux"] = Value(true);

        auto req = request();
        if (!req.args.empty)
        {
            auto ad = req.args.toDict();
            foreach (k; ad.dict.keys)
                params[k] = ad[k];
        }

        if (!req.form.empty)
        {
            auto fd = req.form.toDict();
            foreach (k; fd.dict.keys)
                params[k] = fd[k];
        }
        else if (req.text.length)
        {
            try
            {
                auto parsed = parseJson(req.text);
                if (parsed.isDict)
                {
                    foreach (k; parsed.dict.keys)
                        params[k] = parsed[k];
                }
            }
            catch (Exception) {}
        }

        string rawTitle = params.contains("title") ? params["title"].toString : "PSQL";
        params["title"] = Value(htmlEscape(rawTitle));
        if (params.contains("user"))
            params["user"] = Value(htmlEscape(params["user"].toString));
        if (params.contains("db"))
            params["db"] = Value(htmlEscape(params["db"].toString));
        if (params.contains("role"))
            params["role"] = Value(htmlEscape(params["role"].toString));

        long sid = params.contains("sid") ? params["sid"].integer : 0;
        auto s = getServer(sid);

        if (!s.isNone)
        {
            if (!params.contains("db") || params["db"].toString.length == 0)
                params["db"] = Value("postgres");
            if (!params.contains("role"))
                params["role"] = Value("");

            auto rendered = renderTemplate("psql/index.html", tv(
                "title", Value(rawTitle),
                "params", Value(params.toJson()),
                "csp_nonce", reqctx().cspNonce,
                "is_desktop_mode", Value(false),
                "is_linux", Value(true)
            ));
            return new Response(rendered, 200, "text/html");
        }

        params["error"] = Value(gettext("The server was not found."));
        auto rendered = renderTemplate("psql/index.html", tv(
            "title", Value(rawTitle),
            "params", Value(params.toJson()),
            "csp_nonce", reqctx().cspNonce,
            "is_desktop_mode", Value(false),
            "is_linux", Value(true)
        ));
        return new Response(rendered, 200, "text/html");
    }
}

unittest
{
    assert(htmlEscape("<a> & \"b\" 'c' `d`") == "&lt;a&gt; &amp; &quot;b&quot; &#x27;c&#x27; &#x60;d&#x60;");
    auto psql = findPsqlPath();
    assert(psql.length > 0, "psql path should be found on this system");
}

