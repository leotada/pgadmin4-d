/// `pgadmin/browser/server_groups/servers`: registered servers (tree nodes, connect/disconnect and CRUD).
module pgadmin.browser.server_groups.servers;

import pgadmin.browser.utils;
import pgadmin.core.config;
import pgadmin.core.i18n;
import pgadmin.core.log;
import pgadmin.core.templates : renderTemplate;
import pgadmin.core.value;
import pgadmin.db.driver;
import pgadmin.model;
import pgadmin.utils.constants;
import pgadmin.utils.exception;
import pgadmin.utils.preferences;
import pgadmin.utils.server_access;
import pgadmin.web.auth;
import pgadmin.web.context;
import pgadmin.web.flask;
import pgadmin.web.http;
import pgadmin.core.sqlite : SqliteIntegrity;
import pgadmin.core.crypto : encrypt, decryptStr;
import pgadmin.utils.master_password;
import pgadmin.utils.paths : getCompleteFilePath;
import pgadmin.browser.server_groups.servers.utils;
import std.algorithm : canFind;
import std.conv : to;
import std.string : replace, indexOf;

/// `has_any(data, keys)`: the `hasAny` template filter (also registered in `registerPgFilters`).
bool hasAny(Value data, Value keys)
{
    if (data.isNone || keys.isNone)
        return false;
    foreach (k; keys.iterItems())
        if (data.contains(k))
            return true;
    return false;
}

bool isNonOwner(Value server) => server.get("shared").truthy && server["user_id"].integer != currentUserId();

/// `server_icon_and_background(is_connected, manager, server)`
string serverIconAndBackground(bool isConnected, ServerManager manager, Value server)
{
    string bg;
    if (server.isDict && server.get("bgcolor").truthy)
    {
        bg = " " ~ server["bgcolor"].toString;
        if (server.get("fgcolor").truthy)
            bg = bg ~ " " ~ server["fgcolor"].toString;
    }
    if (isConnected)
        return "icon-" ~ manager.serverType ~ bg;
    if (server.get("shared").truthy && cfgBool("SERVER_MODE"))
        return "icon-shared-server-not-connected" ~ bg;
    if (server.get("cloud_status").isInt && server["cloud_status"].integer == -1)
        return "icon-server-cloud-deploy" ~ bg;
    return "icon-server-not-connected" ~ bg;
}

final class ServerModule : BrowserPluginModule
{
    enum NODE_TYPE = "server";

