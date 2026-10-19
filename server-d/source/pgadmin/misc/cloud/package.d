/// `pgadmin/misc/cloud`: Cloud Deployment Wizard (AWS RDS, Azure, Google Cloud).
module pgadmin.misc.cloud;

import std.conv : to;
import std.string : strip;
import pgadmin.core.config;
import pgadmin.core.i18n : gettext;
import pgadmin.core.log : logError, logInfo;
import pgadmin.core.value;
import pgadmin.model : db;
import pgadmin.utils.constants;
import pgadmin.web.auth : loginRequired;
import pgadmin.web.context : request, currentUserId;
import pgadmin.web.flask : Blueprint;
import pgadmin.web.http;

final class CloudModule : Blueprint
{
    this()
    {
        super("cloud", "/misc/cloud");
    }

    override string[] getExposedUrlEndpoints()
    {
        return [
            "cloud.deploy_on_cloud",
            "cloud.update_cloud_server",
            "cloud.update_cloud_process",
            "cloud.get_host_ip",
            "cloud.clear_cloud_session"
        ];
    }

    override void setup()
    {
        route("/", "index", ["GET"], loginRequired((Dict a) {
            return badRequest(gettext("This URL cannot be called directly."));
        }));

        route("/clear_cloud_session/", "clear_cloud_session", ["POST"], loginRequired((Dict a) {
            return makeJsonResponse(1);
        }));

        route("/get_host_ip/", "get_host_ip", ["GET"], loginRequired((Dict a) {
            auto req = request();
            string ip = (req !is null && req.remoteAddr.length) ? req.remoteAddr : "127.0.0.1";
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(ip), 200);
        }));

        route("/deploy", "deploy_on_cloud", ["POST"], loginRequired((Dict a) {
            auto req = request();
            auto body_ = parseJson(req.text);
            if (!body_.isDict || !body_.contains("cloud"))
                return badRequest(gettext("Invalid cloud deployment request."));

            string cloud = body_["cloud"].toString;
            if (cloud != "aws" && cloud != "azure" && cloud != "google")
                return makeJsonResponse(0, Value(gettext("No cloud implementation.")), Value(""), Value(null), Value(null), 410);

            long uid = currentUserId();
            long gid = 1;
            string serverName = "Cloud PostgreSQL (" ~ cloud ~ ")";
            if (body_.contains("db_details") && body_["db_details"].isDict)
            {
                auto dbDetails = body_["db_details"];
                if (dbDetails.contains("gid"))
                    gid = dbDetails["gid"].integer;
                if (dbDetails.contains("name"))
                    serverName = dbDetails["name"].toString;
            }

            db.exec(
                `INSERT INTO server (user_id, servergroup_id, name, host, port, maintenance_db, username, ssl_mode, comment, cloud_status) ` ~
                `VALUES (?, ?, ?, '127.0.0.1', 5432, 'postgres', 'postgres', 'prefer', 'Cloud deployed instance', -1)`,
                Value(uid), Value(gid), Value(serverName)
            );
            long sid = db.lastInsertId();

            auto node = Value.newDict();
            node["_id"] = Value(sid);
            node["_pid"] = Value(gid);
            node["connected"] = Value(false);
            node["_type"] = Value("server");
            node["icon"] = Value("icon-server-cloud-deploy");
            node["id"] = Value("server_" ~ to!string(sid));
            node["inode"] = Value(true);
            node["label"] = Value(serverName);
            node["server_type"] = Value("pg");
            node["module"] = Value("pgadmin.node.server");
            node["cloud_status"] = Value(-1);

            auto resData = Value.newDict();
            resData["job_id"] = Value(sid);
            resData["desc"] = Value("Deploying " ~ serverName);
            resData["node"] = node;

            return makeJsonResponse(1, Value(""), Value(""), Value(null), resData, 200);
        }));

        route("/update_cloud_process/<int:sid>", "update_cloud_process", ["GET"], loginRequired((Dict a) {
            return makeJsonResponse(1);
        }));

        route("/update_cloud_server", "update_cloud_server", ["POST"], loginRequired((Dict a) {
            auto req = request();
            auto body_ = parseJson(req.text);
            if (!body_.isDict || !body_.contains("instance"))
                return badRequest(gettext("Invalid cloud update request."));

            auto inst = body_["instance"];
            long sid = inst.contains("sid") ? inst["sid"].integer : 0;
            string host = inst.contains("Hostname") ? inst["Hostname"].toString : "";
            long port = inst.contains("Port") ? inst["Port"].integer : 5432;
            bool status = inst.contains("status") ? inst["status"].truthy : true;

            long uid = currentUserId();
            auto srv = db.queryOne(`SELECT * FROM server WHERE id = ? AND user_id = ?`, Value(sid), Value(uid));
            if (srv.isNone)
                return makeJsonResponse(0, Value(gettext("Could not find the server.")), Value(""), Value(null), Value(null), 410);

            if (!status)
            {
                db.exec(`DELETE FROM server WHERE id = ?`, Value(sid));
            }
            else
            {
                db.exec(`UPDATE server SET host = ?, port = ?, cloud_status = 1 WHERE id = ?`, Value(host), Value(port), Value(sid));
            }

            auto node = Value.newDict();
            node["sid"] = Value(sid);
            node["gid"] = srv["servergroup_id"];
            node["_type"] = Value("server");
            node["icon"] = Value("icon-server-not-connected");
            node["id"] = Value("server_" ~ to!string(sid));
            node["label"] = srv["name"];

            auto resData = Value.newDict();
            resData["node"] = node;

            return makeJsonResponse(1, Value(""), Value(""), Value(null), resData, 200);
        }));
    }
}
