/// `constraints/index_constraint/utils.py`: primary key and unique constraints.
module pgadmin.browser.server_groups.servers.databases.schemas.tables.constraints.index_constraint.utils;

import std.algorithm : min;
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

string defaultTemplatePath(Connection conn) => "index_constraint/sql/#" ~ to!string(conn.manager.version_) ~ "#";

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

/// `get_index_constraints(conn, did, tid, ctype, cid=None)` -> (status, rows)
Res getIndexConstraints(Connection conn, Value did, Value tid, string ctype, Value cid = Value(null), string templatePath = null)
{
    if (templatePath.length == 0)
        templatePath = defaultTemplatePath(conn);
    auto r = conn.executeDict(renderTemplate(templatePath ~ "/properties.sql",
            tv("did", did, "tid", tid, "cid", cid, "constraint_type", ctype)));
    if (!r.ok)
        return r;
    foreach (idxCons; r.value["rows"].list.items)
    {
        auto c = conn.executeDict(renderTemplate(templatePath ~ "/get_constraint_cols.sql",
                tv("cid", idxCons["oid"], "colcnt", idxCons["col_count"])));
        if (!c.ok)
            return c;
        Value[] columns;
        foreach (row; c.value["rows"].list.items)
            columns ~= Value.dictOf("column", row["column"].toString.pyStrip("\""));
        idxCons["columns"] = Value(columns);
        if (conn.manager.version_ >= 110000)
        {
            auto inc = conn.executeDict(renderTemplate(templatePath ~ "/get_constraint_include.sql", tv("cid", idxCons["oid"])));
            if (!inc.ok)
                return inc;
            Value[] include;
            foreach (col; inc.value["rows"].list.items)
                include ~= col["colname"];
            idxCons["include"] = Value(include);
        }
    }
    return Res(true, r.value["rows"]);
}

private void sqlToDeleteConstraints(Value data, Value constraint, ref string[] sql, string templatePath, Connection conn)
{
    if (!constraint.contains("deleted"))
        return;
    foreach (c; constraint["deleted"].iterItems())
    {
        // `list(map(lambda x, y: ..., c['columns'], data['columns_to_be_dropped']))`: only its length matters
        size_t delCols;
        if (data.contains("columns_to_be_dropped"))
            delCols = min(c["columns"].length, data["columns_to_be_dropped"].length);
        if (delCols == 0)
        {
            c["schema"] = data["schema"];
            c["table"] = data["name"];
            sql ~= renderTemplate(templatePath ~ "/delete.sql", tv("data", c, "conn", conn)).strip("\n");
        }
    }
}

private void sqlToChangeConstraints(Value did, Value tid, string ctype, Value data, Value constraint, ref string[] sql,
        Connection conn)
{
    if (!constraint.contains("changed"))
        return;
    foreach (c; constraint["changed"].iterItems())
    {
        c["schema"] = data["schema"];
        c["table"] = data["name"];
        Value name;
        auto modified = getSql(conn, c, did, tid, ctype, c["oid"], name);
        if (modified.length)
            sql ~= modified.strip("\n");
    }
}

private void sqlToAddConstraints(Value did, Value tid, string ctype, Value data, Value constraint, ref string[] sql,
        Connection conn)
{
    if (!constraint.contains("added"))
        return;
    foreach (c; constraint["added"].iterItems())
    {
        c["schema"] = data["schema"];
        c["table"] = data["name"];
        Value name;
        sql ~= getSql(conn, c, did, tid, ctype, Value(null), name).strip("\n");
    }
}

/// `get_index_constraint_sql(conn, did, tid, data)`: the SQL, or None.
Value getIndexConstraintSql(Connection conn, Value did, Value tid, Value data, string templatePath = null)
{
    if (templatePath.length == 0)
        templatePath = defaultTemplatePath(conn);
    string[] sql;
    foreach (pair; [["p", "primary_key"], ["u", "unique_constraint"]])
        if (data.contains(pair[1]))
        {
            auto constraint = data[pair[1]];
            sqlToDeleteConstraints(data, constraint, sql, templatePath, conn);
            sqlToChangeConstraints(did, tid, pair[0], data, constraint, sql, conn);
            sqlToAddConstraints(did, tid, pair[0], data, constraint, sql, conn);
        }
    return sql.length ? Value(sql.join("\n\n")) : Value(null);
}

private bool isKeyStr(string key, Value data) => data[key].isString && data[key] != Value("");

private bool checkRequiredArgs(Value data)
{
    foreach (param; ["columns", "index"])
        if (data.contains(param) && (isKeyStr(param, data) || (data[param].isList && data[param].length > 0)))
            return true;
    return false;
}

string getSql(Connection conn, Value data, Value did, Value tid, string ctype, Value cid, out Value name,
        string templatePath = null)
{
    if (templatePath.length == 0)
        templatePath = defaultTemplatePath(conn);
    name = data.contains("name") ? data["name"] : Value(null);
    if (!cid.isNone)
    {
        auto r = conn.executeDict(renderTemplate(templatePath ~ "/properties.sql",
                tv("did", did, "tid", tid, "cid", cid, "constraint_type", ctype)));
        if (!r.ok)
            throw new ExecuteError(r.error);
        if (r.value["rows"].length == 0)
            throw new ObjectGone(gettext("Could not find the constraint in the table."));
        auto oldData = r.value["rows"][0];
        if (!data.contains("name"))
        {
            name = oldData["name"];
            data["name"] = name;
        }
        return renderTemplate(templatePath ~ "/update.sql", tv("data", data, "o_data", oldData, "conn", conn));
    }
    if (!checkRequiredArgs(data))
        return gettext("-- definition incomplete");
    return renderTemplate(templatePath ~ "/create.sql", tv("data", data, "conn", conn, "constraint_name",
            ctype == "p" ? "PRIMARY KEY" : "UNIQUE"));
}
