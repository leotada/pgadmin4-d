/// A dynamic, Python-like value.
///
/// pgAdmin's backend is written against Python dictionaries, lists and scalars: rows come back from the database as
/// dicts, request bodies are parsed into dicts, and the SQL templates are rendered from them. `Value` gives the D port
/// the same model, so the code can follow the original closely:
///
///  - `null` (None), `bool`, `long` (int), `double` (float) and `string` (str) scalars;
///  - `List` and `Dict` are reference types, like Python's: changing a row through one reference changes it everywhere;
///  - `Dict` keeps insertion order (Python 3.7+ semantics), so JSON output matches the original byte for byte;
///  - truthiness, equality (`1 == 1.0 == True`) and `str()` follow Python.
module pgadmin.core.value;

import std.array : appender, Appender;
import std.conv : to;
import std.exception : enforce;
import std.format : format;
import std.math : isNaN, isInfinity, floor;
import std.traits : isIntegral, isFloatingPoint, isSomeString;

enum VType : ubyte
{
    none,
    boolean,
    integer,
    floating,
    str,
    list,
    dict,
    func,
    object,
}

/// Python's `KeyError`, `TypeError`, `ValueError`... raised by Value operations.
class PyError : Exception
{
    string kind;
    this(string kind, string msg, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line);
        this.kind = kind;
    }
}

PyError keyError(string key) => new PyError("KeyError", "'" ~ key ~ "'");
PyError typeError(string msg) => new PyError("TypeError", msg);
PyError valueError(string msg) => new PyError("ValueError", msg);

/// Base of every reference type a Value can hold.
abstract class Obj
{
    /// Attribute access from templates (`obj.name`). Returns `Value.undefined` when missing.
    Value getAttr(string name) { return Value.undefined; }
    string typeName() const { return "object"; }
    /// `str(obj)`
    override string toString() const { return "<" ~ typeName() ~ ">"; }
}

/// Signature of callables (template functions, bound methods, macros).
alias NativeFn = Value delegate(Value[] args, Dict kwargs);

final class Func : Obj
{
    string name;
    NativeFn fn;
    /// Macros remember a caller for `{{ caller() }}`; plain functions ignore it.
    this(string name, NativeFn fn)
    {
        this.name = name;
        this.fn = fn;
    }

    Value call(Value[] args, Dict kwargs = null) => fn(args, kwargs);
    override string typeName() const { return "function"; }
}

final class List : Obj
{
    Value[] items;
    bool tuple; /// created from a (a, b) literal; only matters for repr

    this() {}
    this(Value[] items) { this.items = items; }

    size_t length() const => items.length;
    ref Value opIndex(size_t i) { return items[i]; }
    void append(Value v) { items ~= v; }
    override string typeName() const { return tuple ? "tuple" : "list"; }

    int opApply(scope int delegate(ref Value) dg)
    {
        foreach (ref v; items)
            if (auto r = dg(v))
                return r;
        return 0;
    }

    int opApply(scope int delegate(size_t, ref Value) dg)
    {
        foreach (i, ref v; items)
            if (auto r = dg(i, v))
                return r;
        return 0;
    }
}

/// An insertion-ordered dictionary with string keys.
final class Dict : Obj
{
    private string[] keys_;
    private Value[] vals_;
    private bool[] dead_;
    private size_t[string] index;
    private size_t deleted;

    this() {}

    size_t length() const => index.length;

    bool has(string k) const => (k in index) !is null;

    Value* find(string k)
    {
        if (auto p = k in index)
            return &vals_[*p];
        return null;
    }

    ref Value opIndex(string k)
    {
        if (auto p = k in index)
            return vals_[*p];
        throw keyError(k);
    }

    void opIndexAssign(Value v, string k)
    {
        if (auto p = k in index)
            vals_[*p] = v;
        else
        {
            index[k] = keys_.length;
            keys_ ~= k;
            vals_ ~= v;
            dead_ ~= false;
        }
    }

    void opIndexAssign(T)(T v, string k) if (!is(T == Value))
    {
        opIndexAssign(Value(v), k);
    }

    Value get(string k, Value def = Value.init)
    {
        if (auto p = k in index)
            return vals_[*p];
        return def;
    }

    /// Removes `k`; returns its value (or `def` when absent), like `dict.pop(k, def)`.
    Value pop(string k, Value def = Value.init)
    {
        auto p = k in index;
        if (p is null)
            return def;
        auto i = *p;
        auto v = vals_[i];
        index.remove(k);
        dead_[i] = true;
        vals_[i] = Value.init;
        deleted++;
        if (deleted > 16 && deleted * 2 > keys_.length)
            compact();
        return v;
    }

