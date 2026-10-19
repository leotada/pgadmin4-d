/// Jinja2 interpreter.
///
/// `Environment` owns the loader, the template cache, the globals, filters and tests. `render` evaluates a parsed
/// template against a context of `Value`s. Semantics follow Jinja2 (Python): attribute lookup tries the attribute
/// (dict methods, string methods) before the item, `for` loops have their own scope, macros are callables that return
/// their output, `import` renders a template module without the caller's context.
///
/// One deliberate difference: attribute access on an undefined value yields another undefined value (Jinja's
/// `ChainableUndefined`) instead of raising, so `data.a.b` on a missing `a` is just undefined.
module pgadmin.jinja.runtime;

import std.array : appender, Appender, join, split;
import std.algorithm : canFind, sort, startsWith, endsWith, countUntil;
import std.conv : to;
import std.string : toLower, toUpper, strip, stripLeft, stripRight, indexOf, replace;
import std.uni : isWhite;
import pgadmin.core.value;
import pgadmin.jinja.ast;
import pgadmin.jinja.lexer;
import pgadmin.jinja.parser;

class TemplateNotFound : Exception
{
    string name;
    this(string name, string file = __FILE__, size_t line = __LINE__)
    {
        super(name, file, line);
        this.name = name;
    }
}

class TemplateRuntimeError : Exception
{
    /// "template.sql:12", for logs; the message stays what Jinja would say (users see it in error responses)
    string location;

    this(string msg, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line);
    }
}

/// Jinja's `UndefinedError`: an undefined value was dereferenced, called or used in arithmetic.
class UndefinedError : TemplateRuntimeError
{
    this(string msg, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line);
    }
}

noreturn failUndefined(Value v)
{
    throw new UndefinedError(v.undefinedHint.length ? v.undefinedHint : "undefined value");
}

/// Jinja's `object_type_repr`.
string objectTypeRepr(Value v)
{
    if (v.isNone)
        return "None";
    return v.typeName ~ " object";
}

/// Finds template sources by name.
interface Loader
{
    /// Returns the source and a cache key (usually the resolved path), or throws `TemplateNotFound`.
    string load(string name, out string cacheKey);
}

alias FilterFn = Value delegate(Context ctx, Value v, Value[] args, Dict kwargs);
alias TestFn = bool delegate(Value v, Value[] args);

/// A `Value` object that renders as is under autoescape (Jinja's `Markup`).
Value markSafe(string s)
{
    auto v = Value(s);
    v.safe = true;
    return v;
}

final class Environment
{
    Loader loader;
    LexOptions lexOptions;
    Value[string] globals;
    FilterFn[string] filters;
    TestFn[string] tests;
    /// Template names whose extension turns autoescaping on (`select_autoescape(['html', 'xml'])`).
    string[] autoescapeExtensions = [".html", ".htm", ".xml"];

    private TemplateAst[string] cache;
    private string[string] keyOf; // name -> cache key

    this(Loader loader)
    {
        this.loader = loader;
        installBuiltins(this);
    }

    TemplateAst getTemplate(string name)
    {
        if (auto k = name in keyOf)
            if (auto t = *k in cache)
                return *t;
        string key;
        auto src = loader.load(name, key);
        if (auto t = key in cache)
        {
            keyOf[name] = key;
            return *t;
        }
        auto t = parseTemplate(src, name, lexOptions);
        cache[key] = t;
        keyOf[name] = key;
        return t;
    }

    /// Parses a template from a string (`render_template_string`).
    TemplateAst fromString(string src, string name = "<string>")
    {
        return parseTemplate(src, name, lexOptions);
    }

    void clearCache()
    {
        cache = null;
        keyOf = null;
    }

    bool autoescapeFor(string name)
    {
        foreach (e; autoescapeExtensions)
            if (name.endsWith(e))
                return true;
        return false;
    }

    /// Renders template `name` with `vars`.
    string render(string name, Value[string] vars = null)
    {
        auto t = getTemplate(name);
        return renderAst(t, vars, autoescapeFor(name));
    }

    string renderString(string src, Value[string] vars = null, bool autoescape = false)
    {
        return renderAst(fromString(src), vars, autoescape);
    }

    string renderAst(TemplateAst t, Value[string] vars, bool autoescape)
    {
        auto ctx = new Context(this, t, autoescape);
        foreach (k, v; vars)
            ctx.root.vars[k] = v;
        auto o = appender!string;
        ctx.renderTemplate(t, ctx.root, o);
        return o.data;
    }
}

/// One scope level.
final class Frame
{
    Frame parent;
    Value[string] vars;

    this(Frame parent) { this.parent = parent; }

    Value* lookup(string name)
    {
        for (auto f = this; f !is null; f = f.parent)
            if (auto p = name in f.vars)
                return p;
        return null;
    }
}

/// `loop` inside a for.
final class LoopObj : Obj
{
    size_t index0, length;
    Value[] items;
    LoopObj parent;

    override Value getAttr(string name)
    {
        switch (name)
        {
        case "index": return Value(index0 + 1);
        case "index0": return Value(index0);
        case "revindex": return Value(length - index0);
        case "revindex0": return Value(length - index0 - 1);
        case "first": return Value(index0 == 0);
        case "last": return Value(index0 + 1 == length);
        case "length": return Value(length);
        case "depth": return Value(depth);
        case "depth0": return Value(depth - 1);
        case "previtem": return index0 > 0 ? items[index0 - 1] : Value.undefined;
        case "nextitem": return index0 + 1 < length ? items[index0 + 1] : Value.undefined;
        case "cycle":
            return Value(new Func("cycle", (Value[] args, Dict kw) {
                if (args.length == 0)
                    throw new TemplateRuntimeError("no items for cycling given");
                return args[index0 % args.length];
            }));
        case "changed":
            return Value(new Func("changed", (Value[] args, Dict kw) => Value(true)));
        default: return Value.undefined;
        }
    }

    size_t depth()
    {
        size_t d = 1;
        for (auto p = parent; p !is null; p = p.parent)
            d++;
        return d;
    }

