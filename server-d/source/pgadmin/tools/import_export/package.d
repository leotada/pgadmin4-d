/// `pgadmin/tools/import_export`: COPY table data to/from files through psql.
module pgadmin.tools.import_export;

import std.algorithm : canFind;
import pgadmin.browser.common;
import pgadmin.misc.bgprocess.processes : BatchProcess;
import pgadmin.misc.file_manager : filenameWithFileManagerPath, PermissionError;
import pgadmin.settings : getSetting, storeSetting;
import pgadmin.tools.utility_common;
import pgadmin.utils.paths : getStorageDirectory;
import pgadmin.utils.server_access;
import pgadmin.web.flask;

private enum NOT_NULL_COLUMNS = "not_null_columns";
private enum NULL_COLUMNS = "null_columns";

private Value ieDesc(string[] args, Value server, string sid, Value schema, Value table, string database, bool isImport,
        string filename, string storage)
{
    string cmd;
    bool replaceNext;
    if (storage !is null)
        storage = storage.replace("\\", "/");
    foreach (arg; args)
    {
        if (arg.length >= 2 && arg.startsWith("--"))
        {
            if (arg == "--command")
                replaceNext = true;
            cmd ~= " " ~ arg;
        }
        else if (replaceNext)
        {
            auto a = cmdArg(arg);
            if (storage !is null)
                a = a.replace(storage, "<STORAGE_DIR>");
            cmd ~= " \"" ~ a ~ "\"";
        }
        else
            cmd ~= cmdArg(arg);
    }
    string serverName = "Not available";
    if (!server.isNone)
    {
        string hp;
        if (server.get("host").truthy)
            hp = server.get("port").truthy ? "(" ~ server["host"].toString ~ ":" ~ server["port"].toString ~ ")" : server["host"].toString;
        serverName = server["name"].toString ~ " " ~ hp;
    }
    string message, typeDesc;
    if (schema.isNone && table.isNone)
    {
        message = gettext("Copying table data using query on database '%s' and server '%s'");
        message = fmtS(message, database, serverName);
        typeDesc = gettext("Export - Copying table data using query");
    }
    else
    {
        message = gettext("Copying table data '%s.%s' on database '%s' and server '%s'");
        message = fmtS(message, schema.toString, table.toString, database, serverName);
        typeDesc = (isImport ? gettext("Import - ") : gettext("Export - ")) ~ gettext("Copying table data");
    }
    string objectStr = (schema.isNone && table.isNone) ? database : database ~ "/" ~ schema.toString ~ "." ~ table.toString;
    return Value.dictOf("message", message, "type_desc", typeDesc, "details",
            Value.dictOf("message", message, "cmd", cmd, "server", serverName, "object", objectStr, "type",
                isImport ? gettext("Import Data") : gettext("Export Data")), "current_storage_dir",
            currentStorageDir(filename, isImport));
}

private string columnsToString(Value columns)
{
    string cols;
    foreach (col; columns.iterItems())
    {
        cols = cols is null ? "(" : cols ~ ", ";
        cols ~= qtIdentStr(col.toString);
    }
    return cols ~ ")";
}

private string forceQuoteColumns(Value data)
{
    if (!data.contains("force_quote_columns"))
        return null;
    auto fq = data["force_quote_columns"];
    if (data.get("is_query_export").truthy && fq.contains(Value("*")))
        return "*";
    if (data.contains("total_columns") && fq.length == data["total_columns"].integer)
        return "*";
    if (fq.length > 0)
        return columnsToString(fq);
    return null;
}

private string formattedColumnList(Value data, string key, ServerManager manager)
{
    if (!data.contains(key))
        return null;
    if (data.contains("total_columns") && manager.version_ >= 170000 && [NULL_COLUMNS, NOT_NULL_COLUMNS].canFind(key)
            && data[key].length == data["total_columns"].integer)
        return "*";
    auto columns = data[key];
    if (columns.length > 0)
        return columnsToString(columns);
    return null;
}