    bool remove(string k)
    {
        if (!has(k))
            return false;
        pop(k);
        return true;
    }

    private void compact()
    {
        string[] nk;
        Value[] nv;
        foreach (i, k; keys_)
        {
            if (dead_[i])
                continue;
            index[k] = nk.length;
            nk ~= k;
            nv ~= vals_[i];
        }
        keys_ = nk;
        vals_ = nv;
        dead_ = new bool[nk.length];
        deleted = 0;
    }

    string[] keys()
    {
        string[] r;
        r.reserve(index.length);
        foreach (i, k; keys_)
            if (!dead_[i])
                r ~= k;
        return r;
    }

    Value[] values()
    {
        Value[] r;
        foreach (i, k; keys_)
            if (!dead_[i])
                r ~= vals_[i];
        return r;
    }

    void update(Dict other)
    {
        if (other is null)
            return;
        foreach (k, v; other)
            this[k] = v;
    }

    Dict copy()
    {
        auto d = new Dict;
        foreach (k, v; this)
            d[k] = v;
        return d;
    }

    void clear()
    {
        keys_ = null;
        vals_ = null;
        dead_ = null;
        index = null;
        deleted = 0;
    }

    int opApply(scope int delegate(string, ref Value) dg)
    {
        // iterate over a snapshot of the length: entries added meanwhile are not visited
        immutable n = keys_.length;
        foreach (i; 0 .. n)
        {
            if (i >= keys_.length || dead_[i])
                continue;
            if (auto r = dg(keys_[i], vals_[i]))
                return r;
        }
        return 0;
    }

    override string typeName() const { return "dict"; }
}

/// The dynamic value.
struct Value
{
    VType type;
    private union
    {
        bool b_;
        long i_;
        double f_;
    }
    private string s_;
    private Obj o_;
    /// Set on values that came from a missing template variable / attribute (Jinja's `Undefined`).
    bool isUndefined;
    /// A string that is already HTML-safe (Jinja's `Markup`); only matters under autoescaping.
    bool safe;

    // ------------------------------------------------------------ construction

    static Value undefined()
    {
        Value v;
        v.isUndefined = true;
        return v;
    }

    /// An undefined value that remembers why (Jinja's `Undefined` hint, used in the error when it is dereferenced).
    static Value undefined(string hint)
    {
        Value v;
        v.isUndefined = true;
        v.s_ = hint;
        return v;
    }

    /// The hint of an undefined value ("'data' is undefined", "'dict object' has no attribute 'x'").
    string undefinedHint() const => s_;

    this(typeof(null)) { type = VType.none; }
    this(Value v) { this = v; }
    this(bool b) { type = VType.boolean; b_ = b; }
    // non-template int/long constructors, so that the literals 0 and 1 do not pick the bool one
    this(int i) { type = VType.integer; i_ = i; }
    this(long i) { type = VType.integer; i_ = i; }
    this(T)(T i) if (isIntegral!T && !is(T == bool) && !is(T == char) && !is(T == int) && !is(T == long))
    {
        type = VType.integer;
        i_ = cast(long) i;
    }
    this(T)(T f) if (isFloatingPoint!T)
    {
        type = VType.floating;
        f_ = cast(double) f;
    }
    this(string s)
    {
        if (s is null)
            s = "";
        type = VType.str;
        s_ = s;
    }
    this(const(char)[] s) { this(s.idup); }
    this(Dict d)
    {
        if (d is null)
            type = VType.none;
        else
        {
            type = VType.dict;
            o_ = d;
        }
    }
    this(List l)
    {
        if (l is null)
            type = VType.none;
        else
        {
            type = VType.list;
            o_ = l;
        }
    }
    this(Func f)
    {
        if (f is null)
            type = VType.none;
        else
        {
            type = VType.func;
            o_ = f;
        }
    }
    this(Obj o)
    {
        o_ = o;
        if (o is null)
            type = VType.none;
        else if (cast(Dict) o)
            type = VType.dict;
        else if (cast(List) o)
            type = VType.list;
        else if (cast(Func) o)
            type = VType.func;
        else
            type = VType.object;
    }
    this(Value[] arr) { this(new List(arr)); }
    this(T)(T[] arr) if (!is(T == Value) && !isSomeString!(T[]) && !is(T == immutable(char)) && !is(T == ubyte))
    {
        auto l = new List;
        foreach (x; arr)
            l.items ~= Value(x);
        this(l);
    }
    this(T)(T[string] aa)
    {
        auto d = new Dict;
        import std.algorithm : sort;
        foreach (k; aa.keys.sort)
            d[k] = Value(aa[k]);
        this(d);
    }

