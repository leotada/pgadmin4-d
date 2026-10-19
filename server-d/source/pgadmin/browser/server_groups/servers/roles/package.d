/// `servers/roles`: login/group roles.
module pgadmin.browser.server_groups.servers.roles;

import std.regex : regex, matchFirst;
import pgadmin.browser.common;
import pgadmin.core.strutil : pyIntStrict, dateutilIsoformat;
import pgadmin.utils.constants : ERROR_FETCHING_ROLE_INFORMATION;

private enum REASSIGN_OWN_SQL = "reassign_own.sql";

final class RoleModule : CollectionNodeModule
{
    enum NODE_TYPE = "role";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "Login/Group Roles";
        minVer = Value(null);
        maxVer = Value(null);
        staticDir("browser/server_groups/servers/roles");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => "server_group";
    override bool nodeInode() => false;
    override bool moduleUseTemplateJavascript() => false;

    override string[] csssnippets()
    {
        string[] snippets = [renderTemplate("browser/css/collection.css", ["node_type": Value(nodeType)]),
            renderTemplate("roles/css/role.css")];
        foreach (m; submodules)
            if (auto b = cast(BrowserPluginModule) m)
                snippets ~= b.csssnippets;
        return snippets;
    }

    override Value[] getNodes(Dict kwargs)
    {
        if (showNode)
            return [generateBrowserCollectionNode(kwargs["sid"])];
        return null;
    }

    override void setup()
    {
        registerNodeView!RoleView(this);
    }
}

private enum msgMembersNew = `
Role members information must be passed as an array of JSON objects in the
following format:

rolmembers:[{
    role: [rolename],
    admin: True/False,
    inherit: True/False,
    set: True/False,
    },
    ...
]`;

private enum msgMembersUpdate = `
Role membership information must be passed as a string representing an array of
JSON objects in the following format:
rolmembers:{
    'added': [{
        role: [rolename],
        admin: True/False,
        inherit: True/False,
        set: True/False,
        },
        ...
        ],
    'deleted': [{
        role: [rolename],
        admin: True/False,
        inherit: True/False,
        set: True/False,
        },
        ...
        ],
    'updated': [{
        role: [rolename],
        admin: True/False,
        inherit: True/False,
        set: True/False,
        },
        ...
        ]
`;

private enum msgMembershipNew = `
Role membership information must be passed as an array of JSON objects in the
following format:

rolmembership:[{
    role: [rolename],
    admin: True/False,
    inherit: True/False,
    set: True/False,
    },
    ...
]`;

private enum msgMembershipUpdate = `
Role membership information must be passed as a string representing an array of
JSON objects in the following format:
rolmembership:{
    'added': [{
        role: [rolename],
        admin: True/False,
        inherit: True/False,
        set: True/False,
        },
        ...
        ],
    'deleted': [{
        role: [rolename],
        admin: True/False,
        inherit: True/False,
        set: True/False,
        },
        ...
        ],
    'updated': [{
        role: [rolename],
        admin: True/False,
        inherit: True/False,
        set: True/False,
        },
        ...
        ]
`;

private enum msgSeclabelsNew = `
Security Label must be passed as an array of JSON objects in the following
format:
seclabels:[{
    provider: <provider>,
    label: <label>
    },
    ...
]`;

private enum msgSeclabelsUpdate = `
Security Label must be passed as an array of JSON objects in the following
format:
seclabels:{
    'added': [{
        provider: <provider>,
        label: <label>
        },
        ...
        ],
    'deleted': [{
        provider: <provider>,
        label: <label>
        },
        ...
        ],
    'updated': [{
        provider: <provider>,
        label: <label>
        },
        ...
        ]
`;

private enum msgVariablesNew = `
Configuration parameters/variables must be passed as an array of JSON objects
in the following format in create mode:
variables:[{
database: <database> or null,
name: <configuration>,
value: <value>
},
...
]`;

private enum msgVariablesUpdate = `
Configuration parameters/variables must be passed as an array of JSON objects
in the following format in update mode:
rolmembership:{
'added': [{
    database: <database> or null,
    name: <configuration>,
    value: <value>
    },
    ...
    ],
'deleted': [{
    database: <database> or null,
    name: <configuration>,
    value: <value>
    },
    ...
    ],
'updated': [{
    database: <database> or null,
    name: <configuration>,
    value: <value>
    },
    ...
    ]
`;

