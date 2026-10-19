/// Helpers shared by the server node and the nodes below it (`servers/utils.py`).
module pgadmin.browser.server_groups.servers.utils;

import std.algorithm : canFind, sort;
import std.array : join, split;
import std.conv : to;
import std.socket : InternetAddress, Internet6Address;
import std.string : indexOf, strip, replace;
import pgadmin.core.config;
import pgadmin.core.log;
import pgadmin.core.templates : renderTemplate;
import pgadmin.core.value;
import pgadmin.db.driver;
import pgadmin.db.quoting;
import pgadmin.model;
import pgadmin.utils.constants;
import pgadmin.utils.exception;
import pgadmin.utils.server_access;
import pgadmin.web.context;
import pgadmin.web.http;

bool isValidIpAddress(string address)
{
    try
    {
        if (address.canFind(":"))
        {
            Internet6Address.parse(address);
            return true;
        }
        auto parts = address.split(".");
        if (parts.length != 4)
            return false;
        foreach (p; parts)
        {
            if (p.length == 0 || p.length > 3)
                return false;
            auto n = to!int(p);
            if (n < 0 || n > 255)
                return false;
        }
        return true;
    }
    catch (Exception)
        return false;
}

/// `parse_priv_from_db`: an ACL row as the dialog expects it.
Value parsePrivFromDb(Value dbPrivileges)
{
    auto acl = new Dict;
    acl["grantor"] = dbPrivileges["grantor"];
    acl["grantee"] = dbPrivileges["grantee"];
    acl["privileges"] = Value.newList();
    if (dbPrivileges.contains("acltype"))
        acl["acltype"] = dbPrivileges["acltype"];
    Value[] privs;
    foreach (idx, priv; dbPrivileges["privileges"].iterItems())
        privs ~= Value.dictOf("privilege_type", priv, "privilege", true, "with_grant", dbPrivileges["grantable"][idx]);
    import std.algorithm : SwapStrategy;
    sort!((a, b) => a["privilege_type"].toString < b["privilege_type"].toString, SwapStrategy.stable)(privs);
    acl["privileges"] = Value(privs);
    return Value(acl);
}

private void checkPrivilegeType(Value priv)
{
    auto p = priv["privileges"];
    if (p.isDict && p.contains("changed"))
    {
        Value[] tmp;
        foreach (x; p["changed"].iterItems())
        {
            auto tp = Value.dictOf("privilege_type", x["privilege_type"], "privilege", false, "with_grant", false);
            if (x.contains("with_grant"))
            {
                tp["privilege"] = Value(true);
                tp["with_grant"] = x["with_grant"];
            }
            if (x.contains("privilege"))
                tp["privilege"] = x["privilege"];
            tmp ~= tp;
        }
        priv["privileges"] = Value(tmp);
    }
}

private immutable string[string] privChars = [
    "c": "CONNECT", "C": "CREATE", "T": "TEMPORARY", "a": "INSERT", "r": "SELECT", "R": "READ", "w": "UPDATE",
    "W": "WRITE", "d": "DELETE", "D": "TRUNCATE", "x": "REFERENCES", "t": "TRIGGER", "U": "USAGE", "X": "EXECUTE",
    "m": "MAINTAIN",
];

/// `parse_priv_to_db(str_privileges, allowed_acls)`
Value parsePrivToDb(Value strPrivileges, string[] allowedAcls = null)
{
    Value[] privileges;
    auto allowedLen = allowedAcls.length;
    foreach (priv; strPrivileges.iterItems())
    {
        string[] withGrant, withoutGrant;
        checkPrivilegeType(priv);
        foreach (p; priv["privileges"].iterItems())
        {
            auto pt = p["privilege_type"].toString;
            if (pt !in privChars || !allowedAcls.canFind(pt))
                continue;
            // privilege_type holds the one-letter code
            if (p["with_grant"].truthy)
                withGrant ~= privChars[pt];
            else if (p["privilege"].truthy)
                withoutGrant ~= privChars[pt];
        }
        if (withGrant.length == allowedLen && allowedLen > 1)
            withGrant = ["ALL"];
        if (withoutGrant.length == allowedLen && allowedLen > 1)
            withoutGrant = ["ALL"];
        auto grantee = priv["grantee"].toString != "PUBLIC" ? qtIdentStr(priv["grantee"].toString) : "PUBLIC";
        auto oldGrantee = priv.contains("old_grantee") && priv["old_grantee"].toString != "PUBLIC"
            ? qtIdentStr(priv["old_grantee"].toString) : grantee;
        auto acltype = priv.contains("acltype") ? priv["acltype"] : Value("defaultacls");
        auto grantor = qtIdentStr(priv["grantor"].toString);
        Value[] wg, wog;
        foreach (x; withGrant)
            wg ~= Value(x);
        foreach (x; withoutGrant)
            wog ~= Value(x);
        privileges ~= Value.dictOf("grantor", grantor, "grantee", grantee, "with_grant", Value(wg), "without_grant",
                Value(wog), "old_grantee", oldGrantee, "acltype", acltype);
    }
    return Value(privileges);
}