    this()
    {
        super(NODE_TYPE);
        label = Value(gettext("Servers"));
        staticDir("browser/server_groups/servers");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => "server_group";
    override string[] getExposedUrlEndpoints() => ["NODE-server.connect_id"];

    override string[] csssnippets()
    {
        string[] snippets = [renderTemplate("css/servers.css")];
        foreach (m; submodules)
            if (auto b = cast(BrowserPluginModule) m)
                snippets ~= b.csssnippets;
        foreach (st; ServerType.types())
            snippets ~= renderTemplate("css/server_type.css", ["server_type": Value(st.stype), "icon": Value(st.stype ~ ".svg")]);
        return snippets;
    }

    override Value[] getNodes(Dict kwargs)
    {
        auto gid = kwargs["gid"];
        bool hideShared;
        if (cfgBool("SERVER_MODE"))
        {
            auto p = Preferences.module_("browser").preference("hide_shared_server");
            hideShared = p !is null && p.get().truthy;
        }
        auto objectFilters = currentObjectFilters();
        auto servers = getUserServers("servergroup_id = ? AND is_adhoc = 0", [gid]);
        Value[] nodes;
        auto driver = getDriver();
        foreach (server; servers)
        {
            if (server.get("discovery_id").truthy && !server.get("shared").truthy && cfgBool("SERVER_MODE")
                    && !db.queryOne("SELECT 1 AS x FROM sharedserver WHERE user_id = ? AND osid = ?",
                        Value(currentUserId()), server["id"]).isNone && !hideShared)
                continue;
            if (isNonOwner(server) && hideShared)
                continue;
            if (!hasTag(server, objectFilters))
                continue;
            bool connected, wasConnected;
            ServerManager manager;
            Value errmsg = Value(null);
            string serverType = "pg";
            Value userInfo = Value(null);
            try
            {
                manager = driver.connectionManager(server["id"].integer);
                auto conn = manager.connection();
                wasConnected = conn.wasConnected;
                connected = conn.connected();
                if (connected)
                {
                    serverType = manager.serverType;
                    userInfo = manager.userInfo is null ? Value(null) : Value(manager.userInfo);
                }
            }
            catch (CryptKeyMissing)
            {
            }
            catch (Exception e)
            {
                logException(e);
                errmsg = Value(e.msg);
            }
            auto kw = new Dict;
            kw["connected"] = Value(connected);
            kw["server_type"] = Value(serverType);
            kw["version"] = manager is null ? Value(null) : manager.versionValue;
            kw["db"] = manager is null || manager.db is null ? Value(null) : Value(manager.db);
            kw["user"] = userInfo;
            kw["in_recovery"] = Value(null);
            kw["wal_pause"] = Value(null);
            kw["host"] = server["host"];
            kw["port"] = server["port"];
            kw["is_password_saved"] = Value(server.get("save_password").truthy);
            kw["is_tunnel_password_saved"] = Value(server.get("tunnel_password").truthy);
            kw["was_connected"] = Value(wasConnected);
            kw["errmsg"] = errmsg;
            kw["user_id"] = server["user_id"];
            kw["username"] = server["username"];
            kw["shared"] = server["shared"];
            kw["is_kerberos_conn"] = Value(server.get("kerberos_conn").truthy);
            kw["gss_authenticated"] = Value(manager !is null && manager.gssAuthenticated);
            kw["cloud_status"] = server["cloud_status"];
            kw["description"] = server["comment"];
            kw["tags"] = server["tags"];
            nodes ~= generateBrowserNode(Value(server["id"].toString), gid, server["name"].toString,
                    serverIconAndBackground(connected, manager, server), true, NODE_TYPE, kw);
        }
        return nodes;
    }

    private static bool hasTag(Value server, Value filters)
    {
        try
        {
            auto tags = filters.get("tags");
            if (!tags.isList || tags.length == 0)
                return true;
            auto st = server.get("tags");
            if (!st.isList || st.length == 0)
                return false;
            foreach (t; st.list.items)
                if (tags.contains(t["text"]))
                    return true;
            return false;
        }
        catch (Exception)
            return true;
    }

    override void setup()
    {
        import pgadmin.browser.server_groups.servers.databases : DatabaseModule;
        import pgadmin.browser.server_groups.servers.tablespaces : TablespaceModule;
        submodules ~= new DatabaseModule;
        import pgadmin.browser.server_groups.servers.roles : RoleModule;
        submodules ~= new RoleModule;
        import pgadmin.browser.server_groups.servers.replica_nodes : ReplicationNodesModule;
        import pgadmin.browser.server_groups.servers.pgd_replication_groups : PGDReplicationGroupsModule;
        import pgadmin.browser.server_groups.servers.pgagent : PgaJobModule;
        import pgadmin.browser.server_groups.servers.directories : DirectoryModule;
        import pgadmin.browser.server_groups.servers.resource_groups : ResourceGroupModule;
        submodules ~= new TablespaceModule;
        submodules ~= new ReplicationNodesModule;
        submodules ~= new PGDReplicationGroupsModule;
        submodules ~= new PgaJobModule;
        submodules ~= new DirectoryModule;
        submodules ~= new ResourceGroupModule;
        registerNodeView!ServerNode(this);
    }
}

/// `with_object_filters`: the Object Explorer filter of the current user.
Value currentObjectFilters()
{
    import pgadmin.settings : getSetting;
    auto data = getSetting("Object Explorer/Filter", "");
    if (data.length == 0)
        return Value.newDict();
    return tryParseJson(data, Value.newDict());
}

// ------------------------------------------------------------ shared servers

private immutable string[] SENSITIVE_CONN_KEYS = ["passfile", "sslcert", "sslkey", "sslrootcert", "sslcrl", "sslcrldir"];

/// `create_shared_server(data, gid)`: the per-user copy of a shared server.
void createSharedServer(Value data, long gid)
{
    auto user = userById(data["user_id"].integer);
    auto safe = new Dict;
    if (data["connection_params"].isDict)
        foreach (k, v; data["connection_params"].dict)
            if (!SENSITIVE_CONN_KEYS.canFind(k))
                safe[k] = v;
    auto row = Value.newDict();
    row["osid"] = data["id"];
    row["user_id"] = Value(currentUserId());
    row["server_owner"] = user["username"];
    row["servergroup_id"] = Value(gid);
    row["name"] = data["name"];
    row["host"] = data["host"];
    row["port"] = data["port"];
    row["maintenance_db"] = data["maintenance_db"];
    row["username"] = data["shared_username"];
    row["save_password"] = Value(0);
    row["comment"] = Value(null);
    row["role"] = data["role"];
    row["bgcolor"] = data["bgcolor"].truthy ? data["bgcolor"] : Value(null);
    row["fgcolor"] = data["fgcolor"].truthy ? data["fgcolor"] : Value(null);
    row["service"] = data["service"].truthy ? data["service"] : Value(null);
    row["use_ssh_tunnel"] = data["use_ssh_tunnel"];
    row["tunnel_host"] = data["tunnel_host"];
    row["tunnel_port"] = data["tunnel_port"].truthy ? data["tunnel_port"] : Value(22);
    row["tunnel_username"] = Value(null);
    row["tunnel_authentication"] = Value(0);
    row["tunnel_identity_file"] = Value(null);
    row["tunnel_keep_alive"] = data["tunnel_keep_alive"].truthy ? data["tunnel_keep_alive"] : Value(0);
    row["tunnel_prompt_password"] = Value(0);
    row["shared"] = Value(true);
    row["connection_params"] = Value(safe);
    row["prepare_threshold"] = data["prepare_threshold"];
    row["passexec_cmd"] = Value(null);
    row["passexec_expiration"] = Value(null);
    row["kerberos_conn"] = Value(false);
    row["tags"] = Value(null);
    row["post_connection_sql"] = Value(null);
    insertRow("sharedserver", row);
}

/// `get_shared_server(server, gid)`
Value getSharedServer(Value server, long gid)
{
    auto q = "SELECT * FROM sharedserver WHERE user_id = ? AND osid = ?";
    auto ss = db.queryOne(q, Value(currentUserId()), server["id"]);
    if (ss.isNone)
    {
        try
            createSharedServer(server, gid);
        catch (SqliteIntegrity)
        {
        }
        ss = db.queryOne(q, Value(currentUserId()), server["id"]);
    }
    if (ss.isNone)
        throw new Exception("Failed to create shared server record for server " ~ server["id"].toString);
    return ss;
}

/// `get_shared_server_properties(server, sharedserver)`: the server overlaid with the user's own settings.
Value getSharedServerProperties(Value server, Value shared_)
{
    if (shared_.isNone)
        return server;
    foreach (k; ["bgcolor", "fgcolor", "name", "role", "service", "use_ssh_tunnel", "tunnel_host", "tunnel_port",
            "tunnel_authentication", "tunnel_username", "tunnel_password", "save_password", "tunnel_identity_file",
            "tunnel_prompt_password", "servergroup_id", "username", "password", "prepare_threshold", "passexec_cmd",
            "passexec_expiration", "kerberos_conn", "tags", "post_connection_sql", "server_owner"])
        server[k] = shared_.get(k);
    auto sConn = server["connection_params"].isDict ? server["connection_params"].dict : new Dict;
    auto ssConn = shared_["connection_params"].isDict ? shared_["connection_params"].dict : new Dict;
    foreach (key; SENSITIVE_CONN_KEYS)
    {
        if (ssConn.has(key))
            sConn[key] = ssConn[key];
        else if (sConn.has(key))
            sConn.pop(key);
    }
    server["connection_params"] = Value(sConn);
    return server;
}

/// Persists the given columns of a server (or shared server) row.
void saveRow(string table, Value row, string[] cols)
{
    auto d = Value.newDict();
    foreach (c; cols)
        d[c] = row[c];
    updateRow(table, d, "id = ?", row["id"]);
}

private Value recoveryStateRow(Connection connection, long postgresVersion, out bool status, out Value result)
{
    auto sql = renderTemplate("connect/sql/#" ~ to!string(postgresVersion) ~ "#/check_recovery.sql");
    auto r = connection.executeDict(sql);
    status = r.ok;
    result = r.value;
    return r.value;
}

struct Recovery
{
    bool status;
    Value result;
    Value inRecovery = Value(null);
    Value walPaused = Value(null);
}

Recovery recoveryState(Connection connection, long postgresVersion)
{
    Recovery r;
    auto sql = renderTemplate("connect/sql/#" ~ to!string(postgresVersion) ~ "#/check_recovery.sql");
    auto res = connection.executeDict(sql);
    r.status = res.ok;
    r.result = res.value;
    if (res.ok && res.value.contains("rows") && res.value["rows"].length > 0)
    {
        r.inRecovery = res.value["rows"][0]["inrecovery"];
        r.walPaused = res.value["rows"][0]["isreplaypaused"];
    }
    return r;
}

// ------------------------------------------------------------ ServerNode

final class ServerNode : PGChildNodeView
{
    this()
    {
        super();
        nodeType = ServerModule.NODE_TYPE;
        nodeLabel = "Server";
        parentIds = [IdSpec("int", "gid")];
        ids = [IdSpec("int", "sid")];
        setOps("supported_servers.js", cast(string[string]) null, cast(string[string]) null, ["get": "supported_servers"]);
        setOps("reload", ["get": "reload_configuration"]);
        setOps("restore_point", ["post": "create_restore_point"]);
        setOps("connect", ["get": "connect_status", "post": "connect", "delete": "disconnect"]);
        setOps("change_password", ["post": "change_password"]);
        setOps("wal_replay", ["delete": "pause_wal_replay", "put": "resume_wal_replay"]);
        setOps("check_pgpass", ["get": "check_pgpass"]);
        setOps("clear_saved_password", ["put": "clear_saved_password"]);
        setOps("clear_sshtunnel_password", ["put": "clear_sshtunnel_password"]);
    }

    override bool nodeCsrfExempt(string cmdName) => cmdName == "supported_servers.js";

    private ServerModule sm() => cast(ServerModule) bpModule;

    override Response callMethod(string name, Dict k)
    {
        if (name == "supported_servers")
            return new Response(renderTemplate("servers/supported_servers.js", ["server_types": Value(serverTypeValues())]),
                    200, MIMETYPE_APP_JS);
        if (!isAuthenticated() && name != "connect" && name != "disconnect")
            return unauthorisedResponse();
        auto gid = k.has("gid") ? k["gid"] : Value(null);
        auto sid = k.has("sid") ? k["sid"] : Value(null);
        switch (name)
        {
        case "nodes": return nodes(gid);
        case "node": return node(gid, sid);
        case "delete": return delete_(gid, sid);
        case "update":
            if (!hasPerm("object_register_server"))
                return forbidden(gettext("Unauthorised access, permission denied."));
            return update(gid, sid);
        case "list": return list(gid);
        case "properties": return properties(gid, sid);
        case "create":
            if (!hasPerm("object_register_server"))
                return forbidden(gettext("Unauthorised access, permission denied."));
            return create(gid);
        case "sql", "modified_sql", "dependencies", "dependents":
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(""));
        case "statistics": return statistics(gid, sid);
        case "connect_status": return connectStatus(gid, sid);
        case "connect": return connect(gid, sid);
        case "disconnect": return disconnect(gid, sid);
        case "reload_configuration": return reloadConfiguration(sid);
        case "create_restore_point": return createRestorePoint(sid);
        case "change_password": return changePassword(gid, sid);
        case "pause_wal_replay": return walReplay(sid, true);
        case "resume_wal_replay": return walReplay(sid, false);
        case "check_pgpass": return checkPgpass(sid);
        case "clear_saved_password": return clearSavedPassword(gid, sid);
        case "clear_sshtunnel_password": return clearSshtunnelPassword(gid, sid);
        default: return super.callMethod(name, k);
        }
    }

