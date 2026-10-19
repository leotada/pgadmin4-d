/// Application configuration (`web/config.py`).
///
/// The defaults are the values of `config.py` (embedded from resources/config_defaults.json); the settings that
/// depend on the run mode or on DATA_DIR are recomputed here exactly as config.py and evaluate_config.py do.
///
/// Overrides, applied in this order (later wins), mirror config_distro.py / config_local.py / config_system.py:
///  - `config_distro.json`, `config_local.json` next to the executable or in the web directory,
///    `/etc/pgadmin/config_system.json`;
///  - the same file names with a `.py` extension, read as simple `NAME = <python literal>` assignments;
///  - environment variables `PGADMIN_CONFIG_<NAME>=<python literal>` (as the official container image does).
module pgadmin.core.config;

import std.algorithm : startsWith, endsWith;
import std.array : split;
import std.conv : to;
import std.file : exists, readText, isFile;
import std.path : buildPath, baseName, expandTilde, absolutePath, dirName, buildNormalizedPath;
import std.process : environment;
import std.string : strip, indexOf, toLower;
import pgadmin.core.value;
import pgadmin.core.log;

private __gshared Dict settings;

/// `config.NAME` → Value (undefined when the setting does not exist).
struct ConfigAccess
{
    Value opDispatch(string name)() const @trusted
    {
        return get(name);
    }

    static Value get(string name) @trusted
    {
        assert(settings !is null, "configuration not loaded");
        return settings.get(name, Value.undefined("config has no attribute '" ~ name ~ "'"));
    }

    static bool has(string name) @trusted => settings !is null && settings.has(name);

    static void set(T)(string name, T value) @trusted
    {
        settings[name] = Value(value);
    }

    /// All settings (for the template global `config`).
    static Dict all() @trusted => settings;
}

/// Global accessor: `config.SERVER_MODE.truthy`, `config.DATA_DIR.str`.
enum ConfigAccess config = ConfigAccess.init;

bool cfgBool(string name) => ConfigAccess.get(name).truthy;
string cfgStr(string name)
{
    auto v = ConfigAccess.get(name);
    return v.isNone ? null : v.toString;
}

long cfgInt(string name) => ConfigAccess.get(name).integer;

/// Directory of the original pgAdmin `web` tree (templates, static files, translations).
string webDir() => cfgStr("PGADMIN_WEB_DIR");
string pgadminDir() => buildPath(webDir(), "pgadmin");

