/// Jinja2 parser: tokens to `TemplateAst`, following Jinja2's grammar and operator precedence.
module pgadmin.jinja.parser;

import std.conv : to;
import pgadmin.core.value;
import pgadmin.jinja.ast;
import pgadmin.jinja.lexer;

TemplateAst parseTemplate(string src, string name, LexOptions opts = LexOptions.init)
{
    auto p = Parser(tokenize(src, name, opts), name);
    auto t = new TemplateAst;
    t.name = name;
    p.tmpl = t;
    t.body_ = p.subparse(null);
    return t;
}

private struct Parser
{
    Token[] toks;
    size_t pos;
    string name;
    TemplateAst tmpl;

    this(Token[] toks, string name)
    {
        this.toks = toks;
        this.name = name;
    }

    ref Token cur() return { return toks[pos]; }
    ref Token peek(size_t n = 1) return { return toks[pos + n < toks.length ? pos + n : $ - 1]; }

    noreturn fail(string msg)
    {
        throw new TemplateSyntaxError(msg, name, cur.line);
    }

    bool isOp(string o) { return cur.type == Tok.op && cur.value == o; }
    bool isName(string n) { return cur.type == Tok.name && cur.value == n; }

    bool skipOp(string o)
    {
        if (isOp(o))
        {
            pos++;
            return true;
        }
        return false;
    }

    bool skipName(string n)
    {
        if (isName(n))
        {
            pos++;
            return true;
        }
        return false;
    }

    void expectOp(string o)
    {
        if (!skipOp(o))
            fail("expected '" ~ o ~ "', got '" ~ describe(cur) ~ "'");
    }

    void expectName(string n)
    {
        if (!skipName(n))
            fail("expected '" ~ n ~ "', got '" ~ describe(cur) ~ "'");
    }

    string expectIdent()
    {
        if (cur.type != Tok.name)
            fail("expected name, got '" ~ describe(cur) ~ "'");
        return toks[pos++].value;
    }

    void expectBlockEnd()
    {
        if (cur.type != Tok.blockEnd)
            fail("expected end of statement block, got '" ~ describe(cur) ~ "'");
        pos++;
    }

    static string describe(Token t)
    {
        final switch (t.type)
        {
        case Tok.data: return "template data";
        case Tok.varBegin: return "{{";
        case Tok.varEnd: return "}}";
        case Tok.blockBegin: return "{%";
        case Tok.blockEnd: return "%}";
        case Tok.name, Tok.str, Tok.integer, Tok.floating, Tok.op: return t.value;
        case Tok.eof: return "end of template";
        }
    }

    T mk(T)() if (is(T : Node))
    {
        auto n = new T;
        n.line = cur.line;
        return n;
    }

    // ------------------------------------------------------------ statements

    /// Parses until one of `ends` is the next block keyword (it is left unconsumed, after the `{%`).
    Stmt[] subparse(string[] ends)
    {
        Stmt[] body_;
        for (;;)
        {
            final switch (cur.type)
            {
            case Tok.data:
                auto o = mk!Output;
                o.text = cur.value;
                pos++;
                body_ ~= o;
                break;
            case Tok.varBegin:
                pos++;
                auto o = mk!Output;
                o.expr = parseTuple();
                if (cur.type != Tok.varEnd)
                    fail("expected end of print statement, got '" ~ describe(cur) ~ "'");
                pos++;
                body_ ~= o;
                break;
            case Tok.blockBegin:
                pos++;
                if (cur.type == Tok.name)
                    foreach (e; ends)
                        if (cur.value == e)
                            return body_;
                if (auto s = parseStatement())
                    body_ ~= s;
                break;
            case Tok.eof:
                if (ends.length)
                    fail("unexpected end of template, expected '" ~ ends[0] ~ "'");
                return body_;
            case Tok.varEnd, Tok.blockEnd, Tok.name, Tok.str, Tok.integer, Tok.floating, Tok.op:
                fail("unexpected '" ~ describe(cur) ~ "'");
            }
        }
    }

