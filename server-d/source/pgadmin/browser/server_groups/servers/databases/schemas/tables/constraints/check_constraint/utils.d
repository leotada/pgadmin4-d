/// `constraints/check_constraint/utils.py`
module pgadmin.browser.server_groups.servers.databases.schemas.tables.constraints.check_constraint.utils;

import std.array : join;
import std.conv : to;
import std.string : strip;
import pgadmin.core.i18n;
import pgadmin.core.templates;
import pgadmin.core.value;
import pgadmin.db.driver;
import pgadmin.utils.exception;
import pgadmin.web.http;

string defaultTemplatePath(Connection conn) => "check_constraint/sql/#" ~ to!string(conn.manager.version_) ~ "#";

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

Res getCheckConstraints(Connection conn, Value tid, Value cid = Value(null), string templatePath = null)
{
    if (templatePath.length == 0)
        templatePath = defaultTemplatePath(conn);
    auto r = conn.executeDict(renderTemplate(templatePath ~ "/properties.sql", tv("tid", tid, "cid", cid)));
    if (!r.ok)
        return r;
    return Res(true, r.value["rows"]);
}

Value getCheckConstraintSql(Connection conn, Value tid, Value data, string templatePath = null)
{
    if (templatePath.length == 0)
        templatePath = defaultTemplatePath(conn);
    string[] sql;
    if (data.contains("check_constraint"))
    {
        auto constraint = data["check_constraint"];
        if (constraint.contains("deleted"))
            foreach (c; constraint["deleted"].iterItems())
            {
                c["schema"] = data["schema"];
                c["nspname"] = data["schema"];
                c["table"] = data["name"];
                sql ~= renderTemplate(templatePath ~ "/delete.sql", tv("data", c, "conn", conn)).strip("\n");
            }
        if (constraint.contains("changed"))
            foreach (c; constraint["changed"].iterItems())
            {
                c["schema"] = data["schema"];
                c["table"] = data["name"];
                Value name;
                sql ~= getSql(conn, c, tid, c["oid"], name).strip("\n");
            }
        if (constraint.contains("added"))
            foreach (c; constraint["added"].iterItems())
            {
                c["schema"] = data["schema"];
                c["table"] = data["name"];
                Value name;
                sql ~= getSql(conn, c, tid, Value(null), name).strip("\n");
            }
    }
    return sql.length ? Value(sql.join("\n\n")) : Value(null);
}

string getSql(Connection conn, Value data, Value tid, Value cid, out Value name, string templatePath = null)
{
    if (templatePath.length == 0)
        templatePath = defaultTemplatePath(conn);
    name = data.contains("name") ? data["name"] : Value(null);
    if (!cid.isNone)
    {
        auto r = conn.executeDict(renderTemplate(templatePath ~ "/properties.sql", tv("tid", tid, "cid", cid)));
        if (!r.ok)
            throw new ExecuteError(r.error);
        if (r.value["rows"].length == 0)
            throw new ObjectGone(gettext("Could not find the check constraint in the table."));
        auto oldData = r.value["rows"][0];
        if (!data.contains("name"))
        {
            name = oldData["name"];
            data["name"] = name;
        }
        return renderTemplate(templatePath ~ "/update.sql", tv("data", data, "o_data", oldData, "conn", conn));
    }
    if (!data.contains("consrc") || (data["consrc"].isList && data["consrc"].length < 1))
        return gettext("-- definition incomplete");
    return renderTemplate(templatePath ~ "/create.sql", tv("data", data, "conn", conn));
}
