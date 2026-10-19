/// `pgadmin/tools/import_export_servers`: import and export server definitions to JSON.
module pgadmin.tools.import_export_servers;

import std.algorithm : canFind, endsWith;
import std.conv : to;
import std.file : exists, isFile, readText, write;
import std.path : extension;
import std.random : uniform;
import std.string : indexOf, strip;
import std.uri : decodeComponent;
import pgadmin.core.config;
import pgadmin.core.i18n;
import pgadmin.core.log;
import pgadmin.core.value;
import pgadmin.model;
import pgadmin.utils.constants;
import pgadmin.utils.paths : getCompleteFilePath;
import pgadmin.web.auth;
import pgadmin.web.context;
import pgadmin.web.flask;
import pgadmin.web.http;

final class ImportExportServersModule : Blueprint
{
    this()
    {
        super("import_export_servers");
        label = Value(gettext("Import/Export Servers"));
    }

    override string[] getExposedUrlEndpoints()
    {
        return [
            "import_export_servers.get_servers",
            "import_export_servers.load_servers",
            "import_export_servers.save"
        ];
    }

    override void setup()
    {
        route("/", "index", ["GET"], loginRequired((Dict a) => badRequest(gettext("This URL cannot be called directly."))));

        route("/get_servers", "get_servers", ["GET"], permissionsRequired(loginRequired((Dict a) {
            auto uid = currentUserId();
            auto groups = db.query("SELECT * FROM servergroup WHERE user_id = ? ORDER BY id", Value(uid));
            Value[] allServers;
            foreach (g; groups)
            {
                auto servers = db.query("SELECT id, name FROM server WHERE user_id = ? AND servergroup_id = ? AND is_adhoc = 0 ORDER BY name",
                        Value(uid), g["id"]);
                Value[] children;
                foreach (s; servers)
                    children ~= Value.dictOf("value", s["id"], "label", s["name"]);
                if (children.length > 0)
                    allServers ~= Value.dictOf("value", g["name"], "label", g["name"], "children", Value(children));
            }
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(allServers));
        }), "tools_import_export_servers"));

        route("/load_servers", "load_servers", ["POST"], permissionsRequired(loginRequired((Dict a) {
            auto data = jsonBody(request());
            if (!data.isDict)
                data = request().form.toDict();
            if (!data.contains("filename") || data["filename"].toString.length == 0)
                return badRequest(gettext("Missing filename."));

            string filename = decodeComponent(data["filename"].toString);
            string filePath = getCompleteFilePath(filename, true);
            if (filePath is null || !filePath.exists)
                return internalServerError(gettext("The specified file does not exist."));

            try
            {
                string content = readText(filePath);
                auto parsed = tryParseJson(content, Value.undefined);
                if (!parsed.isDict || !parsed.contains("Servers") || !parsed["Servers"].isDict)
                    return internalServerError(gettext("The specified file is not in the correct format."));

                Value[string] groupsDict;
                Value[][string] groupChildren;

                foreach (serverKey, serverVal; parsed["Servers"].dict)
                {
                    if (!serverVal.isDict)
                        continue;
                    string groupName = serverVal.contains("Group") ? serverVal["Group"].toString : "Servers";
                    string serverName = serverVal.contains("Name") ? serverVal["Name"].toString : serverKey;
                    string serverId = serverKey ~ "_" ~ to!string(uniform(1, 9999));
                    groupChildren[groupName] ~= Value.dictOf("value", serverId, "label", serverName);
                }

                Value[] allServers;
                foreach (groupName, children; groupChildren)
                {
                    allServers ~= Value.dictOf(
                        "value", groupName,
                        "label", groupName,
                        "children", Value(children)
                    );
                }
                return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(allServers));
            }
            catch (Exception e)
            {
                return internalServerError(gettext("Unable to load the specified file.") ~ ": " ~ e.msg);
            }
        }), "tools_import_export_servers"));

        route("/save", "save", ["POST"], permissionsRequired(loginRequired((Dict a) {
            auto data = jsonBody(request());
            if (!data.isDict)
                data = request().form.toDict();

            if (!data.contains("type") || !data.contains("filename"))
                return makeJsonResponse(0, Value(gettext("Could not find the required parameter.")), Value(""), Value(null), Value(null), 410);

            string type = data["type"].toString;
            string rawFilename = decodeComponent(data["filename"].toString);
            string selectedKey = data.contains("selected_sever_ids") ? "selected_sever_ids" : "selected_server_ids";
            Value selected = data.contains(selectedKey) ? data[selectedKey] : Value(null);

            if (type == "export")
            {
                if (rawFilename.extension != ".json")
                    rawFilename ~= ".json";
                string outPath = getCompleteFilePath(rawFilename, false);
                if (outPath is null)
                    return internalServerError(gettext("Invalid destination path."));
                auto err = dumpServers(outPath, selected);
                if (err.length)
                    return internalServerError(err);
                return makeJsonResponse(1);
            }
            else if (type == "import")
            {
                string inPath = getCompleteFilePath(rawFilename, true);
                if (inPath is null || !inPath.exists)
                    return internalServerError(gettext("The specified file does not exist."));

                bool replace = data.contains("replace_servers") && data["replace_servers"].truthy;
                auto err = loadServers(inPath, selected, replace);
                if (err.length)
                    return internalServerError(err);
                return makeJsonResponse(1);
            }
            return badRequest(gettext("Invalid type parameter."));
        }), "tools_import_export_servers"));
    }
}

