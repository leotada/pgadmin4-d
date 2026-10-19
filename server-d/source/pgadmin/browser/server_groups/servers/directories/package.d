/// `servers/directories`: EPAS Directory node module.
module pgadmin.browser.server_groups.servers.directories;

import std.conv : to;
import std.regex : regex, replaceAll;
import std.string : strip, startsWith;
import pgadmin.browser.common;
import pgadmin.browser.server_groups.servers.utils : parsePrivFromDb, parsePrivToDb;
import pgadmin.core.templates : renderTemplate, tv;
import pgadmin.core.value;
import pgadmin.db.driver : Connection, ServerManager, getDriver, Res;

final class DirectoryModule : CollectionNodeModule
{
    enum NODE_TYPE = "directory";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "Directories";
        minVer = Value(130000);
        serverTypes = ["ppas"];
        staticDir("browser/server_groups/servers/directories");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => "server";
    override bool moduleUseTemplateJavascript() => false;
    override bool nodeInode() => false;

    override Value[] getNodes(Dict kwargs) => [generateBrowserCollectionNode(kwargs["sid"])];

    override void setup()
    {
        registerNodeView!DirectoryView(this);
    }
}

final class DirectoryView : PGChildNodeView
{
    this()
    {
        super();
        nodeType = DirectoryModule.NODE_TYPE;
        parentIds = [IdSpec("int", "gid"), IdSpec("int", "sid")];
        ids = [IdSpec("int", "dr_id")];
        setAllOps([
            makeOp("obj", ["get": "properties", "delete": "delete", "put": "update"],
                    ["get": "list", "post": "create", "delete": "delete"]),
            makeOp("nodes", ["get": "node"], ["get": "nodes"]),
            makeOp("children", ["get": "children"]),
            makeOp("sql", ["get": "sql"]),
            makeOp("msql", ["get": "msql"], ["get": "msql"]),
        ]);
    }

    private string[] acl = ["W", "R"];

    private Response dirPrecondition(Dict k)
    {
        if (!k.has("sid"))
            return preconditionRequired(gettext("Required properties are missing."));
        manager = getDriver().connectionManager(k["sid"].integer);
        if (manager is null)
            return gone(gettext("Could not find the server."));
        conn = manager.connection();
        if (!conn.connected())
            return preconditionRequired(gettext("Connection to the server has been lost."));
        templatePath = "directories/sql/#" ~ to!string(manager.version_) ~ "#";
        return null;
    }

    private Value formatter(Value data, Value drId)
    {
        auto sql = renderTemplate(templatePath ~ "/acl.sql", tv("dr_id", drId, "conn", conn));
        auto r = conn.executeDict(sql);
        if (r.ok && r.value["rows"].length > 0)
        {
            Value[] privs;
            foreach (row; r.value["rows"].list.items)
                privs ~= parsePrivFromDb(row);
            data["diracl"] = Value(privs);
        }
        else
            data["diracl"] = Value.newList();
        return data;
    }

    private void formatPrivilegeData(Value data)
    {
        if (!data.isDict || !data.contains("diracl") || data["diracl"].isNone)
            return;
        auto aclDict = data["diracl"];
        if (aclDict.isDict)
        {
            if (aclDict.contains("added") && aclDict["added"].isList)
                aclDict["added"] = parsePrivToDb(aclDict["added"], acl);
            if (aclDict.contains("changed") && aclDict["changed"].isList)
                aclDict["changed"] = parsePrivToDb(aclDict["changed"], acl);
            if (aclDict.contains("deleted") && aclDict["deleted"].isList)
                aclDict["deleted"] = parsePrivToDb(aclDict["deleted"], acl);
        }
    }

    private string getSql(Dict k, Value data, Value drId, out string name)
    {
        string sql;
        if (!drId.isNone)
        {
            auto propSql = renderTemplate(templatePath ~ "/" ~ PROPERTIES_SQL, tv("dr_id", drId, "conn", conn));
            auto r = conn.executeDict(propSql);
            if (!r.ok || r.value["rows"].length == 0)
                return "";
            auto oldData = r.value["rows"][0];
            oldData = formatter(oldData, drId);
            formatPrivilegeData(data);

            if (!data.contains("name"))
                data["name"] = oldData["name"];

            sql = renderTemplate(templatePath ~ "/" ~ UPDATE_SQL,
                    tv("data", data, "o_data", oldData, "conn", conn));
            name = data.contains("name") ? data["name"].toString : oldData["name"].toString;
        }
        else
        {
            if (data.contains("diracl"))
                data["diracl"] = parsePrivToDb(data["diracl"], acl);

            sql = renderTemplate(templatePath ~ "/" ~ CREATE_SQL, tv("data", data, "conn", conn));
            sql ~= "\n" ~ renderTemplate(templatePath ~ "/alter.sql", tv("data", data, "conn", conn));
            name = data.contains("name") ? data["name"].toString : "";
        }
        sql = replaceAll(sql, regex("\n{2,}"), "\n\n");
        return sql;
    }

