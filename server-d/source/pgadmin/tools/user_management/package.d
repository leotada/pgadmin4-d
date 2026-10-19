/// `pgadmin/tools/user_management`: the current user script and user administration.
module pgadmin.tools.user_management;

import std.algorithm : canFind, sort;
import std.array : join;
import std.conv : to;
import std.string : replace, split, strip, toLower;
import pgadmin.authenticate : validateEmail;
import pgadmin.core.config;
import pgadmin.core.crypto : hashPassword, uuid4;
import pgadmin.core.i18n;
import pgadmin.core.templates : renderTemplate;
import pgadmin.core.value;
import pgadmin.model;
import pgadmin.utils.constants;
import pgadmin.utils.paths : getStorageDirectory;
import pgadmin.web.auth;
import pgadmin.web.context;
import pgadmin.web.flask;
import pgadmin.web.http;

final class UserManagementModule : Blueprint
{
    this()
    {
        super("user_management");
    }

    override Value getOwnMenuItems()
    {
        return Value.newDict();
    }

    override string[] getExposedUrlEndpoints()
    {
        return [
            "user_management.roles", "user_management.role", "user_management.role_save",
            "user_management.role_delete", "user_management.users", "user_management.user",
            "user_management.auth_sources", "user_management.change_owner",
            "user_management.shared_servers", "user_management.admin_users",
            "user_management.save", "user_management.save_id",
            "user_management.all_permissions", "user_management.save_permissions"
        ];
    }