final class RoleView : PGChildNodeView
{
    string sqlPath;
    string role;
    Value rolCanLogin, rolSuper;
    Value[] alterKeys;
    Value requestData;

    this()
    {
        super();
        nodeType = "role";
        parentIds = [IdSpec("int", "gid"), IdSpec("int", "sid")];
        ids = [IdSpec("int", "rid")];
        setAllOps([
            makeOp("obj", ["get": "properties", "delete": "drop", "put": "update"],
                    ["get": "list", "post": "create", "delete": "drop"]),
            makeOp("nodes", ["get": "node"], ["get": "nodes"]),
            makeOp("sql", ["get": "sql"]),
            makeOp("msql", ["get": "msql"], ["get": "msql"]),
            makeOp("dependency", ["get": "dependencies"]),
            makeOp("dependent", ["get": "dependents"]),
            makeOp("children", ["get": "children"]),
            makeOp("vopts", null, ["get": "voptions"]),
            makeOp("variables", ["get": "variables"]),
            makeOp("reassign", ["get": "get_reassign_own_sql", "post": "role_reassign_own"]),
        ]);
    }

    // ---------------------------------------------------------------- request validation

    private static bool validateForNew(Value data, string[] reqKeys)
    {
        if (!data.isList)
            return false;
        foreach (item; data.list.items)
        {
            if (!item.isDict)
                return false;
            foreach (k; reqKeys)
                if (!item.contains(k))
                    return false;
        }
        return true;
    }

    private static bool validateForUpdate(Value data, string[] reqAdd, string[] reqDelete)
    {
        if (!data.isDict)
            return false;
        foreach (op; ["added", "deleted", "changed"])
        {
            auto opData = data.dict.get(op, Value.newList());
            if (!validateForNew(opData, op == "deleted" ? reqDelete : reqAdd))
                return false;
        }
        return true;
    }

    private string validateRolvaliduntil(Value data)
    {
        if (data.contains("rolvaliduntil"))
        {
            try
            {
                auto v = data["rolvaliduntil"];
                if (!v.isNone && v != Value("") && v.str.length > 0)
                    data["rolvaliduntil"] = Value(dateutilIsoformat(v.str));
            }
            catch (Exception)
                return gettext("Date format is invalid.");
        }
        return null;
    }

    private string validateRolconnlimit(Value data)
    {
        if (data.contains("rolconnlimit"))
        {
            if (data["rolconnlimit"] == Value(""))
                data["rolconnlimit"] = Value(-1);
            if (!data["rolconnlimit"].isNone)
            {
                data["rolconnlimit"] = Value(pyIntStrict(data["rolconnlimit"]));
                if (data["rolconnlimit"].integer < -1)
                    return gettext("Connection limit must be an integer value or equal to -1.");
            }
        }
        return null;
    }

    /// Splits the `changed` entries by the admin flag before PG 16 (lists keep reference semantics).
    private void processMembership(long id, Value data, string key, string listKey, string revokedAdmins, string revokedList)
    {
        if (id == -1)
        {
            data[listKey] = data[key];
            return;
        }
        data[listKey] = data[key].dict.get("added", Value.newList());
        auto changed = data[key].dict.get("changed", Value.newList());
        if (manager.version_ < 160000)
        {
            foreach (d; changed.iterItems())
                if (d["admin"].truthy)
                    data[listKey].append(d);
            Value[] revoked;
            foreach (d; data[key].dict.get("changed", Value.newList()).iterItems())
                if (!d["admin"].truthy)
                    revoked ~= d;
            data[revokedAdmins] = Value(revoked);
        }
        else
            foreach (d; changed.iterItems())
                data[listKey].append(d);
        data[revokedList] = data[key].dict.get("deleted", Value.newList());
    }

    private string validateMembers(long id, Value data, string key, string newMsg, string updateMsg, string listKey,
            string revokedAdmins, string revokedList)
    {
        if (!data.contains(key))
            return null;
        auto newKeys = manager.version_ < 160000 ? ["role", "admin"] : ["role", "admin", "inherit", "set"];
        if (id == -1)
        {
            if (!validateForNew(data[key], newKeys))
                return newMsg;
            processMembership(id, data, key, listKey, revokedAdmins, revokedList);
            return null;
        }
        if (!validateForUpdate(data[key], newKeys, ["role"]))
            return updateMsg;
        processMembership(id, data, key, listKey, revokedAdmins, revokedList);
        return null;
    }

