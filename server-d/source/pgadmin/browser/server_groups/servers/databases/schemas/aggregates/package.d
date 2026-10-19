/// `schemas/aggregates`: aggregate functions (read-only).
module pgadmin.browser.server_groups.servers.databases.schemas.aggregates;

import std.string : strip;
import pgadmin.browser.server_groups.servers.databases.schemas.utils;
import pgadmin.browser.utils;
import pgadmin.core.value;
import pgadmin.core.templates : tv;

final class AggregateModule : SchemaChildModule
{
    enum NODE_TYPE = "aggregate";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "Aggregates";
        minVer = Value(90100);
        maxVer = Value(null);
        staticDir("browser/server_groups/servers/databases/schemas/aggregates");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => "database";
    override bool nodeInode() => false;

    override Value[] getNodes(Dict kwargs)
    {
        if (hasNodes(kwargs["sid"], kwargs["did"], kwargs["scid"], Value(null), Value(null), AggregateView.BASE))
            return [generateBrowserCollectionNode(kwargs["scid"])];
        return null;
    }

    override void setup()
    {
        registerNodeView!AggregateView(this);
    }
}

final class AggregateView : ReadOnlySchemaChildView
{
    enum BASE = "aggregates/sql/#{0}#";

    this()
    {
        super();
        nodeType = AggregateModule.NODE_TYPE;
        nodeLabel = "Aggregate";
        ids = [IdSpec("int", "agid")];
        idName = "agid";
        icon = "icon-aggregate";
        baseTemplate = BASE;
    }

    override string sqlText(Value data)
    {
        auto sql = rt(CREATE_SQL, tv("data", data));
        auto header = "-- Aggregate: " ~ data["name"].toString ~ ";\n\n-- ";
        header ~= rt(DELETE_SQL, tv("data", data));
        return header ~ "\n" ~ sql.strip("\n");
    }
}