    static Value newDict() => Value(new Dict);
    static Value newList() => Value(new List);
    static Value tuple(Value[] items...)
    {
        auto l = new List(items.dup);
        l.tuple = true;
        return Value(l);
    }

    /// Builds a dict from alternating keys and values: `Value.dictOf("a", 1, "b", "x")`.
    static Value dictOf(Args...)(Args args)
    {
        static assert(Args.length % 2 == 0, "dictOf needs key/value pairs");
        auto d = new Dict;
        static foreach (i; 0 .. Args.length / 2)
            d[args[2 * i]] = Value(args[2 * i + 1]);
        return Value(d);
    }

    static Value listOf(Args...)(Args args)
    {
        auto l = new List;
        foreach (a; args)
            l.items ~= Value(a);
        return Value(l);
    }

    // ------------------------------------------------------------ type checks

    bool isNone() const => type == VType.none;
    bool isNull() const => type == VType.none;
    bool isBool() const => type == VType.boolean;
    bool isInt() const => type == VType.integer;
    bool isFloat() const => type == VType.floating;
    bool isNumber() const => type == VType.integer || type == VType.floating || type == VType.boolean;
    bool isString() const => type == VType.str;
    bool isList() const => type == VType.list;
    bool isDict() const => type == VType.dict;
    bool isFunc() const => type == VType.func;
    bool isObject() const => type == VType.object;
    /// Jinja's `is defined`
    bool isDefined() const => !isUndefined;

    // ------------------------------------------------------------ accessors

    bool boolean() const
    {
        enforce(type == VType.boolean, typeError("expected bool, got " ~ typeName));
        return b_;
    }

    /// The value as an integer (bools and integral floats convert; numeric strings parse).
    long integer() const
    {
        final switch (type)
        {
        case VType.integer: return i_;
        case VType.boolean: return b_ ? 1 : 0;
        case VType.floating: return cast(long) f_;
        case VType.str:
            import std.string : strip;
            try
                return to!long(s_.strip);
            catch (Exception)
                throw valueError("invalid literal for int() with base 10: '" ~ s_ ~ "'");
        case VType.none, VType.list, VType.dict, VType.func, VType.object:
            throw typeError("int() argument must be a string or a number, not '" ~ typeName ~ "'");
        }
    }

    double floating() const
    {
        switch (type)
        {
        case VType.floating: return f_;
        case VType.integer: return cast(double) i_;
        case VType.boolean: return b_ ? 1 : 0;
        case VType.str:
            import std.string : strip;
            try
                return to!double(s_.strip);
            catch (Exception)
                throw valueError("could not convert string to float: '" ~ s_ ~ "'");
        default:
            throw typeError("float() argument must be a string or a number, not '" ~ typeName ~ "'");
        }
    }

    /// The string payload (only for strings; use `toString` for `str()`).
    string str() const
    {
        enforce(type == VType.str, typeError("expected str, got " ~ typeName));
        return s_;
    }

    /// The string payload, or `def` for None/undefined.
    string strOr(string def = null) const
    {
        if (type == VType.str)
            return s_;
        if (type == VType.none)
            return def;
        return toString();
    }

    List list()
    {
        enforce(type == VType.list, typeError("expected list, got " ~ typeName));
        return cast(List) o_;
    }

    Dict dict()
    {
        enforce(type == VType.dict, typeError("expected dict, got " ~ typeName));
        return cast(Dict) o_;
    }

    Func func()
    {
        enforce(type == VType.func, typeError("'" ~ typeName ~ "' object is not callable"));
        return cast(Func) o_;
    }

    Obj obj() { return o_; }

    T as(T : Obj)() { return cast(T) o_; }

    string typeName() const
    {
        final switch (type)
        {
        case VType.none: return isUndefined ? "Undefined" : "NoneType";
        case VType.boolean: return "bool";
        case VType.integer: return "int";
        case VType.floating: return "float";
        case VType.str: return "str";
        case VType.list: return (cast(const List) o_).tuple ? "tuple" : "list";
        case VType.dict: return "dict";
        case VType.func: return "function";
        case VType.object: return o_.typeName();
        }
    }

    // ------------------------------------------------------------ Python semantics

    /// Python truthiness.
    bool truthy() const
    {
        final switch (type)
        {
        case VType.none: return false;
        case VType.boolean: return b_;
        case VType.integer: return i_ != 0;
        case VType.floating: return f_ != 0;
        case VType.str: return s_.length != 0;
        case VType.list: return (cast(const List) o_).items.length != 0;
        case VType.dict: return (cast(const Dict) o_).length != 0;
        case VType.func, VType.object: return true;
        }
    }

