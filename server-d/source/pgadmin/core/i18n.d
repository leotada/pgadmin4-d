/// Message translation (`flask_babel.gettext`). Looks messages up in the .mo catalog of the request's language.
module pgadmin.core.i18n;

import std.string : format, strip;

/// Translation lookup hook; set by the translations module once catalogs are loaded.
__gshared string delegate(string msgid) translateHook;

/// GNU Gettext binary (.mo) catalog reader.
final class MoCatalog
{
    private string[string] entries;

    this() {}

    this(const(ubyte)[] data)
    {
        load(data);
    }

    bool load(const(ubyte)[] data)
    {
        if (data.length < 28)
            return false;

        uint magic = *cast(const(uint)*) data.ptr;
        bool swap = false;
        if (magic == 0xde120495)
            swap = true;
        else if (magic != 0x950412de)
            return false;

        uint read32(size_t offset)
        {
            if (offset + 4 > data.length)
                return 0;
            uint v = *cast(const(uint)*)(data.ptr + offset);
            if (swap)
            {
                import core.bitop : bswap;
                v = bswap(v);
            }
            return v;
        }

        uint numStrings = read32(8);
        uint origTableOffset = read32(12);
        uint transTableOffset = read32(16);

        foreach (i; 0 .. numStrings)
        {
            uint origLen = read32(origTableOffset + i * 8);
            uint origOff = read32(origTableOffset + i * 8 + 4);
            uint transLen = read32(transTableOffset + i * 8);
            uint transOff = read32(transTableOffset + i * 8 + 4);

            if (origOff + origLen <= data.length && transOff + transLen <= data.length)
            {
                auto orig = cast(string) data[origOff .. origOff + origLen].idup;
                auto trans = cast(string) data[transOff .. transOff + transLen].idup;
                entries[orig] = trans;
            }
        }
        return true;
    }

    string get(string msgid) const
    {
        if (auto p = msgid in entries)
            return *p;
        return msgid;
    }

    bool has(string msgid) const
    {
        return (msgid in entries) !is null;
    }

    size_t length() const
    {
        return entries.length;
    }
}

private __gshared MoCatalog[string] loadedCatalogs;
private __gshared string translationsDirectory;

void setTranslationsDir(string dir)
{
    translationsDirectory = dir;
}

MoCatalog getCatalog(string lang)
{
    if (lang.length == 0 || lang == "en")
        return null;

    if (auto c = lang in loadedCatalogs)
        return *c;

    import std.file : exists, read;
    import std.path : buildPath;

    string moPath;
    if (translationsDirectory.length)
        moPath = buildPath(translationsDirectory, lang, "LC_MESSAGES", "messages.mo");
    else
    {
        import pgadmin.core.config : pgadminDir;
        moPath = buildPath(pgadminDir(), "translations", lang, "LC_MESSAGES", "messages.mo");
    }

    if (exists(moPath))
    {
        try
        {
            auto bytes = cast(const(ubyte)[]) read(moPath);
            auto cat = new MoCatalog(bytes);
            loadedCatalogs[lang] = cat;
            return cat;
        }
        catch (Exception) {}
    }
    return null;
}

/// `gettext(msgid)`
string gettext(string msgid)
{
    if (translateHook !is null)
    {
        auto t = translateHook(msgid);
        if (t.length)
            return t;
    }

    try
    {
        import pgadmin.web.context : hasRequestContext, request;
        if (hasRequestContext())
        {
            auto req = request();
            if (req !is null)
            {
                string lang;
                if (auto p = "PGADMIN_LANGUAGE" in req.cookies)
                    lang = *p;
                else
                {
                    auto al = req.header("Accept-Language");
                    if (al.length)
                    {
                        import std.array : split;
                        auto parts = al.split(",");
                        if (parts.length)
                            lang = parts[0].split(";")[0].strip;
                    }
                }

                if (lang.length)
                {
                    auto cat = getCatalog(lang);
                    if (cat !is null)
                        return cat.get(msgid);
                }
            }
        }
    }
    catch (Exception) {}

    return msgid;
}

/// `gettext(msgid).format(args...)` with Python's `{}`/`{0}` placeholders
string gettextFormat(string msgid, string[] args...)
{
    import pgadmin.jinja.runtime : pyStrFormat;
    import pgadmin.core.value : Value;
    Value[] vs;
    foreach (a; args)
        vs ~= Value(a);
    return pyStrFormat(gettext(msgid), vs, null);
}

alias _ = gettext;

unittest
{
    import std.file : exists, read;
    auto testMo = "../web/pgadmin/translations/pt_BR/LC_MESSAGES/messages.mo";
    if (exists(testMo))
    {
        auto bytes = cast(const(ubyte)[]) read(testMo);
        auto cat = new MoCatalog(bytes);
        assert(cat.length > 100, "pt_BR catalog should have many translated strings");
        assert(cat.has("100 rows"), "Should have translation for '100 rows'");
    }
}
