/// `pgadmin/misc/bgprocess`: background utility processes (backup, restore...). The process list is kept in the
/// `process` table of the configuration database.
module pgadmin.misc.bgprocess;

import pgadmin.core.i18n;
import pgadmin.core.value;
import pgadmin.misc.bgprocess.processes;
import pgadmin.model : db;
import pgadmin.web.auth;
import pgadmin.web.context;
import pgadmin.web.flask;
import pgadmin.web.http;

final class BGProcessModule : Blueprint
{
    this()
    {
        super("bgprocess", "/misc/bgprocess");
    }

    override string[] getExposedUrlEndpoints()
    {
        return ["bgprocess.status", "bgprocess.detailed_status", "bgprocess.acknowledge", "bgprocess.list",
            "bgprocess.stop_process", "bgprocess.update_cloud_details"];
    }

    override void setup()
    {
        route("/", "list", ["GET"], loginRequired((Dict a) => makeResponse(BatchProcess.list())));
        auto statusView = loginRequired((Dict a) {
            try
            {
                auto process = BatchProcess.retrieve(a["pid"].toString);
                long outPos = a.has("out") ? a["out"].integer : -1;
                long errPos = a.has("err") ? a["err"].integer : -1;
                return makeResponse(process.status(outPos, errPos));
            }
            catch (LookupError e)
                return gone(e.msg);
        });
        route("/<pid>", "status", ["GET"], statusView);
        route("/<pid>/<int:out>/<int:err>/", "detailed_status", ["GET"], statusView);
        route("/<pid>", "acknowledge", ["PUT"], loginRequired((Dict a) {
            try
            {
                BatchProcess.acknowledge(a["pid"].toString);
                return successReturn();
            }
            catch (LookupError e)
                return gone(e.msg);
        }));
        route("/stop/<pid>", "stop_process", ["PUT"], loginRequired((Dict a) {
            try
            {
                BatchProcess.stopProcess(a["pid"].toString);
                return successReturn();
            }
            catch (LookupError e)
                return gone(e.msg);
        }));
        route("/update_cloud_details/<pid>", "update_cloud_details", ["PUT"], loginRequired((Dict a) {
            try
            {
                BatchProcess.retrieve(a["pid"].toString);
                return successReturn();
            }
            catch (LookupError e)
                return gone(e.msg);
        }));
    }
}