/// `tokenize_options`: "name=value" strings to a list of dicts.
Value tokenizeOptions(Value optionsFromDb, string optionName, string optionValue)
{
    Value[] options;
    if (!optionsFromDb.isNone)
        foreach (o; optionsFromDb.iterItems())
        {
            auto s = o.toString;
            auto eq = s.indexOf('=');
            options ~= Value.dictOf(optionName, s[0 .. eq], optionValue, s[eq + 1 .. $]);
        }
    return Value(options);
}

struct ValidOptions
{
    bool isValid;
    Value options;
}

/// `validate_options`
ValidOptions validateOptions(Value options, string optionName, string optionValue)
{
    Value[] valid;
    foreach (option; options.iterItems())
    {
        if (option.contains(optionName) && !option[optionName].isNone && option[optionName].toString != ""
                && option[optionName].toString.strip.length > 0)
        {
            if (!(option.contains(optionValue) && !option[optionValue].isNone && option[optionValue].toString != ""
                    && option[optionValue].toString.strip.length > 0))
                option[optionValue] = Value("");
            valid ~= option;
        }
    }
    return ValidOptions(valid.length > 0, Value(valid));
}

/// `get_replication_type(conn, sversion)`
Value getReplicationType(Connection conn, long sversion)
{
    auto sql = renderTemplate("/servers/sql/#" ~ to!string(sversion) ~ "#/replication_type.sql");
    auto r = conn.executeDict(sql);
    if (!r.ok)
        throw new Exception(r.error);
    return r.value["rows"][0]["type"];
}

/// `convert_connection_parameter`: list <-> dict forms of the connection parameters.
Value convertConnectionParameter(Value params)
{
    if (params.isList)
    {
        auto d = new Dict;
        foreach (item; params.list.items)
            d[item["name"].toString] = item["value"];
        return Value(d);
    }
    if (params.isDict)
    {
        Value[] r;
        foreach (k, v; params.dict)
            if (!v.isNone)
                r ~= Value.dictOf("name", k, "keyword", k, "value", v);
        return Value(r);
    }
    return Value(null);
}

/// `check_ssl_fields(data)`: adds dummy certificate paths in server mode.
bool checkSslFields(Value data)
{
    bool flag;
    if (data.contains("sslmode") && SSL_MODES.canFind(data["sslmode"].toString))
    {
        flag = true;
        foreach (field; ["sslcert", "sslkey", "sslrootcert", "sslcrl", "sslcompression"])
        {
            if (data.contains(field))
                continue;
            if (cfgBool("SERVER_MODE") && (field == "sslcert" || field == "sslkey"))
                data[field] = Value("<STORAGE_DIR>/.postgresql/postgresql" ~ (field == "sslkey" ? ".key" : ".crt"));
        }
    }
    return flag;
}

void disconnectFromAllServers()
{
    foreach (server; getUserServers())
    {
        try
        {
            auto manager = getDriver().connectionManager(server["id"].integer);
            if (manager !is null)
                manager.release();
        }
        catch (Exception e)
            logWarning("Failed to disconnect server " ~ server["id"].toString ~ ": " ~ e.msg);
    }
}

/// `delete_adhoc_servers(sid)`
void deleteAdhocServers(Value sid = Value(null))
{
    string where = "is_adhoc = 1";
    Value[] params;
    if (!sid.isNone)
    {
        where = "id = ? AND is_adhoc = 1";
        params ~= sid;
    }
    if (hasRequestContext() && isAuthenticated())
    {
        where ~= " AND user_id = ?";
        params ~= Value(currentUserId());
    }
    db.exec("DELETE FROM server WHERE " ~ where, params);
    db.exec("UPDATE sqlite_sequence SET seq = (SELECT COALESCE(max(id), 0) FROM server) WHERE name = 'server'");
}

/// `get_db_restriction(res_type, restriction)`
Value getDbRestriction(Value resType, Value restriction)
{
    if (restriction.truthy && resType.toString == RESTRICTION_TYPE_DATABASES)
    {
        Value[] r;
        foreach (p; restriction.toString.split(","))
            r ~= Value(p);
        return Value(r);
    }
    if (restriction.truthy && resType.toString == RESTRICTION_TYPE_SQL)
        return restriction;
    return Value(null);
}

struct DbDispRestriction
{
    Value expr; /// SQL fragment (placeholders `%s` for the database list) or None
    Value params;
}

/// `get_db_disp_restriction(manager)`
DbDispRestriction getDbDispRestriction(ServerManager m)
{
    DbDispRestriction r;
    r.expr = Value(null);
    r.params = Value(null);
    if (m !is null && m.dbRes.length && m.dbResType == RESTRICTION_TYPE_DATABASES)
    {
        auto names = m.dbRes.split(",");
        string[] marks;
        Value[] ps;
        foreach (n; names)
        {
            marks ~= "%s";
            ps ~= Value(n);
        }
        r.expr = Value(marks.join(", "));
        r.params = Value.tuple(ps);
    }
    else if (m !is null && m.dbRes.length && m.dbResType == RESTRICTION_TYPE_SQL)
        r.expr = Value(m.dbRes);
    return r;
}