    override string typeName() const { return "LoopContext"; }
}

/// `namespace(...)`: an object whose attributes can be assigned from inside loops.
/// Jinja's `self`: gives access to the blocks of the current template (none of the pgAdmin templates define any, so
/// every attribute is undefined).
final class TemplateReference : Obj
{
    override string typeName() const { return "TemplateReference"; }
}

final class Namespace : Obj
{
    Dict attrs;
    this() { attrs = new Dict; }
    override Value getAttr(string name) { return attrs.get(name, Value.undefined); }
    override string typeName() const { return "Namespace"; }
}

/// An imported template (`{% import 'x' as y %}`): its macros and top-level variables.
final class TemplateModule : Obj
{
    string name;
    Value[string] exports;
    override Value getAttr(string n)
    {
        if (auto p = n in exports)
            return *p;
        return Value.undefined;
    }

    override string typeName() const { return "TemplateModule"; }
}

private final class BreakLoop : Exception
{
    this() { super("break"); }
}

/// State of one render.
final class Context
{
    Environment env;
    Frame root;
    bool autoescape;
    TemplateAst current;
    /// Block overrides for template inheritance: name -> stack (child first).
    Block[][string] blockStack;
    private LoopObj currentLoop;

    this(Environment env, TemplateAst t, bool autoescape)
    {
        this.env = env;
        this.current = t;
        this.autoescape = autoescape;
        root = new Frame(null);
    }

    // ------------------------------------------------------------ templates

    void renderTemplate(TemplateAst t, Frame frame, ref Appender!string o)
    {
        auto saved = current;
        current = t;
        scope (exit)
            current = saved;
        if (!t.hasExtends)
        {
            foreach (name, b; t.blocks)
                if (name !in blockStack)
                    blockStack[name] = [b];
            exec(t.body_, frame, o);
            return;
        }
        // Child template: register its blocks, run top-level non-output statements, then render the parent.
        foreach (name, b; t.blocks)
            blockStack[name] ~= b;
        Extends ext;
        foreach (s; t.body_)
        {
            if (auto e = cast(Extends) s)
            {
                ext = e;
                continue;
            }
            if (cast(Output) s || cast(Block) s)
                continue;
            auto junk = appender!string;
            exec([s], frame, junk);
        }
        auto parentName = eval(ext.template_, frame).toString;
        auto parent = env.getTemplate(parentName);
        renderTemplate(parent, frame, o);
    }

    // ------------------------------------------------------------ statements

    void exec(Stmt[] body_, Frame frame, ref Appender!string o)
    {
        foreach (s; body_)
            execOne(s, frame, o);
    }

    void execOne(Stmt s, Frame frame, ref Appender!string o)
    {
        try
            execImpl(s, frame, o);
        catch (TemplateRuntimeError e)
            throw e;
        catch (TemplateNotFound e)
            throw e;
        catch (TemplateSyntaxError e)
            throw e;
        catch (BreakLoop e)
            throw e;
        catch (Exception e)
        {
            auto te = new TemplateRuntimeError(e.msg);
            te.location = (current ? current.name : "?") ~ ":" ~ to!string(s.line);
            throw te;
        }
    }

    void write(ref Appender!string o, Value v)
    {
        if (v.isUndefined)
            return;
        if (autoescape && !v.safe)
            o.put(htmlEscape(v.toString));
        else
            o.put(v.toString);
    }

    void execImpl(Stmt s, Frame frame, ref Appender!string o)
    {
        if (auto x = cast(Output) s)
        {
            if (x.expr is null)
                o.put(x.text);
            else
                write(o, eval(x.expr, frame));
            return;
        }
        if (auto x = cast(If) s)
        {
            foreach (i, t; x.tests)
                if (eval(t, frame).truthy)
                {
                    exec(x.bodies[i], frame, o);
                    return;
                }
            exec(x.else_, frame, o);
            return;
        }
        if (auto x = cast(For) s)
            return execFor(x, frame, o);
        if (auto x = cast(Assign) s)
        {
            assign(x.target, eval(x.value, frame), frame);
            return;
        }
        if (auto x = cast(AssignBlock) s)
        {
            auto buf = appender!string;
            exec(x.body_, frame, buf);
            Value v = autoescape ? markSafe(buf.data) : Value(buf.data);
            if (x.filter !is null)
                v = applyFilterChain(x.filter, v, frame);
            assign(x.target, v, frame);
            return;
        }
        if (auto x = cast(MacroDef) s)
        {
            frame.vars[x.name] = makeMacro(x.name, x.params, x.defaults, x.body_, frame);
            return;
        }
        if (auto x = cast(CallBlock) s)
        {
            auto callerFn = makeMacro("caller", x.params, x.defaults, x.body_, frame);
            auto fnv = eval(x.call.fn, frame);
            Value[] args;
            foreach (a; x.call.args)
                args ~= eval(a, frame);
            auto kw = new Dict;
            foreach (i, n; x.call.kwNames)
                kw[n] = eval(x.call.kwValues[i], frame);
            kw["caller"] = callerFn;
            write(o, callValue(fnv, args, kw));
            return;
        }
        if (auto x = cast(Import) s)
        {
            frame.vars[x.alias_] = Value(importModule(eval(x.template_, frame).toString, x.withContext ? frame : null));
            return;
        }
        if (auto x = cast(FromImport) s)
        {
            auto m = importModule(eval(x.template_, frame).toString, x.withContext ? frame : null);
            foreach (i, n; x.names)
            {
                if (auto p = n in m.exports)
                    frame.vars[x.aliases[i]] = *p;
                else
                    throw new TemplateRuntimeError("the template '" ~ m.name ~ "' does not export '" ~ n ~ "'");
            }
            return;
        }
        if (auto x = cast(Include) s)
        {
            auto names = eval(x.template_, frame);
            Value[] candidates = names.isList ? names.list.items : [names];
            foreach (c; candidates)
            {
                TemplateAst t;
                try
                    t = env.getTemplate(c.toString);
                catch (TemplateNotFound)
                    continue;
                auto f = x.withContext ? new Frame(frame) : new Frame(globalsFrame());
                renderTemplate(t, f, o);
                return;
            }
            if (!x.ignoreMissing)
                throw new TemplateNotFound(names.toString);
            return;
        }
        if (cast(Extends) s)
            return; // handled by renderTemplate
        if (auto x = cast(Block) s)
        {
            renderBlock(x.name, 0, frame, o);
            return;
        }
        if (auto x = cast(With) s)
        {
            auto f = new Frame(frame);
            Value[] vals;
            foreach (v; x.values)
                vals ~= eval(v, frame);
            foreach (i, t; x.targets)
                assign(t, vals[i], f);
            exec(x.body_, f, o);
            return;
        }
        if (auto x = cast(FilterBlock) s)
        {
            auto buf = appender!string;
            exec(x.body_, frame, buf);
            write(o, applyFilterChain(x.filter, Value(buf.data), frame));
            return;
        }
        if (auto x = cast(ExprStmt) s)
        {
            eval(x.expr, frame);
            return;
        }
        if (auto x = cast(AutoEscape) s)
        {
            auto saved = autoescape;
            autoescape = eval(x.enabled, frame).truthy;
            scope (exit)
                autoescape = saved;
            exec(x.body_, frame, o);
            return;
        }
        throw new TemplateRuntimeError("unsupported statement");
    }

