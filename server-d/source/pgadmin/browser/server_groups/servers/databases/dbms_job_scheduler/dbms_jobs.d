/// `databases/dbms_job_scheduler/dbms_jobs`: EPAS DBMS Job node module.
module pgadmin.browser.server_groups.servers.databases.dbms_job_scheduler.dbms_jobs;

import std.conv : to;
import std.string : strip;
import pgadmin.browser.common;
import pgadmin.browser.server_groups.servers.databases.dbms_job_scheduler.utils;
import pgadmin.browser.utils;
import pgadmin.core.i18n;
import pgadmin.core.templates : renderTemplate, tv;
import pgadmin.core.value;
import pgadmin.db.driver : Connection, ServerManager, getDriver, Res;
import pgadmin.utils.constants : DBMS_JOB_SCHEDULER_ID;
import pgadmin.web.auth;
import pgadmin.web.http;

final class DBMSJobModule : CollectionNodeModule
{
    enum NODE_TYPE = "dbms_job";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "DBMS Jobs";
        staticDir("browser/server_groups/servers/databases/dbms_job_scheduler/dbms_jobs");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => "database";
    override bool nodeInode() => false;
    override bool moduleUseTemplateJavascript() => false;

    override Value[] getNodes(Dict kwargs) => [generateBrowserCollectionNode(kwargs["did"])];

    override void setup()
    {
        registerNodeView!DBMSJobView(this);
    }
}

final class DBMSJobView : PGChildNodeView
{
    enum BASE_TEMPLATE_PATH = "dbms_jobs/ppas/#{0}#";
    enum PROGRAM_TEMPLATE_PATH = "dbms_programs/ppas/#{0}#";
    enum SCHEDULE_TEMPLATE_PATH = "dbms_schedules/ppas/#{0}#";

    this()
    {
        super();
        nodeType = DBMSJobModule.NODE_TYPE;
        nodeLabel = "DBMS Job";
        parentIds = [
            IdSpec("int", "gid"), IdSpec("int", "sid"), IdSpec("int", "did"),
            IdSpec("int", "jsid")
        ];
        ids = [IdSpec("int", "jsjobid")];
        setAllOps([
            makeOp("obj", ["get": "properties", "delete": "delete", "put": "update"],
                    ["get": "list", "post": "create", "delete": "delete"]),
            makeOp("nodes", ["get": "nodes"], ["get": "nodes"]),
            makeOp("msql", ["get": "msql"], ["get": "msql"]),
            makeOp("sql", ["get": "sql"]),
            makeOp("get_procedures", ["get": "get_procedures"], ["get": "get_procedures"]),
            makeOp("enable_disable", ["put": "enable_disable"]),
            makeOp("get_programs", ["get": "get_programs"], ["get": "get_programs"]),
            makeOp("get_schedules", ["get": "get_schedules"], ["get": "get_schedules"]),
            makeOp("run_job", ["put": "run_job"]),
        ]);
    }

    private string prTemplatePath;
    private string schTemplatePath;

    private Response jobPrecondition(Dict k)
    {
        if (!k.has("sid") || !k.has("did"))
            return preconditionRequired(gettext("Required properties are missing."));
        manager = getDriver().connectionManager(k["sid"].integer);
        if (manager is null)
            return gone(gettext("Could not find the server."));
        conn = manager.connection(null, null, true, k["did"]);
        if (!conn.connected())
            return preconditionRequired(gettext("Connection to the server has been lost."));

        auto verStr = to!string(manager.version_);
        templatePath = "dbms_jobs/ppas/#" ~ verStr ~ "#";
        prTemplatePath = "dbms_programs/ppas/#" ~ verStr ~ "#";
        schTemplatePath = "dbms_schedules/ppas/#" ~ verStr ~ "#";
        return null;
    }

    private string buildRepeatInterval(Value data)
    {
        string freq = data.get("jsscfreq").toString;
        string date = data.get("jsscdate").toString;
        string[] months;
        if (data.contains("jsscmonths") && data["jsscmonths"].isList)
            foreach (m; data["jsscmonths"].list.items)
                months ~= m.toString;
        string[] monthdays;
        if (data.contains("jsscmonthdays") && data["jsscmonthdays"].isList)
            foreach (d; data["jsscmonthdays"].list.items)
                monthdays ~= d.toString;
        string[] weekdays;
        if (data.contains("jsscweekdays") && data["jsscweekdays"].isList)
            foreach (w; data["jsscweekdays"].list.items)
                weekdays ~= w.toString;
        string[] hours;
        if (data.contains("jsschours") && data["jsschours"].isList)
            foreach (h; data["jsschours"].list.items)
                hours ~= h.toString;
        string[] minutes;
        if (data.contains("jsscminutes") && data["jsscminutes"].isList)
            foreach (m; data["jsscminutes"].list.items)
                minutes ~= m.toString;

        return createCalendarString(freq, date, months, monthdays, weekdays, hours, minutes);
    }

