/// The node modules below a table (`TableModule.register`), in the Python order.
module pgadmin.browser.server_groups.servers.databases.schemas.tables.registry;

import pgadmin.browser.utils : sharedModule;
import pgadmin.browser.server_groups.servers.databases.schemas.tables : TableModule;
import pgadmin.browser.server_groups.servers.databases.schemas.tables.columns : columnsModule;
import pgadmin.browser.server_groups.servers.databases.schemas.tables.compound_triggers : CompoundTriggerModule;
import pgadmin.browser.server_groups.servers.databases.schemas.tables.constraints : ConstraintsModule;
import pgadmin.browser.server_groups.servers.databases.schemas.tables.indexes : IndexesModule;
import pgadmin.browser.server_groups.servers.databases.schemas.tables.partitions : PartitionsModule;
import pgadmin.browser.server_groups.servers.databases.schemas.tables.row_security_policies : RowSecurityModule;
import pgadmin.browser.server_groups.servers.databases.schemas.tables.rules : RuleModule;
import pgadmin.browser.server_groups.servers.databases.schemas.tables.triggers : TriggerModule;

void registerTableSubmodules(TableModule m)
{
    m.submodules ~= columnsModule();
    m.submodules ~= sharedModule!CompoundTriggerModule();
    m.submodules ~= sharedModule!ConstraintsModule();
    m.submodules ~= sharedModule!IndexesModule();
    m.submodules ~= new PartitionsModule;
    m.submodules ~= new RowSecurityModule;
    m.submodules ~= sharedModule!RuleModule();
    m.submodules ~= sharedModule!TriggerModule();
}
