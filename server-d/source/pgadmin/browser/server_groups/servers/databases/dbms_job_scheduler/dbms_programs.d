/// `databases/dbms_job_scheduler/dbms_programs`: EPAS DBMS Program node module.
module pgadmin.browser.server_groups.servers.databases.dbms_job_scheduler.dbms_programs;

import std.conv : to;
import std.string : strip;
import pgadmin.browser.common;
import pgadmin.browser.utils;
import pgadmin.core.i18n;
import pgadmin.core.templates : renderTemplate, tv;
import pgadmin.core.value;
import pgadmin.db.driver : Connection, ServerManager, getDriver, Res;
import pgadmin.utils.constants : DBMS_JOB_SCHEDULER_ID;
import pgadmin.web.auth;
import pgadmin.web.http;

final class DBMSProgramModule : CollectionNodeModule
{
    enum NODE_TYPE = "dbms_program";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "DBMS Programs";
        staticDir("browser/server_groups/servers/databases/dbms_job_scheduler/dbms_programs");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => "database";
    override bool nodeInode() => false;
    override bool moduleUseTemplateJavascript() => false;

    override Value[] getNodes(Dict kwargs) => [generateBrowserCollectionNode(kwargs["did"])];

    override void setup()
    {
        registerNodeView!DBMSProgramView(this);
    }
}

final class DBMSProgramView : PGChildNodeView
{
    enum BASE_TEMPLATE_PATH = "dbms_programs/ppas/#{0}#";

    this()
    {
        super();
        nodeType = DBMSProgramModule.NODE_TYPE;
        nodeLabel = "DBMS Program";
        parentIds = [
            IdSpec("int", "gid"), IdSpec("int", "sid"), IdSpec("int", "did"),
            IdSpec("int", "jsid")
        ];
        ids = [IdSpec("int", "jsprid")];
        setAllOps([
            makeOp("obj", ["get": "properties", "delete": "delete"],
                    ["get": "list", "post": "create", "delete": "delete"]),
            makeOp("nodes", ["get": "nodes"], ["get": "nodes"]),
            makeOp("msql", ["get": "msql"], ["get": "msql"]),
            makeOp("sql", ["get": "sql"]),
            makeOp("get_procedures", ["get": "get_procedures"], ["get": "get_procedures"]),
            makeOp("enable_disable", ["put": "enable_disable"]),
        ]);
    }

    private Response programPrecondition(Dict k)
    {
        if (!k.has("sid") || !k.has("did"))
            return preconditionRequired(gettext("Required properties are missing."));
        manager = getDriver().connectionManager(k["sid"].integer);
        if (manager is null)
            return gone(gettext("Could not find the server."));
        conn = manager.connection(null, null, true, k["did"]);
        if (!conn.connected())
            return preconditionRequired(gettext("Connection to the server has been lost."));
        templatePath = "dbms_programs/ppas/#" ~ to!string(manager.version_) ~ "#";
        return null;
    }

    override Response callMethod(string name, Dict k)
    {
        if (!isAuthenticated())
            return unauthorisedResponse();

        auto err = programPrecondition(k);
        if (err !is null)
            return err;

        auto sid = k["sid"];
        auto did = k["did"];
        auto jsid = k.has("jsid") ? k["jsid"] : Value(DBMS_JOB_SCHEDULER_ID);
        auto jsprid = k.has("jsprid") ? k["jsprid"] : Value(null);

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

            if (!jsprid.isNone)
            {
                if (r.value["rows"].length == 0)
                    return gone(gettext("Could not find the specified program."));
                auto row = r.value["rows"][0];
                bool isEnabled = row["jsprenabled"].truthy;
                auto icon = isEnabled ? "icon-pga_jobstep" : "icon-pga_jobstep-disabled";
                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                        gbn(row["jsprid"], Value(DBMS_JOB_SCHEDULER_ID), row["jsprname"].toString, icon), 200);
            }