    void renderBlock(string name, size_t level, Frame frame, ref Appender!string o)
    {
        auto stack = name in blockStack;
        if (stack is null || level >= (*stack).length)
            return;
        auto b = (*stack)[level];
        auto f = new Frame(frame);
        f.vars["super"] = Value(new Func("super", (Value[] a, Dict k) {
            auto buf = appender!string;
            renderBlock(name, level + 1, frame, buf);
            return markSafe(buf.data);
        }));
        exec(b.body_, f, o);
    }

    Frame globalsFrame()
    {
        auto f = new Frame(null);
        return f;
    }

    TemplateModule importModule(string name, Frame withContext)
    {
        auto t = env.getTemplate(name);
        auto f = new Frame(withContext);
        auto junk = appender!string;
        auto saved = current;
        current = t;
        scope (exit)
            current = saved;
        exec(t.body_, f, junk);
        auto m = new TemplateModule;
        m.name = name;
        foreach (k, v; f.vars)
            if (!k.startsWith("_"))
                m.exports[k] = v;
        return m;
    }

    Value makeMacro(string name, string[] params, Expr[] defaults, Stmt[] body_, Frame defFrame)
    {
        auto defTemplate = current;
        return Value(new Func(name, (Value[] args, Dict kw) {
            auto f = new Frame(defFrame);
            immutable firstDefault = params.length - defaults.length;
            Value[] extra;
            foreach (i, p; params)
            {
                if (i < args.length)
                    f.vars[p] = args[i];
                else if (kw !is null && kw.has(p))
                    f.vars[p] = kw[p];
                else if (i >= firstDefault)
                    f.vars[p] = eval(defaults[i - firstDefault], f);
                else
                    f.vars[p] = Value.undefined;
            }
            if (args.length > params.length)
                extra = args[params.length .. $];
            f.vars["varargs"] = Value(new List(extra));
            auto rest = new Dict;
            if (kw !is null)
                foreach (k, v; kw)
                    if (!params.canFind(k) && k != "caller")
                        rest[k] = v;
            f.vars["kwargs"] = Value(rest);
            if (kw !is null && kw.has("caller"))
                f.vars["caller"] = kw["caller"];
            auto buf = appender!string;
            auto saved = current;
            current = defTemplate;
            scope (exit)
                current = saved;
            exec(body_, f, buf);
            return autoescape ? markSafe(buf.data) : Value(buf.data);
        }));
    }

    void execFor(For x, Frame frame, ref Appender!string o)
    {
        auto seq = eval(x.iter, frame);
        Value[] items;
        if (seq.isDict)
        {
            // iterating a dict gives its keys
            foreach (k; seq.dict.keys)
                items ~= Value(k);
        }
        else if (seq.isObject)
        {
            if (auto it = cast(Iterable) seq.obj)
                items = it.iterate();
            else
                throw new TemplateRuntimeError("'" ~ seq.typeName ~ "' object is not iterable");
        }
        else
            items = seq.iterItems();

        auto f = new Frame(frame);
        if (x.filter !is null)
        {
            Value[] kept;
            foreach (it; items)
            {
                assign(x.target, it, f);
                if (eval(x.filter, f).truthy)
                    kept ~= it;
            }
            items = kept;
        }
        if (items.length == 0)
        {
            exec(x.else_, frame, o);
            return;
        }
        auto loop = new LoopObj;
        loop.items = items;
        loop.length = items.length;
        loop.parent = currentLoop;
        auto savedLoop = currentLoop;
        currentLoop = loop;
        scope (exit)
            currentLoop = savedLoop;
        f.vars["loop"] = Value(loop);
        foreach (i, it; items)
        {
            loop.index0 = i;
            assign(x.target, it, f);
            exec(x.body_, f, o);
        }
    }

    void assign(Expr target, Value v, Frame frame)
    {
        if (auto n = cast(NameExpr) target)
        {
            frame.vars[n.name] = v;
            return;
        }
        if (auto l = cast(ListExpr) target)
        {
            auto items = v.iterItems();
            if (items.length != l.items.length)
                throw new TemplateRuntimeError("cannot unpack " ~ to!string(items.length) ~ " values into "
                        ~ to!string(l.items.length));
            foreach (i, t; l.items)
                assign(t, items[i], frame);
            return;
        }
        if (auto g = cast(GetAttr) target)
        {
            auto obj = eval(g.obj, frame);
            if (obj.isObject)
                if (auto ns = cast(Namespace) obj.obj)
                {
                    ns.attrs[g.attr] = v;
                    return;
                }
            throw new TemplateRuntimeError("cannot assign attribute on non-namespace object");
        }
        throw new TemplateRuntimeError("invalid assignment target");
    }

