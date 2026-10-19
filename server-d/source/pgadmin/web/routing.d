/// URL rules with Werkzeug semantics: `<int:id>`, `<path:p>`, `<name>`, strict trailing slashes (a rule that ends
/// with `/` redirects the slash-less URL with 308), method checks (405 with Allow), endpoint names and URL building.
module pgadmin.web.routing;

import std.algorithm : canFind, sort, startsWith, endsWith, map;
import std.array : array, split, join;
import std.conv : to;
import std.string : indexOf, toUpper;
import pgadmin.core.value;
import pgadmin.web.http;

enum ConvKind : ubyte
{
    static_,
    int_,
    float_,
    uuid,
    string_,
    any,
    path,
}

struct Segment
{
    ConvKind kind;
    string text;    /// static text, or the variable name
    string[] anyOf; /// any(a, b, c)
    bool signed;    /// int(signed=True)
}

/// What the view receives: the path variables (ints as integers) in a dict.
alias ViewFunc = Response delegate(Dict args);

final class Rule
{
    string rule;        /// as declared ("/browser/server/obj/<int:gid>/")
    string endpoint;
    string[] methods;   /// upper case; GET implies HEAD
    ViewFunc view;
    Segment[] segs;
    bool trailingSlash;
    string[] argNames;
    /// Extra data the dispatcher needs (CSRF exemption, the blueprint).
    bool csrfExempt;
    string blueprint;
    Value defaults;     /// default view args (dict or None)

    this(string rule, string endpoint, string[] methods, ViewFunc view)
    {
        this.rule = rule;
        this.endpoint = endpoint;
        this.view = view;
        string[] ms;
        foreach (m; methods)
            ms ~= m.toUpper;
        if (ms.canFind("GET") && !ms.canFind("HEAD"))
            ms ~= "HEAD";
        if (!ms.canFind("OPTIONS"))
            ms ~= "OPTIONS";
        this.methods = ms;
        parse();
    }

    private void parse()
    {
        auto r = rule;
        trailingSlash = r.length > 1 && r.endsWith("/");
        if (trailingSlash)
            r = r[0 .. $ - 1];
        foreach (part; r == "/" ? [] : r.split("/")[1 .. $])
        {
            // a segment may mix static text and one variable ("js/<name>.js" is not used by pgAdmin; keep it simple)
            if (part.startsWith("<") && part.endsWith(">"))
            {
                auto inner = part[1 .. $ - 1];
                Segment s;
                auto colon = inner.indexOf(':');
                string conv = colon < 0 ? "default" : inner[0 .. colon];
                s.text = colon < 0 ? inner : inner[colon + 1 .. $];
                string args;
                auto paren = conv.indexOf('(');
                if (paren >= 0)
                {
                    args = conv[paren + 1 .. $ - 1];
                    conv = conv[0 .. paren];
                }
                switch (conv)
                {
                case "int":
                    s.kind = ConvKind.int_;
                    s.signed = args.canFind("signed=True");
                    break;
                case "float": s.kind = ConvKind.float_; break;
                case "uuid": s.kind = ConvKind.uuid; break;
                case "path": s.kind = ConvKind.path; break;
                case "any":
                    s.kind = ConvKind.any;
                    foreach (a; args.split(","))
                    {
                        import std.string : strip;
                        auto t = a.strip;
                        if (t.length >= 2 && (t[0] == '\'' || t[0] == '"'))
                            t = t[1 .. $ - 1];
                        s.anyOf ~= t;
                    }
                    break;
                default:
                    s.kind = ConvKind.string_;
                }
                argNames ~= s.text;
                segs ~= s;
            }
            else
                segs ~= Segment(ConvKind.static_, part);
        }
    }

    /// Ordering weight (lower wins): static segments first, then typed converters, then strings, then paths.
    int[] weight() const
    {
        int[] w;
        foreach (s; segs)
            w ~= cast(int) s.kind;
        return w;
    }

