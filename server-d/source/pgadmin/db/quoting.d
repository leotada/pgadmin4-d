/// Identifier and literal quoting (`Driver.qtIdent`, `qtTypeIdent`, `qtLiteral` in pgadmin/utils/driver/psycopg3).
module pgadmin.db.quoting;

import std.array : appender;
import std.algorithm : canFind, endsWith, startsWith;
import std.conv : to;
import std.string : toLower, replace;
import pgadmin.core.value;
import pgadmin.db.keywords : scanKeyword;

/// Keywords pgAdmin adds on top of PostgreSQL's (EDB/Oracle compatibility).
private int scanKeywordExtra(string key)
{
    switch (key)
    {
    case "distributed", "log":
        return 0;
    case "connect", "convert", "exec", "long", "minus", "nocache", "number", "package", "pls_integer", "raw",
            "return", "smalldatetime", "smallfloat", "smallmoney", "sysdate", "systimestap", "tinyint", "tinytext",
            "varchar2":
        return 3;
    default:
        return scanKeyword(key);
    }
}

bool needsQuoting(string value, bool forTypes)
{
    string noArray = value;
    if (forTypes && value.endsWith("[]"))
        noArray = value[0 .. $ - 2];

    if (forTypes)
    {
        switch (noArray.toLower)
        {
        case "bit varying", `"char"`, "character varying", "double precision", "timestamp without time zone",
                "timestamp with time zone", "time without time zone", "time with time zone", `"trigger"`,
                `"unknown"`:
            return false;
        default:
            break;
        }
        if (noArray.length && (noArray.startsWith(`"`) || noArray.endsWith(`"`)))
            return false;
    }

    if (noArray.length == 0)
        return false;
    if (noArray[0] >= '0' && noArray[0] <= '9')
        return true;
    foreach (c; noArray)
        if (!((c >= 'a' && c <= 'z') || c == '_' || (c >= '0' && c <= '9')))
            return true;

    immutable category = scanKeywordExtra(value);
    if (category < 0 || category == 0)
        return false;
    if (forTypes && category == 1)
        return false;
    return true;
}

private string identPiece(Value v)
{
    return v.isString ? v.str : v.toString;
}

/// `qtIdent(conn, *names)`: quotes each non-empty name when needed and joins them with dots. None when all are empty.
Value qtIdent(Value[] names...)
{
    string res;
    bool any;
    foreach (n; names)
    {
        if (n.isList)
        {
            // Python returns a lazy map here; the callers only iterate it
            Value[] r;
            foreach (w; n.list.items)
                r ~= qtIdent(w);
            return Value(r);
        }
        auto val = identPiece(n);
        if (val.length == 0)
            continue;
        auto quoted = needsQuoting(val, false) ? `"` ~ val.replace(`"`, `""`) ~ `"` : val;
        res = any ? res ~ "." ~ quoted : quoted;
        any = true;
    }
    return any ? Value(res) : Value(null);
}

string qtIdentStr(string[] names...)
{
    Value[] v;
    foreach (n; names)
        v ~= Value(n);
    auto r = qtIdent(v);
    return r.isNone ? null : r.str;
}

Value qtTypeIdent(Value[] names...)
{
    string res;
    bool any;
    foreach (n; names)
    {
        auto val = identPiece(n);
        if (val.length == 0)
            continue;
        auto quoted = needsQuoting(val, true) ? `"` ~ val.replace(`"`, `""`) ~ `"` : val;
        res = any ? res ~ "." ~ quoted : quoted;
        any = true;
    }
    return any ? Value(res) : Value(null);
}

string qtTypeIdentStr(string[] names...)
{
    Value[] v;
    foreach (n; names)
        v ~= Value(n);
    auto r = qtTypeIdent(v);
    return r.isNone ? null : r.str;
}

/// libpq's `PQescapeLiteral`: doubles quotes; with a backslash, doubles them and uses ` E'...'`.
string escapeLiteral(string s)
{
    auto a = appender!string;
    bool backslash = s.canFind('\\');
    if (backslash)
        a.put(" E");
    a.put('\'');
    foreach (c; s)
    {
        if (c == '\'')
            a.put("''");
        else if (c == '\\')
            a.put("\\\\");
        else
            a.put(c);
    }
    a.put('\'');
    return a.data;
}

