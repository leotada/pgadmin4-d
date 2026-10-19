/// `servers/pgagent/utils.d`: pgAgent formatting helpers.
module pgadmin.browser.server_groups.servers.pgagent.utils;

import std.string : replace;
import pgadmin.core.templates : renderTemplate, tv;
import pgadmin.core.value;
import pgadmin.db.driver : Connection, Res;

Value formatBooleanArray(Value value)
{
    if (value.isString)
        return Value(value.toString.replace("[", "{").replace("]", "}"));
    return value;
}

Value formatScheduleData(Value data)
{
    if (!data.isDict)
        return data;
    foreach (field; ["jscminutes", "jschours", "jscweekdays", "jscmonthdays", "jscmonths"])
    {
        if (data.contains(field) && !data[field].isNone)
            data[field] = formatBooleanArray(data[field]);
    }
    return data;
}

Res formatStepData(Value jobId, Value data, bool hasConnStr, Connection conn, string templatePath)
{
    if (!data.isDict)
        return Res(true, Value(null));
    if (!data.contains("jstconntype") && (data.contains("jstdbname") || data.contains("jstconnstr")) && hasConnStr)
    {
        auto sql = renderTemplate(templatePath ~ "/steps.sql",
                tv("jid", jobId, "jstid", data["jstid"], "conn", conn, "has_connstr", Value(hasConnStr)));
        auto r = conn.executeDict(sql);
        if (!r.ok)
            return r;
        if (r.value["rows"].length > 0)
        {
            auto row = r.value["rows"][0];
            data["jstconntype"] = row["jstconntype"];
            if (row["jstconntype"].truthy)
                data["jstdbname"] = data.dict.get("jstdbname", row["jstdbname"]);
            else
                data["jstconnstr"] = data.dict.get("jstconnstr", row["jstconnstr"]);
        }
    }
    return Res(true, Value(null));
}
