/// `pgadmin/tools/grant_wizard`: GRANT statements for many objects at once (also used by the backup dialog's object tree).
module pgadmin.tools.grant_wizard;

import std.uri : decodeComponent;
import pgadmin.browser.common;
import pgadmin.utils.preferences : Preferences;
import pgadmin.web.flask;

/// What `check_precondition` leaves in the module-level `server_info`.
struct GrantServerInfo
{
    ServerManager manager;
    Connection conn;
    string serverType;
    long version_;
    string templatePath;
}

/// `get_data(...)` result.
struct GrantData
{
    Value rows;       /// None when `error` is set
    string msg;       /// None (null) or the list of object types that could not be fetched
    Response error;
    Value emptySchemas;
}

private Res rowsForType(Connection conn, string ntype, GrantServerInfo info, Value nodeId)
{
    immutable functionSql = "/sql/function.sql";
    string base = info.templatePath;
    if (ntype == "function")
        return conn.executeDict(renderTemplate(base ~ "/" ~ functionSql, tv("node_id", nodeId, "type", "function")));
    if ((info.serverType == "ppas" || (info.serverType == "pg" && info.version_ >= 11000)) && ntype == "procedure")
        return conn.executeDict(renderTemplate(base ~ "/" ~ functionSql, tv("node_id", nodeId, "type", "procedure")));
    if (ntype == "trigger_function")
        return conn.executeDict(renderTemplate(base ~ "/" ~ functionSql, tv("node_id", nodeId, "type", "trigger_function")));
    if (ntype == "sequence")
        return conn.executeDict(renderTemplate(base ~ "//sql/sequence.sql", tv("node_id", nodeId)));
    if (ntype == "table")
        return conn.executeDict(renderTemplate(base ~ "//sql/table.sql", tv("node_id", nodeId)));
    if (ntype == "view")
        return conn.executeDict(renderTemplate(base ~ "//sql/view.sql", tv("node_id", nodeId, "node_type", "v")));
    if (ntype == "mview")
        return conn.executeDict(renderTemplate(base ~ "//sql/view.sql", tv("node_id", nodeId, "node_type", "m")));
    if (ntype == "foreign_table")
        return conn.executeDict(renderTemplate(base ~ "//sql/foreign_table.sql", tv("node_id", nodeId, "node_type", "m")));
    if (info.serverType == "ppas" && ntype == "package")
        return conn.executeDict(renderTemplate(base ~ "//sql/package.sql", tv("node_id", nodeId)));
    return Res(true, Value.newList());
}

/// `get_data(sid, did, node_id, node_type, server_data, return_emtpy_schema)`
GrantData getData(Value sid, Value did, Value nodeId, string nodeType, GrantServerInfo info)
{
    GrantData g;
    nodeType = decodeComponent(nodeType);
    auto manager = getDriver().connectionManager(sid.integer);
    auto conn = manager.connection(null, null, true, did);
    auto showSys = Preferences.module_("browser").preference("show_system_objects").get();
    string sql, ntype;
    if (nodeType == "database")
    {
        sql = renderTemplate(info.templatePath ~ "//sql/get_schemas.sql", tv("show_sysobj", showSys));
        ntype = "schema";
    }
    else
    {
        sql = renderTemplate(info.templatePath ~ "//sql/get_schemas.sql", tv("show_sysobj", showSys, "nspid", nodeId));
        ntype = nodeType;
    }
    auto r = conn.executeDict(sql);
    if (!r.ok)
    {
        g.error = internalServerError(r.error);
        return g;
    }
    Value[] resData;
    string[] failed;
    string[] emptySchemas;
    void append(Res res, string disp)
    {
        if (!res.ok)
        {
            logError(res.error);
            failed ~= disp;
        }
        else if (res.value.isDict && res.value.length > 0)
            resData ~= res.value["rows"].list.items;
    }

    foreach (row; r.value["rows"].list.items)
    {
        bool isEmpty = true;
        if (row.contains("oid"))
            nodeId = row["oid"];
        if (ntype == "schema")
        {
            append(rowsForType(conn, "function", info, nodeId), "function");
            append(rowsForType(conn, "procedure", info, nodeId), "procedure");
            append(rowsForType(conn, "trigger_function", info, nodeId), "trigger function");
            foreach (spec; [["sequence", "sequence"], ["table", "table"], ["view", "view"], ["mview", "materialized view"],
                    ["foreign_table", "foreign table"]])
            {
                auto res = rowsForType(conn, spec[0], info, nodeId);
                if (res.value["rows"].length)
                    isEmpty = false;
                append(res, spec[1]);
            }
            auto pk = rowsForType(conn, "package", info, nodeId);
            if ((pk.value.isList && pk.value.length > 0) || (pk.value.isDict && pk.value.contains("rows") && pk.value["rows"].length > 0))
                isEmpty = false;
            append(pk, "package");
            if (isEmpty && !emptySchemas.canFind(row["name"].toString))
                emptySchemas ~= row["name"].toString;
        }
        else
            append(rowsForType(conn, ntype, info, nodeId), "function");
    }
    if (failed.length)
        g.msg = "Unable to fetch the " ~ failed.join(", ") ~ " objects";
    g.rows = Value(resData);
    Value[] es;
    foreach (e; emptySchemas)
        es ~= Value(e);
    g.emptySchemas = Value(es);
    return g;
}

