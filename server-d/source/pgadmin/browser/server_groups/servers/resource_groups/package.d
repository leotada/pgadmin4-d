/// `servers/resource_groups`: EPAS Resource Group node module.
module pgadmin.browser.server_groups.servers.resource_groups;

import std.conv : to;
import std.string : strip;
import pgadmin.browser.common;
import pgadmin.core.templates : renderTemplate, tv;
import pgadmin.core.value;
import pgadmin.db.driver : Connection, ServerManager, getDriver, Res;

final class ResourceGroupModule : CollectionNodeModule
{
    enum NODE_TYPE = "resource_group";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "Resource Groups";
        minVer = Value(90400);
        serverTypes = ["ppas"];
        staticDir("browser/server_groups/servers/resource_groups");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => "server";
    override bool moduleUseTemplateJavascript() => false;
    override bool nodeInode() => false;

    override Value[] getNodes(Dict kwargs) => [generateBrowserCollectionNode(kwargs["sid"])];

    override void setup()
    {
        registerNodeView!ResourceGroupView(this);
    }
}

final class ResourceGroupView : PGChildNodeView
{
    this()
    {
        super();
        nodeType = ResourceGroupModule.NODE_TYPE;
        parentIds = [IdSpec("int", "gid"), IdSpec("int", "sid")];
        ids = [IdSpec("int", "rg_id")];
        setAllOps([
            makeOp("obj", ["get": "properties", "delete": "delete", "put": "update"],
                    ["get": "list", "post": "create", "delete": "delete"]),
            makeOp("nodes", ["get": "node"], ["get": "nodes"]),
            makeOp("children", ["get": "children"]),
            makeOp("sql", ["get": "sql"]),
            makeOp("msql", ["get": "msql"], ["get": "msql"]),
        ]);
    }

    private Response rgPrecondition(Dict k)
    {
        if (!k.has("sid"))
            return preconditionRequired(gettext("Required properties are missing."));
        manager = getDriver().connectionManager(k["sid"].integer);
        if (manager is null)
            return gone(gettext("Could not find the server."));
        conn = manager.connection();
        if (!conn.connected())
            return preconditionRequired(gettext("Connection to the server has been lost."));
        templatePath = "resource_groups/sql/#" ~ to!string(manager.version_) ~ "#";
        return null;
    }

    private string getSql(Dict k, Value data, Value rgId)
    {
        string sql;
        if (!rgId.isNone)
        {
            auto propSql = renderTemplate(templatePath ~ "/" ~ PROPERTIES_SQL, tv("rgid", rgId, "conn", conn));
            auto r = conn.executeDict(propSql);
            if (!r.ok || r.value["rows"].length == 0)
                return "";
            auto oldData = r.value["rows"][0];
            if (!data.contains("name"))
                data["name"] = oldData["name"];
            if (!data.contains("cpu_rate_limit"))
                data["cpu_rate_limit"] = oldData["cpu_rate_limit"];
            if (!data.contains("dirty_rate_limit"))
                data["dirty_rate_limit"] = oldData["dirty_rate_limit"];

            bool nameChanged = false;
            if (data["name"] != oldData["name"])
            {
                nameChanged = true;
                sql = renderTemplate(templatePath ~ "/" ~ UPDATE_SQL,
                        tv("oldname", oldData["name"], "newname", data["name"], "conn", conn));
            }

            if (data["cpu_rate_limit"] != oldData["cpu_rate_limit"] ||
                data["dirty_rate_limit"] != oldData["dirty_rate_limit"])
            {
                if (nameChanged)
                    sql ~= "\n-- Following query will be executed in a separate transaction\n";
                sql ~= renderTemplate(templatePath ~ "/" ~ UPDATE_SQL,
                        tv("data", data, "conn", conn));
            }
        }
        else
        {
            sql = renderTemplate(templatePath ~ "/" ~ CREATE_SQL,
                    tv("rgname", data.get("name"), "conn", conn));
            bool cpuLimitFlag = data.contains("cpu_rate_limit") && data["cpu_rate_limit"].integer >= 0;
            bool dirtyLimitFlag = data.contains("dirty_rate_limit") && data["dirty_rate_limit"].integer >= 0;
            if (cpuLimitFlag || dirtyLimitFlag)
            {
                sql ~= "\n-- Following query will be executed in a separate transaction\n";
                sql ~= renderTemplate(templatePath ~ "/" ~ UPDATE_SQL,
                        tv("data", data, "conn", conn));
            }
        }
        return strip(sql);
    }

