/// `pgadmin/dashboard`: server and database activity data for the dashboard panels.
module pgadmin.dashboard;

import std.algorithm : canFind;
import std.array : replace;
import std.conv : to;
import std.math : isNaN;
import std.regex : regex, matchFirst, matchAll, Regex;
import std.string : split, strip;
import pgadmin.core.config;
import pgadmin.core.i18n;
import pgadmin.core.templates : renderTemplate;
import pgadmin.core.value;
import pgadmin.db.driver;
import pgadmin.utils.constants;
import pgadmin.utils.preferences : Preferences;
import pgadmin.web.auth;
import pgadmin.web.context;
import pgadmin.web.flask;
import pgadmin.web.http;

/// What `check_precondition` leaves in Flask's `g`.
private struct Ctx
{
    ServerManager manager;
    Connection conn;
    string templatePath;
}

/// `dashboard.precondition.check_precondition`: returns an error response, or null with `ctx` filled in.
private Response dashPrecondition(Dict a, string fname, out Ctx ctx)
{
    if (!a.has("sid"))
        throw new Exception("'sid'");
    ctx.manager = getDriver().connectionManagerOrNull(a["sid"].integer);
    immutable table = ["activity", "prepared", "locks", "config"].canFind(fname);
    string errText(string t) => gettext(table ? "Please connect to the selected %s to view the table."
            : "Please connect to the selected %s to view the graph.").replace("%s", t);
    if (ctx.manager is null)
        return preconditionRequired(errText("server"));
    string nodeType;
    if (a.has("did"))
    {
        ctx.conn = ctx.manager.connection(null, null, true, a["did"]);
        nodeType = "database";
    }
    else
    {
        ctx.conn = ctx.manager.connection();
        nodeType = "server";
    }
    if (!ctx.conn.connected())
    {
        return preconditionRequired(errText(nodeType));
    }
    ctx.templatePath = "dashboard/sql/#" ~ to!string(ctx.manager.version_) ~ "#";
    return null;
}

private Value chartData(Value chartData)
{
    return chartData.isString ? parseJson(chartData.str) : chartData;
}

/// `get_long_running_query_status`
private void longRunningQueryStatus(Value activities)
{
    auto pref = Preferences.module_("dashboards").preference("long_running_query_threshold");
    auto threshold = pref.get();
    if (threshold.isNone)
        return;
    auto parts = threshold.toString.split("|");
    immutable warning = parts[0] != "" ? to!double(parts[0]) : double.infinity;
    immutable alert = parts[1] != "" ? to!double(parts[1]) : double.infinity;
    foreach (row; activities.list.items)
    {
        row["row_type"] = Value(null);
        if (row["state"] == Value("active") && row.contains("active_since") && !row["active_since"].isNone)
        {
            immutable activeSince = to!double(row["active_since"].toString);
            if (activeSince > warning)
                row["row_type"] = Value("warning");
            if (activeSince > alert)
                row["row_type"] = Value("alert");
        }
    }
}

private enum LOG_STATEMENTS = "DEBUG:|STATEMENT:|LOG:|WARNING:|NOTICE:|INFO:|ERROR:|FATAL:|PANIC:";

final class DashboardModule : Blueprint
{
    this()
    {
        super("dashboard", "/dashboard");
    }

    override string[] getExposedUrlEndpoints() => [
        "dashboard.index", "dashboard.get_by_sever_id", "dashboard.get_by_database_id", "dashboard.dashboard_stats",
        "dashboard.dashboard_stats_sid", "dashboard.dashboard_stats_did", "dashboard.activity",
        "dashboard.get_activity_by_server_id", "dashboard.get_activity_by_database_id", "dashboard.locks",
        "dashboard.get_locks_by_server_id", "dashboard.get_locks_by_database_id", "dashboard.prepared",
        "dashboard.get_prepared_by_server_id", "dashboard.get_prepared_by_database_id", "dashboard.config",
        "dashboard.log_formats", "dashboard.logs", "dashboard.get_logs_by_server_id", "dashboard.check_system_statistics",
        "dashboard.check_system_statistics_sid", "dashboard.check_system_statistics_did", "dashboard.system_statistics",
        "dashboard.system_statistics_sid", "dashboard.system_statistics_did", "dashboard.replication_slots",
        "dashboard.replication_stats", "dashboard.pgd.outgoing", "dashboard.pgd.incoming", "dashboard.pgd.cluster_nodes",
        "dashboard.pgd.raft_status", "dashboard.pgd.charts"];

