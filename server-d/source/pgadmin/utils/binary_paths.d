/// Locating pg_dump, pg_restore and psql (`ServerType.utility`).
module pgadmin.utils.binary_paths;

import pgadmin.core.config;
import pgadmin.core.value;
import pgadmin.utils.preferences : Preferences;

/// `replace_binary_path`: "$DIR" stands for the directory of the application.
string replaceBinaryPath(string binaryPath)
{
    import std.array : replace;
    import std.string : indexOf;
    if (binaryPath.indexOf("$DIR") >= 0)
        return binaryPath.replace("$DIR", cfgStr("PGADMIN_WEB_DIR"));
    return binaryPath;
}

/// `ServerType.get_utility_path(sversion)`: the binary directory configured for this server version.
string getUtilityPath(string serverType, int sversion)
{
    auto paths = Preferences.module_("paths", false);
    if (paths is null)
        return null;
    auto p = paths.preference(serverType == "ppas" ? "ppas_bin_dir" : "pg_bin_dir");
    if (p is null)
        return null;
    auto v = p.get();
    if (v.isNone)
        return null;
    auto list = tryParseJson(v.toString, Value(null));
    if (!list.isList)
        return null;
    string defaultPath;
    foreach (binPath; list.list.items)
    {
        import std.conv : to;
        import std.string : strip;
        auto bp = binPath.get("binaryPath");
        if (to!long(binPath["version"].toString) <= sversion && sversion < to!long(binPath["next_major_version"].toString)
                && !bp.isNone && bp.toString.strip != "")
            return bp.toString;
        if (binPath.get("isDefault").truthy && !bp.isNone && bp.toString != "")
            defaultPath = bp.toString;
    }
    return defaultPath;
}

/// Path of the utility for `operation` (backup, restore, ...): `ServerType.utility`; null when no binary path is set.
string utilityPath(string serverType, string operation, int sversion)
{
    import std.path : absolutePath, buildNormalizedPath;
    string res;
    switch (operation)
    {
    case "backup": res = "pg_dump"; break;
    case "backup_server": res = "pg_dumpall"; break;
    case "restore": res = "pg_restore"; break;
    case "sql": res = "psql"; break;
    default:
        throw new Exception("Could not find the utility for the operation '" ~ operation ~ "'");
    }
    auto bin = getUtilityPath(serverType, sversion);
    if (bin is null)
        return null;
    return buildNormalizedPath(absolutePath(replaceBinaryPath(bin)), res);
}

/// `get_binary_path_versions(path)`: version string of each utility found in `path`.
string[string] getBinaryPathVersions(string path)
{
    import std.file : exists;
    import std.path : buildPath;
    import std.process : execute;
    import std.string : strip;
    string[string] r;
    foreach (u; ["pg_dump", "pg_dumpall", "pg_restore", "psql"])
    {
        auto exe = buildPath(path, u);
        if (!exe.exists)
        {
            r[u] = "";
            continue;
        }
        try
        {
            auto res = execute([exe, "--version"]);
            r[u] = res.status == 0 ? res.output.strip : "";
        }
        catch (Exception)
            r[u] = "";
    }
    return r;
}
