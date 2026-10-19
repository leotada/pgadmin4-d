/// `constraints/exclusion_constraint/utils.py`
module pgadmin.browser.server_groups.servers.databases.schemas.tables.constraints.exclusion_constraint.utils;

import std.array : join;
import std.conv : to;
import std.string : strip;
import pgadmin.core.i18n;
import pgadmin.core.strutil;
import pgadmin.core.templates;
import pgadmin.core.value;
import pgadmin.db.driver;
import pgadmin.utils.exception;
import pgadmin.web.http;

string defaultTemplatePath(Connection conn) => "exclusion_constraint/sql/#" ~ to!string(conn.manager.version_) ~ "#";

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

private Value getColumns(Value res)
{
    Value[] columns;
    foreach (row; res["rows"].list.items)
    {
        immutable options = row["options"].integer;
        bool order = !(options & 1);
        bool nullsOrder = (options & 2) != 0;
        columns ~= Value.dictOf("column", row["coldef"].toString.pyStrip("\""), "oper_class", row["opcname"], "order", order,
                "nulls_order", nullsOrder, "operator", row["oprname"], "col_type", row["datatype"], "is_exp", row["is_exp"]);
    }
    return Value(columns);
}

Res getExclusionConstraints(Connection conn, Value did, Value tid, Value exid = Value(null), string templatePath = null)
{
    if (templatePath.length == 0)
        templatePath = defaultTemplatePath(conn);
    auto r = conn.executeDict(renderTemplate(templatePath ~ "/properties.sql", tv("did", did, "tid", tid, "cid", exid)));
    if (!r.ok)
        return r;
    foreach (ex; r.value["rows"].list.items)
    {
        auto c = conn.executeDict(renderTemplate(templatePath ~ "/get_constraint_cols.sql",
                tv("cid", ex["oid"], "colcnt", ex["col_count"])));
        if (!c.ok)
            return c;
        ex["columns"] = getColumns(c.value);
        if (conn.manager.version_ >= 110000)
        {
            auto inc = conn.executeDict(renderTemplate(templatePath ~ "/get_constraint_include.sql", tv("cid", ex["oid"])));
            if (!inc.ok)
                return inc;
            Value[] include;
            foreach (col; inc.value["rows"].list.items)
                include ~= col["colname"];
            ex["include"] = Value(include);
        }
        if (ex.dict.get("amname", Value("")) == Value(""))
            ex["amname"] = Value("btree");
    }
    return Res(true, r.value["rows"]);
}

Value getExclusionConstraintSql(Connection conn, Value did, Value tid, Value data, string templatePath = null)
{
    if (templatePath.length == 0)
        templatePath = defaultTemplatePath(conn);
    string[] sql;
    if (data.contains("exclude_constraint"))
    {
        auto constraint = data["exclude_constraint"];
        if (constraint.contains("deleted"))
            foreach (c; constraint["deleted"].iterItems())
            {
                c["schema"] = data["schema"];
                c["table"] = data["name"];
                sql ~= renderTemplate(templatePath ~ "/delete.sql", tv("data", c, "conn", conn)).strip("\n");
            }
        if (constraint.contains("changed"))
            foreach (c; constraint["changed"].iterItems())
            {
                c["schema"] = data["schema"];
                c["table"] = data["name"];
                Value name;
                sql ~= getSql(conn, c, did, tid, c["oid"], name).strip("\n");
            }
        if (constraint.contains("added"))
            foreach (c; constraint["added"].iterItems())
            {
                c["schema"] = data["schema"];
                c["table"] = data["name"];
                Value name;
                sql ~= getSql(conn, c, did, tid, Value(null), name).strip("\n");
            }
    }
    return sql.length ? Value(sql.join("\n\n")) : Value(null);
}

string getSql(Connection conn, Value data, Value did, Value tid, Value exid, out Value name, string templatePath = null)
{
    if (templatePath.length == 0)
        templatePath = defaultTemplatePath(conn);
    name = data.contains("name") ? data["name"] : Value(null);
    if (!exid.isNone)
    {
        auto r = conn.executeDict(renderTemplate(templatePath ~ "/properties.sql", tv("did", did, "tid", tid, "cid", exid)));
        if (!r.ok)
            throw new ExecuteError(r.error);
        if (r.value["rows"].length == 0)
            throw new ObjectGone(gettext("Could not find the exclusion constraint in the table."));
        auto oldData = r.value["rows"][0];
        if (!data.contains("name"))
        {
            name = oldData["name"];
            data["name"] = name;
        }
        return renderTemplate(templatePath ~ "/update.sql", tv("data", data, "o_data", oldData, "conn", conn));
    }
    if (!data.contains("columns") || (data["columns"].isList && data["columns"].length < 1))
        return gettext("-- definition incomplete");
    return renderTemplate(templatePath ~ "/create.sql", tv("data", data, "conn", conn));
}

/// `get_access_methods(conn)` -> [{label, value}]
Value getAccessMethods(Connection conn, string templatePath = null)
{
    if (templatePath.length == 0)
        templatePath = defaultTemplatePath(conn);
    auto r = conn.execute2darray(renderTemplate(templatePath ~ "/get_access_methods.sql"));
    if (!r.ok)
        throw new HTTPException(internalServerError(r.error));
    Value[] res;
    foreach (row; r.value["rows"].list.items)
        res ~= Value.dictOf("label", row["amname"], "value", row["amname"]);
    return Value(res);
}

Value getOperClass(Connection conn, Value indextype, string templatePath = null)
{
    if (templatePath.length == 0)
        templatePath = defaultTemplatePath(conn);
    auto r = conn.execute2darray(renderTemplate(templatePath ~ "/get_oper_class.sql", tv("indextype", indextype, "conn", conn)));
    if (!r.ok)
        throw new HTTPException(internalServerError(r.error));
    Value[] result;
    foreach (row; r.value["rows"].list.items)
        result ~= Value([row["opcname"], row["opcname"]]);
    return Value(result);
}

Value getOperator(Connection conn, Value coltype, bool showSysobj, string templatePath = null)
{
    if (templatePath.length == 0)
        templatePath = defaultTemplatePath(conn);
    auto r = conn.execute2darray(renderTemplate(templatePath ~ "/get_operator.sql",
            tv("type", coltype, "show_sysobj", showSysobj, "conn", conn)));
    if (!r.ok)
        throw new HTTPException(internalServerError(r.error));
    Value[] result;
    foreach (row; r.value["rows"].list.items)
        result ~= Value([row["oprname"], row["oprname"]]);
    return Value(result);
}