/// Array element text for psycopg's list dumper.
private string arrayElem(Value v)
{
    if (v.isNone)
        return "NULL";
    if (v.isList)
        return arrayLiteralBody(v);
    string s;
    if (v.isBool)
        s = v.boolean ? "t" : "f";
    else if (v.isFloat)
        s = floatText(v.floating);
    else if (v.isDict)
        s = v.toJsonSpaced();
    else
        s = v.toString;
    bool needs = s.length == 0 || s.toLower == "null";
    foreach (c; s)
        if (c == '"' || c == '\\' || c == '{' || c == '}' || c == ',' || c == ' ' || c == '\t' || c == '\n'
                || c == '\r' || c == '\v' || c == '\f')
            needs = true;
    if (!needs)
        return s;
    return `"` ~ s.replace(`\`, `\\`).replace(`"`, `\"`) ~ `"`;
}

private string arrayLiteralBody(Value v)
{
    string r = "{";
    foreach (i, x; v.list.items)
    {
        if (i)
            r ~= ",";
        r ~= arrayElem(x);
    }
    return r ~ "}";
}

private string floatText(double f)
{
    import std.math : isNaN, isInfinity;
    if (isNaN(f))
        return "NaN";
    if (isInfinity(f))
        return f > 0 ? "Infinity" : "-Infinity";
    return pyFloatRepr(f);
}

/// The array cast psycopg appends for homogeneous scalar lists.
private string arrayCast(Value v)
{
    string kind;
    long maxAbs;
    bool sawValue;
    void walk(Value x)
    {
        if (x.isList)
        {
            foreach (y; x.list.items)
                walk(y);
            return;
        }
        if (x.isNone)
            return;
        string k = x.isBool ? "bool" : x.isInt ? "int" : x.isFloat ? "float" : "other";
        if (!sawValue)
            kind = k;
        else if (kind != k)
            kind = "other";
        sawValue = true;
        if (x.isInt)
        {
            auto n = x.integer;
            if (n < 0)
                n = -n - 1;
            if (n > maxAbs)
                maxAbs = n;
        }
    }

    walk(v);
    switch (kind)
    {
    case "bool": return "::bool[]";
    case "float": return "::float8[]";
    case "int":
        if (maxAbs < 32_768)
            return "::int2[]";
        if (maxAbs < 2_147_483_648L)
            return "::int4[]";
        return "::int8[]";
    default: return "";
    }
}

/// `qtLiteral(value, conn, force_quote=False)` with psycopg 3's `sql.Literal(value).as_string(conn).strip()` rules.
string qtLiteral(Value v, bool forceQuote = false)
{
    string res;
    if (v.isNone)
        res = "NULL";
    else if (v.isBool)
        res = v.boolean ? "true" : "false";
    else if (v.isInt)
        res = to!string(v.integer);
    else if (v.isFloat)
    {
        import std.math : isNaN, isInfinity;
        auto f = v.floating;
        if (isNaN(f) || isInfinity(f))
            res = "'" ~ floatText(f) ~ "'::float8";
        else
            res = pyFloatRepr(f);
    }
    else if (v.isString)
        res = escapeLiteral(v.str);
    else if (v.isList)
        res = escapeLiteral(arrayLiteralBody(v)) ~ arrayCast(v);
    else if (v.isDict)
        res = escapeLiteral(v.toJsonSpaced());
    else
        res = escapeLiteral(v.toString);

    import std.string : strip;
    res = res.strip;
    if (forceQuote && !res.startsWith("'"))
        return "'" ~ res ~ "'";
    return res;
}

unittest
{
    assert(qtIdentStr("public", "my table") == `public."my table"`);
    assert(qtIdentStr("select") == `"select"`);
    assert(qtIdentStr("abc") == "abc");
    assert(qtIdentStr("Abc") == `"Abc"`);
    assert(qtIdentStr("1a") == `"1a"`);
    assert(qtTypeIdentStr("character varying") == "character varying");
    assert(qtTypeIdentStr("integer[]") == "integer[]");
    assert(qtLiteral(Value("it's")) == "'it''s'");
    assert(qtLiteral(Value(`back\slash`)) == `E'back\\slash'`);
    assert(qtLiteral(Value(-5)) == "-5");
    assert(qtLiteral(Value.listOf("a", "b c")) == `'{a,"b c"}'`);
    assert(qtLiteral(Value.listOf(1, 2)) == "'{1,2}'::int2[]");
    assert(qtLiteral(Value(null)) == "NULL");
}
