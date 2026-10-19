/// `pgadmin/tools/sqleditor/utils/*`: helpers of the Query Tool (updatable results, saving edited data...).
module pgadmin.tools.sqleditor.helpers;

import std.ascii : isAlpha;
import std.regex : regex, replaceAll;
import pgadmin.browser.common;
import pgadmin.db.libpq : TxStatus;
import pgadmin.tools.sqleditor.command : BaseCommand;

enum ASYNC_OK = 1;
enum ASYNC_READ_TIMEOUT = 2;
enum ASYNC_WRITE_TIMEOUT = 3;
enum ASYNC_NOT_CONNECTED = 4;
enum ASYNC_EXECUTION_ABORTED = 5;

enum TX_STATUS_IDLE = 0;
enum TX_STATUS__ACTIVE = 1;
enum TX_STATUS_INTRANS = 2;
enum TX_STATUS_INERROR = 3;

/// `(status, result, query_results, _rowid)` of `save_changed_data`.
struct SaveResult
{
    bool status;
    Value res;
    Value queryResults;
    Value rowid;
}

// ------------------------------------------------------------ is_begin_required

private void getKeyword(string query, out size_t wordLen, out string keyword)
{
    size_t n;
    while (n < query.length && isAlpha(query[n]))
        n++;
    wordLen = n;
    keyword = query[0 .. n];
}

private bool checkNextKeyword(string query, size_t wordLen, string[] keywordList)
{
    if (keywordList is null)
        return true;
    query = query[wordLen .. $].strip;
    size_t wl;
    string keyword;
    getKeyword(query, wl, keyword);
    return !keywordList.canFind(keyword.toLower);
}

/// `is_begin_required(query)`: whether an implicit BEGIN may precede the statement.
bool isBeginRequired(string query)
{
    query = query.strip;
    size_t wordLen;
    string keyword;
    getKeyword(query, wordLen, keyword);
    auto kw = keyword.toLower;
    if (["abort", "begin", "start", "commit", "vacuum", "end", "rollback"].canFind(kw))
        return false;
    if (kw == "cluster")
    {
        query = query[wordLen .. $].strip;
        if (query.length == 0)
            throw new Exception("string index out of range");
        return isAlpha(query[0]);
    }
    if (kw == "create")
    {
        query = query[wordLen .. $].strip;
        getKeyword(query, wordLen, keyword);
        kw = keyword.toLower;
        if (kw == "database" || kw == "tablespace")
            return false;
        if (kw == "cluster")
        {
            query = query[wordLen .. $].strip;
            getKeyword(query, wordLen, keyword);
            kw = keyword.toLower;
        }
        if (kw == "index")
        {
            query = query[wordLen .. $].strip;
            getKeyword(query, wordLen, keyword);
            if (keyword.toLower == "concurrently")
                return false;
        }
        return true;
    }
    switch (kw)
    {
    case "prepare": return checkNextKeyword(query, wordLen, ["transaction"]);
    case "alter": return checkNextKeyword(query, wordLen, ["system"]);
    case "drop": return checkNextKeyword(query, wordLen, ["database", "system", "tablespace"]);
    case "reindex": return checkNextKeyword(query, wordLen, ["database", "system", "tablespace"]);
    case "discard": return checkNextKeyword(query, wordLen, ["all"]);
    default: return checkNextKeyword(query, wordLen, null);
    }
}

// ------------------------------------------------------------ get_column_types / updatable

/// `_check_single_table(columns_info)`: the table oid shared by all the table columns, or None.
Value checkSingleTable(Value columnsInfo)
{
    Value tableOid = Value(null);
    foreach (column; columnsInfo.iterItems())
    {
        auto t = column["table_oid"];
        if (t.isNone || t == Value(0))
            continue;
        if (tableOid.isNone)
            tableOid = t;
        else if (t != tableOid)
            return Value(null);
    }
    return tableOid;
}

private void setBoth(Value a, Value b, string key, Value v)
{
    a[key] = v;
    b[key] = v;
}

