/// Jinja2's builtin filters, tests and global functions.
module pgadmin.jinja.builtins;

import std.array : appender, join;
import std.algorithm : sort, canFind, startsWith;
import std.conv : to;
import std.string : toLower, toUpper, strip, replace, indexOf;
import pgadmin.core.value;
import pgadmin.jinja.runtime;

private Value kwOr(Dict kw, string name, Value[] args, size_t pos, Value def)
{
    if (pos < args.length)
        return args[pos];
    if (kw !is null && kw.has(name))
        return kw[name];
    return def;
}

private Value attrPath(Context ctx, Value v, string path)
{
    foreach (part; path.split_('.'))
    {
        bool numeric = part.length && part[0] >= '0' && part[0] <= '9';
        v = numeric ? ctx.getItem(v, Value(to!long(part))) : ctx.getItem(v, Value(part));
    }
    return v;
}

private string[] split_(string s, char c)
{
    string[] r;
    size_t st;
    foreach (i, ch; s)
        if (ch == c)
        {
            r ~= s[st .. i];
            st = i + 1;
        }
    r ~= s[st .. $];
    return r;
}

private Value[] seqOf(Value v)
{
    if (v.isUndefined || v.isNone)
        return null;
    if (v.isObject)
        if (auto it = cast(Iterable) v.obj)
            return it.iterate();
    return v.iterItems();
}

private Value sortKey(Value v, bool caseSensitive)
{
    if (!caseSensitive && v.isString)
        return Value(v.str.toLower);
    return v;
}

/// JSON with sorted keys and the default separators (Flask's `tojson`), HTML-safe.
string htmlSafeJson(Value v)
{
    auto s = sortedJson(v);
    s = s.replace("<", "\\u003c").replace(">", "\\u003e").replace("&", "\\u0026").replace("'", "\\u0027");
    return s;
}

string sortedJson(Value v)
{
    if (v.isDict)
    {
        auto keys = v.dict.keys;
        sort(keys);
        auto a = appender!string;
        a.put("{");
        foreach (i, k; keys)
        {
            if (i)
                a.put(", ");
            jsonString(a, k);
            a.put(": ");
            a.put(sortedJson(v.dict[k]));
        }
        a.put("}");
        return a.data;
    }
    if (v.isList)
    {
        string[] parts;
        foreach (x; v.list.items)
            parts ~= sortedJson(x);
        return "[" ~ parts.join(", ") ~ "]";
    }
    if (v.isUndefined)
        return "null";
    return v.toJson;
}