    override void setup()
    {
        route("/", "index", ["GET"], loginRequired((Dict a) => badRequest(gettext("This URL cannot be called directly."))));
        route("/current_user.js", "current_user_info", ["GET"], loginRequired((Dict a) {
            auto uid = currentUserId();
            auto email = currentUserAttr("email");
            string[] perms;
            foreach (p; userPermissions(uid))
                if (!perms.canFind(p))
                    perms ~= p;
            Value[string] vars;
            vars["is_admin"] = Value(currentUserHasRole("Administrator") ? "true" : "false");
            vars["user_id"] = Value(uid);
            vars["email"] = email.isNone ? Value(null) : Value(email.toString.replace("'", "\\'"));
            vars["name"] = Value(cfgBool("SERVER_MODE") ? currentUserAttr("username").toString.split("@")[0].replace("'", "\\'")
                    : "postgres");
            auto allowSave = session().get("allow_save_password").truthy;
            vars["allow_save_password"] = Value(cfgBool("ALLOW_SAVE_PASSWORD") && allowSave ? "true" : "false");
            vars["allow_save_tunnel_password"] = Value(cfgBool("ALLOW_SAVE_TUNNEL_PASSWORD") && allowSave ? "true" : "false");
            vars["auth_sources"] = ConfigAccess.get("AUTHENTICATION_SOURCES");
            vars["current_auth_source"] = cfgBool("SERVER_MODE")
                ? session().get("auth_source_manager").get("current_source") : Value(INTERNAL);
            vars["permissions"] = Value(perms);
            auto r = new Response(renderTemplate("user_management/js/current_user.js", vars), 200, MIMETYPE_APP_JS);
            r.setHeader("Cache-Control", NO_CACHE_CONTROL);
            return r;
        }), true);

        // List or single user
        View userView = rolesRequired("Administrator", (Dict a) {
            if (a.has("uid"))
            {
                auto uid = a["uid"].integer;
                auto u = db.queryOne(`SELECT u.*, ru.role_id FROM "user" u LEFT JOIN roles_users ru ON ru.user_id = u.id WHERE u.id = ?`, Value(uid));
                if (u.isNone)
                    return new HTTPException(404).toResponse();
                auto res = Value.newDict();
                res["id"] = u["id"];
                res["username"] = u["username"];
                res["email"] = u["email"];
                res["active"] = Value(u["active"].integer != 0);
                res["role"] = u.get("role_id");
                res["auth_source"] = u["auth_source"];
                res["locked"] = Value(u.get("locked").truthy);
                return makeResponse(res);
            }
            auto rows = db.query(`SELECT u.*, ru.role_id FROM "user" u LEFT JOIN roles_users ru ON ru.user_id = u.id ORDER BY u.id`);
            Value[] usersList;
            auto curId = currentUserId();
            foreach (u; rows)
            {
                auto d = Value.newDict();
                d["id"] = u["id"];
                d["username"] = u["username"];
                d["email"] = u["email"];
                d["active"] = Value(u["active"].integer != 0);
                d["role"] = u.get("role_id");
                d["auth_source"] = u["auth_source"];
                d["locked"] = Value(u.get("locked").truthy);
                d["canDrop"] = Value(u["id"].integer != curId);
                usersList ~= d;
            }
            return makeResponse(Value(usersList));
        });
        route("/user/", "users", ["GET"], userView);
        route("/user/<int:uid>", "user", ["GET"], userView);

        // Save / update / delete user
        route("/save", "save", ["POST"], rolesRequired("Administrator", (Dict a) {
            auto data = jsonBody(request());
            if (!data.isDict)
                data = request().form.toDict();
            if (!data.contains("id"))
                return handleCreateUser(data);
            return handleUpdateUser(data["id"].integer, data);
        }));
        route("/save/<int:id>", "save_id", ["DELETE"], rolesRequired("Administrator", (Dict a) {
            auto uid = a["id"].integer;
            auto err = handleDeleteUser(uid);
            if (err.length)
                return internalServerError(err);
            return makeResponse(Value(null));
        }));

        // Roles list / single
        View roleView = rolesRequired("Administrator", (Dict a) {
            if (a.has("rid"))
            {
                auto rid = a["rid"].integer;
                auto r = db.queryOne("SELECT * FROM role WHERE id = ?", Value(rid));
                if (r.isNone)
                    return makeResponse(Value(gettext("Role not found")), 404);
                auto res = Value.newDict();
                res["id"] = r["id"];
                res["name"] = r["name"];
                res["description"] = r["description"];
                res["permissions"] = r["permissions"];
                res["is_admin"] = Value(r["name"].str == "Administrator");
                return makeResponse(res);
            }
            auto rows = db.query("SELECT * FROM role ORDER BY id");
            Value[] rolesList;
            foreach (r; rows)
            {
                auto d = Value.newDict();
                d["id"] = r["id"];
                d["name"] = r["name"];
                d["description"] = r["description"];
                d["permissions"] = r["permissions"];
                d["is_admin"] = Value(r["name"].str == "Administrator");
                rolesList ~= d;
            }
            return makeResponse(Value(rolesList));
        });
        route("/role/", "roles", ["GET"], roleView);
        route("/role/<int:rid>", "role", ["GET"], roleView);

        // Save / create / delete role
        route("/role/", "role_save", ["POST"], rolesRequired("Administrator", (Dict a) {
            auto data = jsonBody(request());
            if (!data.isDict)
                data = request().form.toDict();
            if (!data.contains("id"))
                return handleCreateRole(data);
            return handleUpdateRole(data["id"].integer, data);
        }));
        route("/role/<int:id>", "role_delete", ["DELETE"], rolesRequired("Administrator", (Dict a) {
            auto rid = a["id"].integer;
            return handleDeleteRole(rid);
        }));

        // Auth sources
        route("/auth_sources/", "auth_sources", ["GET"], (Dict a) {
            Value[] sources;
            foreach (s; [INTERNAL, "ldap", "kerberos", "oauth2"])
                sources ~= Value.dictOf("label", s, "value", s);
            return makeResponse(Value(sources));
        });

        // Shared servers
        route("/shared_servers/<int:uid>", "shared_servers", ["GET"], rolesRequired("Administrator", (Dict a) {
            auto uid = a["uid"].integer;
            auto usr = userById(uid);
            if (usr.isNone)
                return new HTTPException(404).toResponse();
            long count = 0;
            if (userRoles(uid).canFind("Administrator"))
            {
                auto r = db.queryOne("SELECT count(*) as c FROM server WHERE user_id = ? AND shared = 1", Value(uid));
                if (!r.isNone)
                    count = r["c"].integer;
            }
            string info = count > 0 ? to!string(count) ~ " Shared servers are associated with this user." : gettext("No shared servers found");
            return makeJsonResponse(1, Value(""), Value(info), Value(null), Value.dictOf("shared_servers", count));
        }));

        // Admin users list (for reassignment)
        route("/admin_users/<int:uid>", "admin_users", ["GET"], rolesRequired("Administrator", (Dict a) {
            auto uid = a["uid"].integer;
            auto rows = db.query(`SELECT u.id, u.username FROM "user" u JOIN roles_users ru ON ru.user_id = u.id JOIN role r ON r.id = ru.role_id WHERE r.name = 'Administrator' AND u.id != ?`, Value(uid));
            Value[] adminList;
            foreach (r; rows)
                adminList ~= Value.dictOf("value", r["id"], "label", r["username"]);
            auto res = Value.newDict();
            res["status"] = Value("success");
            res["msg"] = Value("Admin user list");
            res["result"] = Value.dictOf("data", Value(adminList));
            return makeJsonResponse(1, Value(""), Value(""), Value(null), res);
        }));

        // Change owner of shared servers
        route("/change_owner", "change_owner", ["POST"], rolesRequired("Administrator", (Dict a) {
            auto data = jsonBody(request());
            if (!data.isDict)
                data = request().form.toDict();
            try
            {
                auto newOwner = data["new_owner"].integer;
                auto oldOwner = data["old_owner"].integer;
                auto newUser = userById(newOwner);
                if (newUser.isNone)
                    return badRequest(gettext("New owner user not found."));
                auto newUsername = newUser["username"].str;

                auto oldServers = db.query("SELECT * FROM server WHERE user_id = ? AND shared = 1", Value(oldOwner));
                auto newOwnerSgs = db.query("SELECT * FROM servergroup WHERE user_id = ?", Value(newOwner));
                long[string] newSgByName;
                foreach (sg; newOwnerSgs)
                    newSgByName[sg["name"].str] = sg["id"].integer;

                foreach (s; oldServers)
                {
                    auto oldSgId = s["servergroup_id"].integer;
                    auto oldSg = serverGroupById(oldSgId);
                    string sgName = oldSg.isNone ? "Servers" : oldSg["name"].str;
                    long targetSgId;
                    if (sgName in newSgByName)
                        targetSgId = newSgByName[sgName];
                    else
                    {
                        targetSgId = insertRow("servergroup", Value.dictOf("user_id", newOwner, "name", sgName));
                        newSgByName[sgName] = targetSgId;
                    }

                    db.exec("UPDATE server SET user_id = ?, servergroup_id = ? WHERE id = ?", Value(newOwner), Value(targetSgId), s["id"]);
                    db.exec("UPDATE sharedserver SET servergroup_id = ?, server_owner = ? WHERE server_id = ?", Value(targetSgId), Value(newUsername), s["id"]);
                }
                return makeJsonResponse(1, Value(""), Value(gettext("Owner changed successfully.")), Value(null), Value.newDict());
            }
            catch (Exception e)
            {
                return internalServerError("Unable to update shared server owner: " ~ e.msg);
            }
        }));

        // All permissions
        route("/all_permissions", "all_permissions", ["GET"], rolesRequired("Administrator", (Dict a) {
            return makeResponse(getAllPermissionsValue());
        }));

        // Save permissions for role
        route("/save_permissions/<int:id>", "save_permissions", ["PUT"], rolesRequired("Administrator", (Dict a) {
            auto rid = a["id"].integer;
            auto data = jsonBody(request());
            if (!data.isDict)
                data = request().form.toDict();
            auto r = db.queryOne("SELECT * FROM role WHERE id = ?", Value(rid));
            if (r.isNone)
                return makeResponse(Value(gettext("Role not found")), 404);
            auto perms = data.get("permissions");
            string permsStr;
            if (perms.isList)
            {
                string[] pList;
                foreach (item; perms.list.items)
                    pList ~= item.toString;
                permsStr = pList.join(",");
            }
            else if (perms.isString)
                permsStr = perms.str;
            db.exec("UPDATE role SET permissions = ? WHERE id = ?", Value(permsStr), Value(rid));
            auto res = Value.newDict();
            res["id"] = Value(rid);
            res["name"] = r["name"];
            res["permissions"] = Value(permsStr);
            return makeResponse(res);
        }));
    }
}

