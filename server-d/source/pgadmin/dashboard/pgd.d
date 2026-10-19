/// `dashboard/pgd_replication`: EDB Postgres Distributed replication panels of the dashboard.
module pgadmin.dashboard.pgd;

import std.conv : to;
import std.string : split;
import pgadmin.core.i18n;
import pgadmin.core.templates : renderTemplate;
import pgadmin.core.value;
import pgadmin.db.driver;
import pgadmin.utils.constants;
import pgadmin.web.auth;
import pgadmin.web.context;
import pgadmin.web.flask;
import pgadmin.web.http;

final class PGDReplicationDashboard : Blueprint
{
    this()
    {
        super("dashboard.pgd", "/dashboard/pgd");
    }

    override void setup()
    {
        route("/cluster_nodes/<int:sid>", "cluster_nodes", ["GET"], rowsView("cluster_nodes", "pgd_cluster_nodes.sql"));
        route("/raft_status/<int:sid>", "raft_status", ["GET"], rowsView("raft_status", "pgd_raft_status.sql"));
        route("/outgoing/<int:sid>", "outgoing", ["GET"], rowsView("outgoing", "pgd_outgoing.sql"));
        route("/incoming/<int:sid>", "incoming", ["GET"], rowsView("incoming", "pgd_incoming.sql"));
        route("/charts/<int:sid>", "charts", ["GET"], loginRequired((Dict a) {
            auto manager = getDriver().connectionManagerOrNull(a["sid"].integer);
            if (manager is null)
                return preconditionRequired(gettext("Please connect to the selected server to view the graph."));
            if (manager is null)
                return preconditionRequired(gettext("Please connect to the selected server to view the graph."));
            auto conn = manager.connection();
            if (!conn.connected())
                return preconditionRequired(gettext("Please connect to the selected server to view the graph."));
            auto templatePath = "dashboard/sql/#" ~ to!string(manager.version_) ~ "#";
            auto args = request().args;
            if (!args.has("chart_names"))
                throw new HTTPException(400);
            auto resp = Value.newDict();
            if (args.get("chart_names") != "")
            {
                Value[] cv;
                foreach (c; args.get("chart_names").split(","))
                    cv ~= Value(c);
                auto r = conn.executeDict(renderTemplate(templatePath ~ "/pgd_charts.sql", ["chart_names": Value(cv)]));
                if (!r.ok)
                    return internalServerError(r.error);
                foreach (row; r.value["rows"].list.items)
                    resp[row["chart_name"].toString] = row["chart_data"].isString ? parseJson(row["chart_data"].str) : row["chart_data"];
            }
            return makeResponse(resp, 200);
        }));
    }

    private View rowsView(string fname, string tmpl)
    {
        return loginRequired((Dict a) {
            auto manager = getDriver().connectionManagerOrNull(a["sid"].integer);
            if (manager is null)
                return preconditionRequired(gettext("Please connect to the selected server to view the graph."));
            auto conn = manager.connection();
            if (!conn.connected())
                return preconditionRequired(gettext("Please connect to the selected server to view the graph."));
            auto templatePath = "dashboard/sql/#" ~ to!string(manager.version_) ~ "#";
            auto r = conn.executeDict(renderTemplate(templatePath ~ "/" ~ tmpl));
            if (!r.ok)
                return internalServerError(r.error);
            return makeResponse(r.value["rows"], 200);
        });
    }
}