    private static bool hasPerm(string p)
    {
        import pgadmin.model : userHasPermission;
        return userHasPermission(currentUserId(), p);
    }

    private static Value[] serverTypeValues()
    {
        Value[] r;
        foreach (st; ServerType.types())
            r ~= Value(st);
        return r;
    }

    // ---- connection parameter / tags updates

    private void updateConnectionParameter(Value data, Value server, Value sharedserver = Value(null))
    {
        if (!data.contains("connection_params"))
            return;
        Dict existing;
        if (!sharedserver.isNone && server["shared"].truthy && server["user_id"].integer != currentUserId())
            existing = sharedserver["connection_params"].isDict ? sharedserver["connection_params"].dict.copy() : new Dict;
        else
            existing = server["connection_params"].isDict ? server["connection_params"].dict : new Dict;
        auto np = data["connection_params"];
        if (np.contains("deleted"))
            foreach (item; np["deleted"].iterItems())
                existing.pop(item["name"].toString);
        if (np.contains("added"))
            foreach (item; np["added"].iterItems())
                existing[item["name"].toString] = item["value"];
        if (np.contains("changed"))
            foreach (item; np["changed"].iterItems())
                existing[item["name"].toString] = item["value"];
        data["connection_params"] = Value(existing);
    }

    private static void updateTags(Value data, Value server)
    {
        Value[] oldTags;
        if (server["tags"].isList)
            foreach (t; server["tags"].list.items)
            {
                auto c = t.dict.copy();
                c["old_text"] = t["text"];
                oldTags ~= Value(c);
            }
        auto newInfo = data.get("tags");
        if (newInfo.isNone)
            return;
        if (newInfo.contains("deleted"))
        {
            Value[] ids;
            foreach (t; newInfo["deleted"].iterItems())
                ids ~= t["old_text"];
            Value[] keep;
            foreach (t; oldTags)
                if (!ids.canFind(t["old_text"]))
                    keep ~= t;
            oldTags = keep;
        }
        if (newInfo.contains("changed"))
            foreach (changed; newInfo["changed"].iterItems())
                foreach (ref item; oldTags)
                    if (item["old_text"] == changed["old_text"])
                    {
                        auto m = item.dict.copy();
                        m.update(changed.dict);
                        item = Value(m);
                        break;
                    }
        if (newInfo.contains("added"))
            foreach (item; newInfo["added"].iterItems())
                oldTags ~= item;
        Value[] cleaned;
        foreach (t; oldTags)
        {
            auto d = new Dict;
            foreach (k, v; t.dict)
                if (k != "old_text")
                    d[k] = v;
            cleaned ~= Value(d);
        }
        data["tags"] = Value(cleaned);
    }

    // ---- nodes

    Response nodes(Value gid)
    {
        Value[] res;
        auto driver = getDriver();
        foreach (server; getUserServers("servergroup_id = ? AND is_adhoc = 0", [gid]))
        {
            if (isNonOwner(server))
            {
                auto ss = getSharedServer(server, gid.integer);
                server = getSharedServerProperties(server, ss);
            }
            auto manager = driver.connectionManager(server["id"].integer);
            auto conn = manager.connection();
            bool connected = conn.connected();
            Value errmsg = Value(null), inRecovery = Value(null), walPaused = Value(null);
            string serverType = "pg";
            if (connected)
            {
                serverType = manager.serverType;
                auto rs = recoveryState(conn, manager.version_);
                inRecovery = rs.inRecovery;
                walPaused = rs.walPaused;
                if (!rs.status)
                {
                    connected = false;
                    manager.release();
                    errmsg = Value(server["name"].toString ~ " : " ~ rs.result.toString);
                }
            }
            auto kw = new Dict;
            kw["connected"] = Value(connected);
            kw["server_type"] = Value(serverType);
            kw["version"] = manager.versionValue;
            kw["db"] = manager.db is null ? Value(null) : Value(manager.db);
            kw["host"] = server["host"];
            kw["user"] = connected && manager.userInfo !is null ? Value(manager.userInfo) : Value(null);
            kw["in_recovery"] = inRecovery;
            kw["wal_pause"] = walPaused;
            kw["is_password_saved"] = Value(server.get("save_password").truthy);
            kw["is_tunnel_password_saved"] = Value(server.get("tunnel_password").truthy);
            kw["errmsg"] = errmsg;
            kw["username"] = server["username"];
            kw["shared"] = server["shared"];
            kw["is_kerberos_conn"] = Value(server.get("kerberos_conn").truthy);
            kw["gss_authenticated"] = Value(manager.gssAuthenticated);
            kw["description"] = server["comment"];
            kw["tags"] = server["tags"];
            res ~= blueprint.generateBrowserNode(Value(server["id"].toString), gid, server["name"].toString,
                    serverIconAndBackground(connected, manager, server), true, nodeType, kw);
        }
        if (res.length == 0)
            return gone(gettext("The specified server group with id# {0} could not be found."));
        return makeJsonResponse(1, Value(""), Value(""), Value(res));
    }

    Response node(Value gid, Value sid)
    {
        auto server = getServer(sid.integer);
        if (server.isNone)
            return makeJsonResponse(0, Value(gettext("Could not find the server with id# {0}.").replace("{0}", sid.toString)),
                    Value(""), Value(null), Value(null), 410);
        if (isNonOwner(server))
            server = getSharedServerProperties(server, getSharedServer(server, gid.integer));
        auto manager = getDriver().connectionManager(server["id"].integer);
        auto conn = manager.connection();
        bool connected = conn.connected();
        Value errmsg = Value(null), inRecovery = Value(null), walPaused = Value(null);
        if (connected)
        {
            try
            {
                auto rs = recoveryState(conn, manager.version_);
                inRecovery = rs.inRecovery;
                walPaused = rs.walPaused;
                if (!rs.status)
                {
                    connected = false;
                    manager.release();
                    errmsg = Value(server["name"].toString ~ " : " ~ rs.result.toString);
                }
            }
            catch (ConnectionLost)
            {
                connected = false;
                manager.release();
            }
        }
        auto kw = new Dict;
        kw["connected"] = Value(connected);
        kw["server_type"] = Value(connected ? manager.serverType : "pg");
        kw["version"] = manager.versionValue;
        kw["db"] = manager.db is null ? Value(null) : Value(manager.db);
        kw["user"] = connected && manager.userInfo !is null ? Value(manager.userInfo) : Value(null);
        kw["in_recovery"] = inRecovery;
        kw["wal_pause"] = walPaused;
        kw["host"] = server["host"];
        kw["is_password_saved"] = Value(server.get("save_password").truthy);
        kw["is_tunnel_password_saved"] = Value(!server.get("tunnel_password").isNone);
        kw["errmsg"] = errmsg;
        kw["shared"] = server["shared"];
        kw["username"] = server["username"];
        kw["is_kerberos_conn"] = Value(server.get("kerberos_conn").truthy);
        kw["gss_authenticated"] = Value(manager.gssAuthenticated);
        kw["tags"] = server["tags"];
        return makeJsonResponse(1, Value(""), Value(""), blueprint.generateBrowserNode(Value(server["id"].toString), gid,
                server["name"].toString, serverIconAndBackground(connected, manager, server), true, nodeType, kw));
    }

    void deleteSharedServer(Value gid, Value osid, Value userId = Value(null))
    {
        try
        {
            string q = "SELECT * FROM sharedserver WHERE servergroup_id = ? AND osid = ?";
            Value[] p = [gid, osid];
            if (!userId.isNone)
            {
                q ~= " AND user_id = ?";
                p ~= userId;
            }
            foreach (s; db.query(q, p))
            {
                getDriver().deleteManager(s["id"].integer);
                db.exec("DELETE FROM sharedserver WHERE id = ?", s["id"]);
            }
        }
        catch (Exception e)
            logException(e);
    }

