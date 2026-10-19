/// `tables/constraints`: the "Constraints" collection and the node types below it (check, exclusion, foreign key,
/// primary key and unique constraints).
module pgadmin.browser.server_groups.servers.databases.schemas.tables.constraints;

import std.algorithm : canFind;
import pgadmin.browser.common;
import pgadmin.web.flask : View;
import checkUtils = pgadmin.browser.server_groups.servers.databases.schemas.tables.constraints.check_constraint.utils;
import exclusionUtils = pgadmin.browser.server_groups.servers.databases.schemas.tables.constraints.exclusion_constraint.utils;
import fkeyUtils = pgadmin.browser.server_groups.servers.databases.schemas.tables.constraints.foreign_key.utils;
import idxconsUtils = pgadmin.browser.server_groups.servers.databases.schemas.tables.constraints.index_constraint.utils;
import pgadmin.browser.server_groups.servers.databases.schemas.utils : checkPgstattuple;

/// The node view classes of the constraint types, in registration order (`ConstraintRegistry`).
/// (`tables/utils.py` imports the foreign key package first, so it registers first.)
private immutable string[] constraintTypes = ["foreign_key", "check_constraint", "exclusion_constraint", "primary_key",
    "unique_constraint"];

final class ConstraintsModule : CollectionNodeModule
{
    enum NODE_TYPE = "constraints";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "Constraints";
        minVer = Value(null);
        maxVer = Value(null);
        staticDir("browser/server_groups/servers/databases/schemas/tables/constraints");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => "database";
    override bool moduleUseTemplateJavascript() => false;

    override Value[] getNodes(Dict kwargs)
    {
        auto tid = kwargs.has("tid") ? kwargs["tid"] : kwargs.has("vid") ? kwargs["vid"] : kwargs["foid"];
        Value[] nodes;
        foreach (name; constraintTypes)
            nodes ~= Value(name);
        auto node = generateBrowserCollectionNode(tid);
        node["nodes"] = Value(nodes);
        return [Value(node)];
    }

    override void setup()
    {
        submodules ~= new CheckConstraintModule;
        submodules ~= new ExclusionConstraintModule;
        submodules ~= new ForeignKeyConstraintModule;
        submodules ~= new PrimaryKeyConstraintModule;
        submodules ~= new UniqueConstraintModule;
        enum idRule = "/<int:gid>/<int:sid>/<int:did>/<int:scid>/<int:tid>/";
        route("/nodes" ~ idRule, "nodes", ["GET"], (Dict args) {
            if (!isAuthenticated())
                return unauthorisedResponse();
            Value[] res;
            foreach (v; allViews(args))
                res ~= v.getNodesList(args);
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        });
        route("/obj" ~ idRule, "proplist", ["GET"], (Dict args) {
            if (!isAuthenticated())
                return unauthorisedResponse();
            Value[] res;
            foreach (v; allViews(args))
                res ~= v.getNodeListRows(args).list.items;
            return makeResponse(Value(res), 200);
        });
        View del = (Dict args) => deleteConstraints(args);
        route("/obj" ~ idRule, "delete", ["DELETE"], del);
        route("/delete" ~ idRule, "delete", ["DELETE"], del);
    }

    private ConstraintViewBase[] allViews(Dict args)
    {
        ConstraintViewBase[] views;
        foreach (name; constraintTypes)
            views ~= viewFor(name);
        return views;
    }

    private ConstraintViewBase viewFor(string name)
    {
        switch (name)
        {
        case "check_constraint": return makeView!CheckConstraintView();
        case "exclusion_constraint": return makeView!ExclusionConstraintView();
        case "foreign_key": return makeView!ForeignKeyConstraintView();
        case "primary_key": return makeView!PrimaryKeyConstraintView();
        default: return makeView!UniqueConstraintView();
        }
    }

    private Response deleteConstraints(Dict args)
    {
        if (!isAuthenticated())
            return unauthorisedResponse();
        auto data = formOrJson(request());
        Value[][string] moduleWiseData;
        foreach (d; data["ids"].iterItems())
            moduleWiseData[d["_type"].toString] ~= d["id"];
        foreach (name; constraintTypes)
            if (auto ids = name in moduleWiseData)
            {
                auto view = viewFor(name);
                auto body_ = Value.dictOf("ids", Value(*ids)).toJson();
                request().data = cast(immutable(ubyte)[]) body_;
                auto response = view.callMethod("delete", args);
                auto res = parseJson(response.body);
                if (!res["success"].truthy)
                    return response;
            }
        return makeJsonResponse(1, Value(""), Value(gettext("Constraints dropped.")));
    }
}

/// `ConstraintTypeModule`: the module of one constraint type.
abstract class ConstraintTypeModule : CollectionNodeModule
{
    this(string nodeTypeName)
    {
        super(nodeTypeName);
        minVer = Value(null);
        maxVer = Value(null);
    }

    override string scriptLoad() => "database";
    override bool nodeInode() => false;
    override bool moduleUseTemplateJavascript() => false;
    override Value[] getNodes(Dict kwargs) => null;
}

final class CheckConstraintModule : ConstraintTypeModule
{
    enum NODE_TYPE = "check_constraint";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "Check Constraints";
        staticDir("browser/server_groups/servers/databases/schemas/tables/constraints/check_constraint");
    }

    override string nodeType() => NODE_TYPE;
    override Value[] getNodes(Dict kwargs) => [generateBrowserCollectionNode(kwargs["doid"])];

    override string[] csssnippets() => [
        renderTemplate("check_constraint/css/check_constraint.css", ["node_type": Value(nodeType)])
    ];

    override void setup()
    {
        registerNodeView!CheckConstraintView(this);
    }
}

final class ExclusionConstraintModule : ConstraintTypeModule
{
    enum NODE_TYPE = "exclusion_constraint";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "Exclusion Constraints";
        staticDir("browser/server_groups/servers/databases/schemas/tables/constraints/exclusion_constraint");
    }

    override string nodeType() => NODE_TYPE;

    override void setup()
    {
        registerNodeView!ExclusionConstraintView(this);
    }
}

final class ForeignKeyConstraintModule : ConstraintTypeModule
{
    enum NODE_TYPE = "foreign_key";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "Foreign Keys";
        staticDir("browser/server_groups/servers/databases/schemas/tables/constraints/foreign_key");
    }

    override string nodeType() => NODE_TYPE;

    override string[] csssnippets()
    {
        string[] snippets = [
            renderTemplate("browser/css/collection.css", ["node_type": Value(nodeType)]),
            renderTemplate("foreign_key/css/foreign_key.css", ["node_type": Value(nodeType)]),
        ];
        foreach (m; submodules)
            if (auto b = cast(BrowserPluginModule) m)
                snippets ~= b.csssnippets;
        return snippets;
    }

    override void setup()
    {
        registerNodeView!ForeignKeyConstraintView(this);
    }
}

