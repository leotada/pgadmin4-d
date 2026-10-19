/// `schemas/packages`: EPAS Package node module.
module pgadmin.browser.server_groups.servers.databases.schemas.packages;

import std.conv : to;
import std.regex : regex, matchFirst, matchAll;
import std.string : strip, toLower, indexOf, lastIndexOf;
import pgadmin.browser.server_groups.servers.databases.schemas.utils : SchemaChildModule;
import pgadmin.browser.server_groups.servers.databases.schemas.packages.edbvars : EdbVarModule;
import pgadmin.browser.server_groups.servers.databases.schemas.packages.edbfuncs : EdbFuncModule, EdbProcModule;
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

final class PackageModule : SchemaChildModule
{
    enum NODE_TYPE = "package";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "Packages";
        minVer = Value(90100);
        serverTypes = ["ppas"];
        staticDir("browser/server_groups/servers/databases/schemas/packages");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => "database";
    override bool nodeInode() => true;

    override Value[] getNodes(Dict kwargs)
    {
        if (hasNodes(kwargs["sid"], kwargs["did"], kwargs["scid"], Value(null), Value(null), PackageView.BASE_TEMPLATE_PATH))
            return [generateBrowserCollectionNode(kwargs["scid"])];
        return null;
    }

    override void setup()
    {
        submodules ~= new EdbFuncModule;
        submodules ~= new EdbProcModule;
        submodules ~= new EdbVarModule;
        registerNodeView!PackageView(this);
    }
}

final class PackageView : PGChildNodeView
{
    enum BASE_TEMPLATE_PATH = "packages/ppas/#{0}#";
    private string[] acl = ["X"];

    this()
    {
        super();
        nodeType = PackageModule.NODE_TYPE;
        nodeLabel = "Package";
        parentIds = [IdSpec("int", "gid"), IdSpec("int", "sid"), IdSpec("int", "did"), IdSpec("int", "scid")];
        ids = [IdSpec("int", "pkgid")];
        setAllOps([
            makeOp("obj", ["get": "properties", "delete": "delete", "put": "update"],
                    ["get": "list", "post": "create", "delete": "delete"]),
            makeOp("delete", ["delete": "delete"], ["delete": "delete"]),
            makeOp("children", ["get": "children"]),
            makeOp("nodes", ["get": "nodes"], ["get": "nodes"]),
            makeOp("sql", ["get": "sql"]),
            makeOp("msql", ["get": "msql"], ["get": "msql"]),
            makeOp("stats", ["get": "statistics"], ["get": "statistics"]),
            makeOp("dependency", ["get": "dependencies"]),
            makeOp("dependent", ["get": "dependents"]),
        ]);
    }

    private static string getInner(string sql)
    {
        if (sql.length == 0)
            return "";
        auto m = matchFirst(sql, regex(`\s+(is|as)+\s+`, "i"));
        size_t start = 0;
        if (!m.empty)
            start = m.pre.length + m.hit.length;

        auto lower = sql.toLower();
        auto endIdx = lower.lastIndexOf("end");
        if (endIdx != -1 && endIdx > start)
            return sql[start .. endIdx].strip();
        return sql[start .. $].strip();
    }