    private string getSql(Value jsjobid, Value data, out string outName, out bool outEnabled)
    {
        if (jsjobid.isNone)
        {
            outName = data.get("jsjobname").toString;
            outEnabled = data.get("jsjobenabled").truthy;
            auto repeatInterval = buildRepeatInterval(data);
            auto jobAction = data.get("jsprtype").toString == "STORED_PROCEDURE"
                ? data.get("jsprproc") : data.get("jsprcode");

            auto sql = renderTemplate(templatePath ~ "/" ~ CREATE_SQL, tv(
                "job_name", data.get("jsjobname"),
                "internal_job_type", data.get("jsjobtype"),
                "job_type", data.get("jsprtype"),
                "job_action", jobAction,
                "enabled", data.get("jsjobenabled"),
                "comments", data.get("jsjobdesc"),
                "number_of_arguments", data.get("jsprnoofargs"),
                "start_date", data.get("jsscstart"),
                "repeat_interval", Value(repeatInterval),
                "end_date", data.get("jsscend"),
                "program_name", data.get("jsjobprname"),
                "schedule_name", data.get("jsjobscname"),
                "arguments", data.get("jsprarguments"),
                "conn", conn
            ));
            return strip(sql);
        }
        else
        {
            auto propSql = renderTemplate(templatePath ~ "/" ~ PROPERTIES_SQL,
                    tv("jsjobid", jsjobid, "conn", conn));
            auto r = conn.executeDict(propSql);
            if (!r.ok || r.value["rows"].length == 0)
                return "";
            auto oldData = r.value["rows"][0];
            outName = oldData["jsjobname"].toString;
            outEnabled = oldData["jsjobenabled"].truthy;

            Value changedVal = Value.newList();
            if (data.contains("jsprarguments") && data["jsprarguments"].isDict && data["jsprarguments"].contains("changed"))
                changedVal = data["jsprarguments"]["changed"];

            auto sql = renderTemplate(templatePath ~ "/" ~ UPDATE_SQL, tv(
                "job_name", oldData["jsjobname"],
                "changed_value", changedVal,
                "conn", conn
            ));
            return strip(sql);
        }
    }