private void saveImportExportSettings(Value settings)
{
    auto s = Value.newDict();
    foreach (k, v; settings.dict)
        if (!["columns", "database", "schema", "table", "save_btn_icon", "not_null_columns", "null_columns",
                "force_quote_columns", "total_columns", "is_query_export"].canFind(k))
            s[k] = v;
    if (s["is_import"].truthy)
        s["import_file_name"] = s["filename"];
    else
        s["export_file_name"] = s["filename"];
    auto old = getSetting("import_export_setting", null);
    if (old !is null && old != "null")
        s = s; // the old settings are merged into a copy that is then dropped (the Python code stores `settings`)
    else
    {
        if (!s.contains("import_file_name"))
            s["import_file_name"] = Value("");
        else if (!s.contains("export_file_name"))
            s["export_file_name"] = Value("");
    }
    storeSetting("import_export_setting", s.toJsonSpaced);
}

private bool isQueryParensBalanced(string query)
{
    long depth;
    size_t i;
    immutable length = query.length;
    while (i < length)
    {
        char ch = query[i];
        if (ch == '\'')
        {
            i++;
            while (i < length)
            {
                if (query[i] == '\\')
                    return false;
                else if (query[i] == '\'')
                {
                    if (i + 1 < length && query[i + 1] == '\'')
                        i += 2;
                    else
                        break;
                }
                else
                    i++;
            }
            if (i >= length)
                return false;
            i++;
            continue;
        }
        if (ch == '"')
        {
            i++;
            while (i < length)
            {
                if (query[i] == '"')
                {
                    if (i + 1 < length && query[i + 1] == '"')
                        i += 2;
                    else
                        break;
                }
                else
                    i++;
            }
            if (i >= length)
                return false;
            i++;
            continue;
        }
        if (ch == '(')
            depth++;
        else if (ch == ')')
        {
            depth--;
            if (depth < 0)
                return false;
        }
        i++;
    }
    return depth >= 0;
}

final class ImportExportModule : Blueprint
{
    this()
    {
        super("import_export", "/import_export");
    }

    override string[] getExposedUrlEndpoints() => ["import_export.create_job", "import_export.utility_exists",
        "import_export.get_settings"];

    override void setup()
    {
        route("/", "index", ["GET"], loginRequired((Dict a) => badRequest(gettext("This URL cannot be called directly."))));
        route("/job/<int:sid>", "create_job", ["POST"], permissionsRequired(loginRequired((Dict a) => createJob(a)),
                "tools_import_export_data"));
        route("/get_settings/", "get_settings", ["GET"], permissionsRequired(loginRequired((Dict a) {
            auto s = getSetting("import_export_setting", null);
            if (s is null)
                return makeJsonResponseAny(Value(true), Value(""), Value(""), Value(null), Value.newDict());
            return makeJsonResponseAny(Value(true), Value(""), Value(""), Value(null), parseJson(s));
        }), "tools_import_export_data"));
        route("/utility_exists/<int:sid>", "utility_exists", ["GET"], permissionsRequired(loginRequired((Dict a) {
            auto server = getServer(a["sid"].integer);
            if (server.isNone)
                return makeJsonResponse(0, Value(SERVER_NOT_FOUND));
            auto manager = getDriver().connectionManager(server["id"].integer);
            auto retVal = doesUtilityExist(manager.utility("sql"));
            if (retVal.length)
                return makeJsonResponse(0, Value(retVal));
            return makeJsonResponse(1);
        }), "tools_import_export_data"));
    }

