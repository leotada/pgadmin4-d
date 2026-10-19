/// Helpers shared by the tools that run a PostgreSQL utility in the background (backup, restore, maintenance, import/export).
module pgadmin.tools.utility_common;

import std.algorithm : canFind;
import std.array : join, replace;
import std.file : exists;
import std.path : absolutePath, baseName, dirName, buildNormalizedPath, buildPath;
import pgadmin.browser.common;
import pgadmin.utils.paths : getCompleteFilePath, getStorageDirectory;

/// `does_utility_exist(file)`: an error message or null.
string doesUtilityExist(string file)
{
    string errorMsg;
    if (file is null)
        return gettext("Utility file not found. Please correct the Binary Path in the Preferences");
    auto storage = buildNormalizedPath(absolutePath(cfgStr("STORAGE_DIR")));
    auto f = buildNormalizedPath(absolutePath(file));
    if (f == storage || f.startsWith(storage ~ "/"))
        errorMsg = gettext("Please correct the Binary Path in the Preferences. pgAdmin storage directory cannot be a utility binary directory.");
    if (!exists(file))
        errorMsg = gettext("'%s' file not found. Please correct the Binary Path in the Preferences").replace("%s", file);
    return errorMsg;
}

/// `escape_dquotes_process_arg`
string escapeDquotesProcessArg(string arg)
{
    if (arg.length >= 1 && arg[0] == '"' && arg[$ - 1] == '"')
        return "#DQ#" ~ arg ~ "#DQ#";
    return arg;
}

/// The `cmd_arg` helper of the message classes: ` "arg"` with backslashes and quotes escaped.
string cmdArg(string x)
{
    if (x.length)
    {
        x = x.replace("\\", "\\\\");
        x = x.replace("\"", "\\\"");
        x = x.replace("\"\"", "\\\"");
        return " \"" ~ x ~ "\"";
    }
    return "";
}

/// `IProcessDesc.current_storage_dir`
Value currentStorageDir(string bfile, bool isImport = false)
{
    if (!cfgBool("SERVER_MODE"))
        return Value(null);
    auto path = getCompleteFilePath(bfile);
    if (path is null)
        path = bfile;
    auto storage = getStorageDirectory();
    string lastDir;
    if (storage !is null && path.canFind(baseName(storage)))
    {
        auto sd = baseName(storage);
        auto start = path.indexOf(sd);
        lastDir = dirName(path[start + sd.length .. $]);
    }
    else
        lastDir = bfile;
    return isImport ? Value(null) : Value(lastDir);
}

/// The `get_server_name()` of the backup/restore messages: "name (Service: x: host: port)".
string serverNameForArgs(Value server, string[] args, long sid, bool useArgs)
{
    if (server.isNone)
        return gettext("Not available");
    string host, port;
    if (useArgs && args.length)
    {
        string getArg(string val)
        {
            foreach (i, a; args)
                if (a == val && i + 1 < args.length)
                    return args[i + 1];
            return null;
        }

        host = getArg("--host");
        port = getArg("--port");
    }
    else
    {
        host = server.get("host").isNone ? null : server["host"].toString;
        port = server.get("port").isNone ? null : server["port"].toString;
    }
    string[] parts;
    if (server.get("service").truthy)
        parts ~= gettext("Service") ~ ": " ~ server["service"].toString;
    if (host.length)
        parts ~= host;
    if (port.length)
        parts ~= port;
    if (server.get("service").truthy || host.length || port.length)
        return server["name"].toString ~ " (" ~ parts.join(": ") ~ ")";
    return server["name"].toString;
}

/// `gettext(...).format(a, b)` for `%s` templates: each placeholder gets its own argument.
string fmtS(string tmpl, string[] args...)
{
    string r;
    size_t ai;
    for (size_t i = 0; i < tmpl.length; i++)
    {
        if (tmpl[i] == '%' && i + 1 < tmpl.length && tmpl[i + 1] == 's' && ai < args.length)
        {
            r ~= args[ai++];
            i++;
        }
        else
            r ~= tmpl[i];
    }
    return r;
}
