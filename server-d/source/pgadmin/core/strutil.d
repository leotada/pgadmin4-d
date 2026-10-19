/// Python string helpers that Phobos spells differently.
module pgadmin.core.strutil;

/// `s.strip(chars)`: removes any of `chars` from both ends.
string pyStrip(string s, string chars)
{
    size_t a, b = s.length;
    bool inSet(char c)
    {
        foreach (x; chars)
            if (x == c)
                return true;
        return false;
    }

    while (a < b && inSet(s[a]))
        a++;
    while (b > a && inSet(s[b - 1]))
        b--;
    return s[a .. b];
}

import pgadmin.core.value : Value, VType;

/// `int(x)`, raising the ValueError/TypeError text Python would.
long pyIntStrict(Value v)
{
    import std.conv : to, ConvException;
    import std.string : strip;
    switch (v.type)
    {
    case VType.boolean:
        return v.boolean ? 1 : 0;
    case VType.integer:
        return v.integer;
    case VType.floating:
        return cast(long) v.floating;
    case VType.str:
        auto s = v.str.strip;
        try
            return to!long(s.length && s[0] == '+' ? s[1 .. $] : s);
        catch (ConvException)
            throw new Exception("invalid literal for int() with base 10: '" ~ v.str ~ "'");
    case VType.none:
        throw new Exception("int() argument must be a string, a bytes-like object or a real number, not 'NoneType'");
    case VType.list:
        throw new Exception("int() argument must be a string, a bytes-like object or a real number, not 'list'");
    default:
        throw new Exception("int() argument must be a string, a bytes-like object or a real number, not 'dict'");
    }
}

/// `dateutil.parser.parse(s).isoformat()` for the usual ISO-like inputs; throws when the text is not understood.
string dateutilIsoformat(string s)
{
    import std.regex : regex, matchFirst;
    import std.format : format;
    import std.conv : to;
    auto m = matchFirst(s, regex(`^\s*(\d{4})-(\d{1,2})-(\d{1,2})(?:[T\s]+(\d{1,2}):(\d{2})(?::(\d{2})(?:[.,](\d{1,6})\d*)?)?)?\s*(?:(Z|UTC)|([+-])(\d{2}):?(\d{2})?)?\s*$`));
    if (m.empty)
        throw new Exception("Unknown string format: " ~ s);
    auto mon = to!int(m[2]);
    auto day = to!int(m[3]);
    if (mon < 1 || mon > 12 || day < 1 || day > 31)
        throw new Exception("month must be in 1..12");
    string r = format("%s-%02d-%02d", m[1], mon, day);
    int hh = m[4].length ? to!int(m[4]) : 0;
    int mi = m[5].length ? to!int(m[5]) : 0;
    int ss = m[6].length ? to!int(m[6]) : 0;
    if (hh > 23 || mi > 59 || ss > 59)
        throw new Exception("hour must be in 0..23");
    r ~= format("T%02d:%02d:%02d", hh, mi, ss);
    if (m[7].length)
    {
        auto us = m[7];
        while (us.length < 6)
            us ~= "0";
        if (to!int(us) != 0)
            r ~= "." ~ us;
    }
    if (m[8].length)
        r ~= "+00:00";
    else if (m[9].length)
        r ~= m[9] ~ m[10] ~ ":" ~ (m[11].length ? m[11] : "00");
    return r;
}