/// Loads the configuration. `serverMode` overrides SERVER_MODE (like builtins.SERVER_MODE set by the runtime);
/// null means "decide from PGADMIN_SERVER_MODE / config files, default True".
void loadConfig(string webDirectory, Value serverMode = Value.undefined) @trusted
{
    settings = parseJson(import("config_defaults.json")).dict;
    settings["PGADMIN_WEB_DIR"] = Value(absolutePath(webDirectory).buildNormalizedPath);
    settings["CA_FILE"] = Value(buildPath(webDir(), "cacert.pem"));

    // builtins.SERVER_MODE, from the desktop runtime's PGADMIN_SERVER_MODE (pgAdmin4.py)
    bool serverModeSet;
    bool sm = true;
    if (!serverMode.isUndefined)
    {
        sm = serverMode.truthy;
        serverModeSet = true;
    }
    else if (auto e = environment.get("PGADMIN_SERVER_MODE"))
    {
        sm = e.toUpper_ != "OFF";
        serverModeSet = true;
    }

    // collect the custom settings first: SERVER_MODE may come from them
    auto custom = new Dict;
    void merge(Dict d)
    {
        if (d !is null)
            custom.update(d);
    }

    auto exeDir = dirName(absolutePath(executablePath()));
    foreach (name; ["config_distro", "config_local"])
    {
        if (name == "config_distro")
            if (auto p = environment.get("CONFIG_DISTRO_FILE_PATH"))
            {
                merge(loadSettingsFile(p));
                continue;
            }
        foreach (dir; [webDir(), exeDir])
        {
            merge(loadSettingsFile(buildPath(dir, name ~ ".py")));
            merge(loadSettingsFile(buildPath(dir, name ~ ".json")));
        }
    }
    merge(loadSettingsFile("/etc/pgadmin/config_system.py"));
    merge(loadSettingsFile("/etc/pgadmin/config_system.json"));
    foreach (k, v; environment.toAA)
        if (k.startsWith("PGADMIN_CONFIG_") && k != "PGADMIN_CONFIG_DEFAULT_SERVER")
        {
            auto name = k["PGADMIN_CONFIG_".length .. $];
            custom[name] = evalPythonLiteral(v, Value(v));
        }

    if (!serverModeSet && custom.has("SERVER_MODE"))
        sm = custom["SERVER_MODE"].truthy;
    settings["SERVER_MODE"] = Value(sm);

    // mode-dependent defaults (config.py)
    immutable appPath = settings["APP_PATH"].str;
    immutable appShort = settings["APP_SHORT_NAME"].str;
    string dataDir = sm ? buildPath("/var/lib/", appPath) : expandTilde("~/." ~ appPath);
    settings["DATA_DIR"] = Value(dataDir);
    settings["LOG_FILE"] = Value(sm ? buildPath("/var/log/", appPath, appShort ~ ".log") : buildPath(dataDir, appShort ~ ".log"));
    settings["SQLITE_PATH"] = Value(buildPath(dataDir, appShort ~ ".db"));
    settings["SESSION_DB_PATH"] = Value(buildPath(dataDir, "sessions"));
    settings["STORAGE_DIR"] = Value(buildPath(dataDir, "storage"));
    settings["TEST_SQLITE_PATH"] = Value(buildPath(dataDir, "test_pgadmin4.db"));
    settings["KERBEROS_CCACHE_DIR"] = Value(buildPath(dataDir, "krbccache"));
    settings["AZURE_CREDENTIAL_CACHE_DIR"] = Value(buildPath(dataDir, "azurecredentialcache"));
    if (!sm)
        settings["SESSION_EXPIRATION_TIME"] = Value(7);

    // evaluate_and_patch_config
    validateCustom(custom);
    if (custom.has("DATA_DIR"))
    {
        auto dd = custom["DATA_DIR"].toString;
        foreach (s; ["LOG_FILE", "SQLITE_PATH", "SESSION_DB_PATH", "AZURE_CREDENTIAL_CACHE_DIR", "KERBEROS_CCACHE_DIR",
                "STORAGE_DIR"])
            if (!custom.has(s))
                settings[s] = Value(buildPath(dd, baseName(settings[s].str)));
    }
    settings.update(custom);
    settings["SERVER_MODE"] = Value(sm);
    if (auto e = environment.get("PGADMIN_CONFIG_DEFAULT_SERVER"))
        settings["DEFAULT_SERVER"] = Value(e);
    if (!sm)
    {
        settings["USER_INACTIVITY_TIMEOUT"] = Value(0);
        settings["ENABLE_PSQL"] = Value(true);
    }
    if (!settings.has("USE_OS_SECRET_STORAGE") || !custom.has("USE_OS_SECRET_STORAGE"))
    {
        // The D port has no OS keyring backend: behave like Python when no keyring is available.
        settings["USE_OS_SECRET_STORAGE"] = Value(false);
        settings["KEYRING_NAME"] = Value("");
    }
    if (!custom.has("SESSION_COOKIE_PATH"))
        settings["SESSION_COOKIE_PATH"] = settings["COOKIE_DEFAULT_PATH"];
    if (auto sn = environment.get("SCRIPT_NAME"))
        if (sn.length)
        {
            settings["APPLICATION_ROOT"] = Value(sn);
            settings["SESSION_COOKIE_PATH"] = Value(sn);
        }
    if (!settings.has("APPLICATION_ROOT"))
        settings["APPLICATION_ROOT"] = Value("/");
    // Flask defaults the app reads through config
    foreach (k, v; ["MAX_CONTENT_LENGTH": Value(null), "PERMANENT_SESSION_LIFETIME": Value(null)])
        if (!settings.has(k))
            settings[k] = v;
}

private string toUpper_(string s)
{
    import std.uni : toUpper;
    return s.toUpper;
}

private string executablePath() @trusted
{
    import std.file : thisExePath;
    try
        return thisExePath();
    catch (Exception)
        return ".";
}

