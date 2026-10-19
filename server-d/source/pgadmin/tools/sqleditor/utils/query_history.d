/// Query history of the Query Tool (`tools/sqleditor/utils/query_history.py`).
module pgadmin.tools.sqleditor.utils.query_history;

import pgadmin.core.value;
import pgadmin.model : db;

/// `QueryHistory.clear_history(uid, sid)`: removes the history of a server.
void clearHistory(long uid, long sid, string dbname = null)
{
    if (dbname is null)
        db.exec("DELETE FROM query_history WHERE uid = ? AND sid = ?", Value(uid), Value(sid));
    else
        db.exec("DELETE FROM query_history WHERE uid = ? AND sid = ? AND dbname = ?", Value(uid), Value(sid), Value(dbname));
}

/// `QueryHistory.update_history_dbname(uid, sid, old_dbname, new_dbname)`
void updateHistoryDbname(long uid, long sid, string oldName, string newName)
{
    db.exec("UPDATE query_history SET dbname = ? WHERE uid = ? AND sid = ? AND dbname = ?", Value(newName), Value(uid),
            Value(sid), Value(oldName));
}