private Response handleCreateUser(Value data)
{
    string authSource = data.contains("auth_source") && data["auth_source"].toString.length ? data["auth_source"].toString : INTERNAL;
    if (authSource != INTERNAL)
    {
        foreach (f; ["username", "role", "active", "auth_source"])
            if (!data.contains(f) || data[f].toString.length == 0)
                return internalServerError(gettext("Missing field: '%s'").replace("%s", f));
    }
    else
    {
        foreach (f; ["email", "role", "active", "newPassword", "confirmPassword"])
            if (!data.contains(f) || data[f].toString.length == 0)
                return internalServerError(gettext("Missing field: '%s'").replace("%s", f));
    }
    string username = (data.contains("username") && data["username"].toString.length && authSource != INTERNAL)
        ? data["username"].toString : data["email"].toString;
    string email = data.contains("email") ? data["email"].toString : null;

    auto existing = db.queryOne(`SELECT count(*) as c FROM "user" WHERE username = ? AND auth_source = ?`, Value(username), Value(authSource));
    if (!existing.isNone && existing["c"].integer > 0)
        return internalServerError(gettext("User email or username must be unique for each authentication source."));

    string hashedPw = null;
    if (data.contains("newPassword") && data["newPassword"].toString.length)
    {
        if (data["newPassword"].toString != data["confirmPassword"].toString)
            return internalServerError(gettext("Passwords do not match."));
        hashedPw = hashPassword(data["newPassword"].toString, cfgStr("SECURITY_PASSWORD_SALT"));
    }
    if (email !is null && email.length && !validateEmail(email))
        return internalServerError(gettext("Invalid email address %s.").replace("%s", email));

    int active = data.contains("active") && data["active"].truthy ? 1 : 0;
    int locked = data.contains("locked") && data["locked"].truthy ? 1 : 0;
    int attempts = locked ? cast(int) cfgInt("MAX_LOGIN_ATTEMPTS") : 0;

    long uid = insertRow("user", Value.dictOf(
        "username", username,
        "email", email,
        "password", hashedPw,
        "active", active,
        "auth_source", authSource,
        "fs_uniquifier", uuid4(false),
        "locked", locked,
        "login_attempts", attempts
    ));
    if (data.contains("role") && data["role"].truthy)
    {
        auto rid = data["role"].integer;
        db.exec("INSERT INTO roles_users (user_id, role_id) VALUES (?, ?)", Value(uid), Value(rid));
    }
    insertRow("servergroup", Value.dictOf("user_id", uid, "name", "Servers"));
    return makeResponse(Value(null));
}