    bool opCast(T : bool)() const => truthy();

    /// `len(x)`
    size_t length()
    {
        switch (type)
        {
        case VType.str: return utf8Length(s_);
        case VType.list: return list.items.length;
        case VType.dict: return dict.length;
        default: throw typeError("object of type '" ~ typeName ~ "' has no len()");
        }
    }

    /// `str(x)`
    string toString() const
    {
        final switch (type)
        {
        case VType.none: return isUndefined ? "" : "None";
        case VType.boolean: return b_ ? "True" : "False";
        // (an undefined value keeps its hint in s_; it still prints as "")
        case VType.integer: return to!string(i_);
        case VType.floating: return pyFloatRepr(f_);
        case VType.str: return s_;
        case VType.list, VType.dict: return repr();
        case VType.func: return "<function " ~ (cast(const Func) o_).name ~ ">";
        case VType.object: return o_.toString();
        }
    }

    /// `repr(x)`
    string repr() const
    {
        switch (type)
        {
        case VType.str: return pyStrRepr(s_);
        case VType.list:
            auto l = cast(List) cast() o_;
            auto a = appender!string;
            a.put(l.tuple ? "(" : "[");
            foreach (i, v; l.items)
            {
                if (i)
                    a.put(", ");
                a.put(v.repr());
            }
            if (l.tuple && l.items.length == 1)
                a.put(",");
            a.put(l.tuple ? ")" : "]");
            return a.data;
        case VType.dict:
            auto d = cast(Dict) cast() o_;
            auto a = appender!string;
            a.put("{");
            bool first = true;
            foreach (k, v; d)
            {
                if (!first)
                    a.put(", ");
                first = false;
                a.put(pyStrRepr(k));
                a.put(": ");
                a.put(v.repr());
            }
            a.put("}");
            return a.data;
        default:
            return toString();
        }
    }

    bool opEquals(const Value o) const
    {
        if (isUndefined != o.isUndefined)
            return false;
        if (isNumber && o.isNumber)
        {
            if (type == VType.floating || o.type == VType.floating)
                return (cast() this).floating == (cast() o).floating;
            return (cast() this).integer == (cast() o).integer;
        }
        if (type != o.type)
            return false;
        final switch (type)
        {
        case VType.none: return true;
        case VType.boolean, VType.integer, VType.floating: return false; // handled above
        case VType.str: return s_ == o.s_;
        case VType.list:
            auto a = (cast(const List) o_).items, b = (cast(const List) o.o_).items;
            if (a.length != b.length)
                return false;
            foreach (i; 0 .. a.length)
                if (a[i] != b[i])
                    return false;
            return true;
        case VType.dict:
            auto a = cast(Dict) cast() o_, b = cast(Dict) cast() o.o_;
            if (a.length != b.length)
                return false;
            foreach (k, v; a)
            {
                auto p = b.find(k);
                if (p is null || *p != v)
                    return false;
            }
            return true;
        case VType.func, VType.object: return o_ is o.o_;
        }
    }

    bool opEquals(T)(T other) const if (!is(T == Value) && !is(T : const Value))
    {
        return opEquals(Value(other));
    }

    size_t toHash() const nothrow @trusted
    {
        try
        {
            if (type == VType.str)
                return hashOf(s_);
            if (isNumber)
                return hashOf((cast() this).floating);
            return hashOf(cast(void*) o_);
        }
        catch (Exception)
            return 0;
    }

    /// Python ordering (numbers with numbers, strings with strings, lists lexicographically).
    int opCmp(const Value o) const
    {
        if (isNumber && o.isNumber)
        {
            auto a = (cast() this).floating, b = (cast() o).floating;
            return a < b ? -1 : a > b ? 1 : 0;
        }
        if (type == VType.str && o.type == VType.str)
            return s_ < o.s_ ? -1 : s_ > o.s_ ? 1 : 0;
        if (type == VType.list && o.type == VType.list)
        {
            auto a = (cast(const List) o_).items, b = (cast(const List) o.o_).items;
            foreach (i; 0 .. a.length < b.length ? a.length : b.length)
                if (auto c = a[i].opCmp(b[i]))
                    return c;
            return a.length < b.length ? -1 : a.length > b.length ? 1 : 0;
        }
        if (type == VType.none && o.type == VType.none)
            return 0;
        throw typeError("'<' not supported between instances of '" ~ typeName ~ "' and '" ~ o.typeName ~ "'");
    }

    // ------------------------------------------------------------ containers

    /// `x[key]` on a dict. Throws KeyError when missing.
    ref Value opIndex(string k)
    {
        if (type == VType.dict)
            return dict()[k];
        throw typeError("'" ~ typeName ~ "' object is not subscriptable with a string");
    }

