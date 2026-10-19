/// `schemas/catalog_objects`: tables and views of `information_schema`/`sys` (read-only).
module pgadmin.browser.server_groups.servers.databases.schemas.catalog_objects;

import pgadmin.browser.common;
import pgadmin.browser.server_groups.servers.databases.schemas.utils;
import pgadmin.browser.server_groups.servers.databases.schemas.catalog_objects.columns : CatalogObjectColumnsModule;

final class CatalogObjectModule : SchemaChildModule
{
    enum NODE_TYPE = "catalog_object";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "Catalog Objects";
        minVer = Value(null);
        maxVer = Value(null);
        catalogDbSupported = false;
        supportedSchemas = ["information_schema", "sys"];
        staticDir("browser/server_groups/servers/databases/schemas/catalog_objects");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => "database";

    override Value[] getNodes(Dict kwargs) => [generateBrowserCollectionNode(kwargs["scid"])];

    override void setup()
    {
        submodules ~= new CatalogObjectColumnsModule;
        registerNodeView!CatalogObjectView(this);
    }
}

final class CatalogObjectView : PGChildNodeView
{
    this()
    {
        super();
        nodeType = CatalogObjectModule.NODE_TYPE;
        nodeLabel = "Catalog Object";
        parentIds = [IdSpec("int", "gid"), IdSpec("int", "sid"), IdSpec("int", "did"), IdSpec("int", "scid")];
        ids = [IdSpec("int", "coid")];
        setAllOps([
            makeOp("obj", ["get": "properties"], ["get": "list"]),
            makeOp("children", ["get": "children"]),
            makeOp("nodes", ["get": "node"], ["get": "nodes"]),
            makeOp("sql", ["get": "sql"]),
            makeOp("dependency", ["get": "dependencies"]),
            makeOp("dependent", ["get": "dependents"]),
        ]);
    }

    override Response callMethod(string name, Dict k)
    {
        if (!isAuthenticated())
            return unauthorisedResponse();
        if (name == "children")
            return children(k);
        auto err = standardPrecondition(k, name, "catalog_object/sql/{0}/#{1}#");
        if (err !is null)
            return err;
        auto scid = k["scid"];
        auto coid = k.has("coid") ? k["coid"] : Value(null);
        switch (name)
        {
        case "list":
        {
            auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("scid", scid)));
            if (!r.ok)
                return internalServerError(r.error);
            return makeResponse(r.value["rows"], 200);
        }
        case "nodes":
        {
            auto r = conn.execute2darray(rt(NODES_SQL, tv("scid", scid)));
            if (!r.ok)
                return internalServerError(r.error);
            Value[] res;
            foreach (row; r.value["rows"].list.items)
                res ~= gbn(row["oid"], scid, row["name"].toString, "icon-catalog_object",
                        kwDict("description", row["description"]));
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        case "node":
        {
            auto r = conn.execute2darray(rt(NODES_SQL, tv("coid", coid)));
            if (!r.ok)
                return internalServerError(r.error);
            foreach (row; r.value["rows"].list.items)
                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                        gbn(row["oid"], scid, row["name"].toString, "icon-catalog_object"), 200);
            return gone(gettext("Could not find the specified catalog object."));
        }
        case "properties":
        {
            auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("scid", scid, "coid", coid)));
            if (!r.ok)
                return internalServerError(r.error);
            if (r.value["rows"].length == 0)
                return gone(gettext("Could not find the specified catalog object."));
            auto row = r.value["rows"][0];
            row["is_sys_obj"] = Value(row["oid"].integer <= DATABASE_LAST_SYSTEM_OID_ || datistemplate);
            return makeResponse(row, 200);
        }
        case "dependents": return makeResponse(getDependents(conn, coid), 200);
        case "dependencies": return makeResponse(getDependencies(conn, coid), 200);
        default: return super.callMethod(name, k);
        }
    }
}
