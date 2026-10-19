/// The configuration database (`pgadmin/model/__init__.py`).
///
/// The schema is the one of pgAdmin's SCHEMA_VERSION 52, so an existing `pgadmin4.db` created by the Python version
/// works as is. A new database is created directly at that version and seeded like the Alembic migrations do
/// (keys, roles, macros, the first user and its "Servers" group).
///
/// Rows are `Value` dicts keyed by column name. Columns stored through `PgAdminDbBinaryString` (server and tunnel
/// passwords, `masterpass_check`) are hex-encoded on disk; `binaryColumn` decodes them.
module pgadmin.model;

import std.algorithm : canFind;
import std.array : split, join;
import std.conv : to;
import std.file : exists, mkdirRecurse, setAttributes;
import std.path : dirName;
import std.string : strip, toLower;
import pgadmin.core.config;
import pgadmin.core.crypto;
import pgadmin.core.log;
import pgadmin.core.sqlite;
import pgadmin.core.value;

enum SCHEMA_VERSION = 52;
/// The last Alembic revision of pgAdmin 9.18 (stored so the Python version can open the same file).
enum ALEMBIC_HEAD = "normalize_locked_text_default";

immutable string[] allPermissionTypes = [
    "object_register_server", "tools_erd_tool", "tools_query_tool", "tools_debugger", "tools_psql_tool",
    "tools_backup", "tools_restore", "tools_import_export_data", "tools_import_export_servers",
    "tools_search_objects", "tools_maintenance", "tools_schema_diff", "tools_grant_wizard", "tools_ai",
    "storage_add_folder", "storage_remove_folder", "change_password",
];

private __gshared SqliteDb db_;

/// The configuration database connection.
SqliteDb db() @trusted
{
    assert(db_ !is null, "configuration database not open");
    return db_;
}

/// Opens (creating and seeding it when needed) the configuration database.
void initConfigDb(string sqlitePath, string firstUserEmail = null, string firstUserPassword = null) @trusted
{
    auto dir = dirName(sqlitePath);
    if (!dir.exists)
        mkdirRecurse(dir);
    bool fresh = !sqlitePath.exists;
    db_ = new SqliteDb(sqlitePath, cast(int) ConfigAccess.get("SQLITE_TIMEOUT").integer);
    version (Posix)
    {
        try
            setAttributes(sqlitePath, octal!600);
        catch (Exception)
        {
        }
    }

    if (!fresh)
    {
        auto v = getVersion();
        if (v == -1)
            fresh = true;
        else if (v < SCHEMA_VERSION)
            throw new Exception("The configuration database " ~ sqlitePath ~ " is at schema version "
                    ~ to!string(v) ~ "; this build supports version " ~ to!string(SCHEMA_VERSION)
                    ~ ". Upgrade it once with pgAdmin 4 " ~ cfgStr("APP_VERSION") ~ " (Python) first.");
        else if (v > SCHEMA_VERSION)
            throw new Exception("The configuration database " ~ sqlitePath ~ " is newer (schema version "
                    ~ to!string(v) ~ ") than this build supports (" ~ to!string(SCHEMA_VERSION) ~ ").");
    }
    if (fresh)
        createSchema(firstUserEmail, firstUserPassword);
    checkTables();
    loadKeys();
}

private import std.conv : octal;

/// `get_version()`: the ConfigDB schema version, -1 when there is none.
long getVersion()
{
    try
    {
        auto r = db.queryOne("SELECT value FROM version WHERE name = 'ConfigDB'");
        return r.isNone ? -1 : r["value"].integer;
    }
    catch (SqliteError)
        return -1;
}