    Response delete_(Value gid, Value sid)
    {
        auto servers = db.query("SELECT * FROM server WHERE user_id = ? AND id = ?", Value(currentUserId()), sid);
        try
        {
            foreach (s; servers)
            {
                getDriver().deleteManager(s["id"].integer);
                db.exec("DELETE FROM server WHERE id = ?", s["id"]);
            }
            deleteSharedServer(gid, sid);
            import pgadmin.tools.sqleditor.utils.query_history : clearHistory;
            clearHistory(currentUserId(), sid.integer);
        }
        catch (Exception e)
        {
            logException(e);
            return makeJsonResponse(0, Value(e.msg));
        }
        return makeJsonResponse(1, Value(""), Value(gettext("Server deleted")));
    }

    Response list(Value gid)
    {
        auto servers = getUserServers("servergroup_id = ? AND is_adhoc = 0", [gid], "name");
        auto sg = getServerGroup(gid);
        Value[] res;
        auto driver = getDriver();
        foreach (server; servers)
        {
            if (isNonOwner(server))
                server = getSharedServerProperties(server, getSharedServer(server, gid.integer));
            auto manager = driver.connectionManager(server["id"].integer);
            auto conn = manager.connection();
            bool connected = conn.connected();
            auto d = new Dict;
            d["id"] = server["id"];
            d["name"] = server["name"];
            d["host"] = server["host"];
            d["port"] = server["port"];
            d["db"] = server["maintenance_db"];
            d["username"] = server["username"];
            d["gid"] = server["servergroup_id"];
            d["group-name"] = sg["name"];
            d["comment"] = server["comment"];
            d["role"] = server["role"];
            d["connected"] = Value(connected);
            d["version"] = manager.ver.length ? Value(manager.ver) : Value(null);
            d["server_type"] = Value(connected ? manager.serverType : "pg");
            d["db_res"] = getDbRestriction(server["db_res_type"], server["db_res"]);
            res ~= Value(d);
        }
        return makeResponse(Value(res));
    }

    Response properties(Value gid, Value sid)
    {
        auto server = getServer(sid.integer);
        if (server.isNone)
            return makeJsonResponse(0, Value(notFoundErrorMsg()), Value(""), Value(null), Value(null), 410);
        Value serverOwner = Value(null);
        auto sg = serverGroupById(server["servergroup_id"].integer);
        auto manager = getDriver().connectionManager(sid.integer);
        auto conn = manager.connection();
        bool connected = conn.connected();
        auto displayConnectionStr = updateConnectionString(manager, server);
        if (isNonOwner(server))
        {
            server = getSharedServerProperties(server, getSharedServer(server, gid.integer));
            serverOwner = server["server_owner"];
        }
        bool useSshTunnel;
        Value tunnelHost = Value(null);
        Value tunnelPort = Value(22);
        Value tunnelUsername = Value(null);
        bool tunnelAuthentication;
        Value tunnelKeepAlive = Value(0);
        auto connectionParams = convertConnectionParameter(server["connection_params"]);
        if (server["use_ssh_tunnel"].truthy)
        {
            useSshTunnel = true;
            tunnelHost = server["tunnel_host"];
            tunnelPort = server["tunnel_port"];
            tunnelUsername = server["tunnel_username"];
            tunnelAuthentication = server["tunnel_authentication"].truthy;
            tunnelKeepAlive = server["tunnel_keep_alive"];
        }
        Value tags = Value(null);
        if (server["tags"].isList)
        {
            Value[] t;
            foreach (tag; server["tags"].list.items)
            {
                auto c = tag.dict.copy();
                c["old_text"] = tag["text"];
                t ~= Value(c);
            }
            tags = Value(t);
        }
        auto r = new Dict;
        r["id"] = server["id"];
        r["name"] = server["name"];
        r["server_owner"] = serverOwner;
        r["user_id"] = server["user_id"];
        r["host"] = server["host"];
        r["port"] = server["port"];
        r["db"] = server["maintenance_db"];
        r["password"] = server["password"].isNone ? Value(null) : Value(binaryColumn(server["password"]));
        r["save_password"] = server["save_password"];
        r["shared"] = cfgBool("SERVER_MODE") ? server["shared"] : Value(null);
        r["shared_username"] = cfgBool("SERVER_MODE") ? server["shared_username"] : Value(null);
        r["username"] = server["username"];
        r["gid"] = Value(server["servergroup_id"].toString);
        r["group-name"] = sg.isDict && sg["name"].truthy ? sg["name"] : Value(gettext("Servers"));
        r["comment"] = server["comment"];
        r["role"] = server["role"];
        r["connected"] = Value(connected);
        r["version"] = manager.ver.length ? Value(manager.ver) : Value(null);
        r["server_type"] = Value(connected ? manager.serverType : "pg");
        r["bgcolor"] = server["bgcolor"];
        r["fgcolor"] = server["fgcolor"];
        r["db_res"] = getDbRestriction(server["db_res_type"], server["db_res"]);
        r["db_res_type"] = server["db_res_type"];
        r["passexec_cmd"] = server["passexec_cmd"];
        r["passexec_expiration"] = server["passexec_expiration"];
        r["service"] = server["service"].truthy ? server["service"] : Value(null);
        r["use_ssh_tunnel"] = Value(useSshTunnel);
        r["tunnel_host"] = tunnelHost;
        r["tunnel_port"] = tunnelPort;
        r["tunnel_username"] = tunnelUsername;
        r["tunnel_identity_file"] = server["tunnel_identity_file"].truthy ? server["tunnel_identity_file"] : Value(null);
        r["tunnel_prompt_password"] = server["tunnel_identity_file"].truthy ? server["tunnel_prompt_password"] : Value(0);
        r["tunnel_authentication"] = Value(tunnelAuthentication);
        r["tunnel_keep_alive"] = tunnelKeepAlive;
        r["kerberos_conn"] = Value(server["kerberos_conn"].truthy);
        r["gss_authenticated"] = Value(manager.gssAuthenticated);
        r["gss_encrypted"] = Value(manager.gssEncrypted);
        r["cloud_status"] = server["cloud_status"];
        r["connection_params"] = connectionParams;
        r["connection_string"] = displayConnectionStr;
        r["prepare_threshold"] = server["prepare_threshold"];
        r["tags"] = tags;
        r["post_connection_sql"] = server["post_connection_sql"];
        return makeResponse(Value(r));
    }

    /// `update_connection_string(manager, server)`: the display string with host/port/dbname/user first.
    static string updateConnectionString(ServerManager manager, Value server)
    {
        import pgadmin.db.pgconn : conninfoToDict, makeConninfo;
        auto info = conninfoToDict(manager.displayConnectionString);
        string dbName;
        bool hasHost, hasPort, hasUser;
        foreach (p; info)
        {
            if (p[0] == "dbname")
                dbName = p[1];
            hasHost = hasHost || p[0] == "host";
            hasPort = hasPort || p[0] == "port";
            hasUser = hasUser || p[0] == "user";
        }
        string[2][] ordered = [["host", server["host"].isNone ? null : server["host"].toString],
            ["port", server["port"].isNone ? null : server["port"].toString], ["dbname", dbName], ["user", manager.user]];
        foreach (p; info)
        {
            if (hasHost && hasPort && hasUser && (p[0] == "host" || p[0] == "port" || p[0] == "user"))
                continue;
            bool found;
            foreach (ref o; ordered)
                if (o[0] == p[0])
                {
                    o[1] = p[1];
                    found = true;
                }
            if (!found)
                ordered ~= p;
        }
        return makeConninfo(ordered);
    }

    // ---- create / update

