/// `tables/triggers/utils.py`
module pgadmin.browser.server_groups.servers.databases.schemas.tables.triggers.utils;

import std.array : join, split;
import std.conv : to;
import std.string : strip;
import pgadmin.browser.server_groups.servers.databases.schemas.utils : triggerDefinition;
import pgadmin.core.i18n;
import pgadmin.core.templates;
import pgadmin.core.value;
import pgadmin.db.driver;
import pgadmin.db.quoting;
import pgadmin.utils.exception;
import pgadmin.web.http;

string defaultTemplatePath(Connection conn)
    => "triggers/sql/" ~ conn.manager.serverType ~ "/#" ~ to!string(conn.manager.version_) ~ "#";

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

Value getTriggerFunctionAndColumns(Connection conn, Value data, Value tid, bool showSystemObjects,
        bool withoutSchema = false, string templatePath = null)
{
    if (templatePath.length == 0)
        templatePath = defaultTemplatePath(conn);
    auto r = conn.executeDict(renderTemplate(templatePath ~ "/get_triggerfunctions.sql",
            tv("tgfoid", data["tgfoid"], "show_system_objects", showSystemObjects, "without_schema", withoutSchema)));
    if (!r.ok)
        throw new HTTPException(internalServerError(r.error));
    if (r.value.contains("rows") && r.value["rows"].length > 0 && r.value["rows"][0].contains("tfunctions"))
        data["tfunction"] = r.value["rows"][0]["tfunctions"];
    if (data["custom_tgargs"].length > 0)
    {
        string[] formatted;
        foreach (arg; data["custom_tgargs"].iterItems())
            formatted ~= qtLiteral(arg, false);
        data["tgargs"] = Value(formatted.join(", "));
    }
    else
        data["tgargs"] = Value(null);
    if (data["tgattr"].toString.length >= 1)
        data["columns"] = getColumnDetails(conn, tid, data["tgattr"].toString.split(" ").join(", "));
    return data;
}

private string checkSchemaDiffSql(bool isSchemaDiff, Value data, Value oldData, string templatePath, Connection conn)
{
    string dropSql;
    if (isSchemaDiff)
    {
        if (!data.contains("table"))
            data["table"] = oldData["relname"];
        if (!data.contains("schema"))
            data["schema"] = oldData["nspname"];
        bool isDropTrigger;
        foreach (key; ["prosrc", "is_row_trigger", "evnt_insert", "evnt_delete", "evnt_update", "fires", "tgdeferrable",
                "whenclause", "tfunction", "tgargs", "columns", "is_constraint_trigger", "tginitdeferred"])
            if (data.contains(key))
            {
                isDropTrigger = true;
                break;
            }
        if (isDropTrigger)
        {
            auto tmp = Value.dictOf("name", data["name"], "nspname", oldData["nspname"], "relname", oldData["relname"]);
            dropSql = renderTemplate(templatePath ~ "/delete.sql", tv("data", tmp, "conn", conn));
        }
    }
    return dropSql;
}

/// `get_sql(conn, data=, tid=, trid=, ...)`: the SQL; `name` is the trigger name.
string getSql(Connection conn, Value data, Value tid, Value trid, Value datlastsysoid, bool showSystemObjects,
        out Value name, bool isSchemaDiff = false, string templatePath = null)
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
            throw new ObjectGone(gettext("Could not find the trigger in the table."));
        auto oldData = Value(r.value["rows"][0].dict.copy());
        if (!data.contains("name"))
        {
            name = oldData["name"];
            data["name"] = name;
        }
        auto dropSql = checkSchemaDiffSql(isSchemaDiff, data, oldData, templatePath, conn);
        oldData = getTriggerFunctionAndColumns(conn, oldData, tid, showSystemObjects);
        oldData = triggerDefinition(oldData);
        if (oldData.contains("lanname") && oldData["lanname"] == Value("edbspl"))
            data["lanname"] = oldData["lanname"];
        if (oldData.contains("tfunction") && oldData["tfunction"] == Value("Inline EDB-SPL"))
            data["tfunction"] = oldData["tfunction"];
        auto sql = renderTemplate(templatePath ~ "/update.sql", tv("data", data, "o_data", oldData, "conn", conn));
        if (isSchemaDiff)
            sql = dropSql ~ "\n" ~ sql;
        return sql;
    }
    foreach (arg; ["name", "tfunction"])
        if (!data.contains(arg))
            return gettext("-- definition incomplete");
    return renderTemplate(templatePath ~ "/create.sql", tv("data", data, "conn", conn));
}

string getReverseEngineeredSql(Connection conn, string schema, string table, Value tid, Value trid, Value datlastsysoid,
        bool showSystemObjects, string templatePath = null, bool withHeader = true)
{
    if (templatePath.length == 0)
        templatePath = defaultTemplatePath(conn);
    auto r = conn.executeDict(renderTemplate(templatePath ~ "/properties.sql",
            tv("tid", tid, "trid", trid, "datlastsysoid", datlastsysoid)));
    if (!r.ok)
        throw new ExecuteError(r.error);
    if (r.value["rows"].length == 0)
        throw new ObjectGone(gettext("Could not find the trigger in the table."));
    auto data = Value(r.value["rows"][0].dict.copy());
    data["schema"] = Value(schema);
    data["table"] = Value(table);
    data = getTriggerFunctionAndColumns(conn, data, tid, showSystemObjects);
    data = triggerDefinition(data);
    Value name;
    auto sql = getSql(conn, data, tid, Value(null), datlastsysoid, showSystemObjects, name);
    if (withHeader)
    {
        auto header = "-- Trigger: " ~ data["name"].toString ~ "\n\n-- ";
        header ~= renderTemplate(templatePath ~ "/delete.sql", tv("data", data, "conn", conn));
        sql = header ~ "\n\n" ~ sql.strip("\n");
    }
    else
        sql = sql.strip("\n");
    if (data["is_enable_trigger"] != Value("O"))
    {
        sql ~= "\n\n";
        sql ~= renderTemplate(templatePath ~ "/enable_disable_trigger.sql", tv("data", data, "conn", conn));
    }
    return sql;
}
