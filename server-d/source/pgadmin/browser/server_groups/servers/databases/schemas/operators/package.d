/// `schemas/operators`: operators (read-only).
module pgadmin.browser.server_groups.servers.databases.schemas.operators;

import std.string : strip;
import pgadmin.browser.server_groups.servers.databases.schemas.utils;
import pgadmin.browser.utils;
import pgadmin.core.value;
import pgadmin.core.templates : tv;

final class OperatorModule : SchemaChildModule
{
    enum NODE_TYPE = "operator";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "Operators";
        minVer = Value(90100);
        maxVer = Value(null);
        staticDir("browser/server_groups/servers/databases/schemas/operators");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => "database";
    override bool nodeInode() => false;

    override Value[] getNodes(Dict kwargs)
    {
        if (hasNodes(kwargs["sid"], kwargs["did"], kwargs["scid"], Value(null), Value(null), OperatorView.BASE))
            return [generateBrowserCollectionNode(kwargs["scid"])];
        return null;
    }

    override void setup()
    {
        registerNodeView!OperatorView(this);
    }
}

final class OperatorView : ReadOnlySchemaChildView
{
    enum BASE = "operators/sql/#{0}#";

    this()
    {
        super();
        nodeType = OperatorModule.NODE_TYPE;
        nodeLabel = "Operator";
        ids = [IdSpec("int", "opid")];
        idName = "opid";
        icon = "icon-operator";
        baseTemplate = BASE;
    }

    override string sqlText(Value data)
    {
        auto sql = rt(CREATE_SQL, tv("data", data));
        auto header = "-- Operator: " ~ data["name"].toString ~ ";\n\n-- ";
        header ~= rt(DELETE_SQL, tv("name", data["name"], "oprnamespace", data["schema"], "lefttype", data["lefttype"],
                "righttype", data["righttype"]));
        return header ~ "\n" ~ sql.strip("\n");
    }
}
