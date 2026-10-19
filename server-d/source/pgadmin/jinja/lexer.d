/// Jinja2 lexer: splits a template into data, variable, block and comment parts, and tokenizes expressions.
///
/// Matches the environment pgAdmin uses: default delimiters, `trim_blocks=True` (the first newline after a block or
/// comment tag is removed), `lstrip_blocks=False`, `keep_trailing_newline=False`, and `-` whitespace control.
module pgadmin.jinja.lexer;

import std.array : appender;
import std.conv : to;
import std.ascii : isAlpha, isDigit, isWhite, isAlphaNum;

class TemplateSyntaxError : Exception
{
    string templateName;
    size_t lineNo;
    this(string msg, string templateName, size_t lineNo, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg ~ " (" ~ templateName ~ ":" ~ to!string(lineNo) ~ ")", file, line);
        this.templateName = templateName;
        this.lineNo = lineNo;
    }
}

enum Tok : ubyte
{
    data,        // raw text
    varBegin,    // {{
    varEnd,      // }}
    blockBegin,  // {%
    blockEnd,    // %}
    name,
    str,
    integer,
    floating,
    op,
    eof,
}

struct Token
{
    Tok type;
    string value;
    size_t line;
}

struct LexOptions
{
    bool trimBlocks = true;
    bool lstripBlocks = false;
    bool keepTrailingNewline = false;
}

