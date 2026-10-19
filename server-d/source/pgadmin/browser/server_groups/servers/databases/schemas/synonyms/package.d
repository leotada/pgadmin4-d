/// `schemas/synonyms`: EPAS Synonym node module.
module pgadmin.browser.server_groups.servers.databases.schemas.synonyms;

import std.conv : to;
import std.string : strip;
import pgadmin.browser.server_groups.servers.databases.schemas.utils : SchemaChildModule;
import pgadmin.browser.server_groups.servers.utils : parsePrivFromDb, parsePrivToDb;
import pgadmin.browser.utils;
import pgadmin.core.i18n;
import pgadmin.core.log;
import pgadmin.core.templates : renderTemplate, tv;
import pgadmin.core.value;
import pgadmin.db.driver : Connection, ServerManager, getDriver, Res;
import pgadmin.utils.constants : DATABASE_LAST_SYSTEM_OID;
import pgadmin.web.auth;
import pgadmin.web.context;
import pgadmin.web.http;

final class SynonymModule : SchemaChildModule
{
    enum NODE_TYPE = "synonym";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "Synonyms";
        minVer = Value(90100);
        serverTypes = ["ppas"];
        staticDir("browser/server_groups/servers/databases/schemas/synonyms");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => "database";
    override bool nodeInode() => false;

    override Value[] getNodes(Dict kwargs)
    {
        if (hasNodes(kwargs["sid"], kwargs["did"], kwargs["scid"], Value(null), Value(null), SynonymView.BASE_TEMPLATE_PATH))
            return [generateBrowserCollectionNode(kwargs["scid"])];
        return null;
    }

    override void setup()
    {
        registerNodeView!SynonymView(this);
    }
}

final class SynonymView : PGChildNodeView
{
    enum BASE_TEMPLATE_PATH = "synonyms/sql/#{0}#";

    this()
    {
        super();
        nodeType = SynonymModule.NODE_TYPE;
        nodeLabel = "Synonym";
        parentIds = [IdSpec("int", "gid"), IdSpec("int", "sid"), IdSpec("int", "did"), IdSpec("int", "scid")];
        ids = [IdSpec("string", "syid")];
        setAllOps([
            makeOp("obj", ["get": "properties", "delete": "delete", "put": "update"],
                    ["get": "list", "post": "create", "delete": "delete"]),
            makeOp("delete", ["delete": "delete"], ["delete": "delete"]),
            makeOp("children", ["get": "children"]),
            makeOp("nodes", ["get": "node"], ["get": "nodes"]),
            makeOp("sql", ["get": "sql"]),
            makeOp("msql", ["get": "msql"], ["get": "msql"]),
            makeOp("stats", ["get": "statistics"], ["get": "statistics"]),
            makeOp("dependency", ["get": "dependencies"]),
            makeOp("dependent", ["get": "dependents"]),
            makeOp("get_target_objects", ["get": "get_target_objects"], ["get": "get_target_objects"]),
        ]);
    }

    private string getSql(Dict k, Value data, Value scid, Value syid, out string name)
    {
        string sql;
        if (!syid.isNone && syid.toString.length > 0)
        {
            auto propSql = renderTemplate(templatePath ~ "/" ~ PROPERTIES_SQL,
                    tv("scid", scid, "syid", syid, "conn", conn));
            auto r = conn.executeDict(propSql);
            if (!r.ok || r.value["rows"].length == 0)
                return "";
            auto oldData = r.value["rows"][0];
            name = oldData["name"].toString;
            if (!data.contains("synobjschema"))
                data["synobjschema"] = oldData["synobjschema"];
            if (!data.contains("synobjname"))
                data["synobjname"] = oldData["synobjname"];

            sql = renderTemplate(templatePath ~ "/" ~ UPDATE_SQL,
                    tv("data", data, "o_data", oldData, "conn", conn));
        }
        else
        {
            string[] req = ["name", "targettype", "synobjschema", "synobjname"];
            foreach (arg; req)
                if (!data.contains(arg))
                    return gettext("-- missing definition");

            name = data["name"].toString;
            sql = renderTemplate(templatePath ~ "/" ~ CREATE_SQL,
                    tv("data", data, "conn", conn, "comment", false));
        }
        return strip(sql);
    }