    Stmt parseStatement()
    {
        if (cur.type != Tok.name)
            fail("tag name expected");
        auto kw = cur.value;
        switch (kw)
        {
        case "if": return parseIf();
        case "for": return parseFor();
        case "set": return parseSet();
        case "macro": return parseMacro();
        case "call": return parseCall();
        case "import": return parseImport();
        case "from": return parseFrom();
        case "include": return parseInclude();
        case "extends": return parseExtends();
        case "block": return parseBlock();
        case "with": return parseWith();
        case "filter": return parseFilterBlock();
        case "autoescape": return parseAutoEscape();
        case "do":
            pos++;
            auto s = mk!ExprStmt;
            s.expr = parseTuple();
            expectBlockEnd();
            return s;
        default:
            fail("encountered unknown tag '" ~ kw ~ "'");
        }
    }

    Stmt parseIf()
    {
        auto s = mk!If;
        pos++; // if
        for (;;)
        {
            s.tests ~= parseTuple(false, false);
            expectBlockEnd();
            s.bodies ~= subparse(["elif", "else", "endif"]);
            auto kw = toks[pos++].value;
            if (kw == "elif")
                continue;
            if (kw == "else")
            {
                expectBlockEnd();
                s.else_ = subparse(["endif"]);
                pos++;
            }
            expectBlockEnd();
            break;
        }
        return s;
    }

    Stmt parseFor()
    {
        auto s = mk!For;
        pos++;
        s.target = parseAssignTarget(["in"]);
        expectName("in");
        s.iter = parseTuple(false, false, ["recursive"]);
        if (skipName("if"))
            s.filter = parseExpression();
        s.recursive = skipName("recursive");
        expectBlockEnd();
        s.body_ = subparse(["endfor", "else"]);
        if (toks[pos++].value == "else")
        {
            expectBlockEnd();
            s.else_ = subparse(["endfor"]);
            pos++;
        }
        expectBlockEnd();
        return s;
    }

    Stmt parseSet()
    {
        auto line = cur.line;
        pos++;
        auto target = parseAssignTarget(null, true);
        if (skipOp("="))
        {
            auto s = new Assign;
            s.line = line;
            s.target = target;
            s.value = parseTuple();
            expectBlockEnd();
            return s;
        }
        auto s = new AssignBlock;
        s.line = line;
        s.target = target;
        if (isOp("|"))
            s.filter = parseFilterChain(null);
        expectBlockEnd();
        s.body_ = subparse(["endset"]);
        pos++;
        expectBlockEnd();
        return s;
    }

    void parseSignature(ref string[] params, ref Expr[] defaults)
    {
        expectOp("(");
        while (!isOp(")"))
        {
            if (params.length)
                expectOp(",");
            if (isOp(")"))
                break;
            params ~= expectIdent();
            if (skipOp("="))
                defaults ~= parseExpression();
            else if (defaults.length)
                fail("non-default argument follows default argument");
        }
        expectOp(")");
    }

    Stmt parseMacro()
    {
        auto s = mk!MacroDef;
        pos++;
        s.name = expectIdent();
        parseSignature(s.params, s.defaults);
        expectBlockEnd();
        s.body_ = subparse(["endmacro"]);
        pos++;
        if (cur.type == Tok.name)
            pos++; // {% endmacro name %}
        expectBlockEnd();
        return s;
    }

    Stmt parseCall()
    {
        auto s = mk!CallBlock;
        pos++;
        if (isOp("("))
            parseSignature(s.params, s.defaults);
        auto e = parseExpression();
        auto c = cast(CallExpr) e;
        if (c is null)
            fail("expected call");
        s.call = c;
        expectBlockEnd();
        s.body_ = subparse(["endcall"]);
        pos++;
        expectBlockEnd();
        return s;
    }

