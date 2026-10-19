/// Access checks for servers and server groups (`pgadmin/utils/server_access.py`).
module pgadmin.utils.server_access;

import pgadmin.core.config;
import pgadmin.core.value;
import pgadmin.model : db;
import pgadmin.web.context;

/// `get_server_groups_for_user`: groups visible to the user, with `is_shared_group` and `is_first_user_group`.
Value[] getServerGroupsForUser(bool hideShared = false, Value servergroupId = Value(null))
{
    auto uid = Value(currentUserId());
    string select = "SELECT sg.*, ";
    Value[] params;
    string sql;
    immutable first = "(sg.id = (SELECT MIN(id) FROM servergroup WHERE user_id = ?)) AS is_first_user_group";
    if (!cfgBool("SERVER_MODE"))
    {
        sql = select ~ "0 AS is_shared_group, " ~ first ~ " FROM servergroup sg WHERE sg.user_id = ?";
        params = [uid, uid];
        if (!servergroupId.isNone)
        {
            sql ~= " AND sg.id = ?";
            params ~= servergroupId;
        }
        sql ~= " ORDER BY sg.id";
    }
    else
    {
        sql = select ~ "(sg.user_id != ?) AS is_shared_group, " ~ first ~ " FROM servergroup sg WHERE ";
        params = [uid, uid];
        if (hideShared)
        {
            sql ~= "sg.user_id = ?";
            params ~= uid;
        }
        else
        {
            sql ~= "(sg.user_id = ? OR EXISTS (SELECT 1 FROM server s WHERE s.servergroup_id = sg.id AND s.shared))";
            params ~= uid;
        }
        if (!servergroupId.isNone)
        {
            sql ~= " AND sg.id = ?";
            params ~= servergroupId;
        }
        sql ~= " ORDER BY CASE WHEN sg.user_id = ? THEN 0 ELSE 1 END, sg.id";
        params ~= uid;
    }
    auto rows = db.query(sql, params);
    foreach (r; rows)
    {
        r["is_shared_group"] = Value(r["is_shared_group"].integer != 0);
        r["is_first_user_group"] = Value(r["is_first_user_group"].integer != 0);
    }
    return rows;
}

/// `get_server_group(gid, hide_shared)`: the group row or None.
Value getServerGroup(Value gid, bool hideShared = false)
{
    auto sg = getServerGroupsForUser(hideShared, gid);
    return sg.length ? sg[0] : Value(null);
}

/// `get_user_server_query()` with extra conditions: the servers the user can see.
Value[] getUserServers(string where = null, Value[] params = null, string orderBy = null)
{
    string sql = "SELECT * FROM server";
    Value[] p;
    string[] conds;
    if (cfgBool("SERVER_MODE"))
    {
        conds ~= "(user_id = ? OR shared)";
        p ~= Value(currentUserId());
    }
    if (where.length)
    {
        conds ~= "(" ~ where ~ ")";
        p ~= params;
    }
    if (conds.length)
        sql ~= " WHERE " ~ join(conds, " AND ");
    if (orderBy.length)
        sql ~= " ORDER BY " ~ orderBy;
    return db.query(sql, p);
}

private string join(string[] parts, string sep)
{
    string r;
    foreach (i, s; parts)
        r ~= (i ? sep : "") ~ s;
    return r;
}