private Response handleUpdateUser(long uid, Value data)
{
    auto usr = userById(uid);
    if (usr.isNone)
        return internalServerError(gettext("Unable to update user '%s'").replace("%s", to!string(uid)));

    if (usr["auth_source"].str == INTERNAL)
    {
        if (data.contains("username") && data["username"].toString != usr["username"].str)
            return internalServerError(gettext("'username' cannot be modified."));
        if (data.contains("email") && data["email"].toString != usr["email"].str)
            return internalServerError(gettext("'email' cannot be modified."));
    }
    else
    {
        if (data.contains("username") && data["username"].toString != usr["username"].str)
            return internalServerError(gettext("'username' cannot be modified."));
    }

    auto up = Value.newDict();
    if (data.contains("active"))
        up["active"] = Value(data["active"].truthy ? 1 : 0);
    if (data.contains("locked"))
    {
        bool lk = data["locked"].truthy;
        up["locked"] = Value(lk ? 1 : 0);
        up["login_attempts"] = Value(lk ? cfgInt("MAX_LOGIN_ATTEMPTS") : 0);
    }
    if (data.contains("newPassword") && data["newPassword"].toString.length)
    {
        if (data["newPassword"].toString != data["confirmPassword"].toString)
            return internalServerError(gettext("Passwords do not match."));
        up["password"] = Value(hashPassword(data["newPassword"].toString, cfgStr("SECURITY_PASSWORD_SALT")));
    }
    if (up.dict.length)
        updateRow("user", up, "id = ?", Value(uid));

    if (data.contains("role") && data["role"].truthy)
    {
        db.exec("DELETE FROM roles_users WHERE user_id = ?", Value(uid));
        db.exec("INSERT INTO roles_users (user_id, role_id) VALUES (?, ?)", Value(uid), Value(data["role"].integer));
    }
    return makeResponse(Value(null));
}

private string handleDeleteUser(long uid)
{
    auto usr = userById(uid);
    if (usr.isNone)
        return gettext("Unable to update user '%s'").replace("%s", to!string(uid));
    try
    {
        auto sgs = db.query("SELECT id FROM servergroup WHERE user_id = ?", Value(uid));
        foreach (sg; sgs)
            db.exec("DELETE FROM sharedserver WHERE servergroup_id = ?", sg["id"]);

        db.exec("DELETE FROM setting WHERE user_id = ?", Value(uid));
        db.exec("DELETE FROM user_preferences WHERE uid = ?", Value(uid));
        db.exec("DELETE FROM server WHERE user_id = ?", Value(uid));
        db.exec("DELETE FROM servergroup WHERE user_id = ?", Value(uid));
        db.exec("DELETE FROM process WHERE user_id = ?", Value(uid));
        db.exec("DELETE FROM sharedserver WHERE user_id = ?", Value(uid));
        db.exec("DELETE FROM roles_users WHERE user_id = ?", Value(uid));
        db.exec(`DELETE FROM "user" WHERE id = ?`, Value(uid));
        return null;
    }
    catch (Exception e)
    {
        return e.msg;
    }
}