final class PrimaryKeyConstraintModule : ConstraintTypeModule
{
    enum NODE_TYPE = "primary_key";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "Primary Key";
        staticDir("browser/server_groups/servers/databases/schemas/tables/constraints/index_constraint");
    }

    override string nodeType() => NODE_TYPE;

    override void setup()
    {
        registerNodeView!PrimaryKeyConstraintView(this);
    }
}

final class UniqueConstraintModule : ConstraintTypeModule
{
    enum NODE_TYPE = "unique_constraint";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "Unique Constraint";
        staticDir("browser/server_groups/servers/databases/schemas/tables/constraints/index_constraint");
    }

    override string nodeType() => NODE_TYPE;

    override void setup()
    {
        registerNodeView!UniqueConstraintView(this);
    }
}

// ---------------------------------------------------------------- views

/// What the container needs of every constraint view.
abstract class ConstraintViewBase : PGChildNodeView
{
    string schema;
    string table;

    abstract string pathBase();
    abstract void parentOf(Value tid, out string schema, out string table);
    abstract Value[] getNodesList(Dict kwargs);
    abstract Value getNodeListRows(Dict kwargs);

    /// `check_precondition` of the constraint views: sets manager, connection, template path, schema and table.
    Response constraintPrecondition(Dict k, string action)
    {
        auto err = standardPrecondition(k, action, pathBase());
        if (err !is null)
            return err;
        parentOf(k["tid"], schema, table);
        return null;
    }

    /// The set-up `get_nodes` / `get_node_list` do by hand (they are not wrapped by the precondition).
    void manualPrecondition(Value sid, Value did, Value tid)
    {
        manager = getDriver().connectionManager(sid.integer);
        conn = manager.connection(null, null, true, did);
        templatePath = pathBase().replace("{0}", to!string(manager.version_));
        parentOf(tid, schema, table);
    }

    void endTransaction()
    {
        conn.executeScalar(rt("end.sql"));
    }

    Response unauthorized() => unauthorisedResponse();

    Dict idKwargs(string name, Value id)
    {
        auto d = new Dict;
        d[name] = id;
        return d;
    }
}

private string stripEnd(string s) => s.strip("\n").strip(" ");

// ---------------------------------------------------------------- check constraints

final class CheckConstraintView : ConstraintViewBase
{
    enum CHECK_CONSTRAINT_PATH = "check_constraint/sql/#{0}#";

    override string pathBase() => CHECK_CONSTRAINT_PATH;

    override void parentOf(Value tid, out string schema, out string table)
    {
        checkUtils.getParent(conn, tid, schema, table);
    }

    this()
    {
        super();
        nodeType = CheckConstraintModule.NODE_TYPE;
        parentIds = [IdSpec("int", "gid"), IdSpec("int", "sid"), IdSpec("int", "did"), IdSpec("int", "scid"),
            IdSpec("int", "tid")];
        ids = [IdSpec("int", "cid")];
        setAllOps([
            makeOp("obj", ["get": "properties", "delete": "delete", "put": "update"],
                    ["get": "list", "post": "create", "delete": "delete"]),
            makeOp("delete", ["delete": "delete"], ["delete": "delete"]),
            makeOp("children", ["get": "children"]),
            makeOp("nodes", ["get": "node"], ["get": "nodes"]),
            makeOp("sql", ["get": "sql"]),
            makeOp("msql", ["get": "msql"], ["get": "msql"]),
            makeOp("stats", ["get": "statistics"]),
            makeOp("dependency", ["get": "dependencies"]),
            makeOp("dependent", ["get": "dependents"]),
            makeOp("validate", ["get": "validate_check_constraint"]),
        ]);
    }

    private static void iconAndValid(Value row, out string icon, out bool valid)
    {
        if (row.contains("convalidated") && row["convalidated"].truthy)
        {
            icon = "icon-check_constraint_bad";
            valid = false;
        }
        else
        {
            icon = "icon-check_constraint";
            valid = true;
        }
    }