    /// Tries to match the path segments; fills `args`. `slashMismatch` is set when only the trailing slash differs.
    bool match(string[] parts, bool hasSlash, Dict args, out bool needsSlash)
    {
        size_t pi;
        foreach (si, s; segs)
        {
            if (s.kind == ConvKind.path)
            {
                // the rest of the path (at least one char), including slashes
                if (pi >= parts.length)
                    return false;
                // a path converter must be the last segment in pgAdmin's rules
                auto rest = parts[pi .. $].join("/");
                if (hasSlash && !trailingSlash)
                    rest ~= "/";
                if (rest.length == 0)
                    return false;
                args[s.text] = Value(rest);
                return si == segs.length - 1;
            }
            if (pi >= parts.length)
                return false;
            auto p = parts[pi++];
            final switch (s.kind)
            {
            case ConvKind.static_:
                if (p != s.text)
                    return false;
                break;
            case ConvKind.int_:
                if (p.length == 0)
                    return false;
                size_t st = 0;
                if (s.signed && p[0] == '-')
                    st = 1;
                if (st >= p.length)
                    return false;
                foreach (c; p[st .. $])
                    if (c < '0' || c > '9')
                        return false;
                try
                    args[s.text] = Value(to!long(p));
                catch (Exception)
                    return false;
                break;
            case ConvKind.float_:
                try
                {
                    if (!p.canFind('.'))
                        return false;
                    args[s.text] = Value(to!double(p));
                }
                catch (Exception)
                    return false;
                break;
            case ConvKind.uuid:
                if (p.length != 36)
                    return false;
                args[s.text] = Value(p);
                break;
            case ConvKind.string_:
                if (p.length == 0)
                    return false;
                args[s.text] = Value(p);
                break;
            case ConvKind.any:
                if (!s.anyOf.canFind(p))
                    return false;
                args[s.text] = Value(p);
                break;
            case ConvKind.path:
                break;
            }
        }
        if (pi != parts.length)
            return false;
        if (trailingSlash && !hasSlash)
        {
            needsSlash = true;
            return true;
        }
        if (!trailingSlash && hasSlash)
            return false;
        return true;
    }

    /// Builds the path for `values`; null when a variable is missing.
    string build(Dict values)
    {
        string s;
        foreach (seg; segs)
        {
            s ~= "/";
            if (seg.kind == ConvKind.static_)
            {
                s ~= seg.text;
                continue;
            }
            auto p = values.find(seg.text);
            if (p is null)
                return null;
            string v = p.isString ? p.str : p.toString;
            if (seg.kind == ConvKind.int_ && p.isBool)
                v = p.boolean ? "1" : "0";
            s ~= seg.kind == ConvKind.path ? urlQuote(v, "/:!$&'()*+,;=@") : urlQuote(v, ":!$&'()*+,;=@");
        }
        if (trailingSlash || s.length == 0)
            s ~= "/";
        return s;
    }
}

class RoutingError : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line);
    }
}

/// The result of matching a request.
struct MatchResult
{
    Rule rule;              /// null: not found / method not allowed / redirect
    Dict args;
    string redirectTo;      /// strict-slash redirect (308)
    string[] allowed;       /// for 405
}

final class Map
{
    private Rule[] rules;
    private Rule[][string] byEndpoint;
    private bool sorted;

    void add(Rule r)
    {
        rules ~= r;
        byEndpoint[r.endpoint] ~= r;
        sorted = false;
    }

    Rule[] all() => rules;

    Rule[] forEndpoint(string endpoint)
    {
        if (auto p = endpoint in byEndpoint)
            return *p;
        return null;
    }

    bool hasEndpoint(string endpoint) => (endpoint in byEndpoint) !is null;

    private void ensureSorted()
    {
        if (sorted)
            return;
        import std.algorithm : SwapStrategy;
        sort!((a, b) => a.weight < b.weight, SwapStrategy.stable)(rules);
        sorted = true;
    }