private void createSchema(string email, string password)
{
    import std.process : environment;

    db.transaction({
        foreach (stmt; import("schema.sql").split(";\n"))
            if (stmt.strip.length)
                db.exec(stmt.strip);

        db.exec("INSERT INTO version (name, value) VALUES ('ConfigDB', ?)", Value(SCHEMA_VERSION));
        db.exec("INSERT INTO alembic_version (version_num) VALUES (?)", Value(ALEMBIC_HEAD));
        foreach (k; ["CSRF_SESSION_KEY", "SECRET_KEY", "SECURITY_PASSWORD_SALT"])
            db.exec("INSERT INTO keys (name, value) VALUES (?, ?)", Value(k), Value(tokenUrlsafe(32, true)));
        db.exec("INSERT INTO role (id, name, description, permissions) VALUES (1, 'Administrator', "
                ~ "'pgAdmin Administrator Role', NULL)");
        string[] userPerms = allPermissionTypes.dup ~ ["list", "change_password"];
        db.exec("INSERT INTO role (id, name, description, permissions) VALUES (2, 'User', 'pgAdmin User Role', ?)",
                Value(userPerms.join(",")));
        // keyboard macros: Ctrl+1..9, Ctrl+0, Alt+F1..F12
        foreach (i; 1 .. 10)
            db.exec("INSERT INTO macros (id, alt, control, key, key_code) VALUES (?, 0, 1, ?, ?)", Value(i),
                    Value(to!string(i)), Value(48 + i));
        db.exec("INSERT INTO macros (id, alt, control, key, key_code) VALUES (10, 0, 1, '0', 48)");
        foreach (i; 1 .. 13)
            db.exec("INSERT INTO macros (id, alt, control, key, key_code) VALUES (?, 1, 0, ?, ?)", Value(10 + i),
                    Value("F" ~ to!string(i)), Value(111 + i));

        // first user (setup/user_info.py)
        bool serverMode = cfgBool("SERVER_MODE");
        if (!serverMode)
        {
            email = cfgStr("DESKTOP_USER");
            password = randomString(32);
        }
        else
        {
            if (email is null)
                email = environment.get("PGADMIN_SETUP_EMAIL", null);
            if (password is null)
                password = environment.get("PGADMIN_SETUP_PASSWORD", null);
            if (email is null || password is null)
                throw new Exception("SERVER mode: set PGADMIN_SETUP_EMAIL and PGADMIN_SETUP_PASSWORD (or pass "
                        ~ "--setup-email/--setup-password) to create the first administrator account.");
        }
        auto salt = db.scalar("SELECT value FROM keys WHERE name = 'SECURITY_PASSWORD_SALT'").str;
        db.exec("INSERT INTO user (id, email, username, password, active, confirmed_at, masterpass_check, "
                ~ "auth_source, fs_uniquifier, locked, login_attempts) VALUES (1, ?, ?, ?, 1, NULL, NULL, 'internal', ?, 0, 0)",
                Value(email), Value(email), Value(hashPassword(password, salt)), Value(uuid4(false)));
        db.exec("INSERT INTO roles_users (user_id, role_id) VALUES (1, 1)");
        db.exec("INSERT INTO servergroup (id, user_id, name) VALUES (1, 1, 'Servers')");
    });
    logInfo("Created the configuration database " ~ db.path);
}

/// `check_db_tables()`: every model table must exist.
private void checkTables()
{
    string[] have;
    foreach (r; db.query("SELECT name FROM sqlite_master WHERE type = 'table'"))
        have ~= r["name"].str;
    string[] missing;
    foreach (t; ["version", "user", "role", "roles_users", "setting", "servergroup", "server", "module_preference",
            "preference_category", "preferences", "user_preferences", "debugger_function_arguments", "process",
            "keys", "query_history", "application_state", "database", "sharedserver", "macros", "user_macros",
            "user_mfa"])
        if (!have.canFind(t))
            missing ~= t;
    if (missing.length)
        throw new Exception("Table(s) " ~ missing.join(", ") ~ " are missing in the configuration database");
}

/// Loads CSRF_SESSION_KEY, SECRET_KEY and SECURITY_PASSWORD_SALT into the configuration.
private void loadKeys()
{
    foreach (r; db.query("SELECT name, value FROM keys"))
        ConfigAccess.set(r["name"].str, r["value"].str);
}

