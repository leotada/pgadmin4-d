/// `databases/dbms_job_scheduler`: EPAS DBMS Job Scheduler collection node module.
module pgadmin.browser.server_groups.servers.databases.dbms_job_scheduler;

import std.algorithm : canFind;
import std.conv : to;
import pgadmin.browser.common;
import pgadmin.browser.server_groups.servers.databases.dbms_job_scheduler.dbms_jobs : DBMSJobModule;
import pgadmin.browser.server_groups.servers.databases.dbms_job_scheduler.dbms_programs : DBMSProgramModule;
import pgadmin.browser.server_groups.servers.databases.dbms_job_scheduler.dbms_schedules : DBMSScheduleModule;
import pgadmin.browser.utils;
import pgadmin.core.i18n;
import pgadmin.core.templates : renderTemplate, tv;
import pgadmin.core.value;
import pgadmin.db.driver : Connection, ServerManager, getDriver, Res;
import pgadmin.utils.constants : DBMS_JOB_SCHEDULER_ID;
import pgadmin.web.auth;
import pgadmin.web.http;

final class DBMSJobSchedulerModule : CollectionNodeModule
{
    enum NODE_TYPE = "dbms_job_scheduler";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "DBMS Job Scheduler";
        staticDir("browser/server_groups/servers/databases/dbms_job_scheduler");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => "database";
    override bool nodeInode() => true;
    override bool moduleUseTemplateJavascript() => false;

    override Value[] getNodes(Dict kwargs)
    {
        if (showNode && kwargs.has("did"))
            return [generateBrowserNode(Value(DBMS_JOB_SCHEDULER_ID), kwargs["did"], collectionLabelText, "icon-coll-dbms_job_scheduler")];
        return null;
    }

    override bool backendSupported(ServerManager manager, Dict kwargs)
    {
        if (!showNode)
            return false;
        if (!kwargs.has("did"))
            return false;

        try
        {
            auto conn = manager.connection(null, null, true, kwargs["did"]);
            if (!conn.connected())
                return false;

            auto r = conn.executeScalar("SELECT COUNT(*) FROM pg_catalog.pg_extension WHERE extname IN ('edb_job_scheduler', 'dbms_scheduler')");
            if (r.ok && r.value.integer == 2)
            {
                auto lr = conn.executeScalar("SHOW edb_job_scheduler.database_list");
                if (lr.ok && lr.value.toString.canFind(conn.db))
                    return true;
            }
        }
        catch (Exception)
        {
            return false;
        }
        return false;
    }

    override void setup()
    {
        submodules ~= new DBMSJobModule;
        submodules ~= new DBMSProgramModule;
        submodules ~= new DBMSScheduleModule;
        registerNodeView!DBMSJobSchedulerView(this);
    }
}

final class DBMSJobSchedulerView : PGChildNodeView
{
    enum BASE_TEMPLATE_PATH = "dbms_job_scheduler/ppas/#{0}#";

    this()
    {
        super();
        nodeType = DBMSJobSchedulerModule.NODE_TYPE;
        nodeLabel = "DBMS Job Scheduler";
        parentIds = [IdSpec("int", "gid"), IdSpec("int", "sid"), IdSpec("int", "did")];
        ids = [IdSpec("int", "jsid")];
        setAllOps([
            makeOp("obj", ["get": "properties"], ["get": "list"]),
            makeOp("children", ["get": "children"]),
            makeOp("nodes", ["get": "nodes"], ["get": "nodes"]),
        ]);
    }

    private Response schedulerPrecondition(Dict k)
    {
        if (!k.has("sid") || !k.has("did"))
            return preconditionRequired(gettext("Required properties are missing."));
        manager = getDriver().connectionManager(k["sid"].integer);
        if (manager is null)
            return gone(gettext("Could not find the server."));
        conn = manager.connection(null, null, true, k["did"]);
        if (!conn.connected())
            return preconditionRequired(gettext("Connection to the server has been lost."));
        templatePath = "dbms_job_scheduler/ppas/#" ~ to!string(manager.version_) ~ "#";
        return null;
    }

    override Response callMethod(string name, Dict k)
    {
        if (!isAuthenticated())
            return unauthorisedResponse();
        if (name == "children")
            return children(k);

        auto err = schedulerPrecondition(k);
        if (err !is null)
            return err;

        switch (name)
        {
        case "list":
        {
            auto sql = renderTemplate(templatePath ~ "/get_job_run_details.sql", tv("conn", conn));
            auto r = conn.executeDict(sql);
            if (!r.ok)
                return internalServerError(r.error);
            return makeResponse(r.value["rows"], 200);
        }
        case "nodes":
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value.newList(), 200);
        case "properties":
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value.newList(), 200);
        default:
            return super.callMethod(name, k);
        }
    }
}