    override Response callMethod(string name, Dict k)
    {
        if (!isAuthenticated())
            return unauthorisedResponse();
        if (name == "children")
            return children(k);

        auto action = name == "delete" ? "delete" : name;
        auto err = standardPrecondition(k, action, BASE_TEMPLATE_PATH);
        if (err !is null)
            return err;

        auto sid = k["sid"];
        auto did = k["did"];
        auto scid = k["scid"];
        auto syid = k.has("syid") ? k["syid"] : Value(null);

        switch (name)
        {
        case "list":
        {
            auto sql = renderTemplate(templatePath ~ "/" ~ PROPERTIES_SQL,
                    tv("scid", scid, "conn", conn));
            auto r = conn.executeDict(sql);
            if (!r.ok)
                return internalServerError(r.error);
            return makeResponse(r.value["rows"], 200);
        }
        case "node":
        {
            auto sql = renderTemplate(templatePath ~ "/" ~ PROPERTIES_SQL,
                    tv("scid", scid, "syid", syid, "conn", conn));
            auto r = conn.execute2darray(sql);
            if (!r.ok)
                return internalServerError(r.error);
            if (r.value["rows"].length == 0)
                return gone(gettext("Could not find the synonym."));
            auto row = r.value["rows"][0];
            return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    gbn(row["oid"], scid, row["name"].toString, "icon-synonym"), 200);
        }
        case "nodes":
        {
            auto sql = renderTemplate(templatePath ~ "/" ~ NODES_SQL,
                    tv("scid", scid, "conn", conn));
            auto r = conn.execute2darray(sql);
            if (!r.ok)
                return internalServerError(r.error);
            Value[] res;
            foreach (row; r.value["rows"].list.items)
                res ~= gbn(row["oid"], scid, row["name"].toString, "icon-synonym");
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        case "properties":
        {
            auto sql = renderTemplate(templatePath ~ "/" ~ PROPERTIES_SQL,
                    tv("scid", scid, "syid", syid, "conn", conn));
            auto r = conn.executeDict(sql);
            if (!r.ok)
                return internalServerError(r.error);
            if (r.value["rows"].length == 0)
                return gone(gettext("Could not find the synonym."));
            auto row = r.value["rows"][0];
            row["is_sys_obj"] = Value(row["oid"].integer <= DATABASE_LAST_SYSTEM_OID);
            return makeResponse(row, 200);
        }
        case "get_target_objects":
        {
            string trgTyp = request().args.has("trgTyp") ? request().args.get("trgTyp") : "";
            string trgSchema = request().args.has("trgSchema") ? request().args.get("trgSchema") : "";
            Value[] res;
            if (trgTyp.length > 0 && trgSchema.length > 0)
            {
                auto sql = renderTemplate(templatePath ~ "/get_objects.sql",
                        tv("trgTyp", trgTyp, "trgSchema", trgSchema, "conn", conn));
                auto r = conn.executeDict(sql);
                if (!r.ok)
                    return internalServerError(r.error);
                foreach (row; r.value["rows"].list.items)
                    res ~= Value(["label": row["name"], "value": row["name"]]);
            }
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
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
            string[] req = ["name", "targettype", "synobjschema", "synobjname"];
            foreach (arg; req)
                if (!data.contains(arg))
                    return gone(gettext("Could not find the required parameter (" ~ arg ~ ")."));

            auto sql = renderTemplate(templatePath ~ "/" ~ CREATE_SQL,
                    tv("data", data, "conn", conn, "comment", false));
            auto cr = conn.executeScalar(sql);
            if (!cr.ok)
                return internalServerError(cr.error);

            auto psql = renderTemplate(templatePath ~ "/get_parent_oid.sql",
                    tv("data", data, "conn", conn));
            auto pr = conn.executeDict(psql);
            if (!pr.ok || pr.value["rows"].length == 0)
                return internalServerError(gettext("Could not fetch parent ID."));

            auto parentId = pr.value["rows"][0]["scid"];
            auto newSyid = pr.value["rows"][0]["syid"];

            return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    Value(["node": gbn(newSyid, parentId, data["name"].toString, "icon-synonym")]), 200);
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
            auto sql = getSql(k, data, scid, syid, outName);
            if (strip(sql).length > 0)
            {
                auto ur = conn.executeScalar(sql);
                if (!ur.ok)
                    return internalServerError(ur.error);
            }
            return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    Value(["node": gbn(syid, scid, outName, "icon-synonym")]), 200);
        }
        case "delete":
        {
            Value[] ids;
            if (!syid.isNone && syid.toString.length > 0)
                ids ~= syid;
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
                        tv("scid", scid, "syid", id, "conn", conn));
                auto r = conn.executeDict(propSql);
                if (!r.ok)
                    return internalServerError(r.error);
                if (r.value["rows"].length == 0)
                    return gone(gettext("Could not find the synonym."));

                auto oldData = r.value["rows"][0];
                auto delSql = renderTemplate(templatePath ~ "/" ~ DELETE_SQL,
                        tv("data", oldData, "conn", conn));
                auto dr = conn.executeScalar(delSql);
                if (!dr.ok)
                    return internalServerError(dr.error);
            }

            return makeJsonResponse(1, Value(""), Value(gettext("Synonym dropped")), Value(null), Value(null), 200);
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
            auto sql = getSql(k, data, scid, syid, outName);
            if (sql.length == 0)
                sql = "--modified SQL";
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(sql), 200);
        }
        case "sql":
        {
            auto propSql = renderTemplate(templatePath ~ "/" ~ PROPERTIES_SQL,
                    tv("scid", scid, "syid", syid, "conn", conn));
            auto r = conn.executeDict(propSql);
            if (!r.ok || r.value["rows"].length == 0)
                return gone(gettext("Could not find the synonym."));
            auto oldData = r.value["rows"][0];

            auto sql = renderTemplate(templatePath ~ "/" ~ CREATE_SQL,
                    tv("data", oldData, "conn", conn, "comment", true));
            return makeResponse(Value(sql), 200);
        }
        case "dependents":
            return makeResponse(getDependents(conn, syid), 200);
        case "dependencies":
            return makeResponse(getDependencies(conn, syid), 200);
        default:
            return super.callMethod(name, k);
        }
    }
}