    private static Response createJob(Dict a)
    {
        auto sid = a["sid"];
        auto req = request();
        Value data = !req.form.empty ? parseJson(req.form.get("data")) : parseJson(req.text);
        auto server = getServer(sid.integer);
        if (server.isNone)
            return badRequest(gettext("Could not find the specified server."));
        auto manager = getDriver().connectionManager(server["id"].integer);
        auto conn = manager.connection();
        if (!conn.connected())
            return badRequest(gettext("Please connect to the server first..."));
        auto utility = manager.utility("sql");
        auto retVal = doesUtilityExist(utility);
        if (retVal.length)
            return makeJsonResponse(0, Value(retVal));
        auto newSettings = data.deepCopy();
        auto storageDir = getStorageDirectory();
        if (data.contains("filename"))
        {
            string file;
            try
                file = filenameWithFileManagerPath(data["filename"].toString, !data["is_import"].truthy);
            catch (PermissionError e)
                return unauthorized(e.msg);
            catch (Exception e)
                return badRequest(e.msg);
            if (file.length == 0)
                return badRequest(gettext("Please specify a valid file."));
            data["filename"] = file;
        }
        else
            return badRequest(gettext("Please specify a valid file."));
        auto fmt = data.get("format", Value(""));
        if (!fmt.isString)
            return badRequest(gettext("Format must be a string."));
        if (!["csv", "text", "binary"].canFind(fmt.str.toLower))
            return badRequest(gettext("Invalid format specified."));
        data["format"] = Value(fmt.str.toLower);
        if (data.contains("on_error"))
        {
            auto v = data["on_error"];
            if (!v.isString)
                return badRequest(gettext("on_error must be a string."));
            if (!["stop", "ignore"].canFind(v.str.toLower))
                return badRequest(gettext("Invalid on_error value."));
            data["on_error"] = Value(v.str.toLower);
        }
        if (data.contains("log_verbosity"))
        {
            auto v = data["log_verbosity"];
            if (!v.isString)
                return badRequest(gettext("log_verbosity must be a string."));
            if (!["default", "verbose"].canFind(v.str.toLower))
                return badRequest(gettext("Invalid log_verbosity value."));
            data["log_verbosity"] = Value(v.str.toLower);
        }
        auto cols = formattedColumnList(data, "columns", manager);
        auto notNullCols = formattedColumnList(data, NOT_NULL_COLUMNS, manager);
        auto nullCols = formattedColumnList(data, NULL_COLUMNS, manager);
        auto quoteCols = forceQuoteColumns(data);
        saveImportExportSettings(newSettings);
        // update_data_for_import_export
        if (data.get("is_query_export") == Value(true))
        {
            foreach (k; ["on_error", "log_verbosity", "freeze", "default_string"])
                data.dict.remove(k);
            data["is_import"] = Value(false);
        }
        else
            data.dict.remove("query");
        if (data.get("is_query_export") == Value(true))
        {
            auto q = data.get("query");
            if (!q.isString || q.str.strip.length == 0)
                return badRequest(gettext("Query is required for query-based export."));
            if (q.str.canFind('\0'))
                return badRequest(gettext("The query contains invalid characters."));
            auto query = q.str.replace("\r\n", " ").replace("\r", " ").replace("\n", " ");
            if (!isQueryParensBalanced(query))
                return badRequest(gettext("The query contains unbalanced parentheses."));
            data["query"] = Value(query);
        }
        auto tempPath = "import_export/sql/#" ~ to!string(manager.version_) ~ "#/cmd.sql";
        auto query = renderTemplate(tempPath, tv("conn", conn, "data", data, "columns", cols is null ? Value(null) : Value(cols),
                "not_null_columns", notNullCols is null ? Value(null) : Value(notNullCols), "null_columns",
                nullCols is null ? Value(null) : Value(nullCols), "force_quote_columns",
                quoteCols is null ? Value(null) : Value(quoteCols)));
        string[] args = ["--command", query];
        try
        {
            auto desc = ieDesc(args, server, sid.toString, data.get("schema"), data.get("table"), data["database"].toString,
                    data["is_import"].truthy, data["filename"].toString, storageDir);
            auto p = BatchProcess.create(desc, utility, args);
            string[string] env;
            if (server.get("host").truthy)
                env["PGHOST"] = server["host"].toString;
            if (server.get("port").truthy)
                env["PGPORT"] = server["port"].toString;
            if (server.get("username").truthy)
                env["PGUSER"] = server["username"].toString;
            env["PGDATABASE"] = data["database"].toString;
            p.setEnvVariables(server, manager, env);
            p.start();
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value.dictOf("job_id", p.id, "desc", desc["message"],
                    "success", 1), 200);
        }
        catch (Exception e)
        {
            logException(e);
            return badRequest(e.msg);
        }
    }
}