    bool parseContextModifier(bool def)
    {
        if ((isName("with") || isName("without")) && peek.type == Tok.name && peek.value == "context")
        {
            bool w = cur.value == "with";
            pos += 2;
            return w;
        }
        return def;
    }

    Stmt parseImport()
    {
        auto s = mk!Import;
        pos++;
        s.template_ = parseExpression();
        expectName("as");
        s.alias_ = expectIdent();
        s.withContext = parseContextModifier(false);
        expectBlockEnd();
        return s;
    }

    Stmt parseFrom()
    {
        auto s = mk!FromImport;
        pos++;
        s.template_ = parseExpression();
        expectName("import");
        for (;;)
        {
            if (s.names.length)
            {
                if (!skipOp(","))
                    break;
            }
            if (cur.type != Tok.name)
                break;
            if ((isName("with") || isName("without")) && peek.type == Tok.name && peek.value == "context")
                break;
            auto n = expectIdent();
            string al = n;
            if (skipName("as"))
                al = expectIdent();
            s.names ~= n;
            s.aliases ~= al;
        }
        s.withContext = parseContextModifier(false);
        expectBlockEnd();
        return s;
    }

    Stmt parseInclude()
    {
        auto s = mk!Include;
        pos++;
        s.template_ = parseExpression();
        if (isName("ignore") && peek.type == Tok.name && peek.value == "missing")
        {
            pos += 2;
            s.ignoreMissing = true;
        }
        s.withContext = parseContextModifier(true);
        expectBlockEnd();
        return s;
    }

    Stmt parseExtends()
    {
        auto s = mk!Extends;
        pos++;
        s.template_ = parseExpression();
        expectBlockEnd();
        tmpl.hasExtends = true;
        return s;
    }

    Stmt parseBlock()
    {
        auto s = mk!Block;
        pos++;
        s.name = expectIdent();
        s.scoped = skipName("scoped");
        skipName("required");
        expectBlockEnd();
        s.body_ = subparse(["endblock"]);
        pos++;
        if (cur.type == Tok.name)
            pos++;
        expectBlockEnd();
        tmpl.blocks[s.name] = s;
        return s;
    }

    Stmt parseWith()
    {
        auto s = mk!With;
        pos++;
        while (cur.type != Tok.blockEnd)
        {
            if (s.targets.length)
                expectOp(",");
            s.targets ~= parseAssignTarget(null);
            expectOp("=");
            s.values ~= parseExpression();
        }
        expectBlockEnd();
        s.body_ = subparse(["endwith"]);
        pos++;
        expectBlockEnd();
        return s;
    }

    Stmt parseFilterBlock()
    {
        auto s = mk!FilterBlock;
        pos++;
        s.filter = parseFilterChain(null, true);
        expectBlockEnd();
        s.body_ = subparse(["endfilter"]);
        pos++;
        expectBlockEnd();
        return s;
    }

    Stmt parseAutoEscape()
    {
        auto s = mk!AutoEscape;
        pos++;
        s.enabled = parseExpression();
        expectBlockEnd();
        s.body_ = subparse(["endautoescape"]);
        pos++;
        expectBlockEnd();
        return s;
    }

    Expr parseAssignTarget(string[] extraEnd, bool withNamespace = false)
    {
        if (withNamespace && cur.type == Tok.name && peek.type == Tok.op && peek.value == ".")
        {
            auto g = mk!GetAttr;
            auto n = mk!NameExpr;
            n.name = expectIdent();
            pos++; // .
            g.obj = n;
            g.attr = expectIdent();
            return g;
        }
        Expr[] items;
        bool comma;
        for (;;)
        {
            if (items.length)
            {
                if (!skipOp(","))
                    break;
                comma = true;
            }
            if (cur.type != Tok.name)
                break;
            bool stop;
            foreach (e; extraEnd)
                if (cur.value == e)
                    stop = true;
            if (stop)
                break;
            if (isOp("("))
            {
                pos++;
                items ~= parseAssignTarget(null);
                expectOp(")");
                continue;
            }
            auto n = mk!NameExpr;
            n.name = expectIdent();
            items ~= n;
        }
        if (items.length == 0)
            fail("expected assignment target");
        if (items.length == 1 && !comma)
            return items[0];
        auto l = mk!ListExpr;
        l.items = items;
        l.tuple = true;
        return l;
    }