    /// Matches `path` (decoded, starting with '/') for `method`.
    MatchResult match(string path, string method)
    {
        ensureSorted();
        MatchResult res;
        bool hasSlash = path.length > 1 && path.endsWith("/");
        auto trimmed = hasSlash ? path[0 .. $ - 1] : path;
        string[] parts = trimmed == "" || trimmed == "/" ? [] : trimmed.split("/")[1 .. $];
        string[] allowed;
        string redirect;
        foreach (r; rules)
        {
            auto args = new Dict;
            bool needsSlash;
            if (!r.match(parts, hasSlash, args, needsSlash))
                continue;
            if (!r.methods.canFind(method))
            {
                foreach (m; r.methods)
                    if (!allowed.canFind(m))
                        allowed ~= m;
                continue;
            }
            if (needsSlash)
            {
                if (redirect is null)
                    redirect = path ~ "/";
                continue;
            }
            if (r.defaults.isDict)
                foreach (k, v; r.defaults.dict)
                    if (!args.has(k))
                        args[k] = v;
            res.rule = r;
            res.args = args;
            return res;
        }
        if (redirect !is null)
        {
            res.redirectTo = redirect;
            return res;
        }
        res.allowed = allowed;
        return res;
    }

    /// `url_for(endpoint, **values)`: the path (without the application root) plus the extra values as a query.
    string build(string endpoint, Dict values, string method = null)
    {
        auto rs = forEndpoint(endpoint);
        if (rs.length == 0)
            throw new RoutingError("Could not build url for endpoint '" ~ endpoint ~ "'");
        if (values is null)
            values = new Dict;
        // Werkzeug prefers the rule that uses the most of the given values
        Rule best;
        size_t bestUsed;
        foreach (r; rs)
        {
            if (method !is null && !r.methods.canFind(method))
                continue;
            bool ok = true;
            foreach (a; r.argNames)
                if (!values.has(a) && !(r.defaults.isDict && r.defaults.dict.has(a)))
                {
                    ok = false;
                    break;
                }
            if (!ok)
                continue;
            if (best is null || r.argNames.length > bestUsed)
            {
                best = r;
                bestUsed = r.argNames.length;
            }
        }
        if (best is null)
            throw new RoutingError("Could not build url for endpoint '" ~ endpoint ~ "'. Did you forget to specify "
                    ~ "values " ~ (rs[0].argNames.map!(a => "'" ~ a ~ "'").join(", ")) ~ "?");
        auto merged = new Dict;
        if (best.defaults.isDict)
            merged.update(best.defaults.dict);
        merged.update(values);
        auto path = best.build(merged);
        string[2][] extra;
        foreach (k, v; values)
            if (!best.argNames.canFind(k) && !v.isNone && !v.isUndefined)
            {
                if (v.isList)
                    foreach (x; v.list.items)
                        extra ~= [k, x.toString];
                else
                    extra ~= [k, v.isBool ? (v.boolean ? "True" : "False") : v.toString];
            }
        if (extra.length)
            path ~= "?" ~ urlEncodeQuery(extra);
        return path;
    }
}

unittest
{
    auto m = new Map;
    Response v(Dict a) => null;
    m.add(new Rule("/browser/server/obj/<int:gid>/", "server.obj", ["GET", "POST"], &v));
    m.add(new Rule("/browser/server/obj/<int:gid>/<int:sid>", "server.obj_id", ["GET", "PUT", "DELETE"], &v));
    m.add(new Rule("/static/<path:filename>", "static", ["GET"], &v));
    auto r = m.match("/browser/server/obj/1/2", "GET");
    assert(r.rule.endpoint == "server.obj_id" && r.args["sid"] == 2);
    r = m.match("/browser/server/obj/1", "GET");
    assert(r.rule is null && r.redirectTo == "/browser/server/obj/1/");
    r = m.match("/browser/server/obj/1/", "POST");
    assert(r.rule.endpoint == "server.obj");
    r = m.match("/browser/server/obj/1/2", "POST");
    assert(r.rule is null && r.allowed.canFind("PUT"));
    r = m.match("/static/js/generated/app.bundle.js", "GET");
    assert(r.args["filename"] == "js/generated/app.bundle.js");
    auto d = new Dict;
    d["gid"] = 1;
    d["sid"] = 5;
    assert(m.build("server.obj_id", d) == "/browser/server/obj/1/5");
    auto e = new Dict;
    e["filename"] = "js/x.js";
    e["ver"] = 91800;
    assert(m.build("static", e) == "/static/js/x.js?ver=91800");
}
