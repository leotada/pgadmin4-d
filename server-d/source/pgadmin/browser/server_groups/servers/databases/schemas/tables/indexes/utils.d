/// `tables/indexes/utils.py`
module pgadmin.browser.server_groups.servers.databases.schemas.tables.indexes.utils;

import std.array : join, split;
import std.conv : to;
import std.string : startsWith, endsWith, strip;
import pgadmin.core.i18n;
import pgadmin.core.strutil;
import pgadmin.core.templates;
import pgadmin.core.value;
import pgadmin.db.driver;
import pgadmin.utils.exception;
import pgadmin.web.http;

enum AUTO_CREATE_INDEX_MSG = "-- This constraint index is automatically generated from a constraint with an identical "
    ~ "name.\n-- For more details, refer to the Constraints node. Note that this type of index is only visible \n-- when "
    ~ "the 'Show system objects?' is set to True in the Preferences.\n\n";

string defaultTemplatePath(Connection conn) => "indexes/sql/#" ~ to!string(conn.manager.version_) ~ "#";

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

private string columnPropertyDisplayData(Value row, string colStr, Value data)
{
    if (row["collnspname"].truthy)
        colStr ~= " COLLATE " ~ row["collnspname"].toString;
    if (row["opcname"].truthy)
        colStr ~= " " ~ row["opcname"].toString;
    if (data.contains("amname") && data["amname"] == Value("btree"))
    {
        colStr ~= " " ~ row["options"][0].toString;
        colStr ~= " " ~ row["options"][1].toString;
    }
    return colStr;
}

Value getColumnDetails(Connection conn, Value idx, Value data, string mode = "properties", string templatePath = null)
{
    if (templatePath.length == 0)
        templatePath = defaultTemplatePath(conn);
    auto r = conn.execute2darray(renderTemplate(templatePath ~ "/column_details.sql", tv("idx", idx)));
    if (!r.ok)
        throw new HTTPException(internalServerError(r.error));
    // keep the last of equal rows
    auto all = r.value["rows"].list.items;
    Value[] rows;
    foreach (n, i; all)
    {
        bool later;
        foreach (j; all[n + 1 .. $])
            if (i == j)
            {
                later = true;
                break;
            }
        if (!later)
            rows ~= i;
    }
    Value[] columns;
    string[] cols;
    foreach (row; rows)
    {
        auto colsData = Value.dictOf("colname", mode == "create" ? row["attdef"].toString : row["attdef"].toString.pyStrip("\""),
                "collspcname", row["collnspname"], "op_class", row["opcname"], "col_num", row["attnum"],
                "is_exp", row["is_exp"], "statistics", row["statistics"]);
        if (data.contains("amname") && data["amname"] == Value("btree"))
        {
            colsData["sort_order"] = Value(row["options"][0] == Value("DESC"));
            colsData["nulls"] = Value(row["options"][1].toString.split(" ")[1] == "FIRST");
        }
        columns ~= colsData;
        cols ~= columnPropertyDisplayData(row, row["attdef"].toString, data);
    }
    data["columns"] = Value(columns);
    data["columns_csv"] = Value(cols.join(", "));
    return data;
}

Value getIncludeDetails(Connection conn, Value idx, Value data, string templatePath = null)
{
    if (templatePath.length == 0)
        templatePath = defaultTemplatePath(conn);
    auto r = conn.execute2darray(renderTemplate(templatePath ~ "/include_details.sql", tv("idx", idx)));
    if (!r.ok)
        throw new HTTPException(internalServerError(r.error));
    Value[] include;
    foreach (col; r.value["rows"].list.items)
        include ~= col["colname"];
    data["include"] = Value(include);
    return data;
}

private string createSql(Value data, string templatePath, Connection conn, Value mode, Value name, bool ifExistsFlag)
{
    bool err;
    if (data["columns"].length < 1)
        err = true;
    if (!data.contains("columns"))
        err = true;
    if (err)
        return gettext("-- definition incomplete");
    auto sql = renderTemplate(templatePath ~ "/create.sql", tv("data", data, "conn", conn, "mode", mode,
            "add_not_exists_clause", ifExistsFlag));
    sql ~= "\n";
    sql ~= renderTemplate(templatePath ~ "/alter.sql", tv("data", data, "conn", conn));
    return sql;
}

private void columnDetailsToUpdate(Value oldData, Value data, out Value[] updateColumnData, out bool updateColumn)
{
    if (data.contains("columns") && data["columns"].contains("changed"))
        foreach (col1; oldData["columns"].iterItems())
            foreach (col2; data["columns"]["changed"].iterItems())
                if (col1["col_num"] == col2["col_num"] && col1["statistics"] != col2["statistics"])
                {
                    updateColumnData ~= col2;
                    updateColumn = true;
                    break;
                }
}