    override Value getNodeListRows(Dict k)
    {
        manualPrecondition(k["sid"], k["did"], k["tid"]);
        auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("tid", k["tid"])));
        foreach (row; r.value["rows"].list.items)
            row["_type"] = Value(nodeType);
        return r.value["rows"];
    }

    override Value[] getNodesList(Dict k)
    {
        manualPrecondition(k["sid"], k["did"], k["tid"]);
        auto r = conn.execute2darray(rt(NODES_SQL, tv("tid", k["tid"])));
        Value[] res;
        foreach (row; r.value["rows"].list.items)
        {
            string icon;
            bool valid;
            iconAndValid(row, icon, valid);
            res ~= gbn(row["oid"], k["tid"], row["name"].toString, icon, kwDict("valid", valid));
        }
        return res;
    }

    override Response callMethod(string name, Dict k)
    {
        if (!isAuthenticated())
            return unauthorisedResponse();
        if (name == "children")
            return children(k);
        auto err = constraintPrecondition(k, name);
        if (err !is null)
            return err;
        auto gid = k.has("gid") ? k["gid"] : Value(null);
        auto sid = k["sid"];
        auto did = k["did"];
        auto scid = k["scid"];
        auto tid = k["tid"];
        auto cid = k.has("cid") ? k["cid"] : Value(null);
        switch (name)
        {
        case "list":
        {
            try
                return makeResponse(getNodeListRows(k), 200);
            catch (HTTPException e)
                throw e;
            catch (Exception e)
                return internalServerError(e.msg);
        }
        case "node":
        {
            auto r = conn.execute2darray(rt(NODES_SQL, tv("tid", tid, "cid", cid)));
            if (r.value["rows"].length == 0)
                return gone(gettext("Could not find the check constraint."));
            auto row = r.value["rows"][0];
            string icon;
            bool valid;
            iconAndValid(row, icon, valid);
            return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    gbn(row["oid"], tid, row["name"].toString, icon, kwDict("valid", valid)), 200);
        }
        case "nodes":
        {
            auto r = conn.execute2darray(rt(NODES_SQL, tv("tid", tid)));
            Value[] res;
            foreach (row; r.value["rows"].list.items)
            {
                string icon;
                bool valid;
                iconAndValid(row, icon, valid);
                res ~= gbn(row["oid"], tid, row["name"].toString, icon,
                        kwDict("valid", valid, "description", row["comment"]));
                // the Python code returns from inside the loop: only the first constraint is listed
                return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
            }
            throw new ViewReturnedNone;
        }
        case "properties":
        {
            auto r = checkUtils.getCheckConstraints(conn, tid, cid);
            if (!r.ok)
                return internalServerError(r.error);
            if (r.value.length == 0)
                return gone(gettext("Could not find the check constraint in the table."));
            auto result = r.value[0];
            result["is_sys_obj"] = Value(result["oid"].integer <= DATABASE_LAST_SYSTEM_OID_ || datistemplate);
            return makeResponse(result, 200);
        }
        case "create": return create(tid);
        case "delete": return delete_(tid, cid);
        case "update": return update(tid, cid);
        case "sql": return sqlView(tid, cid);
        case "msql": return msql(tid, cid);
        case "dependents": return makeResponse(getDependents(conn, cid), 200);
        case "dependencies": return makeResponse(getDependencies(conn, cid), 200);
        case "validate_check_constraint": return validate(scid, did, tid, cid);
        default: return super.callMethod(name, k);
        }
    }

    private Response create(Value tid)
    {
        auto data = loadJsonValues(formOrJson(request()), "comment");
        if (!data.contains("consrc") || data["consrc"] == Value(""))
            return makeJsonResponse(0, Value(gettext("Could not find the required parameter ({}).").replace("{}", "consrc")),
                    Value(""), Value(null), Value(null), 400);
        data["schema"] = Value(schema);
        data["table"] = Value(table);
        if (table.length == 0)
            return gone(gettext(notFoundErrorMsg("Table")));
        try
        {
            bool noName = !data.contains("name") || data["name"] == Value("");
            if (noName)
            {
                auto b = conn.executeScalar("BEGIN;");
                if (!b.ok)
                {
                    endTransaction();
                    return internalServerError(b.error);
                }
            }
            auto c = conn.executeScalar(rt(CREATE_SQL, tv("data", data, "conn", conn)));
            if (!c.ok)
            {
                endTransaction();
                return internalServerError(c.error);
            }
            Value res;
            if (noName)
            {
                auto o = conn.executeDict(rt("get_oid_with_transaction.sql", tv("tid", tid)));
                if (!o.ok)
                {
                    endTransaction();
                    return internalServerError(o.error);
                }
                endTransaction();
                res = o.value;
                data["name"] = res["rows"][0]["name"];
            }
            else
            {
                auto o = conn.executeDict(rt(OID_SQL, tv("tid", tid, "name", data["name"], "conn", conn)));
                if (!o.ok)
                {
                    endTransaction();
                    return internalServerError(o.error);
                }
                res = o.value;
            }
            string icon;
            bool valid;
            iconAndValid(res["rows"][0], icon, valid);
            return jsonify(Value.dictOf("node", gbn(res["rows"][0]["oid"], tid, data["name"].toString, icon,
                    kwDict("valid", valid))));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
        {
            endTransaction();
            return makeJsonResponse(0, Value(e.msg), Value(""), Value(null), Value(null), 400);
        }
    }

    private Response delete_(Value tid, Value cidArg)
    {
        Value data = cidArg.isNone ? formOrJson(request()) : Value.dictOf("ids", Value([cidArg]));
        try
        {
            foreach (cid; data["ids"].iterItems())
            {
                auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("tid", tid, "cid", cid)));
                if (!r.ok)
                    return internalServerError(r.error);
                if (r.value["rows"].length == 0)
                    return makeJsonResponse(0, Value(gettext("Error: Object not found.")),
                            Value(gettext("The specified check constraint could not be found.\n")));
                auto x = conn.executeScalar(rt(DELETE_SQL, tv("data", r.value["rows"][0])));
                if (!x.ok)
                    return internalServerError(x.error);
            }
            return makeJsonResponse(1, Value(""), Value(gettext("Check constraint dropped.")));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response update(Value tid, Value cid)
    {
        auto data = formOrJson(request());
        try
        {
            data["schema"] = Value(schema);
            data["table"] = Value(table);
            Value name;
            auto sql = checkUtils.getSql(conn, data, tid, cid, name);
            if (!sql.length)
                return new Response(name.toString); // Python returns the bare name here
            sql = stripEnd(sql);
            auto x = conn.executeScalar(sql);
            if (!x.ok)
                return internalServerError(x.error);
            auto n = conn.executeDict(rt("get_name.sql", tv("cid", cid)));
            if (!n.ok)
                return internalServerError(n.error);
            string icon;
            bool valid;
            iconAndValid(n.value["rows"][0], icon, valid);
            auto extra = kwDict("valid", valid);
            if (data.contains("comment"))
                extra["description"] = data["comment"];
            return jsonify(Value.dictOf("node", gbn(cid, tid, name.toString, icon, extra)));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response sqlView(Value tid, Value cid)
    {
        auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("tid", tid, "cid", cid)));
        if (!r.ok)
            return internalServerError(r.error);
        if (r.value["rows"].length == 0)
            return gone(gettext("Could not find the object on the server."));
        auto data = r.value["rows"][0];
        data["schema"] = Value(schema);
        data["table"] = Value(table);
        auto sql = rt(CREATE_SQL, tv("data", data, "conn", conn));
        auto header = "-- Constraint: " ~ data["name"].toString ~ "\n\n-- ";
        header ~= rt(DELETE_SQL, tv("data", data));
        header ~= "\n";
        return makeResponse(Value(header ~ sql));
    }

    private Response msql(Value tid, Value cid)
    {
        auto data = msqlData("comment");
        data["schema"] = Value(schema);
        data["table"] = Value(table);
        try
        {
            Value name;
            auto sql = checkUtils.getSql(conn, data, tid, cid, name);
            if (!sql.length)
                return new Response(name.toString); // Python returns the bare name here
            sql = stripEnd(sql);
            if (sql == "")
                sql = "--modified SQL";
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(sql), 200);
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response validate(Value scid, Value did, Value tid, Value cid)
    {
        auto data = Value.newDict();
        try
        {
            data["schema"] = Value(schema);
            data["table"] = Value(table);
            auto n = conn.executeScalar(rt("get_name.sql", tv("cid", cid)));
            if (!n.ok)
                return internalServerError(n.error);
            data["name"] = n.value;
            auto v = conn.executeDict(rt("validate.sql", tv("data", data)));
            if (!v.ok)
                return internalServerError(v.error);
            return makeJsonResponse(1, Value(""), Value(gettext("Check constraint updated.")), Value(null),
                    Value.dictOf("id", cid, "tid", tid, "scid", scid, "did", did), 200);
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }
}

// ---------------------------------------------------------------- exclusion constraints

final class ExclusionConstraintView : ConstraintViewBase
{
    enum EXCLUSION_CONSTRAINT_PATH = "exclusion_constraint/sql/#{0}#";

    override string pathBase() => EXCLUSION_CONSTRAINT_PATH;

    override void parentOf(Value tid, out string schema, out string table)
    {
        exclusionUtils.getParent(conn, tid, schema, table);
    }

    this()
    {
        super();
        nodeType = ExclusionConstraintModule.NODE_TYPE;
        parentIds = [IdSpec("int", "gid"), IdSpec("int", "sid"), IdSpec("int", "did"), IdSpec("int", "scid"),
            IdSpec("int", "tid")];
        ids = [IdSpec("int", "exid")];
        setAllOps([
            makeOp("obj", ["get": "properties", "delete": "delete", "put": "update"],
                    ["get": "list", "post": "create", "delete": "delete"]),
            makeOp("delete", ["delete": "delete"], ["delete": "delete"]),
            makeOp("children", ["get": "children"]),
            makeOp("nodes", ["get": "node"], ["get": "nodes"]),
            makeOp("sql", ["get": "sql"]),
            makeOp("msql", ["get": "msql"], ["get": "msql"]),
            makeOp("stats", ["get": "statistics"]),
            makeOp("dependency", ["get": "dependencies"]),
            makeOp("dependent", ["get": "dependents"]),
        ]);
    }

    override Value getNodeListRows(Dict k)
    {
        manualPrecondition(k["sid"], k["did"], k["tid"]);
        auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("did", k["did"], "tid", k["tid"])));
        foreach (row; r.value["rows"].list.items)
            row["_type"] = Value(nodeType);
        return r.value["rows"];
    }

    override Value[] getNodesList(Dict k)
    {
        manualPrecondition(k["sid"], k["did"], k["tid"]);
        auto r = conn.execute2darray(rt(NODES_SQL, tv("tid", k["tid"])));
        Value[] res;
        foreach (row; r.value["rows"].list.items)
            res ~= gbn(row["oid"], k["tid"], row["name"].toString, "icon-exclusion_constraint");
        return res;
    }

    override Response callMethod(string name, Dict k)
    {
        if (!isAuthenticated())
            return unauthorisedResponse();
        if (name == "children")
            return children(k);
        auto err = constraintPrecondition(k, name);
        if (err !is null)
            return err;
        auto did = k["did"];
        auto tid = k["tid"];
        auto exid = k.has("exid") ? k["exid"] : Value(null);
        switch (name)
        {
        case "list":
        {
            try
                return makeResponse(getNodeListRows(k), 200);
            catch (HTTPException e)
                throw e;
            catch (Exception e)
                return internalServerError(e.msg);
        }
        case "node":
        {
            auto r = conn.execute2darray(rt(NODES_SQL, tv("tid", tid, "exid", exid)));
            if (r.value["rows"].length == 0)
                return gone(gettext("Could not find the exclusion constraint."));
            auto row = r.value["rows"][0];
            return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    gbn(row["oid"], tid, row["name"].toString, "icon-exclusion_constraint"), 200);
        }
        case "nodes":
        {
            auto r = conn.execute2darray(rt(NODES_SQL, tv("tid", tid)));
            Value[] res;
            foreach (row; r.value["rows"].list.items)
                res ~= gbn(row["oid"], tid, row["name"].toString, "icon-exclusion_constraint",
                        kwDict("description", row["comment"]));
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        case "properties":
        {
            auto r = exclusionUtils.getExclusionConstraints(conn, did, tid, exid);
            if (!r.ok)
                return internalServerError(r.error);
            if (r.value.length == 0)
                return gone(gettext("Could not find the exclusion constraint in the table."));
            auto result = r.value[0];
            result["is_sys_obj"] = Value(result["oid"].integer <= DATABASE_LAST_SYSTEM_OID_ || datistemplate);
            return makeResponse(result, 200);
        }
        case "create": return create(did, tid);
        case "update": return update(did, tid, exid);
        case "delete": return delete_(tid, exid);
        case "msql": return msql(did, tid, exid);
        case "sql": return sqlView(did, tid, exid);
        case "statistics": return statistics(tid, exid);
        case "dependents": return makeResponse(getDependents(conn, exid), 200);
        case "dependencies": return makeResponse(getDependencies(conn, exid), 200);
        default: return super.callMethod(name, k);
        }
    }

    private Response create(Value did, Value tid)
    {
        auto data = loadJsonValues(parseJson(request().text), "comment");
        foreach (arg; ["columns"])
            if (!data.contains(arg) || (data[arg].isList && data[arg].length < 1))
                return makeJsonResponse(0, Value(gettext("Could not find required parameter ({}).").replace("{}", arg)),
                        Value(""), Value(null), Value(null), 400);
        data["schema"] = Value(schema);
        data["table"] = Value(table);
        try
        {
            bool noName = data.dict.get("name", Value("")) == Value("");
            if (noName)
            {
                auto b = conn.executeScalar(rt("begin.sql"));
                if (!b.ok)
                {
                    endTransaction();
                    return internalServerError(b.error);
                }
            }
            auto c = conn.executeScalar(rt(CREATE_SQL, tv("data", data, "conn", conn)));
            if (!c.ok)
            {
                endTransaction();
                return internalServerError(c.error);
            }
            Value res;
            if (noName)
            {
                auto o = conn.executeDict(rt("get_oid_with_transaction.sql", tv("tid", tid)));
                if (!o.ok)
                {
                    endTransaction();
                    return internalServerError(o.error);
                }
                endTransaction();
                res = o.value;
                data["name"] = res["rows"][0]["name"];
            }
            else
            {
                auto o = conn.executeDict(rt(OID_SQL, tv("name", data["name"], "conn", conn)));
                if (!o.ok)
                {
                    endTransaction();
                    return internalServerError(o.error);
                }
                res = o.value;
            }
            return jsonify(Value.dictOf("node", gbn(res["rows"][0]["oid"], tid, data["name"].toString,
                    "icon-exclusion_constraint")));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
        {
            endTransaction();
            return makeJsonResponse(0, Value(e.msg), Value(""), Value(null), Value(null), 400);
        }
    }

    private Response update(Value did, Value tid, Value exid)
    {
        auto data = formOrJson(request());
        try
        {
            data["schema"] = Value(schema);
            data["table"] = Value(table);
            Value name;
            auto sql = exclusionUtils.getSql(conn, data, did, tid, exid, name);
            sql = stripEnd(sql);
            auto x = conn.executeScalar(sql);
            if (!x.ok)
                return internalServerError(x.error);
            auto o = conn.executeDict(rt(OID_SQL, tv("name", data["name"], "conn", conn)));
            if (!o.ok)
                return internalServerError(o.error);
            Dict extra;
            if (data.contains("comment"))
                extra = kwDict("description", data["comment"]);
            return jsonify(Value.dictOf("node", gbn(exid, tid, name.toString, "icon-" ~ nodeType, extra)));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response delete_(Value tid, Value exidArg)
    {
        Value data = exidArg.isNone ? formOrJson(request()) : Value.dictOf("ids", Value([exidArg]));
        bool cascade = checkCascadeOperation();
        try
        {
            foreach (exid; data["ids"].iterItems())
            {
                auto r = conn.executeDict(rt("get_name.sql", tv("cid", exid)));
                if (!r.ok)
                    return internalServerError(r.error);
                if (r.value["rows"].length == 0)
                    return makeJsonResponse(0, Value(gettext("Error: Object not found.")),
                            Value(gettext("The specified exclusion constraint could not be found.\n")));
                auto row = r.value["rows"][0];
                row["schema"] = Value(schema);
                row["table"] = Value(table);
                auto x = conn.executeScalar(rt(DELETE_SQL, tv("data", row, "cascade", cascade)));
                if (!x.ok)
                    return internalServerError(x.error);
            }
            return makeJsonResponse(1, Value(""), Value(gettext("Exclusion constraint dropped.")));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response msql(Value did, Value tid, Value exid)
    {
        auto data = msqlData("comment");
        data["schema"] = Value(schema);
        data["table"] = Value(table);
        try
        {
            Value name;
            auto sql = exclusionUtils.getSql(conn, data, did, tid, exid, name);
            sql = stripEnd(sql);
            if (sql == "")
                sql = "--modified SQL";
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(sql), 200);
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response sqlView(Value did, Value tid, Value exid)
    {
        try
        {
            auto r = exclusionUtils.getExclusionConstraints(conn, did, tid, exid, templatePath);
            if (!r.ok)
                return internalServerError(r.error);
            if (r.value.length == 0)
                return gone(gettext("Could not find the exclusion constraint."));
            auto data = r.value[0];
            data["schema"] = Value(schema);
            data["table"] = Value(table);
            auto sql = rt(CREATE_SQL, tv("data", data, "conn", conn));
            auto header = "-- Constraint: " ~ data["name"].toString ~ "\n\n-- ";
            header ~= rt(DELETE_SQL, tv("data", data));
            header ~= "\n";
            return makeResponse(Value(header ~ sql));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response statistics(Value tid, Value exid)
    {
        auto p = checkPgstattuple(conn, tid);
        if (!p.ok)
            return internalServerError(p.error);
        Value name = Value(null);
        if (p.value.truthy)
        {
            auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("did", Value(null), "tid", tid, "conn", conn, "cid", exid)));
            if (!r.ok)
                return internalServerError(r.error);
            if (r.value["rows"].length == 0)
                return gone(gettext("Could not find the exclusion constraint."));
            name = r.value["rows"][0]["name"];
        }
        auto s = conn.executeDict(rt("stats.sql", tv("conn", conn, "schema", schema, "name", name, "exid", exid,
                "is_pgstattuple", p.value)));
        if (!s.ok)
            return internalServerError(s.error);
        return makeJsonResponse(1, Value(""), Value(""), Value(null), s.value, 200);
    }
}

// ---------------------------------------------------------------- foreign keys

final class ForeignKeyConstraintView : ConstraintViewBase
{
    enum FOREIGN_KEY_PATH = "foreign_key/sql/#{0}#";

    override string pathBase() => FOREIGN_KEY_PATH;

    override void parentOf(Value tid, out string schema, out string table)
    {
        fkeyUtils.getParent(conn, tid, schema, table);
    }

    static string FOREIGN_KEY_NOT_FOUND() => gettext("Could not find the foreign key.");

    this()
    {
        super();
        nodeType = ForeignKeyConstraintModule.NODE_TYPE;
        parentIds = [IdSpec("int", "gid"), IdSpec("int", "sid"), IdSpec("int", "did"), IdSpec("int", "scid"),
            IdSpec("int", "tid")];
        ids = [IdSpec("int", "fkid")];
        setAllOps([
            makeOp("obj", ["get": "properties", "delete": "delete", "put": "update"],
                    ["get": "list", "post": "create", "delete": "delete"]),
            makeOp("delete", ["delete": "delete"], ["delete": "delete"]),
            makeOp("children", ["get": "children"]),
            makeOp("nodes", ["get": "node"], ["get": "nodes"]),
            makeOp("sql", ["get": "sql"]),
            makeOp("msql", ["get": "msql"], ["get": "msql"]),
            makeOp("stats", ["get": "statistics"]),
            makeOp("dependency", ["get": "dependencies"]),
            makeOp("dependent", ["get": "dependents"]),
            makeOp("indices", null, ["get": "get_indices"]),
            makeOp("validate", ["get": "validate_foreign_key"]),
            makeOp("get_coveringindex", null, ["get": "get_coveringindex"]),
        ]);
    }

    override Value getNodeListRows(Dict k)
    {
        manualPrecondition(k["sid"], k["did"], k["tid"]);
        auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("tid", k["tid"])));
        foreach (row; r.value["rows"].list.items)
            row["_type"] = Value(nodeType);
        return r.value["rows"];
    }

    private static void iconAndValid(Value row, out string icon, out bool valid)
    {
        if (row["convalidated"].truthy)
        {
            icon = "icon-foreign_key_no_validate";
            valid = false;
        }
        else
        {
            icon = "icon-foreign_key";
            valid = true;
        }
    }

    override Value[] getNodesList(Dict k)
    {
        manualPrecondition(k["sid"], k["did"], k["tid"]);
        auto r = conn.execute2darray(rt(NODES_SQL, tv("tid", k["tid"])));
        Value[] res;
        foreach (row; r.value["rows"].list.items)
        {
            string icon;
            bool valid;
            iconAndValid(row, icon, valid);
            res ~= gbn(row["oid"], k["tid"], row["name"].toString, icon,
                    kwDict("valid", valid, "description", row["comment"]));
        }
        return res;
    }

    override Response callMethod(string name, Dict k)
    {
        if (!isAuthenticated())
            return unauthorisedResponse();
        if (name == "children")
            return children(k);
        auto err = constraintPrecondition(k, name);
        if (err !is null)
            return err;
        auto scid = k["scid"];
        auto did = k["did"];
        auto tid = k["tid"];
        auto fkid = k.has("fkid") ? k["fkid"] : Value(null);
        switch (name)
        {
        case "properties":
        {
            auto r = fkeyUtils.getForeignKeys(conn, tid, fkid);
            if (!r.ok)
                return internalServerError(r.error);
            if (r.value.length == 0)
                return gone(FOREIGN_KEY_NOT_FOUND());
            auto result = fkid.truthy ? r.value[0] : r.value;
            result["is_sys_obj"] = Value(result["oid"].integer <= DATABASE_LAST_SYSTEM_OID_ || datistemplate);
            return makeResponse(result, 200);
        }
        case "list":
        {
            try
            {
                auto res = getNodeListRows(k);
                if (!fkid.isNone)
                {
                    foreach (fk; res.iterItems())
                        if (fk["oid"] == fkid)
                            return makeResponse(fk, 200);
                    return gone(FOREIGN_KEY_NOT_FOUND());
                }
                throw new Exception("cannot access local variable 'foreign_key' where it is not associated with a value");
            }
            catch (HTTPException e)
                throw e;
            catch (Exception e)
                return internalServerError(e.msg);
        }
        case "node":
        {
            auto r = conn.execute2darray(rt(NODES_SQL, tv("tid", tid)));
            if (r.value["rows"].length == 0)
                return gone(FOREIGN_KEY_NOT_FOUND());
            auto row = r.value["rows"][0];
            string icon;
            bool valid;
            iconAndValid(row, icon, valid);
            return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    gbn(row["oid"], tid, row["name"].toString, icon, kwDict("valid", valid)), 200);
        }
        case "nodes":
        {
            Value[] res;
            foreach (n; getNodesList(k))
                res ~= n;
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        case "create": return create(tid);
        case "update": return update(tid, fkid);
        case "delete": return delete_(tid, fkid);
        case "msql": return msql(tid, fkid);
        case "sql": return sqlView(tid, fkid);
        case "dependents": return makeResponse(getDependents(conn, fkid), 200);
        case "dependencies": return makeResponse(getDependencies(conn, fkid), 200);
        case "validate_foreign_key": return validate(scid, did, tid, fkid);
        case "get_coveringindex": return coveringIndex(tid);
        default: return super.callMethod(name, k);
        }
    }

    private Response create(Value tid)
    {
        auto data = loadJsonValues(formOrJson(request()), "comment");
        if (!data.contains("columns") || (data["columns"].isList && data["columns"].length < 1))
            return makeJsonResponse(0, Value(gettext("Could not find required parameter ({}).").replace("{}", "columns")),
                    Value(""), Value(null), Value(null), 400);
        data["schema"] = Value(schema);
        data["table"] = Value(table);
        try
        {
            string rs, rt_;
            fkeyUtils.getParent(conn, data["columns"][0]["references"], rs, rt_);
            data["remote_schema"] = Value(rs);
            data["remote_table"] = Value(rt_);
            bool noName = !data.contains("name") || data["name"] == Value("");
            if (noName)
            {
                auto b = conn.executeScalar(rt("begin.sql"));
                if (!b.ok)
                {
                    endTransaction();
                    return internalServerError(b.error);
                }
            }
            auto c = conn.executeScalar(rt(CREATE_SQL, tv("data", data, "conn", conn)));
            if (!c.ok)
            {
                endTransaction();
                return internalServerError(c.error);
            }
            Value res;
            if (noName)
            {
                auto o = conn.executeDict(rt("get_oid_with_transaction.sql", tv("tid", tid)));
                if (!o.ok)
                {
                    endTransaction();
                    return internalServerError(o.error);
                }
                endTransaction();
                res = o.value;
                data["name"] = res["rows"][0]["name"];
            }
            else
            {
                auto o = conn.executeDict(rt(OID_SQL, tv("name", data["name"], "conn", conn)));
                if (!o.ok)
                {
                    endTransaction();
                    return internalServerError(o.error);
                }
                res = o.value;
            }
            string icon;
            bool valid;
            iconAndValid(res["rows"][0], icon, valid);
            if (data["autoindex"].truthy)
            {
                auto sql = stripEnd(rt("create_index.sql", tv("data", data, "conn", conn)));
                if (sql != "")
                {
                    auto idx = conn.executeScalar(sql);
                    if (!idx.ok)
                    {
                        endTransaction();
                        return internalServerError(idx.error);
                    }
                }
            }
            auto extra = kwDict("valid", valid);
            if (data.contains("comment"))
                extra["description"] = data["comment"];
            return jsonify(Value.dictOf("node", gbn(res["rows"][0]["oid"], tid, data["name"].toString, icon, extra)));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
        {
            endTransaction();
            return makeJsonResponse(0, Value(e.msg), Value(""), Value(null), Value(null), 400);
        }
    }

    private Response update(Value tid, Value fkid)
    {
        auto data = formOrJson(request());
        try
        {
            data["schema"] = Value(schema);
            data["table"] = Value(table);
            Value name;
            auto sql = stripEnd(fkeyUtils.getSql(conn, data, tid, fkid, name));
            auto x = conn.executeScalar(sql);
            if (!x.ok)
                return internalServerError(x.error);
            auto o = conn.executeDict(rt(OID_SQL, tv("tid", tid, "name", data["name"], "conn", conn)));
            if (!o.ok)
                return internalServerError(o.error);
            string icon;
            bool valid;
            iconAndValid(o.value["rows"][0], icon, valid);
            auto extra = kwDict("valid", valid);
            if (data.contains("comment"))
                extra["description"] = data["comment"];
            return jsonify(Value.dictOf("node", gbn(fkid, tid, name.toString, icon, extra)));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response delete_(Value tid, Value fkidArg)
    {
        Value data = fkidArg.isNone ? formOrJson(request()) : Value.dictOf("ids", Value([fkidArg]));
        bool cascade = checkCascadeOperation();
        try
        {
            foreach (fkid; data["ids"].iterItems())
            {
                auto r = conn.executeDict(rt("get_name.sql", tv("fkid", fkid)));
                if (!r.ok)
                    return internalServerError(r.error);
                if (r.value["rows"].length == 0)
                    return makeJsonResponse(0, Value(gettext("Error: Object not found.")),
                            Value(gettext("The specified foreign key could not be found.\n")));
                auto row = r.value["rows"][0];
                row["schema"] = Value(schema);
                row["table"] = Value(table);
                auto x = conn.executeScalar(rt(DELETE_SQL, tv("data", row, "cascade", cascade)));
                if (!x.ok)
                    return internalServerError(x.error);
            }
            return makeJsonResponse(1, Value(""), Value(gettext("Foreign key dropped.")));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response msql(Value tid, Value fkid)
    {
        auto data = msqlData("comment");
        data["schema"] = Value(schema);
        data["table"] = Value(table);
        try
        {
            Value name;
            auto sql = stripEnd(fkeyUtils.getSql(conn, data, tid, fkid, name));
            if (sql == "")
                sql = "--modified SQL";
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(sql), 200);
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response sqlView(Value tid, Value fkid)
    {
        auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("tid", tid, "conn", conn, "cid", fkid)));
        if (!r.ok)
            return internalServerError(r.error);
        if (r.value["rows"].length == 0)
            return gone(FOREIGN_KEY_NOT_FOUND());
        auto data = r.value["rows"][0];
        data["schema"] = Value(schema);
        data["table"] = Value(table);
        Value[] keys;
        auto confkey = data["confkey"].list.items;
        auto conkey = data["conkey"].list.items;
        foreach (i; 0 .. (confkey.length < conkey.length ? confkey.length : conkey.length))
            keys ~= Value([confkey[i], conkey[i]]);
        auto c = conn.executeDict(rt("get_constraint_cols.sql", tv("tid", tid, "keys", Value(keys),
                "confrelid", data["confrelid"])));
        if (!c.ok)
            return internalServerError(c.error);
        Value[] columns;
        foreach (row; c.value["rows"].list.items)
            columns ~= Value.dictOf("local_column", row["conattname"], "references", data["confrelid"],
                    "referenced", row["confattname"]);
        data["columns"] = Value(columns);
        string rs, rtab;
        fkeyUtils.getParent(conn, columns[0]["references"], rs, rtab);
        data["remote_schema"] = Value(rs);
        data["remote_table"] = Value(rtab);
        auto sql = rt(CREATE_SQL, tv("data", data, "conn", conn));
        auto header = "-- Constraint: " ~ data["name"].toString ~ "\n\n-- ";
        header ~= rt(DELETE_SQL, tv("data", data));
        header ~= "\n";
        return makeResponse(Value(header ~ sql));
    }

    private Response validate(Value scid, Value did, Value tid, Value fkid)
    {
        auto data = Value.newDict();
        try
        {
            data["schema"] = Value(schema);
            data["table"] = Value(table);
            auto n = conn.executeScalar(rt("get_name.sql", tv("fkid", fkid)));
            if (!n.ok)
                return internalServerError(n.error);
            data["name"] = n.value;
            auto v = conn.executeDict(rt("validate.sql", tv("data", data)));
            if (!v.ok)
                return internalServerError(v.error);
            return makeJsonResponse(1, Value(""), Value(gettext("Foreign key updated.")), Value(null),
                    Value.dictOf("id", fkid, "tid", tid, "scid", scid, "did", did), 200);
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response coveringIndex(Value tid)
    {
        auto args = request().args;
        Value index = Value(null);
        try
        {
            if (!args.empty && args.has("cols"))
            {
                string[] cols;
                foreach (c; parseJson(args.get("cols")).iterItems())
                    cols ~= c.toString;
                index = fkeyUtils.searchCoveringindex(conn, tid, cols);
            }
            return makeJsonResponse(1, Value(""), Value(""), Value(null), index, 200);
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }
}

// ---------------------------------------------------------------- primary key and unique constraints

abstract class IndexConstraintView : ConstraintViewBase
{
    enum INDEX_CONSTRAINT_PATH = "index_constraint/sql/#{0}#";

    abstract string constraintName();
    abstract string constraintType();
    abstract string nodeIconName();
    abstract string nodeLabelText();

    override string pathBase() => INDEX_CONSTRAINT_PATH;

    override void parentOf(Value tid, out string schema, out string table)
    {
        idxconsUtils.getParent(conn, tid, schema, table);
    }

    this()
    {
        super();
        parentIds = [IdSpec("int", "gid"), IdSpec("int", "sid"), IdSpec("int", "did"), IdSpec("int", "scid"),
            IdSpec("int", "tid")];
        ids = [IdSpec("int", "cid")];
        setAllOps([
            makeOp("obj", ["get": "properties", "delete": "delete", "put": "update"],
                    ["get": "list", "post": "create", "delete": "delete"]),
            makeOp("delete", ["delete": "delete"], ["delete": "delete"]),
            makeOp("children", ["get": "children"]),
            makeOp("nodes", ["get": "node"], ["get": "nodes"]),
            makeOp("sql", ["get": "sql"]),
            makeOp("msql", ["get": "msql"], ["get": "msql"]),
            makeOp("stats", ["get": "statistics"]),
            makeOp("dependency", ["get": "dependencies"]),
            makeOp("dependent", ["get": "dependents"]),
        ]);
    }

    string keyNotFoundErrorMsg()
        => gettext("Could not find the {} in the table.").replace("{}", constraintType == "p" ? gettext("primary key")
                : gettext("unique key"));

    override Value getNodeListRows(Dict k)
    {
        manualPrecondition(k["sid"], k["did"], k["tid"]);
        auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("did", k["did"], "tid", k["tid"], "constraint_type", constraintType)));
        foreach (row; r.value["rows"].list.items)
            row["_type"] = Value(nodeType);
        return r.value["rows"];
    }

    override Value[] getNodesList(Dict k)
    {
        manualPrecondition(k["sid"], k["did"], k["tid"]);
        auto r = conn.execute2darray(rt(NODES_SQL, tv("tid", k["tid"], "constraint_type", constraintType)));
        Value[] res;
        foreach (row; r.value["rows"].list.items)
            res ~= gbn(row["oid"], k["tid"], row["name"].toString, nodeIconName, kwDict("description", row["comment"]));
        return res;
    }

    override Response callMethod(string name, Dict k)
    {
        if (!isAuthenticated())
            return unauthorisedResponse();
        if (name == "children")
            return children(k);
        auto err = constraintPrecondition(k, name);
        if (err !is null)
            return err;
        auto gid = k.has("gid") ? k["gid"] : Value(null);
        auto sid = k["sid"];
        auto did = k["did"];
        auto tid = k["tid"];
        auto cid = k.has("cid") ? k["cid"] : Value(null);
        switch (name)
        {
        case "properties":
        {
            auto r = idxconsUtils.getIndexConstraints(conn, did, tid, constraintType, cid);
            if (!r.ok)
                return internalServerError(r.error);
            if (r.value.length == 0)
                return gone(keyNotFoundErrorMsg());
            auto result = cid.truthy ? r.value[0] : r.value;
            result["is_sys_obj"] = Value(result["oid"].integer <= DATABASE_LAST_SYSTEM_OID_ || datistemplate);
            return makeResponse(result, 200);
        }
        case "list":
        {
            try
                return makeResponse(getNodeListRows(k), 200);
            catch (HTTPException e)
                throw e;
            catch (Exception e)
                return internalServerError(e.msg);
        }
        case "node":
        {
            auto r = conn.execute2darray(rt(NODES_SQL, tv("cid", cid, "tid", tid, "constraint_type", constraintType)));
            if (!r.ok)
                return internalServerError(r.error);
            if (r.value["rows"].length == 0)
                return gone(keyNotFoundErrorMsg());
            auto row = r.value["rows"][0];
            return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    gbn(row["oid"], tid, row["name"].toString, nodeIconName), 200);
        }
        case "nodes":
        {
            auto r = conn.execute2darray(rt(NODES_SQL, tv("tid", tid, "constraint_type", constraintType)));
            if (!r.ok)
                return internalServerError(r.error);
            Value[] res;
            foreach (row; r.value["rows"].list.items)
                res ~= gbn(row["oid"], tid, row["name"].toString, nodeIconName, kwDict("description", row["comment"]));
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        case "create": return create(tid);
        case "update": return update(did, tid, cid);
        case "delete": return delete_(gid, sid, did, tid, cid);
        case "msql": return msql(did, tid, cid);
        case "sql": return sqlView(did, tid, cid);
        case "statistics": return statistics(did, tid, cid);
        case "dependents": return makeResponse(getDependents(conn, cid), 200);
        case "dependencies": return makeResponse(getDependencies(conn, cid), 200);
        default: return super.callMethod(name, k);
        }
    }

    private Response checkRequiredArgs(Value data)
    {
        // either `columns` (a non-empty list) or `index`
        foreach (param; ["columns", "index"])
            if (data.contains(param) && (param != "columns" || (data[param].isList && data[param].length > 0)))
                return null;
        return makeJsonResponse(0, Value("Could not find at least one required parameter (index)."), Value(""), Value(null),
                Value(null), 400);
    }

    private Response create(Value tid)
    {
        auto data = loadJsonValues(formOrJson(request()), "comment");
        auto bad = checkRequiredArgs(data);
        if (bad !is null)
            return bad;
        data["schema"] = Value(schema);
        data["table"] = Value(table);
        try
        {
            bool noName = !data.contains("name") || data["name"] == Value("");
            if (noName)
            {
                auto b = conn.executeScalar(rt("begin.sql"));
                if (!b.ok)
                {
                    endTransaction();
                    return internalServerError(b.error);
                }
            }
            auto c = conn.executeScalar(rt(CREATE_SQL, tv("data", data, "conn", conn, "constraint_name", constraintName)));
            if (!c.ok)
            {
                endTransaction();
                return internalServerError(c.error);
            }
            Value res;
            if (noName)
            {
                auto o = conn.executeDict(rt("get_oid_with_transaction.sql", tv("constraint_type", constraintType, "tid", tid)));
                if (!o.ok)
                {
                    endTransaction();
                    return internalServerError(o.error);
                }
                endTransaction();
                res = o.value;
                data["name"] = res["rows"][0]["name"];
            }
            else
            {
                auto o = conn.executeDict(rt(OID_SQL, tv("tid", tid, "constraint_type", constraintType, "name", data["name"],
                        "conn", conn)));
                if (!o.ok)
                {
                    endTransaction();
                    return internalServerError(o.error);
                }
                res = o.value;
            }
            Dict extra;
            if (data.contains("comment"))
                extra = kwDict("description", data["comment"]);
            return jsonify(Value.dictOf("node", gbn(res["rows"][0]["oid"], tid, data["name"].toString, nodeIconName, extra)));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
        {
            endTransaction();
            return makeJsonResponse(0, Value(e.msg), Value(""), Value(null), Value(null), 400);
        }
    }

    private Response update(Value did, Value tid, Value cid)
    {
        auto data = formOrJson(request());
        try
        {
            data["schema"] = Value(schema);
            data["table"] = Value(table);
            Value name;
            auto sql = stripEnd(idxconsUtils.getSql(conn, data, did, tid, constraintType, cid, name));
            auto x = conn.executeScalar(sql);
            if (!x.ok)
                return internalServerError(x.error);
            auto o = conn.executeDict(rt(OID_SQL, tv("tid", tid, "constraint_type", constraintType, "name", data["name"],
                    "conn", conn)));
            if (!o.ok)
                return internalServerError(o.error);
            Dict extra;
            if (data.contains("comment"))
                extra = kwDict("description", data["comment"]);
            return jsonify(Value.dictOf("node", gbn(cid, tid, name.toString, nodeIconName, extra)));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response delete_(Value gid, Value sid, Value did, Value tid, Value cidArg)
    {
        Value data = cidArg.isNone ? formOrJson(request()) : Value.dictOf("ids", Value([cidArg]));
        bool cascade = checkCascadeOperation();
        try
        {
            Value cid;
            foreach (id; data["ids"].iterItems())
            {
                cid = id;
                auto r = conn.executeDict(rt("get_name.sql", tv("tid", tid, "constraint_type", constraintType, "cid", cid)));
                if (!r.ok)
                    return internalServerError(r.error);
                if (r.value["rows"].length == 0)
                    return makeJsonResponse(0, Value(gettext("Error: Object not found.")),
                            Value(gettext("The specified constraint could not be found.\n")));
                auto row = r.value["rows"][0];
                row["schema"] = Value(schema);
                row["table"] = Value(table);
                auto x = conn.executeScalar(rt(DELETE_SQL, tv("data", row, "cascade", cascade)));
                if (!x.ok)
                    return internalServerError(x.error);
            }
            return makeJsonResponse(1, Value(""), Value(gettext("{0} dropped.").replace("{0}", nodeLabelText)), Value(null),
                    Value.dictOf("id", cid, "sid", sid, "gid", gid, "did", did), 200);
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response msql(Value did, Value tid, Value cid)
    {
        auto data = msqlData("comment");
        data["schema"] = Value(schema);
        data["table"] = Value(table);
        try
        {
            Value name;
            auto sql = stripEnd(idxconsUtils.getSql(conn, data, did, tid, constraintType, cid, name));
            if (sql == "")
                sql = "--modified SQL";
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(sql), 200);
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response sqlView(Value did, Value tid, Value cid)
    {
        auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("did", did, "tid", tid, "conn", conn, "cid", cid,
                "constraint_type", constraintType)));
        if (!r.ok)
            return internalServerError(r.error);
        if (r.value["rows"].length == 0)
            return gone(keyNotFoundErrorMsg());
        auto data = r.value["rows"][0];
        data["schema"] = Value(schema);
        data["table"] = Value(table);
        auto c = conn.executeDict(rt("get_constraint_cols.sql", tv("cid", cid, "colcnt", data["col_count"])));
        if (!c.ok)
            return internalServerError(c.error);
        import pgadmin.core.strutil : pyStrip;
        Value[] columns;
        foreach (row; c.value["rows"].list.items)
            columns ~= Value.dictOf("column", pyStrip(row["column"].toString, "\""));
        data["columns"] = Value(columns);
        if (manager.version_ >= 110000)
        {
            auto inc = conn.executeDict(rt("get_constraint_include.sql", tv("cid", cid)));
            if (!inc.ok)
                return internalServerError(inc.error);
            Value[] include;
            foreach (col; inc.value["rows"].list.items)
                include ~= col["colname"];
            data["include"] = Value(include);
        }
        auto sql = rt(CREATE_SQL, tv("data", data, "constraint_name", constraintName, "conn", conn));
        auto header = "-- Constraint: " ~ data["name"].toString ~ "\n\n-- ";
        header ~= rt(DELETE_SQL, tv("data", data));
        header ~= "\n";
        return makeResponse(Value(header ~ sql));
    }

    private Response statistics(Value did, Value tid, Value cid)
    {
        auto p = checkPgstattuple(conn, tid);
        if (!p.ok)
            return internalServerError(p.error);
        Value name = Value(null);
        if (p.value.truthy)
        {
            auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("did", did, "tid", tid, "cid", cid,
                    "constraint_type", constraintType)));
            if (!r.ok)
                return internalServerError(r.error);
            if (r.value["rows"].length == 0)
                return gone(keyNotFoundErrorMsg());
            name = r.value["rows"][0]["name"];
        }
        auto s = conn.executeDict(rt("stats.sql", tv("conn", conn, "schema", schema, "name", name, "cid", cid,
                "is_pgstattuple", p.value)));
        if (!s.ok)
            return internalServerError(s.error);
        return makeJsonResponse(1, Value(""), Value(""), Value(null), s.value, 200);
    }
}

final class PrimaryKeyConstraintView : IndexConstraintView
{
    override string constraintName() => "PRIMARY KEY";
    override string constraintType() => "p";
    override string nodeIconName() => "icon-primary_key";
    override string nodeLabelText() => gettext("Primary key");

    this()
    {
        super();
        nodeType = PrimaryKeyConstraintModule.NODE_TYPE;
        nodeLabel = gettext("Primary key");
    }
}

final class UniqueConstraintView : IndexConstraintView
{
    override string constraintName() => "UNIQUE";
    override string constraintType() => "u";
    override string nodeIconName() => "icon-unique_constraint";
    override string nodeLabelText() => gettext("Unique constraint");

    this()
    {
        super();
        nodeType = UniqueConstraintModule.NODE_TYPE;
        nodeLabel = gettext("Unique constraint");
    }
}
