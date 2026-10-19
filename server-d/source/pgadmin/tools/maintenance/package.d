/// `pgadmin/tools/maintenance`: VACUUM / ANALYZE / REINDEX / CLUSTER jobs (run through psql).
module pgadmin.tools.maintenance;

import std.regex : regex, matchFirst;
import pgadmin.core.strutil : pyIntStrict;
import pgadmin.browser.common;
import pgadmin.misc.bgprocess.processes : BatchProcess;
import pgadmin.tools.utility_common;
import pgadmin.utils.server_access;
import pgadmin.web.flask;

private string objectMsg(Value data)
{
    auto msg = gettext("on database '%s'").replace("%s", data["database"].toString);
    if (data.contains("primary_key") || data.contains("unique_constraint"))
        msg = "on constraint '" ~ [data["database"].toString, data["schema"].toString, data["table"].toString,
            (data.contains("primary_key") ? data["primary_key"] : data["unique_constraint"]).toString].join("/") ~ "'";
    else if (data.contains("index"))
        msg = "on index '" ~ [data["database"].toString, data["schema"].toString, data["table"].toString,
            data["index"].toString].join("/") ~ "'";
    else if (data.contains("table"))
        msg = "on table '" ~ [data["database"].toString, data["schema"].toString, data["table"].toString].join("/") ~ "'";
    else if (data.contains("schema"))
        msg = "on schema '" ~ [data["database"].toString, data["schema"].toString].join("/") ~ "'";
    return msg;
}

private Value maintenanceDesc(Value server, Value data, string query)
{
    string host = server.get("host").isNone ? "None" : server["host"].toString;
    string port = server.get("port").isNone ? "None" : server["port"].toString;
    auto serverName = server["name"].toString ~ " (" ~ host ~ ":" ~ port ~ ")";
    string op = gettext("VACUUM");
    auto dop = data["op"].toString;
    if (dop == "ANALYZE")
        op = gettext("ANALYZE");
    else if (dop == "REINDEX" && !data.contains("schema"))
        op = gettext("REINDEX");
    else if (dop == "REINDEX" && data.contains("schema"))
    {
        if (data.contains("primary_key") || data.contains("unique_constraint") || data.contains("index"))
            op = gettext("REINDEX INDEX");
        else if (data.contains("table"))
            op = gettext("REINDEX TABLE");
        else
            op = gettext("REINDEX SCHEMA");
    }
    else if (dop == "CLUSTER")
        op = gettext("CLUSTER");
    auto message = op ~ " " ~ objectMsg(data) ~ " of server " ~ serverName;
    return Value.dictOf("message", message, "type_desc", gettext("Maintenance"), "details",
            Value.dictOf("message", message, "query", query, "server", serverName, "object", data["database"], "type",
                gettext("Maintenance")), "current_storage_dir", Value(null));
}

private string getIndexName(Value data)
{
    foreach (k; ["primary_key", "unique_constraint", "index"])
        if (data.contains(k) && data[k].truthy)
            return data[k].toString;
    return null;
}

private string validateMaintenanceData(Value data)
{
    auto ic = data.get("vacuum_index_cleanup");
    if (ic.truthy)
        if (!ic.isString || !["AUTO", "ON", "OFF"].canFind(ic.str))
            return gettext("Invalid value for INDEX_CLEANUP option.");
    auto parallel = data.get("vacuum_parallel");
    if (!parallel.isNone && parallel != Value(""))
    {
        long n;
        try
            n = pyIntStrict(parallel);
        catch (Exception)
            return gettext("Invalid value for PARALLEL option.");
        if (n < 0 || n > 1024)
            return gettext("Invalid value for PARALLEL option.");
    }
    auto bl = data.get("buffer_usage_limit");
    if (bl.truthy)
        if (!bl.isString || matchFirst(bl.str.strip, regex(`^\d+\s*(kB|MB|GB|TB)$`, "i")).empty)
            return gettext("Invalid value for BUFFER_USAGE_LIMIT option.");
    auto ts = data.get("reindex_tablespace");
    if (!ts.isNone && !ts.isString)
        return gettext("Invalid value for TABLESPACE option.");
    return null;
}

final class MaintenanceModule : Blueprint
{
    this()
    {
        super("maintenance", "/maintenance");
    }

    override string[] getExposedUrlEndpoints() => ["maintenance.create_job", "maintenance.utility_exists"];

    override void setup()
    {
        route("/", "index", ["GET"], loginRequired((Dict a) => badRequest(gettext("This URL cannot be called directly."))));
        route("/job/<int:sid>/<int:did>", "create_job", ["POST"], permissionsRequired(loginRequired((Dict a) => createJob(a)),
                "tools_maintenance"));
        route("/utility_exists/<int:sid>", "utility_exists", ["GET"], permissionsRequired(loginRequired((Dict a) {
            auto server = getServer(a["sid"].integer);
            if (server.isNone)
                return makeJsonResponse(0, Value(SERVER_NOT_FOUND));
            auto manager = getDriver().connectionManager(server["id"].integer);
            auto retVal = doesUtilityExist(manager.utility("sql"));
            if (retVal.length)
                return makeJsonResponse(0, Value(retVal));
            return makeJsonResponse(1);
        }), "tools_maintenance"));
    }

    private static Response createJob(Dict a)
    {
        auto sid = a["sid"];
        auto req = request();
        Value data = !req.form.empty ? parseJson(req.form.get("data")) : parseJson(req.text);
        auto err = validateMaintenanceData(data);
        if (err !is null)
            return badRequest(err);
        if (!data.get("database").truthy)
            return badRequest(gettext("Database parameter is required."));
        auto indexName = getIndexName(data);
        auto server = getServer(sid.integer);
        if (server.isNone)
            return makeJsonResponse(0, Value(gettext("Could not find the specified server.")));
        auto manager = getDriver().connectionManager(server["id"].integer);
        auto conn = manager.connection();
        if (!conn.connected())
            return makeJsonResponse(0, Value(gettext("Please connect to the server first.")));
        auto utility = manager.utility("sql");
        auto retVal = doesUtilityExist(utility);
        if (retVal.length)
            return makeJsonResponse(0, Value(retVal));
        auto query = renderTemplate("maintenance/sql/command.sql", tv("conn", conn, "data", data, "index_name",
                indexName is null ? Value(null) : Value(indexName)));
        string[] args = ["--host", server["host"].toString, "--port", server["port"].toString, "--username",
            server["username"].toString, "--command", query];
        try
        {
            string[string] env;
            if (data.get("database").truthy)
                env["PGDATABASE"] = data["database"].toString;
            auto desc = maintenanceDesc(server, data, query);
            auto p = BatchProcess.create(desc, utility, args);
            p.setEnvVariables(server, manager, env);
            p.start();
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value.dictOf("job_id", p.id, "desc", desc["message"],
                    "status", true, "info", gettext("Maintenance job created.")), 200);
        }
        catch (Exception e)
        {
            logException(e);
            return makeJsonResponse(0, Value(e.msg), Value(""), Value(null), Value(null), 410);
        }
    }
}
