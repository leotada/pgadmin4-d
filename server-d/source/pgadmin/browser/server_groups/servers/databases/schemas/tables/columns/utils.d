/// `tables/columns/utils.py`: column formatting shared by tables, views and the column node.
module pgadmin.browser.server_groups.servers.databases.schemas.tables.columns.utils;

import std.algorithm : canFind, sort;
import std.array : array, join, split;
import std.conv : to;
import std.regex : regex, matchFirst;
import std.string : startsWith, strip;
import pgadmin.browser.server_groups.servers.databases.schemas.utils;
import pgadmin.browser.server_groups.servers.utils;
import pgadmin.core.templates;
import pgadmin.core.value;
import pgadmin.db.driver;
import pgadmin.utils.exception;
import pgadmin.web.http;

string defaultTemplatePath(Connection conn) => "columns/sql/#" ~ to!string(conn.manager.version_) ~ "#";

/// `get_parent(conn, tid)` -> (schema, table)
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

private void checkPrimaryColumn(Value data)
{
    if (data.contains("attnum") && data.contains("indkey"))
    {
        auto attnum = data["attnum"].toString;
        auto indkey = data["indkey"].toString;
        bool pk = indkey.split(" ").canFind(attnum);
        data["is_pk"] = Value(pk);
        data["is_primary_key"] = Value(pk);
    }
}

/// Returns false (and the error message in `errmsg`) when the query fails.
private bool fetchInheritedTables(Value tid, Value data, bool fetch, string templatePath, Connection conn, out Response err)
{
    if (fetch)
    {
        auto r = conn.executeDict(renderTemplate(templatePath ~ "/get_inherited_tables.sql", tv("tid", tid)));
        if (!r.ok)
        {
            err = internalServerError(r.error);
            return true;
        }
        foreach (row; r.value["rows"].list.items)
            if (row["attrname"] == data["name"])
            {
                data["is_inherited"] = Value(true);
                data["tbls_inherited"] = row["inhrelname"];
            }
    }
    return false;
}

/// `column_formatter(...)`. `editTypesList` is shared with the caller (the Python code appends to it).
Value columnFormatter(Connection conn, Value tid, Value clid, Value data, List editTypesList = null,
        bool fetchInheritedTablesFlag = true, string templatePath = null)
{
    if (templatePath.length == 0)
        templatePath = defaultTemplatePath(conn);
    checkPrimaryColumn(data);
    data = fetchLengthPrecision(data);
    Response err;
    if (fetchInheritedTables(tid, data, fetchInheritedTablesFlag, templatePath, conn, err))
        throw new HTTPException(err);
    if (data.contains("attoptions") && !data["attoptions"].isNone)
        data["attoptions"] = parseColumnVariables(data["attoptions"]);
    if (data.contains("seclabels") && !data["seclabels"].isNone)
    {
        Value[] seclabels;
        foreach (s; data["seclabels"].iterItems())
        {
            auto parts = s.toString.split("=");
            if (parts.length != 2)
                throw new Exception("too many values to unpack (expected 2)");
            seclabels ~= Value.dictOf("provider", parts[0], "label", parts[1]);
        }
        data["seclabels"] = Value(seclabels);
    }
    if (data.contains("attfdwoptions") && data["attfdwoptions"] != Value(""))
        data["coloptions"] = parseOptionsForColumn(data["attfdwoptions"]);
    auto a = conn.executeDict(renderTemplate(templatePath ~ "/acl.sql", tv("tid", tid, "clid", clid)));
    if (!a.ok)
        throw new HTTPException(internalServerError(a.error));
    data["attacl"] = Value.newList();
    foreach (row; a.value["rows"].list.items)
    {
        auto priv = parsePrivFromDb(row);
        auto t = row["deftype"].toString;
        if (data.contains(t))
            data[t].append(priv);
        else
            data[t] = Value([priv]);
    }
    auto typeId = data["atttypid"];
    if (editTypesList is null)
    {
        editTypesList = new List;
        auto r = conn.execute2darray(renderTemplate(templatePath ~ "/edit_mode_types.sql", tv("type_id", typeId)));
        foreach (row; r.value["rows"].list.items)
            editTypesList.items ~= row["typname"];
    }
    editTypesList.items ~= data["typname"];
    auto sortedTypes = editTypesList.items.dup;
    sortedTypes.sort!((x, y) => x.toString < y.toString);
    data["edit_types"] = Value(sortedTypes);
    data["cltype"] = Value(DataTypeReader.parseTypeName(data["cltype"].toString));
    return data;
}