    Response create(Value gid)
    {
        string[] requiredArgs = ["name", "db"];
        auto data = formOrJson(request());
        foreach (item; data.dict.keys)
            if (data[item].isString && data[item].str == "")
                data[item] = Value(null);
        auto ck = getCryptKey();
        if (!ck.present)
            throw new CryptKeyMissing();
        if (data.contains("service") && !data["service"].truthy)
            requiredArgs ~= ["host", "port", "username", "role"];
        foreach (arg; requiredArgs)
            if (!data.contains(arg))
                return makeJsonResponse(0, Value(gettext("Could not find the required parameter ({}).").replace("{}", arg)),
                        Value(""), Value(null), Value(null), 410);
        auto rawParams = data.contains("connection_params") ? data["connection_params"] : Value.newList();
        Value connectionParams = rawParams.isDict ? rawParams : convertConnectionParameter(rawParams);
        if (!connectionParams.isDict)
            connectionParams = Value.newDict();
        if (connectionParams.contains("hostaddr") && !isValidIpAddress(connectionParams["hostaddr"].toString))
            return makeJsonResponse(0, Value(gettext("Not a valid Host address")), Value(""), Value(null), Value(null), 400);
        checkSslFields(connectionParams);
        if (data.contains("connection_params"))
            data["connection_params"] = connectionParams;
        Value dbRestriction = Value(null);
        if (data.contains("db_res") && data["db_res"].isList)
        {
            string[] ps;
            foreach (x; data["db_res"].iterItems())
                ps ~= x.toString;
            import std.array : join;
            dbRestriction = Value(ps.join(","));
        }
        else if (data.contains("db_res") && data.contains("db_res_type") && data["db_res_type"].toString == RESTRICTION_TYPE_SQL)
            dbRestriction = data["db_res"];

        long serverId = -1;
        try
        {
            Value g(string k, Value def = Value(null)) => data.contains(k) ? data[k] : def;
            auto row = Value.newDict();
            row["user_id"] = Value(currentUserId());
            row["servergroup_id"] = g("gid", gid);
            row["name"] = g("name");
            row["host"] = g("host");
            row["port"] = g("port");
            row["maintenance_db"] = g("db");
            row["username"] = g("username");
            row["save_password"] = Value(g("save_password", Value(false)).truthy && cfgBool("ALLOW_SAVE_PASSWORD") ? 1 : 0);
            row["comment"] = g("comment");
            row["role"] = g("role");
            row["db_res"] = dbRestriction;
            if (!g("db_res_type").isNone)
                row["db_res_type"] = g("db_res_type");
            row["bgcolor"] = g("bgcolor");
            row["fgcolor"] = g("fgcolor");
            row["service"] = g("service");
            row["use_ssh_tunnel"] = Value(g("use_ssh_tunnel", Value(false)).truthy ? 1 : 0);
            row["tunnel_host"] = g("tunnel_host");
            row["tunnel_port"] = g("tunnel_port", Value(22));
            row["tunnel_username"] = g("tunnel_username");
            row["tunnel_authentication"] = Value(g("tunnel_authentication", Value(false)).truthy ? 1 : 0);
            row["tunnel_identity_file"] = g("tunnel_identity_file");
            row["tunnel_prompt_password"] = Value(g("tunnel_prompt_password", Value(true)).truthy ? 1 : 0);
            row["tunnel_keep_alive"] = g("tunnel_keep_alive", Value(0));
            row["shared"] = g("shared");
            row["shared_username"] = g("shared_username");
            row["passexec_cmd"] = g("passexec_cmd");
            row["passexec_expiration"] = g("passexec_expiration");
            row["kerberos_conn"] = Value(g("kerberos_conn", Value(false)).truthy ? 1 : 0);
            row["connection_params"] = connectionParams;
            row["prepare_threshold"] = g("prepare_threshold");
            row["tags"] = g("tags");
            row["post_connection_sql"] = g("post_connection_sql");
            row["cloud_status"] = Value(0);
            row["is_adhoc"] = Value(0);
            serverId = insertRow("server", row);
            auto server = serverById(serverId);

            bool connected;
            Value user = Value(null);
            ServerManager manager;
            Value replicationType = Value(null);
            bool tunnelPasswordSaved;
            if (data.contains("connect_now") && data["connect_now"].truthy)
            {
                manager = getDriver().connectionManager(serverId);
                manager.update(server);
                auto conn = manager.connection();
                bool havePassword, haveTunnelPassword;
                string password, tunnelPassword;
                if (data.contains("password") && data["password"].truthy)
                {
                    havePassword = true;
                    password = encrypt(data["password"].toString, ck.key);
                }
                if (data.contains("tunnel_password") && data["tunnel_password"].toString != "")
                {
                    haveTunnelPassword = true;
                    tunnelPassword = encrypt(data["tunnel_password"].toString, ck.key);
                }
                auto kwargs = new Dict;
                if (password.length)
                    kwargs["password"] = password;
                kwargs["tunnel_password"] = tunnelPassword;
                auto st = conn.connect(kwargs);
                if (!st.ok)
                {
                    db.exec("DELETE FROM server WHERE id = ?", Value(serverId));
                    return makeJsonResponse(0, Value(gettext("Unable to connect to server:\n\n{}").replace("{}", st.error)),
                            Value(""), Value(null), Value(null), 401);
                }
                if (data.get("save_password").truthy && havePassword && cfgBool("ALLOW_SAVE_PASSWORD"))
                    db.exec("UPDATE server SET password = ? WHERE id = ?", toBinaryColumn(password), Value(serverId));
                if (data.get("save_tunnel_password").truthy && haveTunnelPassword && cfgBool("ALLOW_SAVE_TUNNEL_PASSWORD"))
                    db.exec("UPDATE server SET tunnel_password = ? WHERE id = ?", toBinaryColumn(tunnelPassword), Value(serverId));
                replicationType = getReplicationType(conn, manager.version_);
                user = manager.userInfo is null ? Value(null) : Value(manager.userInfo);
                connected = true;
                server = serverById(serverId);
            }
            auto kw = new Dict;
            kw["username"] = server["username"];
            kw["user"] = user;
            kw["connected"] = Value(connected);
            kw["replication_type"] = replicationType;
            kw["shared"] = server["shared"];
            kw["server_type"] = Value(manager !is null && manager.serverType.length ? manager.serverType : "pg");
            kw["version"] = manager !is null && manager.version_ ? Value(manager.version_) : Value(null);
            kw["is_kerberos_conn"] = Value(server["kerberos_conn"].truthy);
            kw["gss_authenticated"] = Value(manager !is null && manager.gssAuthenticated);
            kw["is_password_saved"] = Value(server["save_password"].truthy);
            kw["is_tunnel_password_saved"] = Value(tunnelPasswordSaved);
            kw["user_id"] = server["user_id"];
            kw["tags"] = g("tags");
            return jsonify(Value.dictOf("node", blueprint.generateBrowserNode(Value(server["id"].toString),
                    server["servergroup_id"], server["name"].toString,
                    serverIconAndBackground(connected, manager, server), true, nodeType, kw)));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
        {
            if (serverId >= 0)
                db.exec("DELETE FROM server WHERE id = ?", Value(serverId));
            logException(e);
            return makeJsonResponse(0, Value(e.msg), Value(""), Value(null), Value(null), 410);
        }
    }

    private static immutable string[string] configParamMap = [
        "name": "name", "host": "host", "port": "port", "db": "maintenance_db", "username": "username",
        "password": "password", "save_password": "save_password", "gid": "servergroup_id", "comment": "comment",
        "role": "role", "db_res": "db_res", "db_res_type": "db_res_type", "passexec_cmd": "passexec_cmd",
        "passexec_expiration": "passexec_expiration", "bgcolor": "bgcolor", "fgcolor": "fgcolor", "service": "service",
        "use_ssh_tunnel": "use_ssh_tunnel", "tunnel_host": "tunnel_host", "tunnel_port": "tunnel_port",
        "tunnel_username": "tunnel_username", "tunnel_authentication": "tunnel_authentication",
        "tunnel_identity_file": "tunnel_identity_file", "tunnel_prompt_password": "tunnel_prompt_password",
        "tunnel_keep_alive": "tunnel_keep_alive", "shared": "shared", "shared_username": "shared_username",
        "kerberos_conn": "kerberos_conn", "connection_params": "connection_params",
        "prepare_threshold": "prepare_threshold", "tags": "tags", "post_connection_sql": "post_connection_sql",
    ];
    // the order the Python dict iterates
    private static immutable string[] configParamOrder = [
        "name", "host", "port", "db", "username", "password", "save_password", "gid", "comment", "role", "db_res",
        "db_res_type", "passexec_cmd", "passexec_expiration", "bgcolor", "fgcolor", "service", "use_ssh_tunnel",
        "tunnel_host", "tunnel_port", "tunnel_username", "tunnel_authentication", "tunnel_identity_file",
        "tunnel_prompt_password", "tunnel_keep_alive", "shared", "shared_username", "kerberos_conn",
        "connection_params", "prepare_threshold", "tags", "post_connection_sql",
    ];

    Response update(Value gid, Value sid)
    {
        auto server = getServer(sid.integer);
        Value sharedserver = Value(null);
        if (server.isNone)
            return makeJsonResponse(0, Value(gettext("Could not find the required server.")), Value(""), Value(null),
                    Value(null), 410);
        if (cfgBool("SERVER_MODE") && server["shared"].truthy && server["user_id"].integer != currentUserId())
            sharedserver = getSharedServer(server, gid.integer);
        auto dispLbl = ["name": gettext("name"), "port": gettext("Port"), "db": gettext("Maintenance database"),
            "username": gettext("Username"), "comment": gettext("Comments"), "role": gettext("Role")];
        auto data = formOrJson(request());
        if (data.contains("db_res") && data["db_res"].isList)
        {
            import std.array : join;
            string[] ps;
            foreach (x; data["db_res"].iterItems())
                ps ~= x.toString;
            data["db_res"] = Value(ps.join(","));
        }
        updateConnectionParameter(data, server, sharedserver);
        updateTags(data, sharedserver.isNone ? server : sharedserver);
        if (data.contains("connection_params") && data["connection_params"].contains("hostaddr")
                && !isValidIpAddress(data["connection_params"]["hostaddr"].toString))
            return makeJsonResponse(0, Value(gettext("Not a valid Host address")), Value(""), Value(null), Value(null), 400);
        if (data.contains("shared") && data["shared"].isBool && !data["shared"].boolean)
            data["shared_username"] = Value("");
        auto manager = getDriver().connectionManager(sid.integer);
        auto conn = manager.connection();
        bool connected = conn.connected();
        if (connected)
            foreach (arg; ["db", "role", "service"])
                if (data.contains(arg))
                    return forbidden(gettext("'%s' cannot be modified when the server is connected.")
                            .replace("%s", dispLbl[arg]));
        // _set_valid_attr_value
        auto ck = getCryptKey();
        if (!ck.present)
            throw new CryptKeyMissing();
        int idx;
        string[] ownerOnly = ["passexec_cmd", "passexec_expiration", "db_res", "db_res_type"];
        string[] changedCols;
        string[] changedColsShared;
        foreach (arg; configParamOrder)
        {
            if (!data.contains(arg))
                continue;
            if (isNonOwner(server) && ownerOnly.canFind(arg))
                continue;
            auto value = data[arg];
            if (arg == "password")
                value = toBinaryColumn(encrypt(data[arg].toString, ck.key));
            if (data.contains("shared") && !data["shared"].truthy && !isNonOwner(server))
                deleteSharedServer(gid, server["id"]);
            if (["sslcompression", "use_ssh_tunnel", "tunnel_authentication", "kerberos_conn", "shared"].canFind(arg))
                value = Value(value.truthy ? 1 : 0);
            if (value.isString && value.str == "")
                value = Value(null);
            auto col = configParamMap[arg];
            if (isNonOwner(server))
            {
                sharedserver[col] = value;
                changedColsShared ~= col;
            }
            else
            {
                server[col] = value;
                changedCols ~= col;
            }
            idx++;
        }
        if (idx == 0)
            return makeJsonResponse(0, Value(gettext("No parameters were changed.")));
        try
        {
            if (changedCols.length)
                saveRow("server", server, changedCols);
            if (changedColsShared.length)
                saveRow("sharedserver", sharedserver, changedColsShared);
            if (data.contains("tags"))
            {
                auto target = sharedserver.isNone ? server : sharedserver;
                db.exec("UPDATE " ~ (sharedserver.isNone ? "server" : "sharedserver") ~ " SET tags = ? WHERE id = ?",
                        target["tags"], target["id"]);
            }
        }
        catch (Exception e)
        {
            logException(e);
            return makeJsonResponse(0, Value(e.msg));
        }
        if (!conn.connected())
        {
            manager.update(server);
            if (isNonOwner(server))
                manager.passexecCmd = null;
        }
        auto kw = new Dict;
        kw["connected"] = Value(connected);
        kw["shared"] = server["shared"];
        kw["user_id"] = server["user_id"];
        kw["user"] = connected && manager.userInfo !is null ? Value(manager.userInfo) : Value(null);
        kw["server_type"] = Value("pg");
        kw["username"] = server["username"];
        kw["role"] = server["role"];
        kw["is_password_saved"] = Value(server["save_password"].truthy);
        kw["description"] = server["comment"];
        kw["tags"] = sharedserver.isNone ? server["tags"] : sharedserver["tags"];
        return jsonify(Value.dictOf("node", blueprint.generateBrowserNode(Value(server["id"].toString),
                server["servergroup_id"], server["name"].toString,
                isNonOwner(server) ? serverIconAndBackground(connected, manager, sharedserver)
                : serverIconAndBackground(connected, manager, server), true, nodeType, kw)));
    }

    // ---- statistics

    Response statistics(Value gid, Value sid)
    {
        auto manager = getDriver().connectionManager(sid.integer);
        auto conn = manager.connection();
        if (conn.connected())
        {
            auto r = conn.executeDict(renderTemplate("/servers/sql/#" ~ to!string(manager.version_) ~ "#/stats.sql",
                    ["conn": Value(conn)]));
            if (!r.ok)
                return internalServerError(r.error);
            return makeJsonResponse(1, Value(""), Value(""), Value(null), r.value);
        }
        return makeJsonResponse(1, Value(""), Value(gettext("Server has no active connection for generating statistics.")));
    }

    // ---- connect / disconnect

    private Response connectStatus(Value gid, Value sid)
    {
        auto server = getServer(sid.integer);
        if (server.isNone)
            return makeJsonResponse(0, Value(notFoundErrorMsg()), Value(""), Value(null), Value(null), 410);
        auto manager = getDriver().connectionManager(sid.integer);
        auto conn = manager.connection();
        bool connected = conn.connected();
        Value inRecovery = Value(null), walPaused = Value(null), errmsg = Value(null), replicationType = Value(null);
        if (connected)
        {
            auto rs = recoveryState(conn, manager.version_);
            inRecovery = rs.inRecovery;
            walPaused = rs.walPaused;
            if (!rs.status)
            {
                connected = false;
                manager.release();
                errmsg = Value(server["name"].toString ~ " : " ~ rs.result.toString);
            }
            replicationType = getReplicationType(conn, manager.version_);
        }
        auto d = new Dict;
        d["icon"] = serverIconAndBackground(connected, manager, server);
        d["connected"] = Value(connected);
        d["replication_type"] = replicationType;
        d["in_recovery"] = inRecovery;
        d["wal_pause"] = walPaused;
        d["server_type"] = Value(connected ? manager.serverType : "pg");
        d["user"] = connected && manager.userInfo !is null ? Value(manager.userInfo) : Value(null);
        d["errmsg"] = errmsg;
        return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(d));
    }