    // ------------------------------------------------------------ expressions

    Value lookupName(string name, Frame frame)
    {
        if (auto p = frame.lookup(name))
            return *p;
        if (auto p = name in env.globals)
            return *p;
        if (name == "self")
            return Value(new TemplateReference);
        return Value.undefined("'" ~ name ~ "' is undefined");
    }

    Value eval(Expr e, Frame frame)
    {
        if (auto c = cast(Const) e)
            return c.value;
        if (auto n = cast(NameExpr) e)
            return lookupName(n.name, frame);
        if (auto g = cast(GetAttr) e)
            return getAttr(eval(g.obj, frame), g.attr);
        if (auto g = cast(GetItem) e)
            return getItem(eval(g.obj, frame), eval(g.key, frame));
        if (auto f = cast(FilterExpr) e)
            return applyFilter(f, f.value is null ? Value.undefined : eval(f.value, frame), frame);
        if (auto t = cast(TestExpr) e)
            return Value(applyTest(t, frame));
        if (auto b = cast(BinOp) e)
            return evalBin(b, frame);
        if (auto c = cast(CompareExpr) e)
        {
            auto left = eval(c.first, frame);
            foreach (i, op; c.ops)
            {
                auto right = eval(c.rest[i], frame);
                if (!compare(op, left, right))
                    return Value(false);
                left = right;
            }
            return Value(true);
        }
        if (auto u = cast(UnaryOp) e)
        {
            auto v = eval(u.operand, frame);
            switch (u.op)
            {
            case "not": return Value(!v.truthy);
            case "-":
                if (v.isInt || v.isBool)
                    return Value(-v.integer);
                return Value(-v.floating);
            default: return v;
            }
        }
        if (auto c = cast(CondExpr) e)
        {
            if (eval(c.test, frame).truthy)
                return eval(c.then, frame);
            return c.else_ is null ? Value.undefined : eval(c.else_, frame);
        }
        if (auto l = cast(ListExpr) e)
        {
            auto r = new List;
            r.tuple = l.tuple;
            foreach (it; l.items)
                r.items ~= eval(it, frame);
            return Value(r);
        }
        if (auto d = cast(DictExpr) e)
        {
            auto r = new Dict;
            foreach (i, k; d.keys)
                r[eval(k, frame).toString] = eval(d.values[i], frame);
            return Value(r);
        }
        if (auto s = cast(SliceExpr) e)
            return slice(eval(s.obj, frame), s.start ? eval(s.start, frame) : Value(null),
                    s.stop ? eval(s.stop, frame) : Value(null), s.step ? eval(s.step, frame) : Value(null));
        if (auto c = cast(CallExpr) e)
        {
            auto fnv = eval(c.fn, frame);
            Value[] args;
            foreach (a; c.args)
                args ~= eval(a, frame);
            if (c.dynArgs !is null)
                args ~= eval(c.dynArgs, frame).iterItems();
            Dict kw;
            if (c.kwNames.length || c.dynKwargs !is null)
            {
                kw = new Dict;
                foreach (i, n; c.kwNames)
                    kw[n] = eval(c.kwValues[i], frame);
                if (c.dynKwargs !is null)
                {
                    auto dk = eval(c.dynKwargs, frame);
                    if (dk.isDict)
                        kw.update(dk.dict);
                }
            }
            return callValue(fnv, args, kw);
        }
        throw new TemplateRuntimeError("unsupported expression");
    }

    Value callValue(Value fnv, Value[] args, Dict kw)
    {
        if (fnv.isFunc)
            return fnv.func.call(args, kw);
        if (fnv.isUndefined)
            failUndefined(fnv);
        throw new TemplateRuntimeError("'" ~ fnv.typeName ~ "' object is not callable");
    }

    Value evalBin(BinOp b, Frame frame)
    {
        if (b.op == "and")
        {
            auto l = eval(b.left, frame);
            return l.truthy ? eval(b.right, frame) : l;
        }
        if (b.op == "or")
        {
            auto l = eval(b.left, frame);
            return l.truthy ? l : eval(b.right, frame);
        }
        auto l = eval(b.left, frame);
        auto r = eval(b.right, frame);
        return arith(b.op, l, r);
    }

    Value arith(string op, Value l, Value r)
    {
        switch (op)
        {
        case "~":
            auto s = l.toString ~ r.toString;
            return (l.safe || r.safe) && autoescape ? markSafe(s) : Value(s);
        case "+":
            if (l.isString && r.isString)
                return Value(l.str ~ r.str);
            if (l.isList && r.isList)
                return Value(l.list.items ~ r.list.items);
            if (l.isUndefined || r.isUndefined)
                throw new TemplateRuntimeError("unsupported operand for +: undefined");
            return numOp(op, l, r);
        case "*":
            if (l.isString && (r.isInt || r.isBool))
            {
                string s;
                foreach (_; 0 .. r.integer)
                    s ~= l.str;
                return Value(s);
            }
            if (l.isList && r.isInt)
            {
                Value[] items;
                foreach (_; 0 .. r.integer)
                    items ~= l.list.items;
                return Value(items);
            }
            return numOp(op, l, r);
        case "%":
            if (l.isString)
                return Value(pyPercentFormat(l.str, r));
            return numOp(op, l, r);
        default:
            return numOp(op, l, r);
        }
    }