    private string validateSeclabels(long id, Value data)
    {
        if (!data.contains("seclabels") || manager.version_ < 90200)
            return null;
        if (id == -1)
            return validateForNew(data["seclabels"], ["provider", "label"]) ? null : msgSeclabelsNew;
        return validateForUpdate(data["seclabels"], ["provider", "label"], ["provider"]) ? null : msgSeclabelsUpdate;
    }

    private string validateVariables(long id, Value data)
    {
        if (!data.contains("variables"))
            return null;
        if (id == -1)
            return validateForNew(data["variables"], ["name", "value"]) ? null : msgVariablesNew;
        return validateForUpdate(data["variables"], ["name", "value"], ["name"]) ? null : msgVariablesUpdate;
    }

    /// The `validate_request` decorator: fills `requestData` or returns the 428 response.
    private Response validateRequest(Dict k)
    {
        Value data;
        auto req = request();
        if (req.text.length)
            data = parseJson(req.text);
        else
        {
            data = Value.newDict();
            foreach (key; req.args.keys)
            {
                auto raw = req.args.get(key);
                data[key] = key == "comment" ? Value(raw) : tryParseJson(raw, Value(raw));
            }
        }
        long id = k.has("rid") ? k["rid"].integer : -1;
        string[] msgs;
        bool noName = id == -1 && !data.contains("rolname");
        msgs ~= null;
        msgs ~= validateRolvaliduntil(data);
        msgs ~= validateRolconnlimit(data);
        msgs ~= validateMembers(id, data, "rolmembership", msgMembershipNew, msgMembershipUpdate, "rolmembership_list",
                "rolmembership_revoked_admins", "rolmembership_revoked_list");
        msgs ~= validateSeclabels(id, data);
        msgs ~= validateVariables(id, data);
        msgs ~= validateMembers(id, data, "rolmembers", msgMembersNew, msgMembersUpdate, "rol_members_list",
                "rol_members_revoked_admins", "rol_members_revoked_list");
        if (noName)
            // precondition_required(<Response>) is not JSON serialisable: the app answers with its generic 500
            return internalServerError("Circular reference detected");
        foreach (m; msgs)
            if (m !is null)
                return preconditionRequired(m);
        requestData = data;
        return null;
    }

    // ---------------------------------------------------------------- precondition

    private Response rolePrecondition(Dict k, string action)
    {
        manager = getDriver().connectionManager(k["sid"].integer);
        conn = manager.connection();
        if (!conn.connected())
            return preconditionRequired(gettext("Connection to the server has been lost."));
        datistemplate = false;
        if (manager.dbInfo !is null && !manager.did.isNone && manager.dbInfo.has(manager.did.toString)
                && manager.dbInfo[manager.did.toString].contains("datistemplate"))
            datistemplate = manager.dbInfo[manager.did.toString]["datistemplate"].truthy;
        sqlPath = "roles/sql/#" ~ to!string(manager.version_) ~ "#/";
        alterKeys = manager.version_ >= 90200
            ? [Value("rolcanlogin"), Value("rolsuper"), Value("rolcreatedb"), Value("rolcreaterole"), Value("rolinherit"),
                Value("rolreplication"), Value("rolconnlimit"), Value("rolvaliduntil"), Value("rolpassword"),
                Value("rolbypassrls")]
            : [Value("rolcanlogin"), Value("rolsuper"), Value("rolcreatedb"), Value("rolcreaterole"), Value("rolinherit"),
                Value("rolconnlimit"), Value("rolvaliduntil"), Value("rolpassword")];

        bool fetchName, checkPermission;
        string forbiddenMsg;
        if (action == "drop" || action == "update")
        {
            if (k.has("rid"))
            {
                fetchName = true;
                checkPermission = true;
            }
            forbiddenMsg = action == "drop" ? gettext("The current user does not have permission to drop the role.")
                : gettext("The current user does not have permission to update the role.");
        }
        else if (action == "create")
        {
            checkPermission = true;
            forbiddenMsg = gettext("The current user does not have permission to create the role.");
        }
        else if (action == "msql" && k.has("rid"))
            fetchName = true;

        if (checkPermission)
        {
            auto user = manager.userInfo;
            if (!user["is_superuser"].truthy && !user["can_create_role"].truthy && (action != "update" || k.has("rid")))
            {
                if (!k.has("rid"))
                    throw new Exception("'rid'");
                if (k["rid"].integer != -1 && user["id"] != k["rid"])
                    return forbidden(forbiddenMsg);
            }
        }
        if (fetchName)
        {
            auto r = conn.executeDict(rtr("permission.sql", tv("rid", k["rid"], "conn", conn)));
            if (!r.ok)
                return internalServerError(gettext("Error retrieving the role information.\n%s").replace("%s", r.error));
            if (r.value["rows"].length == 0)
                return gone(gettext("Could not find the role on the database server."));
            auto row = r.value["rows"][0];
            role = row["rolname"].toString;
            rolCanLogin = row["rolcanlogin"];
            rolSuper = row["rolsuper"];
        }
        return null;
    }

