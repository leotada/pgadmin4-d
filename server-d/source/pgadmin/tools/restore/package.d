/// `pgadmin/tools/restore`: pg_restore / psql jobs.
module pgadmin.tools.restore;

import std.array : join;
import std.random : uniform;
import pgadmin.browser.common;
import pgadmin.misc.bgprocess.processes : BatchProcess;
import pgadmin.misc.file_manager : filenameWithFileManagerPath;
import pgadmin.tools.utility_common;
import pgadmin.utils.paths : getCompleteFilePath;
import pgadmin.utils.server_access;
import pgadmin.web.flask;

private Value restoreDesc(Value server, string bfile, string[] args, string database, string utility)
{
    string cmd;
    foreach (arg; args)
    {
        auto idx = arg.indexOf(RESTRICT_COMMAND);
        if (arg.length && idx >= 0)
        {
            auto i = idx + RESTRICT_COMMAND.length;
            auto masked = arg[0 .. i + 1] ~ replicateX(arg.length - i - 1);
            cmd ~= cmdArg(masked);
        }
        else if (arg.length >= 2 && arg.startsWith("--"))
            cmd ~= " " ~ arg;
        else
            cmd ~= cmdArg(arg);
    }
    auto serverName = serverNameForArgs(server, args, 0, true);
    auto message = fmtS(gettext("Restoring backup on the server '%s'"), serverName);
    auto createMessage = fmtS(gettext("Restoring backup on the server '%s'"), serverNameForArgs(server, null, 0, false));
    return Value.dictOf("message", createMessage, "list_message", message, "type_desc", gettext("Restoring backup on the server"), "details",
            Value.dictOf("message", message, "cmd", utility ~ cmd, "server", serverName, "object",
                database is null ? Value("") : Value(database), "type", gettext("Restore")), "current_storage_dir",
            Value(null));
}

private string replicateX(long n)
{
    string r;
    foreach (i; 0 .. n)
        r ~= 'x';
    return r;
}

private void setParam(Value data, ref string[] args, string key, string param, out bool set)
{
    set = false;
    if (data.contains(key) && data[key].truthy)
    {
        args ~= param;
        set = true;
    }
}

private void setValue(Value data, ref string[] args, string key, string param)
{
    if (data.contains(key) && !data[key].isNone && data[key] != Value(""))
        args ~= [param, data[key].toString];
}

private bool setMultiple(Value data, ref string[] args, string key, string param)
{
    if (data.contains(key) && data[key].length > 0)
    {
        foreach (o; data[key].iterItems())
            args ~= [param, o.toString];
        return true;
    }
    return false;
}

private string[] getRestoreUtilArgs(Value data, ServerManager manager, Value server, string filepath)
{
    string[] args;
    bool ignore;
    void p(string key, string param)
    {
        bool s;
        setParam(data, args, key, param, s);
    }

    if (data.contains("list"))
        args ~= "--list";
    else
    {
        auto host = server.get("host");
        auto port = server.get("port");
        if (host.truthy)
            args ~= ["--host", host.toString];
        if (port.truthy)
            args ~= ["--port", port.toString];
        if (server.get("username").truthy)
            args ~= ["--username", server["username"].toString];
        args ~= "--no-password";
        setValue(data, args, "role", "--role");
        args ~= "--dbname=";
        if (data["format"] == Value("directory"))
            args ~= "--format=d";
        setValue(data, args, "no_of_jobs", "--jobs");
        p("pre_data", "--section=pre-data");
        p("data", "--section=data");
        p("post_data", "--section=post-data");
        bool onlyData;
        setParam(data, args, "only_data", "--data-only", onlyData);
        if (!onlyData)
        {
            p("dns_owner", "--no-owner");
            p("dns_privilege", "--no-privileges");
            p("dns_tablespace", "--no-tablespaces");
            if (manager.version_ >= 110000)
            {
                p("dns_comments", "--no-comments");
                p("dns_publications", "--no-publications");
                p("dns_subscriptions", "--no-subscriptions");
                p("dns_security_labels", "--no-security-labels");
            }
            if (manager.version_ >= 150000)
                p("dns_table_access_method", "--no-table-access-method");
        }
        p("include_create_database", "--create");
        p("clean", "--clean");
        p("if_exists", "--if-exists");
        p("single_transaction", "--single-transaction");
        p("enable_row_security", "--enable-row-security");
        p("no_data_fail_table", "--no-data-for-failed-tables");
        bool onlySchema;
        setParam(data, args, "only_schema", "--schema-only", onlySchema);
        if (!onlySchema)
            p("disable_trigger", "--disable-triggers");
        p("verbose", "--verbose");
        p("use_set_session_auth", "--use-set-session-authorization");
        p("exit_on_error", "--exit-on-error");
        setValue(data, args, "exclude_schema", "--exclude-schema");
        setMultiple(data, args, "schemas", "--schema");
        setMultiple(data, args, "tables", "--table");
        setMultiple(data, args, "functions", "--function");
        setMultiple(data, args, "triggers", "--trigger");
        setMultiple(data, args, "trigger_funcs", "--function");
        setMultiple(data, args, "indexes", "--index");
    }
    args ~= filepath;
    return args;
}

