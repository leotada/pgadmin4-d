/// `pgadmin/tools/schema_diff/compare`: Object and schema comparison logic.
module pgadmin.tools.schema_diff.compare;

import std.algorithm : canFind;
import std.conv : to;
import std.typecons : Tuple, tuple;
import pgadmin.browser.server_groups.servers.databases.schemas : SchemaView;
import pgadmin.browser.utils : NodeView, makeView;
import pgadmin.core.i18n;
import pgadmin.core.log;
import pgadmin.core.value;
import pgadmin.db.driver;
import pgadmin.tools.schema_diff.directory_compare;
import pgadmin.tools.schema_diff.node_registry;

final class SchemaDiffCompare
{
    static string[] keysToIgnore = ["oid", "oid-2", "is_sys_obj", "schema"];

    static bool getSchema(long sid, long did, long scid, out string schemaName)
    {
        try
        {
            auto manager = getDriver().connectionManager(sid);
            auto conn = manager.connection(null, null, true, Value(did));
            if (!conn.connected())
            {
                auto st = conn.connect();
                if (!st.ok)
                {
                    schemaName = st.error;
                    return false;
                }
            }
            auto r = conn.executeScalar("SELECT nsp.nspname FROM pg_catalog.pg_namespace nsp WHERE nsp.oid = " ~ to!string(scid));
            if (!r.ok)
            {
                schemaName = r.error;
                return false;
            }
            schemaName = r.value.toString;
            return true;
        }
        catch (Exception e)
        {
            schemaName = e.msg;
            return false;
        }
    }
}

string getObjectSql(NodeView view, long sid, long did, long scid, long oid)
{
    if (view is null || oid <= 0)
        return "";

    try
    {
        auto kwargs = new Dict;
        kwargs["gid"] = Value(1);
        kwargs["sid"] = Value(sid);
        kwargs["did"] = Value(did);
        if (scid > 0)
            kwargs["scid"] = Value(scid);

        if (view.ids.length > 0)
            kwargs[view.ids[0].id] = Value(oid);
        else
            kwargs["oid"] = Value(oid);

        auto resp = view.dispatchRequest("sql", kwargs);
        if (resp !is null && resp.status == 200)
        {
            auto txt = resp.sqlText.length ? resp.sqlText : resp.body;
            if (txt.length && txt[0] == '{')
            {
                try
                {
                    auto json = parseJson(txt);
                    if (json.isDict && json.contains("data"))
                    {
                        if (json["data"].isString)
                            return json["data"].toString;
                        else if (json["data"].isDict && json["data"].contains("sql"))
                            return json["data"]["sql"].toString;
                    }
                }
                catch (Exception) {}
            }
            return txt;
        }
    }
    catch (Exception e)
    {
        logError("ddl_compare getObjectSql error: " ~ e.msg);
    }
    return "";
}

Dict ddlCompare(long sourceSid, long sourceDid, long sourceScid,
                long targetSid, long targetDid, long targetScid,
                long sourceOid, long targetOid, string nodeType, string compStatus)
{
    auto view = SchemaDiffRegistry.getNodeView(nodeType);
    if (view is null)
        return null;

    string sourceDdl = getObjectSql(view, sourceSid, sourceDid, sourceScid, sourceOid);
    auto targetView = SchemaDiffRegistry.getNodeView(nodeType);
    string targetDdl = getObjectSql(targetView, targetSid, targetDid, targetScid, targetOid);

    auto res = new Dict;
    res["source_ddl"] = Value(sourceDdl);
    res["target_ddl"] = Value(targetDdl);
    res["diff_ddl"] = Value("");
    return res;
}

Tuple!(bool, string) checkVersionCompatibility(long sid, long tid)
{
    auto srcServer = getServer(sid);
    if (srcServer.isNone)
        return tuple(false, gettext("Could not find the source server."));
    auto srcMgr = getDriver().connectionManager(sid);
    auto srcConn = srcMgr.connection();

    auto tarServer = getServer(tid);
    if (tarServer.isNone)
        return tuple(false, gettext("Could not find the target server."));
    auto tarMgr = getDriver().connectionManager(tid);
    auto tarConn = tarMgr.connection();

    if (!srcConn.connected() || !tarConn.connected())
        return tuple(false, gettext("Server(s) disconnected."));

    if (srcMgr.serverType != tarMgr.serverType)
        return tuple(false, gettext("Schema diff does not support the comparison between Postgres Server and EDB Postgres Advanced Server."));

    long getRoundVal(long x)
    {
        if (x < 100000)
            return x + 100 - (x % 100);
        else
            return x + 10000 - (x % 10000);
    }

    if (getRoundVal(srcMgr.version_) == getRoundVal(tarMgr.version_))
        return tuple(true, "");

    return tuple(false, gettext("Source and Target database server must be of the same major version."));
}

Value[] getSchemas(long sid, long did)
{
    auto server = getServer(sid);
    if (server.isNone)
        return null;
    auto view = makeView!SchemaView();
    auto resp = view.nodes(server["servergroup_id"], Value(sid), Value(did), Value(null), true);
    if (resp is null || resp.status != 200)
        return null;
    auto data = parseJson(resp.body);
    if (data.isDict && data.contains("data") && data["data"].isList)
        return data["data"].list.items;
    return null;
}