// ------------------------------------------------------------ helpers

/// Decodes a `PgAdminDbBinaryString` column (hex on disk); returns the value unchanged when it is not hex.
string binaryColumn(Value v)
{
    if (!v.isString)
        return null;
    auto s = v.str;
    if (s.length % 2 != 0)
        return s;
    try
    {
        auto b = new ubyte[s.length / 2];
        foreach (i; 0 .. b.length)
            b[i] = to!ubyte(s[2 * i .. 2 * i + 2], 16);
        return cast(string) b.idup;
    }
    catch (Exception)
        return s;
}

/// Encodes for a `PgAdminDbBinaryString` column (Python stores bytes as hex, str as is).
Value toBinaryColumn(string s)
{
    if (s is null)
        return Value(null);
    import std.format : format;
    string h;
    foreach (ubyte c; cast(immutable(ubyte)[]) s)
        h ~= format("%02x", c);
    return Value(h);
}

/// `Role.permissions` (comma separated) as a list.
string[] rolePermissions(Value role)
{
    auto p = role.get("permissions");
    if (p.isNone || !p.isString || p.str.length == 0)
        return null;
    return p.str.split(",");
}

// ------------------------------------------------------------ users

Value userById(long id) => db.queryOne(`SELECT * FROM "user" WHERE id = ?`, Value(id));
Value userByEmail(string email) => db.queryOne(`SELECT * FROM "user" WHERE email = ?`, Value(email));
Value userByUsername(string username, string authSource = null)
{
    if (authSource is null)
        return db.queryOne(`SELECT * FROM "user" WHERE username = ?`, Value(username));
    return db.queryOne(`SELECT * FROM "user" WHERE username = ? AND auth_source = ?`, Value(username),
            Value(authSource));
}

/// Role names of a user.
string[] userRoles(long uid)
{
    string[] r;
    foreach (row; db.query("SELECT r.name FROM role r JOIN roles_users ru ON ru.role_id = r.id WHERE ru.user_id = ?",
            Value(uid)))
        r ~= row["name"].str;
    return r;
}

/// The permissions of a user (Administrator has all of them).
string[] userPermissions(long uid)
{
    string[] perms;
    foreach (row; db.query("SELECT r.* FROM role r JOIN roles_users ru ON ru.role_id = r.id WHERE ru.user_id = ?",
            Value(uid)))
    {
        if (row["name"].str == "Administrator")
            return allPermissionTypes.dup;
        foreach (p; rolePermissions(row))
            if (!perms.canFind(p))
                perms ~= p;
    }
    return perms;
}

bool userHasPermission(long uid, string permission)
{
    return userRoles(uid).canFind("Administrator") || userPermissions(uid).canFind(permission);
}

// ------------------------------------------------------------ servers

Value serverById(long id) => db.queryOne("SELECT * FROM server WHERE id = ?", Value(id));
Value serverGroupById(long id) => db.queryOne("SELECT * FROM servergroup WHERE id = ?", Value(id));

/// Inserts a row from a dict; returns the new rowid.
long insertRow(string table, Value data)
{
    string[] cols, marks;
    Value[] vals;
    foreach (k, v; data.dict)
    {
        cols ~= `"` ~ k ~ `"`;
        marks ~= "?";
        vals ~= v;
    }
    db.exec(`INSERT INTO "` ~ table ~ `" (` ~ cols.join(", ") ~ ") VALUES (" ~ marks.join(", ") ~ ")", vals);
    return db.lastInsertId();
}

/// Updates columns of the rows matching `where` (with its own parameters).
int updateRow(string table, Value data, string where, Value[] whereParams...)
{
    string[] sets;
    Value[] vals;
    foreach (k, v; data.dict)
    {
        sets ~= `"` ~ k ~ `" = ?`;
        vals ~= v;
    }
    if (sets.length == 0)
        return 0;
    return db.exec(`UPDATE "` ~ table ~ `" SET ` ~ sets.join(", ") ~ " WHERE " ~ where, vals ~ whereParams);
}