private string dumpServers(string outPath, Value selectedIds)
{
    try
    {
        auto uid = currentUserId();
        auto servers = db.query("SELECT * FROM server WHERE user_id = ? AND is_adhoc = 0", Value(uid));
        auto groups = db.query("SELECT * FROM servergroup WHERE user_id = ?", Value(uid));
        string[long] groupNames;
        foreach (g; groups)
            groupNames[g["id"].integer] = g["name"].str;

        string[] selected;
        if (selectedIds.isList)
            foreach (v; selectedIds.list.items)
                selected ~= v.toString;

        auto serversDict = new Dict;
        long idx = 0;
        foreach (s; servers)
        {
            auto sidStr = s["id"].toString;
            if (selected.length > 0 && !selected.canFind(sidStr))
                continue;
            idx++;
            long gid = s["servergroup_id"].integer;
            string gName = (gid in groupNames) ? groupNames[gid] : "Servers";

            auto d = new Dict;
            d["Name"] = s["name"];
            d["Group"] = Value(gName);
            if (s.contains("host") && !s["host"].isNone)
                d["Host"] = s["host"];
            if (s.contains("port") && !s["port"].isNone)
                d["Port"] = s["port"];
            if (s.contains("maintenance_db") && !s["maintenance_db"].isNone)
                d["MaintenanceDB"] = s["maintenance_db"];
            if (s.contains("username") && !s["username"].isNone)
                d["Username"] = s["username"];
            if (s.contains("role") && !s["role"].isNone)
                d["Role"] = s["role"];
            if (s.contains("comment") && !s["comment"].isNone)
                d["Comment"] = s["comment"];
            if (s.contains("shared") && !s["shared"].isNone)
                d["Shared"] = s["shared"];
            if (s.contains("shared_username") && !s["shared_username"].isNone)
                d["SharedUsername"] = s["shared_username"];
            if (s.contains("db_res") && !s["db_res"].isNone)
                d["DBRestriction"] = s["db_res"];
            if (s.contains("db_res_type") && !s["db_res_type"].isNone)
                d["DBRestrictionType"] = s["db_res_type"];
            if (s.contains("bgcolor") && !s["bgcolor"].isNone)
                d["BGColor"] = s["bgcolor"];
            if (s.contains("fgcolor") && !s["fgcolor"].isNone)
                d["FGColor"] = s["fgcolor"];
            if (s.contains("service") && !s["service"].isNone)
                d["Service"] = s["service"];
            if (s.contains("use_ssh_tunnel") && !s["use_ssh_tunnel"].isNone)
                d["UseSSHTunnel"] = s["use_ssh_tunnel"];
            if (s.contains("tunnel_host") && !s["tunnel_host"].isNone)
                d["TunnelHost"] = s["tunnel_host"];
            if (s.contains("tunnel_port") && !s["tunnel_port"].isNone)
                d["TunnelPort"] = s["tunnel_port"];
            if (s.contains("tunnel_username") && !s["tunnel_username"].isNone)
                d["TunnelUsername"] = s["tunnel_username"];
            if (s.contains("tunnel_authentication") && !s["tunnel_authentication"].isNone)
                d["TunnelAuthentication"] = s["tunnel_authentication"];
            if (s.contains("tunnel_identity_file") && !s["tunnel_identity_file"].isNone)
                d["TunnelIdentityFile"] = s["tunnel_identity_file"];
            if (s.contains("tunnel_prompt_password") && !s["tunnel_prompt_password"].isNone)
                d["TunnelPromptPassword"] = s["tunnel_prompt_password"];
            if (s.contains("tunnel_keep_alive") && !s["tunnel_keep_alive"].isNone)
                d["TunnelKeepAlive"] = s["tunnel_keep_alive"];
            if (s.contains("kerberos_conn") && !s["kerberos_conn"].isNone)
                d["KerberosAuthentication"] = s["kerberos_conn"];
            if (s.contains("connection_params") && !s["connection_params"].isNone)
                d["ConnectionParameters"] = s["connection_params"];
            if (s.contains("tags") && !s["tags"].isNone)
                d["Tags"] = s["tags"];

            serversDict[to!string(idx)] = Value(d);
        }

        auto root = Value.dictOf("Servers", Value(serversDict));
        write(outPath, root.toJson());
        return null;
    }
    catch (Exception e)
    {
        return e.msg;
    }
}

