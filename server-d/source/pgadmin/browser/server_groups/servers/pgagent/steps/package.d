/// `servers/pgagent/steps`: pgAgent Job Step node.
module pgadmin.browser.server_groups.servers.pgagent.steps;

import std.conv : to;
import std.string : strip;
import pgadmin.browser.common;
import pgadmin.browser.server_groups.servers.pgagent.utils;
import pgadmin.core.templates : renderTemplate, tv;
import pgadmin.core.value;
import pgadmin.db.driver : Connection, ServerManager, getDriver, Res;
import pgadmin.utils.preferences : Preferences;

final class PgaStepModule : CollectionNodeModule
{
    enum NODE_TYPE = "pga_jobstep";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "Steps";
        staticDir("browser/server_groups/servers/pgagent/steps");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => "pga_job";
    override bool moduleUseTemplateJavascript() => false;
    override bool nodeInode() => false;

    override Value[] getNodes(Dict kwargs) => [generateBrowserCollectionNode(kwargs["jid"])];

    override void setup()
    {
        registerNodeView!PgaStepView(this);
    }
}

final class PgaStepView : PGChildNodeView
{
    this()
    {
        super();
        nodeType = PgaStepModule.NODE_TYPE;
        parentIds = [IdSpec("int", "gid"), IdSpec("int", "sid"), IdSpec("int", "jid")];
        ids = [IdSpec("int", "jstid")];
        setAllOps([
            makeOp("obj", ["get": "properties", "put": "update", "delete": "delete"],
                    ["get": "list", "post": "create", "delete": "delete"]),
            makeOp("nodes", ["get": "node"], ["get": "nodes"]),
            makeOp("msql", ["get": "msql"], ["get": "msql"]),
            makeOp("sql", ["get": "sql"]),
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

    private Response stepPrecondition(Dict k)
    {
        if (!k.has("sid"))
            return preconditionRequired(gettext("Required properties are missing."));
        manager = getDriver().connectionManager(k["sid"].integer);
        if (manager is null)
            return gone(gettext("Could not find the server."));
        conn = manager.connection();
        templatePath = "pga_jobstep/sql/pre3.4";
        return null;
    }

    override Response callMethod(string name, Dict k)
    {
        if (!isAuthenticated())
            return unauthorisedResponse();
        auto err = stepPrecondition(k);
        if (err !is null)
            return err;

        auto gid = k.has("gid") ? k["gid"] : Value(null);
        auto sid = k["sid"];
        auto jid = k.has("jid") ? k["jid"] : Value(null);
        auto jstid = k.has("jstid") ? k["jstid"] : Value(null);
        bool hc = hasConnStr();

        switch (name)
        {
        case "list":
        {
            auto sql = renderTemplate(templatePath ~ "/" ~ PROPERTIES_SQL,
                    tv("jid", jid, "has_connstr", Value(hc), "conn", conn));
            auto r = conn.executeDict(sql);
            if (!r.ok)
                return internalServerError(r.error);
            return makeResponse(r.value["rows"], 200);
        }
        case "node", "nodes":
        {
            auto sql = renderTemplate(templatePath ~ "/" ~ NODES_SQL,
                    tv("jstid", jstid, "jid", jid, "conn", conn));
            auto r = conn.execute2darray(sql);
            if (!r.ok)
                return internalServerError(r.error);

            if (!jstid.isNone)
            {
                if (r.value["rows"].length == 0)
                    return gone(gettext("Could not find the specified job step."));
                auto row = r.value["rows"][0];
                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                        gbn(row["jstid"], row["jstjobid"], row["jstname"].toString,
                            row["jstenabled"].truthy ? "icon-pga_jobstep" : "icon-pga_jobstep-disabled"), 200);
            }

            Value[] res;
            foreach (row; r.value["rows"].list.items)
            {
                res ~= gbn(row["jstid"], row["jstjobid"], row["jstname"].toString,
                        row["jstenabled"].truthy ? "icon-pga_jobstep" : "icon-pga_jobstep-disabled");
            }
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        case "properties":
        {
            auto sql = renderTemplate(templatePath ~ "/" ~ PROPERTIES_SQL,
                    tv("jstid", jstid, "jid", jid, "has_connstr", Value(hc), "conn", conn));
            auto r = conn.executeDict(sql);
            if (!r.ok)
                return internalServerError(r.error);
            if (r.value["rows"].length == 0)
                return gone(gettext("Could not find the specified job step."));
            return makeResponse(r.value["rows"][0], 200);
        }
        case "create":
        {
            Value data = Value.newDict();
            if (request().text.length)
                data = parseJson(request().text);

            auto sql = renderTemplate(templatePath ~ "/" ~ CREATE_SQL,
                    tv("jid", jid, "data", data, "has_connstr", Value(hc), "conn", conn));
            auto r = conn.executeScalar(sql);
            if (!r.ok)
                return internalServerError(r.error);

            auto propSql = renderTemplate(templatePath ~ "/" ~ NODES_SQL,
                    tv("jstid", r.value, "jid", jid, "conn", conn));
            auto pRes = conn.execute2darray(propSql);
            if (!pRes.ok)
                return internalServerError(pRes.error);
            if (pRes.value["rows"].length == 0)
                return gone(gettext("Job step creation failed."));

            auto row = pRes.value["rows"][0];
            auto nodeObj = gbn(row["jstid"], row["jstjobid"], row["jstname"].toString,
                    row["jstenabled"].truthy ? "icon-pga_jobstep" : "icon-pga_jobstep-disabled");

            return makeResponse(Value.dictOf("node", nodeObj), 200);
        }
        case "update":
        {
            Value data = Value.newDict();
            if (request().text.length)
                data = parseJson(request().text);

            if (hc && !data.contains("jstconntype") && (data.contains("jstdbname") || data.contains("jstconnstr")))
            {
                auto propSql = renderTemplate(templatePath ~ "/" ~ PROPERTIES_SQL,
                        tv("jstid", jstid, "jid", jid, "has_connstr", Value(hc), "conn", conn));
                auto pRes = conn.executeDict(propSql);
                if (pRes.ok && pRes.value["rows"].length > 0)
                {
                    auto row = pRes.value["rows"][0];
                    data["jstconntype"] = row["jstconntype"];
                    if (row["jstconntype"].truthy)
                        data["jstdbname"] = data.dict.get("jstdbname", row["jstdbname"]);
                    else
                        data["jstconnstr"] = data.dict.get("jstconnstr", row["jstconnstr"]);
                }
            }

            auto sql = renderTemplate(templatePath ~ "/" ~ UPDATE_SQL,
                    tv("jid", jid, "jstid", jstid, "data", data, "has_connstr", Value(hc), "conn", conn));
            auto r = conn.executeVoid(sql);
            if (!r.ok)
                return internalServerError(r.error);

            auto propSql = renderTemplate(templatePath ~ "/" ~ NODES_SQL,
                    tv("jstid", jstid, "jid", jid, "conn", conn));
            auto pRes = conn.execute2darray(propSql);
            if (!pRes.ok)
                return internalServerError(pRes.error);
            if (pRes.value["rows"].length == 0)
                return gone(gettext("Job step update failed."));

            auto row = pRes.value["rows"][0];
            auto nodeObj = gbn(jstid, jid, row["jstname"].toString,
                    row["jstenabled"].truthy ? "icon-pga_jobstep" : "icon-pga_jobstep-disabled");

            return makeResponse(Value.dictOf("node", nodeObj), 200);
        }
        case "delete":
        {
            Value[] ids;
            if (jstid.isNone)
            {
                if (request().text.length)
                {
                    auto parsed = parseJson(request().text);
                    if (parsed.isDict && parsed.contains("ids"))
                        ids = parsed["ids"].list.items;
                }
            }
            else
                ids = [jstid];

            foreach (delId; ids)
            {
                auto sql = renderTemplate(templatePath ~ "/" ~ DELETE_SQL,
                        tv("jid", jid, "jstid", delId, "conn", conn));
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

            string sql;
            if (jstid.isNone)
            {
                sql = renderTemplate(templatePath ~ "/" ~ CREATE_SQL,
                        tv("jid", jid, "data", data, "has_connstr", Value(hc), "conn", conn));
            }
            else
            {
                if (hc && !data.contains("jstconntype") && (data.contains("jstdbname") || data.contains("jstconnstr")))
                {
                    auto propSql = renderTemplate(templatePath ~ "/" ~ PROPERTIES_SQL,
                            tv("jstid", jstid, "jid", jid, "has_connstr", Value(hc), "conn", conn));
                    auto pRes = conn.executeDict(propSql);
                    if (pRes.ok && pRes.value["rows"].length > 0)
                    {
                        auto row = pRes.value["rows"][0];
                        data["jstconntype"] = row["jstconntype"];
                        if (row["jstconntype"].truthy)
                            data["jstdbname"] = data.dict.get("jstdbname", row["jstdbname"]);
                        else
                            data["jstconnstr"] = data.dict.get("jstconnstr", row["jstconnstr"]);
                    }
                }
                sql = renderTemplate(templatePath ~ "/" ~ UPDATE_SQL,
                        tv("jid", jid, "jstid", jstid, "data", data, "has_connstr", Value(hc), "conn", conn));
            }

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
                    tv("jid", jid, "jstid", jstid, "conn", conn, "rows_threshold", Value(threshold)));
            auto r = conn.executeDict(sql);
            if (!r.ok)
                return internalServerError(r.error);
            return makeJsonResponse(1, Value(""), Value(""), Value(null), r.value, 200);
        }
        case "sql":
            return makeResponse(Value(gettext("-- No SQL could be generated for the selected object.")), 200);

        default:
            return super.callMethod(name, k);
        }
    }
}