private void validateCustom(Dict custom)
{
    foreach (k; ["SERVER_MODE", "ENHANCED_COOKIE_PROTECTION", "SUPPORT_SSH_TUNNEL", "ALLOW_SAVE_TUNNEL_PASSWORD",
            "MASTER_PASSWORD_REQUIRED"])
        if (custom.has(k) && !custom[k].isBool)
            throw new Exception("Expected boolean value for " ~ k ~ "; got " ~ custom[k].repr);
    foreach (k; ["DEFAULT_SERVER_PORT", "SERVER_HEARTBEAT_TIMEOUT", "LOG_ROTATION_SIZE", "LOG_ROTATION_AGE",
            "LOG_ROTATION_MAX_LOG_FILES", "MAX_SESSION_IDLE_TIME"])
        if (custom.has(k) && !custom[k].isInt)
            throw new Exception("Expected integer value for " ~ k ~ "; got " ~ custom[k].repr);
}

/// Reads a JSON object file, or a Python file of `NAME = literal` lines. Null when the file does not exist.
Dict loadSettingsFile(string path)
{
    if (!path.exists || !path.isFile)
        return null;
    auto text = readText(path);
    if (path.endsWith(".json"))
    {
        auto v = parseJson(text);
        return v.isDict ? v.dict : null;
    }
    auto d = new Dict;
    // join continuation lines: a statement continues while brackets are open or the line ends with '\'
    string stmt;
    int depth;
    void flush()
    {
        auto s = stmt.strip;
        stmt = null;
        if (s.length == 0)
            return;
        auto eq = s.indexOf('=');
        if (eq <= 0)
            return;
        auto name = s[0 .. eq].strip;
        if (name.length == 0 || !isUpperName(name))
            return;
        auto rhs = s[eq + 1 .. $].strip;
        auto v = evalPythonLiteral(rhs, Value.undefined);
        if (v.isUndefined)
        {
            logWarning("config: cannot evaluate " ~ name ~ " in " ~ path ~ " (only literals are supported)");
            return;
        }
        d[name] = v;
    }

    foreach (line; text.split("\n"))
    {
        auto l = stripComment(line);
        if (depth == 0 && stmt.length == 0 && l.strip.length == 0)
            continue;
        foreach (c; l)
        {
            if (c == '[' || c == '(' || c == '{')
                depth++;
            else if (c == ']' || c == ')' || c == '}')
                depth--;
        }
        auto t = l.stripRight_;
        bool cont = t.endsWith("\\");
        stmt ~= (cont ? t[0 .. $ - 1] : t) ~ "\n";
        if (depth <= 0 && !cont)
        {
            depth = 0;
            flush();
        }
    }
    flush();
    return d;
}

private string stripRight_(string s)
{
    import std.string : stripRight;
    return s.stripRight;
}

private bool isUpperName(string s)
{
    foreach (c; s)
        if (!((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'))
            return false;
    return true;
}

/// Removes a `#` comment that is not inside a string literal.
private string stripComment(string line)
{
    char q = 0;
    foreach (i, c; line)
    {
        if (q)
        {
            if (c == q && (i == 0 || line[i - 1] != '\\'))
                q = 0;
        }
        else if (c == '\'' || c == '"')
            q = c;
        else if (c == '#')
            return line[0 .. i];
    }
    return line;
}

/// Evaluates a Python literal (strings, numbers, True/False/None, lists, tuples, dicts) with the Jinja expression
/// parser; returns `def` when the text is not a literal.
Value evalPythonLiteral(string text, Value def)
{
    import pgadmin.jinja.runtime : Environment, Loader, TemplateNotFound;

    static final class NoLoader : Loader
    {
        string load(string name, out string key) { throw new TemplateNotFound(name); }
    }

    try
    {
        auto env = new Environment(new NoLoader);
        env.globals = null; // no functions: only literals
        auto src = "{{ __v__.append((" ~ text ~ ")) or '' }}";
        auto holder = Value.newList();
        env.renderString(src, ["__v__": holder]);
        if (holder.list.items.length != 1)
            return def;
        auto v = holder.list.items[0];
        return v.isUndefined ? def : v;
    }
    catch (Exception)
        return def;
}
