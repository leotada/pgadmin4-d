/// `constraints/foreign_key/utils.py`
module pgadmin.browser.server_groups.servers.databases.schemas.tables.constraints.foreign_key.utils;

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

string defaultTemplatePath(Connection conn) => "foreign_key/sql/#" ~ to!string(conn.manager.version_) ~ "#";

enum FKEY_PROPERTIES_SQL = "properties.sql";

/// `get_foreign_keys(conn, tid, fkid=None)` -> (status, rows)
Res getForeignKeys(Connection conn, Value tid, Value fkid = Value(null), string templatePath = null)
{
    if (templatePath.length == 0)
        templatePath = defaultTemplatePath(conn);
    auto r = conn.executeDict(renderTemplate(templatePath ~ "/" ~ FKEY_PROPERTIES_SQL, tv("tid", tid, "cid", fkid)));
    if (!r.ok)
        return r;
    foreach (fk; r.value["rows"].list.items)
    {
        // zip(confkey, conkey)
        Value[] keys;
        auto confkey = fk["confkey"].list.items;
        auto conkey = fk["conkey"].list.items;
        foreach (i; 0 .. (confkey.length < conkey.length ? confkey.length : conkey.length))
            keys ~= Value([confkey[i], conkey[i]]);
        auto c = conn.executeDict(renderTemplate(templatePath ~ "/get_constraint_cols.sql",
                tv("tid", tid, "keys", Value(keys), "confrelid", fk["confrelid"])));
        if (!c.ok)
            return c;
        Value[] columns;
        string[] cols;
        foreach (row; c.value["rows"].list.items)
        {
            columns ~= Value.dictOf("local_column", row["conattname"], "references", fk["confrelid"], "referenced",
                    row["confattname"], "references_table_name", fk["refnsp"].toString ~ "." ~ fk["reftab"].toString);
            cols ~= row["conattname"].toString;
        }
        fk["columns"] = Value(columns);
        if (!fkid.truthy)
        {
            string schema, table;
            getParent(conn, columns[0]["references"], schema, table);
            fk["remote_schema"] = Value(schema);
            fk["remote_table"] = Value(table);
        }
        auto coveringindex = searchCoveringindex(conn, tid, cols);
        fk["coveringindex"] = coveringindex;
        if (coveringindex.truthy)
        {
            fk["autoindex"] = Value(false);
            fk["hasindex"] = Value(true);
        }
        else
        {
            fk["autoindex"] = Value(true);
            fk["hasindex"] = Value(false);
        }
    }
    return Res(true, r.value["rows"]);
}

Value searchCoveringindex(Connection conn, Value tid, string[] cols, string templatePath = null)
{
    if (templatePath.length == 0)
        templatePath = defaultTemplatePath(conn);
    bool[string] want;
    foreach (c; cols)
        want[c] = true;
    auto r = conn.executeDict(renderTemplate(templatePath ~ "/get_constraints.sql", tv("tid", tid)));
    if (!r.ok)
        throw new ExecuteError(r.error);
    foreach (constraint; r.value["rows"].list.items)
    {
        auto rest = conn.executeDict(renderTemplate(templatePath ~ "/get_cols.sql",
                tv("cid", constraint["oid"], "colcnt", constraint["col_count"])));
        if (!rest.ok)
            throw new ExecuteError(rest.error);
        bool[string] have;
        foreach (row; rest.value["rows"].list.items)
            have[row["column"].toString.pyStrip("\"")] = true;
        bool same = want.length == have.length;
        if (same)
            foreach (k; want.byKey)
                if (!(k in have))
                {
                    same = false;
                    break;
                }
        if (same)
            return constraint["idxname"];
    }
    return Value(null);
}

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

string getDeleteSql(Connection conn, Value fkData, string templatePath = null)
{
    if (templatePath.length == 0)
        templatePath = defaultTemplatePath(conn);
    return renderTemplate(templatePath ~ "/delete.sql", tv("data", fkData, "conn", conn)).strip("\n");
}