    static Value numOp(string op, Value l, Value r)
    {
        if (!l.isNumber || !r.isNumber)
            throw new TemplateRuntimeError("unsupported operand type(s) for " ~ op ~ ": '" ~ l.typeName ~ "' and '"
                    ~ r.typeName ~ "'");
        bool ints = !l.isFloat && !r.isFloat;
        switch (op)
        {
        case "+": return ints ? Value(l.integer + r.integer) : Value(l.floating + r.floating);
        case "-": return ints ? Value(l.integer - r.integer) : Value(l.floating - r.floating);
        case "*": return ints ? Value(l.integer * r.integer) : Value(l.floating * r.floating);
        case "/":
            if (r.floating == 0)
                throw new TemplateRuntimeError("division by zero");
            return Value(l.floating / r.floating);
        case "//":
            if (r.floating == 0)
                throw new TemplateRuntimeError("integer division or modulo by zero");
            if (ints)
            {
                long a = l.integer, c = r.integer;
                long q = a / c;
                if ((a % c != 0) && ((a < 0) != (c < 0)))
                    q--;
                return Value(q);
            }
            import std.math : floor;
            return Value(floor(l.floating / r.floating));
        case "%":
            if (ints)
            {
                long a = l.integer, c = r.integer;
                if (c == 0)
                    throw new TemplateRuntimeError("integer division or modulo by zero");
                long m = a % c;
                if (m != 0 && ((m < 0) != (c < 0)))
                    m += c;
                return Value(m);
            }
            import std.math : fmod;
            return Value(fmod(l.floating, r.floating));
        case "**":
            import std.math : pow;
            if (ints && r.integer >= 0)
                return Value(pow(l.integer, cast(ulong) r.integer));
            return Value(pow(l.floating, r.floating));
        default:
            throw new TemplateRuntimeError("unknown operator " ~ op);
        }
    }

    static bool compare(string op, Value l, Value r)
    {
        switch (op)
        {
        case "==": return l == r;
        case "!=": return l != r;
        case "<": return l.opCmp(r) < 0;
        case "<=": return l.opCmp(r) <= 0;
        case ">": return l.opCmp(r) > 0;
        case ">=": return l.opCmp(r) >= 0;
        case "in": return containsValue(r, l);
        case "notin": return !containsValue(r, l);
        default: throw new TemplateRuntimeError("unknown comparison " ~ op);
        }
    }

    static bool containsValue(Value container, Value item)
    {
        if (container.isUndefined)
            return false;
        if (container.isObject)
            if (auto it = cast(Iterable) container.obj)
            {
                foreach (v; it.iterate())
                    if (v == item)
                        return true;
                return false;
            }
        return container.contains(item);
    }

    static Value noAttr(Value obj, string name)
    {
        return Value.undefined("'" ~ objectTypeRepr(obj) ~ "' has no attribute '" ~ name ~ "'");
    }

    static Value noItem(Value obj, Value key)
    {
        if (key.isString)
            return noAttr(obj, key.str);
        return Value.undefined("'" ~ objectTypeRepr(obj) ~ "' has no element " ~ key.repr);
    }

    Value getAttr(Value obj, string name)
    {
        if (obj.isUndefined)
            failUndefined(obj);
        // methods of builtin types win over items, like Python's getattr
        if (auto m = builtinMethod(obj, name))
            return Value(m);
        switch (obj.type)
        {
        case VType.dict:
            if (auto p = obj.dict.find(name))
                return *p;
            return noAttr(obj, name);
        case VType.object:
            auto r = obj.obj.getAttr(name);
            if (r.isUndefined && r.undefinedHint.length == 0)
                return noAttr(obj, name);
            return r;
        default:
            return noAttr(obj, name);
        }
    }

    Value getItem(Value obj, Value key)
    {
        if (obj.isUndefined)
            failUndefined(obj);
        switch (obj.type)
        {
        case VType.dict:
            if (auto p = obj.dict.find(key.isString ? key.str : key.toString))
                return *p;
            if (key.isString)
                if (auto m = builtinMethod(obj, key.str))
                    return Value(m);
            return noItem(obj, key);
        case VType.list:
            if (key.isInt || key.isBool)
            {
                long i = key.integer;
                auto items = obj.list.items;
                if (i < 0)
                    i += items.length;
                if (i < 0 || i >= items.length)
                    return noItem(obj, key);
                return items[cast(size_t) i];
            }
            if (key.isString)
                if (auto m = builtinMethod(obj, key.str))
                    return Value(m);
            return noItem(obj, key);
        case VType.str:
            if (key.isInt)
            {
                import std.utf : toUTF32;
                auto d = toUTF32(obj.str);
                long i = key.integer;
                if (i < 0)
                    i += d.length;
                if (i < 0 || i >= d.length)
                    return noItem(obj, key);
                return Value(to!string(d[cast(size_t) i]));
            }
            if (key.isString)
                if (auto m = builtinMethod(obj, key.str))
                    return Value(m);
            return noItem(obj, key);
        case VType.object:
            if (key.isString)
            {
                auto r = obj.obj.getAttr(key.str);
                if (r.isUndefined && r.undefinedHint.length == 0)
                    return noItem(obj, key);
                return r;
            }
            return noItem(obj, key);
        default:
            return noItem(obj, key);
        }
    }

    static Value slice(Value obj, Value start, Value stop, Value step)
    {
        long n;
        dstring ds;
        Value[] items;
        if (obj.isString)
        {
            import std.utf : toUTF32;
            ds = toUTF32(obj.str);
            n = ds.length;
        }
        else if (obj.isList)
        {
            items = obj.list.items;
            n = items.length;
        }
        else if (obj.isUndefined)
            return Value.undefined;
        else
            throw new TemplateRuntimeError("'" ~ obj.typeName ~ "' object is not subscriptable");
        long st = step.isNone ? 1 : step.integer;
        if (st == 0)
            throw new TemplateRuntimeError("slice step cannot be zero");
        long a, b;
        if (st > 0)
        {
            a = start.isNone ? 0 : start.integer;
            b = stop.isNone ? n : stop.integer;
            if (a < 0) a += n;
            if (b < 0) b += n;
            if (a < 0) a = 0;
            if (b > n) b = n;
        }
        else
        {
            a = start.isNone ? n - 1 : start.integer;
            b = stop.isNone ? -n - 1 : stop.integer;
            if (a < 0) a += n;
            if (b < 0) b += n;
            if (a >= n) a = n - 1;
        }
        long[] idx;
        if (st > 0)
            for (long i = a; i < b; i += st)
                idx ~= i;
        else
            for (long i = a; i > b && i >= 0; i += st)
                idx ~= i;
        if (obj.isString)
        {
            dstring r;
            foreach (i; idx)
                r ~= ds[cast(size_t) i];
            return Value(to!string(r));
        }
        Value[] r;
        foreach (i; idx)
            r ~= items[cast(size_t) i];
        return Value(r);
    }

