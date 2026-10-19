/// `servers/replica_nodes`: standbys connected to a server using logical replication.
module pgadmin.browser.server_groups.servers.replica_nodes;

import pgadmin.browser.common;
import pgadmin.browser.server_groups.servers.utils : getReplicationType;

final class ReplicationNodesModule : CollectionNodeModule
{
    enum NODE_TYPE = "replica_nodes";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "Replica Nodes";
        staticDir("browser/server_groups/servers/replica_nodes");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => "server";
    override bool nodeInode() => false;
    override string collectionIcon() => "icon-server_group";

    override Value[] getNodes(Dict kwargs) => [generateBrowserCollectionNode(kwargs["sid"])];

    override bool backendSupported(ServerManager manager, Dict kwargs)
    {
        if (!super.backendSupported(manager, kwargs))
            return false;
        auto c = manager.connection();
        return getReplicationType(c, manager.version_) == Value("log");
    }

    override void setup()
    {
        registerNodeView!ReplicationNodesView(this);
    }
}

final class ReplicationNodesView : PGChildNodeView
{
    enum BASE_TEMPLATE_PATH = "replica_nodes/sql/#{0}#";

    this()
    {
        super();
        nodeType = ReplicationNodesModule.NODE_TYPE;
        parentIds = [IdSpec("int", "gid"), IdSpec("int", "sid")];
        ids = [IdSpec("int", "pid")];
        setAllOps([
            makeOp("obj", ["get": "properties"], ["get": "list"]),
            makeOp("nodes", ["get": "nodes"], ["get": "nodes"]),
            makeOp("replication_slots", ["get": "replication_slots"], ["get": "replication_slots"]),
        ]);
    }

    override Response callMethod(string name, Dict k)
    {
        if (!isAuthenticated())
            return unauthorisedResponse();
        // the Python class defines no `replication_slots` view
        if (name == "replication_slots")
            return super.callMethod(name, k);
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
                res ~= gbn(row["pid"], sid, row["name"].toString, null);
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        case "properties":
        {
            auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("pid", k["pid"])));
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