Value parseOptionsForColumn(Value dbVariables)
{
    Value[] lst;
    if (!dbVariables.isNone)
        foreach (row; dbVariables.iterItems())
        {
            auto s = row.toString;
            auto idx = s.indexOfChar('=');
            lst ~= Value.dictOf("option", s[0 .. idx], "value", s[idx + 1 .. $]);
        }
    return Value(lst);
}

private ptrdiff_t indexOfChar(string s, char c)
{
    foreach (i, ch; s)
        if (ch == c)
            return i;
    throw new Exception("not enough values to unpack (expected 2, got 1)");
}

immutable string[string] SERIAL_TYPES = ["integer": "serial", "smallint": "smallserial", "bigint": "bigserial"];
immutable string[string] UNDERLYING_SERIAL_TYPES = ["serial": "integer", "smallserial": "smallint", "bigserial": "bigint"];

bool isSerialColumn(Value col)
{
    auto defval = col.dict.get("defval", Value("")).truthy ? col["defval"].toString : "";
    return col.dict.get("seqrelid", Value(null)).truthy && defval.startsWith("nextval('")
        && !col.dict.get("attidentity", Value(null)).truthy
        && col.dict.get("seqrelid", Value(null)) == col.dict.get("defseqrelid", Value(null))
        && (col.dict.get("typname", Value(null)).toString in SERIAL_TYPES) !is null;
}

Value reprojectSerialColumn(Value col)
{
    if (!isSerialColumn(col))
        return col;
    auto serialType = SERIAL_TYPES[col["typname"].toString];
    col["displaytypname"] = Value(serialType);
    col["cltype"] = Value(serialType);
    col["typname"] = Value(serialType);
    col["defval"] = Value("");
    return col;
}

Value getFormattedColumns(Connection conn, Value tid, Value data, Value[] otherColumns, string tableOrType,
        string templatePath = null, bool withSerial = true)
{
    if (templatePath.length == 0)
        templatePath = defaultTemplatePath(conn);
    auto r = conn.executeDict(renderTemplate(templatePath ~ "/properties.sql", tv("tid", tid, "show_sys_objects", false)));
    if (!r.ok)
        throw new ExecuteError(r.error);
    auto allColumns = r.value["rows"];
    List[string] editTypes;
    string[] editTypeKeys;
    foreach (col; allColumns.list.items)
    {
        auto key = col["atttypid"].toString;
        if (!(key in editTypes))
            editTypeKeys ~= key;
        editTypes[key] = new List;
        foreach (other; otherColumns)
            if (col["name"] == other["name"])
                col["inheritedfrom" ~ tableOrType] = other["inheritedfrom"];
        if (withSerial)
            reprojectSerialColumn(col);
    }
    data["columns"] = allColumns;
    if (data["columns"].length > 0)
    {
        auto typeIds = editTypeKeys.join(",");
        auto m = conn.execute2darray(renderTemplate(templatePath ~ "/edit_mode_types_multi.sql", tv("type_ids", typeIds)));
        foreach (row; m.value["rows"].list.items)
        {
            auto sorted = row["edit_types"].list.items.dup;
            sorted.sort!((x, y) => x.toString < y.toString);
            auto l = new List;
            l.items = sorted;
            editTypes[row["main_oid"].toString] = l;
        }
        foreach (column; data["columns"].list.items)
            columnFormatter(conn, tid, column["attnum"], column, editTypes[column["atttypid"].toString], false);
    }
    return data;
}

private void parseColumnActions(Value finalColumns, string[] columnAcl)
{
    foreach (c; finalColumns.iterItems())
    {
        if (c.contains("attacl"))
        {
            foreach (k; ["added", "changed", "deleted"])
                if (c["attacl"].contains(k))
                {
                    c["attacl"][k] = parsePrivToDb(c["attacl"][k], columnAcl);
                    break;
                }
        }
        if (c.contains("cltype"))
        {
            bool sqr;
            auto t = typeFormatter(c["cltype"].toString, sqr);
            c["cltype"] = Value(t);
            c["hasSqrBracket"] = Value(sqr);
        }
        convertLengthPrecisionToString(c);
    }
}

private void parseFormatColForEdit(Value data, Value columns, string[] columnAcl)
{
    foreach (action; ["added", "changed"])
        if (columns.contains(action))
        {
            Value[] finalColumns;
            foreach (c; columns[action].iterItems())
                if (c.dict.get("inheritedfrom", Value(null)).isNone)
                    finalColumns ~= c;
            parseColumnActions(Value(finalColumns), columnAcl);
            data["columns"][action] = Value(finalColumns);
        }
}