    Value applyFilter(FilterExpr f, Value v, Frame frame)
    {
        auto fn = f.name in env.filters;
        if (fn is null)
            throw new TemplateRuntimeError("no filter named '" ~ f.name ~ "'");
        Value[] args;
        foreach (a; f.args)
            args ~= eval(a, frame);
        Dict kw;
        if (f.kwNames.length)
        {
            kw = new Dict;
            foreach (i, n; f.kwNames)
                kw[n] = eval(f.kwValues[i], frame);
        }
        return (*fn)(this, v, args, kw);
    }

    /// Applies a chain parsed for `{% filter %}` / `{% set x | f %}` to `v` (the innermost value is replaced).
    Value applyFilterChain(FilterExpr f, Value v, Frame frame)
    {
        FilterExpr[] chain;
        for (Expr e = f; e !is null;)
        {
            auto fe = cast(FilterExpr) e;
            if (fe is null)
                break;
            chain = fe ~ chain;
            e = fe.value;
        }
        foreach (fe; chain)
            v = applyFilter(fe, v, frame);
        return v;
    }

    bool applyTest(TestExpr t, Frame frame)
    {
        auto fn = t.name in env.tests;
        if (fn is null)
            throw new TemplateRuntimeError("no test named '" ~ t.name ~ "'");
        auto v = eval(t.value, frame);
        Value[] args;
        foreach (a; t.args)
            args ~= eval(a, frame);
        auto r = (*fn)(v, args);
        return t.negated ? !r : r;
    }
}

/// An object that can be iterated in a `for` loop.
interface Iterable
{
    Value[] iterate();
}

// ------------------------------------------------------------ helpers

string htmlEscape(string s)
{
    auto a = appender!string;
    foreach (c; s)
    {
        switch (c)
        {
        case '&': a.put("&amp;"); break;
        case '<': a.put("&lt;"); break;
        case '>': a.put("&gt;"); break;
        case '"': a.put("&#34;"); break;
        case '\'': a.put("&#39;"); break;
        default: a.put(c);
        }
    }
    return a.data;
}

/// Python's `'%s ... %d' % args`.
string pyPercentFormat(string fmt, Value args)
{
    Value[] list = args.isList && args.list.tuple ? args.list.items : [args];
    Dict named = args.isDict ? args.dict : null;
    auto a = appender!string;
    size_t ai;
    size_t i;
    while (i < fmt.length)
    {
        char c = fmt[i];
        if (c != '%')
        {
            a.put(c);
            i++;
            continue;
        }
        i++;
        if (i >= fmt.length)
            break;
        if (fmt[i] == '%')
        {
            a.put('%');
            i++;
            continue;
        }
        Value arg;
        if (fmt[i] == '(')
        {
            auto e = fmt.indexOf(')', i);
            auto key = fmt[i + 1 .. e];
            i = e + 1;
            arg = named !is null ? named.get(key) : Value(null);
        }
        else
            arg = ai < list.length ? list[ai++] : Value(null);
        // flags/width (ignored except for precision on floats)
        size_t st = i;
        while (i < fmt.length && "-+ #0123456789.".canFind(fmt[i]))
            i++;
        auto spec = fmt[st .. i];
        if (i >= fmt.length)
            break;
        char conv = fmt[i++];
        switch (conv)
        {
        case 's': a.put(arg.toString); break;
        case 'r': a.put(arg.repr); break;
        case 'd', 'i': a.put(to!string(arg.integer)); break;
        case 'f':
            import std.format : format;
            a.put(format("%" ~ (spec.length ? spec : ".6") ~ "f", arg.floating));
            break;
        default: a.put(arg.toString);
        }
    }
    return a.data;
}

/// Python's `str.format`, positional `{}`/`{0}` and named `{name}` fields.
string pyStrFormat(string fmt, Value[] args, Dict kw)
{
    auto a = appender!string;
    size_t auto_;
    size_t i;
    while (i < fmt.length)
    {
        char c = fmt[i];
        if (c == '{')
        {
            if (i + 1 < fmt.length && fmt[i + 1] == '{')
            {
                a.put('{');
                i += 2;
                continue;
            }
            auto e = fmt.indexOf('}', i);
            if (e < 0)
                throw valueError("Single '{' encountered in format string");
            auto field = fmt[i + 1 .. e];
            auto colon = field.indexOf(':');
            if (colon >= 0)
                field = field[0 .. colon];
            Value v;
            if (field.length == 0)
                v = auto_ < args.length ? args[auto_++] : Value(null);
            else if (field[0] >= '0' && field[0] <= '9')
            {
                auto k = to!size_t(field);
                v = k < args.length ? args[k] : Value(null);
            }
            else
                v = kw !is null ? kw.get(field) : Value(null);
            a.put(v.toString);
            i = e + 1;
            continue;
        }
        if (c == '}' && i + 1 < fmt.length && fmt[i + 1] == '}')
        {
            a.put('}');
            i += 2;
            continue;
        }
        a.put(c);
        i++;
    }
    return a.data;
}

private string pyStrip(string s, Value[] args, int which)
{
    if (args.length == 0 || args[0].isNone)
    {
        if (which == 0) return s.strip;
        if (which == 1) return s.stripLeft;
        return s.stripRight;
    }
    auto chars = args[0].toString;
    size_t a = 0, b = s.length;
    if (which != 2)
        while (a < b && chars.canFind(s[a]))
            a++;
    if (which != 1)
        while (b > a && chars.canFind(s[b - 1]))
            b--;
    return s[a .. b];
}