private string[] getSqlUtilArgs(Value server, string filepath)
{
    import std.format : format;
    string key;
    foreach (i; 0 .. 32)
        key ~= format("%02x", uniform(0, 256));
    string[] args = ["-c", "\\restrict " ~ key, "--file", filepath];
    if (server.get("host").truthy)
        args ~= ["--host", server["host"].toString];
    if (server.get("port").truthy)
        args ~= ["--port", server["port"].toString];
    if (server.get("username").truthy)
        args ~= ["--username", server["username"].toString];
    return args;
}

final class RestoreModule : Blueprint
{
    this()
    {
        super("restore", "/restore");
        staticUrlPath = "";
    }

    override string[] getExposedUrlEndpoints() => ["restore.create_job", "restore.utility_exists"];

    override void setup()
    {
        route("/", "index", ["GET"], loginRequired((Dict a) => badRequest(gettext("This URL cannot be called directly."))));
        route("/job/<int:sid>", "create_job", ["POST"], permissionsRequired(loginRequired((Dict a) => createRestoreJob(a)), "tools_restore"));
        route("/utility_exists/<int:sid>", "utility_exists", ["GET"], permissionsRequired(loginRequired((Dict a) {
            auto server = getServer(a["sid"].integer);
            if (server.isNone)
                return makeJsonResponse(0, Value(SERVER_NOT_FOUND));
            auto manager = getDriver().connectionManager(server["id"].integer);
            auto retVal = doesUtilityExist(manager.utility("restore"));
            if (retVal.length)
                return makeJsonResponse(0, Value(retVal));
            return makeJsonResponse(1);
        }), "tools_restore"));
    }

    private static Response createRestoreJob(Dict a)
    {
        auto sid = a["sid"];
        auto req = request();
        Value data = !req.form.empty ? parseJson(req.form.get("data")) : parseJson(req.text);
        string filepath;
        try
            filepath = filenameWithFileManagerPath(data["file"].toString);
        catch (Exception e)
            return internalServerError(e.msg);
        if (filepath is null)
            return makeJsonResponse(0, Value(gettext("File could not be found.")), Value(""), Value(null), Value(null), 410);
        if (!data.get("database").truthy)
            return badRequest(gettext("Database parameter is required."));
        auto server = getServer(sid.integer);
        if (server.isNone)
            return makeJsonResponse(0, Value(SERVER_NOT_FOUND));
        auto manager = getDriver().connectionManager(server["id"].integer);
        auto conn = manager.connection();
        if (!conn.connected())
            return makeJsonResponse(0, Value(gettext("Please connect to the server first.")));
        string utility;
        string[] args;
        string errorMsg;
        if (data["format"] == Value("plain"))
        {
            utility = manager.utility("sql");
            errorMsg = doesUtilityExist(utility);
            if (!errorMsg.length)
                args = getSqlUtilArgs(server, filepath);
        }
        else
        {
            utility = manager.utility("restore");
            errorMsg = doesUtilityExist(utility);
            if (!errorMsg.length)
                args = getRestoreUtilArgs(data, manager, server, filepath);
        }
        if (errorMsg.length)
            return makeJsonResponse(0, Value(errorMsg));
        try
        {
            string[string] env;
            if (data.get("database").truthy)
                env["PGDATABASE"] = data["database"].toString;
            auto desc = restoreDesc(server, data["file"].toString, args, data["database"].toString, utility);
            auto p = BatchProcess.create(desc, utility, args);
            p.setEnvVariables(server, manager, env);
            p.start();
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value.dictOf("job_id", p.id, "desc", desc["message"],
                    "Success", 1), 200);
        }
        catch (Exception e)
        {
            logException(e);
            return makeJsonResponse(0, Value(e.msg), Value(""), Value(null), Value(null), 410);
        }
    }
}