    override Response callMethod(string name, Dict k)
    {
        if (!isAuthenticated())
            return unauthorisedResponse();
        if (name == "children")
            return children(k);

        auto err = rgPrecondition(k);
        if (err !is null)
            return err;

        auto sid = k["sid"];
        auto rgId = k.has("rg_id") ? k["rg_id"] : Value(null);

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
        case "node":
        {
            auto sql = renderTemplate(templatePath ~ "/" ~ NODES_SQL, tv("rgid", rgId, "conn", conn));
            auto r = conn.execute2darray(sql);
            if (!r.ok)
                return internalServerError(r.error);
            if (r.value["rows"].length == 0)
                return gone(gettext("Could not find the resource group."));
            auto row = r.value["rows"][0];
            return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    gbn(row["oid"], sid, row["name"].toString, "icon-resource_group"), 200);
        }
        case "nodes":
        {
            auto sql = renderTemplate(templatePath ~ "/" ~ NODES_SQL, tv("conn", conn));
            auto r = conn.execute2darray(sql);
            if (!r.ok)
                return internalServerError(r.error);
            Value[] res;
            foreach (row; r.value["rows"].list.items)
                res ~= gbn(row["oid"], sid, row["name"].toString, "icon-resource_group");
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        case "properties":
        {
            auto sql = renderTemplate(templatePath ~ "/" ~ PROPERTIES_SQL, tv("rgid", rgId, "conn", conn));
            auto r = conn.executeDict(sql);
            if (!r.ok)
                return internalServerError(r.error);
            if (r.value["rows"].length == 0)
                return gone(gettext("Could not find the resource group."));
            auto row = r.value["rows"][0];
            row["is_sys_obj"] = Value(row["oid"].integer <= DATABASE_LAST_SYSTEM_OID);
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
            if (!data.contains("name"))
                return gone(gettext("Could not find the required parameter (name)."));

            auto sql = renderTemplate(templatePath ~ "/" ~ CREATE_SQL,
                    tv("rgname", data["name"], "conn", conn));
            if (strip(sql).length > 0)
            {
                auto cr = conn.executeScalar(sql);
                if (!cr.ok)
                    return internalServerError(cr.error);
            }

            auto upSql = renderTemplate(templatePath ~ "/" ~ UPDATE_SQL,
                    tv("data", data, "conn", conn));
            if (strip(upSql).length > 0)
            {
                auto ur = conn.executeScalar(upSql);
                if (!ur.ok)
                    return internalServerError(ur.error);
            }

            auto oidSql = renderTemplate(templatePath ~ "/getoid.sql",
                    tv("rgname", data["name"], "conn", conn));
            Value newOid = Value(0);
            if (strip(oidSql).length > 0)
            {
                auto or = conn.executeScalar(oidSql);
                if (!or.ok)
                    return internalServerError(or.error);
                newOid = or.value;
            }

            return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    Value(["node": gbn(newOid, sid, data["name"].toString, "icon-resource_group")]), 200);
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

            auto propSql = renderTemplate(templatePath ~ "/" ~ PROPERTIES_SQL, tv("rgid", rgId, "conn", conn));
            auto r = conn.executeDict(propSql);
            if (!r.ok || r.value["rows"].length == 0)
                return gone(gettext("Could not find the resource group."));
            auto oldData = r.value["rows"][0];

            if (!data.contains("name"))
                data["name"] = oldData["name"];
            if (!data.contains("cpu_rate_limit"))
                data["cpu_rate_limit"] = oldData["cpu_rate_limit"];
            if (!data.contains("dirty_rate_limit"))
                data["dirty_rate_limit"] = oldData["dirty_rate_limit"];

            if (data["name"] != oldData["name"])
            {
                auto sql = renderTemplate(templatePath ~ "/" ~ UPDATE_SQL,
                        tv("oldname", oldData["name"], "newname", data["name"], "conn", conn));
                if (strip(sql).length > 0)
                {
                    auto ur = conn.executeScalar(sql);
                    if (!ur.ok)
                        return internalServerError(ur.error);
                }
            }

            if (data["cpu_rate_limit"] != oldData["cpu_rate_limit"] ||
                data["dirty_rate_limit"] != oldData["dirty_rate_limit"])
            {
                auto sql = renderTemplate(templatePath ~ "/" ~ UPDATE_SQL,
                        tv("data", data, "conn", conn));
                if (strip(sql).length > 0)
                {
                    auto ur = conn.executeScalar(sql);
                    if (!ur.ok)
                        return internalServerError(ur.error);
                }
            }

            return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    Value(["node": gbn(rgId, sid, data["name"].toString, "icon-resource_group")]), 200);
        }
        case "delete":
        {
            Value[] ids;
            if (!rgId.isNone)
                ids ~= rgId;
            else if (request().text.length)
            {
                try
                {
                    auto body = parseJson(request().text);
                    if (body.contains("ids") && body["ids"].isList)
                    {
                        foreach (id; body["ids"].list.items)
                            ids ~= id;
                    }
                }
                catch (Exception e)
                    return badRequest(e.msg);
            }

            foreach (id; ids)
            {
                auto getSql = renderTemplate(templatePath ~ "/" ~ DELETE_SQL, tv("rgid", id, "conn", conn));
                auto r = conn.executeScalar(getSql);
                if (!r.ok)
                    return internalServerError(r.error);
                if (r.value.isNone || r.value.toString.length == 0)
                    return makeJsonResponse(0, Value(gettext("Error: Object not found.")),
                            Value(gettext("The specified resource group could not be found.\n")), Value(null), Value(null), 404);

                auto delSql = renderTemplate(templatePath ~ "/" ~ DELETE_SQL, tv("rgname", r.value, "conn", conn));
                auto dr = conn.executeScalar(delSql);
                if (!dr.ok)
                    return internalServerError(dr.error);
            }

            return makeJsonResponse(1, Value(""), Value(gettext("Resource Group dropped")), Value(null), Value(null), 200);
        }
        case "msql":
        {
            Value data = Value.newDict();
            foreach (kArg; request().args.keys)
            {
                auto raw = request().args.get(kArg);
                try { data[kArg] = parseJson(raw); } catch (Exception) { data[kArg] = Value(raw); }
            }
            auto sql = getSql(k, data, rgId);
            if (sql.length == 0)
                sql = "--modified SQL";
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(sql), 200);
        }
        case "sql":
        {
            auto propSql = renderTemplate(templatePath ~ "/" ~ PROPERTIES_SQL, tv("rgid", rgId, "conn", conn));
            auto r = conn.executeDict(propSql);
            if (!r.ok || r.value["rows"].length == 0)
                return gone(gettext("The specified resource group could not be found."));
            auto oldData = r.value["rows"][0];

            auto sql = renderTemplate(templatePath ~ "/" ~ CREATE_SQL,
                    tv("display_comments", true, "rgname", oldData["name"], "conn", conn));
            sql ~= "\n" ~ renderTemplate(templatePath ~ "/" ~ UPDATE_SQL,
                    tv("data", oldData, "conn", conn));

            return makeResponse(Value(sql), 200);
        }
        default:
            return super.callMethod(name, k);
        }
    }
}