/// `get_columns_types(...)`
Value getColumnsTypesFor(Connection conn, Value columnsInfo, bool hasOids, Value tableOid, bool isQueryTool,
        string tableName = null, string tableNspname = null)
{
    auto nodesPath = "columns/sql/#" ~ to!string(conn.manager.version_) ~ "#";
    Value[string] vars = tv("conn", conn, "has_oids", hasOids);
    if (tableName.length && tableNspname.length)
    {
        vars["table_name"] = Value(tableName);
        vars["table_nspname"] = Value(tableNspname);
    }
    else
        vars["tid"] = tableOid;
    auto colst = conn.execute2darray(renderTemplate(nodesPath ~ "/nodes.sql", vars));
    if (!colst.ok)
        throw new ExecuteError(colst.error);
    auto rows = colst.value["rows"];
    auto columnTypes = Value.newDict();
    foreach (key, col; columnsInfo.list.items)
    {
        auto colType = Value.newDict();
        colType["type_code"] = col["type_code"];
        colType["type_name"] = Value(null);
        colType["internal_size"] = col["internal_size"];
        colType["display_size"] = col["display_size"];
        colType["is_editable"] = isQueryTool ? col.dict.get("is_editable", Value(true)) : Value(true);
        columnTypes[col["name"].toString] = colType;
        if (rows.length)
        {
            if (!isQueryTool)
            {
                auto row = rows[key];
                setBoth(colType, col, "not_null", row["not_null"]);
                setBoth(colType, col, "has_default_val", row["has_default_val"]);
                setBoth(colType, col, "seqtypid", row["seqtypid"]);
            }
            else
            {
                foreach (row; rows.list.items)
                {
                    if (row["oid"] == col["table_column"])
                    {
                        setBoth(colType, col, "not_null", row["not_null"]);
                        setBoth(colType, col, "has_default_val", row["has_default_val"]);
                        setBoth(colType, col, "seqtypid", row["seqtypid"]);
                        break;
                    }
                    else
                    {
                        setBoth(colType, col, "not_null", Value(null));
                        setBoth(colType, col, "has_default_val", Value(null));
                        setBoth(colType, col, "seqtypid", Value(null));
                    }
                }
            }
        }
    }
    return columnTypes;
}

struct Updatable
{
    bool updatable;
    bool hasOids;
    Value primaryKeys = Value(null);
    Value pkNames = Value(null);
    Value tableOid = Value(null);
    Value columnTypes = Value(null);
}

private void checkEditableColumns(Value tableColumns, Value resultsColumns)
{
    bool[long] seen;
    foreach (rc; resultsColumns.iterItems())
    {
        auto tcn = rc["table_column"];
        if (tcn.isNone)
            rc["is_editable"] = Value(false);
        else if (tcn.integer in seen)
            rc["is_editable"] = Value(false);
        else if (!tableColumns.contains(tcn.toString))
            rc["is_editable"] = Value(false);
        else if (rc["display_name"].toString != tableColumns[tcn.toString].toString)
            rc["is_editable"] = Value(false);
        else
        {
            rc["is_editable"] = Value(true);
            seen[tcn.integer] = true;
        }
    }
}

private bool checkOids(Connection conn, string sqlPath, Value tableOid, Value columnsInfo)
{
    if (conn.manager.sversion >= 120000)
        return false;
    auto r = conn.executeScalar(renderTemplate(sqlPath ~ "/has_oids.sql", tv("obj_id", tableOid)));
    if (!r.ok)
        throw new ExecuteError(r.error);
    bool oidColumnSelected;
    foreach (col; columnsInfo.iterItems())
        if ((col["table_column"].isNone || col["table_column"] == Value(-2)) && col["display_name"] == Value("oid"))
        {
            oidColumnSelected = true;
            break;
        }
    return r.value.truthy && oidColumnSelected;
}

private bool allPrimaryKeysExist(Value pkColumns, Value columnsInfo)
{
    foreach (pk; pkColumns.iterItems())
    {
        bool pkExists;
        foreach (col; columnsInfo.iterItems())
        {
            if (col["is_editable"].truthy && col["table_column"] == pk["column_number"])
            {
                pkExists = true;
                if (col["name"] != pk["name"])
                {
                    import std.array : split;
                    auto parts = col["name"].toString.split("-");
                    if (parts.length > 2)
                        throw new Exception("too many values to unpack (expected 2)");
                    if (parts.length < 2)
                        throw new Exception("not enough values to unpack (expected 2, got 1)");
                    col["name"] = Value(parts[0]);
                }
            }
            else if (col["name"] == pk["name"])
                col["name"] = Value(col["name"].toString ~ "-0");
        }
        if (!pkExists)
            return false;
    }
    return true;
}

