/// `schemas/sequences`: sequences.
module pgadmin.browser.server_groups.servers.databases.schemas.sequences;

import std.array : replace, split;
import std.conv : to;
import std.string : strip;
import pgadmin.browser.server_groups.servers.databases.schemas.utils;
import pgadmin.browser.server_groups.servers.utils;
import pgadmin.browser.utils;
import pgadmin.core.i18n;
import pgadmin.core.log;
import pgadmin.core.templates;
import pgadmin.core.value;
import pgadmin.db.driver;
import pgadmin.db.quoting;
import pgadmin.web.auth;
import pgadmin.web.context;
import pgadmin.web.http;

final class SequenceModule : SchemaChildModule
{
    enum NODE_TYPE = "sequence";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "Sequences";
        minVer = Value(null);
        maxVer = Value(null);
        staticDir("browser/server_groups/servers/databases/schemas/sequences");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => "database";
    override bool nodeInode() => false;

    override Value[] getNodes(Dict kwargs)
    {
        if (hasNodes(kwargs["sid"], kwargs["did"], kwargs["scid"], Value(null), Value(null), SequenceView.BASE_TEMPLATE_PATH))
            return [generateBrowserCollectionNode(kwargs["scid"])];
        return null;
    }

    override void setup()
    {
        registerNodeView!SequenceView(this);
    }
}

final class SequenceView : PGChildNodeView
{
    enum BASE_TEMPLATE_PATH = "sequences/sql/#{0}#";
    string[] acl = ["r", "w", "U"];

    this()
    {
        super();
        nodeType = SequenceModule.NODE_TYPE;
        nodeLabel = "Sequence";
        parentIds = [IdSpec("int", "gid"), IdSpec("int", "sid"), IdSpec("int", "did"), IdSpec("int", "scid")];
        ids = [IdSpec("int", "seid")];
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

    private string nodeIcon() => "icon-sequence";

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
        auto gid = k.has("gid") ? k["gid"] : Value(null);
        auto sid = k["sid"];
        auto did = k.has("did") ? k["did"] : Value(null);
        auto scid = k["scid"];
        auto seid = k.has("seid") ? k["seid"] : Value(null);
        switch (name)
        {
        case "list": return list(scid);
        case "nodes": return nodes(scid, seid);
        case "properties": return properties(scid, seid);
        case "create": return create(gid, sid, did, scid);
        case "delete": return delete_(scid, seid);
        case "update": return update(gid, sid, did, scid, seid);
        case "msql": return msql(gid, sid, did, scid, seid);
        case "sql": return sqlView(gid, sid, did, scid, seid);
        case "dependents": return makeResponse(getDependents(conn, seid), 200);
        case "dependencies": return makeResponse(getDependency(seid), 200);
        case "statistics": return statistics(scid, seid);
        default: return super.callMethod(name, k);
        }
    }