private string loadServers(string inPath, Value selectedIds, bool replaceServers)
{
    try
    {
        auto uid = currentUserId();
        string content = readText(inPath);
        auto parsed = tryParseJson(content, Value.undefined);
        if (!parsed.isDict || !parsed.contains("Servers") || !parsed["Servers"].isDict)
            return gettext("The specified file is not in the correct format.");

        if (replaceServers)
            db.exec("DELETE FROM server WHERE user_id = ?", Value(uid));

        string[] selected;
        if (selectedIds.isList)
            foreach (v; selectedIds.list.items)
            {
                auto s = v.toString;
                auto usIdx = s.indexOf('_');
                selected ~= usIdx != -1 ? s[0 .. usIdx] : s;
            }

        auto curGroups = db.query("SELECT * FROM servergroup WHERE user_id = ?", Value(uid));
        long[string] groupIdsByName;
        foreach (g; curGroups)
            groupIdsByName[g["name"].str] = g["id"].integer;

        foreach (serverKey, serverVal; parsed["Servers"].dict)
        {
            if (selected.length > 0 && !selected.canFind(serverKey))
                continue;
            if (!serverVal.isDict)
                continue;

            string gName = serverVal.contains("Group") ? serverVal["Group"].toString : "Servers";
            long gid;
            if (gName in groupIdsByName)
                gid = groupIdsByName[gName];
            else
            {
                gid = insertRow("servergroup", Value.dictOf("user_id", uid, "name", gName));
                groupIdsByName[gName] = gid;
            }

            auto sRow = Value.newDict();
            sRow["user_id"] = Value(uid);
            sRow["servergroup_id"] = Value(gid);
            sRow["name"] = serverVal.get("Name", Value(serverKey));
            sRow["maintenance_db"] = serverVal.get("MaintenanceDB", Value("postgres"));

            if (serverVal.contains("Host"))
                sRow["host"] = serverVal["Host"];
            if (serverVal.contains("Port"))
                sRow["port"] = serverVal["Port"];
            if (serverVal.contains("Username"))
                sRow["username"] = serverVal["Username"];
            if (serverVal.contains("Role"))
                sRow["role"] = serverVal["Role"];
            if (serverVal.contains("Comment"))
                sRow["comment"] = serverVal["Comment"];
            if (serverVal.contains("Shared") && currentUserHasRole("Administrator"))
                sRow["shared"] = serverVal["Shared"];
            if (serverVal.contains("SharedUsername"))
                sRow["shared_username"] = serverVal["SharedUsername"];
            if (serverVal.contains("DBRestriction"))
                sRow["db_res"] = serverVal["DBRestriction"];
            if (serverVal.contains("DBRestrictionType"))
                sRow["db_res_type"] = serverVal["DBRestrictionType"];
            if (serverVal.contains("BGColor"))
                sRow["bgcolor"] = serverVal["BGColor"];
            if (serverVal.contains("FGColor"))
                sRow["fgcolor"] = serverVal["FGColor"];
            if (serverVal.contains("Service"))
                sRow["service"] = serverVal["Service"];
            if (serverVal.contains("UseSSHTunnel"))
                sRow["use_ssh_tunnel"] = serverVal["UseSSHTunnel"];
            if (serverVal.contains("TunnelHost"))
                sRow["tunnel_host"] = serverVal["TunnelHost"];
            if (serverVal.contains("TunnelPort"))
                sRow["tunnel_port"] = serverVal["TunnelPort"];
            if (serverVal.contains("TunnelUsername"))
                sRow["tunnel_username"] = serverVal["TunnelUsername"];
            if (serverVal.contains("TunnelAuthentication"))
                sRow["tunnel_authentication"] = serverVal["TunnelAuthentication"];
            if (serverVal.contains("TunnelIdentityFile"))
                sRow["tunnel_identity_file"] = serverVal["TunnelIdentityFile"];
            if (serverVal.contains("TunnelPromptPassword"))
                sRow["tunnel_prompt_password"] = serverVal["TunnelPromptPassword"];
            if (serverVal.contains("TunnelKeepAlive"))
                sRow["tunnel_keep_alive"] = serverVal["TunnelKeepAlive"];
            if (serverVal.contains("KerberosAuthentication"))
                sRow["kerberos_conn"] = serverVal["KerberosAuthentication"];
            if (serverVal.contains("ConnectionParameters"))
                sRow["connection_params"] = serverVal["ConnectionParameters"];
            if (serverVal.contains("Tags"))
                sRow["tags"] = serverVal["Tags"];

            insertRow("server", Value(sRow));
        }
        return null;
    }
    catch (Exception e)
    {
        return e.msg;
    }
}