            Value[] res;
            foreach (row; r.value["rows"].list.items)
            {
                bool isEnabled = row["jsprenabled"].truthy;
                auto icon = isEnabled ? "icon-pga_jobstep" : "icon-pga_jobstep-disabled";
                res ~= gbn(row["jsprid"], Value(DBMS_JOB_SCHEDULER_ID), row["jsprname"].toString, icon);
            }
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        case "properties":
        {
            auto sql = renderTemplate(templatePath ~ "/" ~ PROPERTIES_SQL, tv("jsprid", jsprid, "conn", conn));
            auto r = conn.executeDict(sql);
            if (!r.ok)
                return internalServerError(r.error);
            if (r.value["rows"].length == 0)
                return gone(gettext("Could not find the specified program."));
            return makeResponse(r.value["rows"][0], 200);
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

            auto progAction = data.get("jsprtype").toString == "STORED_PROCEDURE"
                ? data.get("jsprproc") : data.get("jsprcode");

            auto sql = renderTemplate(templatePath ~ "/" ~ CREATE_SQL, tv(
                "program_name", data.get("jsprname"),
                "program_type", data.get("jsprtype"),
                "program_action", progAction,
                "number_of_arguments", data.get("jsprnoofargs"),
                "enabled", data.get("jsprenabled"),
                "comments", data.get("jsprdesc"),
                "arguments", data.get("jsprarguments"),
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

            auto oidSql = renderTemplate(templatePath ~ "/get_program_id.sql",
                    tv("jsprname", data.get("jsprname"), "conn", conn));
            auto or = conn.executeDict(oidSql);
            if (!or.ok || or.value["rows"].length == 0)
                return internalServerError(gettext("Job program creation failed."));

            auto row = or.value["rows"][0];
            bool isEnabled = row["jsprenabled"].truthy;
            auto icon = isEnabled ? "icon-pga_jobstep" : "icon-pga_jobstep-disabled";

            return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    Value(["node": gbn(row["jsprid"], Value(DBMS_JOB_SCHEDULER_ID), row["jsprname"].toString, icon)]), 200);
        }
        case "delete":
        {
            Value[] ids;
            if (!jsprid.isNone)
                ids ~= jsprid;
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
                        tv("jsprid", id, "conn", conn));
                auto r = conn.executeDict(propSql);
                if (!r.ok || r.value["rows"].length == 0)
                    return gone(gettext("Could not find the specified program."));
                auto jsprname = r.value["rows"][0]["jsprname"];

                auto delSql = renderTemplate(templatePath ~ "/" ~ DELETE_SQL,
                        tv("program_name", jsprname, "conn", conn));
                auto dr = conn.executeVoid(delSql);
                if (!dr.ok)
                    return internalServerError(dr.error);
            }

            return makeJsonResponse(1, Value(""), Value(gettext("Program dropped")), Value(null), Value(null), 200);
        }
        case "msql":
        {
            Value data = Value.newDict();
            foreach (kArg; request().args.keys)
            {
                auto raw = request().args.get(kArg);
                try { data[kArg] = parseJson(raw); } catch (Exception) { data[kArg] = Value(raw); }
            }

            auto progAction = data.get("jsprtype").toString == "STORED_PROCEDURE"
                ? data.get("jsprproc") : data.get("jsprcode");

            auto sql = renderTemplate(templatePath ~ "/" ~ CREATE_SQL, tv(
                "program_name", data.get("jsprname"),
                "program_type", data.get("jsprtype"),
                "program_action", progAction,
                "number_of_arguments", data.get("jsprnoofargs"),
                "enabled", data.get("jsprenabled"),
                "comments", data.get("jsprdesc"),
                "arguments", data.get("jsprarguments"),
                "conn", conn
            ));
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(strip(sql)), 200);
        }
        case "sql":
        {
            auto propSql = renderTemplate(templatePath ~ "/" ~ PROPERTIES_SQL,
                    tv("jsprid", jsprid, "conn", conn));
            auto r = conn.executeDict(propSql);
            if (!r.ok || r.value["rows"].length == 0)
                return gone(gettext("Could not find the DBMS Program."));
            auto data = r.value["rows"][0];

            auto progAction = data.get("jsprtype").toString == "STORED_PROCEDURE"
                ? data.get("jsprproc") : data.get("jsprcode");

            auto sql = renderTemplate(templatePath ~ "/" ~ CREATE_SQL, tv(
                "display_comments", true,
                "program_name", data.get("jsprname"),
                "program_type", data.get("jsprtype"),
                "program_action", progAction,
                "number_of_arguments", data.get("jsprnoofargs"),
                "enabled", data.get("jsprenabled"),
                "comments", data.get("jsprdesc"),
                "arguments", data.get("jsprarguments"),
                "conn", conn
            ));
            return makeResponse(Value(strip(sql)), 200);
        }
        case "get_procedures":
        {
            auto sql = renderTemplate(templatePath ~ "/get_procedures.sql",
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
        case "enable_disable":
        {
            Value data = Value.newDict();
            if (request().text.length)
            {
                try
                    data = parseJson(request().text);
                catch (Exception e)
                    return badRequest(e.msg);
            }
            auto name_ = data.get("program_name");
            auto isEnable = data.get("is_enable_program").truthy;

            auto sql = renderTemplate(templatePath ~ "/enable_disable.sql",
                    tv("name", name_, "is_enable", isEnable, "conn", conn));
            auto r = conn.executeVoid(sql);
            if (!r.ok)
                return internalServerError(r.error);

            auto msg = isEnable ? gettext("Program enabled") : gettext("Program disabled");
            return makeJsonResponse(1, Value(""), Value(msg), Value(null),
                    Value.dictOf("sid", sid, "did", did, "jsid", jsid, "jsprid", jsprid), 200);
        }
        default:
            return super.callMethod(name, k);
        }
    }
}