    private Response list(Value scid)
    {
        auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("scid", scid)));
        if (!r.ok)
            return internalServerError(r.error);
        return makeResponse(getSequenceNodes(r.value["rows"]), 200);
    }

    private Value getSequenceNodes(Value nodes)
    {
        if (bpModule.showSystemObjectsFlag)
            return nodes;
        Value[] seq;
        foreach (row; nodes.list.items)
        {
            auto systemSeq = getDependency(row["oid"], Value(true));
            bool internal;
            if (systemSeq.isList)
                foreach (dep; systemSeq.list.items)
                    if (dep["type"].toString == "column" && dep["field"].toString == "internal")
                        internal = true;
            if (internal)
                continue;
            seq ~= row;
        }
        return Value(seq);
    }

    private Response nodes(Value scid, Value seid)
    {
        bool showInternal = bpModule.showSystemObjectsFlag;
        auto r = conn.executeDict(rt(NODES_SQL, tv("scid", scid, "seid", seid, "show_internal", showInternal, "conn", conn)));
        if (!r.ok)
            return internalServerError(r.error);
        if (!seid.isNone)
        {
            if (r.value["rows"].length == 0)
                return gone(notFoundErrorMsg());
            auto row = r.value["rows"][0];
            return makeJsonResponse(1, Value(""), Value(""), Value(null), gbn(row["oid"], scid,
                    row["name"].toString, nodeIcon, kwDict("description", row["comment"])), 200);
        }
        Value[] res;
        foreach (row; r.value["rows"].list.items)
            res ~= gbn(row["oid"], scid, row["name"].toString, nodeIcon,
                    kwDict("description", row["comment"]));
        return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
    }

    private Value fetchProperties(Value scid, Value seid, out Response err)
    {
        auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("scid", scid, "seid", seid)));
        if (!r.ok)
        {
            err = internalServerError(r.error);
            return Value(null);
        }
        if (r.value["rows"].length == 0)
        {
            err = gone(notFoundErrorMsg());
            return Value(null);
        }
        auto res = r.value;
        res["rows"][0]["is_sys_obj"] = Value(res["rows"][0]["oid"].integer <= DATABASE_LAST_SYSTEM_OID_ || datistemplate);
        foreach (row; res["rows"].list.items)
        {
            auto d = conn.executeDict(rt("get_def.sql", tv("data", row)));
            if (!d.ok)
            {
                err = internalServerError(d.error);
                return Value(null);
            }
            auto def = d.value["rows"][0];
            row["current_value"] = def["last_value"];
            row["minimum"] = def["min_value"];
            row["maximum"] = def["max_value"];
            row["increment"] = def["increment_by"];
            row["start"] = def["start_value"];
            row["cache"] = def["cache_value"];
            row["cycled"] = def["is_cycled"];
            addSecuritiesToRow(row);
        }
        auto a = conn.executeDict(rt(ACL_SQL, tv("scid", scid, "seid", seid)));
        if (!a.ok)
        {
            err = internalServerError(res.toString);
            return Value(null);
        }
        foreach (row; a.value["rows"].list.items)
        {
            auto priv = parsePrivFromDb(row);
            auto first = res["rows"][0];
            auto t = row["deftype"].toString;
            if (first.contains(t))
                first[t].append(priv);
            else
                first[t] = Value([priv]);
        }
        return res["rows"][0];
    }

    private static void addSecuritiesToRow(Value row)
    {
        Value[] lbls;
        if (row.contains("securities") && !row["securities"].isNone)
            foreach (sec; row["securities"].iterItems())
            {
                import std.regex : regex, matchFirst;
                auto m = matchFirst(sec.toString, regex(`([^=]+)=(.*$)`));
                lbls ~= Value.dictOf("provider", m[1].idup, "label", m[2].idup);
            }
        row["securities"] = Value(lbls);
    }

    private Response properties(Value scid, Value seid)
    {
        Response err;
        auto res = fetchProperties(scid, seid, err);
        if (err !is null)
            return err;
        return makeResponse(res, 200);
    }

    private Response create(Value gid, Value sid, Value did, Value scid)
    {
        auto data = formOrJson(request());
        auto miss = missingArg(data, ["name", "schema", "seqowner"], 400);
        if (miss !is null)
            return miss;
        string sql;
        try
            sql = rt(CREATE_SQL, tv("data", data, "conn", conn));
        catch (Exception e)
            return internalServerError(e.msg);
        auto r = conn.executeScalar(sql);
        if (!r.ok)
            return internalServerError(r.error);
        if (data.contains("relacl"))
            data["relacl"] = parsePrivToDb(data["relacl"], acl);
        sql = rt(GRANT_SQL, tv("data", data, "conn", conn)).strip("\n").strip(" ");
        if (sql.length)
        {
            auto g = conn.executeScalar(sql);
            if (!g.ok)
                return internalServerError(g.error);
        }
        sql = rt(OID_SQL, tv("name", data["name"], "schema", data["schema"], "conn", conn)).strip("\n").strip(" ");
        auto o = conn.execute2darray(sql);
        if (!o.ok)
            return internalServerError(o.error);
        auto row = o.value["rows"][0];
        return jsonify(Value.dictOf("node", gbn(row["oid"], row["relnamespace"],
                data["name"].toString, nodeIcon)));
    }

    Response delete_(Value scid, Value seidArg, bool onlySql = false)
    {
        Value data = seidArg.isNone ? formOrJson(request()) : Value.dictOf("ids", Value([seidArg]));
        bool cascade = checkCascadeOperation();
        try
        {
            foreach (seid; data["ids"].iterItems())
            {
                auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("scid", scid, "seid", seid)));
                if (!r.ok)
                    return internalServerError(r.error);
                if (r.value["rows"].length == 0)
                    return makeJsonResponse(0, Value(gettext("Error: Object not found.")), Value(notFoundErrorMsg()));
                auto sql = rt(DELETE_SQL, tv("data", r.value["rows"][0], "cascade", cascade));
                if (onlySql)
                    return Response.sqlOnly(sql);
                auto d = conn.executeScalar(sql);
                if (!d.ok)
                    return internalServerError(d.error);
            }
            return makeJsonResponse(1, Value(""), Value(gettext("Sequence dropped")));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response update(Value gid, Value sid, Value did, Value scid, Value seid)
    {
        auto data = formOrJson(request());
        Response err;
        string name;
        auto sql = getSQL(gid, sid, did, data, scid, seid, name, err);
        if (err !is null)
            return err;
        sql = sql.strip("\n").strip(" ");
        auto r = conn.executeScalar(sql);
        if (!r.ok)
            return internalServerError(r.error);
        auto n = conn.execute2darray(rt(NODES_SQL, tv("seid", seid, "conn", conn)));
        if (!n.ok)
            return internalServerError(n.error);
        auto row = n.value["rows"][0];
        return jsonify(Value.dictOf("node", gbn(seid, row["schema"], row["name"].toString,
                nodeIcon, kwDict("description", row["comment"]))));
    }

    private Response msql(Value gid, Value sid, Value did, Value scid, Value seid)
    {
        auto data = msqlData("comment");
        if (seid.isNone)
        {
            auto miss = missingArg(data, ["name", "schema"], 400);
            if (miss !is null)
                return miss;
        }
        Response err;
        string name;
        auto sql = getSQL(gid, sid, did, data, scid, seid, name, err);
        if (err !is null)
            return err;
        sql = sql.strip("\n").strip(" ");
        if (sql == "")
            sql = "--modified SQL";
        return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(sql), 200);
    }

    private void addRestartForNewBounds(Value data, Value oldData)
    {
        auto minimum = data.contains("minimum") ? data["minimum"] : Value(null);
        auto maximum = data.contains("maximum") ? data["maximum"] : Value(null);
        if (minimum.isNone && maximum.isNone)
            return;
        auto current = data.contains("current_value") ? data["current_value"] : Value(null);
        if (current.isNone)
        {
            auto r = conn.executeDict(rt("get_def.sql", tv("data", oldData, "conn", conn)));
            if (!r.ok || r.value["rows"].length == 0)
                return;
            current = r.value["rows"][0]["last_value"];
        }
        if (current.isNone)
            return;
        if (!minimum.isNone && minimum.integer > current.integer)
            data["restart"] = Value(minimum.integer);
        else if (!maximum.isNone && maximum.integer < current.integer)
            data["restart"] = Value(maximum.integer);
    }

    /// `get_SQL`: the SQL for a new or modified sequence; `err` is set instead when something is wrong.
    string getSQL(Value gid, Value sid, Value did, Value data, Value scid, Value seid, out string name, out Response err,
            bool addNotExistsClause = false)
    {
        if (!seid.isNone)
        {
            auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("scid", scid, "seid", seid)));
            if (!r.ok)
            {
                err = internalServerError(r.error);
                return null;
            }
            if (r.value["rows"].length == 0)
            {
                err = gone(notFoundErrorMsg());
                return null;
            }
            auto oldData = Value(r.value["rows"][0].dict.copy());
            oldData = formatter(oldData, scid, seid, err);
            if (err !is null)
                return null;
            formatPrivilegeData(data);
            foreach (arg; ["name"])
                if (!data.contains(arg))
                    data[arg] = oldData[arg];
            addRestartForNewBounds(data, oldData);
            auto sql = rt(UPDATE_SQL, tv("data", data, "o_data", oldData, "conn", conn));
            name = data.contains("name") ? data["name"].toString : oldData["name"].toString;
            return sql;
        }
        if (data.contains("relacl"))
            data["relacl"] = parsePrivToDb(data["relacl"], acl);
        auto sql = rt(CREATE_SQL, tv("data", data, "conn", conn, "add_not_exists_clause", addNotExistsClause));
        sql ~= rt(GRANT_SQL, tv("data", data, "conn", conn));
        name = data["name"].toString;
        return sql;
    }

    private void formatPrivilegeData(Value data)
    {
        if (data.contains("relacl") && !data["relacl"].isNone)
            foreach (k; ["added", "changed", "deleted"])
                if (data["relacl"].contains(k))
                    data["relacl"][k] = parsePrivToDb(data["relacl"][k], acl);
    }

    private Response sqlView(Value gid, Value sid, Value did, Value scid, Value seid, string targetSchema = null,
            bool jsonResp = true)
    {
        auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("scid", scid, "seid", seid)));
        if (!r.ok)
            return internalServerError(r.error);
        if (r.value["rows"].length == 0)
            return gone(notFoundErrorMsg());
        foreach (row; r.value["rows"].list.items)
        {
            auto d = conn.executeDict(rt("get_def.sql", tv("data", row)));
            if (!d.ok)
                return internalServerError(d.error);
            auto def = d.value["rows"][0];
            row["current_value"] = def["last_value"];
            row["minimum"] = def["min_value"];
            row["maximum"] = def["max_value"];
            row["increment"] = def["increment_by"];
            row["start"] = def["start_value"];
            row["cache"] = def["cache_value"];
            row["cycled"] = def["is_cycled"];
        }
        auto result = r.value["rows"][0];
        if (targetSchema.length)
            result["schema"] = Value(targetSchema);
        Response err;
        result = formatter(result, scid, seid, err);
        if (err !is null)
            return err;
        string name;
        auto sql = getSQL(gid, sid, did, result, scid, Value(null), name, err, true);
        if (err !is null)
            return err;
        sql = sql.strip("\n").strip(" ");
        if (!jsonResp)
            return Response.sqlOnly(sql);
        auto header = "-- SEQUENCE: " ~ result["schema"].toString ~ "." ~ result["name"].toString ~ "\n\n";
        header ~= "-- DROP SEQUENCE IF EXISTS " ~ qtIdentStr(result["schema"].toString, result["name"].toString) ~ ";\n\n";
        return makeResponse(Value(header ~ sql));
    }

    private Value formatter(Value data, Value scid, Value seid, out Response err)
    {
        if (data.contains("securities") && !data["securities"].isNone)
        {
            Value[] seclabels;
            foreach (s; data["securities"].iterItems())
            {
                auto parts = s.toString.split("=");
                if (parts.length != 2)
                    throw new Exception("too many values to unpack (expected 2)");
                seclabels ~= Value.dictOf("provider", parts[0], "label", parts[1]);
            }
            data["securities"] = Value(seclabels);
        }
        auto a = conn.executeDict(rt(ACL_SQL, tv("scid", scid, "seid", seid)));
        if (!a.ok)
        {
            err = internalServerError(a.error);
            return data;
        }
        data["relacl"] = Value.newList();
        foreach (row; a.value["rows"].list.items)
        {
            auto priv = parsePrivFromDb(row);
            auto t = row["deftype"].toString;
            if (data.contains(t))
                data[t].append(priv);
            else
                data[t] = Value([priv]);
        }
        return data;
    }

    private Value getDependency(Value seid, Value showSystemObjects = Value(null))
    {
        auto result = getDependencies(conn, seid, null, showSystemObjects);
        auto r = conn.executeDict(rt("get_dependencies.sql", tv("seid", seid)));
        if (!r.ok)
            return Value(internalServerError(r.error));
        foreach (row; r.value["rows"].list.items)
        {
            if (row["refname"].isNone)
                continue;
            string depType;
            auto ds = row["deptype"].toString;
            if (ds == "a")
                depType = "auto";
            else if (ds == "n")
                depType = "normal";
            else if (ds == "i")
                depType = "internal";
            result.append(Value.dictOf("type", "column", "name", row["refname"], "field", depType));
        }
        return result;
    }

    private Response statistics(Value scid, Value seid)
    {
        string sql = "stats.sql";
        Value schemaName = Value(null);
        if (seid.isNone)
        {
            sql = "coll_stats.sql";
            auto r = conn.executeScalar(renderTemplate("schemas/pg/#" ~ to!string(manager.version_) ~ "#/sql/get_name.sql",
                    tv("scid", scid, "conn", conn)));
            if (!r.ok)
                return internalServerError(r.error);
            schemaName = r.value;
        }
        auto r = conn.executeDict(rt(sql, tv("conn", conn, "seid", seid, "schema_name", schemaName)));
        if (!r.ok)
            return internalServerError(r.error);
        return makeJsonResponse(1, Value(""), Value(""), Value(null), r.value, 200);
    }
}