    override Response callMethod(string name, Dict k)
    {
        if (!isAuthenticated())
            return unauthorisedResponse();

        auto err = jobPrecondition(k);
        if (err !is null)
            return err;

        auto sid = k["sid"];
        auto did = k["did"];
        auto jsid = k.has("jsid") ? k["jsid"] : Value(DBMS_JOB_SCHEDULER_ID);
        auto jsjobid = k.has("jsjobid") ? k["jsjobid"] : Value(null);

        switch (name)
        {
        case "list":
        {
            auto sql = renderTemplate(templatePath ~ "/" ~ PROPERTIES_SQL, tv("conn", conn));
            auto r = conn.executeDict(sql);
            if (!r.ok)
                return internalServerError(r.error);
            return makeResponse(r.value["rows"], 200);
        }
        case "nodes":
        {
            auto sql = renderTemplate(templatePath ~ "/" ~ NODES_SQL, tv("conn", conn));
            auto r = conn.execute2darray(sql);
            if (!r.ok)
                return internalServerError(r.error);

            if (!jsjobid.isNone)
            {
                if (r.value["rows"].length == 0)
                    return gone(gettext("Could not find the specified job."));
                auto row = r.value["rows"][0];
                bool isEnabled = row["jsjobenabled"].truthy;
                auto icon = isEnabled ? "icon-pga_job" : "icon-pga_job-disabled";
                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                        gbn(row["jsjobid"], Value(DBMS_JOB_SCHEDULER_ID), row["jsjobname"].toString, icon), 200);
            }

            Value[] res;
            foreach (row; r.value["rows"].list.items)
            {
                bool isEnabled = row["jsjobenabled"].truthy;
                auto icon = isEnabled ? "icon-pga_job" : "icon-pga_job-disabled";
                res ~= gbn(row["jsjobid"], Value(DBMS_JOB_SCHEDULER_ID), row["jsjobname"].toString, icon);
            }
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        case "properties":
        {
            auto sql = renderTemplate(templatePath ~ "/" ~ PROPERTIES_SQL,
                    tv("jsjobid", jsjobid, "conn", conn));
            auto r = conn.executeDict(sql);
            if (!r.ok)
                return internalServerError(r.error);
            if (r.value["rows"].length == 0)
                return gone(gettext("Could not find the specified job."));
            auto row = r.value["rows"][0];

            if (row.contains("jsjobscname") && !row["jsjobscname"].isNone &&
                row.contains("jsjobprname") && !row["jsjobprname"].isNone)
                row["jsjobtype"] = Value("p");
            else
                row["jsjobtype"] = Value("s");

            if (row.contains("jsscrepeatint") && !row["jsscrepeatint"].isNone)
            {
                auto cal = resolveCalendarString(row["jsscrepeatint"].toString);
                row["jsscfreq"] = Value(cal.freq);
                row["jsscdate"] = Value(cal.byDate);
                Value[] monthsList; foreach (m; cal.byMonth) monthsList ~= Value(m);
                row["jsscmonths"] = Value(monthsList);
                Value[] monthdaysList; foreach (md; cal.byMonthday) monthdaysList ~= Value(md);
                row["jsscmonthdays"] = Value(monthdaysList);
                Value[] weekdaysList; foreach (wd; cal.byWeekday) weekdaysList ~= Value(wd);
                row["jsscweekdays"] = Value(weekdaysList);
                Value[] hoursList; foreach (h; cal.byHour) hoursList ~= Value(h);
                row["jsschours"] = Value(hoursList);
                Value[] minutesList; foreach (m; cal.byMinute) minutesList ~= Value(m);
                row["jsscminutes"] = Value(minutesList);
            }

            return makeResponse(row, 200);
        }
        case "create":
        {
            Value data = Value.newDict();
            if (request().text.length)
            {
                try
                    data = parseJson(request().text);
                catch (Exception e)
                    return badRequest(e.msg);
            }

            string outName;
            bool outEnabled;
            auto sql = getSql(Value(null), data, outName, outEnabled);

            conn.executeVoid("BEGIN");
            auto cr = conn.executeScalar(sql);
            if (!cr.ok)
            {
                conn.executeVoid("ROLLBACK");
                return internalServerError(cr.error);
            }
            conn.executeVoid("COMMIT");

            auto oidSql = renderTemplate(templatePath ~ "/get_job_id.sql",
                    tv("jsjobname", data.get("jsjobname"), "conn", conn));
            auto or = conn.executeDict(oidSql);
            if (!or.ok || or.value["rows"].length == 0)
                return internalServerError(gettext("Job creation failed."));

            auto row = or.value["rows"][0];
            bool isEnabled = row["jsjobenabled"].truthy;
            auto icon = isEnabled ? "icon-pga_job" : "icon-pga_job-disabled";

            return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    Value(["node": gbn(row["jsjobid"], Value(DBMS_JOB_SCHEDULER_ID), row["jsjobname"].toString, icon)]), 200);
        }
        case "update":
        {
            Value data = Value.newDict();
            if (request().text.length)
            {
                try
                    data = parseJson(request().text);
                catch (Exception e)
                    return badRequest(e.msg);
            }

            string outName;
            bool outEnabled;
            auto sql = getSql(jsjobid, data, outName, outEnabled);
            if (sql.length > 0)
            {
                auto ur = conn.executeScalar(sql);
                if (!ur.ok)
                    return internalServerError(ur.error);
            }

            auto icon = outEnabled ? "icon-pga_job" : "icon-pga_job-disabled";
            return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    Value(["node": gbn(jsjobid, Value(DBMS_JOB_SCHEDULER_ID), outName, icon)]), 200);
        }
        case "delete":
        {
            Value[] ids;
            if (!jsjobid.isNone)
                ids ~= jsjobid;
            else if (request().text.length)
            {
                try
                {
                    auto body = parseJson(request().text);
                    if (body.contains("ids") && body["ids"].isList)
                        foreach (id; body["ids"].list.items)
                            ids ~= id;
                }
                catch (Exception e)
                    return badRequest(e.msg);
            }

            foreach (id; ids)
            {
                auto propSql = renderTemplate(templatePath ~ "/" ~ PROPERTIES_SQL,
                        tv("jsjobid", id, "conn", conn));
                auto r = conn.executeDict(propSql);
                if (!r.ok || r.value["rows"].length == 0)
                    return gone(gettext("Could not find the specified job."));
                auto jsjobname = r.value["rows"][0]["jsjobname"];

                auto delSql = renderTemplate(templatePath ~ "/" ~ DELETE_SQL,
                        tv("job_name", jsjobname, "conn", conn));
                auto dr = conn.executeVoid(delSql);
                if (!dr.ok)
                    return internalServerError(dr.error);
            }

            return makeJsonResponse(1, Value(""), Value(gettext("Job dropped")), Value(null), Value(null), 200);
        }
        case "msql":
        {
            Value data = Value.newDict();
            foreach (kArg; request().args.keys)
            {
                auto raw = request().args.get(kArg);
                try { data[kArg] = parseJson(raw); } catch (Exception) { data[kArg] = Value(raw); }
            }
            string outName;
            bool outEnabled;
            auto sql = getSql(jsjobid, data, outName, outEnabled);
            if (sql.length == 0)
                sql = "--modified SQL";
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(sql), 200);
        }
        case "sql":
        {
            auto propSql = renderTemplate(templatePath ~ "/" ~ PROPERTIES_SQL,
                    tv("jsjobid", jsjobid, "conn", conn));
            auto r = conn.executeDict(propSql);
            if (!r.ok || r.value["rows"].length == 0)
                return gone(gettext("Could not find the specified job."));
            auto data = r.value["rows"][0];

            auto repeatInterval = data.get("jsscrepeatint").toString;
            auto jobAction = data.get("jsprtype").toString == "STORED_PROCEDURE"
                ? data.get("jsprproc") : data.get("jsprcode");

            auto sql = renderTemplate(templatePath ~ "/" ~ CREATE_SQL, tv(
                "display_comments", true,
                "job_name", data.get("jsjobname"),
                "internal_job_type", data.get("jsjobtype"),
                "job_type", data.get("jsprtype"),
                "job_action", jobAction,
                "enabled", data.get("jsjobenabled"),
                "comments", data.get("jsjobdesc"),
                "number_of_arguments", data.get("jsprnoofargs"),
                "start_date", data.get("jsscstart"),
                "repeat_interval", Value(repeatInterval),
                "end_date", data.get("jsscend"),
                "program_name", data.get("jsjobprname"),
                "schedule_name", data.get("jsjobscname"),
                "arguments", data.get("jsprarguments"),
                "conn", conn
            ));
            return makeResponse(Value(strip(sql)), 200);
        }
        case "get_procedures":
        {
            auto sql = renderTemplate(prTemplatePath ~ "/get_procedures.sql",
                    tv("datlastsysoid", Value(DATABASE_LAST_SYSTEM_OID)));
            auto r = conn.executeDict(sql);
            if (!r.ok)
                return internalServerError(r.error);
            Value[] res;
            foreach (row; r.value["rows"].list.items)
            {
                res ~= Value.dictOf(
                    "label", row["proc_name"],
                    "value", row["proc_name"],
                    "no_of_args", row["number_of_arguments"]
                );
            }
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        case "get_programs":
        {
            auto sql = renderTemplate(prTemplatePath ~ "/" ~ NODES_SQL, tv("conn", conn));
            auto r = conn.executeDict(sql);
            if (!r.ok)
                return internalServerError(r.error);
            Value[] res;
            foreach (row; r.value["rows"].list.items)
                res ~= Value.dictOf("label", row["jsprname"], "value", row["jsprname"]);
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        case "get_schedules":
        {
            auto sql = renderTemplate(schTemplatePath ~ "/" ~ NODES_SQL, tv("conn", conn));
            auto r = conn.executeDict(sql);
            if (!r.ok)
                return internalServerError(r.error);
            Value[] res;
            foreach (row; r.value["rows"].list.items)
                res ~= Value.dictOf("label", row["jsscname"], "value", row["jsscname"]);
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        case "run_job":
        {
            Value data = Value.newDict();
            if (request().text.length)
            {
                try
                    data = parseJson(request().text);
                catch (Exception e)
                    return badRequest(e.msg);
            }

            auto sql = renderTemplate(templatePath ~ "/run_job.sql",
                    tv("job_name", data.get("job_name"), "conn", conn));
            auto r = conn.executeVoid(sql);
            if (!r.ok)
                return internalServerError(r.error);
            return makeJsonResponse(1, Value(""), Value(gettext("Started the Job execution.")), Value(null), Value(null), 200);
        }
        default:
            return super.callMethod(name, k);
        }
    }
}