    private bool isPromptTunnelPassword(Value server)
    {
        bool prompt = true;
        if (!server["tunnel_password"].isNone || (!server["tunnel_identity_file"].isNone && server["tunnel_prompt_password"].integer != 1))
            prompt = false;
        return prompt;
    }

    Response connect(Value gid, Value sid, bool isQt = false, Value serverArg = Value(null))
    {
        logInfo("Connection Request for server#" ~ sid.toString);
        auto server = serverArg.isNone ? getServer(sid.integer) : serverArg;
        if (server.isNone)
            return badRequest(notFoundErrorMsg());
        Value sharedServer = Value(null);
        if (isNonOwner(server))
        {
            sharedServer = getSharedServer(server, gid.integer);
            server = getSharedServerProperties(server, sharedServer);
        }
        if (server["username"].isNone && !server["service"].truthy && server["shared"].truthy)
            return makeJsonResponse(0, Value(gettext("Please enter the server details to connect")));
        if (!isAuthenticated() || userById(currentUserId()).isNone)
            return unauthorized(gettext(UNAUTH_REQ));

        auto req = request();
        Value data = Value.newDict();
        if (!req.form.empty)
            data = req.form.toDict;
        else if (req.data.length)
            data = parseJson(req.text);

        string password, passfile, tunnelPassword;
        bool savePassword, saveTunnelPassword, promptPassword, promptTunnelPassword;

        auto manager = getDriver().connectionManager(sid.integer);
        if (!manager.connection().connected() && !isQt)
        {
            manager.update(server);
            if (isNonOwner(server))
                manager.passexecCmd = null;
        }
        auto conn = manager.connection();
        auto ck = getCryptKey();
        if (!ck.present)
            throw new CryptKeyMissing();

        if (server["use_ssh_tunnel"].truthy)
        {
            if (!data.contains("tunnel_password") && server["tunnel_password"].isNone)
                promptTunnelPassword = isPromptTunnelPassword(server);
            else if (!data.contains("tunnel_password") && !server["tunnel_password"].isNone)
                tunnelPassword = binaryColumn(server["tunnel_password"]);
            else
            {
                tunnelPassword = data.contains("tunnel_password") ? data["tunnel_password"].toString : "";
                saveTunnelPassword = tunnelPassword.length && data.contains("save_tunnel_password")
                    ? data["save_tunnel_password"].truthy : false;
                tunnelPassword = encrypt(tunnelPassword, ck.key);
            }
        }
        if (!data.contains("password") && !server["kerberos_conn"].truthy)
        {
            Value passfileParam = server["connection_params"].isDict && server["connection_params"].contains("passfile")
                ? server["connection_params"]["passfile"] : Value(null);
            auto connPasswd = conn.password;
            if (connPasswd is null && !server["save_password"].truthy && passfileParam.isNone
                    && server["passexec_cmd"].isNone && server["service"].isNone)
                promptPassword = true;
            else if (passfileParam.truthy && getCompleteFilePath(passfileParam.toString) !is null)
                passfile = passfileParam.toString;
            else
                password = connPasswd !is null ? connPasswd : binaryColumn(server["password"]);
        }
        else
        {
            auto pw = data.contains("password") ? data["password"] : Value(null);
            savePassword = data.contains("save_password") ? data["save_password"].truthy : false;
            if (!pw.isNone)
                password = encrypt(pw.toString, ck.key);
            else
                password = binaryColumn(server["password"]);
        }
        if (promptPassword || promptTunnelPassword)
            return responseForPassword(server, 428, promptPassword, promptTunnelPassword);
        promptTunnelPassword = isPromptTunnelPassword(server);

        Res status;
        try
        {
            auto kwargs = new Dict;
            if (password.length)
                kwargs["password"] = password;
            kwargs["tunnel_password"] = tunnelPassword;
            status = conn.connect(kwargs);
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return responseForPassword(server, 401, !server["save_password"].truthy, promptTunnelPassword, e.msg);
        if (!status.ok)
        {
            logError("Could not connect to server(#" ~ server["id"].toString ~ ") - '" ~ server["name"].toString
                    ~ "'.\nError: " ~ status.error);
            if (status.error.canFind("Ticket expired"))
                return internalServerError(status.error);
            return responseForPassword(server, 401, !server["save_password"].truthy, promptTunnelPassword, status.error);
        }
        if (savePassword && cfgBool("ALLOW_SAVE_PASSWORD"))
        {
            try
            {
                auto table = isNonOwner(server) ? "sharedserver" : "server";
                auto id = isNonOwner(server) ? sharedServer["id"] : server["id"];
                db.exec("UPDATE " ~ table ~ " SET save_password = 1 WHERE id = ?", id);
                if (password.length)
                    db.exec("UPDATE " ~ table ~ " SET password = ? WHERE id = ?", toBinaryColumn(password), id);
                server["save_password"] = Value(1);
            }
            catch (Exception e)
            {
                logException(e);
                manager.release(server["maintenance_db"].strOr(null));
                return internalServerError(e.msg);
            }
        }
        if (saveTunnelPassword && cfgBool("ALLOW_SAVE_TUNNEL_PASSWORD"))
        {
            try
            {
                auto table = isNonOwner(server) ? "sharedserver" : "server";
                auto id = isNonOwner(server) ? sharedServer["id"] : server["id"];
                db.exec("UPDATE " ~ table ~ " SET tunnel_password = ? WHERE id = ?", toBinaryColumn(tunnelPassword), id);
            }
            catch (Exception e)
            {
                logException(e);
                manager.release(server["maintenance_db"].strOr(null));
                return internalServerError(e.msg);
            }
        }
        logInfo("Connection Established for server: " ~ server["id"].toString ~ " - " ~ server["name"].toString);
        auto rs = recoveryState(conn, manager.version_);
        auto replicationType = getReplicationType(conn, manager.version_);
        auto d = new Dict;
        d["sid"] = server["id"];
        d["did"] = manager.did;
        d["icon"] = serverIconAndBackground(true, manager, server);
        d["connected"] = Value(true);
        d["server_type"] = Value(manager.serverType);
        d["replication_type"] = replicationType;
        d["type"] = Value(manager.serverType);
        d["version"] = manager.versionValue;
        d["db"] = Value(manager.db);
        d["user"] = manager.userInfo is null ? Value(null) : Value(manager.userInfo);
        d["in_recovery"] = rs.inRecovery;
        d["wal_pause"] = rs.walPaused;
        d["is_password_saved"] = Value(server["save_password"].truthy);
        d["is_tunnel_password_saved"] = Value(!server["tunnel_password"].isNone);
        d["is_kerberos_conn"] = Value(server["kerberos_conn"].truthy);
        d["gss_authenticated"] = Value(manager.gssAuthenticated);
        return makeJsonResponse(1, status.value, Value(gettext("Server connected.")), Value(null), Value(d));
    }

    Response disconnect(Value gid, Value sid)
    {
        auto server = getServer(sid.integer);
        if (server.isNone)
            return badRequest(notFoundErrorMsg());
        auto manager = getDriver().connectionManager(sid.integer);
        auto status = manager.release();
        if (!status)
            return unauthorized(gettext("Server could not be disconnected."));
        return makeJsonResponse(1, Value(""), Value(gettext("Server disconnected.")), Value(null),
                Value.dictOf("icon", serverIconAndBackground(false, manager, server), "connected", false));
    }

    Response reloadConfiguration(Value sid)
    {
        auto manager = getDriver().connectionManager(sid.integer);
        auto conn = manager.connection();
        if (conn.connected())
        {
            auto r = conn.executeScalar("SELECT pg_catalog.pg_reload_conf();");
            if (!r.ok)
                return internalServerError(gettext("Could not reload the server configuration."));
            return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    Value.dictOf("status", true, "result", gettext("Server configuration reloaded.")));
        }
        return makeJsonResponse(1, Value(""), Value(""), Value(null),
                Value.dictOf("status", false, "result", SERVER_CONNECTION_CLOSED));
    }