    ref Value opIndex(size_t i)
    {
        if (type == VType.list)
        {
            auto l = list();
            if (i >= l.items.length)
                throw new PyError("IndexError", "list index out of range");
            return l.items[i];
        }
        throw typeError("'" ~ typeName ~ "' object is not subscriptable with an integer");
    }

    void opIndexAssign(T)(T v, string k)
    {
        if (type != VType.dict)
            throw typeError("'" ~ typeName ~ "' object does not support item assignment");
        dict()[k] = Value(v);
    }

    void opIndexAssign(T)(T v, size_t i)
    {
        list()[i] = Value(v);
    }

    /// `key in x`: dict keys, list items or a substring.
    bool contains(Value k)
    {
        switch (type)
        {
        case VType.dict: return k.type == VType.str ? dict.has(k.s_) : dict.has(k.toString);
        case VType.list:
            foreach (ref v; list.items)
                if (v == k)
                    return true;
            return false;
        case VType.str:
            import std.algorithm : canFind;
            return s_.canFind(k.toString);
        case VType.none: return false;
        default: throw typeError("argument of type '" ~ typeName ~ "' is not iterable");
        }
    }

    bool contains(string k)
    {
        if (type == VType.dict)
            return dict.has(k);
        return contains(Value(k));
    }

    bool opBinaryRight(string op : "in")(string k) { return contains(k); }
    bool opBinaryRight(string op : "in")(Value k) { return contains(k); }

    /// `d.get(k, def)` (None when `this` is not a dict).
    Value get(string k, Value def = Value(null))
    {
        if (type != VType.dict)
            return def;
        return dict.get(k, def);
    }

    Value get(T)(string k, T def) if (!is(T == Value))
    {
        return get(k, Value(def));
    }

    /// `d.setdefault(k, def)`
    Value setDefault(string k, Value def)
    {
        auto d = dict();
        if (auto p = d.find(k))
            return *p;
        d[k] = def;
        return def;
    }

    void append(T)(T v)
    {
        list().append(Value(v));
    }

    /// Iterates list items, dict keys or the characters of a string (Python iteration).
    Value[] iterItems()
    {
        switch (type)
        {
        case VType.list: return list.items;
        case VType.dict:
            Value[] r;
            foreach (k; dict.keys)
                r ~= Value(k);
            return r;
        case VType.str:
            Value[] r;
            import std.utf : byDchar;
            foreach (dchar c; s_)
                r ~= Value(to!string(c));
            return r;
        case VType.none:
            if (isUndefined)
                return null;
            throw typeError("'NoneType' object is not iterable");
        default: throw typeError("'" ~ typeName ~ "' object is not iterable");
        }
    }

    int opApply(scope int delegate(ref Value) dg)
    {
        foreach (v; iterItems())
            if (auto r = dg(v))
                return r;
        return 0;
    }

    /// Python attribute access for templates.
    Value getAttr(string name)
    {
        switch (type)
        {
        case VType.dict:
            // Jinja: obj.attr looks up the attribute first, then the item
            if (auto p = dict.find(name))
                return *p;
            return Value.undefined;
        case VType.object:
            return o_.getAttr(name);
        default:
            return Value.undefined;
        }
    }

    /// Deep copy of dicts and lists (`copy.deepcopy`).
    Value deepCopy()
    {
        switch (type)
        {
        case VType.dict:
            auto d = new Dict;
            foreach (k, v; dict)
                d[k] = v.deepCopy();
            return Value(d);
        case VType.list:
            auto l = new List;
            l.tuple = list.tuple;
            foreach (v; list.items)
                l.items ~= v.deepCopy();
            return Value(l);
        default:
            return this;
        }
    }

    /// Shallow copy (`dict(x)`, `list(x)`, `x.copy()`).
    Value shallowCopy()
    {
        switch (type)
        {
        case VType.dict: return Value(dict.copy());
        case VType.list: return Value(new List(list.items.dup));
        default: return this;
        }
    }

    // ------------------------------------------------------------ JSON

    /// `json.dumps(x, separators=(',', ':'))` (ensure_ascii, Python float repr).
    string toJson() const
    {
        auto a = appender!string;
        writeJson(a);
        return a.data;
    }

    /// `json.dumps(x)` with the default `, ` and `: ` separators.
    string toJsonSpaced() const
    {
        auto a = appender!string;
        writeJson(a, true);
        return a.data;
    }