    // ------------------------------------------------------------ expressions

    Expr parseExpression(bool withCondExpr = true)
    {
        return withCondExpr ? parseCondExpr() : parseOr();
    }

    /// Comma-separated expressions; a single one without a comma is returned as is.
    Expr parseTuple(bool simplified = false, bool withCondExpr = true, string[] extraEnd = null, bool explicitParens = false)
    {
        Expr[] items;
        bool comma;
        for (;;)
        {
            if (items.length)
            {
                if (!skipOp(","))
                    break;
                comma = true;
            }
            if (isTupleEnd(extraEnd))
                break;
            if (simplified)
                items ~= parsePrimary();
            else
                items ~= parseExpression(withCondExpr);
        }
        if (!comma && items.length == 1)
            return items[0];
        if (items.length == 0 && !explicitParens)
            fail("expected an expression, got '" ~ describe(cur) ~ "'");
        auto l = mk!ListExpr;
        l.items = items;
        l.tuple = true;
        return l;
    }

    bool isTupleEnd(string[] extraEnd)
    {
        if (cur.type == Tok.varEnd || cur.type == Tok.blockEnd || cur.type == Tok.eof)
            return true;
        if (isOp(")") || isOp("]") || isOp("}"))
            return true;
        if (cur.type == Tok.name)
            foreach (e; extraEnd)
                if (cur.value == e)
                    return true;
        return false;
    }

    Expr parseCondExpr()
    {
        auto e1 = parseOr();
        while (isName("if"))
        {
            auto line = cur.line;
            pos++;
            auto e2 = parseOr();
            Expr e3;
            if (skipName("else"))
                e3 = parseCondExpr();
            auto c = new CondExpr;
            c.line = line;
            c.test = e2;
            c.then = e1;
            c.else_ = e3;
            e1 = c;
        }
        return e1;
    }

    Expr bin(string op, Expr l, Expr r, size_t line)
    {
        auto b = new BinOp;
        b.line = line;
        b.op = op;
        b.left = l;
        b.right = r;
        return b;
    }

    Expr parseOr()
    {
        auto l = parseAnd();
        while (isName("or"))
        {
            auto line = cur.line;
            pos++;
            l = bin("or", l, parseAnd(), line);
        }
        return l;
    }

    Expr parseAnd()
    {
        auto l = parseNot();
        while (isName("and"))
        {
            auto line = cur.line;
            pos++;
            l = bin("and", l, parseNot(), line);
        }
        return l;
    }

    Expr parseNot()
    {
        if (isName("not"))
        {
            auto u = mk!UnaryOp;
            pos++;
            u.op = "not";
            u.operand = parseNot();
            return u;
        }
        return parseCompare();
    }

    Expr parseCompare()
    {
        auto line = cur.line;
        auto first = parseMath1();
        string[] ops;
        Expr[] rest;
        for (;;)
        {
            if (cur.type == Tok.op && (cur.value == "==" || cur.value == "!=" || cur.value == "<" || cur.value == "<="
                    || cur.value == ">" || cur.value == ">="))
            {
                ops ~= cur.value;
                pos++;
                rest ~= parseMath1();
            }
            else if (isName("in"))
            {
                pos++;
                ops ~= "in";
                rest ~= parseMath1();
            }
            else if (isName("not") && peek.type == Tok.name && peek.value == "in")
            {
                pos += 2;
                ops ~= "notin";
                rest ~= parseMath1();
            }
            else
                break;
        }
        if (ops.length == 0)
            return first;
        auto c = new CompareExpr;
        c.line = line;
        c.first = first;
        c.ops = ops;
        c.rest = rest;
        return c;
    }

