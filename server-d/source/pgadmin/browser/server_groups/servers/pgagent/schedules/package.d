/// `servers/pgagent/schedules`: pgAgent Job Schedule node.
module pgadmin.browser.server_groups.servers.pgagent.schedules;

import std.conv : to;
import std.string : strip;
import pgadmin.browser.common;
import pgadmin.browser.server_groups.servers.pgagent.utils;
import pgadmin.core.templates : renderTemplate, tv;
import pgadmin.core.value;
import pgadmin.db.driver : Connection, ServerManager, getDriver, Res;

final class PgaScheduleModule : CollectionNodeModule
{
    enum NODE_TYPE = "pga_schedule";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "Schedules";
        staticDir("browser/server_groups/servers/pgagent/schedules");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => "pga_job";
    override bool moduleUseTemplateJavascript() => false;
    override bool nodeInode() => false;

    override Value[] getNodes(Dict kwargs) => [generateBrowserCollectionNode(kwargs["jid"])];

    override void setup()
    {
        registerNodeView!PgaScheduleView(this);
    }
}

final class PgaScheduleView : PGChildNodeView
{
    this()
    {
        super();
        nodeType = PgaScheduleModule.NODE_TYPE;
        parentIds = [IdSpec("int", "gid"), IdSpec("int", "sid"), IdSpec("int", "jid")];
        ids = [IdSpec("int", "jscid")];
        setAllOps([
            makeOp("obj", ["get": "properties", "put": "update", "delete": "delete"],
                    ["get": "list", "post": "create", "delete": "delete"]),
            makeOp("nodes", ["get": "node"], ["get": "nodes"]),
            makeOp("msql", ["get": "msql"], ["get": "msql"]),
            makeOp("sql", ["get": "sql"]),
        ]);
    }

    private Response schedulePrecondition(Dict k)
    {
        if (!k.has("sid"))
            return preconditionRequired(gettext("Required properties are missing."));
        manager = getDriver().connectionManager(k["sid"].integer);
        if (manager is null)
            return gone(gettext("Could not find the server."));
        conn = manager.connection();
        templatePath = "pga_schedule/sql/pre3.4";
        return null;
    }

