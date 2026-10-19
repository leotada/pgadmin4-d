/// `schemas/catalog_objects/columns`: columns of a catalog object.
module pgadmin.browser.server_groups.servers.databases.schemas.catalog_objects.columns;

import pgadmin.browser.common;

final class CatalogObjectColumnsModule : CollectionNodeModule
{
    enum NODE_TYPE = "catalog_object_column";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "Columns";
        minVer = Value(null);
        maxVer = Value(null);
        staticDir("browser/server_groups/servers/databases/schemas/catalog_objects/columns");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => "database";
    override bool nodeInode() => false;
    override bool moduleUseTemplateJavascript() => false;

    override Value[] getNodes(Dict kwargs) => [generateBrowserCollectionNode(kwargs["coid"])];

    override void setup()
    {
        registerNodeView!CatalogObjectColumnsView(this);
    }
}

final class CatalogObjectColumnsView : PGChildNodeView
{
    this()
    {
        super();
        nodeType = CatalogObjectColumnsModule.NODE_TYPE;
        nodeLabel = "Catalog Object Column";
        parentIds = [IdSpec("int", "gid"), IdSpec("int", "sid"), IdSpec("int", "did"), IdSpec("int", "scid"),
            IdSpec("int", "coid")];
        ids = [IdSpec("int", "clid")];
        setAllOps([
            makeOp("obj", ["get": "properties"], ["get": "list"]),
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
        auto err = standardPrecondition(k, name, "catalog_object_column/sql/#{0}#");
        if (err !is null)
            return err;
        auto coid = k["coid"];
        auto clid = k.has("clid") ? k["clid"] : Value(null);
        switch (name)
        {
        case "list":
        {
            auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("coid", coid)));
            if (!r.ok)
                return internalServerError(r.error);
            return makeResponse(r.value["rows"], 200);
        }
        case "nodes":
        {
            auto r = conn.execute2darray(rt(NODES_SQL, tv("coid", coid)));
            if (!r.ok)
                return internalServerError(r.error);
            Value[] res;
            foreach (row; r.value["rows"].list.items)
                res ~= gbn(row["attnum"], coid, row["attname"].toString, "icon-catalog_object_column",
                        kwDict("description", row["description"]));
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        case "properties":
        {
            auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("coid", coid, "clid", clid)));
            if (!r.ok)
                return internalServerError(r.error);
            if (r.value["rows"].length == 0)
                return gone(gettext("Could not find the specified column."));
            auto row = r.value["rows"][0];
            row["is_sys_obj"] = Value(row["attrelid"].integer <= DATABASE_LAST_SYSTEM_OID_ || datistemplate);
            return makeResponse(row, 200);
        }
        case "dependents":
        {
            auto where = "WHERE dep.refobjid=" ~ coid.toString ~ "::OID AND dep.refobjsubid=" ~ clid.toString;
            auto result = getDependents(conn, clid, where);
            auto r = conn.executeDict(rt("depend.sql", tv("where", where)));
            if (!r.ok)
                return internalServerError(r.error);
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
                result.append(Value.dictOf("type", "sequence", "name", row["refname"], "field", depType));
            }
            return makeResponse(result, 200);
        }
        case "dependencies":
        {
            auto where = "WHERE dep.objid=" ~ coid.toString ~ "::OID AND dep.objsubid=" ~ clid.toString;
            return makeResponse(getDependencies(conn, clid, where), 200);
        }
        default: return super.callMethod(name, k);
        }
    }
}
