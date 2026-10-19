/// pgAdmin 4 backend in D: entry point.
module app;

import std.conv : to;
import std.file : exists;
import std.path : buildPath, absolutePath, dirName;
import std.stdio : stderr, writeln;
import std.getopt;
import andaime;
import andaime.engine.loop : ServerConfig;
import pgadmin.core.config;
import pgadmin.core.log : configureLogging, logInfo;
import pgadmin.core.templates;
import pgadmin.core.value;
import pgadmin.model;
import pgadmin.web.flask;
import pgadmin.registry : createFlaskApp, setRuntime;

int main(string[] args)
{
    if (args.length > 2 && args[1] == "--bg-executor")
    {
        import pgadmin.misc.bgprocess.executor : runExecutor;
        return runExecutor(args[2 .. $]);
    }
    string webDir = "../web";
    string host, setupEmail, setupPassword;
    int port;
    bool serverMode, desktopMode;
    auto opt = getopt(args,
        "web-dir", "Directory of the pgAdmin web tree (templates, static files). Default ../web", &webDir,
        "host", "Listen address (default DEFAULT_SERVER)", &host,
        "port", "Listen port (default DEFAULT_SERVER_PORT)", &port,
        "server-mode", "Run in server mode (multi user, the default)", &serverMode,
        "desktop-mode", "Run in desktop mode (single user, no login)", &desktopMode,
        "setup-email", "Email of the first administrator (server mode, first run)", &setupEmail,
        "setup-password", "Password of the first administrator (server mode, first run)", &setupPassword);
    if (opt.helpWanted)
    {
        defaultGetoptPrinter("pgAdmin 4 (D port)", opt.options);
        return 0;
    }
    if (!buildPath(webDir, "pgadmin").exists)
    {
        stderr.writeln("pgAdmin web directory not found: ", absolutePath(webDir), " (use --web-dir)");
        return 1;
    }

    try
    {
        Value mode = Value.undefined;
        if (desktopMode)
            mode = Value(false);
        else if (serverMode)
            mode = Value(true);
        loadConfig(webDir, mode);
        configureLogging(cast(int) cfgInt("CONSOLE_LOG_LEVEL"), cast(int) cfgInt("FILE_LOG_LEVEL"),
                cfgBool("SERVER_MODE") ? cfgStr("LOG_FILE") : cfgStr("LOG_FILE"), cfgBool("JSON_LOGGER"));
        logInfo("Starting " ~ cfgStr("APP_NAME") ~ " v" ~ cfgStr("APP_VERSION") ~ "...");
        initConfigDb(cfgStr("SQLITE_PATH"), setupEmail.length ? setupEmail : null,
                setupPassword.length ? setupPassword : null);
        import std.process : environment;
        setRuntime(environment.get("PGADMIN_INT_KEY", ""));
        createFlaskApp();
    }
    catch (Exception e)
    {
        stderr.writeln("Startup failed: ", e.msg);
        return 1;
    }

    ServerConfig cfg;
    cfg.host = host.length ? host : cfgStr("DEFAULT_SERVER");
    cfg.port = cast(ushort)(port ? port : cfgInt("DEFAULT_SERVER_PORT"));
    // pgAdmin keeps connections and sessions in process memory: one worker
    cfg.workers = 1;
    cfg.limits.maxBodyBytes = 512 << 20;
    cfg.requestTimeoutMs = 600_000;
    cfg.fiberStackBytes = 8 << 20;
    stderr.writeln("Starting pgAdmin 4. Please navigate to http://", cfg.host, ":", cfg.port, " in your browser.");
    serve(() @trusted { return buildAndaimeApp(); }, cfg);
    return 0;
}

App buildAndaimeApp()
{
    import pgadmin.web.socketio : installSocketIo;
    auto app = new App;
    installSocketIo(app);
    flaskApp.install(app);
    return app;
}
