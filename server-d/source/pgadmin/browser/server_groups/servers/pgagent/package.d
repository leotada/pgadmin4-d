/// `servers/pgagent`: pgAgent Job node module.
module pgadmin.browser.server_groups.servers.pgagent;

import std.conv : to;
import std.string : strip;
import pgadmin.browser.common;
import pgadmin.browser.server_groups.servers.pgagent.schedules;
import pgadmin.browser.server_groups.servers.pgagent.steps;
import pgadmin.browser.server_groups.servers.pgagent.utils;
import pgadmin.core.templates : renderTemplate, tv;
import pgadmin.core.value;
import pgadmin.db.driver : Connection, ServerManager, getDriver, Res;
import pgadmin.utils.preferences : Preferences;

final class PgaJobModule : CollectionNodeModule
{
    enum NODE_TYPE = "pga_job";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "pgAgent Jobs";
        staticDir("browser/server_groups/servers/pgagent");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => "server";
    override bool moduleUseTemplateJavascript() => false;
    override bool nodeInode() => true;

    override Value[] getNodes(Dict kwargs) => [generateBrowserCollectionNode(kwargs["sid"])];

    override bool backendSupported(ServerManager manager, Dict kwargs)
    {
        auto conn = manager.connection();
        auto q1 = `SELECT has_table_privilege('pgagent.pga_job', 'INSERT, SELECT, UPDATE') has_privilege
WHERE EXISTS(
    SELECT has_schema_privilege('pgagent', 'USAGE')
    WHERE EXISTS(
        SELECT cl.oid FROM pg_catalog.pg_class cl
        LEFT JOIN pg_catalog.pg_namespace ns ON ns.oid=relnamespace
        WHERE relname='pga_job' AND nspname='pgagent'
    )
)`;
        auto r1 = conn.executeScalar(q1);
        if (r1.ok && r1.value.truthy)
        {
            auto q2 = `SELECT EXISTS(
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='pgagent' AND table_name='pga_jobstep' AND column_name='jstconnstr'
) has_connstr`;
            auto r2 = conn.executeDict(q2);
            bool hasConnStr = false;
            if (r2.ok && r2.value["rows"].length > 0)
                hasConnStr = r2.value["rows"][0]["has_connstr"].truthy;
            manager.dbInfo["pgAgent"] = Value.dictOf("has_connstr", Value(hasConnStr));
            return true;
        }
        return false;
    }

    override string[] csssnippets()
    {
        string[] snippets = [
            renderTemplate("browser/css/collection.css", ["node_type": Value(nodeType)]),
            renderTemplate("pga_job/css/pga_job.css", ["node_type": Value(nodeType)])
        ];
        foreach (m; submodules)
            if (auto b = cast(BrowserPluginModule) m)
                snippets ~= b.csssnippets;
        return snippets;
    }

    override void setup()
    {
        submodules ~= new PgaScheduleModule;
        submodules ~= new PgaStepModule;
        registerNodeView!PgaJobView(this);
    }
}

final class PgaJobView : PGChildNodeView
{
    this()
    {
        super();
        nodeType = PgaJobModule.NODE_TYPE;
        parentIds = [IdSpec("int", "gid"), IdSpec("int", "sid")];
        ids = [IdSpec("int", "jid")];
        setAllOps([
            makeOp("obj", ["get": "properties", "delete": "delete", "put": "update"],
                    ["get": "properties", "post": "create", "delete": "delete"]),
            makeOp("nodes", ["get": "node"], ["get": "nodes"]),
            makeOp("sql", ["get": "sql"]),
            makeOp("msql", ["get": "msql"], ["get": "msql"]),
            makeOp("run_now", ["put": "run_now"]),
            makeOp("classes", cast(string[string]) null, ["get": "job_classes"]),
            makeOp("children", ["get": "children"]),
            makeOp("stats", ["get": "statistics"]),
        ]);
    }