    Expr parseMath1()
    {
        auto l = parseConcat();
        while (isOp("+") || isOp("-"))
        {
            auto op = cur.value;
            auto line = cur.line;
            pos++;
            l = bin(op, l, parseConcat(), line);
        }
        return l;
    }

    Expr parseConcat()
    {
        auto l = parseMath2();
        while (isOp("~"))
        {
            auto line = cur.line;
            pos++;
            l = bin("~", l, parseMath2(), line);
        }
        return l;
    }

    Expr parseMath2()
    {
        auto l = parsePow();
        while (isOp("*") || isOp("/") || isOp("//") || isOp("%"))
        {
            auto op = cur.value;
            auto line = cur.line;
            pos++;
            l = bin(op, l, parsePow(), line);
        }
        return l;
    }

    Expr parsePow()
    {
        auto l = parseUnary();
        while (isOp("**"))
        {
            auto line = cur.line;
            pos++;
            l = bin("**", l, parseUnary(), line);
        }
        return l;
    }

    Expr parseUnary(bool withFilter = true)
    {
        Expr node;
        if (isOp("-") || isOp("+"))
        {
            auto u = mk!UnaryOp;
            u.op = cur.value;
            pos++;
            u.operand = parseUnary(false);
            node = u;
        }
        else
            node = parsePrimary();
        node = parsePostfix(node);
        if (withFilter)
            node = parseFilterExpr(node);
        return node;
    }

    Expr parsePrimary()
    {
        auto t = cur;
        switch (t.type)
        {
        case Tok.name:
            pos++;
            switch (t.value)
            {
            case "true", "True": return konst(Value(true), t.line);
            case "false", "False": return konst(Value(false), t.line);
            case "none", "None": return konst(Value(null), t.line);
            default:
                auto n = new NameExpr(t.value);
                n.line = t.line;
                return n;
            }
        case Tok.str:
            string s;
            while (cur.type == Tok.str)
                s ~= toks[pos++].value;
            return konst(Value(s), t.line);
        case Tok.integer:
            pos++;
            return konst(Value(to!long(t.value)), t.line);
        case Tok.floating:
            pos++;
            return konst(Value(to!double(t.value)), t.line);
        case Tok.op:
            if (t.value == "(")
            {
                pos++;
                auto e = parseTuple(false, true, null, true);
                expectOp(")");
                return e;
            }
            if (t.value == "[")
            {
                pos++;
                auto l = new ListExpr;
                l.line = t.line;
                while (!isOp("]"))
                {
                    if (l.items.length)
                        expectOp(",");
                    if (isOp("]"))
                        break;
                    l.items ~= parseExpression();
                }
                expectOp("]");
                return l;
            }
            if (t.value == "{")
            {
                pos++;
                auto d = new DictExpr;
                d.line = t.line;
                while (!isOp("}"))
                {
                    if (d.keys.length)
                        expectOp(",");
                    if (isOp("}"))
                        break;
                    d.keys ~= parseExpression();
                    expectOp(":");
                    d.values ~= parseExpression();
                }
                expectOp("}");
                return d;
            }
            goto default;
        default:
            fail("unexpected '" ~ describe(t) ~ "'");
        }
    }

    Expr konst(Value v, size_t line)
    {
        auto c = new Const(v);
        c.line = line;
        return c;
    }

    Expr parsePostfix(Expr node)
    {
        for (;;)
        {
            if (isOp(".") || isOp("["))
                node = parseSubscript(node);
            else if (isOp("("))
                node = parseCallArgs(node);
            else
                break;
        }
        return node;
    }

