/// `pgadmin/tools/backup`: pg_dump / pg_dumpall jobs.
module pgadmin.tools.backup;

import std.algorithm : canFind;
import std.array : join;
import std.ascii : toUpper;
import pgadmin.browser.common;
import pgadmin.misc.bgprocess.processes : BatchProcess;
import pgadmin.misc.file_manager : filenameWithFileManagerPath, PermissionError;
import pgadmin.tools.grant_wizard : getData, GrantServerInfo;
import pgadmin.tools.utility_common;
import pgadmin.utils.server_access;
import pgadmin.web.flask;

enum BACKUP_GLOBALS = 1;
enum BACKUP_SERVER = 2;
enum BACKUP_OBJECT = 3;

private string backupTypeDesc(int t)
{
    switch (t)
    {
    case BACKUP_OBJECT: return gettext("Backing up an object on the server");
    case BACKUP_GLOBALS: return gettext("Backing up the global objects");
    case BACKUP_SERVER: return gettext("Backing up the server");
    default: return gettext("Unknown Backup");
    }
}

/// `BackupMessage`: the description of a backup process.
private Value backupDesc(int type, Value server, string bfile, string[] cmdArgs, string[] procArgs, string database,
        string utility)
{
    string cmd;
    foreach (arg; cmdArgs)
    {
        if (arg.length >= 2 && arg.startsWith("--"))
            cmd ~= " " ~ arg;
        else
            cmd ~= cmdArg(arg);
    }
    auto serverNameCreate = serverNameForArgs(server, null, 0, false);
    auto serverName = serverNameForArgs(server, procArgs, 0, true);
    string message;
    if (type == BACKUP_OBJECT)
        message = gettext("Backing up an object on the server '%s' from database '%s'");
    else if (type == BACKUP_GLOBALS)
        message = gettext("Backing up the global objects on the server '%s'");
    else if (type == BACKUP_SERVER)
        message = gettext("Backing up the server '%s'");
    else
        message = "Unknown Backup";
    string createMessage = type == BACKUP_OBJECT ? fmtS(message, serverNameCreate, database) : fmtS(message, serverNameCreate);
    string finalMessage = type == BACKUP_OBJECT ? fmtS(message, serverName, database) : fmtS(message, serverName);
    string backupType = gettext("Backup");
    if (type == BACKUP_OBJECT)
        backupType = gettext("Backup Object");
    else if (type == BACKUP_GLOBALS)
        backupType = gettext("Backup Globals");
    else if (type == BACKUP_SERVER)
        backupType = gettext("Backup Server");
    return Value.dictOf("message", createMessage, "list_message", finalMessage, "type_desc", backupTypeDesc(type), "details",
            Value.dictOf("message", finalMessage, "cmd", utility ~ cmd, "server", serverName, "object",
                database is null ? Value(null) : Value(database), "type", backupType), "current_storage_dir",
            currentStorageDir(bfile));
}