string getSql(Connection conn, Value data, Value did, Value tid, Value idx, Value datlastsysoid, out Value name,
        Value mode = Value(null), bool ifExistsFlag = false, bool showSysObj = false, string templatePath = null)
{
    if (templatePath.length == 0)
        templatePath = defaultTemplatePath(conn);
    name = data.contains("name") ? data["name"] : Value(null);
    if (!data.dict.get("dependsonextensions", Value(null)).truthy && data.dict.get("dependsonextensions", Value(null)).isNone)
        data["dependsonextensions"] = Value.newList();
    else if (data.dict.get("dependsonextensions", Value(null)).isNone)
        data["dependsonextensions"] = Value.newList();
    if (!idx.isNone)
    {
        auto r = conn.executeDict(renderTemplate(templatePath ~ "/properties.sql",
                tv("did", did, "tid", tid, "idx", idx, "datlastsysoid", datlastsysoid, "show_sys_objects", showSysObj)));
        if (!r.ok)
            throw new HTTPException(internalServerError(r.error));
        if (r.value["rows"].length == 0)
            throw new ObjectGone(gettext("Could not find the index in the table."));
        auto oldData = Value(r.value["rows"][0].dict.copy());
        oldData = getColumnDetails(conn, idx, oldData);
        Value[] updateColumnData;
        bool updateColumn;
        columnDetailsToUpdate(oldData, data, updateColumnData, updateColumn);
        foreach (key; ["using", "withcheck"])
            if (oldData.contains(key) && !oldData[key].isNone)
            {
                auto s = oldData[key].toString;
                if (s.startsWith("(") && s.endsWith(")"))
                    oldData[key] = Value(s[1 .. $ - 1]);
            }
        if (oldData.dict.get("dependsonextensions", Value(null)).isNone)
            oldData["dependsonextensions"] = Value.newList();
        if (!data.contains("name"))
        {
            name = oldData["name"];
            data["name"] = name;
        }
        return renderTemplate(templatePath ~ "/update.sql", tv("data", data, "o_data", oldData, "conn", conn,
                "update_column_data", Value(updateColumnData), "update_column", updateColumn));
    }
    return createSql(data, templatePath, conn, mode, name, ifExistsFlag);
}

string[] getStorageParams(string amname)
{
    switch (amname)
    {
    case "btree": return ["fillfactor", "deduplicate_items"];
    case "hash": return ["fillfactor"];
    case "gist": return ["fillfactor", "buffering"];
    case "gin": return ["fastupdate", "gin_pending_list_limit"];
    case "spgist": return ["fillfactor"];
    case "brin": return ["pages_per_range", "autosummarize"];
    case "ivfflat": return ["lists"];
    default: return null;
    }
}

string getReverseEngineeredSql(Connection conn, string schema, string table, Value did, Value tid, Value idx,
        Value datlastsysoid, string templatePath = null, bool withHeader = true, bool ifExistsFlag = false,
        bool showSysObj = false)
{
    if (templatePath.length == 0)
        templatePath = defaultTemplatePath(conn);
    auto r = conn.executeDict(renderTemplate(templatePath ~ "/properties.sql",
            tv("did", did, "tid", tid, "idx", idx, "datlastsysoid", datlastsysoid, "show_sys_objects", showSysObj)));
    if (!r.ok)
        throw new ExecuteError(r.error);
    if (r.value["rows"].length == 0)
        throw new ObjectGone(gettext("Could not find the index in the table."));
    auto data = Value(r.value["rows"][0].dict.copy());
    data["schema"] = Value(schema);
    data["table"] = Value(table);
    data["storage_parameters"] = Value.newDict();
    foreach (param; getStorageParams(data["amname"].toString))
        if (data.contains(param) && !data[param].isNone)
            data["storage_parameters"][param] = data[param];
    data = getColumnDetails(conn, idx, data, "create");
    if (conn.manager.version_ >= 110000)
        data = getIncludeDetails(conn, idx, data);
    Value name;
    auto sql = getSql(conn, data, did, tid, Value(null), datlastsysoid, name, Value(null), ifExistsFlag);
    if (withHeader)
    {
        string header;
        if (data.contains("conname") && !data["conname"].isNone)
            header ~= AUTO_CREATE_INDEX_MSG;
        header ~= "-- Index: " ~ data["name"].toString ~ "\n\n-- ";
        header ~= renderTemplate(templatePath ~ "/delete.sql", tv("data", data, "conn", conn));
        sql = header ~ "\n\n" ~ sql;
    }
    return sql;
}