    private bool hasConnStr()
    {
        if (manager is null || manager.dbInfo is null)
            return false;
        if (!manager.dbInfo.has("pgAgent"))
        {
            auto q = `SELECT EXISTS(
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='pgagent' AND table_name='pga_jobstep' AND column_name='jstconnstr'
) has_connstr`;
            auto r = conn.executeDict(q);
            bool hc = false;
            if (r.ok && r.value["rows"].length > 0)
                hc = r.value["rows"][0]["has_connstr"].truthy;
            manager.dbInfo["pgAgent"] = Value.dictOf("has_connstr", Value(hc));
            return hc;
        }
        return manager.dbInfo["pgAgent"]["has_connstr"].truthy;
    }

    private Response jobPrecondition(Dict k)
    {
        if (!k.has("sid"))
            return preconditionRequired(gettext("Required properties are missing."));
        manager = getDriver().connectionManager(k["sid"].integer);
        if (manager is null)
            return gone(gettext("Could not find the server."));
        conn = manager.connection();
        templatePath = "pga_job/sql/pre3.4";
        return null;
    }

    private void formatScheduleStepData(Value data, Value jid = Value(null))
    {
        if (!data.isDict)
            return;
        if (data.contains("jschedules") && data["jschedules"].isDict)
        {
            auto jsc = data["jschedules"];
            if (jsc.contains("added") && jsc["added"].isList)
                foreach (s; jsc["added"].list.items)
                    formatScheduleData(s);
            if (jsc.contains("changed") && jsc["changed"].isList)
                foreach (s; jsc["changed"].list.items)
                    formatScheduleData(s);
        }

        bool hc = hasConnStr();
        if (data.contains("jsteps") && data["jsteps"].isDict)
        {
            auto jst = data["jsteps"];
            Value targetJid = jid;
            if (targetJid.isNone && data.contains("jobid"))
                targetJid = data["jobid"];

            if (jst.contains("changed") && jst["changed"].isList)
                foreach (step; jst["changed"].list.items)
                    formatStepData(targetJid, step, hc, conn, templatePath);
        }
    }