/// `is_query_resultset_updatable(conn, sql_path)`
Updatable isQueryResultsetUpdatable(Connection conn, string sqlPath)
{
    Updatable u;
    auto columnsInfo = conn.getColumnInfo();
    if (columnsInfo.isNone || columnsInfo.length < 1)
        return u;
    auto tableOid = checkSingleTable(columnsInfo);
    if (tableOid.isNone)
        return u;
    if (!conn.connected())
        throw new HTTPException(500, SERVER_CONNECTION_CLOSED);
    // _get_table_columns
    auto cq = conn.executeDict(renderTemplate(sqlPath ~ "/get_columns.sql", tv("obj_id", tableOid)));
    if (!cq.ok)
        throw new ExecuteError(cq.error);
    auto tableColumns = Value.newDict();
    foreach (row; cq.value["rows"].list.items)
        tableColumns[row["attnum"].toString] = row["attname"];
    checkEditableColumns(tableColumns, columnsInfo);
    // _check_primary_keys
    auto pq = conn.executeDict(renderTemplate(sqlPath ~ "/primary_keys.sql", tv("obj_id", tableOid)));
    if (!pq.ok)
        throw new ExecuteError(pq.error);
    auto primaryKeys = Value.newDict();
    Value[] pkColumns, pkNames;
    foreach (row; pq.value["rows"].list.items)
    {
        primaryKeys[row["attname"].toString] = row["typname"];
        pkColumns ~= Value.dictOf("name", row["attname"], "column_number", row["attnum"]);
        pkNames ~= row["attname"];
    }
    Value pks = primaryKeys;
    Value names = Value(pkNames);
    if (!allPrimaryKeysExist(Value(pkColumns), columnsInfo))
    {
        pks = Value(null);
        names = Value(null);
    }
    auto hasOids = checkOids(conn, sqlPath, tableOid, columnsInfo);
    bool updatable = hasOids || (!pks.isNone && pks.length != 0);
    if (!updatable)
        foreach (col; columnsInfo.iterItems())
            col["is_editable"] = Value(false);
    u.columnTypes = getColumnsTypesFor(conn, columnsInfo, hasOids, tableOid, true);
    u.updatable = updatable;
    u.hasOids = hasOids;
    u.primaryKeys = pks;
    u.pkNames = names;
    u.tableOid = tableOid;
    return u;
}

// ------------------------------------------------------------ save_changed_data

private immutable ignoreTypeCastList = ["character", "character[]", "bit", "bit[]"];

private Res executeVoidWrapper(Connection conn, string sql, Value queryResults)
{
    auto r = conn.executeVoid(sql);
    if (r.ok)
        queryResults.append(Value.dictOf("status", true, "result", r.value, "sql", sql, "rows_affected", 0, "row_added",
                Value(null)));
    return r;
}

