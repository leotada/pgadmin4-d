/// `pgadmin/misc`: ping, heartbeat, upgrade check, binary path validation and the miscellaneous preferences.
module pgadmin.misc;

import std.algorithm : map;
import std.array : array;
import std.datetime : Clock;
import std.string : replace, toLower, toUpper;
import pgadmin.core.config;
import pgadmin.core.i18n;
import pgadmin.core.log;
import pgadmin.core.value;
import pgadmin.db.driver;
import pgadmin.settings : getSetting, storeSetting;
import pgadmin.utils.constants;
import pgadmin.utils.heartbeat;
import pgadmin.web.auth;
import pgadmin.web.context;
import pgadmin.web.flask;
import pgadmin.web.http;

/// The themes the UI offers (`misc/themes/__init__.py`).
Value getAllThemes()
{
    auto d = new Dict;
    d["light"] = Value.dictOf("disp_name", "Light", "preview_img", "light_preview.png");
    d["dark"] = Value.dictOf("disp_name", "dark", "preview_img", "dark_preview.png");
    d["high_contrast"] = Value.dictOf("disp_name", "high_contrast", "preview_img", "high_contrast_preview.png");
    d["system"] = Value.dictOf("disp_name", "system");
    return Value(d);
}

private string titleCase(string s)
{
    import pgadmin.jinja.runtime : pyTitle;
    return pyTitle(s);
}

final class MiscModule : Blueprint
{
    Blueprint[] subs;

    this()
    {
        super("misc");
        label = Value(gettext("Miscellaneous"));
    }

    override string[] getExposedUrlEndpoints()
    {
        return ["misc.ping", "misc.index", "misc.cleanup", "misc.validate_binary_path", "misc.log_heartbeat",
            "misc.stop_heartbeat", "misc.get_heartbeat", "misc.upgrade_check", "misc.auto_update"];
    }

    override void setup()
    {
        foreach (s; subs)
            submodules ~= s;

        route("/", "index", ["GET"], (Dict a) => new Response(""), false);
        route("/ping", "ping", ["GET"], (Dict a) => new Response("PING"), true);
        route("/cleanup", "cleanup", ["POST"], (Dict a) {
            // driver.ping(): refresh the pinged time of the session's managers
            getDriver().gcTimeout();
            return new Response("");
        }, true);
        route("/heartbeat/log", "log_heartbeat", ["POST"], (Dict a) {
            auto data = jsonBody(request());
            auto r = logServerHeartbeat(data);
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(r.msg), r.ok ? 200 : 404);
        }, true);
        route("/heartbeat/stop", "stop_heartbeat", ["POST"], (Dict a) {
            auto data = jsonBody(request());
            auto r = stopServerHeartbeat(data);
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(r.msg), 200);
        }, true);
        route("/get_heartbeat/<int:sid>", "get_heartbeat", ["GET"], (Dict a) {
            return makeJsonResponse(1, Value(""), Value(""), Value(null), getServerHeartbeat(a["sid"].integer), 200);
        }, true);
        route("/shutdown", "shutdown", ["GET", "POST"], (Dict a) => new Response(""), true);
        route("/validate_binary_path", "validate_binary_path", ["POST"], loginRequired((Dict a) {
            import pgadmin.utils.binary_paths : getBinaryPathVersions;
            import std.path : buildNormalizedPath, absolutePath;
            import std.algorithm : startsWith;
            auto data = jsonBody(request());
            if (data.isDict && data.contains("utility_path") && !data["utility_path"].isNone)
            {
                auto storage = absolutePath(cfgStr("STORAGE_DIR")).buildNormalizedPath;
                auto up = absolutePath(data["utility_path"].toString).buildNormalizedPath;
                if (up != storage && !up.startsWith(storage ~ "/"))
                {
                    Value[] utilities;
                    foreach (util, ver; getBinaryPathVersions(up))
                        utilities ~= Value.dictOf("utility", util, "version", ver);
                    return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(utilities), 200);
                }
            }
            return preconditionRequired(gettext("Invalid binary path."));
        }));
        route("/upgrade_check", "upgrade_check", ["GET"], loginRequired((Dict a) {
            auto trigger = request().args.get("trigger_update_check", "false").toLower == "true";
            auto ret = Value.dictOf("outdated", false);
            if (cfgBool("UPGRADE_CHECK_ENABLED"))
            {
                import pgadmin.misc.upgrade : upgradeCheck;
                return upgradeCheck(trigger);
            }
            return makeJsonResponse(1, Value(""), Value(""), Value(null), ret, 200);
        }));
        route("/auto_update/<current_version_int>/<latest_version>/<latest_version_int>/<product_name>/<path:ftp_url>/",
                "auto_update", ["GET"], (Dict a) {
            import std.conv : to;
            if (a["latest_version_int"].str.to!long > a["current_version_int"].str.to!long)
            {
                auto info = Value.dictOf("url", urlUnquote(a["ftp_url"].str), "name",
                        a["product_name"].str ~ " v" ~ a["latest_version"].str);
                return makeResponse(info, 200);
            }
            return makeResponse(Value(null), 204);
        }, true);
    }
}

/// Builds a kwargs dict from alternating names and values (for `register(...)`).
Dict kw(Args...)(Args args)
{
    static assert(Args.length % 2 == 0);
    auto d = new Dict;
    static foreach (i; 0 .. Args.length / 2)
        d[args[2 * i]] = Value(args[2 * i + 1]);
    return d;
}
