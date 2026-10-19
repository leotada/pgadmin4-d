/// File system helpers (`pgadmin/utils/paths.py`, `get_complete_file_path`).
module pgadmin.utils.paths;

import std.file : exists, isFile, mkdirRecurse;
import std.path : buildPath;
import std.string : strip;
import pgadmin.core.config;
import pgadmin.core.value;
import pgadmin.utils.constants : MY_STORAGE;
import pgadmin.web.context;

/// `get_storage_directory(shared_storage=...)`: the per-user storage directory (server mode) or null (desktop: the
/// whole file system). `sharedStorage` names an entry of the SHARED_STORAGE setting.
string getStorageDirectory(string sharedStorage = "")
{
    if (!cfgBool("SERVER_MODE"))
        return null;
    string base;
    bool isShared;
    if (sharedStorage.length && sharedStorage != MY_STORAGE)
    {
        isShared = true;
        auto shared_ = ConfigAccess.get("SHARED_STORAGE");
        if (shared_.isList)
            foreach (sd; shared_.list.items)
                if (sd.isDict && sd.get("name") == Value(sharedStorage))
                    base = sd["path"].toString;
        if (base.length == 0)
            return null;
    }
    else
        base = cfgStr("STORAGE_DIR");
    string dir;
    if (isShared)
        dir = base;
    else
    {
        auto user = currentUserAttr("username").strOr("");
        string safe;
        foreach (c; user)
            safe ~= (c == '@' ? '_' : c);
        dir = buildPath(base, safe);
    }
    if (!dir.exists)
        mkdirRecurse(dir);
    return dir;
}

/// `get_complete_file_path(file, validate)`
string getCompleteFilePath(string file, bool validate = true)
{
    if (file is null || file.length == 0)
        return null;
    auto storage = getStorageDirectory();
    if (storage is null)
        return file.isFile ? file : null;
    auto full = buildPath(storage, file.strip.stripLeadingSlash);
    if (validate)
        return full.exists && full.isFile ? full : null;
    return full;
}

private string stripLeadingSlash(string s)
{
    while (s.length && (s[0] == '/' || s[0] == '\\'))
        s = s[1 .. $];
    return s;
}
