/// `schemas/functions/utils.py`: the argument lists of functions and procedures.
module pgadmin.browser.server_groups.servers.databases.schemas.functions.utils;

import std.array : insertInPlace, join, array;
import std.regex : regex, split;
import std.string : strip;
import pgadmin.core.templates;
import pgadmin.core.value;
import pgadmin.db.driver;

/// `get_argument_values(data)`. The lists that come straight from `data` are shared (and mutated by the callers),
/// as in the Python code.
struct ArgumentValues
{
    List proargtypes;
    List proargmodes;
    List proargnames;
    List proargdefaultvals;
    List proallargtypes;
}

ArgumentValues getArgumentValues(Value data)
{
    ArgumentValues a;
    a.proargtypes = new List;
    if (data.contains("proargtypenames") && data["proargtypenames"].truthy && data["proargtypenames"].isString)
    {
        foreach (p; data["proargtypenames"].str.splitComma)
            a.proargtypes.items ~= Value(p);
    }
    else if (data.contains("proargtypenames") && data["proargtypenames"].truthy)
        a.proargtypes = data["proargtypenames"].list;
    if (data.contains("proargmodes") && data["proargmodes"].truthy)
        a.proargmodes = data["proargmodes"].list;
    else
    {
        a.proargmodes = new List;
        foreach (i; 0 .. a.proargtypes.items.length)
            a.proargmodes.items ~= Value("i");
    }
    a.proargnames = data.contains("proargnames") && data["proargnames"].truthy ? data["proargnames"].list : new List;
    a.proargdefaultvals = new List;
    if (data.contains("proargdefaultvals") && data["proargdefaultvals"].truthy && data["proargdefaultvals"].isString)
    {
        // split on the commas that are outside quotes
        foreach (p; data["proargdefaultvals"].str.split(regex(`,(?=(?:[^"']*["'][^"']*["'])*[^"']*$)`)))
            a.proargdefaultvals.items ~= Value(p);
    }
    else if (data.contains("proargdefaultvals") && data["proargdefaultvals"].truthy)
        a.proargdefaultvals = data["proargdefaultvals"].list;
    a.proallargtypes = data.contains("proallargtypes") && data["proallargtypes"].truthy
        ? data["proallargtypes"].list : new List;
    return a;
}

private string[] splitComma(string s)
{
    string[] r;
    size_t start;
    foreach (i, c; s)
        if (c == ',')
        {
            r ~= s[start .. i];
            start = i + 1;
        }
    r ~= s[start .. $];
    return r;
}

private string at(List l, size_t i) => l.items.length > i && !l.items[i].isNone ? l.items[i].toString : "";

Value mapArgumentsDict(long argid, string argmode, string argtype, string argname, string argdefval)
{
    if (argmode == "INOUT" && argdefval.strip == "-")
        argdefval = "";
    return Value.dictOf("argid", argid, "argtype", argtype.strip, "argmode", argmode, "argname", argname,
            "argdefval", argdefval);
}

string mapArgumentsList(string argmode, string argtype, string argname, string argdef)
{
    if (argmode == "INOUT" && argdef.strip == "-")
        argdef = "";
    string arg;
    if (argmode.length)
        arg ~= argmode ~ " ";
    if (argname.length)
        arg ~= argname ~ " ";
    if (argtype.length)
        arg ~= argtype ~ " ";
    if (argdef.length)
        arg ~= " DEFAULT " ~ argdef;
    return arg.strip(" ");
}

/// `format_arguments_from_db(sql_template_path, conn, data)` -> `(params, proargs)`; an `Exception` carries a database
/// error.
void formatArgumentsFromDb(string sqlTemplatePath, Connection conn, Value data, out Value params, out Value proargs)
{
    auto arguments = getArgumentValues(data);
    auto proargtypes = arguments.proargtypes;
    auto proargmodes = arguments.proargmodes;
    auto proargnames = arguments.proargnames;
    auto proargdefaultvals = arguments.proargdefaultvals;
    auto proallargtypes = arguments.proallargtypes;
    immutable proargmodenames = ["i": "IN", "o": "OUT", "b": "INOUT", "v": "VARIADIC", "t": "TABLE"];

    immutable totalDefault = proargdefaultvals.items.length;
    immutable totalParams = proargtypes.items.length;
    if (totalDefault > 0 && totalParams > totalDefault)
        foreach (idx; 0 .. totalParams - totalDefault)
            proargdefaultvals.items.insertInPlace(idx, Value(""));

    Value[] modesFltrd = proargmodes.items.dup;
    Value[] namesFltrd;
    size_t cnt;
    foreach (m; proargmodes.items.dup)
    {
        auto ms = m.toString;
        if (ms == "o")
        {
            auto r = conn.executeScalar(renderTemplate(sqlTemplatePath ~ "/get_out_types.sql",
                    tv("out_arg_oid", proallargtypes.items[cnt])));
            if (!r.ok)
                throw new Exception(r.error);
            proargtypes.items.insertInPlace(cnt, r.value);
            proargdefaultvals.items.insertInPlace(cnt, Value(""));
        }
        else if (ms == "v")
            proargdefaultvals.items.insertInPlace(cnt, Value(""));
        else if (ms == "t")
        {
            foreach (i, v; modesFltrd)
                if (v == m)
                {
                    modesFltrd = modesFltrd[0 .. i] ~ modesFltrd[i + 1 .. $];
                    break;
                }
            namesFltrd ~= proargnames.items[cnt];
        }
        cnt++;
    }
    string[] modeNames;
    foreach (m; modesFltrd)
        modeNames ~= proargmodenames[m.toString];
    foreach (n; namesFltrd)
        foreach (i, v; proargnames.items)
            if (v == n)
            {
                proargnames.items = proargnames.items[0 .. i] ~ proargnames.items[i + 1 .. $];
                break;
            }

    // params_list_for_display
    if (modeNames.length > proargdefaultvals.items.length)
    {
        auto dif = modeNames.length - proargdefaultvals.items.length;
        foreach (_; 0 .. dif)
            proargdefaultvals.items.insertInPlace(0, Value(""));
    }
    Value[] argList;
    string[] display;
    foreach (i; 0 .. proargtypes.items.length)
    {
        auto mode = modeNames.length > i ? modeNames[i] : "";
        auto type = at(proargtypes, i);
        auto name = at(proargnames, i);
        auto def = at(proargdefaultvals, i);
        argList ~= mapArgumentsDict(i, mode, type, name, def);
        display ~= mapArgumentsList(mode, type, name, def);
    }
    params = Value.dictOf("arguments", Value(argList));
    proargs = Value.dictOf("proargs", display.join(", "));
}
