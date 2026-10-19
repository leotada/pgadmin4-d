/// `servers/pgd_replication_groups`: EDB Postgres Distributed node groups.
module pgadmin.browser.server_groups.servers.pgd_replication_groups;

import pgadmin.browser.common;
import pgadmin.browser.server_groups.servers.utils : getReplicationType;
import pgadmin.browser.server_groups.servers.pgd_replication_groups.pgd_replication_servers : PGDReplicationServersModule;

final class PGDReplicationGroupsModule : CollectionNodeModule
{
    enum NODE_TYPE = "pgd_replication_groups";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "PGD Replication Groups";
        staticDir("browser/server_groups/servers/pgd_replication_groups");
    }

    override string nodeType() => NODE_TYPE;
    override bool nodeInode() => false;
    override string collectionIcon() => "icon-ppas";

    override Value[] getNodes(Dict kwargs) => [generateBrowserCollectionNode(kwargs["sid"])];

    override bool backendSupported(ServerManager manager, Dict kwargs)
    {
        if (!super.backendSupported(manager, kwargs))
            return false;
        auto c = manager.connection();
        return getReplicationType(c, manager.version_) == Value("pgd");
    }

    override void setup()
    {
        submodules ~= new PGDReplicationServersModule;
        registerNodeView!PGDReplicationGroupsView(this);
    }
}

final class PGDReplicationGroupsView : PGChildNodeView
{
    enum BASE_TEMPLATE_PATH = "pgd_replication_groups/sql/#{0}#";

    this()
    {
        super();
        nodeType = PGDReplicationGroupsModule.NODE_TYPE;
        parentIds = [IdSpec("int", "gid"), IdSpec("int", "sid")];
        ids = [IdSpec("int", "node_group_id")];
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
        switch (name)
        {
        case "list":
        {
            auto r = conn.executeDict(rt(PROPERTIES_SQL));
            if (!r.ok)
                return internalServerError(r.error);
            return makeResponse(r.value["rows"], 200);
        }
        case "nodes":
        {
            auto r = conn.execute2darray(rt(NODES_SQL));
            if (!r.ok)
                return internalServerError(r.error);
            Value[] res;
            foreach (row; r.value["rows"].list.items)
                res ~= gbn(row["node_group_id"], sid, row["node_group_name"].toString, "icon-pgd_replication_groups",
                        kwDict("inode", Value(true)));
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        case "properties":
        {
            auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("node_group_id", k["node_group_id"])));
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
