/// Template loader with pgAdmin's version-aware lookup.
///
/// Flask searches the application's template folder and then every blueprint's `templates` folder, in registration
/// order. pgAdmin wraps that with `VersionedTemplateLoader`: a name such as `sequences/sql/#160000#/properties.sql`
/// (or `#gpdb#80323#`) is resolved by trying `16_plus/`, `15_plus/`, ... down to `default/` and taking the first
/// directory whose version is not above the server's.
module pgadmin.jinja.loader;

import std.algorithm : startsWith;
import std.array : split, join;
import std.conv : to;
import std.file : exists, isFile, readText;
import std.path : buildPath;
import std.string : strip;
import pgadmin.jinja.runtime : Loader, TemplateNotFound;

struct VersionDir
{
    string name;
    long number;
}

immutable VersionDir[] versionMapping = [
    VersionDir("18_plus", 180000),
    VersionDir("17_plus", 170000),
    VersionDir("16_plus", 160000),
    VersionDir("15_plus", 150000),
    VersionDir("14_plus", 140000),
    VersionDir("13_plus", 130000),
    VersionDir("12_plus", 120000),
    VersionDir("11_plus", 110000),
    VersionDir("default", 0),
];

final class VersionedLoader : Loader
{
    /// Template folders, searched in order.
    string[] searchPaths;

    this(string[] searchPaths)
    {
        this.searchPaths = searchPaths;
    }

    string load(string name, out string cacheKey)
    {
        auto parts = name.split("#");
        if (parts.length == 1)
            return loadPlain(name, cacheKey);
        long ver;
        if (parts.length == 3)
            ver = to!long(parts[1]);
        else if (parts.length >= 4)
            ver = to!long(parts[2]);
        else
            throw new TemplateNotFound(name);
        auto dir = stripSlashes(parts[0]);
        auto file = stripSlashes(parts[$ - 1]);
        foreach (m; versionMapping)
        {
            if (m.number > ver)
                continue;
            auto p = dir ~ "/" ~ m.name ~ "/" ~ file;
            string key;
            auto src = tryPlain(p, key);
            if (src !is null)
            {
                cacheKey = key;
                return src;
            }
        }
        throw new TemplateNotFound(name);
    }

    private static string stripSlashes(string s)
    {
        while (s.length && (s[0] == '/' || s[0] == '\\'))
            s = s[1 .. $];
        while (s.length && (s[$ - 1] == '/' || s[$ - 1] == '\\'))
            s = s[0 .. $ - 1];
        return s;
    }

    private string loadPlain(string name, out string cacheKey)
    {
        auto src = tryPlain(name, cacheKey);
        if (src is null)
            throw new TemplateNotFound(name);
        return src;
    }

    /// Jinja's `split_template_path` + FileSystemLoader over every search path.
    private string tryPlain(string name, out string cacheKey)
    {
        string[] pieces;
        foreach (p; name.split("/"))
        {
            if (p == "..")
                throw new TemplateNotFound(name);
            if (p.length && p != ".")
                pieces ~= p;
        }
        auto rel = pieces.join("/");
        foreach (dir; searchPaths)
        {
            auto full = buildPath(dir, rel);
            if (full.exists && full.isFile)
            {
                cacheKey = full;
                auto src = readText(full);
                return src is null ? "" : src;
            }
        }
        return null;
    }
}
