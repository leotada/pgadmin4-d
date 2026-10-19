/// The node modules below a schema (`SchemaModule.register`). Modules are added as they are ported.
module pgadmin.browser.server_groups.servers.databases.schemas.registry;

import pgadmin.browser.server_groups.servers.databases.schemas : SchemaModule;
import pgadmin.browser.server_groups.servers.databases.schemas.aggregates : AggregateModule;
import pgadmin.browser.server_groups.servers.databases.schemas.catalog_objects : CatalogObjectModule;
import pgadmin.browser.server_groups.servers.databases.schemas.collations : CollationModule;
import pgadmin.browser.server_groups.servers.databases.schemas.domains : DomainModule;
import pgadmin.browser.server_groups.servers.databases.schemas.fts_configurations : FtsConfigurationModule;
import pgadmin.browser.server_groups.servers.databases.schemas.fts_dictionaries : FtsDictionaryModule;
import pgadmin.browser.server_groups.servers.databases.schemas.fts_parsers : FtsParserModule;
import pgadmin.browser.server_groups.servers.databases.schemas.fts_templates : FtsTemplateModule;
import pgadmin.browser.server_groups.servers.databases.schemas.tables : TableModule;
import pgadmin.browser.server_groups.servers.databases.schemas.views : ViewModule, MViewModule;
import pgadmin.browser.server_groups.servers.databases.schemas.foreign_tables : ForeignTableModule;
import pgadmin.browser.server_groups.servers.databases.schemas.types : TypeModule;
import pgadmin.browser.server_groups.servers.databases.schemas.functions : FunctionModule, ProcedureModule, TriggerFunctionModule;
import pgadmin.browser.server_groups.servers.databases.schemas.operators : OperatorModule;
import pgadmin.browser.server_groups.servers.databases.schemas.sequences : SequenceModule;
import pgadmin.browser.server_groups.servers.databases.schemas.synonyms : SynonymModule;
import pgadmin.browser.server_groups.servers.databases.schemas.packages : PackageModule;

void registerSchemaSubmodules(SchemaModule m)
{
    m.submodules ~= new AggregateModule;
    m.submodules ~= new CatalogObjectModule;
    m.submodules ~= new CollationModule;
    m.submodules ~= new DomainModule;
    m.submodules ~= new FtsConfigurationModule;
    m.submodules ~= new FtsDictionaryModule;
    m.submodules ~= new FtsParserModule;
    m.submodules ~= new FtsTemplateModule;
    m.submodules ~= new FunctionModule;
    m.submodules ~= new ProcedureModule;
    m.submodules ~= new TriggerFunctionModule;
    m.submodules ~= new OperatorModule;
    m.submodules ~= new TableModule;
    m.submodules ~= new TypeModule;
    m.submodules ~= new ForeignTableModule;
    m.submodules ~= new ViewModule;
    m.submodules ~= new MViewModule;
    m.submodules ~= new SequenceModule;
    m.submodules ~= new SynonymModule;
    m.submodules ~= new PackageModule;
}
