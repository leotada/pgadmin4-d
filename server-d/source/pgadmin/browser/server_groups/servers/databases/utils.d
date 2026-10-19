/// Helpers of the databases node (`databases/utils.py`).
module pgadmin.browser.server_groups.servers.databases.utils;

import std.regex : regex, matchFirst;
import std.string : indexOf, split;
import pgadmin.core.value;
import pgadmin.db.driver;

/// `parse_sec_labels_from_db`
Dict parseSecLabelsFromDb(Value dbSecLabels)
{
    Value[] lbls;
    if (!dbSecLabels.isNone)
        foreach (sec; dbSecLabels.iterItems())
        {
            auto m = matchFirst(sec.toString, regex(`([^=]+)=(.*$)`));
            lbls ~= Value.dictOf("provider", m[1].idup, "label", m[2].idup);
        }
    return kwDict("seclabels", Value(lbls));
}

private Value checkVarType(string varValue, string varName, Value row)
{
    Value v = Value(varValue);
    if (varValue == "false" || varValue == "off")
        v = Value(false);
    auto d = Value.dictOf("name", varName, "value", v);
    if (row.contains("user_name"))
        d["role"] = row["user_name"];
    if (row.contains("db_name"))
        d["database"] = row["db_name"];
    return d;
}

/// `parse_variables_from_db`
Dict parseVariablesFromDb(Value dbVariables)
{
    Value[] lst;
    if (!dbVariables.isNone)
        foreach (row; dbVariables.iterItems())
            if (row.contains("setconfig") && !row["setconfig"].isNone)
                foreach (d; row["setconfig"].iterItems())
                {
                    auto s = d.toString;
                    auto parts = s.split("=");
                    if (parts.length != 2)
                        throw new Exception("too many values to unpack (expected 2)");
                    lst ~= checkVarType(parts[1], parts[0], row);
                }
    return kwDict("variables", Value(lst));
}

struct DbAttrs
{
    bool datistemplate;
    bool datallowconn;
}

/// `get_attributes_from_db_info(manager, kwargs)`
DbAttrs getAttributesFromDbInfo(ServerManager manager, Dict kwargs)
{
    if (kwargs.has("did") && manager.dbInfo.has(kwargs["did"].toString))
    {
        auto info = manager.dbInfo[kwargs["did"].toString];
        return DbAttrs(info.contains("datistemplate") ? info["datistemplate"].truthy : false,
                info.contains("datallowconn") ? info["datallowconn"].truthy : false);
    }
    return DbAttrs(false, true);
}

/// `make_object_name(name1, name2, label)`: "a_b_label" truncated to 63 characters.
string makeObjectName(string name1, string name2, string label)
{
    enum namedatalen = 63;
    string result = name1 ~ "_" ~ name2 ~ "_" ~ label;
    while (result.length > namedatalen)
    {
        if (name1.length > name2.length)
            name1 = name1[0 .. $ - 1];
        else
            name2 = name2[0 .. $ - 1];
        result = name1 ~ "_" ~ name2 ~ "_" ~ label;
    }
    return result;
}
