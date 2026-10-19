/// Which node modules hang below a database (`DatabaseModule.register`). Modules are added as they are ported.
module pgadmin.browser.server_groups.servers.databases.registry;

import pgadmin.browser.server_groups.servers.databases : DatabaseModule;
import pgadmin.browser.server_groups.servers.databases.casts : CastModule;
import pgadmin.browser.server_groups.servers.databases.event_triggers : EventTriggerModule;
import pgadmin.browser.server_groups.servers.databases.extensions : ExtensionModule;
import pgadmin.browser.server_groups.servers.databases.foreign_data_wrappers : ForeignDataWrapperModule;
import pgadmin.browser.server_groups.servers.databases.languages : LanguageModule;
import pgadmin.browser.server_groups.servers.databases.publications : PublicationModule;
import pgadmin.browser.server_groups.servers.databases.subscriptions : SubscriptionModule;
import pgadmin.browser.server_groups.servers.databases.schemas : SchemaModule;
import pgadmin.browser.server_groups.servers.databases.dbms_job_scheduler : DBMSJobSchedulerModule;

void registerDatabaseSubmodules(DatabaseModule m)
{
    m.submodules ~= new CastModule;
    m.submodules ~= new EventTriggerModule;
    m.submodules ~= new ExtensionModule;
    m.submodules ~= new ForeignDataWrapperModule;
    m.submodules ~= new LanguageModule;
    m.submodules ~= new PublicationModule;
    m.submodules ~= new SubscriptionModule;
    m.submodules ~= new SchemaModule("schema", "Schemas");
    m.submodules ~= new SchemaModule("catalog", "Catalogs");
    m.submodules ~= new DBMSJobSchedulerModule;
}