private string[] getArgsParamsValues(Value data, Connection conn, string backupObjType, string backupFile, Value server,
        ServerManager manager)
{
    string[] args = ["--file", backupFile];
    auto host = server.get("host");
    auto port = server.get("port");
    if (host.truthy)
        args ~= ["--host", host.toString];
    if (port.truthy)
        args ~= ["--port", port.toString];
    if (manager.user.length)
        args ~= ["--username", manager.user];
    args ~= "--no-password";

    void setParam(string key, string param, bool assertion = true)
    {
        if (!assertion)
            return;
        if (data.get(key).truthy)
            args ~= param;
    }

    void setValue(string key, string param, bool assertion = true)
    {
        if (!assertion)
            return;
        auto val = data.get(key);
        if (val.truthy)
        {
            if (val.isList)
            {
                foreach (c; val.list.items)
                    args ~= [param, c.toString];
                return;
            }
            args ~= [param, val.toString];
        }
    }

    if (backupObjType != "objects")
    {
        args ~= "--database";
        args ~= server["maintenance_db"].toString;
    }
    if (backupObjType == "globals")
        args ~= "--globals-only";
    setValue("role", "--role");
    if (backupObjType == "objects" && data.get("format").truthy)
    {
        string f;
        switch (data["format"].toString)
        {
        case "custom": f = "c"; break;
        case "tar": f = "t"; break;
        case "plain": f = "p"; break;
        case "directory": f = "d"; break;
        default: throw new Exception("'" ~ data["format"].toString ~ "'");
        }
        args ~= "--format=" ~ f;
        bool ct = ["custom", "tar"].canFind(data["format"].toString);
        if (manager.version_ >= 160000)
            setParam("blobs", "--large-objects", ct);
        else
            setParam("blobs", "--blobs", ct);
        setValue("ratio", "--compress");
    }
    setValue("encoding", "--encoding");
    setValue("no_of_jobs", "--jobs");
    setParam("only_data", "--data-only", data.get("only_data").truthy);
    setParam("only_schema", "--schema-only", data.get("only_schema").truthy && !data.get("only_data").truthy);
    setParam("only_tablespaces", "--tablespaces-only", data.get("only_tablespaces").truthy);
    setParam("only_roles", "--roles-only", data.get("only_roles").truthy);
    setParam("pre_data", "--section=pre-data");
    setParam("data", "--section=data");
    setParam("post_data", "--section=post-data");
    setParam("dns_owner", "--no-owner");
    setParam("dns_privilege", "--no-privileges");
    setParam("dns_tablespace", "--no-tablespaces");
    setParam("dns_unlogged_tbl_data", "--no-unlogged-table-data");
    setParam("dns_comments", "--no-comments", manager.version_ >= 110000);
    setParam("dns_publications", "--no-publications", manager.version_ >= 110000);
    setParam("dns_subscriptions", "--no-subscriptions", manager.version_ >= 110000);
    setParam("dns_security_labels", "--no-security-labels", manager.version_ >= 110000);
    setParam("dns_toast_compression", "--no-toast-compression", manager.version_ >= 140000);
    setParam("dns_table_access_method", "--no-table-access-method", manager.version_ >= 150000);
    setParam("dns_no_role_passwords", "--no-role-passwords");
    setParam("use_insert_commands", "--inserts");
    setValue("max_rows_per_insert", "--rows-per-insert", manager.version_ >= 120000);
    setParam("on_conflict_do_nothing", "--on-conflict-do-nothing", manager.version_ >= 120000);
    setParam("include_create_database", "--create");
    setParam("include_drop_database", "--clean");
    setParam("if_exists", "--if-exists");
    setParam("use_column_inserts", "--column-inserts");
    setParam("load_via_partition_root", "--load-via-partition-root", manager.version_ >= 110000);
    setParam("enable_row_security", "--enable-row-security");
    setValue("exclude_table_data", "--exclude-table-data");
    setValue("table_and_children", "--table-and-children", manager.version_ >= 160000);
    setValue("exclude_table_and_children", "--exclude-table-and-children", manager.version_ >= 160000);
    setValue("exclude_table_data_and_children", "--exclude-table-data-and-children", manager.version_ >= 160000);
    setValue("exclude_table", "--exclude-table");
    setParam("disable_trigger", "--disable-triggers", data.get("only_data").truthy && data.get("format", Value("")) == Value("plain"));
    setParam("disable_quoting", "--disable-dollar-quoting");
    setParam("verbose", "--verbose");
    setParam("dqoute", "--quote-all-identifiers");
    setParam("use_set_session_auth", "--use-set-session-authorization");
    setValue("exclude_schema", "--exclude-schema");
    setValue("extra_float_digits", "--extra-float-digits", manager.version_ >= 120000);
    setValue("lock_wait_timeout", "--lock-wait-timeout");
    setValue("exclude_database", "--exclude-database", manager.version_ >= 160000);
    if (data.contains("schemas"))
        foreach (s; data["schemas"].iterItems())
            args ~= ["--schema", qtIdentStr(s.toString).replace("\"", "\"")];
    if (data.contains("tables"))
        foreach (t; data["tables"].iterItems())
            args ~= ["--table", qtIdentStr(t[0].toString, t[1].toString).replace("\"", "\"")];
    if (data.contains("objects"))
    {
        foreach (key, objs; data["objects"].dict)
        {
            auto param = key == "schema" ? "schema" : "table";
            if (objs.isNone)
                continue;
            foreach (s; objs.iterItems())
            {
                string val = s.isDict ? qtIdentStr(s["schema"].toString) ~ "." ~ qtIdentStr(s["name"].toString)
                    : qtIdentStr(s.toString);
                args ~= ["--" ~ param, val];
            }
        }
    }
    return args;
}