    private void formatPrivilegeData(Value data)
    {
        if (!data.isDict || !data.contains("pkgacl") || data["pkgacl"].isNone)
            return;
        auto aclDict = data["pkgacl"];
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

    private string getSchemaName(Value sid, Value did, Value scid)
    {
        import pgadmin.browser.server_groups.servers.databases.schemas.utils : getSchema;
        auto r = getSchema(sid, did, scid);
        return r.ok ? r.value.toString : "";
    }

    private string getSql(Dict k, Value data, Value scid, Value pkgid, string schemaName, out string name)
    {
        data["schema"] = Value(schemaName);
        if (!pkgid.isNone)
        {
            auto propSql = renderTemplate(templatePath ~ "/" ~ PROPERTIES_SQL,
                    tv("scid", scid, "pkgid", pkgid, "conn", conn));
            auto r = conn.executeDict(propSql);
            if (!r.ok || r.value["rows"].length == 0)
                return "";
            auto oldData = r.value["rows"][0];
            oldData["pkgheadsrc"] = Value(getInner(oldData.get("pkgheadsrc").toString));
            oldData["pkgbodysrc"] = Value(getInner(oldData.get("pkgbodysrc").toString));

            auto aclSql = renderTemplate(templatePath ~ "/" ~ ACL_SQL,
                    tv("scid", scid, "pkgid", pkgid, "conn", conn));
            auto ar = conn.executeDict(aclSql);
            if (ar.ok)
            {
                foreach (row; ar.value["rows"].list.items)
                {
                    auto deftype = row["deftype"].toString;
                    if (!oldData.contains(deftype))
                        oldData[deftype] = Value.newList();
                    oldData[deftype].list.items ~= parsePrivFromDb(row);
                }
            }

            formatPrivilegeData(data);
            if (!data.contains("name"))
                data["name"] = oldData["name"];
            name = data["name"].toString;

            auto sql = renderTemplate(templatePath ~ "/" ~ UPDATE_SQL,
                    tv("data", data, "o_data", oldData, "conn", conn));
            return strip(sql);
        }
        else
        {
            if (data.contains("pkgacl"))
                data["pkgacl"] = parsePrivToDb(data["pkgacl"], acl);
            name = data.get("name").toString;
            auto sql = renderTemplate(templatePath ~ "/" ~ CREATE_SQL,
                    tv("data", data, "conn", conn));
            return strip(sql);
        }
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
        auto pkgid = k.has("pkgid") ? k["pkgid"] : Value(null);
        auto schemaName = getSchemaName(sid, did, scid);

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
                    tv("scid", scid, "pkgid", pkgid, "conn", conn));
            auto r = conn.executeDict(sql);
            if (!r.ok)
                return internalServerError(r.error);
            if (r.value["rows"].length == 0)
                return gone(gettext("Could not find the package."));
            auto row = r.value["rows"][0];
            return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    gbn(row["oid"], scid, row["name"].toString, "icon-package"), 200);
        }
        case "nodes":
        {
            auto sql = renderTemplate(templatePath ~ "/" ~ NODES_SQL,
                    tv("scid", scid, "pkgid", pkgid, "conn", conn));
            auto r = conn.executeDict(sql);
            if (!r.ok)
                return internalServerError(r.error);

            if (!pkgid.isNone)
            {
                if (r.value["rows"].length == 0)
                    return gone(gettext("Could not find the package."));
                auto row = r.value["rows"][0];
                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                        gbn(row["oid"], scid, row["name"].toString, "icon-package"), 200);
            }

            Value[] res;
            foreach (row; r.value["rows"].list.items)
                res ~= gbn(row["oid"], scid, row["name"].toString, "icon-package");
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        case "properties":
        {
            auto sql = renderTemplate(templatePath ~ "/" ~ PROPERTIES_SQL,
                    tv("scid", scid, "pkgid", pkgid, "conn", conn));
            auto r = conn.executeDict(sql);
            if (!r.ok)
                return internalServerError(r.error);
            if (r.value["rows"].length == 0)
                return gone(gettext("Could not find the package."));
            auto row = r.value["rows"][0];
            row["pkgheadsrc"] = Value(getInner(row.get("pkgheadsrc").toString));
            row["pkgbodysrc"] = Value(getInner(row.get("pkgbodysrc").toString));
            row["schema"] = Value(schemaName);
            row["is_sys_obj"] = Value(row["oid"].integer <= DATABASE_LAST_SYSTEM_OID);

            auto aclSql = renderTemplate(templatePath ~ "/" ~ ACL_SQL,
                    tv("scid", scid, "pkgid", pkgid, "conn", conn));
            auto ar = conn.executeDict(aclSql);
            if (ar.ok)
            {
                foreach (arow; ar.value["rows"].list.items)
                {
                    auto deftype = arow["deftype"].toString;
                    if (!row.contains(deftype))
                        row[deftype] = Value.newList();
                    row[deftype].list.items ~= parsePrivFromDb(arow);
                }
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
            if (!data.contains("name") || !data.contains("pkgheadsrc"))
                return badRequest(gettext("Could not find the required parameter (name, pkgheadsrc)."));

            string outName;
            auto sql = getSql(k, data, scid, Value(null), schemaName, outName);
            auto cr = conn.executeScalar(sql);
            if (!cr.ok)
                return internalServerError(cr.error);

            auto oidSql = renderTemplate(templatePath ~ "/" ~ OID_SQL,
                    tv("name", data["name"], "scid", scid, "conn", conn));
            Value newOid = Value(0);
            if (strip(oidSql).length > 0)
            {
                auto or = conn.executeScalar(oidSql);
                if (or.ok)
                    newOid = or.value;
            }

            return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    Value(["node": gbn(newOid, scid, data["name"].toString, "icon-package")]), 200);
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
            auto sql = getSql(k, data, scid, pkgid, schemaName, outName);
            if (strip(sql).length > 0)
            {
                auto ur = conn.executeScalar(sql);
                if (!ur.ok)
                    return internalServerError(ur.error);
            }
            return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    Value(["node": gbn(pkgid, scid, outName, "icon-package")]), 200);
        }
        case "delete":
        {
            Value[] ids;
            if (!pkgid.isNone)
                ids ~= pkgid;
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

            bool cascade = checkCascadeOperation();

            foreach (id; ids)
            {
                auto propSql = renderTemplate(templatePath ~ "/" ~ PROPERTIES_SQL,
                        tv("scid", scid, "pkgid", id, "conn", conn));
                auto r = conn.executeDict(propSql);
                if (!r.ok || r.value["rows"].length == 0)
                    return gone(gettext("Could not find the package."));
                auto oldData = r.value["rows"][0];
                oldData["schema"] = Value(schemaName);

                auto delSql = renderTemplate(templatePath ~ "/" ~ DELETE_SQL,
                        tv("data", oldData, "cascade", cascade, "conn", conn));
                auto dr = conn.executeScalar(delSql);
                if (!dr.ok)
                    return internalServerError(dr.error);
            }

            return makeJsonResponse(1, Value(""), Value(gettext("Package dropped")), Value(null), Value(null), 200);
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
            auto sql = getSql(k, data, scid, pkgid, schemaName, outName);
            if (sql.length == 0)
                sql = "--modified SQL";
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(sql), 200);
        }
        case "sql":
        {
            auto propSql = renderTemplate(templatePath ~ "/" ~ PROPERTIES_SQL,
                    tv("scid", scid, "pkgid", pkgid, "conn", conn));
            auto r = conn.executeDict(propSql);
            if (!r.ok || r.value["rows"].length == 0)
                return gone(gettext("Could not find the package."));
            auto oldData = r.value["rows"][0];
            oldData["schema"] = Value(schemaName);

            auto aclSql = renderTemplate(templatePath ~ "/" ~ ACL_SQL,
                    tv("scid", scid, "pkgid", pkgid, "conn", conn));
            auto ar = conn.executeDict(aclSql);
            if (ar.ok)
            {
                foreach (arow; ar.value["rows"].list.items)
                {
                    auto deftype = arow["deftype"].toString;
                    if (!oldData.contains(deftype))
                        oldData[deftype] = Value.newList();
                    oldData[deftype].list.items ~= parsePrivFromDb(arow);
                }
            }

            auto sql = renderTemplate(templatePath ~ "/" ~ CREATE_SQL,
                    tv("data", oldData, "conn", conn));
            return makeResponse(Value(sql), 200);
        }
        case "dependents":
            return makeResponse(getDependents(conn, pkgid), 200);
        case "dependencies":
            return makeResponse(getDependencies(conn, pkgid), 200);
        default:
            return super.callMethod(name, k);
        }
    }
}