    void writeJson(ref Appender!string a, bool spaced = false) const
    {
        final switch (type)
        {
        case VType.none: a.put("null"); break;
        case VType.boolean: a.put(b_ ? "true" : "false"); break;
        case VType.integer: a.put(to!string(i_)); break;
        case VType.floating:
            if (isNaN(f_))
                a.put("NaN");
            else if (isInfinity(f_))
                a.put(f_ > 0 ? "Infinity" : "-Infinity");
            else
                a.put(pyFloatRepr(f_));
            break;
        case VType.str: jsonString(a, s_); break;
        case VType.list:
            a.put("[");
            foreach (i, v; (cast(const List) o_).items)
            {
                if (i)
                    a.put(spaced ? ", " : ",");
                v.writeJson(a, spaced);
            }
            a.put("]");
            break;
        case VType.dict:
            a.put("{");
            bool first = true;
            foreach (k, v; cast(Dict) cast() o_)
            {
                if (!first)
                    a.put(spaced ? ", " : ",");
                first = false;
                jsonString(a, k);
                a.put(spaced ? ": " : ":");
                v.writeJson(a, spaced);
            }
            a.put("}");
            break;
        case VType.func: a.put("null"); break;
        case VType.object:
            if (auto j = cast(JsonSerializable) cast() o_)
                j.writeJson(a);
            else
                jsonString(a, o_.toString());
            break;
        }
    }
}

/// An `Obj` that knows how to write itself as JSON (dates, decimals...).
interface JsonSerializable
{
    void writeJson(ref Appender!string a) const;
}

// ------------------------------------------------------------ helpers

size_t utf8Length(string s) pure
{
    size_t n;
    foreach (char c; s)
        if ((c & 0xC0) != 0x80)
            n++;
    return n;
}

/// Python's `repr(float)`: the shortest string that reads back to the same double.
string pyFloatRepr(double f)
{
    if (isNaN(f))
        return "nan";
    if (isInfinity(f))
        return f > 0 ? "inf" : "-inf";
    if (f == 0)
        return (1 / f < 0) ? "-0.0" : "0.0";
    string digits;
    int exp10;
    shortestDigits(f, digits, exp10);
    // digits is d1d2d3... and the value is 0.d1d2d3 * 10^exp10
    immutable neg = f < 0;
    immutable decpt = exp10; // position of the decimal point relative to digits
    string r;
    // Python uses scientific notation when the exponent is < -4 or >= 16
    immutable sciExp = decpt - 1;
    if (sciExp < -4 || sciExp >= 16)
    {
        r = digits[0 .. 1];
        if (digits.length > 1)
            r ~= "." ~ digits[1 .. $];
        r ~= "e" ~ (sciExp < 0 ? "-" : "+");
        auto e = to!string(sciExp < 0 ? -sciExp : sciExp);
        if (e.length < 2)
            e = "0" ~ e;
        r ~= e;
    }
    else if (decpt <= 0)
    {
        r = "0.";
        foreach (_; 0 .. -decpt)
            r ~= "0";
        r ~= digits;
    }
    else if (decpt >= digits.length)
    {
        r = digits;
        foreach (_; 0 .. decpt - digits.length)
            r ~= "0";
        r ~= ".0";
    }
    else
        r = digits[0 .. decpt] ~ "." ~ digits[decpt .. $];
    return neg ? "-" ~ r : r;
}

private void shortestDigits(double f, out string digits, out int exp10)
{
    import core.stdc.stdio : snprintf;
    import core.stdc.stdlib : strtod;

    double a = f < 0 ? -f : f;
    char[64] buf;
    foreach (prec; 1 .. 18)
    {
        auto n = snprintf(buf.ptr, buf.length, "%.*e", prec - 1, a);
        buf[n] = 0;
        if (strtod(buf.ptr, null) == a || prec == 17)
        {
            // buf looks like d.ddddde[+-]XX
            auto s = buf[0 .. n];
            size_t epos;
            foreach (i, c; s)
                if (c == 'e')
                    epos = i;
            string m;
            foreach (c; s[0 .. epos])
                if (c != '.')
                    m ~= c;
            // strip trailing zeros
            while (m.length > 1 && m[$ - 1] == '0')
                m = m[0 .. $ - 1];
            digits = m;
            exp10 = to!int(s[epos + 1 .. $]) + 1;
            return;
        }
    }
}

/// Python's `repr(str)`.
string pyStrRepr(string s)
{
    import std.algorithm : canFind;

    char q = '\'';
    if (s.canFind('\'') && !s.canFind('"'))
        q = '"';
    auto a = appender!string;
    a.put(q);
    foreach (dchar c; s)
    {
        if (c == q || c == '\\')
        {
            a.put('\\');
            a.put(c);
        }
        else if (c == '\n')
            a.put("\\n");
        else if (c == '\r')
            a.put("\\r");
        else if (c == '\t')
            a.put("\\t");
        else if (c < 0x20 || c == 0x7f)
            a.put(format("\\x%02x", cast(uint) c));
        else
            a.put(c);
    }
    a.put(q);
    return a.data;
}