private Response handleCreateRole(Value data)
{
    if (!data.contains("name") || data["name"].toString.strip.length == 0)
        return internalServerError(gettext("Role name must be unique."));
    string name = data["name"].toString.strip;
    auto exist = db.queryOne("SELECT count(*) as c FROM role WHERE lower(name) = lower(?)", Value(name));
    if (!exist.isNone && exist["c"].integer > 0)
        return internalServerError(gettext("Role name must be unique."));

    string desc = data.contains("description") ? data["description"].toString : "";
    insertRow("role", Value.dictOf("name", name, "description", desc));
    return makeResponse(Value(null));
}

private Response handleUpdateRole(long rid, Value data)
{
    auto r = db.queryOne("SELECT * FROM role WHERE id = ?", Value(rid));
    if (r.isNone)
        return makeResponse(Value(gettext("Role not found")), 404);
    if (data.contains("name"))
    {
        string name = data["name"].toString.strip;
        auto exist = db.queryOne("SELECT count(*) as c FROM role WHERE lower(name) = lower(?) AND id != ?", Value(name), Value(rid));
        if (!exist.isNone && exist["c"].integer > 0)
            return internalServerError(gettext("Role name must be unique."));
        db.exec("UPDATE role SET name = ? WHERE id = ?", Value(name), Value(rid));
    }
    if (data.contains("description"))
        db.exec("UPDATE role SET description = ? WHERE id = ?", Value(data["description"].toString), Value(rid));
    return makeResponse(Value(null));
}

private Response handleDeleteRole(long rid)
{
    auto r = db.queryOne("SELECT * FROM role WHERE id = ?", Value(rid));
    if (r.isNone)
        return makeResponse(Value(gettext("Role not found")), 404);
    auto usersCount = db.queryOne("SELECT count(*) as c FROM roles_users WHERE role_id = ?", Value(rid));
    if (!usersCount.isNone && usersCount["c"].integer > 0)
    {
        string msg = gettext("To proceed, ensure that all users assigned the '{0}' role have been reassigned.")
            .replace("{0}", r["name"].str);
        return makeJsonResponse(0, Value(msg), Value(""), Value(null), Value(null), 400);
    }
    db.exec("DELETE FROM role WHERE id = ?", Value(rid));
    return makeResponse(Value(null));
}

private Value getAllPermissionsValue()
{
    struct PermDef
    {
        string category;
        string name;
        string label;
    }

    static immutable PermDef[] defs = [
        PermDef("Object Explorer", "object_register_server", "Manage Server"),
        PermDef("Tools", "tools_query_tool", "Query Tool"),
        PermDef("Tools", "tools_debugger", "Debugger"),
        PermDef("Tools", "tools_psql_tool", "PSQL Tool"),
        PermDef("Tools", "tools_backup", "Backup Tool (including server and globals)"),
        PermDef("Tools", "tools_restore", "Restore Tool"),
        PermDef("Tools", "tools_import_export_data", "Import/Export Data"),
        PermDef("Tools", "tools_import_export_servers", "Import/Export Servers"),
        PermDef("Tools", "tools_search_objects", "Search Objects"),
        PermDef("Tools", "tools_maintenance", "Maintenance"),
        PermDef("Tools", "tools_schema_diff", "Schema Diff"),
        PermDef("Tools", "tools_grant_wizard", "Grant Wizard"),
        PermDef("Tools", "tools_erd_tool", "ERD Tool"),
        PermDef("Tools", "tools_ai", "AI Reports"),
        PermDef("Storage Manager", "storage_add_folder", "Add Folder"),
        PermDef("Storage Manager", "storage_remove_folder", "Delete File/Folder"),
        PermDef("Miscellaneous", "change_password", "Change Password")
    ];

    auto sorted = defs.dup;
    sort!((a, b) => a.category < b.category || (a.category == b.category && a.label < b.label))(sorted);

    Value[] items;
    foreach (d; sorted)
        items ~= Value.dictOf("category", gettext(d.category), "name", d.name, "label", gettext(d.label));
    return Value(items);
}
