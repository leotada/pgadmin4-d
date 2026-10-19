/// `tables/compound_triggers/utils.py` (EDB Postgres Advanced Server)
module pgadmin.browser.server_groups.servers.databases.schemas.tables.compound_triggers.utils;

import std.array : join, split;
import std.conv : to;
import std.string : strip;
import pgadmin.browser.server_groups.servers.databases.schemas.utils : triggerDefinition;
import pgadmin.core.i18n;
import pgadmin.core.templates;
import pgadmin.core.value;
import pgadmin.db.driver;
import pgadmin.utils.exception;
import pgadmin.web.http;

string defaultTemplatePath(Connection conn)
    => "compound_triggers/sql/" ~ conn.manager.serverType ~ "/#" ~ to!string(conn.manager.version_) ~ "#";

void getParent(Connection conn, Value tid, out string schema, out string table, string templatePath = null)
{
    if (templatePath.length == 0)
        templatePath = defaultTemplatePath(conn);
    auto r = conn.execute2darray(renderTemplate(templatePath ~ "/get_parent.sql", tv("tid", tid)));
    if (!r.ok)
        throw new ExecuteError(r.error);
    if (r.value.contains("rows") && r.value["rows"].length > 0)
    {
        schema = r.value["rows"][0]["schema"].toString;
        table = r.value["rows"][0]["table"].toString;
    }
}

Value getColumnDetails(Connection conn, Value tid, string clist, string templatePath = null)
{
    if (templatePath.length == 0)
        templatePath = defaultTemplatePath(conn);
    auto r = conn.execute2darray(renderTemplate(templatePath ~ "/get_columns.sql", tv("tid", tid, "clist", clist)));
    if (!r.ok)
        throw new HTTPException(internalServerError(r.error));
    Value[] columns;
    foreach (row; r.value["rows"].list.items)
        columns ~= row["name"];
    return Value(columns);
}

string getSql(Connection conn, Value data, Value tid, Value trid, Value datlastsysoid, out Value name,
        string templatePath = null)
{
    if (templatePath.length == 0)
        templatePath = defaultTemplatePath(conn);
    name = data.contains("name") ? data["name"] : Value(null);
    if (!trid.isNone)
    {
        auto r = conn.executeDict(renderTemplate(templatePath ~ "/properties.sql",
                tv("tid", tid, "trid", trid, "datlastsysoid", datlastsysoid)));
        if (!r.ok)
            throw new ExecuteError(r.error);
        if (r.value["rows"].length == 0)
            throw new ObjectGone(gettext("Could not find the compound trigger in the table."));
        auto oldData = Value(r.value["rows"][0].dict.copy());
        if (!data.contains("name"))
        {
            name = oldData["name"];
            data["name"] = name;
        }
        if (oldData["tgattr"].toString.length > 1)
            oldData["columns"] = getColumnDetails(conn, tid, oldData["tgattr"].toString.split(" ").join(", "));
        oldData = triggerDefinition(oldData);
        return renderTemplate(templatePath ~ "/update.sql", tv("data", data, "o_data", oldData, "conn", conn));
    }
    if (!data.contains("name"))
        return gettext("-- definition incomplete");
    return renderTemplate(templatePath ~ "/create.sql", tv("data", data, "conn", conn));
}

string getReverseEngineeredSql(Connection conn, string schema, string table, Value tid, Value trid, Value datlastsysoid,
        string templatePath = null)
{
    if (templatePath.length == 0)
        templatePath = defaultTemplatePath(conn);
    auto r = conn.executeDict(renderTemplate(templatePath ~ "/properties.sql",
            tv("tid", tid, "trid", trid, "datlastsysoid", datlastsysoid)));
    if (!r.ok)
        throw new ExecuteError(r.error);
    if (r.value["rows"].length == 0)
        throw new ObjectGone(gettext("Could not find the compound trigger in the table."));
    auto data = Value(r.value["rows"][0].dict.copy());
    data["schema"] = Value(schema);
    data["table"] = Value(table);
    if (data["tgattr"].toString.length >= 1)
        data["columns"] = getColumnDetails(conn, tid, data["tgattr"].toString.split(" ").join(", "));
    data = triggerDefinition(data);
    Value name;
    auto sql = getSql(conn, data, tid, Value(null), datlastsysoid, name);
    auto header = "-- Compound Trigger: " ~ data["name"].toString ~ "\n\n-- ";
    header ~= renderTemplate(templatePath ~ "/delete.sql", tv("data", data, "conn", conn));
    sql = header ~ "\n\n" ~ sql.strip("\n");
    if (data["is_enable_trigger"] != Value("O"))
    {
        sql ~= "\n\n";
        sql ~= renderTemplate(templatePath ~ "/enable_disable_trigger.sql", tv("data", data, "conn", conn));
    }
    return sql;
}