/// Writes a JSON string with Python's `ensure_ascii=True` escaping.
void jsonString(ref Appender!string a, string s)
{
    static immutable hex = "0123456789abcdef";
    a.put('"');
    size_t i;
    while (i < s.length)
    {
        char c = s[i];
        if (c < 0x80)
        {
            switch (c)
            {
            case '"': a.put("\\\""); break;
            case '\\': a.put("\\\\"); break;
            case '\n': a.put("\\n"); break;
            case '\r': a.put("\\r"); break;
            case '\t': a.put("\\t"); break;
            case '\b': a.put("\\b"); break;
            case '\f': a.put("\\f"); break;
            default:
                if (c < 0x20 || c == 0x7f)
                {
                    if (c == 0x7f)
                    {
                        a.put(c);
                        break;
                    }
                    a.put("\\u00");
                    a.put(hex[c >> 4]);
                    a.put(hex[c & 15]);
                }
                else
                    a.put(c);
            }
            i++;
            continue;
        }
        dchar d;
        try
        {
            import std.utf : decode;
            d = decode(s, i);
        }
        catch (Exception)
        {
            d = 0xFFFD;
            i++;
        }
        void u16(uint x)
        {
            a.put("\\u");
            a.put(hex[(x >> 12) & 15]);
            a.put(hex[(x >> 8) & 15]);
            a.put(hex[(x >> 4) & 15]);
            a.put(hex[x & 15]);
        }

        if (d >= 0x10000)
        {
            uint v = d - 0x10000;
            u16(0xD800 + (v >> 10));
            u16(0xDC00 + (v & 0x3FF));
        }
        else
            u16(d);
    }
    a.put('"');
}

// ------------------------------------------------------------ JSON parsing

/// `json.loads`: objects keep their key order; integers stay integers.
Value parseJson(const(char)[] text)
{
    auto p = JsonParser(text);
    p.ws();
    auto v = p.value();
    p.ws();
    if (p.i != text.length)
        throw valueError("Extra data: line 1 column " ~ to!string(p.i + 1));
    return v;
}

/// Like `parseJson` but returns `def` instead of throwing.
Value tryParseJson(const(char)[] text, Value def = Value(null))
{
    try
        return parseJson(text);
    catch (Exception)
        return def;
}

private struct JsonParser
{
    const(char)[] s;
    size_t i;