    Response createRestorePoint(Value sid)
    {
        try
        {
            Value data = Value(null);
            auto req = request();
            if (!req.form.empty)
                data = req.form.toDict;
            else if (req.data.length)
                data = parseJson(req.text);
            Value name = data.isDict ? data.get("value") : Value(null);
            auto manager = getDriver().connectionManager(sid.integer);
            auto conn = manager.connection();
            if (conn.connected())
            {
                if (name.truthy)
                {
                    auto r = conn.executeScalar("SELECT pg_catalog.pg_create_restore_point(%s);", Value.tuple(name));
                    if (!r.ok)
                        return internalServerError(r.error);
                }
                return makeJsonResponse(1, Value(""), Value(""), Value(null), Value.dictOf("status", 1, "result",
                        gettext("Named restore point created: {0}").replace("{0}", name.isNone ? "None" : name.toString)));
            }
            return makeJsonResponse(1);
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
        {
            logError(gettext("Named restore point creation failed ({0})").replace("{0}", e.msg));
            return internalServerError(e.msg);
        }
    }

    Response changePassword(Value gid, Value sid)
    {
        try
        {
            Value data = Value(null);
            auto req = request();
            if (!req.form.empty)
                data = req.form.toDict;
            else if (req.data.length)
                data = parseJson(req.text);
            auto ck = getCryptKey();
            if (!ck.present)
                throw new CryptKeyMissing();
            auto server = getServer(sid.integer);
            if (server.isNone)
                return badRequest(notFoundErrorMsg());
            if (userById(currentUserId()).isNone)
                return unauthorized(gettext(UNAUTH_REQ));
            auto manager = getDriver().connectionManager(sid.integer);
            auto conn = manager.connection();
            bool isPassfile;
            auto cp = server["connection_params"];
            if (server["password"].isNone && manager.password.length == 0 && cp.isDict && cp.contains("passfile")
                    && !manager.connectionParam("passfile").isNone && cp["passfile"] == manager.connectionParam("passfile"))
                isPassfile = true;
            if (!isPassfile && data.truthy && (!data.contains("password") || data["password"].toString == ""))
                return makeJsonResponse(0, Value(gettext("Could not find the required parameter(s).")), Value(""),
                        Value(null), Value(null), 400);
            if (data.truthy && (!data.contains("newPassword") || data["newPassword"].toString == ""
                    || !data.contains("confirmPassword") || data["confirmPassword"].toString == ""))
                return makeJsonResponse(0, Value(gettext("Could not find the required parameter(s).")), Value(""),
                        Value(null), Value(null), 400);
            if (data["newPassword"] != data["confirmPassword"])
                return makeJsonResponse(0, Value(gettext("Passwords do not match.")), Value(""), Value(null), Value(null), 200);
            if (!isPassfile)
            {
                auto decrypted = decryptStr(manager.password, ck.key);
                if (data["password"].toString != decrypted)
                    return unauthorized(gettext("Incorrect password."));
            }
            auto password = conn.pqEncryptPasswordConn(data["newPassword"].toString, manager.user);
            if (password is null)
                return internalServerError("Unable to change the password.");
            auto sql = renderTemplate("/servers/sql/#" ~ to!string(manager.version_) ~ "#/change_password.sql", [
                "conn": Value(conn), "user": Value(manager.user), "encrypted_password": Value(password)]);
            auto r = conn.executeScalar(sql);
            if (!r.ok)
                return internalServerError(r.error);
            if (!isPassfile)
            {
                auto enc = encrypt(data["newPassword"].toString, ck.key);
                if (cfgBool("ALLOW_SAVE_PASSWORD"))
                {
                    if (server["shared"].truthy && server["user_id"].integer != currentUserId())
                    {
                        auto ss = getSharedServer(server, gid.integer);
                        if (!ss["password"].isNone)
                            db.exec("UPDATE sharedserver SET password = ? WHERE id = ?", toBinaryColumn(enc), ss["id"]);
                    }
                    else if (!server["password"].isNone)
                        db.exec("UPDATE server SET password = ? WHERE id = ?", toBinaryColumn(enc), server["id"]);
                }
                manager.password = enc;
            }
            return makeJsonResponse(1, Value(""), Value(gettext("Password changed successfully.")), Value(null), Value(null), 200);
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    Response walReplay(Value sid, bool pause)
    {
        auto server = getServer(sid.integer);
        if (server.isNone)
            return makeJsonResponse(0, Value(notFoundErrorMsg()));
        try
        {
            auto manager = getDriver().connectionManager(sid.integer);
            auto conn = manager.connection();
            if (conn.connected())
            {
                string sql, msg;
                if (pause)
                {
                    sql = manager.version_ >= 100000 ? "SELECT pg_catalog.pg_wal_replay_pause();" : "SELECT pg_catalog.pg_xlog_replay_pause();";
                    msg = gettext("WAL replay paused");
                }
                else
                {
                    sql = manager.version_ >= 100000 ? "SELECT pg_catalog.pg_wal_replay_resume();" : "SELECT pg_catalog.pg_xlog_replay_resume();";
                    msg = gettext("WAL replay resumed");
                }
                auto r = conn.executeScalar(sql);
                if (!r.ok)
                    return internalServerError(r.error);
                return makeJsonResponse(1, Value(""), Value(msg), Value(null),
                        Value.dictOf("in_recovery", true, "wal_pause", pause));
            }
            return gone(gettext("Please connect to the server."));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
        {
            logError("WAL replay pause/resume failed");
            return internalServerError(e.msg);
        }
    }

    Response checkPgpass(Value sid)
    {
        bool isPgpass;
        auto server = getServer(sid.integer);
        if (server.isNone)
            return makeJsonResponse(0, Value(notFoundErrorMsg()));
        try
        {
            auto manager = getDriver().connectionManager(sid.integer);
            auto conn = manager.connection();
            if (!conn.connected())
                return gone(gettext("Please connect to the server."));
            auto cp = server["connection_params"];
            if ((server["password"].isNone || manager.password.length == 0) && cp.isDict && cp.contains("passfile")
                    && !manager.connectionParam("passfile").isNone && cp["passfile"] == manager.connectionParam("passfile"))
                isPgpass = true;
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value.dictOf("is_pgpass", isPgpass));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
        {
            logError("Unable to fetch pgpass status");
            return internalServerError(e.msg);
        }
    }

    Response responseForPassword(Value server, int status, bool promptPassword = false, bool promptTunnelPassword = false,
            string errmsg = null)
    {
        auto allowSave = cfgBool("ALLOW_SAVE_PASSWORD") && session().get("allow_save_password").truthy;
        Value err = errmsg is null ? Value(null) : Value(errmsg);
        Value data;
        if (server["use_ssh_tunnel"].truthy)
        {
            auto d = new Dict;
            d["server_label"] = server["name"];
            d["username"] = server["username"];
            d["tunnel_username"] = server["tunnel_username"];
            d["tunnel_host"] = server["tunnel_host"];
            d["tunnel_identity_file"] = server["tunnel_identity_file"];
            d["tunnel_keep_alive"] = server["tunnel_keep_alive"];
            d["errmsg"] = err;
            d["service"] = server["service"];
            d["prompt_tunnel_password"] = Value(promptTunnelPassword);
            d["prompt_password"] = Value(promptPassword);
            d["allow_save_password"] = Value(allowSave);
            d["allow_save_tunnel_password"] = Value(cfgBool("ALLOW_SAVE_TUNNEL_PASSWORD")
                    && session().get("allow_save_password").truthy);
            data = Value(d);
        }
        else
        {
            auto d = new Dict;
            d["sid"] = server["id"];
            d["server_label"] = server["name"];
            d["username"] = server["username"];
            d["errmsg"] = err;
            d["service"] = server["service"];
            d["prompt_password"] = Value(true);
            d["allow_save_password"] = Value(allowSave);
            data = Value(d);
        }
        return makeJsonResponse(0, Value(""), Value(""), data, Value(null), status);
    }

    Response clearSavedPassword(Value gid, Value sid)
    {
        try
        {
            auto server = getServer(sid.integer, false);
            if (server.isNone)
                return makeJsonResponse(0, Value(""), Value(notFoundErrorMsg()));
            if (isNonOwner(server))
            {
                auto ss = getSharedServer(server, gid.integer);
                db.exec("UPDATE sharedserver SET password = NULL, save_password = 0 WHERE id = ?", ss["id"]);
            }
            else
                db.exec("UPDATE server SET password = NULL, save_password = 0 WHERE id = ?", server["id"]);
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
        {
            logError("Unable to clear saved password.\nError: " ~ e.msg);
            return internalServerError(e.msg);
        }
        return makeJsonResponse(1, Value(""), Value(gettext("The saved password was cleared successfully.")), Value(null),
                Value.dictOf("is_password_saved", false));
    }

    Response clearSshtunnelPassword(Value gid, Value sid)
    {
        try
        {
            auto server = getServer(sid.integer, false);
            if (server.isNone)
                return makeJsonResponse(0, Value(""), Value(notFoundErrorMsg()));
            if (isNonOwner(server))
            {
                auto ss = getSharedServer(server, gid.integer);
                db.exec("UPDATE sharedserver SET tunnel_password = NULL WHERE id = ?", ss["id"]);
            }
            else
                db.exec("UPDATE server SET tunnel_password = NULL WHERE id = ?", server["id"]);
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
        {
            logError("Unable to clear ssh tunnel password.\nError: " ~ e.msg);
            return internalServerError(e.msg);
        }
        return makeJsonResponse(1, Value(""), Value(gettext("The saved password was cleared successfully.")), Value(null),
                Value.dictOf("is_tunnel_password_saved", false));
    }
}
