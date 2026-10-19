/// `databases/dbms_job_scheduler/dbms_schedules`: EPAS DBMS Schedule node module.
module pgadmin.browser.server_groups.servers.databases.dbms_job_scheduler.dbms_schedules;

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

final class DBMSScheduleModule : CollectionNodeModule
{
    enum NODE_TYPE = "dbms_schedule";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "DBMS Schedules";
        staticDir("browser/server_groups/servers/databases/dbms_job_scheduler/dbms_schedules");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => "database";
    override bool nodeInode() => false;
    override bool moduleUseTemplateJavascript() => false;

    override Value[] getNodes(Dict kwargs) => [generateBrowserCollectionNode(kwargs["did"])];

    override void setup()
    {
        registerNodeView!DBMSScheduleView(this);
    }
}

final class DBMSScheduleView : PGChildNodeView
{
    enum BASE_TEMPLATE_PATH = "dbms_schedules/ppas/#{0}#";

    this()
    {
        super();
        nodeType = DBMSScheduleModule.NODE_TYPE;
        nodeLabel = "DBMS Schedule";
        parentIds = [
            IdSpec("int", "gid"), IdSpec("int", "sid"), IdSpec("int", "did"),
            IdSpec("int", "jsid")
        ];
        ids = [IdSpec("int", "jsscid")];
        setAllOps([
            makeOp("obj", ["get": "properties", "delete": "delete"],
                    ["get": "list", "post": "create", "delete": "delete"]),
            makeOp("nodes", ["get": "nodes"], ["get": "nodes"]),
            makeOp("msql", ["get": "msql"], ["get": "msql"]),
            makeOp("sql", ["get": "sql"]),
        ]);
    }

    private Response schedulePrecondition(Dict k)
    {
        if (!k.has("sid") || !k.has("did"))
            return preconditionRequired(gettext("Required properties are missing."));
        manager = getDriver().connectionManager(k["sid"].integer);
        if (manager is null)
            return gone(gettext("Could not find the server."));
        conn = manager.connection(null, null, true, k["did"]);
        if (!conn.connected())
            return preconditionRequired(gettext("Connection to the server has been lost."));
        templatePath = "dbms_schedules/ppas/#" ~ to!string(manager.version_) ~ "#";
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

    override Response callMethod(string name, Dict k)
    {
        if (!isAuthenticated())
            return unauthorisedResponse();

        auto err = schedulePrecondition(k);
        if (err !is null)
            return err;

        auto sid = k["sid"];
        auto did = k["did"];
        auto jsid = k.has("jsid") ? k["jsid"] : Value(DBMS_JOB_SCHEDULER_ID);
        auto jsscid = k.has("jsscid") ? k["jsscid"] : Value(null);

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

            if (!jsscid.isNone)
            {
                if (r.value["rows"].length == 0)
                    return gone(gettext("Could not find the specified schedule."));
                auto row = r.value["rows"][0];
                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                        gbn(row["jsscid"], Value(DBMS_JOB_SCHEDULER_ID), row["jsscname"].toString, "icon-pga_schedule"), 200);
            }

            Value[] res;
            foreach (row; r.value["rows"].list.items)
                res ~= gbn(row["jsscid"], Value(DBMS_JOB_SCHEDULER_ID), row["jsscname"].toString, "icon-pga_schedule");
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        case "properties":
        {
            auto sql = renderTemplate(templatePath ~ "/" ~ PROPERTIES_SQL, tv("jsscid", jsscid, "conn", conn));
            auto r = conn.executeDict(sql);
            if (!r.ok)
                return internalServerError(r.error);
            if (r.value["rows"].length == 0)
                return gone(gettext("Could not find the specified schedule."));
            auto row = r.value["rows"][0];

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

            auto repeatInterval = buildRepeatInterval(data);

            auto sql = renderTemplate(templatePath ~ "/" ~ CREATE_SQL, tv(
                "schedule_name", data.get("jsscname"),
                "start_date", data.get("jsscstart"),
                "repeat_interval", Value(repeatInterval),
                "end_date", data.get("jsscend"),
                "comments", data.get("jsscdesc"),
                "conn", conn
            ));

            conn.executeVoid("BEGIN");
            auto cr = conn.executeScalar(sql);
            if (!cr.ok)
            {
                conn.executeVoid("ROLLBACK");
                return internalServerError(cr.error);
            }
            conn.executeVoid("COMMIT");

            auto oidSql = renderTemplate(templatePath ~ "/get_schedule_id.sql",
                    tv("jsscname", data.get("jsscname"), "conn", conn));
            auto or = conn.executeDict(oidSql);
            if (!or.ok || or.value["rows"].length == 0)
                return internalServerError(gettext("Job schedule creation failed."));

            auto row = or.value["rows"][0];
            return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    Value(["node": gbn(row["jsscid"], Value(DBMS_JOB_SCHEDULER_ID), row["jsscname"].toString, "icon-pga_schedule")]), 200);
        }
        case "delete":
        {
            Value[] ids;
            if (!jsscid.isNone)
                ids ~= jsscid;
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
                        tv("jsscid", id, "conn", conn));
                auto r = conn.executeDict(propSql);
                if (!r.ok || r.value["rows"].length == 0)
                    return gone(gettext("Could not find the specified schedule."));
                auto jsscname = r.value["rows"][0]["jsscname"];

                auto delSql = renderTemplate(templatePath ~ "/" ~ DELETE_SQL,
                        tv("schedule_name", jsscname, "conn", conn));
                auto dr = conn.executeVoid(delSql);
                if (!dr.ok)
                    return internalServerError(dr.error);
            }

            return makeJsonResponse(1, Value(""), Value(gettext("Schedule dropped")), Value(null), Value(null), 200);
        }
        case "msql":
        {
            Value data = Value.newDict();
            foreach (kArg; request().args.keys)
            {
                auto raw = request().args.get(kArg);
                try { data[kArg] = parseJson(raw); } catch (Exception) { data[kArg] = Value(raw); }
            }

            auto repeatInterval = buildRepeatInterval(data);
            auto sql = renderTemplate(templatePath ~ "/" ~ CREATE_SQL, tv(
                "schedule_name", data.get("jsscname"),
                "start_date", data.get("jsscstart"),
                "repeat_interval", Value(repeatInterval),
                "end_date", data.get("jsscend"),
                "comments", data.get("jsscdesc"),
                "conn", conn
            ));
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(strip(sql)), 200);
        }
        case "sql":
        {
            auto propSql = renderTemplate(templatePath ~ "/" ~ PROPERTIES_SQL,
                    tv("jsscid", jsscid, "conn", conn));
            auto r = conn.executeDict(propSql);
            if (!r.ok || r.value["rows"].length == 0)
                return gone(gettext("Could not find the DBMS Schedule."));
            auto data = r.value["rows"][0];

            auto repeatInterval = data.get("jsscrepeatint").toString;
            auto sql = renderTemplate(templatePath ~ "/" ~ CREATE_SQL, tv(
                "display_comments", true,
                "schedule_name", data.get("jsscname"),
                "start_date", data.get("jsscstart"),
                "repeat_interval", Value(repeatInterval),
                "end_date", data.get("jsscend"),
                "comments", data.get("jsscdesc"),
                "conn", conn
            ));
            return makeResponse(Value(strip(sql)), 200);
        }
        default:
            return super.callMethod(name, k);
        }
    }
}
