/// `pgadmin/misc/workspaces`: workspace adhoc connections and layout switching.
module pgadmin.misc.workspaces;

import std.conv : to;
import std.string : strip;
import pgadmin.browser.server_groups.servers : ServerNode;
import pgadmin.browser.server_groups.servers.utils : disconnectFromAllServers, deleteAdhocServers, isValidIpAddress, checkSslFields;
import pgadmin.browser.utils : makeView;
import pgadmin.core.config;
import pgadmin.core.i18n;
import pgadmin.core.log;
import pgadmin.core.value;
import pgadmin.model;
import pgadmin.db.driver : getServer;
import pgadmin.web.auth;
import pgadmin.web.context;
import pgadmin.web.flask;
import pgadmin.web.http;

final class WorkspaceModule : Blueprint
{
    this()
    {
        super("workspace", "/misc/workspace");
    }

    override string[] getExposedUrlEndpoints()
    {
        return [
            "workspace.adhoc_connect_server",
            "workspace.layout_changed"
        ];
    }

    override void setup()
    {
        route("/", "index", ["GET"], loginRequired((Dict a) {
            return badRequest(gettext("This URL cannot be requested directly."));
        }));

        route("/adhoc_connect_server", "adhoc_connect_server", ["POST"], loginRequired((Dict a) {
            auto data = jsonBody(request());
            if (!data.isDict)
                data = request().form.toDict();

            // Check required fields
            if (!data.contains("server_name") || !data.contains("did"))
                return makeJsonResponse(0, Value(gettext("Could not find the required parameter.")), Value(""), Value(null), Value(null), 410);

            bool hasService = data.contains("service") && data["service"].toString.length > 0;
            if (!hasService)
            {
                foreach (f; ["host", "port", "user"])
                {
                    if (!data.contains(f) || data[f].toString.length == 0)
                        return makeJsonResponse(0, Value(gettext("Could not find the required parameter.")), Value(""), Value(null), Value(null), 410);
                }
            }

            auto rawParams = data.get("connection_params", Value(null));
            if (rawParams.isDict && rawParams.contains("hostaddr"))
            {
                if (!isValidIpAddress(rawParams["hostaddr"].toString))
                    return makeJsonResponse(0, Value(gettext("Not a valid Host address")), Value(""), Value(null), Value(null), 400);
            }

            string host = data.contains("host") ? data["host"].toString : null;
            long port = data.contains("port") ? data["port"].integer : 0;
            string dbName = data.contains("database_name") && data["database_name"].toString.length
                ? data["database_name"].toString : data["did"].toString;
            string username = data.contains("user") ? data["user"].toString : null;
            string role = data.contains("role") && data["role"].toString.length ? data["role"].toString : null;
            string serverName = data["server_name"].toString;
            string service = hasService ? data["service"].toString : null;
            auto uid = currentUserId();

            try
            {
                // Look for an existing adhoc server matching these properties
                auto existing = db.queryOne(
                    "SELECT * FROM server WHERE host IS ? AND port = ? AND maintenance_db = ? AND username IS ? AND name = ? AND user_id = ?",
                    Value(host), Value(port), Value(dbName), Value(username), Value(serverName), Value(uid)
                );

                Value serverRow;
                if (!existing.isNone)
                    serverRow = existing;
                else if (data.contains("sid") && data["sid"].integer > 0)
                {
                    auto src = getServer(data["sid"].integer);
                    if (src.isNone)
                        return badRequest(gettext("Could not find the required server."));

                    auto cloned = Value.newDict();
                    foreach (k; src.dict.keys)
                        cloned[k] = src[k];

                    cloned["user_id"] = Value(uid);
                    cloned["shared"] = Value(0);
                    cloned["shared_username"] = Value(null);
                    cloned["password"] = Value(null);
                    cloned["save_password"] = Value(0);
                    cloned["tunnel_password"] = Value(null);
                    cloned["maintenance_db"] = Value(dbName);
                    cloned["username"] = Value(username);
                    cloned["role"] = Value(role);
                    cloned["is_adhoc"] = Value(1);
                    cloned.dict.remove("id");

                    long newSid = insertRow("server", Value(cloned));
                    serverRow = db.queryOne("SELECT * FROM server WHERE id = ?", Value(newSid));
                }
                else
                {
                    long gid = data.contains("gid") ? data["gid"].integer : 1;
                    long newSid = insertRow("server", Value.dictOf(
                        "user_id", uid,
                        "servergroup_id", gid,
                        "name", serverName,
                        "host", host,
                        "port", port,
                        "maintenance_db", dbName,
                        "username", username,
                        "role", role,
                        "service", service,
                        "is_adhoc", 1
                    ));
                    serverRow = db.queryOne("SELECT * FROM server WHERE id = ?", Value(newSid));
                }

                auto view = makeView!ServerNode();
                long sidVal = serverRow["id"].integer;
                return view.connect(Value(1), Value(sidVal), false, serverRow);
            }
            catch (Exception e)
            {
                logException(e);
                return makeJsonResponse(0, Value(e.msg), Value(""), Value(null), Value(null), 410);
            }
        }));

        route("/layout_changed", "layout_changed", ["DELETE"], loginRequired((Dict a) {
            disconnectFromAllServers();
            deleteAdhocServers();
            return makeJsonResponse(1);
        }));
    }
}
