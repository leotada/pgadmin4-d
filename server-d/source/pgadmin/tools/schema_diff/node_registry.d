/// `pgadmin/tools/schema_diff/node_registry`: Node registry for schema comparison.
module pgadmin.tools.schema_diff.node_registry;

import pgadmin.browser.utils : NodeView, makeView;

import pgadmin.browser.server_groups.servers : ServerNode;
import pgadmin.browser.server_groups.servers.databases : DatabaseView;
import pgadmin.browser.server_groups.servers.databases.schemas : SchemaView;
import pgadmin.browser.server_groups.servers.databases.casts : CastView;
import pgadmin.browser.server_groups.servers.databases.event_triggers : EventTriggerView;
import pgadmin.browser.server_groups.servers.databases.extensions : ExtensionView;
import pgadmin.browser.server_groups.servers.databases.foreign_data_wrappers : ForeignDataWrapperView;
import pgadmin.browser.server_groups.servers.databases.foreign_data_wrappers.foreign_servers : ForeignServerView;
import pgadmin.browser.server_groups.servers.databases.foreign_data_wrappers.foreign_servers.user_mappings : UserMappingView;
import pgadmin.browser.server_groups.servers.databases.languages : LanguageView;
import pgadmin.browser.server_groups.servers.databases.publications : PublicationView;
import pgadmin.browser.server_groups.servers.databases.subscriptions : SubscriptionView;

import pgadmin.browser.server_groups.servers.databases.schemas.collations : CollationView;
import pgadmin.browser.server_groups.servers.databases.schemas.domains : DomainView;
import pgadmin.browser.server_groups.servers.databases.schemas.foreign_tables : ForeignTableView;
import pgadmin.browser.server_groups.servers.databases.schemas.fts_configurations : FtsConfigurationView;
import pgadmin.browser.server_groups.servers.databases.schemas.fts_dictionaries : FtsDictionaryView;
import pgadmin.browser.server_groups.servers.databases.schemas.fts_parsers : FtsParserView;
import pgadmin.browser.server_groups.servers.databases.schemas.fts_templates : FtsTemplateView;
import pgadmin.browser.server_groups.servers.databases.schemas.functions : FunctionView, ProcedureView, TriggerFunctionView;
import pgadmin.browser.server_groups.servers.databases.schemas.packages : PackageView;
import pgadmin.browser.server_groups.servers.databases.schemas.sequences : SequenceView;
import pgadmin.browser.server_groups.servers.databases.schemas.synonyms : SynonymView;
import pgadmin.browser.server_groups.servers.databases.schemas.tables : TableView;
import pgadmin.browser.server_groups.servers.databases.schemas.views : ViewNode, MViewNode;
import pgadmin.browser.server_groups.servers.databases.schemas.types : TypeView;

import pgadmin.browser.server_groups.servers.databases.schemas.tables.rules : RuleView;
import pgadmin.browser.server_groups.servers.databases.schemas.tables.row_security_policies : RowSecurityView;
import pgadmin.browser.server_groups.servers.databases.schemas.tables.indexes : IndexesView;
import pgadmin.browser.server_groups.servers.databases.schemas.tables.partitions : PartitionsView;
import pgadmin.browser.server_groups.servers.databases.schemas.tables.triggers : TriggerView;
import pgadmin.browser.server_groups.servers.databases.schemas.tables.compound_triggers : CompoundTriggerView;

struct RegisteredNode
{
    string nodeName;
    string parentNode;
    NodeView delegate() factory;
}

final class SchemaDiffRegistry
{
    private static RegisteredNode[string] _registeredNodes;
    private static string _compareMode;

    static void registerNode(string nodeName, NodeView delegate() factory, string parentNode = "schema")
    {
        _registeredNodes[nodeName] = RegisteredNode(nodeName, parentNode, factory);
    }

    static void register(T : NodeView)(string nodeName, string parentNode = "schema")
    {
        registerNode(nodeName, () => makeView!T(), parentNode);
    }

    static NodeView getNodeView(string nodeName)
    {
        if (auto p = nodeName in _registeredNodes)
            return p.factory();
        return null;
    }

    static RegisteredNode[string] getRegisteredNodes(string nodeName = null, string parentNode = "schema")
    {
        RegisteredNode[string] result;
        if (nodeName.length)
        {
            if (auto p = nodeName in _registeredNodes)
                result[nodeName] = *p;
            return result;
        }
        foreach (k, v; _registeredNodes)
        {
            if (v.parentNode == parentNode)
                result[k] = v;
        }
        return result;
    }

    static void setSchemaDiffCompareMode(string mode)
    {
        _compareMode = mode;
    }

    static string getSchemaDiffCompareMode()
    {
        return _compareMode;
    }
}

/// Register all default schema diff nodes supported in pgAdmin 4.
void registerDefaultSchemaDiffNodes()
{
    // Root nodes
    SchemaDiffRegistry.register!ServerNode("server", "server");
    SchemaDiffRegistry.register!DatabaseView("database", "server");
    SchemaDiffRegistry.register!SchemaView("schema", "database");

    // Database objects (parent: "Database")
    SchemaDiffRegistry.register!CastView("cast", "Database");
    SchemaDiffRegistry.register!EventTriggerView("event_trigger", "Database");
    SchemaDiffRegistry.register!ExtensionView("extension", "Database");
    SchemaDiffRegistry.register!ForeignDataWrapperView("foreign_data_wrapper", "Database");
    SchemaDiffRegistry.register!ForeignServerView("foreign_server", "Database");
    SchemaDiffRegistry.register!UserMappingView("user_mapping", "Database");
    SchemaDiffRegistry.register!LanguageView("language", "Database");
    SchemaDiffRegistry.register!PublicationView("publication", "Database");
    SchemaDiffRegistry.register!SubscriptionView("subscription", "Database");

    // Schema objects (parent: "schema")
    SchemaDiffRegistry.register!CollationView("collation", "schema");
    SchemaDiffRegistry.register!DomainView("domain", "schema");
    SchemaDiffRegistry.register!ForeignTableView("foreign_table", "schema");
    SchemaDiffRegistry.register!FtsConfigurationView("fts_configuration", "schema");
    SchemaDiffRegistry.register!FtsDictionaryView("fts_dictionary", "schema");
    SchemaDiffRegistry.register!FtsParserView("fts_parser", "schema");
    SchemaDiffRegistry.register!FtsTemplateView("fts_template", "schema");
    SchemaDiffRegistry.register!FunctionView("function", "schema");
    SchemaDiffRegistry.register!ProcedureView("procedure", "schema");
    SchemaDiffRegistry.register!TriggerFunctionView("trigger_function", "schema");
    SchemaDiffRegistry.register!PackageView("package", "schema");
    SchemaDiffRegistry.register!SequenceView("sequence", "schema");
    SchemaDiffRegistry.register!SynonymView("synonym", "schema");
    SchemaDiffRegistry.register!TableView("table", "schema");
    SchemaDiffRegistry.register!ViewNode("view", "schema");
    SchemaDiffRegistry.register!MViewNode("mview", "schema");
    SchemaDiffRegistry.register!TypeView("type", "schema");

    // Table objects (parent: "table")
    SchemaDiffRegistry.register!RuleView("rule", "table");
    SchemaDiffRegistry.register!RowSecurityView("row_security_policy", "table");
    SchemaDiffRegistry.register!IndexesView("index", "table");
    SchemaDiffRegistry.register!PartitionsView("partition", "table");
    SchemaDiffRegistry.register!TriggerView("trigger", "table");
    SchemaDiffRegistry.register!CompoundTriggerView("compound_trigger", "table");
}
