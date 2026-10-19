/// `pgadmin/settings`: per-user settings, layout, tree state, application state and the object explorer filter.
module pgadmin.settings;

import std.algorithm : canFind;
import std.conv : to;
import std.file : exists, read;
import std.string : startsWith, toLower;
import pgadmin.core.config;
import pgadmin.core.crypto;
import pgadmin.core.i18n;
import pgadmin.core.log;
import pgadmin.core.value;
import pgadmin.model : db;
import pgadmin.utils.constants;
import pgadmin.utils.paths : getCompleteFilePath;
import pgadmin.web.auth;
import pgadmin.web.context;
import pgadmin.web.flask;
import pgadmin.web.http;

/// `store_setting(setting, value)`
void storeSetting(string setting, Value value)
{
    auto uid = Value(currentUserId());
    db.exec(`INSERT INTO "setting" (user_id, setting, value) VALUES (?, ?, ?) `
            ~ `ON CONFLICT(user_id, setting) DO UPDATE SET value = excluded.value`, uid, Value(setting), value);
}

void storeSetting(string setting, string value)
{
    storeSetting(setting, Value(value));
}

/// `get_setting(setting, default)`
string getSetting(string setting, string def = "")
{
    auto r = db.queryOne(`SELECT value FROM "setting" WHERE user_id = ? AND setting = ?`, Value(currentUserId()),
            Value(setting));
    if (r.isNone || r["value"].isNone)
        return def;
    return r["value"].toString;
}

Value getWorkspaceLayout()
{
    auto settings = new Dict;
    foreach (row; db.query(`SELECT setting, value FROM "setting" WHERE user_id = ? AND setting LIKE 'Workspace/Layout%'`,
            Value(currentUserId())))
        settings[row["setting"].str] = row["value"];
    return Value(settings);
}

/// `get_layout()`
Value getLayout()
{
    auto layout = new Dict;
    layout["Browser/Layout"] = Value(getSetting("Browser/Layout", ""));
    layout["Browser/ObjectExplorerVisible"] = Value(getSetting("Browser/ObjectExplorerVisible", "true"));
    layout.update(getWorkspaceLayout().dict);
    return Value(layout);
}

/// `get_dialog_type(file_type)`
string getDialogType(Value fileTypes)
{
    bool has(string s)
    {
        foreach (t; fileTypes.iterItems())
            if (t.toString.canFind(s))
                return true;
        return fileTypes.isString && fileTypes.str.canFind(s);
    }

    if (has("pgerd"))
        return "erd_file_type";
    if (has("backup"))
        return "backup_file_type";
    if (has("csv") && has("txt"))
        return "import_export_file_type";
    if (has("csv") && !has("txt"))
        return "storage_manager_file_type";
    return "sqleditor_file_format";
}

string getFileTypeSetting(Value fileTypes)
{
    auto fileType = getDialogType(fileTypes);
    auto d = db.queryOne(`SELECT value FROM "setting" WHERE user_id = ? AND setting = ?`, Value(currentUserId()),
            Value(fileType));
    return d.isNone ? "*" : d["value"].toString;
}

/// `delete_tool_data(trans_id)`
bool deleteToolData(long transId, out string msg)
{
    try
    {
        if (transId)
            db.exec("DELETE FROM application_state WHERE uid = ? AND id = ?", Value(currentUserId()), Value(transId));
        else
            db.exec("DELETE FROM application_state WHERE uid = ?", Value(currentUserId()));
        msg = "Success";
        return true;
    }
    catch (Exception e)
    {
        msg = e.msg;
        return false;
    }
}

private string fernetKey() => cfgStr("SECRET_KEY");

private string fileHash(string path)
{
    import std.digest.sha : sha256Of;
    import std.digest : toHexString;
    import std.string : toLower;
    return toHexString(sha256Of(cast(ubyte[]) read(path))).toLower.idup;
}

final class SettingsModule : Blueprint
{
    this()
    {
        super("settings");
    }

    override Value getOwnMenuItems()
    {
        auto item = Value.dictOf("name", "mnu_resetlayout", "priority", 997, "module", "pgAdmin.Settings", "callback",
                "show", "label", gettext("Reset Layout"));
        return Value.dictOf("file_items", Value([item]));
    }

    override string[] getExposedUrlEndpoints()
    {
        return ["settings.store", "settings.store_bulk", "settings.reset_layout", "settings.save_tree_state",
            "settings.get_tree_state", "settings.reset_tree_state", "settings.save_file_format_setting",
            "settings.get_file_format_setting", "settings.save_application_state", "settings.get_application_state",
            "settings.delete_application_state", "settings.get_tool_data", "settings.object_explorer_filter"];
    }