/// The `check_precondition` decorator; returns an error response or null.
private Response checkPrecondition(Dict a, out GrantServerInfo info)
{
    info.manager = getDriver().connectionManager(a["sid"].integer);
    info.conn = info.manager.connection(null, null, true, a["did"]);
    if (!info.conn.connected())
        return preconditionRequired(gettext("Connection to the server has been lost."));
    info.serverType = info.manager.serverType;
    info.version_ = info.manager.version_;
    if (info.serverType == "pg")
        info.templatePath = "grant_wizard/pg/#" ~ to!string(info.version_) ~ "#";
    else if (info.serverType == "ppas")
        info.templatePath = "grant_wizard/ppas/#" ~ to!string(info.version_) ~ "#";
    return null;
}

private Value reqData()
{
    auto req = request();
    return !req.form.empty ? req.form.toDict : parseJson(req.text);
}

private Value loadAcls(GrantServerInfo info)
{
    try
        return parseJson(renderTemplate(info.templatePath ~ "//acl.json"));
    catch (Exception e)
    {
        logException(e);
        return Value.newList();
    }
}

private string[] aclOf(Value acls, string kind)
{
    string[] r;
    foreach (c; acls[kind]["acl"].iterItems())
        r ~= c.toString;
    return r;
}

private void parsePriv(Value data, Value acls, GrantServerInfo info)
{
    if (data.contains("acl"))
    {
        data["priv"]["function"] = parsePrivToDb(data["acl"], aclOf(acls, "function"));
        data["priv"]["sequence"] = parsePrivToDb(data["acl"], aclOf(acls, "sequence"));
        data["priv"]["table"] = parsePrivToDb(data["acl"], aclOf(acls, "table"));
        data["priv"]["foreign_table"] = parsePrivToDb(data["acl"], aclOf(acls, "foreign_table"));
        if (info.serverType == "ppas")
            data["priv"]["package"] = parsePrivToDb(data["acl"], aclOf(acls, "package"));
    }
}

private string grantSql(Value data, GrantServerInfo info, Connection conn)
{
    string sqlData;
    void add(string file, string key)
    {
        auto d = Value.dictOf("objects", data["objects"], "priv", data["priv"][key]);
        auto sql = renderTemplate(info.templatePath ~ "//sql/" ~ file, tv("data", d, "conn", conn));
        if (sql.length && sql.strip("\n") != "")
            sqlData ~= sql;
    }

    add("grant_function.sql", "function");
    add("grant_sequence.sql", "sequence");
    add("grant_table.sql", "table");
    add("grant_foreign_table.sql", "foreign_table");
    if (info.serverType == "ppas")
        add("grant_package.sql", "package");
    return sqlData;
}

final class GrantWizardModule : Blueprint
{
    this()
    {
        super("grant_wizard", "/grant_wizard");
    }

    override string[] getExposedUrlEndpoints() => ["grant_wizard.acl", "grant_wizard.objects", "grant_wizard.apply",
        "grant_wizard.modified_sql"];

    override void setup()
    {
        route("/", "index", ["GET"], loginRequired((Dict a) => badRequest(gettext("This URL cannot be called directly."))));
        route("/acl/<int:sid>/<int:did>/", "acl", ["GET"], permissionsRequired(loginRequired((Dict a) {
            GrantServerInfo info;
            if (auto e = checkPrecondition(a, info))
                return e;
            return new Response(renderTemplate(info.templatePath ~ "//acl.json"), 200, "application/json");
        }), "tools_grant_wizard"));
        route("/<int:sid>/<int:did>/<int:node_id>/<node_type>/", "objects", ["GET"],
                permissionsRequired(loginRequired((Dict a) {
            GrantServerInfo info;
            if (auto e = checkPrecondition(a, info))
                return e;
            auto g = getData(a["sid"], a["did"], a["node_id"], a["node_type"].toString, info);
            if (g.error !is null)
                return g.error;
            return makeJsonResponse(1, Value(""), g.msg is null ? Value(null) : Value(g.msg), g.rows, Value(null), 200);
        }), "tools_grant_wizard"));
        route("/sql/<int:sid>/<int:did>/", "modified_sql", ["POST"], permissionsRequired(loginRequired((Dict a) {
            GrantServerInfo info;
            if (auto e = checkPrecondition(a, info))
                return e;
            auto data = reqData();
            auto conn = getDriver().connectionManager(a["sid"].integer).connection(null, null, true, a["did"]);
            auto acls = loadAcls(info);
            try
            {
                data["priv"] = Value.newDict();
                parsePriv(data, acls, info);
                return makeResponse(Value.dictOf("data", grantSql(data, info, conn)), 200);
            }
            catch (Exception e)
                return makeJsonResponse(0, Value(e.msg), Value(""), Value(null), Value(null), 410);
        }), "tools_grant_wizard"));
        route("/<int:sid>/<int:did>/", "apply", ["POST"], permissionsRequired(loginRequired((Dict a) {
            GrantServerInfo info;
            if (auto e = checkPrecondition(a, info))
                return e;
            auto data = reqData();
            auto conn = getDriver().connectionManager(a["sid"].integer).connection(null, null, true, a["did"]);
            auto acls = loadAcls(info);
            try
            {
                data["priv"] = Value.newDict();
                parsePriv(data, acls, info);
                auto sql = grantSql(data, info, conn);
                auto r = conn.executeDict(sql);
                if (!r.ok)
                    return internalServerError(r.error);
                return makeJsonResponse(1, Value(""), Value("Privileges applied"));
            }
            catch (Exception e)
                return internalServerError(e.msg);
        }), "tools_grant_wizard"));
    }
}