Value getForeignKeySql(Connection conn, Value tid, Value data, string templatePath = null)
{
    if (templatePath.length == 0)
        templatePath = defaultTemplatePath(conn);
    string[] sql;
    if (data.contains("foreign_key"))
    {
        auto constraint = data["foreign_key"];
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

string getSql(Connection conn, Value data, Value tid, Value fkid, out Value name, string templatePath = null)
{
    if (templatePath.length == 0)
        templatePath = defaultTemplatePath(conn);
    string sql;
    if (!fkid.isNone)
    {
        name = data.contains("name") ? data["name"] : Value(null);
        auto r = conn.executeDict(renderTemplate(templatePath ~ "/" ~ FKEY_PROPERTIES_SQL, tv("tid", tid, "cid", fkid)));
        if (!r.ok)
            throw new ExecuteError(r.error);
        if (r.value["rows"].length == 0)
            throw new ObjectGone(gettext("Could not find the foreign key constraint in the table."));
        auto oldData = r.value["rows"][0];
        if (!data.contains("name"))
        {
            name = oldData["name"];
            data["name"] = name;
        }
        sql = renderTemplate(templatePath ~ "/update.sql", tv("data", data, "o_data", oldData, "conn", conn));
        if (data.contains("autoindex") && data["autoindex"].truthy && data.contains("coveringindex")
                && data["coveringindex"] != Value(""))
        {
            Value[] keys;
            auto confkey = oldData["confkey"].list.items;
            auto conkey = oldData["conkey"].list.items;
            foreach (i; 0 .. (confkey.length < conkey.length ? confkey.length : conkey.length))
                keys ~= Value([confkey[i], conkey[i]]);
            auto c = conn.executeDict(renderTemplate(templatePath ~ "/get_constraint_cols.sql",
                    tv("tid", tid, "keys", Value(keys), "confrelid", oldData["confrelid"])));
            if (!c.ok)
                throw new ExecuteError(c.error);
            Value[] columns;
            foreach (row; c.value["rows"].list.items)
                columns ~= Value.dictOf("local_column", row["conattname"], "references", oldData["confrelid"],
                        "referenced", row["confattname"]);
            data["columns"] = Value(columns);
            sql ~= renderTemplate(templatePath ~ "/create_index.sql", tv("data", data, "conn", conn));
        }
        return sql;
    }
    name = data.contains("name") ? data["name"] : Value(null);
    if (!data.contains("columns") || (data["columns"].isList && data["columns"].length < 1))
        return gettext("-- definition incomplete");
    if (data.dict.get("autoindex", Value(false)).truthy
            && (!data.contains("coveringindex") || data["coveringindex"] == Value("")))
        return gettext("-- definition incomplete");
    if (data["columns"][0].contains("references"))
    {
        string schema, table;
        getParent(conn, data["columns"][0]["references"], schema, table);
        checksForSchemaDiff(table, schema, data);
    }
    sql = renderTemplate(templatePath ~ "/create.sql", tv("data", data, "conn", conn));
    if (data.dict.get("autoindex", Value(false)).truthy)
        sql ~= renderTemplate(templatePath ~ "/create_index.sql", tv("data", data, "conn", conn));
    name = Value("");
    return sql;
}

private void checksForSchemaDiff(string table, string schema, Value data)
{
    if (schema.length && table.length)
    {
        data["remote_schema"] = Value(schema);
        data["remote_table"] = Value(table);
    }
    if (!data.contains("remote_schema"))
    {
        data["remote_schema"] = Value(null);
        if (data.contains("schema") && schema.length == 0)
            data["remote_schema"] = data["schema"];
    }
    if (!data.contains("remote_table"))
        data["remote_table"] = Value(null);
}

/// `get_fkey_dependencies(conn, tid)` -> (status, deps)
Res getFkeyDependencies(Connection conn, Value tid, string templatePath = null)
{
    if (templatePath.length == 0)
        templatePath = defaultTemplatePath(conn);
    auto r = conn.executeDict(renderTemplate(templatePath ~ "/" ~ FKEY_PROPERTIES_SQL, tv("tid", tid)));
    if (!r.ok)
        return r;
    Value[] deps;
    foreach (fk; r.value["rows"].list.items)
        deps ~= Value.dictOf("type", "table", "name", fk["refnsp"].toString ~ "." ~ fk["reftab"].toString);
    return Res(true, Value(deps));
}

/// `get_parent` of `foreign_key.utils` as used by the table code: (schema, table) of the referenced table.
void getParentOf(Connection conn, Value tid, out string schema, out string table)
{
    getParent(conn, tid, schema, table);
}