    override void setup()
    {
        route("/", "index", ["GET"], loginRequired((Dict a) => badRequest(gettext("This URL cannot be called directly."))));
        route("/settings.js", "script", ["GET"], loginRequired((Dict a) {
            import pgadmin.core.templates : renderTemplate;
            auto r = new Response(renderTemplate("settings/settings.js"), 200, MIMETYPE_APP_JS);
            return r;
        }));
        View store = loginRequired((Dict a) {
            long success = 1;
            string errormsg;
            auto req = request();
            try
            {
                auto data = formOrJson(req);
                if (req.method == "POST")
                {
                    if (req.form.has("count"))
                    {
                        foreach (x; 0 .. data["count"].integer)
                            storeSetting(data["setting" ~ to!string(x + 1)].toString, data["value" ~ to!string(x + 1)]);
                    }
                    else
                        storeSetting(data["setting"].toString, data["value"]);
                }
                else
                    storeSetting(a["setting"].toString, a["value"]);
            }
            catch (Exception e)
            {
                success = 0;
                errormsg = e.msg;
            }
            return makeJsonResponse(success, Value(errormsg), Value(gettext("Setting stored")));
        });
        route("/store", "store_bulk", ["POST"], store);
        route("/store/<setting>/<value>", "store", ["PUT"], store);
        route("/layout", "reset_layout", ["DELETE"], loginRequired((Dict a) {
            try
            {
                // Browser layout reset also restores the Object Explorer visibility
                db.exec(`DELETE FROM "setting" WHERE user_id = ? AND setting IN ('Browser/Layout', 'SQLEditor/Layout', `
                        ~ `'Debugger/Layout', 'Browser/ObjectExplorerVisible')`, Value(currentUserId()));
            }
            catch (Exception e)
                return makeJsonResponse(0, Value(e.msg), Value(""), Value(null), Value(null), 410);
            return makeJsonResponse(1, Value(""), Value(""), request().form.toDict);
        }));
        route("/reset_tree_state", "reset_tree_state", ["DELETE"], loginRequired((Dict a) {
            try
                db.exec(`DELETE FROM "setting" WHERE user_id = ? AND setting = 'browser_tree_state'`,
                        Value(currentUserId()));
            catch (Exception e)
                return makeJsonResponse(0, Value(e.msg), Value(""), Value(null), Value(null), 410);
            return successReturn();
        }));
        route("/save_tree_state/", "save_tree_state", ["POST"], loginRequired((Dict a) {
            auto req = request();
            string data = req.form.empty ? req.text : req.form.toDict.toJson;
            auto oldData = getSetting("browser_tree_state", "");
            string newData;
            if (oldData.length && oldData != "null")
            {
                auto merged = data.length ? parseJson(data) : Value.newDict();
                auto old = parseJson(oldData);
                old.dict.update(merged.dict);
                newData = old.toJsonSpaced();
            }
            else
                newData = data;
            try
                storeSetting("browser_tree_state", newData);
            catch (Exception e)
            {
                logException(e);
                return internalServerError(e.msg);
            }
            return successReturn();
        }));
        route("/get_tree_state/", "get_tree_state", ["GET"], loginRequired((Dict a) {
            string data;
            try
                data = getSetting("browser_tree_state", "");
            catch (Exception e)
            {
                logException(e);
                return internalServerError(e.msg);
            }
            return new Response(data, 200, "application/json");
        }));
        route("/save_file_format_setting/", "save_file_format_setting", ["POST"], loginRequired((Dict a) {
            auto data = formOrJson(request());
            storeSetting(getDialogType(data["allowed_file_types"]), data["last_selected_format"]);
            return makeJsonResponse(1, Value(""), data, request().form.toDict);
        }));
        route("/get_file_format_setting/", "get_file_format_setting", ["GET"], loginRequired((Dict a) {
            Value[] vals;
            foreach (k; request().args.keys)
            {
                auto v = request().args.get(k);
                vals ~= tryParseJson(v, Value(v));
            }
            return makeJsonResponse(1, Value(""), Value(getFileTypeSetting(Value(vals))));
        }));
        route("/save_application_state", "save_application_state", ["POST"], loginRequired((Dict a) {
            auto data = parseJson(request().text);
            auto transId = data["trans_id"].integer;
            auto toolData = fernetEncrypt(data["tool_data"].toJsonSpaced().representation_, fernetKey());
            Value connectionInfo = data.contains("connection_info") ? data["connection_info"] : Value(null);
            if (connectionInfo.isDict && connectionInfo.get("open_file_name").truthy)
            {
                auto fp = getCompleteFilePath(connectionInfo["open_file_name"].toString);
                connectionInfo["last_saved_file_hash"] = getLastSavedFileHash(fp, transId);
            }
            try
            {
                db.exec("INSERT OR REPLACE INTO application_state (uid, id, connection_info, tool_data) VALUES (?, ?, ?, ?)",
                        Value(currentUserId()), Value(transId), connectionInfo, Value(toolData));
            }
            catch (Exception e)
                logException(e);
            return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    Value.dictOf("status", true, "msg", "Success"));
        }));
        route("/get_application_state", "get_application_state", ["GET"], loginRequired((Dict a) {
            Value[] res;
            foreach (row; db.query("SELECT * FROM application_state WHERE uid = ?", Value(currentUserId())))
            {
                auto ci = row["connection_info"];
                annotateFileState(ci);
                res ~= Value.dictOf("connection_info", ci, "tool_data",
                        cast(string) fernetDecrypt(row["tool_data"].str, fernetKey()).idup, "id", row["id"]);
            }
            return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    Value.dictOf("status", true, "msg", "", "result", Value(res)));
        }));
        route("/get_tool_data/<int:trans_id>", "get_tool_data", ["GET"], loginRequired((Dict a) {
            auto row = db.queryOne("SELECT * FROM application_state WHERE uid = ? AND id = ?", Value(currentUserId()),
                    a["trans_id"]);
            if (row.isNone)
                return makeJsonResponse(0, Value(gettext("There is no saved content available for this tab.")),
                        Value(""), Value(null), Value(null), 404);
            auto ci = row["connection_info"];
            Value toolData = Value(cast(string) fernetDecrypt(row["tool_data"].str, fernetKey()).idup);
            if (ci.isDict && ci.get("open_file_name").truthy)
            {
                annotateFileState(ci);
                if (!(ci.get("file_deleted").truthy || ci.get("is_editor_dirty").truthy))
                    toolData = Value(null);
            }
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value.dictOf("status", true, "msg", "",
                    "result", Value.dictOf("connection_info", ci, "tool_data", toolData, "id", row["id"])));
        }));
        route("/object_explorer_filter", "object_explorer_filter", ["GET", "PUT"], loginRequired((Dict a) {
            if (request().method == "GET")
            {
                auto result = getSetting("Object Explorer/Filter", "{}");
                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                        Value.dictOf("status", true, "msg", "", "result", parseJson(result)));
            }
            auto data = parseJson(request().text);
            storeSetting("Object Explorer/Filter", data.toJsonSpaced());
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value.dictOf("status", true, "msg", "Success"));
        }));
        route("/delete_application_state/", "delete_application_state", ["DELETE"], loginRequired((Dict a) {
            bool status;
            string msg = gettext("Unable to delete application state data.");
            if (request().data.length)
            {
                auto data = parseJson(request().text);
                if (data.contains("trans_ids"))
                    foreach (t; data["trans_ids"].iterItems())
                        status = deleteToolData(t.integer, msg);
                else
                {
                    import std.array : split;
                    status = deleteToolData(to!long(data["panelId"].toString.split("_")[$ - 1]), msg);
                }
            }
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value.dictOf("status", status, "msg", msg));
        }));
    }

    private void annotateFileState(Value ci)
    {
        if (!(ci.isDict && ci.get("open_file_name").truthy))
            return;
        auto fp = getCompleteFilePath(ci["open_file_name"].toString);
        bool deleted = fp is null;
        ci["file_deleted"] = Value(deleted);
        if (!deleted && ci.get("is_editor_dirty").truthy && ci.get("last_saved_file_hash").truthy)
            ci["external_file_changes"] = Value(fileHash(fp) != ci["last_saved_file_hash"].toString);
    }

    private Value getLastSavedFileHash(string filePath, long transId)
    {
        bool update = true;
        Value last = Value(null);
        foreach (row; db.query("SELECT connection_info FROM application_state WHERE uid = ? AND id = ?",
                Value(currentUserId()), Value(transId)))
        {
            auto ci = row["connection_info"];
            if (ci.isDict && ci.get("open_file_name").truthy)
            {
                update = !ci.get("is_editor_dirty").truthy;
                last = ci.get("last_saved_file_hash");
            }
        }
        if (update && filePath !is null && filePath.exists)
            last = Value(fileHash(filePath));
        return last;
    }
}

private immutable(ubyte)[] representation_(string s)
{
    return cast(immutable(ubyte)[]) s;
}