final class BackupModule : Blueprint
{
    this()
    {
        super("backup", "/backup");
        staticUrlPath = "";
    }

    override string[] getExposedUrlEndpoints() => ["backup.create_server_job", "backup.create_object_job",
        "backup.utility_exists", "backup.objects", "backup.schema_objects"];

    override void setup()
    {
        route("/", "index", ["GET"], loginRequired((Dict a) => badRequest(gettext("This URL cannot be called directly."))));
        View createJob = permissionsRequired(loginRequired((Dict a) => createBackupObjectsJob(a)), "tools_backup");
        route("/job/<int:sid>", "create_server_job", ["POST"], createJob);
        route("/job/<int:sid>/object", "create_object_job", ["POST"], createJob);
        route("/utility_exists/<int:sid>/<backup_obj_type>", "utility_exists", ["GET"],
                permissionsRequired(loginRequired((Dict a) => checkUtilityExists(a)), "tools_backup"));
        View objs = permissionsRequired(loginRequired((Dict a) => objects(a)), "tools_backup");
        route("/objects/<int:sid>/<int:did>", "objects", ["GET"], objs);
        route("/objects/<int:sid>/<int:did>/<int:scid>", "schema_objects", ["GET"], objs);
    }

    private static Response createBackupObjectsJob(Dict a)
    {
        auto sid = a["sid"];
        auto data = parseJson(request().text);
        auto backupObjType = data.get("type", Value("objects")).toString;
        string backupFile;
        try
            backupFile = filenameWithFileManagerPath(data["file"].toString, data.get("format", Value("")) != Value("directory"));
        catch (PermissionError e)
            return unauthorized(e.msg);
        catch (Exception e)
            return badRequest(e.msg);
        auto server = getServer(sid.integer);
        if (server.isNone)
            return makeJsonResponse(0, Value(SERVER_NOT_FOUND));
        auto manager = getDriver().connectionManager(server["id"].integer);
        auto conn = manager.connection();
        if (!conn.connected())
            return makeJsonResponse(0, Value(gettext("Please connect to the server first.")));
        auto utility = manager.utility(backupObjType == "objects" ? "backup" : "backup_server");
        auto retVal = doesUtilityExist(utility);
        if (retVal.length)
            return makeJsonResponse(0, Value(retVal));
        auto args = getArgsParamsValues(data, conn, backupObjType, backupFile, server, manager);
        string[] escaped;
        foreach (arg; args)
            escaped ~= escapeDquotesProcessArg(arg);
        try
        {
            string[string] env;
            Value desc;
            string bfile = data["file"].toString;
            if (backupObjType == "objects")
            {
                env["PGDATABASE"] = data["database"].toString;
                desc = backupDesc(BACKUP_OBJECT, server, bfile, args, escaped, data["database"].toString, utility);
            }
            else
                desc = backupDesc(backupObjType != "globals" ? BACKUP_SERVER : BACKUP_GLOBALS, server, bfile, args, escaped, null, utility);
            auto p = BatchProcess.create(desc, utility, escaped);
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

    private static Response checkUtilityExists(Dict a)
    {
        auto server = getServer(a["sid"].integer);
        if (server.isNone)
            return makeJsonResponse(0, Value(SERVER_NOT_FOUND));
        auto manager = getDriver().connectionManager(server["id"].integer);
        auto utility = manager.utility(a["backup_obj_type"].toString == "objects" ? "backup" : "backup_server");
        auto retVal = doesUtilityExist(utility);
        if (retVal.length)
            return makeJsonResponse(0, Value(retVal));
        return makeJsonResponse(1);
    }

    private static Response objects(Dict a)
    {
        auto sid = a["sid"];
        auto did = a["did"];
        auto server = getServer(sid.integer);
        if (server.isNone)
            return makeJsonResponse(0, Value(SERVER_NOT_FOUND));
        GrantServerInfo info;
        info.manager = getDriver().connectionManager(sid.integer);
        info.conn = info.manager.connection(null, null, true, did);
        if (!info.conn.connected())
            return preconditionRequired(gettext("Connection to the server has been lost."));
        info.serverType = info.manager.serverType;
        info.version_ = info.manager.version_;
        if (info.serverType == "pg")
            info.templatePath = "grant_wizard/pg/#" ~ to!string(info.version_) ~ "#";
        else if (info.serverType == "ppas")
            info.templatePath = "grant_wizard/ppas/#" ~ to!string(info.version_) ~ "#";
        auto scid = a.has("scid") ? a["scid"] : Value(null);
        auto g = getData(sid, did, scid, a.has("scid") ? "schema" : "database", info);
        if (g.error !is null)
            return g.error;
        enum MVIEW = "materialized view";
        enum FTABLE = "foreign table";
        static immutable kinds = ["table", "view", MVIEW, FTABLE, "sequence"];
        // schema name -> {id, name, icon, children: {kind: [..]}}
        Value[] schemaGroup;
        string[] order;
        Value[string] groups;
        foreach (row; g.rows.iterItems())
        {
            auto objType = row["object_type"].toString.toLower;
            if (!kinds.canFind(objType))
                continue;
            auto nsp = row["nspname"].toString;
            if (nsp !in groups)
            {
                auto children = Value.newDict();
                foreach (k; kinds)
                    children[k] = Value.newList();
                groups[nsp] = Value.dictOf("id", nsp, "name", nsp, "icon", "icon-schema", "children", children, "is_schema", true);
                order ~= nsp;
            }
            string icon = objType == MVIEW ? "icon-mview" : objType == FTABLE ? "icon-foreign_table" : row["icon"].toString;
            groups[nsp]["children"][objType].append(Value.dictOf("id", nsp ~ "_" ~ row["name"].toString, "name", row["name"],
                    "icon", icon, "schema", nsp, "type", objType, "_name", nsp ~ "." ~ row["name"].toString));
        }
        foreach (nsp; order)
        {
            auto ch = groups[nsp];
            Value[] children;
            foreach (objType; kinds)
            {
                auto items = ch["children"][objType];
                if (items.length)
                {
                    string icon = objType == MVIEW ? "icon-coll-mview" : objType == FTABLE ? "icon-coll-foreign_table"
                        : "icon-coll-" ~ objType.toLower;
                    children ~= Value.dictOf("id", ch["id"].toString ~ "_" ~ objType, "name", titleCase(objType) ~ "s", "icon",
                            Value([Value(icon)]) /* a one-element tuple in Python */, "children", items, "type", objType,
                            "is_collection", true);
                }
            }
            ch["children"] = Value(children);
            schemaGroup ~= ch;
        }
        foreach (es; g.emptySchemas.iterItems())
            schemaGroup ~= Value.dictOf("id", es, "name", es, "icon", "icon-schema", "children", Value.newList(), "is_schema", true);
        return makeJsonResponse(200, Value(""), Value(""), Value(null), Value(schemaGroup), 200);
    }
}

private string titleCase(string s)
{
    string r;
    bool up = true;
    foreach (char c; s)
    {
        r ~= up ? cast(char) toUpper(c) : c;
        up = c == ' ';
    }
    return r;
}