/// Tokenizes `src` into a flat token stream.
Token[] tokenize(string src, string name, LexOptions opts = LexOptions.init)
{
    if (!opts.keepTrailingNewline)
    {
        if (src.length && src[$ - 1] == '\n')
        {
            src = src[0 .. $ - 1];
            if (src.length && src[$ - 1] == '\r')
                src = src[0 .. $ - 1];
        }
    }

    Token[] toks;
    size_t i;
    size_t line = 1;
    bool stripNextWs;        // previous tag ended with "-%}" / "-}}" / "-#}"
    bool trimNextNewline;    // previous tag was a block/comment end and trim_blocks is on

    void countLines(const(char)[] s)
    {
        foreach (c; s)
            if (c == '\n')
                line++;
    }

    void pushData(string d)
    {
        if (stripNextWs)
        {
            size_t k;
            while (k < d.length && isWhite(d[k]))
                k++;
            countLines(d[0 .. k]);
            d = d[k .. $];
            stripNextWs = false;
            trimNextNewline = false;
        }
        else if (trimNextNewline)
        {
            if (d.length && d[0] == '\n')
            {
                d = d[1 .. $];
                line++;
            }
            else if (d.length > 1 && d[0] == '\r' && d[1] == '\n')
            {
                d = d[2 .. $];
                line++;
            }
            trimNextNewline = false;
        }
        if (d.length)
        {
            toks ~= Token(Tok.data, d, line);
            countLines(d);
        }
    }

    while (i < src.length)
    {
        // find the next tag start
        size_t j = i;
        size_t tagAt = size_t.max;
        char kind;
        while (j + 1 < src.length)
        {
            if (src[j] == '{' && (src[j + 1] == '{' || src[j + 1] == '%' || src[j + 1] == '#'))
            {
                tagAt = j;
                kind = src[j + 1];
                break;
            }
            j++;
        }
        if (tagAt == size_t.max)
        {
            pushData(src[i .. $]);
            break;
        }

        string before = src[i .. tagAt];
        bool lstrip = tagAt + 2 < src.length && src[tagAt + 2] == '-';
        if (lstrip)
        {
            size_t e = before.length;
            while (e > 0 && isWhite(before[e - 1]))
                e--;
            // keep the line count right for the stripped part
            auto stripped = before[e .. $];
            before = before[0 .. e];
            pushData(before);
            countLines(stripped);
        }
        else if (opts.lstripBlocks && (kind == '%' || kind == '#'))
        {
            size_t e = before.length;
            while (e > 0 && (before[e - 1] == ' ' || before[e - 1] == '\t'))
                e--;
            if (e == 0 || before[e - 1] == '\n')
                before = before[0 .. e];
            pushData(before);
        }
        else
            pushData(before);

        size_t p = tagAt + 2 + (lstrip ? 1 : 0);
        if (p < src.length && src[p] == '+')
            p++;

        if (kind == '#')
        {
            // comment: find "#}"
            size_t e = p;
            while (e + 1 < src.length && !(src[e] == '#' && src[e + 1] == '}'))
                e++;
            if (e + 1 >= src.length)
                throw new TemplateSyntaxError("missing end of comment tag", name, line);
            countLines(src[p .. e]);
            bool rstrip = e > p && src[e - 1] == '-';
            i = e + 2;
            stripNextWs = rstrip;
            trimNextNewline = !rstrip && opts.trimBlocks;
            continue;
        }

        immutable endCh = kind == '{' ? '}' : '%';
        toks ~= Token(kind == '{' ? Tok.varBegin : Tok.blockBegin, null, line);

        // raw block: {% raw %} ... {% endraw %}
        if (kind == '%')
        {
            size_t q = p;
            while (q < src.length && isWhite(src[q]))
                q++;
            if (q + 3 <= src.length && src[q .. q + 3] == "raw")
            {
                size_t r = q + 3;
                while (r < src.length && isWhite(src[r]))
                    r++;
                bool rawRstrip = r < src.length && src[r] == '-';
                if (rawRstrip)
                    r++;
                if (r + 1 < src.length && src[r] == '%' && src[r + 1] == '}')
                {
                    toks = toks[0 .. $ - 1];
                    // find {% endraw %}
                    size_t s = r + 2;
                    size_t found = size_t.max, foundEnd;
                    bool endLstrip, endRstrip;
                    size_t k = s;
                    while (k + 1 < src.length)
                    {
                        if (src[k] == '{' && src[k + 1] == '%')
                        {
                            size_t t = k + 2;
                            bool ls = t < src.length && src[t] == '-';
                            if (ls)
                                t++;
                            while (t < src.length && isWhite(src[t]))
                                t++;
                            if (t + 6 <= src.length && src[t .. t + 6] == "endraw")
                            {
                                t += 6;
                                while (t < src.length && isWhite(src[t]))
                                    t++;
                                bool rs = t < src.length && src[t] == '-';
                                if (rs)
                                    t++;
                                if (t + 1 < src.length && src[t] == '%' && src[t + 1] == '}')
                                {
                                    found = k;
                                    foundEnd = t + 2;
                                    endLstrip = ls;
                                    endRstrip = rs;
                                    break;
                                }
                            }
                        }
                        k++;
                    }
                    if (found == size_t.max)
                        throw new TemplateSyntaxError("missing endraw", name, line);
                    string body = src[s .. found];
                    if (rawRstrip)
                    {
                        size_t b;
                        while (b < body.length && isWhite(body[b]))
                            b++;
                        body = body[b .. $];
                    }
                    else if (opts.trimBlocks && body.length && body[0] == '\n')
                        body = body[1 .. $];
                    if (endLstrip)
                    {
                        size_t e2 = body.length;
                        while (e2 > 0 && isWhite(body[e2 - 1]))
                            e2--;
                        body = body[0 .. e2];
                    }
                    if (body.length)
                        toks ~= Token(Tok.data, body, line);
                    countLines(src[r .. foundEnd]);
                    i = foundEnd;
                    stripNextWs = endRstrip;
                    trimNextNewline = !endRstrip && opts.trimBlocks;
                    continue;
                }
            }
        }

        // tokenize the expression up to the matching end delimiter
        size_t k = p;
        bool closed;
        while (k < src.length)
        {
            char c = src[k];
            if (c == '\n')
            {
                line++;
                k++;
                continue;
            }
            if (isWhite(c))
            {
                k++;
                continue;
            }
            // end delimiter (with optional '-')
            if (c == '-' && k + 2 < src.length && src[k + 1] == endCh && src[k + 2] == '}')
            {
                toks ~= Token(kind == '{' ? Tok.varEnd : Tok.blockEnd, null, line);
                i = k + 3;
                stripNextWs = true;
                trimNextNewline = false;
                closed = true;
                break;
            }
            if (c == endCh && k + 1 < src.length && src[k + 1] == '}')
            {
                toks ~= Token(kind == '{' ? Tok.varEnd : Tok.blockEnd, null, line);
                i = k + 2;
                stripNextWs = false;
                trimNextNewline = kind == '%' && opts.trimBlocks;
                closed = true;
                break;
            }
            if (isAlpha(c) || c == '_')
            {
                size_t s = k;
                while (k < src.length && (isAlphaNum(src[k]) || src[k] == '_'))
                    k++;
                toks ~= Token(Tok.name, src[s .. k], line);
                continue;
            }
            if (isDigit(c))
            {
                size_t s = k;
                bool isF;
                while (k < src.length && (isDigit(src[k]) || src[k] == '_'))
                    k++;
                if (k + 1 < src.length && src[k] == '.' && isDigit(src[k + 1]))
                {
                    isF = true;
                    k++;
                    while (k < src.length && (isDigit(src[k]) || src[k] == '_'))
                        k++;
                }
                if (k < src.length && (src[k] == 'e' || src[k] == 'E'))
                {
                    size_t t = k + 1;
                    if (t < src.length && (src[t] == '+' || src[t] == '-'))
                        t++;
                    if (t < src.length && isDigit(src[t]))
                    {
                        isF = true;
                        k = t;
                        while (k < src.length && isDigit(src[k]))
                            k++;
                    }
                }
                string num;
                foreach (ch; src[s .. k])
                    if (ch != '_')
                        num ~= ch;
                toks ~= Token(isF ? Tok.floating : Tok.integer, num, line);
                continue;
            }
            if (c == '\'' || c == '"')
            {
                auto a = appender!string;
                size_t t = k + 1;
                bool ok;
                while (t < src.length)
                {
                    char d = src[t];
                    if (d == c)
                    {
                        ok = true;
                        t++;
                        break;
                    }
                    if (d == '\n')
                        line++;
                    if (d == '\\' && t + 1 < src.length)
                    {
                        char e = src[t + 1];
                        t += 2;
                        switch (e)
                        {
                        case 'n': a.put('\n'); break;
                        case 't': a.put('\t'); break;
                        case 'r': a.put('\r'); break;
                        case '\\': a.put('\\'); break;
                        case '\'': a.put('\''); break;
                        case '"': a.put('"'); break;
                        case '0': a.put('\0'); break;
                        case '\n': line++; break;
                        case 'x':
                            if (t + 2 <= src.length)
                            {
                                a.put(cast(char) to!ubyte(src[t .. t + 2], 16));
                                t += 2;
                            }
                            break;
                        case 'u':
                            if (t + 4 <= src.length)
                            {
                                import pgadmin.core.value : putUtf;
                                putUtf(a, cast(dchar) to!uint(src[t .. t + 4], 16));
                                t += 4;
                            }
                            break;
                        default:
                            a.put('\\');
                            a.put(e);
                        }
                        continue;
                    }
                    a.put(d);
                    t++;
                }
                if (!ok)
                    throw new TemplateSyntaxError("unexpected end of string", name, line);
                toks ~= Token(Tok.str, a.data, line);
                k = t;
                continue;
            }
            // operators
            static immutable string[] ops3 = ["**", "//", "==", "!=", "<=", ">="];
            bool matched;
            if (k + 1 < src.length)
            {
                auto two = src[k .. k + 2];
                foreach (o; ops3)
                    if (two == o)
                    {
                        toks ~= Token(Tok.op, o, line);
                        k += 2;
                        matched = true;
                        break;
                    }
            }
            if (matched)
                continue;
            switch (c)
            {
            case '+', '-', '*', '/', '%', '~', '<', '>', '=', '(', ')', '[', ']', '{', '}', ',', '.', ':', '|', ';':
                toks ~= Token(Tok.op, src[k .. k + 1], line);
                k++;
                break;
            default:
                throw new TemplateSyntaxError("unexpected char '" ~ c ~ "'", name, line);
            }
        }
        if (!closed)
            throw new TemplateSyntaxError("unexpected end of template, expected end of tag", name, line);
    }
    toks ~= Token(Tok.eof, null, line);
    return toks;
}