void registerBuiltins(Environment env)
{
    alias F = FilterFn;

    // ------------------------------------------------------------ filters

    env.filters["safe"] = (Context c, Value v, Value[] a, Dict k) => markSafe(v.toString);
    F esc = (Context c, Value v, Value[] a, Dict k) => v.safe ? v : markSafe(htmlEscape(v.toString));
    env.filters["escape"] = esc;
    env.filters["e"] = esc;
    env.filters["forceescape"] = (Context c, Value v, Value[] a, Dict k) => markSafe(htmlEscape(v.toString));

    F len = (Context c, Value v, Value[] a, Dict k) {
        if (v.isUndefined || v.isNone)
        {
            if (v.isNone && !v.isUndefined)
                throw typeError("object of type 'NoneType' has no len()");
            return Value(0);
        }
        if (v.isObject)
            if (auto it = cast(Iterable) v.obj)
                return Value(it.iterate().length);
        return Value(v.length);
    };
    env.filters["length"] = len;
    env.filters["count"] = len;

    env.filters["lower"] = (Context c, Value v, Value[] a, Dict k) => Value(v.toString.toLower);
    env.filters["upper"] = (Context c, Value v, Value[] a, Dict k) => Value(v.toString.toUpper);
    env.filters["title"] = (Context c, Value v, Value[] a, Dict k) => Value(pyTitle(v.toString));
    env.filters["capitalize"] = (Context c, Value v, Value[] a, Dict k) => Value(pyCapitalize(v.toString));
    env.filters["string"] = (Context c, Value v, Value[] a, Dict k) {
        auto r = Value(v.toString);
        r.safe = v.safe;
        return r;
    };

    env.filters["trim"] = (Context c, Value v, Value[] a, Dict k) {
        auto chars = kwOr(k, "chars", a, 0, Value(null));
        auto s = v.toString;
        if (chars.isNone)
            return Value(s.strip);
        auto cs = chars.toString;
        size_t st = 0, e = s.length;
        while (st < e && cs.canFind(s[st]))
            st++;
        while (e > st && cs.canFind(s[e - 1]))
            e--;
        return Value(s[st .. e]);
    };

    F dflt = (Context c, Value v, Value[] a, Dict k) {
        auto def = kwOr(k, "default_value", a, 0, Value(""));
        auto boolean = kwOr(k, "boolean", a, 1, Value(false)).truthy;
        if (v.isUndefined || (boolean && !v.truthy))
            return def;
        return v;
    };
    env.filters["default"] = dflt;
    env.filters["d"] = dflt;

    env.filters["int"] = (Context c, Value v, Value[] a, Dict k) {
        auto def = kwOr(k, "default", a, 0, Value(0));
        auto base = kwOr(k, "base", a, 1, Value(10)).integer;
        if (v.isUndefined)
            failUndefined(v);
        if (v.isInt)
            return v;
        if (v.isBool)
            return Value(v.boolean ? 1L : 0L);
        if (v.isFloat)
            return Value(cast(long) v.floating);
        if (v.isString)
        {
            auto s = v.str.strip;
            try
            {
                if (base != 10)
                    return Value(to!long(s, cast(uint) base));
                return Value(to!long(s));
            }
            catch (Exception)
            {
                try
                    return Value(cast(long) to!double(s));
                catch (Exception)
                    return def;
            }
        }
        return def;
    };

    env.filters["float"] = (Context c, Value v, Value[] a, Dict k) {
        auto def = kwOr(k, "default", a, 0, Value(0.0));
        try
            return Value(v.floating);
        catch (Exception)
            return def;
    };

    env.filters["abs"] = (Context c, Value v, Value[] a, Dict k) {
        if (v.isInt)
            return Value(v.integer < 0 ? -v.integer : v.integer);
        auto f = v.floating;
        return Value(f < 0 ? -f : f);
    };

    env.filters["round"] = (Context c, Value v, Value[] a, Dict k) {
        import std.math : round, floor, ceil, pow;
        auto prec = kwOr(k, "precision", a, 0, Value(0)).integer;
        auto method = kwOr(k, "method", a, 1, Value("common")).toString;
        auto m = pow(10.0, prec);
        auto f = v.floating * m;
        double r = method == "ceil" ? ceil(f) : method == "floor" ? floor(f) : round(f);
        return Value(r / m);
    };

    env.filters["join"] = (Context c, Value v, Value[] a, Dict k) {
        auto d = kwOr(k, "d", a, 0, Value("")).toString;
        auto attr = kwOr(k, "attribute", a, 1, Value(null));
        string[] parts;
        foreach (x; seqOf(v))
            parts ~= (attr.isNone ? x : attrPath(c, x, attr.toString)).toString;
        return Value(parts.join(d));
    };

    env.filters["replace"] = (Context c, Value v, Value[] a, Dict k) {
        auto s = v.toString;
        auto from = a[0].toString, to_ = a[1].toString;
        long count = a.length > 2 ? a[2].integer : -1;
        if (count < 0)
        {
            if (from.length == 0)
            {
                // Python inserts `to` between every character
                string r = to_;
                foreach (dchar ch; s)
                {
                    r ~= ch;
                    r ~= to_;
                }
                return Value(r);
            }
            return Value(s.replace(from, to_));
        }
        string outp, rest = s;
        while (count-- > 0)
        {
            auto p = rest.indexOf(from);
            if (p < 0)
                break;
            outp ~= rest[0 .. p] ~ to_;
            rest = rest[p + from.length .. $];
        }
        return Value(outp ~ rest);
    };

    env.filters["list"] = (Context c, Value v, Value[] a, Dict k) => Value(seqOf(v).dup);
    env.filters["first"] = (Context c, Value v, Value[] a, Dict k) {
        auto s = seqOf(v);
        return s.length ? s[0] : Value.undefined;
    };
    env.filters["last"] = (Context c, Value v, Value[] a, Dict k) {
        auto s = seqOf(v);
        return s.length ? s[$ - 1] : Value.undefined;
    };
    env.filters["reverse"] = (Context c, Value v, Value[] a, Dict k) {
        if (v.isString)
        {
            import std.utf : toUTF32;
            import std.algorithm : reverse;
            auto d = toUTF32(v.str).dup;
            reverse(d);
            return Value(to!string(d));
        }
        auto s = seqOf(v).dup;
        import std.algorithm : reverse;
        reverse(s);
        return Value(s);
    };

    env.filters["sort"] = (Context c, Value v, Value[] a, Dict k) {
        auto rev = kwOr(k, "reverse", a, 0, Value(false)).truthy;
        auto cs = kwOr(k, "case_sensitive", a, 1, Value(false)).truthy;
        auto attr = kwOr(k, "attribute", a, 2, Value(null));
        auto items = seqOf(v).dup;
        Value keyOf(Value x) => sortKey(attr.isNone ? x : attrPath(c, x, attr.toString), cs);
        import std.algorithm : sort, SwapStrategy;
        if (rev)
            sort!((x, y) => keyOf(x).opCmp(keyOf(y)) > 0, SwapStrategy.stable)(items);
        else
            sort!((x, y) => keyOf(x).opCmp(keyOf(y)) < 0, SwapStrategy.stable)(items);
        return Value(items);
    };

    env.filters["unique"] = (Context c, Value v, Value[] a, Dict k) {
        auto cs = kwOr(k, "case_sensitive", a, 0, Value(false)).truthy;
        auto attr = kwOr(k, "attribute", a, 1, Value(null));
        Value[] seen, r;
        foreach (x; seqOf(v))
        {
            auto key = sortKey(attr.isNone ? x : attrPath(c, x, attr.toString), cs);
            if (!seen.canFind(key))
            {
                seen ~= key;
                r ~= x;
            }
        }
        return Value(r);
    };

    env.filters["dictsort"] = (Context c, Value v, Value[] a, Dict k) {
        auto cs = kwOr(k, "case_sensitive", a, 0, Value(false)).truthy;
        auto by = kwOr(k, "by", a, 1, Value("key")).toString;
        auto rev = kwOr(k, "reverse", a, 2, Value(false)).truthy;
        Value[] items;
        foreach (key, val; v.dict)
            items ~= Value.tuple(Value(key), val);
        auto pos = by == "value" ? 1 : 0;
        Value keyOf(Value x) => sortKey(x.list.items[pos], cs);
        import std.algorithm : sort, SwapStrategy;
        if (rev)
            sort!((x, y) => keyOf(x).opCmp(keyOf(y)) > 0, SwapStrategy.stable)(items);
        else
            sort!((x, y) => keyOf(x).opCmp(keyOf(y)) < 0, SwapStrategy.stable)(items);
        return Value(items);
    };

    env.filters["items"] = (Context c, Value v, Value[] a, Dict k) {
        Value[] items;
        if (v.isDict)
            foreach (key, val; v.dict)
                items ~= Value.tuple(Value(key), val);
        return Value(items);
    };

    env.filters["tojson"] = (Context c, Value v, Value[] a, Dict k) => markSafe(htmlSafeJson(v));

    env.filters["format"] = (Context c, Value v, Value[] a, Dict k) {
        Value args = a.length == 1 ? a[0] : Value.tuple(a);
        if (a.length == 0 && k !is null)
            args = Value(k);
        if (a.length == 1 && !a[0].isList && !a[0].isDict)
            args = Value.tuple(a);
        return Value(pyPercentFormat(v.toString, args));
    };

    env.filters["center"] = (Context c, Value v, Value[] a, Dict k) {
        auto w = kwOr(k, "width", a, 0, Value(80)).integer;
        auto s = v.toString;
        auto n = cast(long) utf8Length(s);
        if (n >= w)
            return Value(s);
        auto total = w - n;
        auto left = total / 2 + (total & w & 1);
        string r;
        foreach (_; 0 .. left)
            r ~= " ";
        r ~= s;
        foreach (_; 0 .. total - left)
            r ~= " ";
        return Value(r);
    };

    env.filters["indent"] = (Context c, Value v, Value[] a, Dict k) {
        auto w = kwOr(k, "width", a, 0, Value(4));
        auto first = kwOr(k, "first", a, 1, Value(false)).truthy;
        auto blank = kwOr(k, "blank", a, 2, Value(false)).truthy;
        string pad;
        if (w.isString)
            pad = w.str;
        else
            foreach (_; 0 .. w.integer)
                pad ~= " ";
        auto s = v.toString;
        auto lines = s.split_('\n');
        string r;
        foreach (i, l; lines)
        {
            if (i)
                r ~= "\n";
            if ((i > 0 || first) && (blank || l.strip.length))
                r ~= pad;
            r ~= l;
        }
        return Value(r);
    };

    env.filters["truncate"] = (Context c, Value v, Value[] a, Dict k) {
        auto length = kwOr(k, "length", a, 0, Value(255)).integer;
        auto killwords = kwOr(k, "killwords", a, 1, Value(false)).truthy;
        auto end = kwOr(k, "end", a, 2, Value("...")).toString;
        auto leeway = kwOr(k, "leeway", a, 3, Value(5)).integer;
        auto s = v.toString;
        import std.utf : toUTF32;
        auto d = toUTF32(s);
        if (cast(long) d.length <= length + leeway)
            return Value(s);
        auto cut = to!string(d[0 .. cast(size_t)(length - end.length > 0 ? length - end.length : 0)]);
        if (killwords)
            return Value(cut ~ end);
        import std.string : lastIndexOf;
        auto sp = cut.lastIndexOf(' ');
        if (sp > 0)
            cut = cut[0 .. sp];
        return Value(cut ~ end);
    };

    env.filters["wordcount"] = (Context c, Value v, Value[] a, Dict k) {
        import std.array : split;
        return Value(v.toString.split.length);
    };

    env.filters["striptags"] = (Context c, Value v, Value[] a, Dict k) {
        auto s = v.toString;
        string r;
        bool inTag;
        foreach (ch; s)
        {
            if (ch == '<')
                inTag = true;
            else if (ch == '>')
                inTag = false;
            else if (!inTag)
                r ~= ch;
        }
        import std.array : split;
        return Value(r.split.join(" "));
    };

    env.filters["urlencode"] = (Context c, Value v, Value[] a, Dict k) {
        import std.uri : encodeComponent;
        if (v.isDict)
        {
            string[] parts;
            foreach (key, val; v.dict)
                parts ~= encodeComponent(key) ~ "=" ~ encodeComponent(val.toString);
            return Value(parts.join("&"));
        }
        return Value(encodeComponent(v.toString).replace("%2F", "/"));
    };

    env.filters["sum"] = (Context c, Value v, Value[] a, Dict k) {
        auto attr = kwOr(k, "attribute", a, 0, Value(null));
        Value total = kwOr(k, "start", a, 1, Value(0));
        foreach (x; seqOf(v))
            total = c.arith("+", total, attr.isNone ? x : attrPath(c, x, attr.toString));
        return total;
    };

    F minmax(bool isMax)
    {
        return (Context c, Value v, Value[] a, Dict k) {
            auto cs = kwOr(k, "case_sensitive", a, 0, Value(false)).truthy;
            auto attr = kwOr(k, "attribute", a, 1, Value(null));
            auto items = seqOf(v);
            if (items.length == 0)
                return Value.undefined;
            Value best = items[0];
            foreach (x; items[1 .. $])
            {
                auto kx = sortKey(attr.isNone ? x : attrPath(c, x, attr.toString), cs);
                auto kb = sortKey(attr.isNone ? best : attrPath(c, best, attr.toString), cs);
                if (isMax ? kx.opCmp(kb) > 0 : kx.opCmp(kb) < 0)
                    best = x;
            }
            return best;
        };
    }

    env.filters["max"] = minmax(true);
    env.filters["min"] = minmax(false);

    env.filters["attr"] = (Context c, Value v, Value[] a, Dict k) => c.getAttr(v, a[0].toString);

    env.filters["map"] = (Context c, Value v, Value[] a, Dict k) {
        Value[] r;
        if (k !is null && k.has("attribute"))
        {
            auto attr = k["attribute"].toString;
            auto def = k.get("default", Value.undefined);
            foreach (x; seqOf(v))
            {
                auto y = attrPath(c, x, attr);
                r ~= y.isUndefined ? def : y;
            }
            return Value(r);
        }
        auto fname = a[0].toString;
        auto fn = fname in c.env.filters;
        if (fn is null)
            throw new TemplateRuntimeError("no filter named '" ~ fname ~ "'");
        foreach (x; seqOf(v))
            r ~= (*fn)(c, x, a[1 .. $], k);
        return Value(r);
    };

    F selectReject(bool select, bool byAttr)
    {
        return (Context c, Value v, Value[] a, Dict k) {
            Value[] r;
            size_t off = byAttr ? 1 : 0;
            foreach (x; seqOf(v))
            {
                auto item = byAttr ? attrPath(c, x, a[0].toString) : x;
                bool ok;
                if (a.length > off)
                {
                    auto tname = a[off].toString;
                    auto t = tname in c.env.tests;
                    if (t is null)
                        throw new TemplateRuntimeError("no test named '" ~ tname ~ "'");
                    ok = (*t)(item, a[off + 1 .. $]);
                }
                else
                    ok = item.truthy;
                if (ok == select)
                    r ~= x;
            }
            return Value(r);
        };
    }

    env.filters["select"] = selectReject(true, false);
    env.filters["reject"] = selectReject(false, false);
    env.filters["selectattr"] = selectReject(true, true);
    env.filters["rejectattr"] = selectReject(false, true);

    env.filters["batch"] = (Context c, Value v, Value[] a, Dict k) {
        auto n = a[0].integer;
        auto fill = a.length > 1 ? a[1] : Value.undefined;
        Value[] r;
        Value[] cur;
        foreach (x; seqOf(v))
        {
            cur ~= x;
            if (cast(long) cur.length == n)
            {
                r ~= Value(cur);
                cur = null;
            }
        }
        if (cur.length)
        {
            if (!fill.isUndefined)
                while (cast(long) cur.length < n)
                    cur ~= fill;
            r ~= Value(cur);
        }
        return Value(r);
    };

    env.filters["groupby"] = (Context c, Value v, Value[] a, Dict k) {
        auto attr = kwOr(k, "attribute", a, 0, Value(null)).toString;
        auto items = seqOf(v).dup;
        import std.algorithm : sort, SwapStrategy;
        sort!((x, y) => attrPath(c, x, attr).opCmp(attrPath(c, y, attr)) < 0, SwapStrategy.stable)(items);
        Value[] r;
        Value curKey;
        Value[] cur;
        bool any;
        foreach (x; items)
        {
            auto key = attrPath(c, x, attr);
            if (any && key != curKey)
            {
                r ~= groupTuple(curKey, cur);
                cur = null;
            }
            curKey = key;
            cur ~= x;
            any = true;
        }
        if (any)
            r ~= groupTuple(curKey, cur);
        return Value(r);
    };

    env.filters["xmlattr"] = (Context c, Value v, Value[] a, Dict k) {
        string r;
        foreach (key, val; v.dict)
            if (!val.isNone && !val.isUndefined)
                r ~= " " ~ key ~ "=\"" ~ htmlEscape(val.toString) ~ "\"";
        return markSafe(r);
    };

    env.filters["filesizeformat"] = (Context c, Value v, Value[] a, Dict k) {
        import std.format : format;
        auto bytes = v.floating;
        auto binary = a.length && a[0].truthy;
        auto base = binary ? 1024.0 : 1000.0;
        string[] pre = binary ? ["KiB", "MiB", "GiB", "TiB", "PiB", "EiB", "ZiB", "YiB"]
            : ["kB", "MB", "GB", "TB", "PB", "EB", "ZB", "YB"];
        if (bytes == 1)
            return Value("1 Byte");
        if (bytes < base)
            return Value(format("%d Bytes", cast(long) bytes));
        foreach (i, p; pre)
        {
            auto unit = base ^^ (i + 2);
            if (bytes < unit || i + 1 == pre.length)
                return Value(format("%.1f %s", base * bytes / unit, p));
        }
        return Value(v.toString);
    };

    // ------------------------------------------------------------ tests

    env.tests["defined"] = (Value v, Value[] a) => !v.isUndefined;
    env.tests["undefined"] = (Value v, Value[] a) => v.isUndefined;
    env.tests["none"] = (Value v, Value[] a) => v.isNone && !v.isUndefined;
    env.tests["true"] = (Value v, Value[] a) => v.isBool && v.boolean;
    env.tests["false"] = (Value v, Value[] a) => v.isBool && !v.boolean;
    env.tests["boolean"] = (Value v, Value[] a) => v.isBool;
    env.tests["integer"] = (Value v, Value[] a) => v.isInt;
    env.tests["float"] = (Value v, Value[] a) => v.isFloat;
    env.tests["number"] = (Value v, Value[] a) => v.isNumber;
    env.tests["string"] = (Value v, Value[] a) => v.isString;
    env.tests["mapping"] = (Value v, Value[] a) => v.isDict;
    env.tests["sequence"] = (Value v, Value[] a) => v.isList || v.isString || v.isDict;
    env.tests["iterable"] = (Value v, Value[] a) => v.isList || v.isString || v.isDict
        || (v.isObject && cast(Iterable) v.obj !is null);
    env.tests["callable"] = (Value v, Value[] a) => v.isFunc;
    env.tests["odd"] = (Value v, Value[] a) => v.integer % 2 != 0;
    env.tests["even"] = (Value v, Value[] a) => v.integer % 2 == 0;
    env.tests["divisibleby"] = (Value v, Value[] a) => v.integer % a[0].integer == 0;
    env.tests["lower"] = (Value v, Value[] a) => v.toString == v.toString.toLower;
    env.tests["upper"] = (Value v, Value[] a) => v.toString == v.toString.toUpper;
    env.tests["escaped"] = (Value v, Value[] a) => v.safe;
    env.tests["in"] = (Value v, Value[] a) => Context.containsValue(a[0], v);
    env.tests["sameas"] = (Value v, Value[] a) {
        auto o = a[0];
        if (v.type != o.type)
            return false;
        if (v.isNone || v.isBool)
            return v == o;
        if (v.isList || v.isDict || v.isFunc || v.isObject)
            return v.obj is o.obj;
        return v == o;
    };
    TestFn eq = (Value v, Value[] a) => v == a[0];
    env.tests["eq"] = eq;
    env.tests["equalto"] = eq;
    env.tests["=="] = eq;
    TestFn ne = (Value v, Value[] a) => v != a[0];
    env.tests["ne"] = ne;
    env.tests["!="] = ne;
    TestFn lt = (Value v, Value[] a) => v.opCmp(a[0]) < 0;
    env.tests["lt"] = lt;
    env.tests["lessthan"] = lt;
    env.tests["<"] = lt;
    TestFn le = (Value v, Value[] a) => v.opCmp(a[0]) <= 0;
    env.tests["le"] = le;
    env.tests["<="] = le;
    TestFn gt = (Value v, Value[] a) => v.opCmp(a[0]) > 0;
    env.tests["gt"] = gt;
    env.tests["greaterthan"] = gt;
    env.tests[">"] = gt;
    TestFn ge = (Value v, Value[] a) => v.opCmp(a[0]) >= 0;
    env.tests["ge"] = ge;
    env.tests[">="] = ge;
    env.tests["filter"] = (Value v, Value[] a) => (v.toString in env.filters) !is null;
    env.tests["test"] = (Value v, Value[] a) => (v.toString in env.tests) !is null;

    // ------------------------------------------------------------ globals

    env.globals["range"] = Value(new Func("range", (Value[] a, Dict k) {
        long start = 0, stop, step = 1;
        if (a.length == 1)
            stop = a[0].integer;
        else
        {
            start = a[0].integer;
            stop = a[1].integer;
            if (a.length > 2)
                step = a[2].integer;
        }
        if (step == 0)
            throw valueError("range() arg 3 must not be zero");
        Value[] r;
        if (step > 0)
            for (long i = start; i < stop; i += step)
                r ~= Value(i);
        else
            for (long i = start; i > stop; i += step)
                r ~= Value(i);
        return Value(r);
    }));

    env.globals["dict"] = Value(new Func("dict", (Value[] a, Dict k) {
        auto d = new Dict;
        if (a.length && a[0].isDict)
            d.update(a[0].dict);
        else if (a.length && a[0].isList)
            foreach (pair; a[0].list.items)
                d[pair[0].toString] = pair[1];
        if (k !is null)
            d.update(k);
        return Value(d);
    }));

    env.globals["namespace"] = Value(new Func("namespace", (Value[] a, Dict k) {
        auto ns = new Namespace;
        if (a.length && a[0].isDict)
            ns.attrs.update(a[0].dict);
        if (k !is null)
            ns.attrs.update(k);
        return Value(ns);
    }));

    env.globals["joiner"] = Value(new Func("joiner", (Value[] a, Dict k) {
        auto sep = a.length ? a[0].toString : ", ";
        bool used;
        return Value(new Func("joiner", (Value[] b, Dict kk) {
            if (!used)
            {
                used = true;
                return Value("");
            }
            return Value(sep);
        }));
    }));
}

private Value groupTuple(Value key, Value[] items)
{
    auto g = new GroupTuple;
    g.grouper = key;
    g.list_ = items;
    return Value(g);
}

private final class GroupTuple : Obj, Iterable
{
    Value grouper;
    Value[] list_;
    override Value getAttr(string name)
    {
        if (name == "grouper")
            return grouper;
        if (name == "list")
            return Value(list_);
        return Value.undefined;
    }

    Value[] iterate() { return [grouper, Value(list_)]; }
}