    override Response callMethod(string name, Dict k)
    {
        if (!isAuthenticated())
            return unauthorisedResponse();
        if (name == "children")
            return children(k);

        auto err = jobPrecondition(k);
        if (err !is null)
            return err;

        auto gid = k.has("gid") ? k["gid"] : Value(null);
        auto sid = k["sid"];
        auto jid = k.has("jid") ? k["jid"] : Value(null);
        bool hc = hasConnStr();

        switch (name)
        {
        case "node", "nodes":
        {
            auto sql = renderTemplate(templatePath ~ "/" ~ NODES_SQL, tv("jid", jid, "conn", conn));
            auto r = conn.executeDict(sql);
            if (!r.ok)
                return internalServerError(r.error);

            if (!jid.isNone)
            {
                if (r.value["rows"].length != 1)
                    return gone(gettext("Could not find the pgAgent job on the server."));
                auto row = r.value["rows"][0];
                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                        gbn(row["jobid"], sid, row["jobname"].toString,
                            row["jobenabled"].truthy ? "icon-pga_job" : "icon-pga_job-disabled"), 200);
            }

            Value[] res;
            foreach (row; r.value["rows"].list.items)
            {
                res ~= gbn(row["jobid"], sid, row["jobname"].toString,
                        row["jobenabled"].truthy ? "icon-pga_job" : "icon-pga_job-disabled");
            }
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        case "list", "properties":
        {
            auto sql = renderTemplate(templatePath ~ "/" ~ PROPERTIES_SQL, tv("jid", jid, "conn", conn));
            auto r = conn.executeDict(sql);
            if (!r.ok)
                return internalServerError(r.error);

            if (!jid.isNone)
            {
                if (r.value["rows"].length != 1)
                    return gone(gettext("Could not find the pgAgent job on the server."));
                auto res = r.value["rows"][0];

                auto stepSql = renderTemplate(templatePath ~ "/steps.sql",
                        tv("jid", jid, "conn", conn, "has_connstr", Value(hc)));
                auto stepRes = conn.executeDict(stepSql);
                if (!stepRes.ok)
                    return internalServerError(stepRes.error);
                res["jsteps"] = stepRes.value["rows"];

                auto schedSql = renderTemplate(templatePath ~ "/schedules.sql",
                        tv("jid", jid, "conn", conn));
                auto schedRes = conn.executeDict(schedSql);
                if (!schedRes.ok)
                    return internalServerError(schedRes.error);

                foreach (schedule; schedRes.value["rows"].list.items)
                {
                    if (schedule.contains("jexid") && !schedule["jexid"].isNone && schedule["jexid"].length > 0)
                    {
                        Value[] exList;
                        auto exids = schedule["jexid"].list.items;
                        auto dates = schedule["jexdate"].list.items;
                        auto times = schedule["jextime"].list.items;
                        foreach (i; 0 .. exids.length)
                        {
                            exList ~= Value.dictOf(
                                "jexid", exids[i],
                                "jexdate", i < dates.length ? dates[i] : Value(null),
                                "jextime", i < times.length ? times[i] : Value(null)
                            );
                        }
                        schedule["jscexceptions"] = Value(exList);
                    }
                }
                res["jschedules"] = schedRes.value["rows"];
                return makeResponse(res, 200);
            }

            return makeResponse(r.value["rows"], 200);
        }
        case "create":
        {
            Value data = Value.newDict();
            if (request().text.length)
                data = parseJson(request().text);

            if (!data.contains("jobname"))
                return makeJsonResponse(0, Value(gettext("Could not find the required parameter (jobname).")),
                        Value(""), Value(null), Value(null), 410);

            conn.executeVoid("BEGIN");
            auto sql = renderTemplate(templatePath ~ "/" ~ CREATE_SQL,
                    tv("data", data, "conn", conn, "fetch_id", Value(true), "has_connstr", Value(hc)));
            auto r = conn.executeScalar(sql);
            if (!r.ok)
            {
                if (conn.connected())
                    conn.executeVoid("END");
                return internalServerError(r.error);
            }

            auto nodeSql = renderTemplate(templatePath ~ "/" ~ NODES_SQL,
                    tv("jid", r.value, "conn", conn));
            auto nRes = conn.executeDict(nodeSql);
            conn.executeVoid("END");
            if (!nRes.ok)
                return internalServerError(nRes.error);

            auto row = nRes.value["rows"][0];
            auto nodeObj = gbn(row["jobid"], sid, row["jobname"].toString,
                    row["jobenabled"].truthy ? "icon-pga_job" : "icon-pga_job-disabled");

            return makeResponse(Value.dictOf("node", nodeObj), 200);
        }
        case "update":
        {
            Value data = Value.newDict();
            if (request().text.length)
                data = parseJson(request().text);

            formatScheduleStepData(data, jid);

            auto sql = renderTemplate(templatePath ~ "/" ~ UPDATE_SQL,
                    tv("data", data, "conn", conn, "jid", jid, "has_connstr", Value(hc)));
            auto r = conn.executeVoid(sql);
            if (!r.ok)
                return internalServerError(r.error);

            auto nodeSql = renderTemplate(templatePath ~ "/" ~ NODES_SQL,
                    tv("jid", jid, "conn", conn));
            auto nRes = conn.executeDict(nodeSql);
            if (!nRes.ok)
                return internalServerError(nRes.error);

            auto row = nRes.value["rows"][0];
            auto nodeObj = gbn(jid, sid, row["jobname"].toString,
                    row["jobenabled"].truthy ? "icon-pga_job" : "icon-pga_job-disabled");

            return makeResponse(Value.dictOf("node", nodeObj), 200);
        }
        case "delete":
        {
            Value[] ids;
            if (jid.isNone)
            {
                if (request().text.length)
                {
                    auto parsed = parseJson(request().text);
                    if (parsed.isDict && parsed.contains("ids"))
                        ids = parsed["ids"].list.items;
                }
            }
            else
                ids = [jid];

            foreach (delId; ids)
            {
                auto sql = renderTemplate(templatePath ~ "/" ~ DELETE_SQL,
                        tv("jid", delId, "conn", conn));
                auto r = conn.executeVoid(sql);
                if (!r.ok)
                    return internalServerError(r.error);
            }
            return makeJsonResponse(1);
        }
        case "msql":
        {
            Value data = Value.newDict();
            foreach (kArg; request().args.keys)
            {
                auto raw = request().args.get(kArg);
                try { data[kArg] = parseJson(raw); } catch (Exception) { data[kArg] = Value(raw); }
            }

            formatScheduleStepData(data, jid);

            string sql;
            if (jid.isNone)
                sql = renderTemplate(templatePath ~ "/" ~ CREATE_SQL,
                        tv("jid", jid, "data", data, "conn", conn, "fetch_id", Value(false), "has_connstr", Value(hc)));
            else
                sql = renderTemplate(templatePath ~ "/" ~ UPDATE_SQL,
                        tv("jid", jid, "data", data, "conn", conn, "has_connstr", Value(hc)));

            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(sql), 200);
        }
        case "statistics":
        {
            long threshold = 250;
            auto pref = Preferences.module_("browser");
            if (pref !is null)
            {
                auto p = pref.preference("pgagent_row_threshold");
                if (p !is null)
                    threshold = p.get().integer;
            }
            auto sql = renderTemplate(templatePath ~ "/stats.sql",
                    tv("jid", jid, "conn", conn, "rows_threshold", Value(threshold)));
            auto r = conn.executeDict(sql);
            if (!r.ok)
                return internalServerError(r.error);
            return makeJsonResponse(1, Value(""), Value(""), Value(null), r.value, 200);
        }
        case "sql":
        {
            auto propSql = renderTemplate(templatePath ~ "/" ~ PROPERTIES_SQL,
                    tv("jid", jid, "conn", conn, "last_system_oid", Value(0)));
            auto pRes = conn.executeDict(propSql);
            if (!pRes.ok)
                return internalServerError(pRes.error);
            if (pRes.value["rows"].length == 0)
                return gone(gettext("Could not find the object on the server."));

            auto row = pRes.value["rows"][0];

            auto stepSql = renderTemplate(templatePath ~ "/steps.sql",
                    tv("jid", jid, "conn", conn, "has_connstr", Value(hc)));
            auto stepRes = conn.executeDict(stepSql);
            if (!stepRes.ok)
                return internalServerError(stepRes.error);
            row["jsteps"] = stepRes.value["rows"];

            auto schedSql = renderTemplate(templatePath ~ "/schedules.sql",
                    tv("jid", jid, "conn", conn));
            auto schedRes = conn.executeDict(schedSql);
            if (!schedRes.ok)
                return internalServerError(schedRes.error);

            row["jschedules"] = schedRes.value["rows"];
            foreach (schedule; row["jschedules"].list.items)
            {
                Value[] exList;
                if (schedule.contains("jexid") && !schedule["jexid"].isNone && schedule["jexid"].length > 0)
                {
                    auto exids = schedule["jexid"].list.items;
                    auto dates = schedule["jexdate"].list.items;
                    auto times = schedule["jextime"].list.items;
                    foreach (i; 0 .. exids.length)
                    {
                        exList ~= Value.dictOf(
                            "jexid", exids[i],
                            "jexdate", i < dates.length ? dates[i] : Value(null),
                            "jextime", i < times.length ? times[i] : Value(null)
                        );
                    }
                }
                schedule["jscexceptions"] = Value(exList);
                schedule.dict.remove("jexid");
                schedule.dict.remove("jexdate");
                schedule.dict.remove("jextime");
            }

            auto createSql = renderTemplate(templatePath ~ "/" ~ CREATE_SQL,
                    tv("jid", jid, "data", row, "conn", conn, "fetch_id", Value(false), "has_connstr", Value(hc)));

            return makeResponse(Value(createSql), 200);
        }
        case "run_now":
        {
            auto sql = renderTemplate(templatePath ~ "/run_now.sql",
                    tv("jid", jid, "conn", conn));
            auto r = conn.executeVoid(sql);
            if (!r.ok)
                return internalServerError(r.error);
            return makeJsonResponse(1, Value(gettext("Updated the next runtime to now.")));
        }
        case "job_classes":
        {
            auto sql = renderTemplate(templatePath ~ "/job_classes.sql");
            auto r = conn.executeDict(sql);
            if (!r.ok)
                return internalServerError(r.error);
            return makeJsonResponse(1, Value(""), Value(""), Value(null), r.value["rows"], 200);
        }
        default:
            return super.callMethod(name, k);
        }
    }
}