    private string rtr(string name, Value[string] vars = null) => renderTemplate(sqlPath ~ name, vars);

    private static string fetchError(string res) => gettext(ERROR_FETCHING_ROLE_INFORMATION) ~ "\n" ~ res;

    // ---------------------------------------------------------------- dispatch

    override Response callMethod(string name, Dict k)
    {
        if (!isAuthenticated())
            return unauthorisedResponse();
        if (name == "children")
            return children(k);
        if (name == "variables") // the Python view has no check_precondition here, so self.conn does not exist
            return internalServerError("'RoleView' object has no attribute 'conn'");
        string action;
        switch (name)
        {
        case "list": action = "list"; break;
        case "nodes": action = "nodes"; break;
        case "node": action = "node"; break;
        case "properties": action = "properties"; break;
        case "drop": action = "drop"; break;
        case "create": action = "create"; break;
        case "update": action = "update"; break;
        case "msql": action = "msql"; break;
        default: action = null; break;
        }
        auto err = rolePrecondition(k, action);
        if (err !is null)
            return err;
        auto sid = k["sid"];
        auto rid = k.has("rid") ? k["rid"] : Value(null);
        switch (name)
        {
        case "list":
        {
            auto r = conn.executeDict(rtr(PROPERTIES_SQL, tv("conn", conn)));
            if (!r.ok)
                return internalServerError(fetchError(r.error));
            transform(r.value);
            return makeResponse(r.value["rows"], 200);
        }
        case "nodes":
        {
            auto r = conn.execute2darray(rtr(NODES_SQL, tv("conn", conn)));
            if (!r.ok)
                return internalServerError(fetchError(r.error));
            Value[] res;
            foreach (row; r.value["rows"].list.items)
                res ~= gbn(row["oid"], sid, row["rolname"].toString, row["rolcanlogin"].truthy ? "icon-role" : "icon-group",
                        kwDict("can_login", row["rolcanlogin"], "is_superuser", row["rolsuper"],
                            "description", row["description"]));
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        case "node":
        {
            auto r = conn.execute2darray(rtr(NODES_SQL, tv("rid", rid, "conn", conn)));
            if (!r.ok)
                return internalServerError(fetchError(r.error));
            foreach (row; r.value["rows"].list.items)
                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                        gbn(row["oid"], sid, row["rolname"].toString, row["rolcanlogin"].truthy ? "icon-role" : "icon-group",
                            kwDict("can_login", row["rolcanlogin"], "is_superuser", row["rolsuper"])), 200);
            return gone();
        }
        case "properties":
        {
            auto r = conn.executeDict(rtr(PROPERTIES_SQL, tv("rid", rid, "conn", conn)));
            auto vars = conn.executeDict(rtr("variables.sql", tv("rid", rid, "conn", conn)));
            if (!vars.ok)
                return internalServerError(gettext("Error retrieving variable information for the role.\n%s").replace("%s", vars.error));
            if (!r.ok)
                return internalServerError(fetchError(r.error));
            transform(r.value);
            if (r.value["rows"].length == 0)
                return gone(notFoundErrorMsg());
            auto row = r.value["rows"][0];
            row["is_sys_obj"] = Value(row["oid"].integer <= DATABASE_LAST_SYSTEM_OID_ || datistemplate);
            auto res = row.shallowCopy();
            res["variables"] = vars.value["rows"];
            return makeResponse(res, 200);
        }
        case "variables":
        {
            auto vars = conn.executeDict(rtr("variables.sql", tv("rid", rid, "conn", conn)));
            if (!vars.ok)
                return internalServerError(gettext("Error retrieving variable information for the role.\n%s").replace("%s", vars.error));
            return jsonify(vars.value);
        }
        case "drop": return drop(rid);
        case "sql":
        {
            bool showPassword = manager.userInfo["is_superuser"].truthy;
            auto r = conn.executeScalar(rtr("sql.sql", tv("show_password", showPassword)), Value.dictOf("rid", rid));
            if (!r.ok)
                return internalServerError(gettext("Could not generate reverse-engineered query for the role.\n%s").replace("%s", r.error));
            if (r.value.isNone || r.value.toString.length == 0)
                return gone(gettext("Could not generate reverse-engineered query for the role."));
            return makeResponse(Value(r.value.toString.strip("\n")));
        }
        case "create":
        {
            auto v = validateRequest(k);
            if (v !is null)
                return v;
            return create(sid);
        }
        case "update":
        {
            auto v = validateRequest(k);
            if (v !is null)
                return v;
            return update(sid, rid);
        }
        case "msql":
        {
            auto v = validateRequest(k);
            if (v !is null)
                return v;
            string sql;
            if (rid.isNone)
                sql = rtr(CREATE_SQL, tv("data", requestData, "dummy", true, "conn", conn));
            else
                sql = rtr(UPDATE_SQL, tv("data", requestData, "dummy", true, "conn", conn, "role", role,
                        "rolCanLogin", rolCanLogin, "rolSuper", rolSuper, "alterKeys", Value(alterKeys)));
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(sql.strip("\n")));
        }
        case "dependencies": return makeResponse(getDependencies(conn, rid), 200);
        case "dependents": return makeResponse(roleDependents(sid, rid), 200);
        case "voptions": return voptions();
        case "get_reassign_own_sql": return getReassignOwnSql();
        case "role_reassign_own": return roleReassignOwn(sid, rid);
        default: return super.callMethod(name, k);
        }
    }

    // ---------------------------------------------------------------- helpers

    private void setSeclabels(Value row)
    {
        if (row.contains("seclabels") && !row["seclabels"].isNone)
        {
            Value[] res;
            foreach (sec; row["seclabels"].iterItems())
            {
                auto m = matchFirst(sec.toString, regex(`([^=]+)=(.*$)`));
                if (m.empty)
                    throw new Exception("'NoneType' object has no attribute 'group'");
                res ~= Value.dictOf("provider", m[1], "label", m[2]);
            }
            row["seclabels"] = Value(res);
        }
    }

    private Value[] parseMemberList(Value list)
    {
        Value[] res;
        foreach (role; list.iterItems())
        {
            auto text = role.isNone ? "" : role.toString;
            if (manager.version_ < 160000)
            {
                auto m = matchFirst(text, regex(`^([01])(.+)$`));
                if (m.empty)
                    continue;
                res ~= Value.dictOf("role", m[2], "admin", m[1] == "1");
            }
            else
            {
                auto m = matchFirst(text, regex(`^([01])([01])([01])(.+)$`));
                if (m.empty)
                    continue;
                res ~= Value.dictOf("role", m[4], "admin", m[1] == "1", "inherit", m[2] == "1", "set", m[3] == "1");
            }
        }
        return res;
    }

    private void transform(Value rset)
    {
        foreach (row; rset["rows"].list.items)
        {
            row["rolpassword"] = Value("");
            row["rolmembership"] = Value(parseMemberList(row["rolmembership"]));
            setSeclabels(row);
            if (row.contains("rolmembers") && !row["rolmembers"].isNone)
                row["rolmembers"] = Value(parseMemberList(row["rolmembers"]));
        }
    }

    private Response drop(Value ridArg)
    {
        Value data = ridArg.isNone ? formOrJson(request()) : Value.dictOf("ids", Value([ridArg]));
        foreach (rid; data["ids"].iterItems())
        {
            auto r = conn.executeDict(rtr("permission.sql", tv("rid", rid, "conn", conn)));
            if (!r.ok)
                return internalServerError(gettext("Error retrieving the role information.\n%s").replace("%s", r.error));
            if (r.value["rows"].length == 0)
                return gone(gettext("Could not find the role on the database server."));
            auto x = conn.execute2darray("DROP ROLE " ~ qtIdentStr(r.value["rows"][0]["rolname"].toString) ~ ";");
            if (!x.ok)
                return internalServerError(gettext("Could not drop the role.\n%s").replace("%s", x.error));
        }
        return successReturn();
    }

    private Response create(Value sid)
    {
        auto c = conn.executeDict(rtr(CREATE_SQL, tv("data", requestData, "dummy", false, "conn", conn)));
        if (!c.ok)
            return internalServerError(gettext("Could not create the role.\n%s").replace("%s", c.error));
        auto rr = conn.executeScalar("SELECT oid FROM pg_catalog.pg_roles WHERE rolname = %(rolname)s",
                Value.dictOf("rolname", requestData["rolname"]));
        if (!rr.ok)
            return internalServerError(fetchError(c.error.length ? c.error : ""));
        auto rid = rr.value;
        auto n = conn.executeDict(rtr(NODES_SQL, tv("rid", rid, "conn", conn)));
        if (!n.ok)
            return internalServerError(fetchError(n.error));
        foreach (row; n.value["rows"].list.items)
            return jsonify(Value.dictOf("node", gbn(rid, sid, row["rolname"].toString,
                    row["rolcanlogin"].truthy ? "icon-role" : "icon-group", kwDict("can_login", row["rolcanlogin"]))));
        return gone(notFoundErrorMsg());
    }

    private Response update(Value sid, Value rid)
    {
        auto c = conn.executeDict(rtr(UPDATE_SQL, tv("data", requestData, "dummy", false, "conn", conn, "role", role,
                "rolCanLogin", rolCanLogin, "rolSuper", rolSuper, "alterKeys", Value(alterKeys))));
        if (!c.ok)
            return internalServerError(gettext("Could not create the role.\n%s").replace("%s", c.error));
        auto n = conn.executeDict(rtr(NODES_SQL, tv("rid", rid, "conn", conn)));
        if (!n.ok)
            return internalServerError(fetchError(n.error));
        foreach (row; n.value["rows"].list.items)
            return jsonify(Value.dictOf("node", gbn(rid, sid, row["rolname"].toString,
                    row["rolcanlogin"].truthy ? "icon-role" : "icon-group",
                    kwDict("can_login", row["rolcanlogin"], "is_superuser", row["rolsuper"],
                        "description", row["description"]))));
        return gone(notFoundErrorMsg());
    }

    private Response voptions()
    {
        auto r = conn.executeDict(`
SELECT
name, vartype, min_val, max_val, enumvals
FROM
(
SELECT
    'role'::text AS name, 'string'::text AS vartype,
    NULL AS min_val, NULL AS max_val, NULL::text[] AS enumvals
UNION ALL
SELECT
    name, vartype, min_val::numeric AS min_val, max_val::numeric AS max_val,
    enumvals
FROM
    pg_show_all_settings()
WHERE
    context in ('user', 'superuser')
) a`);
        if (!r.ok)
            return internalServerError(gettext("Error retrieving the variable options for the role.\n%s").replace("%s", r.error));
        return makeJsonResponse(1, Value(""), Value(""), Value(null), r.value["rows"]);
    }

    private Value roleDependents(Value sid, Value rid)
    {
        static immutable string[string] types = [
            "r": "table", "i": null, "S": "sequence", "v": "view", "x": "external_table", "p": "function",
            "n": "schema", "y": "type", "d": "domain", "T": "trigger_function", "C": "conversion", "o": null
        ];
        auto q = conn.executeDict(rtr("dependents.sql", tv("fetch_database", true, "rid", rid)));
        auto dependents = Value.newList();
        auto mgr = getDriver().connectionManager(sid.integer);
        foreach (dbRow; q.value["rows"].list.items)
        {
            if (dbRow["type"] == Value("d"))
            {
                if (rid == dbRow["datdba"])
                    dependents.append(Value.dictOf("type", "database", "name", "", "field", dbRow["datname"]));
            }
            else
                dependents.append(Value.dictOf("type", "tablespace", "name", dbRow["datname"], "field", ""));
            if (!dbRow["datallowconn"].truthy)
                continue;
            bool isConnected = true;
            Connection temp;
            try
            {
                temp = mgr.connection(dbRow["datname"].toString);
                isConnected = temp.connected();
                if (!isConnected)
                    temp.connect();
            }
            catch (Exception)
            {
            }
            if (temp.connected())
            {
                auto res = temp.executeDict(rtr("dependents.sql", tv("fetch_dependents", true, "rid", rid,
                        "lastsysoid", DATABASE_LAST_SYSTEM_OID_)));
                if (!res.ok)
                    throw new Exception(res.error);
                foreach (row; res.value["rows"].list.items)
                {
                    string relName = row["nspname"].isNone ? null : row["nspname"].toString ~ ".";
                    relName = relName is null ? row["relname"].toString : relName ~ row["relname"].toString;
                    auto key = row["relkind"].toString[0 .. 1];
                    if (key !in types)
                        continue;
                    string typeName;
                    if (types[key] is null)
                    {
                        if (key == "i")
                        {
                            typeName = "index";
                            relName = row["indname"].toString ~ " ON " ~ relName;
                        }
                        else
                        {
                            typeName = "operator";
                            relName = row["relname"].toString;
                        }
                    }
                    else
                        typeName = types[key];
                    dependents.append(Value.dictOf("type", typeName, "name", relName, "field", dbRow["datname"]));
                }
            }
            if (!isConnected)
                mgr.release(dbRow["datname"].toString);
        }
        return dependents;
    }

    private Value reassignData()
    {
        auto data = Value.newDict();
        auto req = request();
        if (req.text.length)
            return parseJson(req.text);
        foreach (key; req.args.keys)
            data[key] = tryParseJson(req.args.get(key), Value(req.args.get(key)));
        return data;
    }

    private Response getReassignOwnSql()
    {
        try
        {
            auto data = reassignData();
            string[] required = data.contains("role_op") && data["role_op"] == Value("reassign")
                ? ["role_op", "did", "old_role_name", "new_role_name"] : ["role_op", "did", "drop_with_cascade"];
            foreach (arg; required)
                if (!data.contains(arg))
                    return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(gettext("-- definition incomplete")), 200);
            data["is_reassign"] = Value(data["role_op"] == Value("reassign"));
            auto sql = rtr(REASSIGN_OWN_SQL, tv("data", data));
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(sql.strip("\n")), 200);
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            throw new ViewReturnedNone;
    }

    private Response roleReassignOwn(Value sid, Value rid)
    {
        Value data;
        auto req = request();
        if (req.text.length)
            data = parseJson(req.text);
        else
        {
            data = Value.newDict();
            foreach (key; req.args.keys)
                data[key] = Value(req.args.get(key));
            foreach (key; req.form.keys)
                data[key] = Value(req.form.get(key));
        }
        long did = pyIntStrict(data["did"]);
        bool alreadyConnected, canDisconn = true;
        try
        {
            auto mgr = getDriver().connectionManager(sid.integer);
            auto c = mgr.connection(null, null, true, Value(did));
            alreadyConnected = c.connected();
            auto pgDb = manager.dbInfo[manager.did.toString];
            if (Value(did) == pgDb["did"])
                canDisconn = false;
            if (!alreadyConnected)
            {
                auto r = c.connect();
                if (!r.ok)
                    return internalServerError(r.error);
            }
            auto old = c.executeScalar(rtr(REASSIGN_OWN_SQL, tv("rid", rid, "data", Value(null))));
            if (!old.ok)
                throw new Exception(old.error);
            data["old_role_name"] = old.value;
            bool isReassign = data["role_op"] == Value("reassign");
            data["is_reassign"] = Value(isReassign);
            auto nrn = data.contains("new_role_name") ? data["new_role_name"] : Value(null);
            bool special = nrn == Value("CURRENT_USER") || nrn == Value("SESSION_USER") || nrn == Value("CURRENT_ROLE");
            if (isReassign && !special)
            {
                auto nn = c.executeScalar(rtr(REASSIGN_OWN_SQL, tv("rid", data["new_role_id"], "data", Value(null))));
                if (!nn.ok)
                    throw new Exception(nn.error);
                data["new_role_name"] = nn.value;
            }
            auto fin = c.executeScalar(rtr(REASSIGN_OWN_SQL, tv("rid", Value(null), "data", data)));
            if (!fin.ok)
                throw new Exception(fin.error);
            if (!alreadyConnected && canDisconn)
                mgr.release(null, null, Value(did));
            return makeJsonResponse(1, Value(""), Value(isReassign ? gettext("Reassign owned executed successfully!")
                    : gettext("Drop owned executed successfully!")));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
        {
            if (!alreadyConnected && canDisconn)
                manager.release(null, null, Value(did));
            return internalServerError(e.msg);
        }
    }
}