    void ws()
    {
        while (i < s.length && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r'))
            i++;
    }

    noreturn fail(string what)
    {
        throw valueError("Expecting " ~ what ~ ": char " ~ to!string(i));
    }

    Value value()
    {
        if (i >= s.length)
            fail("value");
        switch (s[i])
        {
        case '{':
            i++;
            auto d = new Dict;
            ws();
            if (i < s.length && s[i] == '}')
            {
                i++;
                return Value(d);
            }
            for (;;)
            {
                ws();
                if (i >= s.length || s[i] != '"')
                    fail("property name enclosed in double quotes");
                auto k = str();
                ws();
                if (i >= s.length || s[i] != ':')
                    fail("':' delimiter");
                i++;
                ws();
                d[k] = value();
                ws();
                if (i < s.length && s[i] == ',')
                {
                    i++;
                    continue;
                }
                if (i < s.length && s[i] == '}')
                {
                    i++;
                    return Value(d);
                }
                fail("',' delimiter");
            }
        case '[':
            i++;
            auto l = new List;
            ws();
            if (i < s.length && s[i] == ']')
            {
                i++;
                return Value(l);
            }
            for (;;)
            {
                ws();
                l.items ~= value();
                ws();
                if (i < s.length && s[i] == ',')
                {
                    i++;
                    continue;
                }
                if (i < s.length && s[i] == ']')
                {
                    i++;
                    return Value(l);
                }
                fail("',' delimiter");
            }
        case '"':
            return Value(str());
        case 't':
            return lit("true", Value(true));
        case 'f':
            return lit("false", Value(false));
        case 'n':
            return lit("null", Value(null));
        case 'N':
            return lit("NaN", Value(double.nan));
        case 'I':
            return lit("Infinity", Value(double.infinity));
        default:
            return number();
        }
    }

    Value lit(string w, Value v)
    {
        if (i + w.length <= s.length && s[i .. i + w.length] == w)
        {
            i += w.length;
            return v;
        }
        fail("value");
    }

    Value number()
    {
        auto st = i;
        if (i < s.length && s[i] == '-')
            i++;
        if (i + 8 <= s.length && s[i .. i + 8] == "Infinity")
        {
            i += 8;
            return Value(-double.infinity);
        }
        bool isF;
        while (i < s.length && s[i] >= '0' && s[i] <= '9')
            i++;
        if (i < s.length && s[i] == '.')
        {
            isF = true;
            i++;
            while (i < s.length && s[i] >= '0' && s[i] <= '9')
                i++;
        }
        if (i < s.length && (s[i] == 'e' || s[i] == 'E'))
        {
            isF = true;
            i++;
            if (i < s.length && (s[i] == '+' || s[i] == '-'))
                i++;
            while (i < s.length && s[i] >= '0' && s[i] <= '9')
                i++;
        }
        auto t = s[st .. i];
        if (t.length == 0 || t == "-")
            fail("value");
        if (isF)
            return Value(to!double(t));
        try
            return Value(to!long(t));
        catch (Exception)
            return Value(to!double(t)); // beyond 64 bits: Python keeps it exact, we lose precision
    }

    string str()
    {
        i++; // opening quote
        auto a = appender!string;
        for (;;)
        {
            if (i >= s.length)
                fail("unterminated string");
            char c = s[i++];
            if (c == '"')
                break;
            if (c != '\\')
            {
                a.put(c);
                continue;
            }
            if (i >= s.length)
                fail("escape");
            char e = s[i++];
            switch (e)
            {
            case '"': a.put('"'); break;
            case '\\': a.put('\\'); break;
            case '/': a.put('/'); break;
            case 'b': a.put('\b'); break;
            case 'f': a.put('\f'); break;
            case 'n': a.put('\n'); break;
            case 'r': a.put('\r'); break;
            case 't': a.put('\t'); break;
            case 'u':
                dchar d = hex4();
                if (d >= 0xD800 && d < 0xDC00 && i + 6 <= s.length && s[i] == '\\' && s[i + 1] == 'u')
                {
                    i += 2;
                    dchar lo = hex4();
                    if (lo >= 0xDC00 && lo < 0xE000)
                        d = 0x10000 + ((d - 0xD800) << 10) + (lo - 0xDC00);
                    else
                    {
                        putUtf(a, d);
                        d = lo;
                    }
                }
                putUtf(a, d);
                break;
            default:
                fail("valid escape");
            }
        }
        return a.data;
    }

    dchar hex4()
    {
        if (i + 4 > s.length)
            fail("4 hex digits");
        uint v;
        foreach (k; 0 .. 4)
        {
            char c = s[i++];
            v <<= 4;
            if (c >= '0' && c <= '9')
                v |= c - '0';
            else if (c >= 'a' && c <= 'f')
                v |= c - 'a' + 10;
            else if (c >= 'A' && c <= 'F')
                v |= c - 'A' + 10;
            else
                fail("hex digit");
        }
        return cast(dchar) v;
    }
}

void putUtf(ref Appender!string a, dchar d)
{
    import std.utf : encode;

    if (d >= 0xD800 && d < 0xE000)
        d = 0xFFFD;
    char[4] buf;
    auto n = encode(buf, d);
    a.put(buf[0 .. n]);
}

unittest
{
    auto v = parseJson(`{"b":1,"a":[1,2.5,"xé",null,true],"c":{"d":-3e2}}`);
    assert(v["b"] == 1);
    assert(v["a"][1] == 2.5);
    assert(v.toJson == "{\"b\":1,\"a\":[1,2.5,\"x\\u00e9\",null,true],\"c\":{\"d\":-300.0}}");
    assert(pyFloatRepr(0.1) == "0.1");
    assert(pyFloatRepr(1e16) == "1e+16");
    assert(pyFloatRepr(1e-5) == "1e-05");
    assert(pyFloatRepr(123.0) == "123.0");
    assert(pyFloatRepr(0.0001) == "0.0001");
    assert(Value(1) == Value(1.0));
    assert(Value(true) == Value(1));
    assert(!Value(""));
    auto d = Value.newDict();
    d["x"] = 1;
    auto e = d;
    e["y"] = "z";
    assert(d.dict.length == 2);
    d.dict.pop("x");
    assert(d.toJson == `{"y":"z"}`);
    assert("y" in d);
}

/// Builds a `Dict` from alternating keys and values (keyword arguments of the Python code).
Dict kwDict(Args...)(Args args)
{
    static assert(Args.length % 2 == 0, "kwDict needs key/value pairs");
    auto d = new Dict;
    static foreach (i; 0 .. Args.length / 2)
        d[args[2 * i]] = Value(args[2 * i + 1]);
    return d;
}