    /// `get_data`
    private static Value getData(Ctx ctx, Value sid, Value did, string tmpl, bool checkLongRunning, bool onlyData, out Response err)
    {
        if (!sid.truthy)
        {
            err = internalServerError(ERROR_SERVER_ID_NOT_SPECIFIED);
            return Value(null);
        }
        auto sql = renderTemplate(ctx.templatePath ~ "/" ~ tmpl, ["did": did]);
        auto r = ctx.conn.executeDict(sql);
        if (!r.ok)
        {
            err = internalServerError(r.error);
            return Value(null);
        }
        if (checkLongRunning)
            longRunningQueryStatus(r.value["rows"]);
        if (onlyData)
            return r.value["rows"];
        err = makeResponse(r.value["rows"], 200);
        return Value(null);
    }

    private static Value idArg(Dict a, string k) => a.has(k) ? a[k] : Value(null);

    override void setup()
    {
        import pgadmin.dashboard.pgd : PGDReplicationDashboard;
        submodules ~= new PGDReplicationDashboard;

        route("/dashboard.js", "script", ["GET"], loginRequired((Dict a) {
            auto body_ = renderTemplate("dashboard/js/dashboard.js", ["_": Value(null)]);
            return new Response(body_, 200, MIMETYPE_APP_JS);
        }));

        auto indexView = loginRequired((Dict a) {
            if (a.has("sid"))
            {
                auto m = getDriver().connectionManagerOrNull(a["sid"].integer);
                m.connection();
            }
            if (!a.has("sid") && !a.has("did"))
                return new Response(renderTemplate("/dashboard/welcome_dashboard.html"), 200);
            if (!a.has("did"))
                return new Response(renderTemplate("/dashboard/server_dashboard.html"), 200);
            return new Response(renderTemplate("/dashboard/database_dashboard.html"), 200);
        });
        route("/", "index", ["GET"], indexView);
        route("/<int:sid>", "get_by_sever_id", ["GET"], indexView);
        route("/<int:sid>/<int:did>", "get_by_database_id", ["GET"], indexView);

        auto statsView = (string fname, string tmpl) => loginRequired((Dict a) {
            Ctx ctx;
            if (auto e = dashPrecondition(a, fname, ctx))
                return e;
            auto args = request().args;
            if (!args.has("chart_names"))
                throw new HTTPException(400);
            auto resp = Value.newDict();
            if (args.get("chart_names") != "")
            {
                auto charts = args.get("chart_names").split(",");
                if (!idArg(a, "sid").truthy)
                    return internalServerError(ERROR_SERVER_ID_NOT_SPECIFIED);
                Value[] cv;
                foreach (c; charts)
                    cv ~= Value(c);
                auto sql = renderTemplate(ctx.templatePath ~ "/" ~ tmpl, ["did": idArg(a, "did"), "chart_names": Value(cv)]);
                auto r = ctx.conn.executeDict(sql);
                if (!r.ok)
                {
                    if (fname == "dashboard_stats")
                        throw new Exception("'NoneType' object is not subscriptable");
                    return internalServerError(r.error);
                }
                foreach (row; r.value["rows"].list.items)
                    resp[row["chart_name"].toString] = chartData(row["chart_data"]);
            }
            return makeResponse(resp, 200);
        });
        auto ds = statsView("dashboard_stats", "dashboard_stats.sql");
        route("/dashboard_stats", "dashboard_stats", ["GET"], ds);
        route("/dashboard_stats/<int:sid>", "dashboard_stats_sid", ["GET"], ds);
        route("/dashboard_stats/<int:sid>/<int:did>", "dashboard_stats_did", ["GET"], ds);

        auto activityView = loginRequired((Dict a) {
            Ctx ctx;
            if (auto e = dashPrecondition(a, "activity", ctx))
                return e;
            Response err;
            auto sid = idArg(a, "sid");
            auto did = idArg(a, "did");
            auto act = getData(ctx, sid, did, "activity.sql", true, true, err);
            auto locks = getData(ctx, sid, did, "locks.sql", false, true, err);
            auto prepared = getData(ctx, sid, did, "prepared.sql", false, true, err);
            auto data = Value([Value.dictOf("activity", act, "locks", locks, "prepared", prepared)]);
            return makeResponse(data, 200);
        });
        route("/activity/", "activity", ["GET"], activityView);
        route("/activity/<int:sid>", "get_activity_by_server_id", ["GET"], activityView);
        route("/activity/<int:sid>/<int:did>", "get_activity_by_database_id", ["GET"], activityView);

        View simpleData(string fname, string tmpl) => loginRequired((Dict a) {
            Ctx ctx;
            if (auto e = dashPrecondition(a, fname, ctx))
                return e;
            Response err;
            getData(ctx, idArg(a, "sid"), idArg(a, "did"), tmpl, false, false, err);
            return err;
        });
        auto locks = simpleData("locks", "locks.sql");
        route("/locks/", "locks", ["GET"], locks);
        route("/locks/<int:sid>", "get_locks_by_server_id", ["GET"], locks);
        route("/locks/<int:sid>/<int:did>", "get_locks_by_database_id", ["GET"], locks);
        auto prepared = simpleData("prepared", "prepared.sql");
        route("/prepared/", "prepared", ["GET"], prepared);
        route("/prepared/<int:sid>", "get_prepared_by_server_id", ["GET"], prepared);
        route("/prepared/<int:sid>/<int:did>", "get_prepared_by_database_id", ["GET"], prepared);

        route("/config/<int:sid>", "config", ["GET"], loginRequired((Dict a) {
            Ctx ctx;
            if (auto e = dashPrecondition(a, "config", ctx))
                return e;
            Response err;
            getData(ctx, idArg(a, "sid"), Value(null), "config.sql", false, false, err);
            return err;
        }));

        auto logFormats = loginRequired((Dict a) {
            Ctx ctx;
            if (auto e = dashPrecondition(a, "log_formats", ctx))
                return e;
            if (!idArg(a, "sid").truthy)
                return internalServerError("Server ID not specified.");
            auto r = ctx.conn.executeScalar(renderTemplate(ctx.templatePath ~ "/log_format.sql"));
            if (!r.ok)
                return internalServerError(r.error);
            return makeResponse(r.value, 200);
        });
        route("/log_formats", "log_formats", ["GET"], logFormats);
        route("/log_formats/<int:sid>", "log_formats", ["GET"], logFormats);

        auto logsView = loginRequired((Dict a) {
            Ctx ctx;
            if (auto e = dashPrecondition(a, "logs", ctx))
                return e;
            return logs(ctx, a);
        });
        route("/logs/<log_format>/<disp_format>/<int:sid>", "logs", ["GET"], logsView);
        route("/logs/<log_format>/<disp_format>/<int:sid>/<int:page>", "get_logs_by_server_id", ["GET"], logsView);

        View killView(string fname, string fn) => loginRequired((Dict a) {
            Ctx ctx;
            if (auto e = dashPrecondition(a, fname, ctx))
                return e;
            auto r = ctx.conn.executeScalar("SELECT pg_catalog." ~ fn ~ "(" ~ a["pid"].toString ~ ");");
            if (!r.ok)
                return internalServerError(r.error);
            return makeResponse(Value(r.value.truthy ? gettext("Success") : gettext("Failed")), 200);
        });
        auto cancel = killView("cancel_query", "pg_cancel_backend");
        route("/cancel_query/<int:sid>/<int:pid>", "cancel_query", ["DELETE"], cancel);
        route("/cancel_query/<int:sid>/<int:did>/<int:pid>", "cancel_query", ["DELETE"], cancel);
        auto terminate = killView("terminate_session", "pg_terminate_backend");
        route("/terminate_session/<int:sid>/<int:pid>", "terminate_session", ["DELETE"], terminate);
        route("/terminate_session/<int:sid>/<int:did>/<int:pid>", "terminate_session", ["DELETE"], terminate);

        auto checkSs = loginRequired((Dict a) {
            Ctx ctx;
            if (auto e = dashPrecondition(a, "check_system_statistics", ctx))
                return e;
            auto r = ctx.conn.executeScalar("SELECT 1 FROM pg_catalog.pg_extension WHERE extname = 'system_stats';");
            if (!r.ok)
                return internalServerError(r.error);
            return makeResponse(Value.dictOf("ss_present", !r.value.isNone), 200);
        });
        route("check_extension/system_statistics", "check_system_statistics", ["GET"], checkSs);
        route("check_extension/system_statistics/<int:sid>", "check_system_statistics_sid", ["GET"], checkSs);
        route("check_extension/system_statistics/<int:sid>/<int:did>", "check_system_statistics_did", ["GET"], checkSs);

        auto ss = statsView("system_statistics", "system_statistics.sql");
        route("/system_statistics", "system_statistics", ["GET"], ss);
        route("/system_statistics/<int:sid>", "system_statistics_sid", ["GET"], ss);
        route("/system_statistics/<int:sid>/<int:did>", "system_statistics_did", ["GET"], ss);

        View replView(string fname, string tmpl) => loginRequired((Dict a) {
            Ctx ctx;
            if (auto e = dashPrecondition(a, fname, ctx))
                return e;
            if (!idArg(a, "sid").truthy)
                return internalServerError(ERROR_SERVER_ID_NOT_SPECIFIED);
            auto r = ctx.conn.executeDict(renderTemplate(ctx.templatePath ~ "/" ~ tmpl));
            if (!r.ok)
                return internalServerError(r.error);
            return makeResponse(r.value["rows"], 200);
        });
        route("/replication_stats/<int:sid>", "replication_stats", ["GET"], replView("replication_stats", "replication_stats.sql"));
        route("/replication_slots/<int:sid>", "replication_slots", ["GET"], replView("replication_slots", "replication_slots.sql"));
    }