/// Python `str.split(sep=None, maxsplit=-1)`.
Value[] pySplit(string s, Value sepv, long maxsplit = -1)
{
    Value[] r;
    if (sepv.isNone || sepv.isUndefined)
    {
        size_t i;
        long n;
        while (i < s.length)
        {
            while (i < s.length && isWhite(s[i]))
                i++;
            if (i >= s.length)
                break;
            if (maxsplit >= 0 && n >= maxsplit)
            {
                auto rest = s[i .. $].stripRight;
                r ~= Value(rest);
                return r;
            }
            size_t j = i;
            while (j < s.length && !isWhite(s[j]))
                j++;
            r ~= Value(s[i .. j]);
            n++;
            i = j;
        }
        return r;
    }
    auto sep = sepv.toString;
    if (sep.length == 0)
        throw valueError("empty separator");
    long n;
    size_t i;
    for (;;)
    {
        if (maxsplit >= 0 && n >= maxsplit)
            break;
        auto k = s[i .. $].indexOf(sep);
        if (k < 0)
            break;
        r ~= Value(s[i .. i + k]);
        i += k + sep.length;
        n++;
    }
    r ~= Value(s[i .. $]);
    return r;
}

/// Bound methods of builtin types (`'a,b'.split(',')`, `d.items()`, `l.append(x)`).
Func builtinMethod(Value obj, string name)
{
    if (obj.isString)
    {
        auto s = obj.str;
        switch (name)
        {
        case "startswith":
            return new Func(name, (Value[] a, Dict k) {
                if (a.length && a[0].isList)
                {
                    foreach (p; a[0].list.items)
                        if (s.startsWith(p.toString))
                            return Value(true);
                    return Value(false);
                }
                return Value(a.length && s.startsWith(a[0].toString));
            });
        case "endswith":
            return new Func(name, (Value[] a, Dict k) {
                if (a.length && a[0].isList)
                {
                    foreach (p; a[0].list.items)
                        if (s.endsWith(p.toString))
                            return Value(true);
                    return Value(false);
                }
                return Value(a.length && s.endsWith(a[0].toString));
            });
        case "split":
            return new Func(name, (Value[] a, Dict k) {
                Value sep = a.length ? a[0] : (k !is null ? k.get("sep") : Value(null));
                long maxs = a.length > 1 ? a[1].integer : (k !is null && k.has("maxsplit") ? k["maxsplit"].integer : -1);
                return Value(pySplit(s, sep, maxs));
            });
        case "rsplit":
            return new Func(name, (Value[] a, Dict k) {
                Value sep = a.length ? a[0] : Value(null);
                long maxs = a.length > 1 ? a[1].integer : -1;
                if (maxs < 0 || sep.isNone)
                    return Value(pySplit(s, sep, maxs));
                auto sp = sep.toString;
                Value[] r;
                string rest = s;
                foreach (_; 0 .. maxs)
                {
                    import std.string : lastIndexOf;
                    auto p = rest.lastIndexOf(sp);
                    if (p < 0)
                        break;
                    r = Value(rest[p + sp.length .. $]) ~ r;
                    rest = rest[0 .. p];
                }
                return Value(Value(rest) ~ r);
            });
        case "splitlines":
            return new Func(name, (Value[] a, Dict k) {
                import std.string : splitLines;
                Value[] r;
                foreach (l; s.splitLines)
                    r ~= Value(l);
                return Value(r);
            });
        case "strip": return new Func(name, (Value[] a, Dict k) => Value(pyStrip(s, a, 0)));
        case "lstrip": return new Func(name, (Value[] a, Dict k) => Value(pyStrip(s, a, 1)));
        case "rstrip": return new Func(name, (Value[] a, Dict k) => Value(pyStrip(s, a, 2)));
        case "upper": return new Func(name, (Value[] a, Dict k) => Value(s.toUpper));
        case "lower": return new Func(name, (Value[] a, Dict k) => Value(s.toLower));
        case "title": return new Func(name, (Value[] a, Dict k) => Value(pyTitle(s)));
        case "capitalize": return new Func(name, (Value[] a, Dict k) => Value(pyCapitalize(s)));
        case "replace":
            return new Func(name, (Value[] a, Dict k) {
                if (a.length < 2)
                    throw typeError("replace expected 2 arguments");
                auto from = a[0].toString;
                if (from.length == 0)
                    return Value(s);
                if (a.length > 2)
                {
                    long cnt = a[2].integer;
                    string r = s;
                    string outp;
                    while (cnt-- > 0)
                    {
                        auto p = r.indexOf(from);
                        if (p < 0)
                            break;
                        outp ~= r[0 .. p] ~ a[1].toString;
                        r = r[p + from.length .. $];
                    }
                    return Value(outp ~ r);
                }
                return Value(s.replace(from, a[1].toString));
            });
        case "find":
            return new Func(name, (Value[] a, Dict k) => Value(a.length ? cast(long) s.indexOf(a[0].toString) : -1L));
        case "rfind":
            return new Func(name, (Value[] a, Dict k) {
                import std.string : lastIndexOf;
                return Value(a.length ? cast(long) s.lastIndexOf(a[0].toString) : -1L);
            });
        case "index":
            return new Func(name, (Value[] a, Dict k) {
                auto p = s.indexOf(a[0].toString);
                if (p < 0)
                    throw valueError("substring not found");
                return Value(cast(long) p);
            });
        case "count":
            return new Func(name, (Value[] a, Dict k) {
                import std.algorithm : count;
                auto sub = a[0].toString;
                return Value(sub.length ? cast(long) s.count(sub) : cast(long) utf8Length(s) + 1);
            });
        case "join":
            return new Func(name, (Value[] a, Dict k) {
                string[] parts;
                foreach (v; a[0].iterItems())
                    parts ~= v.toString;
                return Value(parts.join(s));
            });
        case "format":
            return new Func(name, (Value[] a, Dict k) => Value(pyStrFormat(s, a, k)));
        case "isdigit", "isnumeric", "isdecimal":
            return new Func(name, (Value[] a, Dict k) {
                if (s.length == 0)
                    return Value(false);
                foreach (c; s)
                    if (c < '0' || c > '9')
                        return Value(false);
                return Value(true);
            });
        case "isalpha":
            return new Func(name, (Value[] a, Dict k) {
                import std.uni : isAlpha;
                if (s.length == 0)
                    return Value(false);
                foreach (dchar c; s)
                    if (!isAlpha(c))
                        return Value(false);
                return Value(true);
            });
        case "isupper":
            return new Func(name, (Value[] a, Dict k) => Value(s.length && s == s.toUpper && s != s.toLower));
        case "islower":
            return new Func(name, (Value[] a, Dict k) => Value(s.length && s == s.toLower && s != s.toUpper));
        case "zfill":
            return new Func(name, (Value[] a, Dict k) {
                auto w = a[0].integer;
                string r = s;
                while (cast(long) r.length < w)
                    r = "0" ~ r;
                return Value(r);
            });
        case "encode":
            return new Func(name, (Value[] a, Dict k) => Value(s));
        case "decode":
            return new Func(name, (Value[] a, Dict k) => Value(s));
        default:
            return null;
        }
    }
    if (obj.isDict)
    {
        auto d = obj.dict;
        switch (name)
        {
        case "items":
            return new Func(name, (Value[] a, Dict k) {
                Value[] r;
                foreach (key, v; d)
                    r ~= Value.tuple(Value(key), v);
                return Value(r);
            });
        case "keys":
            return new Func(name, (Value[] a, Dict k) {
                Value[] r;
                foreach (key; d.keys)
                    r ~= Value(key);
                return Value(r);
            });
        case "values":
            return new Func(name, (Value[] a, Dict k) => Value(d.values));
        case "get":
            return new Func(name, (Value[] a, Dict k) {
                if (a.length == 0)
                    throw typeError("get expected at least 1 argument");
                auto def = a.length > 1 ? a[1] : Value(null);
                return d.get(a[0].toString, def);
            });
        case "update":
            return new Func(name, (Value[] a, Dict k) {
                if (a.length && a[0].isDict)
                    d.update(a[0].dict);
                if (k !is null)
                    d.update(k);
                return Value(null);
            });
        case "pop":
            return new Func(name, (Value[] a, Dict k) {
                auto key = a[0].toString;
                if (!d.has(key) && a.length < 2)
                    throw keyError(key);
                return d.pop(key, a.length > 1 ? a[1] : Value(null));
            });
        case "copy":
            return new Func(name, (Value[] a, Dict k) => Value(d.copy()));
        case "setdefault":
            return new Func(name, (Value[] a, Dict k) {
                auto key = a[0].toString;
                if (auto p = d.find(key))
                    return *p;
                auto v = a.length > 1 ? a[1] : Value(null);
                d[key] = v;
                return v;
            });
        case "clear":
            return new Func(name, (Value[] a, Dict k) { d.clear(); return Value(null); });
        default:
            return null;
        }
    }
    if (obj.isList)
    {
        auto l = obj.list;
        switch (name)
        {
        case "append":
            return new Func(name, (Value[] a, Dict k) { l.items ~= a[0]; return Value(null); });
        case "extend":
            return new Func(name, (Value[] a, Dict k) { l.items ~= a[0].iterItems(); return Value(null); });
        case "insert":
            return new Func(name, (Value[] a, Dict k) {
                long i = a[0].integer;
                if (i < 0)
                    i += l.items.length;
                if (i < 0)
                    i = 0;
                if (i > l.items.length)
                    i = l.items.length;
                l.items = l.items[0 .. cast(size_t) i] ~ a[1] ~ l.items[cast(size_t) i .. $];
                return Value(null);
            });
        case "pop":
            return new Func(name, (Value[] a, Dict k) {
                if (l.items.length == 0)
                    throw new PyError("IndexError", "pop from empty list");
                long i = a.length ? a[0].integer : -1;
                if (i < 0)
                    i += l.items.length;
                auto v = l.items[cast(size_t) i];
                l.items = l.items[0 .. cast(size_t) i] ~ l.items[cast(size_t) i + 1 .. $];
                return v;
            });
        case "remove":
            return new Func(name, (Value[] a, Dict k) {
                foreach (i, v; l.items)
                    if (v == a[0])
                    {
                        l.items = l.items[0 .. i] ~ l.items[i + 1 .. $];
                        return Value(null);
                    }
                throw valueError("list.remove(x): x not in list");
            });
        case "index":
            return new Func(name, (Value[] a, Dict k) {
                foreach (i, v; l.items)
                    if (v == a[0])
                        return Value(i);
                throw valueError("value is not in list");
            });
        case "count":
            return new Func(name, (Value[] a, Dict k) {
                long n;
                foreach (v; l.items)
                    if (v == a[0])
                        n++;
                return Value(n);
            });
        case "sort":
            return new Func(name, (Value[] a, Dict k) {
                sort!((x, y) => x.opCmp(y) < 0)(l.items);
                return Value(null);
            });
        case "reverse":
            return new Func(name, (Value[] a, Dict k) {
                import std.algorithm : reverse;
                reverse(l.items);
                return Value(null);
            });
        case "copy":
            return new Func(name, (Value[] a, Dict k) => Value(l.items.dup));
        default:
            return null;
        }
    }
    return null;
}

string pyTitle(string s)
{
    import std.uni : toUpper, toLower, isAlpha;
    string r;
    bool prevAlpha;
    foreach (dchar c; s)
    {
        if (isAlpha(c))
        {
            r ~= prevAlpha ? toLower(c) : toUpper(c);
            prevAlpha = true;
        }
        else
        {
            r ~= c;
            prevAlpha = false;
        }
    }
    return r;
}

string pyCapitalize(string s)
{
    import std.uni : toUpper, toLower;
    if (s.length == 0)
        return s;
    string r;
    bool first = true;
    foreach (dchar c; s)
    {
        r ~= first ? toUpper(c) : toLower(c);
        first = false;
    }
    return r;
}

// ------------------------------------------------------------ builtins

private void installBuiltins(Environment env)
{
    import pgadmin.jinja.builtins : registerBuiltins;
    registerBuiltins(env);
}
