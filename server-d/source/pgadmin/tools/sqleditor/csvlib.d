/// CSV output of the Query Tool (`pgadmin/utils/csv_lib.py`'s writer with the `replace_nulls_with` extension).
module pgadmin.tools.sqleditor.csvlib;

import std.array : join;
import std.string : indexOf;
import pgadmin.core.value;

/// postgres oids whose values psycopg hands to the csv writer as numbers
private bool isNumberOid(uint oid)
{
    switch (oid)
    {
    case 16, 20, 21, 23, 26, 700, 701, 1700:
        return true;
    default:
        return false;
    }
}

private string pyFloatText(string t)
{
    switch (t)
    {
    case "NaN": return "nan";
    case "Infinity": return "inf";
    case "-Infinity": return "-inf";
    default: return t;
    }
}

/// `str(value)` of what psycopg would have returned for the cell.
private string pyStr(Value v, uint oid)
{
    if (v.isNone)
        return "";
    if (v.isBool)
        return v.boolean ? "True" : "False";
    if (v.isString && (oid == 700 || oid == 701))
        return pyFloatText(v.str);
    return v.toString;
}

private bool isNumber(Value v, uint oid)
    => v.isBool || v.isInt || v.type == VType.floating || (v.isString && isNumberOid(oid) && oid != 16);

struct CsvDialect
{
    string quoting = "strings"; /// 'strings' | 'all' | other (none)
    string quoteChar = "\"";
    string delimiter = ",";
    Value replaceNullsWith = Value(null);
    string lineTerminator = "\r\n";
}

private string prepare(CsvDialect d, Value raw, uint oid, bool only, bool isHeader = false)
{
    string field = raw.isNone ? "" : pyStr(raw, oid);
    bool nullLike = raw.isNone || (!d.replaceNullsWith.isNone && raw == d.replaceNullsWith);
    bool quoted;
    if (d.quoting == "all")
        quoted = !nullLike;
    else if (d.quoting == "strings")
        quoted = !nullLike && !(isHeader ? false : isNumber(raw, oid));
    else
    {
        if (field == "" && only)
            throw new Exception("single empty field record must be quoted");
        quoted = false;
    }
    if (quoted && d.quoteChar.length)
    {
        string r;
        foreach (char c; field)
        {
            if (d.quoteChar.indexOf(c) >= 0)
                r ~= d.quoteChar;
            r ~= c;
        }
        field = r;
        field = d.quoteChar ~ field ~ d.quoteChar;
    }
    return field;
}

/// The header row followed by `rows` (one `Value[]` per row, in `typeCodes` order).
string csvText(CsvDialect d, string[] header, uint[] typeCodes, Value[][] rows, bool withHeader)
{
    string o;
    if (withHeader)
    {
        string[] cells;
        foreach (h; header)
            cells ~= prepare(d, Value(h), 0, header.length == 1, true);
        o ~= join(cells, d.delimiter) ~ d.lineTerminator;
    }
    foreach (row; rows)
    {
        string[] cells;
        foreach (i, v; row)
        {
            if (v.isNone && !d.replaceNullsWith.isNone)
                v = d.replaceNullsWith;
            cells ~= prepare(d, v, i < typeCodes.length ? typeCodes[i] : 0, row.length == 1);
        }
        o ~= join(cells, d.delimiter) ~ d.lineTerminator;
    }
    return o;
}