    override Response callMethod(string name, Dict k)
    {
        if (!isAuthenticated())
            return unauthorisedResponse();
        if (name == "children")
            return children(k);

        auto err = dirPrecondition(k);
        if (err !is null)
            return err;

        auto gid = k.has("gid") ? k["gid"] : Value(null);
        auto sid = k["sid"];
        auto drId = k.has("dr_id") ? k["dr_id"] : Value(null);

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
            auto sql = renderTemplate(templatePath ~ "/" ~ NODES_SQL, tv("dr_id", drId, "conn", conn));
            auto r = conn.execute2darray(sql);
            if (!r.ok)
                return internalServerError(r.error);
            if (r.value["rows"].length == 0)
                return gone(gettext("Could not find the directory."));
            auto row = r.value["rows"][0];
            return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    gbn(row["oid"], sid, row["name"].toString, "icon-directory"), 200);
        }
        case "nodes":
        {
            auto sql = renderTemplate(templatePath ~ "/" ~ NODES_SQL, tv("dr_id", drId, "conn", conn));
            auto r = conn.execute2darray(sql);
            if (!r.ok)
                return internalServerError(r.error);
            Value[] res;
            foreach (row; r.value["rows"].list.items)
                res ~= gbn(row["oid"], sid, row["name"].toString, "icon-directory");
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        case "properties":
        {
            auto sql = renderTemplate(templatePath ~ "/" ~ PROPERTIES_SQL, tv("dr_id", drId, "conn", conn));
            auto r = conn.executeDict(sql);
            if (!r.ok)
                return internalServerError(r.error);
            if (r.value["rows"].length == 0)
                return gone(gettext("Could not find the directory information."));
            auto row = formatter(r.value["rows"][0], drId);
            return makeResponse(row, 200);
        }
        case "create":
        {
            Value data = Value.newDict();
            if (request().text.length)
                data = parseJson(request().text);

            if (!data.contains("name") || !data.contains("path"))
                return makeJsonResponse(0, Value(gettext("Could not find the required parameter (name/path).")),
                        Value(""), Value(null), Value(null), 410);

            if (data.contains("diracl"))
                data["diracl"] = parsePrivToDb(data["diracl"], acl);

            auto sql = renderTemplate(templatePath ~ "/" ~ CREATE_SQL, tv("data", data, "conn", conn));
            auto r = conn.executeScalar(sql);
            if (!r.ok)
                return internalServerError(r.error);

            auto alterSql = renderTemplate(templatePath ~ "/alter.sql", tv("directory", data["name"], "conn", conn));
            auto idRes = conn.executeScalar(alterSql);
            if (!idRes.ok)
                return internalServerError(idRes.error);

            auto alter2Sql = renderTemplate(templatePath ~ "/alter.sql", tv("data", data, "conn", conn));
            conn.executeScalar(alter2Sql);

            auto nodeObj = gbn(idRes.value, sid, data["name"].toString, "icon-directory");
            return makeResponse(Value.dictOf("node", nodeObj), 200);
        }
        case "update":
        {
            Value data = Value.newDict();
            if (request().text.length)
                data = parseJson(request().text);

            string updatedName;
            auto sql = getSql(k, data, drId, updatedName);
            if (sql.length == 0)
                return internalServerError(gettext("Failed to generate update SQL."));

            auto r = conn.executeScalar(sql.strip());
            if (!r.ok)
                return internalServerError(r.error);

            auto nodeObj = gbn(drId, sid, updatedName, "icon-directory");
            return makeResponse(Value.dictOf("node", nodeObj), 200);
        }
        case "delete":
        {
            Value[] ids;
            if (drId.isNone)
            {
                if (request().text.length)
                {
                    auto parsed = parseJson(request().text);
                    if (parsed.isDict && parsed.contains("ids"))
                        ids = parsed["ids"].list.items;
                }
            }
            else
                ids = [drId];

            foreach (delId; ids)
            {
                auto nodeSql = renderTemplate(templatePath ~ "/" ~ NODES_SQL, tv("dr_id", delId, "conn", conn));
                auto nRes = conn.executeDict(nodeSql);
                if (!nRes.ok || nRes.value["rows"].length == 0)
                    continue;

                auto drName = nRes.value["rows"][0]["name"];
                auto delSql = renderTemplate(templatePath ~ "/" ~ DELETE_SQL, tv("dr_name", drName, "conn", conn));
                auto r = conn.executeScalar(delSql);
                if (!r.ok)
                    return internalServerError(r.error);
            }
            return makeJsonResponse(1, Value(gettext("Directory dropped")));
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
            auto sql = getSql(k, data, drId, outName);
            sql = sql.strip();
            if (sql.length == 0)
                sql = "--modified SQL";
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(sql), 200);
        }
        case "sql":
        {
            auto propSql = renderTemplate(templatePath ~ "/" ~ PROPERTIES_SQL, tv("dr_id", drId, "conn", conn));
            auto pRes = conn.executeDict(propSql);
            if (!pRes.ok || pRes.value["rows"].length == 0)
                return gone(gettext("Could not find the directory on the server."));

            auto oldData = formatter(pRes.value["rows"][0], drId);
            if (oldData.contains("diracl"))
                oldData["diracl"] = parsePrivToDb(oldData["diracl"], acl);

            string sql = "";
            if (!oldData["name"].toString.startsWith("pg_"))
            {
                sql = renderTemplate(templatePath ~ "/" ~ CREATE_SQL, tv("data", oldData, "conn", conn));
                sql ~= "\n";
            }
            sql ~= renderTemplate(templatePath ~ "/alter.sql", tv("data", oldData, "conn", conn));
            auto sqlHeader = "-- Directory: " ~ oldData["name"].toString ~ "\n\n-- DROP DIRECTORY IF EXISTS " ~ oldData["name"].toString ~ ";\n\n";
            sql = replaceAll(sqlHeader ~ sql, regex("\n{2,}"), "\n\n");
            return makeResponse(Value(sql.strip()), 200);
        }
        default:
            return super.callMethod(name, k);
        }
    }
}