/// `save_changed_data(...)`
SaveResult saveChangedData(Value changedData, Value columnsInfo, Connection conn, BaseCommand commandObj,
        string clientPrimaryKey, bool autoCommit = true)
{
    auto queryResults = Value.newList();
    auto listOfSql = Value.newDict();
    Value rowid = Value(null);
    auto pgadminAlias = Value.newDict();
    foreach (colName, colInfo; columnsInfo.dict)
        pgadminAlias[colName] = colInfo["pgadmin_alias"];

    bool isSavepoint;
    string sql;
    if (conn.transactionStatus() == cast(TxStatus) TX_STATUS_IDLE)
        sql = "BEGIN;";
    else
    {
        sql = "SAVEPOINT save_data;";
        isSavepoint = true;
    }
    auto b = executeVoidWrapper(conn, sql, queryResults);
    if (!b.ok)
        return SaveResult(false, b.value, queryResults, Value(null));

    foreach (ofType, _; changedData.dict)
    {
        if (!["added", "updated", "deleted"].canFind(ofType))
            continue;
        if (changedData[ofType].length < 1)
            continue;
        auto columnType = Value.newDict();
        auto columnData = Value.newDict();
        auto typeCastRequired = Value.newDict();
        foreach (eachCol, info; columnsInfo.dict)
        {
            if (info["not_null"].truthy && !info["has_default_val"].truthy)
            {
                columnData[eachCol] = Value(null);
                columnType[eachCol] = info["type_name"];
            }
            else
                columnType[eachCol] = info["type_name"];
            typeCastRequired[eachCol] = Value(!ignoreTypeCastList.canFind(columnType[eachCol].toString));
        }
        if (ofType == "added")
        {
            // sorted by int(key)
            string[] keys;
            foreach (k, v; changedData["added_index"].dict)
                keys ~= k;
            import std.algorithm : sort;
            keys.sort!((a, b) => to!long(a) < to!long(b));
            listOfSql[ofType] = Value.newList();
            columnData = Value.newDict();
            string pkn;
            auto primaryKeys = commandObj.getPrimaryKeys(pkn);
            foreach (eachRow; keys)
            {
                auto tmpRowIndex = changedData["added_index"][eachRow];
                auto data = changedData[ofType][tmpRowIndex.toString]["data"];
                data.dict.remove(clientPrimaryKey);
                data.dict.remove("is_row_copied");
                if (commandObj.hasOids())
                    data.dict.remove("oid");
                auto filtered = Value.newDict();
                foreach (k, v; data.dict)
                    if (columnsInfo.contains(k) && columnsInfo[k].dict.get("is_editable", Value(true)).truthy)
                        filtered[k] = v;
                data = filtered;
                foreach (k, v; data.dict)
                    columnData[k] = v;
                bool useDefault;
                if (!columnData.truthy)
                    foreach (eachCol, info; columnsInfo.dict)
                        if (info["has_default_val"].truthy)
                        {
                            columnData[eachCol] = Value("set_default");
                            useDefault = true;
                        }
                auto insertSql = renderTemplate(commandObj.sqlPath ~ "/insert.sql", tv("data_to_be_saved", columnData,
                        "pgadmin_alias", pgadminAlias, "primary_keys", Value(null), "object_name", commandObj.objectName,
                        "nsp_name", commandObj.nspName, "data_type", columnType, "pk_names", pkn,
                        "has_oids", commandObj.hasOids(), "type_cast_required", typeCastRequired, "use_default", useDefault));
                auto selectSql = renderTemplate(commandObj.sqlPath ~ "/select.sql", tv("object_name", commandObj.objectName,
                        "nsp_name", commandObj.nspName, "pgadmin_alias", pgadminAlias, "primary_keys", primaryKeys,
                        "has_oids", commandObj.hasOids()));
                listOfSql[ofType].append(Value.dictOf("sql", insertSql, "data", data, "client_row", tmpRowIndex,
                        "select_sql", selectSql, "row_id", data.dict.get(clientPrimaryKey, Value(null))));
                columnData = Value.newDict();
            }
        }
        else if (ofType == "updated")
        {
            listOfSql[ofType] = Value.newList();
            foreach (eachRow, entry; changedData[ofType].dict)
            {
                auto data = entry["data"];
                auto pkEscaped = Value.newDict();
                foreach (pk, pkVal; entry["primary_keys"].dict)
                    pkEscaped[pk] = pkVal.isString ? Value(pkVal.str.replace("%", "%%")) : pkVal;
                auto updateSql = renderTemplate(commandObj.sqlPath ~ "/update.sql", tv("data_to_be_saved", data,
                        "pgadmin_alias", pgadminAlias, "primary_keys", pkEscaped, "object_name", commandObj.objectName,
                        "nsp_name", commandObj.nspName, "data_type", columnType, "type_cast_required", typeCastRequired,
                        "conn", conn));
                listOfSql[ofType].append(Value.dictOf("sql", updateSql, "data", data, "row_id",
                        data.dict.get(clientPrimaryKey, Value(null))));
            }
        }
        else if (ofType == "deleted")
        {
            bool deleteAll = changedData.dict.get("delete_all", Value(false)).truthy;
            listOfSql[ofType] = Value.newList();
            string pkn;
            auto primaryKeys = commandObj.getPrimaryKeys(pkn);
            string[] keys;
            foreach (k, v; primaryKeys.dict)
                keys ~= k;
            Value rowsToDelete;
            if (deleteAll)
            {
                auto r = conn.asyncFetchmany(-1);
                if (!r.ok)
                    throw new ExecuteError(r.error);
                Value[] rows;
                foreach (rr; r.value.iterItems())
                {
                    auto d = Value.newDict();
                    foreach (col; changedData["columns"].iterItems())
                        if (keys.canFind(col["name"].toString))
                            d[col["name"].toString] = rr[col["pos"].integer];
                    rows ~= d;
                }
                rowsToDelete = Value(rows);
                columnsInfo = conn.getColumnInfo();
            }
            else
            {
                Value[] rows;
                foreach (k, v; changedData[ofType].dict)
                    rows ~= v;
                rowsToDelete = Value(rows);
            }
            Value[] keyValues;
            foreach (k; keys)
                keyValues ~= Value(k);
            auto deleteSql = renderTemplate(commandObj.sqlPath ~ "/delete.sql", tv("data", rowsToDelete,
                    "primary_key_labels", Value(keyValues), "no_of_keys", cast(long) keys.length,
                    "object_name", commandObj.objectName, "nsp_name", commandObj.nspName, "conn", conn));
            listOfSql[ofType].append(Value.dictOf("sql", deleteSql, "data", Value.newDict()));
        }
    }

    SaveResult failureHandle(Value item, Value res, Value rowId)
    {
        auto mogrified = conn.mogrify(item["sql"].toString, item["data"]);
        queryResults.append(Value.dictOf("status", false, "result", res, "sql", mogrified.length ? Value(mogrified) : item["sql"],
                "rows_affected", 0, "row_added", Value(null)));
        string rbSql, msg;
        if (isSavepoint)
        {
            rbSql = "ROLLBACK TO SAVEPOINT save_data;";
            msg = "A ROLLBACK was done for the save operation only. The active transaction is not affected.";
        }
        else
        {
            rbSql = "ROLLBACK;";
            msg = "A ROLLBACK was done for the save transaction.";
        }
        auto rb = executeVoidWrapper(conn, rbSql, queryResults);
        if (!rb.ok)
            return SaveResult(false, rb.value, queryResults, Value(null));
        foreach (query; queryResults.iterItems())
            if (query["status"].truthy)
                query["result"] = Value(msg);
        return SaveResult(false, res, queryResults, rowId);
    }

    bool status = true;
    Value res = Value(null);
    foreach (opr, sqls; listOfSql.dict)
    {
        foreach (item; sqls.iterItems())
        {
            if (!item["sql"].truthy)
                continue;
            auto remapped = Value.newDict();
            foreach (k, v; item["data"].dict)
                remapped[pgadminAlias.contains(k) ? pgadminAlias[k].toString : k] = v;
            item["data"] = remapped;
            Value rowAdded = Value(null);
            Res r;
            try
            {
                if (item.contains("select_sql") && item["select_sql"].truthy)
                    r = conn.executeDict(item["sql"].toString, item["data"]);
                else
                    r = conn.executeVoid(item["sql"].toString, item["data"]);
            }
            catch (Exception e)
            {
                failureHandle(item, Value(e.msg), item.dict.get("row_id", Value(0)));
                throw e;
            }
            status = r.ok;
            res = r.value;
            if (!r.ok)
                return failureHandle(item, res, item.dict.get("row_id", Value(0)));
            if (item.contains("select_sql"))
            {
                auto params = Value.newDict();
                foreach (k, v; res["rows"][0].dict)
                    params[pgadminAlias.contains(k) ? pgadminAlias[k].toString : k] = v;
                auto sel = conn.executeDict(item["select_sql"].toString, params);
                if (!sel.ok)
                    return failureHandle(item, sel.value, item.dict.get("row_id", Value(0)));
                if (sel.value.contains("rows") && sel.value["rows"].length > 0)
                {
                    rowAdded = Value.newDict();
                    rowAdded[item["client_row"].toString] = sel.value["rows"][0];
                }
            }
            auto rowsAffected = conn.rowsAffected();
            auto mogrified = conn.mogrify(item["sql"].toString, item["data"]);
            queryResults.append(Value.dictOf("status", status, "result", rowAdded.truthy ? Value(null) : res,
                    "sql", mogrified.length ? Value(mogrified) : item["sql"], "rows_affected", rowsAffected,
                    "row_added", rowAdded));
        }
    }
    if (autoCommit)
    {
        auto c = executeVoidWrapper(conn, "COMMIT;", queryResults);
        if (!c.ok)
            return SaveResult(false, c.value, queryResults, Value(null));
        status = true;
        res = c.value;
    }
    return SaveResult(status, res, queryResults, rowid);
}