    Expr parseFilterExpr(Expr node)
    {
        for (;;)
        {
            if (isOp("|"))
                node = parseFilterChain(node);
            else if (isName("is"))
                node = parseTest(node);
            else if (isOp("("))
                node = parseCallArgs(node);
            else
                break;
        }
        return node;
    }

    Expr parseSubscript(Expr node)
    {
        auto line = cur.line;
        if (skipOp("."))
        {
            if (cur.type == Tok.name)
            {
                auto g = new GetAttr;
                g.line = line;
                g.obj = node;
                g.attr = toks[pos++].value;
                return g;
            }
            if (cur.type == Tok.integer)
            {
                auto g = new GetItem;
                g.line = line;
                g.obj = node;
                g.key = konst(Value(to!long(toks[pos++].value)), line);
                return g;
            }
            fail("expected name or number");
        }
        expectOp("[");
        // slice or index
        Expr[3] parts;
        int colons;
        bool any;
        while (!isOp("]"))
        {
            if (skipOp(":"))
            {
                colons++;
                if (colons > 2)
                    fail("invalid slice");
                continue;
            }
            if (parts[colons] !is null)
                fail("invalid subscript");
            parts[colons] = parseExpression();
            any = true;
        }
        expectOp("]");
        if (colons == 0)
        {
            if (!any)
                fail("expected subscript expression");
            auto g = new GetItem;
            g.line = line;
            g.obj = node;
            g.key = parts[0];
            return g;
        }
        auto s = new SliceExpr;
        s.line = line;
        s.obj = node;
        s.start = parts[0];
        s.stop = parts[1];
        s.step = parts[2];
        return s;
    }

    Expr parseCallArgs(Expr fn)
    {
        auto c = mk!CallExpr;
        c.fn = fn;
        expectOp("(");
        bool first = true;
        while (!isOp(")"))
        {
            if (!first)
            {
                expectOp(",");
                if (isOp(")"))
                    break;
            }
            first = false;
            if (isOp("*"))
            {
                pos++;
                c.dynArgs = parseExpression();
            }
            else if (isOp("**"))
            {
                pos++;
                c.dynKwargs = parseExpression();
            }
            else if (cur.type == Tok.name && peek.type == Tok.op && peek.value == "=")
            {
                c.kwNames ~= cur.value;
                pos += 2;
                c.kwValues ~= parseExpression();
            }
            else
                c.args ~= parseExpression();
        }
        expectOp(")");
        return c;
    }

    FilterExpr parseFilterChain(Expr node, bool startInline = false)
    {
        FilterExpr last;
        while (isOp("|") || startInline)
        {
            if (!startInline)
                pos++;
            startInline = false;
            auto f = mk!FilterExpr;
            f.value = node;
            f.name = expectIdent();
            while (isOp("."))
            {
                pos++;
                f.name ~= "." ~ expectIdent();
            }
            if (isOp("("))
            {
                auto c = cast(CallExpr) parseCallArgs(null);
                f.args = c.args;
                f.kwNames = c.kwNames;
                f.kwValues = c.kwValues;
            }
            node = f;
            last = f;
        }
        return last;
    }

    Expr parseTest(Expr node)
    {
        auto t = mk!TestExpr;
        pos++; // is
        t.negated = skipName("not");
        t.value = node;
        t.name = expectIdent();
        while (isOp("."))
        {
            pos++;
            t.name ~= "." ~ expectIdent();
        }
        if (isOp("("))
        {
            auto c = cast(CallExpr) parseCallArgs(null);
            t.args = c.args;
        }
        else if ((cur.type == Tok.name || cur.type == Tok.str || cur.type == Tok.integer || cur.type == Tok.floating
                || isOp("(") || isOp("[") || isOp("{"))
                && !(isName("else") || isName("or") || isName("and")))
        {
            if (isName("is"))
                fail("You cannot chain multiple tests with is");
            auto arg = parsePrimary();
            arg = parsePostfix(arg);
            t.args = [arg];
        }
        return t;
    }
}
