/// `sqleditor/utils/macros.py` and `query_history.py`: per-user SQL macros and the query history.
module pgadmin.tools.sqleditor.macros;

import pgadmin.browser.common;

// ------------------------------------------------------------ macros

/// `get_macros(macro_id, json_resp=True)`
Response getMacros(Value macroId)
{
    if (macroId.truthy)
    {
        auto mc = db.queryOne("SELECT id, mid, name, sql FROM user_macros WHERE id = ? AND uid = ?", macroId,
                Value(currentUserId()));
        if (mc.isNone)
            return makeJsonResponse(0, Value(gettext("Macro not found.")), Value(""), Value(null), Value(null), 410);
        return makeResponse(Value.dictOf("id", mc["id"], "mid", mc["mid"], "name", mc["name"], "sql", mc["sql"]), 200);
    }
    auto rows = db.query("SELECT m.id AS m_id, m.alt, m.control, m.\"key\" AS mkey, m.key_code, um.name, um.sql, um.id AS um_id "
            ~ "FROM macros m LEFT OUTER JOIN user_macros um ON m.id = um.mid AND um.uid = ?", Value(currentUserId()));
    Value[] data;
    foreach (m; rows)
    {
        auto key = m["mkey"].toString;
        auto keyLabel = m["control"].truthy ? "Ctrl + " ~ key : "Alt + " ~ key;
        data ~= Value.dictOf("id", m["m_id"], "alt", m["alt"], "control", m["control"], "key", m["mkey"], "key_code",
                m["key_code"], "name", m["name"], "sql", m["sql"], "key_label", keyLabel);
    }
    return makeResponse(Value.dictOf("macro", Value(data)), 200);
}

/// `get_user_macros()`
Value getUserMacros()
{
    auto rows = db.query("SELECT um.id AS um_id, um.name, m.id AS m_id, m.alt, m.control, m.\"key\" AS mkey, m.key_code, um.sql "
            ~ "FROM user_macros um LEFT OUTER JOIN macros m ON um.mid = m.id WHERE um.uid = ? ORDER BY um.name",
            Value(currentUserId()));
    Value[] data;
    foreach (m; rows)
    {
        string keyLabel;
        if (m["control"].isBool && m["control"].boolean)
            keyLabel = "Ctrl + " ~ m["mkey"].toString;
        else if (!m["mkey"].isNone)
            keyLabel = "Alt + " ~ m["mkey"].toString;
        data ~= Value.dictOf("id", m["um_id"], "name", m["name"], "mid", m["m_id"], "key", m["mkey"], "key_label", keyLabel,
                "alt", m["alt"].truthy ? 1 : 0, "control", m["control"].truthy ? 1 : 0, "key_code", m["key_code"], "sql",
                m["sql"]);
    }
    return Value(data);
}

private Res createMacro(Value mc)
{
    foreach (arg; ["name", "sql"])
        if (!mc.contains(arg))
            return Res(false, Value(gettext("Could not find the required parameter (%s).").replace("%s", arg)));
    try
    {
        db.exec("INSERT INTO user_macros (uid, mid, name, sql) VALUES (?, ?, ?, ?)", Value(currentUserId()),
                mc.get("mid").truthy ? mc["mid"] : Value(null), mc["name"], mc["sql"]);
    }
    catch (Exception e)
        return Res(false, Value(e.msg));
    return Res(true, Value(null));
}

private Res updateMacro(Value data, Value mc)
{
    auto name = data.get("name");
    auto sql = data.get("sql");
    auto mid = data.get("mid");
    if ((name.truthy || sql.truthy) && mc["sql"].truthy && data.contains("name") && name.isNone)
        return Res(false, Value(gettext("Could not find the required parameter (name).")));
    if ((name.truthy || sql.truthy) && mc["name"].truthy && data.contains("sql") && sql.isNone)
        return Res(false, Value(gettext("Could not find the required parameter (sql).")));
    try
    {
        if (name.truthy || sql.truthy || mid.truthy)
        {
            if (name.truthy)
                db.exec("UPDATE user_macros SET name = ? WHERE id = ?", name, mc["id"]);
            if (sql.truthy)
                db.exec("UPDATE user_macros SET sql = ? WHERE id = ?", sql, mc["id"]);
            db.exec("UPDATE user_macros SET mid = ? WHERE id = ?", mid != Value(0) ? mid : Value(null), mc["id"]);
        }
        else
            db.exec("DELETE FROM user_macros WHERE id = ?", mc["id"]);
    }
    catch (Exception e)
        return Res(false, Value(e.msg));
    return Res(true, Value(null));
}