Dict fetchCompareSchemas(long sourceSid, long sourceDid, long targetSid, long targetDid)
{
    auto sourceSchemas = getSchemas(sourceSid, sourceDid);
    auto targetSchemas = getSchemas(targetSid, targetDid);

    if (sourceSchemas is null || targetSchemas is null)
        return null;

    long[string] srcSchemaDict;
    foreach (item; sourceSchemas)
        srcSchemaDict[item["label"].toString] = item["_id"].integer;

    long[string] tarSchemaDict;
    foreach (item; targetSchemas)
        tarSchemaDict[item["label"].toString] = item["_id"].integer;

    Value[] sourceOnly;
    Value[] targetOnly;
    Value[] inBothDatabase;

    foreach (k, scid; srcSchemaDict)
    {
        if (auto p = k in tarSchemaDict)
        {
            inBothDatabase ~= Value.dictOf(
                "schema_name", k,
                "src_scid", scid,
                "tar_scid", *p
            );
        }
        else
        {
            sourceOnly ~= Value.dictOf(
                "schema_name", k,
                "scid", scid
            );
        }
    }

    foreach (k, scid; tarSchemaDict)
    {
        if (k !in srcSchemaDict)
        {
            targetOnly ~= Value.dictOf(
                "schema_name", k,
                "scid", scid
            );
        }
    }

    auto res = new Dict;
    res["source_only"] = Value(sourceOnly);
    res["target_only"] = Value(targetOnly);
    res["in_both_database"] = Value(inBothDatabase);
    return res;
}

Value[string] fetchObjectsForNode(NodeView view, long sid, long did, long scid)
{
    Value[string] res;
    try
    {
        auto kwargs = new Dict;
        kwargs["gid"] = Value(1);
        kwargs["sid"] = Value(sid);
        kwargs["did"] = Value(did);
        if (scid > 0)
            kwargs["scid"] = Value(scid);

        auto resp = view.dispatchRequest("nodes", kwargs);
        if (resp !is null && resp.status == 200)
        {
            auto json = parseJson(resp.body);
            if (json.isDict && json.contains("data") && json["data"].isList)
            {
                foreach (item; json["data"].list.items)
                {
                    if (item.contains("label"))
                    {
                        auto name = item["label"].toString;
                        res[name] = item;
                    }
                }
            }
        }
    }
    catch (Exception e)
    {
        logError("fetchObjectsForNode error: " ~ e.msg);
    }
    return res;
}

private string getNodeLabel(NodeView view, string nodeName)
{
    if (view is null)
        return nodeName;
    if (view.collection !is null && view.collection.collectionLabelText.length)
        return view.collection.collectionLabelText;
    if (view.nodeLabel.length)
        return view.nodeLabel;
    return nodeName;
}

Value[] compareDatabaseObjects(
    long sourceSid, long sourceDid,
    long targetSid, long targetDid,
    bool ignoreOwner, bool ignoreWhitespaces,
    bool ignoreTablespace, bool ignoreGrants,
    ref long count
)
{
    Value[] comparisonResult;
    auto nodes = SchemaDiffRegistry.getRegisteredNodes(null, "Database");
    foreach (nodeName, reg; nodes)
    {
        auto view = SchemaDiffRegistry.getNodeView(nodeName);
        if (view is null)
            continue;

        Value[string] sourceDict = fetchObjectsForNode(view, sourceSid, sourceDid, 0);
        auto targetView = SchemaDiffRegistry.getNodeView(nodeName);
        Value[string] targetDict = fetchObjectsForNode(targetView, targetSid, targetDid, 0);

        if (sourceDict.length == 0 && targetDict.length == 0)
            continue;

        auto diff = compareDictionaries(
            sourceDict, targetDict,
            nodeName, getNodeLabel(view, nodeName),
            gettext("Database Objects"), "", "",
            SchemaDiffCompare.keysToIgnore,
            ignoreOwner, ignoreWhitespaces, ignoreTablespace, ignoreGrants,
            count
        );
        comparisonResult ~= diff;
    }
    return comparisonResult;
}

Value[] compareSchemaObjects(
    long sourceSid, long sourceDid, long sourceScid,
    long targetSid, long targetDid, long targetScid,
    string schemaName,
    bool ignoreOwner, bool ignoreWhitespaces,
    bool ignoreTablespace, bool ignoreGrants,
    ref long count
)
{
    Value[] comparisonResult;
    auto nodes = SchemaDiffRegistry.getRegisteredNodes(null, "schema");
    foreach (nodeName, reg; nodes)
    {
        auto view = SchemaDiffRegistry.getNodeView(nodeName);
        if (view is null)
            continue;

        Value[string] sourceDict = sourceScid > 0 ? fetchObjectsForNode(view, sourceSid, sourceDid, sourceScid) : null;
        auto targetView = SchemaDiffRegistry.getNodeView(nodeName);
        Value[string] targetDict = targetScid > 0 ? fetchObjectsForNode(targetView, targetSid, targetDid, targetScid) : null;

        if (sourceDict.length == 0 && targetDict.length == 0)
            continue;

        string targetSchema;
        if (targetScid > 0)
            SchemaDiffCompare.getSchema(targetSid, targetDid, targetScid, targetSchema);

        auto diff = compareDictionaries(
            sourceDict, targetDict,
            nodeName, getNodeLabel(view, nodeName),
            gettext(schemaName), targetSchema, schemaName,
            SchemaDiffCompare.keysToIgnore,
            ignoreOwner, ignoreWhitespaces, ignoreTablespace, ignoreGrants,
            count
        );
        comparisonResult ~= diff;
    }
    return comparisonResult;
}