/// `parse_format_columns(data, mode=None)`
Value parseFormatColumns(Value data, string mode = null)
{
    string[] columnAcl = ["a", "r", "w", "x"];
    auto columns = data["columns"];
    if (mode.length)
        parseFormatColForEdit(data, columns, columnAcl);
    else
    {
        Value[] finalColumns;
        bool[string] pkColumns;
        if (data.contains("primary_key") && data["primary_key"].length > 0)
            foreach (pk; data["primary_key"].iterItems())
                if (pk.contains("columns"))
                    foreach (col; pk["columns"].iterItems())
                        if (col.contains("column"))
                            pkColumns[col["column"].toString] = true;
        foreach (c; columns.iterItems())
        {
            if (c.dict.get("inheritedfrom", Value(null)).isNone)
                finalColumns ~= c;
            else if (!c.dict.get("inheritedfromtype", Value(null)).isNone)
            {
                bool hasModifications;
                auto originalDefval = c.dict.get("original_defval", Value(null));
                auto currentDefval = c.dict.get("defval", Value(null));
                auto origVal = originalDefval.isNone ? "" : originalDefval.toString;
                auto currVal = currentDefval.isNone ? "" : currentDefval.toString;
                if (origVal != currVal)
                    hasModifications = true;
                auto originalNotNull = c.dict.get("original_attnotnull", Value(false));
                auto currentNotNull = c.dict.get("attnotnull", Value(false));
                if (originalNotNull != currentNotNull)
                    hasModifications = true;
                if (hasModifications)
                {
                    if (c.dict.get("colconstype", Value(null)) != Value("i"))
                        c["has_with_options"] = Value(true);
                    finalColumns ~= c;
                }
            }
        }
        foreach (c; finalColumns)
        {
            if (c.contains("attacl"))
                c["attacl"] = parsePrivToDb(c["attacl"], columnAcl);
            if (c.contains("cltype"))
            {
                bool sqr;
                auto t = typeFormatter(c["cltype"].toString, sqr);
                c["cltype"] = Value(t);
                c["hasSqrBracket"] = Value(sqr);
            }
            convertLengthPrecisionToString(c);
        }
        data["columns"] = Value(finalColumns);
    }
    return data;
}

Value convertLengthPrecisionToString(Value data)
{
    if (data.contains("attlen") && data["attlen"] == Value(""))
        data["attlen"] = Value(null);
    else if (data.contains("attlen") && !data["attlen"].isNone)
        data["attlen"] = Value(data["attlen"].toString);
    if (data.contains("attprecision") && data["attprecision"] == Value(""))
        data["attprecision"] = Value(null);
    else if (data.contains("attprecision") && !data["attprecision"].isNone)
        data["attprecision"] = Value(data["attprecision"].toString);
    return data;
}

/// `type_formatter(data_type)` -> (type without `[]`, has `[]`)
string typeFormatter(string dataType, out bool hasSqrBracket)
{
    import std.algorithm : canFind;
    if (dataType.canFind("[]"))
    {
        hasSqrBracket = true;
        return dataType[0 .. $ - 2];
    }
    hasSqrBracket = false;
    return dataType;
}

Value fetchLengthPrecision(Value data)
{
    auto fulltype = DataTypeReader.getFullType(data["typnspname"], data["typname"].toString, data["isdup"],
            data["attndims"].integer, data["atttypmod"].integer);
    bool length, precision;
    if (data.contains("elemoid"))
    {
        string typeval;
        DataTypeReader.getLengthPrecision(data["elemoid"], data["typname"].toString, length, precision, typeval);
    }
    data["attlen"] = Value(null);
    data["attprecision"] = Value(null);
    string[] params;
    if (data.contains("typname") && (data["typname"] == Value("geometry") || data["typname"] == Value("geography")))
    {
        params = parseParams(data["cltype"].toString);
        if (params.length)
        {
            data["geometry"] = Value(params[0]);
            data["srid"] = Value(params[1]);
        }
    }
    else
        params = parseParams(fulltype);
    if (length && precision)
    {
        if (params.length)
        {
            data["attlen"] = Value(params[0]);
            data["attprecision"] = Value(params[1]);
        }
    }
    else if (length)
    {
        if (params.length)
        {
            data["attlen"] = Value(params[0]);
            data["attprecision"] = Value(null);
        }
    }
    return data;
}

Value parseColumnVariables(Value colVariables)
{
    Value[] spc;
    if (!colVariables.isNone)
        foreach (o; colVariables.iterItems())
        {
            auto parts = o.toString.split("=");
            if (parts.length != 2)
                throw new Exception("too many values to unpack (expected 2)");
            spc ~= Value.dictOf("name", parts[0], "value", parts[1]);
        }
    return Value(spc);
}

string[] parseParams(string fulltype)
{
    auto m = matchFirst(fulltype, regex(`\((\d*[a-zA-Z]*),?(\d*)\)`));
    if (!m.empty)
        return [m[1].idup, m[2].idup];
    return null;
}