/// `set_macros()`
Response setMacros()
{
    auto data = formOrJson(request());
    if (!data.contains("changed"))
        return makeJsonResponse(1, Value(""), Value(gettext("Nothing to update.")));
    foreach (m; data["changed"].iterItems())
    {
        if (m.get("id").truthy)
        {
            auto found = db.queryOne("SELECT id, mid, name, sql FROM user_macros WHERE uid = ? AND id = ?",
                    Value(currentUserId()), m["id"]);
            if (!found.isNone)
                updateMacro(m, found);
        }
        else
        {
            auto r = createMacro(m);
            if (!r.ok)
                return makeJsonResponse(0, r.value, Value(""), Value(null), Value(null), 410);
        }
    }
    return jsonify(getUserMacros());
}

// ------------------------------------------------------------ query history

/// `QueryHistory.save(uid, sid, dbname, request)`
Response queryHistorySave(long uid, Value sid, string dbname)
{
    try
    {
        auto maxSrno = db.scalar("SELECT MAX(srno) FROM query_history WHERE uid = ? AND sid = ? AND dbname = ?", Value(uid),
                sid, Value(dbname));
        long maxStored = cfgInt("MAX_QUERY_HIST_STORED");
        long newSrno;
        if (maxSrno.isNone)
            newSrno = 1;
        else
        {
            newSrno = maxSrno.integer + 1;
            auto last = db.queryOne("SELECT srno FROM query_history WHERE uid = ? AND sid = ? AND dbname = ? "
                    ~ "AND last_updated_flag = 'Y'", Value(uid), sid, Value(dbname));
            if (!last.isNone)
            {
                db.exec("UPDATE query_history SET last_updated_flag = 'N' WHERE uid = ? AND sid = ? AND dbname = ? "
                        ~ "AND srno = ?", Value(uid), sid, Value(dbname), last["srno"]);
                if (newSrno > maxStored)
                    newSrno = (last["srno"].integer % maxStored) + 1;
            }
            else
                newSrno = 1;
            if (maxSrno.integer > maxStored)
                db.exec("DELETE FROM query_history WHERE uid = ? AND sid = ? AND dbname = ? AND srno > ?", Value(uid), sid,
                        Value(dbname), Value(maxStored));
        }
        db.exec("INSERT OR REPLACE INTO query_history (srno, uid, sid, dbname, query_info, last_updated_flag) "
                ~ "VALUES (?, ?, ?, ?, ?, 'Y')", Value(newSrno), Value(uid), sid, Value(dbname), Value(request().text));
    }
    catch (Exception e)
        logException(e);
    return makeJsonResponse(1, Value(""), Value(""), Value(null), Value.dictOf("status", true, "msg", "Success"));
}

/// `QueryHistory.clear_history(uid, sid, dbname, filter)`
void queryHistoryClear(long uid, Value sid, string dbname, Value filter)
{
    try
    {
        string where = "uid = ? AND sid = ?";
        Value[] params = [Value(uid), sid];
        if (dbname !is null)
        {
            where ~= " AND dbname = ?";
            params ~= Value(dbname);
        }
        if (!filter.isNone)
        {
            foreach (row; db.query("SELECT srno, dbname, query_info FROM query_history WHERE " ~ where, params))
            {
                auto info = parseJson(row["query_info"].toString);
                if (info["query"] == filter["query"] && info["start_time"] == filter["start_time"])
                    db.exec("DELETE FROM query_history WHERE uid = ? AND sid = ? AND dbname = ? AND srno = ?", Value(uid), sid,
                            row["dbname"], row["srno"]);
            }
        }
        else
            db.exec("DELETE FROM query_history WHERE " ~ where, params);
    }
    catch (Exception e)
        logException(e);
}
