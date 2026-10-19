/// `pgd_replication_groups/pgd_replication_servers`: the nodes of a PGD group.
module pgadmin.browser.server_groups.servers.pgd_replication_groups.pgd_replication_servers;

import pgadmin.browser.common;

final class PGDReplicationServersModule : CollectionNodeModule
{
    enum NODE_TYPE = "pgd_replication_servers";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "Servers";
        staticDir("browser/server_groups/servers/pgd_replication_groups/pgd_replication_servers");
    }

    override string nodeType() => NODE_TYPE;
    override bool nodeInode() => false;
    override string collectionIcon() => "icon-server_group";

    override string[] csssnippets() => [renderTemplate("pgd_replication_servers/css/pgd_replication_servers.css",
            ["node_type": Value(nodeType)])];

    override Value[] getNodes(Dict kwargs) => [generateBrowserCollectionNode(kwargs["node_group_id"])];

    override void setup()
    {
        registerNodeView!PGDReplicationServersView(this);
    }
}

final class PGDReplicationServersView : PGChildNodeView
{
    enum BASE_TEMPLATE_PATH = "pgd_replication_servers/sql/#{0}#";

    this()
    {
        super();
        nodeType = PGDReplicationServersModule.NODE_TYPE;
        parentIds = [IdSpec("int", "gid"), IdSpec("int", "sid"), IdSpec("int", "node_group_id")];
        ids = [IdSpec("int", "node_id")];
        setAllOps([
            makeOp("obj", ["get": "properties"], ["get": "list"]),
            makeOp("nodes", ["get": "nodes"], ["get": "nodes"]),
            makeOp("children", ["get": "children"]),
        ]);
    }

    override Response callMethod(string name, Dict k)
    {
        if (!isAuthenticated())
            return unauthorisedResponse();
        if (name == "children")
            return children(k);
        manager = getDriver().connectionManager(k["sid"].integer);
        conn = manager.connection();
        if (!conn.connected())
            return preconditionRequired(gettext("Connection to the server has been lost."));
        templatePath = BASE_TEMPLATE_PATH.replace("{0}", to!string(manager.version_));
        auto sid = k["sid"];
        auto ngid = k["node_group_id"];
        switch (name)
        {
        case "list":
        {
            auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("node_group_id", ngid)));
            if (!r.ok)
                return internalServerError(r.error);
            return makeResponse(r.value["rows"], 200);
        }
        case "nodes":
        {
            auto r = conn.execute2darray(rt(NODES_SQL, tv("node_group_id", ngid)));
            if (!r.ok)
                return internalServerError(r.error);
            Value[] res;
            foreach (row; r.value["rows"].list.items)
                res ~= gbn(row["node_id"], sid, row["node_name"].toString, "icon-pgd_node_" ~ row["node_kind_name"].toString);
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        case "properties":
        {
            auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("node_group_id", ngid, "node_id", k["node_id"])));
            if (!r.ok)
                return internalServerError(r.error);
            if (r.value["rows"].length == 0)
                return gone(gettext("Could not find the Replication Node."));
            return makeResponse(r.value["rows"][0], 200);
        }
        default: return super.callMethod(name, k);
        }
    }
}
