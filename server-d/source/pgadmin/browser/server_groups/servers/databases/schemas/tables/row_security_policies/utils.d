/// `tables/row_security_policies/utils.py`
module pgadmin.browser.server_groups.servers.databases.schemas.tables.row_security_policies.utils;

import std.conv : to;
import pgadmin.core.i18n;
import pgadmin.core.templates;
import pgadmin.core.value;
import pgadmin.db.driver;
import pgadmin.utils.exception;
import pgadmin.web.http;

string defaultTemplatePath(Connection conn) => "row_security_policies/sql/#" ~ to!string(conn.manager.version_) ~ "#";

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

string getSql(Connection conn, Value data, Value scid, Value plid, Value policyTableId, string schema, string table,
        out Value name, string templatePath = null)
{
    if (templatePath.length == 0)
        templatePath = defaultTemplatePath(conn);
    Value oldData = Value(null);
    string sql;
    if (!plid.isNone)
    {
        auto r = conn.executeDict(renderTemplate(templatePath ~ "/properties.sql",
                tv("schema", schema, "plid", plid, "scid", scid, "policy_table_id", policyTableId)));
        if (!r.ok)
            throw new HTTPException(internalServerError(r.error));
        if (r.value["rows"].length == 0)
            throw new ObjectGone(gettext("Could not find the policy in the table."));
        oldData = Value(r.value["rows"][0].dict.copy());
        oldData["schema"] = Value(schema);
        oldData["table"] = Value(table);
        sql = renderTemplate(templatePath ~ "/update.sql", tv("data", data, "o_data", oldData, "conn", conn));
    }
    else
    {
        data["schema"] = Value(schema);
        data["table"] = Value(table);
        sql = renderTemplate(templatePath ~ "/create.sql", tv("data", data, "conn", conn));
    }
    if (!data.contains("name") && oldData.isNone)
        throw new Exception("cannot access local variable 'old_data' where it is not associated with a value");
    name = data.contains("name") ? data["name"] : oldData["name"];
    return sql;
}

string getReverseEngineeredSql(Connection conn, string schema, string table, Value scid, Value plid, Value policyTableId,
        Value datlastsysoid, string templatePath = null, bool withHeader = true)
{
    if (templatePath.length == 0)
        templatePath = defaultTemplatePath(conn);
    auto r = conn.executeDict(renderTemplate(templatePath ~ "/properties.sql",
            tv("plid", plid, "scid", scid, "policy_table_id", policyTableId)));
    if (!r.ok)
        throw new ExecuteError(r.error);
    if (r.value["rows"].length == 0)
        throw new ObjectGone(gettext("Could not find the policy in the table."));
    auto data = Value(r.value["rows"][0].dict.copy());
    data["schema"] = Value(schema);
    data["table"] = Value(table);
    Value name;
    auto sql = getSql(conn, data, scid, Value(null), policyTableId, schema, table, name);
    if (withHeader)
    {
        auto header = "-- POLICY: " ~ data["name"].toString ~ "\n\n-- ";
        header ~= renderTemplate(templatePath ~ "/delete.sql", tv("policy_name", data["name"], "result", data));
        sql = header ~ "\n\n" ~ sql;
    }
    return sql;
}