    /// The `logs` view.
    private static Response logs(Ctx ctx, Dict a)
    {
        auto sid = idArg(a, "sid");
        if (!sid.truthy)
            return internalServerError(gettext("Server ID not specified."));
        string logFormat = a["log_format"].toString;
        string dispFormat = a["disp_format"].toString;
        long page = a.has("page") ? a["page"].integer : 0;
        auto f = ctx.conn.executeScalar(renderTemplate(ctx.templatePath ~ "/log_format.sql"));
        auto format_ = f.value.isNone ? "" : f.value.toString;
        if (f.value.isNone)
            throw new Exception("argument of type 'NoneType' is not iterable");
        if (logFormat == "C" && format_.canFind("csvlog"))
            logFormat = "csvlog";
        else if (logFormat == "J" && format_.canFind("jsonlog"))
            logFormat = "jsonlog";
        else
            logFormat = "";
        auto st = ctx.conn.executeScalar(renderTemplate(ctx.templatePath ~ "/log_stat.sql",
                ["log_format": Value(logFormat), "conn": Value(ctx.conn)]));
        if (!st.ok)
            return internalServerError(st.error);
        bool empty = st.value.isNone || (st.value.isString && st.value.str.length == 0) || st.value.length == 0;
        if (empty)
            return makeResponse(Value.dictOf("logs_disabled", true), 200);
        Value first = st.value.isString ? Value(st.value.str[0 .. 1]) : st.value[0];
        auto fileStat = parseJson(first.toString);
        if (fileStat.integer <= 0)
            return makeResponse(Value.dictOf("logs_disabled", true), 200);
        immutable onDemand = cfgInt("ON_DEMAND_LOG_COUNT");
        long start = 0, end = onDemand;
        if (page > 0)
        {
            start = page * onDemand;
            end = start + onDemand;
        }
        Value[] finalCols;
        Value rows;
        if (start < fileStat.integer)
        {
            if (dispFormat == "plain")
                end = fileStat.integer;
            auto res = ctx.conn.executeDict(renderTemplate(ctx.templatePath ~ "/logs.sql",
                    ["st": Value(start), "ed": Value(end), "log_format": Value(logFormat), "conn": Value(ctx.conn)]));
            if (!res.ok)
                return internalServerError(res.error);
            rows = res.value["rows"];
            auto lines = rows[0]["pg_read_file"].toString.split("\n");
            if (logFormat == "jsonlog")
            {
                foreach (line; lines)
                {
                    try
                    {
                        auto t = parseJson(line);
                        finalCols ~= Value.dictOf("error_severity", t["error_severity"], "timestamp", t["timestamp"],
                                "message", t["message"]);
                    }
                    catch (Exception)
                    {
                    }
                }
            }
            else if (logFormat == "csvlog")
            {
                foreach (line; lines)
                {
                    auto t = line.split(",");
                    if (t.length > 13)
                        finalCols ~= Value.dictOf("error_severity", t[11], "timestamp", t[0], "message", t[13]);
                }
            }
            else
            {
                auto re = regex(LOG_STATEMENTS);
                foreach (line; lines)
                {
                    auto m = matchFirst(line, re);
                    if (m.empty || m.hit == "STATEMENT:")
                    {
                        Value last = finalCols.length > 0 ? finalCols[$ - 1] : Value.dictOf("message", "");
                        if (finalCols.length > 0)
                            finalCols = finalCols[0 .. $ - 1];
                        last["message"] = Value(last["message"].toString ~ line);
                        finalCols ~= last;
                    }
                    else
                    {
                        auto hit = m.hit;
                        string before = m.pre;
                        string rest = m.post;
                        auto m2 = matchFirst(rest, re);
                        string mid = m2.empty ? rest : m2.pre;
                        finalCols ~= Value.dictOf("error_severity", hit[0 .. $ - 1], "timestamp", before, "message", mid);
                    }
                }
            }
        }
        if (dispFormat == "plain")
        {
            if (rows.isNone)
                throw new Exception("string indices must be integers, not 'str'");
            return makeResponse(rows, 200);
        }
        return makeResponse(Value(finalCols), 200);
    }
}