    override Response callMethod(string name, Dict k)
    {
        if (!isAuthenticated())
            return unauthorisedResponse();
        auto err = schedulePrecondition(k);
        if (err !is null)
            return err;

        auto gid = k.has("gid") ? k["gid"] : Value(null);
        auto sid = k["sid"];
        auto jid = k.has("jid") ? k["jid"] : Value(null);
        auto jscid = k.has("jscid") ? k["jscid"] : Value(null);

        switch (name)
        {
        case "list":
        {
            auto sql = renderTemplate(templatePath ~ "/" ~ PROPERTIES_SQL, tv("jid", jid, "conn", conn));
            auto r = conn.executeDict(sql);
            if (!r.ok)
                return internalServerError(r.error);
            return makeResponse(r.value["rows"], 200);
        }
        case "node", "nodes":
        {
            auto sql = renderTemplate(templatePath ~ "/" ~ NODES_SQL,
                    tv("jscid", jscid, "jid", jid, "conn", conn));
            auto r = conn.execute2darray(sql);
            if (!r.ok)
                return internalServerError(r.error);

            if (!jscid.isNone)
            {
                if (r.value["rows"].length == 0)
                    return gone(gettext("Could not find the specified job step."));
                auto row = r.value["rows"][0];
                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                        gbn(row["jscid"], row["jscjobid"], row["jscname"].toString,
                            row["jscenabled"].truthy ? "icon-pga_schedule" : "icon-pga_schedule-disabled"), 200);
            }

            Value[] res;
            foreach (row; r.value["rows"].list.items)
            {
                res ~= gbn(row["jscid"], row["jscjobid"], row["jscname"].toString,
                        row["jscenabled"].truthy ? "icon-pga_schedule" : "icon-pga_schedule-disabled");
            }
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        case "properties":
        {
            auto sql = renderTemplate(templatePath ~ "/" ~ PROPERTIES_SQL,
                    tv("jscid", jscid, "jid", jid, "conn", conn));
            auto r = conn.executeDict(sql);
            if (!r.ok)
                return internalServerError(r.error);
            if (r.value["rows"].length == 0)
                return gone(gettext("Could not find the specified job step."));

            auto row = r.value["rows"][0];
            if (row.contains("jexid") && !row["jexid"].isNone && row["jexid"].length > 0)
            {
                Value[] exList;
                auto exids = row["jexid"].list.items;
                auto dates = row["jexdate"].list.items;
                auto times = row["jextime"].list.items;
                foreach (i; 0 .. exids.length)
                {
                    exList ~= Value.dictOf(
                        "jexid", exids[i],
                        "jexdate", i < dates.length ? dates[i] : Value(null),
                        "jextime", i < times.length ? times[i] : Value(null)
                    );
                }
                row["jscexceptions"] = Value(exList);
            }
            return makeResponse(row, 200);
        }
        case "create":
        {
            Value data = Value.newDict();
            if (request().text.length)
                data = parseJson(request().text);
            data = formatScheduleData(data);

            auto sql = renderTemplate(templatePath ~ "/" ~ CREATE_SQL,
                    tv("jid", jid, "data", data, "fetch_id", Value(true), "conn", conn));

            conn.executeVoid("BEGIN");
            auto r = conn.executeScalar(sql);
            if (!r.ok)
            {
                if (conn.connected())
                    conn.executeVoid("END");
                return internalServerError(r.error);
            }
            conn.executeVoid("END");

            auto propSql = renderTemplate(templatePath ~ "/" ~ PROPERTIES_SQL,
                    tv("jscid", r.value, "jid", jid, "conn", conn));
            auto pRes = conn.execute2darray(propSql);
            if (!pRes.ok)
                return internalServerError(pRes.error);
            if (pRes.value["rows"].length == 0)
                return gone(gettext("Job schedule creation failed."));

            auto row = pRes.value["rows"][0];
            auto nodeObj = gbn(row["jscid"], row["jscjobid"], row["jscname"].toString,
                    row["jscenabled"].truthy ? "icon-pga_schedule" : "icon-pga_schedule-disabled");

            return makeResponse(Value.dictOf("node", nodeObj), 200);
        }
        case "update":
        {
            Value data = Value.newDict();
            if (request().text.length)
                data = parseJson(request().text);
            data = formatScheduleData(data);

            auto sql = renderTemplate(templatePath ~ "/" ~ UPDATE_SQL,
                    tv("jid", jid, "jscid", jscid, "data", data, "conn", conn));
            auto r = conn.executeVoid(sql);
            if (!r.ok)
                return internalServerError(r.error);

            auto propSql = renderTemplate(templatePath ~ "/" ~ PROPERTIES_SQL,
                    tv("jscid", jscid, "jid", jid, "conn", conn));
            auto pRes = conn.execute2darray(propSql);
            if (!pRes.ok)
                return internalServerError(pRes.error);
            if (pRes.value["rows"].length == 0)
                return gone(gettext("Job schedule update failed."));

            auto row = pRes.value["rows"][0];
            auto nodeObj = gbn(jscid, jid, row["jscname"].toString,
                    row["jscenabled"].truthy ? "icon-pga_schedule" : "icon-pga_schedule-disabled");

            return makeResponse(Value.dictOf("node", nodeObj), 200);
        }
        case "delete":
        {
            Value[] ids;
            if (jscid.isNone)
            {
                if (request().text.length)
                {
                    auto parsed = parseJson(request().text);
                    if (parsed.isDict && parsed.contains("ids"))
                        ids = parsed["ids"].list.items;
                }
            }
            else
                ids = [jscid];

            foreach (delId; ids)
            {
                auto sql = renderTemplate(templatePath ~ "/" ~ DELETE_SQL,
                        tv("jid", jid, "jscid", delId, "conn", conn));
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
            data = formatScheduleData(data);

            string sql;
            if (jscid.isNone)
                sql = renderTemplate(templatePath ~ "/" ~ CREATE_SQL,
                        tv("jid", jid, "data", data, "fetch_id", Value(false), "conn", conn));
            else
                sql = renderTemplate(templatePath ~ "/" ~ UPDATE_SQL,
                        tv("jid", jid, "jscid", jscid, "data", data, "conn", conn));

            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(sql), 200);
        }
        case "sql":
            return makeResponse(Value(gettext("-- No SQL could be generated for the selected object.")), 200);

        default:
            return super.callMethod(name, k);
        }
    }
}
