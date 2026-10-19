/// The application's template environment: search paths, pgAdmin's filters and `render_template`.
module pgadmin.core.templates;

import std.algorithm : sort, count, startsWith, endsWith;
import std.array : array;
import std.file : dirEntries, SpanMode, exists, isDir;
import std.path : buildPath, baseName;
import pgadmin.core.value;
import pgadmin.db.quoting;
import pgadmin.jinja.runtime;
import pgadmin.jinja.loader;

/// Every `templates` folder of the pgAdmin tree, in the order Flask searches them: the application's own folder
/// first, then the blueprints' folders, parents before children (Flask registers a blueprint before its children).
string[] templateSearchPaths(string pgadminDir)
{
    string[] dirs;
    foreach (e; dirEntries(pgadminDir, SpanMode.breadth))
    {
        if (!e.isDir || baseName(e.name) != "templates")
            continue;
        if (e.name.canFindSeg("node_modules") || e.name.canFindSeg("static") || e.name.canFindSeg("tests"))
            continue;
        // nested `templates` folders inside another templates folder are content, not blueprint folders
        auto rel = e.name[pgadminDir.length .. $];
        if (rel.count("/templates") > 1)
            continue;
        dirs ~= e.name;
    }
    auto root = buildPath(pgadminDir, "templates");
    sort!((a, b) {
        if (a == root)
            return b != root;
        if (b == root)
            return false;
        auto da = a.count('/'), db = b.count('/');
        if (da != db)
            return da < db;
        return a < b;
    })(dirs);
    return dirs;
}

private bool canFindSeg(string path, string seg)
{
    import std.algorithm : canFind;
    return path.canFind("/" ~ seg ~ "/") || path.endsWith("/" ~ seg);
}

/// Registers the filters pgAdmin installs on its Jinja environment.
void registerPgFilters(Environment env)
{
    // {{ conn|qtIdent(a, b) }}: the value is the connection (unused), the names are the arguments
    env.filters["qtIdent"] = (Context c, Value conn, Value[] a, Dict k) => qtIdent(a);
    env.filters["qtTypeIdent"] = (Context c, Value conn, Value[] a, Dict k) => qtTypeIdent(a);
    env.filters["qtLiteral"] = (Context c, Value v, Value[] a, Dict k) {
        auto conn = a.length ? a[0] : (k !is null ? k.get("conn") : Value.undefined);
        if (!conn.truthy)
            throw valueError("qtLiteral requires a connection: without one, escaping silently degrades to "
                    ~ "returning the raw value, which is a SQL injection sink. When using the Jinja filter, "
                    ~ "ensure render_template is called with conn=<conn>; when calling from Python, pass the "
                    ~ "connection as the second argument.");
        bool force = a.length > 1 ? a[1].truthy : (k !is null && k.get("force_quote").truthy);
        if (v.isUndefined)
            throw valueError("cannot adapt type 'Undefined' using placeholder '%t' (format: TEXT)");
        return Value(qtLiteral(v, force));
    };
    env.filters["hasAny"] = (Context c, Value data, Value[] a, Dict k) {
        if (data.isNone || data.isUndefined)
            return Value(false);
        auto keys = a.length ? a[0] : Value(null);
        if (keys.isNone || keys.isUndefined)
            return Value(false);
        foreach (key; keys.iterItems())
            if (data.contains(key))
                return Value(true);
        return Value(false);
    };
}

/// Creates the environment used for every template (SQL and HTML), like `app.jinja_env`.
Environment createEnvironment(string pgadminDir)
{
    auto env = new Environment(new VersionedLoader(templateSearchPaths(pgadminDir)));
    env.lexOptions.trimBlocks = true;
    registerPgFilters(env);
    // gettext; the i18n module replaces these with real translations
    auto gt = Value(new Func("gettext", (Value[] a, Dict k) {
        auto s = a.length ? a[0].toString : "";
        if (k !is null && k.length)
        {
            import pgadmin.jinja.runtime : pyPercentFormat;
            return Value(pyPercentFormat(s, Value(k)));
        }
        return Value(s);
    }));
    env.globals["_"] = gt;
    env.globals["gettext"] = gt;
    env.globals["ngettext"] = Value(new Func("ngettext", (Value[] a, Dict k) {
        auto n = a.length > 2 ? a[2].integer : 1;
        return a[n == 1 ? 0 : 1];
    }));
    return env;
}

private Environment env_;

/// The worker's template environment (set up once by the application).
Environment templateEnv()
{
    assert(env_ !is null, "template environment not initialised");
    return env_;
}

void setTemplateEnv(Environment e)
{
    env_ = e;
}

/// `render_template(name, **vars)`.
string renderTemplate(string name, Value[string] vars = null)
{
    return templateEnv().render(name, vars);
}

/// Variadic convenience: `renderTemplate2("x.sql", "data", data, "conn", conn)`.
string render(Args...)(string name, Args args)
{
    static assert(Args.length % 2 == 0, "render needs name/value pairs");
    Value[string] vars;
    static foreach (i; 0 .. Args.length / 2)
        vars[args[2 * i]] = toValue(args[2 * i + 1]);
    return templateEnv().render(name, vars);
}

Value toValue(T)(T v)
{
    static if (is(T == Value))
        return v;
    else static if (is(T : Obj))
        return Value(cast(Obj) v);
    else
        return Value(v);
}


/// Builds the variables of a template from alternating names and values: `tv("data", data, "conn", conn)`.
Value[string] tv(Args...)(Args args)
{
    static assert(Args.length % 2 == 0, "tv needs name/value pairs");
    Value[string] vars;
    static foreach (i; 0 .. Args.length / 2)
        vars[args[2 * i]] = toValue(args[2 * i + 1]);
    return vars;
}
