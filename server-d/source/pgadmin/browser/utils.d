/// Base classes of the object browser (`pgadmin/browser/utils.py` and `collection.py`).
///
/// A node module (`CollectionNodeModule`) describes one object type: its URL prefix, the tree nodes it contributes and
/// its version range. A node view (`NodeView`/`PGChildNodeView`) implements the REST commands of that type
/// (properties, create, update, delete, sql, msql, nodes, statistics, dependencies...). The URL structure and the
/// command-to-method table are exactly the Python ones, so the JavaScript client works unchanged.
module pgadmin.browser.utils;

import std.algorithm : canFind, sort, startsWith;
import std.array : array, join, replace;
import std.conv : to;
import std.string : format, toLower;
import pgadmin.core.config;
import pgadmin.core.i18n;
import pgadmin.core.log;
import pgadmin.core.templates;
import pgadmin.core.value;
import pgadmin.db.driver;
import pgadmin.utils.constants;
import pgadmin.utils.exception;
import pgadmin.utils.preferences;
import pgadmin.web.auth;
import pgadmin.web.context;
import pgadmin.web.flask;
import pgadmin.web.http;
import pgadmin.web.routing : Rule;

// ------------------------------------------------------------ helpers

/// `underscore_escape`: HTML escaping compatible with underscore.js.
string underscoreEscape(string text)
{
    if (text.length == 0)
        return text;
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;").replace("'", "&#39;");
}

string underscoreUnescape(string text)
{
    if (text.length == 0)
        return text;
    return text.replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&#39;", "'");
}

bool isVersionInRange(long sversion, Value minVer, Value maxVer)
{
    if (minVer.isNone && maxVer.isNone)
        return true;
    return (minVer.isNone || minVer.integer <= sversion) && (maxVer.isNone || maxVer.integer >= sversion);
}

// ------------------------------------------------------------ PGChildModule

/// Version/server-type gate shared by the nodes below a server (`PGChildModule`).
mixin template PGChildModuleFields()
{
    Value minVer = Value(0);
    Value maxVer = Value(1_100_000_000);
    Value minPpasVer = Value(0);
    Value maxPpasVer = Value(1_100_000_000);
    string[] serverTypes; /// empty = any

    bool backendSupportedBase(ServerManager manager, Dict kwargs)
    {
        if (!showNode)
            return false;
        if (manager is null || manager.sversion == 0)
            return false;
        if (serverTypes.length == 0 || serverTypes.canFind(manager.serverType))
        {
            auto mn = minVer, mx = maxVer;
            if (manager.serverType == "ppas")
            {
                mn = minPpasVer;
                mx = maxPpasVer;
            }
            return isVersionInRange(manager.sversion, mn, mx);
        }
        return false;
    }
}

// ------------------------------------------------------------ browser modules

/// `BrowserPluginModule`: a module below the browser tree (server groups, servers...).
abstract class BrowserPluginModule : Blueprint
{
    enum browserUrlPrefix = "/browser/";
    bool showOnBrowser = true;
    Preference prefShowNode;
    Preference prefShowSystemObjects;

    this(string nodeTypeName, string urlPrefix = null)
    {
        super("NODE-" ~ nodeTypeName, urlPrefix is null ? browserUrlPrefix ~ nodeTypeName : urlPrefix);
        staticUrlPath = "/static";
    }

    abstract string nodeType();
    string nodeIcon() => "icon-" ~ nodeType;
    /// When to load the node's script (the parent node type), or null.
    string scriptLoad() => null;
    bool moduleUseTemplateJavascript() => false;
    bool nodeInode() => true;
    string nodePath() => browserUrlPrefix ~ nodeType;

    /// The tree nodes this module contributes (a generator in Python); `kwargs` carries the path ids.
    abstract Value[] getNodes(Dict kwargs);

    string[] csssnippets()
    {
        string[] snippets;
        snippets ~= renderTemplate("browser/css/node.css", ["node_type": Value(nodeType)]);
        foreach (m; submodules)
            if (auto b = cast(BrowserPluginModule) m)
                snippets ~= b.csssnippets;
        return snippets;
    }

    string[] jssnippets() => null;

    bool showNode()
    {
        auto p = prefShowNode !is null ? prefShowNode : lookupShowNode();
        if (p !is null)
            return p.get().truthy;
        return showOnBrowser;
    }

    private Preference lookupShowNode()
    {
        auto b = Preferences.module_("browser", false);
        return b is null ? null : b.preference("show_node_" ~ nodeType);
    }

    bool showSystemObjectsFlag() => showSystemObjects();

    bool showSystemObjects()
    {
        auto b = Preferences.module_("browser", false);
        if (b is null)
            return false;
        auto p = b.preference("show_system_objects");
        return p !is null && p.get().truthy;
    }

    /// `generate_browser_node(node_id, parent_id, label, icon, inode, node_type, **kwargs)`
    Value generateBrowserNode(Value nodeId, Value parentId, string label, string icon, bool inode, string nodeTypeName,
            Dict kwargs = null)
    {
        auto obj = new Dict;
        obj["id"] = nodeTypeName ~ "_" ~ nodeId.toString;
        obj["label"] = label;
        obj["icon"] = icon;
        obj["inode"] = Value(inode);
        obj["_type"] = nodeTypeName;
        obj["_id"] = nodeId;
        obj["_pid"] = parentId;
        obj["module"] = PGADMIN_NODE.replace("%s", nodeTypeName);
        if (kwargs !is null)
            foreach (k, v; kwargs)
                if (!obj.has(k))
                    obj[k] = v;
        return Value(obj);
    }
}

/// `CollectionNodeModule`: the module of an object type listed under a parent (tables, views, roles...).
abstract class CollectionNodeModule : BrowserPluginModule
{
    mixin PGChildModuleFields;

    string collectionLabelText;

    this(string nodeTypeName)
    {
        super(nodeTypeName);
    }

    override bool nodeInode() => true;

    string collectionLabel() => gettext(collectionLabelText);
    string collectionIcon() => "icon-coll-" ~ nodeType;

    /// Show/hide the user-defined template databases.
    bool showDatabaseTemplate()
    {
        auto b = Preferences.module_("browser", false);
        if (b is null)
            return false;
        auto p = b.preference("show_user_defined_templates");
        return p !is null && p.get().truthy;
    }

    /// `backend_supported(manager, **kwargs)`
    bool backendSupported(ServerManager manager, Dict kwargs) => backendSupportedBase(manager, kwargs);

    Value generateBrowserNode(Value nodeId, Value parentId, string label, string icon = null, Dict kwargs = null)
    {
        auto obj = new Dict;
        obj["id"] = nodeType ~ "_" ~ nodeId.toString;
        obj["label"] = label;
        obj["icon"] = icon is null ? nodeIcon : icon;
        obj["inode"] = kwargs !is null && kwargs.has("inode") ? kwargs["inode"] : Value(nodeInode);
        obj["_type"] = nodeType;
        obj["_id"] = nodeId;
        obj["_pid"] = parentId;
        obj["module"] = PGADMIN_NODE.replace("%s", nodeType);
        if (kwargs !is null)
            foreach (k, v; kwargs)
                if (!obj.has(k))
                    obj[k] = v;
        return Value(obj);
    }

    Value generateBrowserCollectionNode(Value parentId, Dict kwargs = null)
    {
        auto obj = new Dict;
        obj["id"] = "coll-" ~ nodeType ~ "_" ~ parentId.toString;
        obj["label"] = collectionLabel;
        obj["icon"] = collectionIcon;
        obj["inode"] = Value(true);
        obj["_type"] = "coll-" ~ nodeType;
        obj["_id"] = parentId;
        obj["_pid"] = parentId;
        obj["module"] = PGADMIN_NODE.replace("%s", nodeType);
        obj["nodes"] = Value([Value(nodeType)]);
        if (kwargs !is null)
            foreach (k, v; kwargs)
                if (!obj.has(k))
                    obj[k] = v;
        return Value(obj);
    }

    /// Whether the collection has children, or empty collections are shown (`has_nodes`).
    bool hasNodes(Value sid, Value did, Value scid = Value(null), Value tid = Value(null), Value vid = Value(null),
            string baseTemplatePath = "")
    {
        auto showEmpty = Preferences.module_("browser").preference("show_empty_coll_nodes");
        if (showEmpty !is null && showEmpty.get().truthy)
            return true;
        try
        {
            auto manager = getDriver().connectionManager(sid.integer);
            auto conn = manager.connection(null, null, true, did);
            string templateBase = baseTemplatePath.canFind("{1}")
                ? baseTemplatePath.replace("{0}", manager.serverType).replace("{1}", to!string(manager.version_))
                : baseTemplatePath.replace("{0}", to!string(manager.version_));
            auto lastSystemOid = showSystemObjects ? 0 : DATABASE_LAST_SYSTEM_OID;
            auto sql = renderTemplate(templateBase ~ "/count.sql", [
                "did": did, "scid": scid, "tid": tid, "vid": vid, "datlastsysoid": Value(lastSystemOid),
                "showsysobj": Value(showSystemObjects), "conn": Value(conn)
            ]);
            auto r = conn.executeDict(sql);
            return r.ok ? r.value["rows"][0]["count"].integer > 0 : true;
        }
        catch (Exception)
            return true;
    }

    override string[] csssnippets()
    {
        string[] snippets;
        snippets ~= renderTemplate("browser/css/collection.css", ["node_type": Value(nodeType)]);
        snippets ~= renderTemplate("browser/css/node.css", ["node_type": Value(nodeType)]);
        foreach (m; submodules)
            if (auto b = cast(BrowserPluginModule) m)
                snippets ~= b.csssnippets;
        return snippets;
    }

    override Value[] getNodes(Dict kwargs) => null;
}

// ------------------------------------------------------------ NodeView

/// One entry of a view's command table: `'obj': [{'get': 'properties', ...}, {'get': 'list', ...}]`.
struct OpSet
{
    string[string] methods; /// http method (lower case) -> method name
}

/// A command: the URL part (`obj`, `sql`, `nodes`...) and the method tables for "with id" (0), "collection" (1) and an
/// optional third table (2) used by a few views.
struct Operation
{
    string cmd;
    OpSet[] sets;
}

private Operation op(string cmd, string[string][] sets...)
{
    Operation o;
    o.cmd = cmd;
    foreach (s; sets)
        o.sets ~= OpSet(s);
    return o;
}

/// One `{'type': 'int', 'id': 'gid'}` entry.
struct IdSpec
{
    string type;
    string id;
}

/// `NodeView`
abstract class NodeView
{
    string cmd;
    string nodeType;
    string nodeLabel;
    string nodeIcon_;
    IdSpec[] parentIds;
    IdSpec[] ids;
    Operation[] operations;
    CollectionNodeModule collection;   /// the module that owns the view (null for non-collection nodes)
    BrowserPluginModule bpModule;      /// idem, for any browser plugin module

    this()
    {
        operations = defaultOperations();
    }

    static Operation[] defaultOperations()
    {
        return [
            op("obj", ["get": "properties", "delete": "delete", "put": "update"], ["get": "list", "post": "create"]),
            op("nodes", ["get": "node"], ["get": "nodes"]),
            op("sql", ["get": "sql"]),
            op("msql", ["get": "modified_sql"]),
            op("stats", ["get": "statistics"]),
            op("dependency", ["get": "dependencies"]),
            op("dependent", ["get": "dependents"]),
            op("children", ["get": "children"]),
        ];
    }

    /// Replaces or adds a command (the `operations = dict({...})` override of a subclass).
    protected void setOps(string cmdName, string[string][] sets...)
    {
        foreach (ref o; operations)
            if (o.cmd == cmdName)
            {
                o = op(cmdName, sets);
                return;
            }
        operations ~= op(cmdName, sets);
    }

    /// Replaces the whole table.
    protected void setAllOps(Operation[] ops)
    {
        operations = ops;
    }

    static Operation makeOp(string cmdName, string[string][] sets...) => op(cmdName, sets);

    /// The module of the node (for `generate_browser_node`).
    BrowserPluginModule blueprint() => bpModule;

    /// `get_node_urls()`: `(id_url, common_url)`.
    void nodeUrls(out string idUrl, out string commonUrl)
    {
        assert(nodeType.length, "Please set the node_type for this class");
        string common = "/";
        foreach (p; parentIds)
            common ~= "<" ~ p.type ~ ":" ~ p.id ~ ">/";
        string id;
        foreach (p; ids)
            id = (id.length ? id : common) ~ "<" ~ p.type ~ ":" ~ p.id ~ ">";
        idUrl = id;
        commonUrl = common;
    }

    protected bool nodeCsrfExempt(string cmdName) => false;

    private static View makeDispatcher(T : NodeView)(string cmdName)
    {
        // a fresh view per request: views keep per-request state (manager, connection, template path) in fields
        return (Dict args) {
            auto v = new T;
            v.bpModule = ModuleOf!T.module_;
            v.collection = cast(CollectionNodeModule) v.bpModule;
            return v.dispatchRequest(cmdName, args);
        };
    }

    /// `check_args`: `(has_args, has_id)`
    void checkArgs(Dict kwargs, out bool hasArgs, out bool hasId)
    {
        hasId = hasArgs = true;
        foreach (p; parentIds)
            if (!kwargs.has(p.id))
            {
                hasArgs = false;
                break;
            }
        foreach (p; ids)
            if (!kwargs.has(p.id))
            {
                hasId = false;
                break;
            }
        hasId = hasId && hasArgs;
    }

    /// `dispatch_request`: picks the method name of the command for the HTTP method and calls it.
    Response dispatchRequest(string cmdName, Dict kwargs)
    {
        cmd = cmdName;
        auto httpMethod = request().method.toLower;
        if (httpMethod == "head")
            httpMethod = "get";
        bool hasArgs, hasId;
        checkArgs(kwargs, hasArgs, hasId);
        Operation* o;
        foreach (ref x; operations)
            if (x.cmd == cmdName)
                o = &x;
        assert(o !is null, "Unimplemented command (" ~ cmdName ~ ") for " ~ typeid(this).name);
        string meth;
        if (hasId && o.sets.length > 0 && httpMethod in o.sets[0].methods)
            meth = o.sets[0].methods[httpMethod];
        else if (hasArgs && o.sets.length > 1 && httpMethod in o.sets[1].methods)
            meth = o.sets[1].methods[httpMethod];
        else if (o.sets.length > 2 && httpMethod in o.sets[2].methods)
            meth = o.sets[2].methods[httpMethod];
        else
            throw new Exception("Unimplemented method (" ~ httpMethod ~ ") for command (" ~ cmdName ~ "), which "
                    ~ (hasId ? "requires" : "does not require") ~ " an id");
        return callMethod(meth, kwargs);
    }

    /// Calls the view method called `name`. Subclasses `switch` over their methods and fall back to the base.
    Response callMethod(string name, Dict kwargs)
    {
        switch (name)
        {
        case "children": return children(kwargs);
        default:
            return makeJsonResponse(0, Value(gettext("Unimplemented method ({0}) for this url ({1})")
                    .replace("{0}", name).replace("{1}", request().path)), Value(""), Value(null), Value(null), 406);
        }
    }

    /// `children`: the tree nodes below this node.
    Response children(Dict kwargs)
    {
        auto ch = getChildrenNodes(kwargs);
        sortByLabel(ch);
        return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(ch));
    }

    Value[] getChildrenNodes(Dict kwargs)
    {
        Value[] nodes;
        foreach (m; bpModule.submodules)
            if (auto b = cast(BrowserPluginModule) m)
                nodes ~= b.getNodes(kwargs);
        return nodes;
    }

    static void sortByLabel(ref Value[] nodes)
    {
        import std.algorithm : SwapStrategy;
        sort!((a, b) => a["label"].str < b["label"].str, SwapStrategy.stable)(nodes);
    }

    string notFoundErrorMsg(string customLabel = null)
    {
        return gettext(("Could not find the specified " ~ (customLabel.length ? customLabel : nodeLabel) ~ ".").toLower);
    }
}

private string toUpper_(string s)
{
    import std.uni : toUpper;
    return s.toUpper;
}


private template ModuleOf(T)
{
    __gshared BrowserPluginModule module_;
}

/// One shared instance of a module type (a Python blueprint object imported by several parents).
T sharedModule(T : BrowserPluginModule)()
{
    __gshared T inst;
    if (inst is null)
        inst = new T;
    return inst;
}

/// A view of type `T` set up as the dispatcher does (module registered by `registerNodeView!T`).
T makeView(T : NodeView)()
{
    auto v = new T;
    v.bpModule = ModuleOf!T.module_;
    v.collection = cast(CollectionNodeModule) v.bpModule;
    return v;
}

/// `NodeView.register_node_view(blueprint)`: registers one URL rule per command of `T`; `T` is instantiated per request.
void registerNodeView(T : NodeView)(BrowserPluginModule bp)
{
    ModuleOf!T.module_ = bp;
    auto proto = new T;
    proto.bpModule = bp;
    string idUrl, url;
    proto.nodeUrls(idUrl, url);
    foreach (o; proto.operations)
    {
        auto c = o.cmd;
        auto ep = c.replace(".", "-");
        foreach (idx, set; o.sets)
        {
            if (set.methods.length == 0)
                continue;
            string[] ms;
            foreach (k, v; set.methods)
                ms ~= k.toUpper_;
            bool withId = idx != 2;
            bool req = idx == 0;
            string rule = withId ? "/" ~ c ~ (req ? idUrl : url) : "/" ~ c;
            string endpoint = withId ? ep ~ (req ? "_id" : "") : ep;
            bp.route(rule, endpoint, ms, NodeView.makeDispatcher!T(c), proto.nodeCsrfExempt(c));
        }
    }
}

// ------------------------------------------------------------ PGChildNodeView

/// `PGChildNodeView`: the base of every node below a server; adds the dependency queries and the connection-aware
/// `children`.
abstract class PGChildNodeView : NodeView
{
    enum NODE_SQL = "node.sql";
    enum NODES_SQL = "nodes.sql";
    enum COUNT_SQL = "count.sql";
    enum CREATE_SQL = "create.sql";
    enum UPDATE_SQL = "update.sql";
    enum ALTER_SQL = "alter.sql";
    enum PROPERTIES_SQL = "properties.sql";
    enum DELETE_SQL = "delete.sql";
    enum GRANT_SQL = "grant.sql";
    enum SCHEMA_SQL = "schema.sql";
    enum ACL_SQL = "acl.sql";
    enum OID_SQL = "get_oid.sql";
    enum FUNCTIONS_SQL = "functions.sql";
    enum GET_CONSTRAINTS_SQL = "get_constraints.sql";
    enum GET_TABLES_SQL = "get_tables.sql";
    enum GET_DEFINITION_SQL = "get_definition.sql";
    enum GET_SCHEMA_OID_SQL = "get_schema_oid.sql";
    enum GET_COLUMNS_SQL = "get_columns.sql";
    enum GET_COLUMNS_FOR_TABLE_SQL = "get_columns_for_table.sql";
    enum GET_SUBTYPES_SQL = "get_subtypes.sql";
    enum GET_EXTERNAL_FUNCTIONS_SQL = "get_external_functions.sql";
    enum GET_TABLE_FOR_PUBLICATION = "get_tables.sql";
    enum DATABASE_LAST_SYSTEM_OID_ = DATABASE_LAST_SYSTEM_OID;

    /// Set by `checkPrecondition` of the concrete view.
    ServerManager manager;
    Connection conn;
    string templatePath;

    /// Children nodes whose module supports the server version (`get_children_nodes(manager, **kwargs)`).
    Value[] getChildrenNodesFor(ServerManager mgr, Dict kwargs)
    {
        Value[] nodes;
        foreach (m; bpModule.submodules)
        {
            auto cm = cast(CollectionNodeModule) m;
            if (cm !is null)
            {
                if (mgr !is null && cm.backendSupported(mgr, kwargs))
                    nodes ~= cm.getNodes(kwargs);
            }
            else if (auto b = cast(BrowserPluginModule) m)
                nodes ~= b.getNodes(kwargs);
        }
        return nodes;
    }

    override Response children(Dict kwargs)
    {
        if (!kwargs.has("sid"))
            return preconditionRequired(gettext("Required properties are missing."));
        auto mgr = getDriver().connectionManager(kwargs["sid"].integer);
        Value did = kwargs.has("did") ? kwargs["did"] : Value(null);
        try
        {
            auto c = mgr.connection(null, null, true, did);
            if (!c.ping())
            {
                auto r = c.connect();
                if (!r.ok)
                    return serviceUnavailable(r.error, "CONNECTION_LOST");
            }
        }
        catch (ConnectionLost e)
            throw e;
        catch (SSHTunnelConnectionLost e)
            throw e;
        catch (CryptKeyMissing e)
            throw e;
        catch (HTTPException e)
            throw e;
        catch (Exception)
            return preconditionRequired(gettext("Connection to the server has been lost."));
        auto ch = getChildrenNodesFor(mgr, kwargs);
        sortByLabel(ch);
        return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(ch));
    }

    /// `get_dependencies(conn, object_id, where, show_system_objects, is_schema_diff)`
    Value getDependencies(Connection c, Value objectId, string where = null, Value showSystemObjects = Value(null),
            bool isSchemaDiff = false)
    {
        auto sqlPath = "depends/" ~ c.manager.serverType ~ "/#" ~ to!string(c.manager.version_) ~ "#";
        auto whereClause = where is null ? "WHERE dep.objid=" ~ objectId.toString ~ "::oid" : where;
        auto query = renderTemplate(sqlPath ~ "/dependencies.sql", [
            "where_clause": Value(whereClause), "object_id": objectId
        ]);
        auto dependencies = fetchDependency(c, query, showSystemObjects, isSchemaDiff);
        if (whereClause.canFind("subid") == false)
        {
            auto sql = renderTemplate(sqlPath ~ "/role_dependencies.sql", [
                "where_clause": Value(whereClause), "conn": Value(c)
            ]);
            auto r = c.executeDict(sql);
            if (!r.ok)
                logError(r.error);
            else
                foreach (row; r.value["rows"].list.items)
                {
                    if (row["refclassid"].integer == 1260)
                    {
                        string depType;
                        auto ds = row["deptype"].toString;
                        if (ds == "a")
                            depType = "ACL";
                        else if (ds == "o")
                            depType = "Owner";
                        dependencies.append(Value.dictOf("type", "role", "name", row["refname"], "field", depType));
                    }
                }
        }
        return dependencies;
    }

    /// `get_dependents(conn, object_id, where)`
    Value getDependents(Connection c, Value objectId, string where = null)
    {
        auto sqlPath = "depends/" ~ c.manager.serverType ~ "/#" ~ to!string(c.manager.version_) ~ "#";
        auto whereClause = where is null ? "WHERE dep.refobjid=" ~ objectId.toString ~ "::oid" : where;
        auto query = renderTemplate(sqlPath ~ "/dependents.sql", ["where_clause": Value(whereClause)]);
        return fetchDependency(c, query);
    }

    private Value fetchDependency(Connection c, string query, Value showSystemObjects = Value(null),
            bool isSchemaDiff = false)
    {
        // type letter -> name; null entries are resolved from the following letters (see below)
        static immutable string[string] standardTypes = [
            "r": null, "i": "index", "S": "sequence", "v": "view", "p": "partition_table", "f": "foreign_table",
            "m": "materialized_view", "t": "toast_table", "I": "partition_index",
        ];
        static immutable string[string] customTypes = [
            "x": "external_table", "n": "schema", "d": "domain", "l": "language", "Cc": "check",
            "Cd": "domain_constraints", "Cf": "foreign_key", "Cp": "primary_key", "Co": "collation",
            "Cu": "unique_constraint", "Cx": "exclusion_constraint", "Fw": "foreign_data_wrapper",
            "Fs": "foreign_server", "Fc": "fts_configuration", "Fp": "fts_parser", "Fd": "fts_dictionary",
            "Ft": "fts_template", "Ex": "extension", "Et": "event_trigger", "Pa": "package", "Pf": "function",
            "Pt": "trigger_function", "Pp": "procedure", "Rl": "rule", "Rs": "row_security_policy", "Sy": "synonym",
            "Ty": "type", "Tr": "trigger", "Tc": "compound_trigger", "c": "type", "A": null,
        ];
        string typeFor(string key, out bool known)
        {
            if (auto p = key in standardTypes)
            {
                known = true;
                return *p;
            }
            if (auto p = key in customTypes)
            {
                known = true;
                return *p;
            }
            known = false;
            return null;
        }

        auto dependency = Value.newList();
        auto r = c.executeDict(query);
        if (!r.ok)
        {
            logError(r.error);
            return dependency;
        }
        foreach (row; r.value["rows"].list.items)
        {
            auto refNameV = row["refname"];
            string _refName = refNameV.isNone ? null : refNameV.toString;
            auto typeStr = row["type"].toString;
            auto depStr = row["deptype"].toString;
            auto nspName = row["nspname"];
            Value objectId = row.contains("refobjid") ? row["refobjid"] : Value(null);
            string refName;
            if (!nspName.isNone)
                refName = nspName.toString ~ ".";
            string typeName;
            Value icon = Value(null);

            bool known;
            auto t = typeStr.length ? typeFor(typeStr, known) : null;
            if (typeStr.length && known && t !is null)
            {
                typeName = t;
                if (typeStr == "Rl")
                {
                    refName = _refName ~ " ON " ~ refName ~ row["ownertable"].toString;
                    _refName = null;
                }
                else if (typeStr == "Cf")
                    refName ~= row["ownertable"].toString ~ ".";
                else if (typeStr == "m")
                    icon = Value("icon-mview");
            }
            else if (typeStr.length)
            {
                bool known0;
                auto first = typeStr[0 .. 1];
                auto t0 = typeFor(first, known0);
                if (known0 && t0 is null)
                {
                    if (first == "r")
                    {
                        bool isColumn = (typeStr.length > 1 && typeStr[1] >= '0' && typeStr[1] <= '9' && typeStr[1] != '0')
                            || (typeStr.length > 2 && typeStr[2] >= '0' && typeStr[2] <= '9' && typeStr[2] != '0');
                        if (isColumn)
                            typeName = "column";
                        else
                        {
                            typeName = "table";
                            auto inherits = row.get("is_inherits");
                            auto inherited = row.get("is_inherited");
                            if (row.contains("is_inherits") && inherits.toString == "1")
                            {
                                if (row.contains("is_inherited") && inherited.toString == "1")
                                    icon = Value("icon-table-multi-inherit");
                                else if (row.contains("is_inherited") && inherited.toString == "0" && depStr == "a")
                                    typeName = "partition";
                                else
                                    icon = Value("icon-table-inherits");
                            }
                            else if (row.contains("is_inherited") && inherited.toString == "1")
                                icon = Value("icon-table-inherited");
                        }
                    }
                    else if (first == "A")
                    {
                        if (row["adbin"].toString.startsWith("{FUNCEXPR"))
                        {
                            typeName = "function";
                            refName = row["adsrc"].toString;
                        }
                        else
                            continue;
                    }
                }
                else
                    continue;
            }
            else
                continue;

            if (_refName !is null)
                refName ~= _refName;

            if (isSchemaDiff && typeName != "schema")
                dependency.append(Value.dictOf("type", typeName, "name", refName, "oid", objectId));
            else if (!isSchemaDiff)
            {
                string depType;
                if (showSystemObjects.isNone)
                    showSystemObjects = Value(bpModule.showSystemObjectsFlag);
                switch (depStr.length ? depStr[0 .. 1] : "")
                {
                case "n": depType = "normal"; break;
                case "a": depType = "auto"; break;
                case "i":
                    if (showSystemObjects.truthy)
                        depType = "internal";
                    else
                        continue;
                    break;
                case "p":
                    depType = "pin";
                    typeName = "";
                    break;
                default: break;
                }
                dependency.append(Value.dictOf("type", typeName, "name", refName, "field", depType, "icon", icon));
            }
        }
        return dependency;
    }

    bool checkCascadeOperation(bool onlySql = false) => cmd == "delete" || onlySql;

    // ------------------------------------------------------------ helpers shared by the node views

    bool datistemplate;

    /// `self.blueprint.generate_browser_node(...)`: the node's `inode` comes from the module.
    Value gbn(Value nodeId, Value parentId, string label, string icon = null, Dict extra = null)
    {
        return (cast(CollectionNodeModule) bpModule).generateBrowserNode(nodeId, parentId, label, icon, extra);
    }

    /// The usual `check_precondition(action)` of the nodes below a database: sets `manager`, `conn`, `datistemplate`
    /// and `templatePath` (`base` has `{0}` for the server version, or `{0}`/`{1}` for server type and version).
    /// Returns an error response or null.
    Response standardPrecondition(Dict kwargs, string action, string base)
    {
        manager = getDriver().connectionManagerOrNull(kwargs["sid"].integer);
        if (manager is null)
            return gone(gettext("Could not find the server."));
        if (action == "drop")
            conn = manager.connection();
        else if (kwargs.has("did"))
            conn = manager.connection(null, null, true, kwargs["did"]);
        else
            conn = manager.connection();
        datistemplate = false;
        if (kwargs.has("did") && manager.dbInfo !is null && manager.dbInfo.has(kwargs["did"].toString)
                && manager.dbInfo[kwargs["did"].toString].contains("datistemplate"))
            datistemplate = manager.dbInfo[kwargs["did"].toString]["datistemplate"].truthy;
        templatePath = base.canFind("{1}")
            ? base.replace("{0}", manager.serverType).replace("{1}", to!string(manager.version_))
            : base.replace("{0}", to!string(manager.version_));
        return null;
    }

    /// The `check_precondition` of the nodes directly below a server (no database id): like `standardPrecondition`
    /// but the database is the manager's current one and a lost connection answers 428.
    Response serverPrecondition(Dict kwargs, string action, string base)
    {
        auto err = standardPrecondition(kwargs, action, base);
        if (err !is null)
            return err;
        datistemplate = false;
        if (manager.dbInfo !is null && !manager.did.isNone && manager.dbInfo.has(manager.did.toString)
                && manager.dbInfo[manager.did.toString].contains("datistemplate"))
            datistemplate = manager.dbInfo[manager.did.toString]["datistemplate"].truthy;
        if (!conn.connected())
            return preconditionRequired(gettext("Connection to the server has been lost."));
        return null;
    }

    /// Renders `<templatePath>/<name>` with the given variables (`tv(...)`).
    string rt(string name, Value[string] vars = null) => renderTemplate(templatePath ~ "/" ~ name, vars);

    /// The query-string arguments as a data dict (each value parsed as JSON when possible, except the `rawKeys`),
    /// as every `msql` view does.
    static Value msqlData(string[] rawKeys...)
    {
        auto data = Value.newDict();
        foreach (k; request().args.keys)
        {
            auto v = request().args.get(k);
            data[k] = rawKeys.canFind(k) ? Value(v) : tryParseJson(v, Value(v));
        }
        return data;
    }

    /// 400/410 response naming the first missing required argument, or null.
    static Response missingArg(Value data, string[] required, int status = 410)
    {
        foreach (arg; required)
            if (!data.contains(arg))
                return makeJsonResponse(0, Value(gettext("Could not find the required parameter ({}).").replace("{}", arg)),
                        Value(""), Value(null), Value(null), status);
        return null;
    }

    /// `for k, v in data.items(): try: data[k] = json.loads(v) except (ValueError, TypeError, KeyError): data[k] = v`
    /// (string values are decoded, except the `rawKeys`).
    static Value loadJsonValues(Value data, string[] rawKeys...)
    {
        foreach (k, v; data.dict)
            if (!rawKeys.canFind(k) && v.isString)
                data[k] = tryParseJson(v.str, v);
        return data;
    }

    /// `json.loads(request.data)` if there is a body, else `request.args or request.form`.
    static Value argsOrJson()
    {
        auto r = request();
        if (r.data.length)
            return parseJson(r.text);
        return r.args.empty ? r.form.toDict : r.args.toDict;
    }

    /// The `[{label, value}]` list of the function pickers (`FUNCTIONS_SQL` rendered with `flag=True`), led by an
    /// entry with an empty label and `firstValue`.
    Response functionOptions(string flag, Value firstValue)
    {
        auto r = conn.executeDict(rt(FUNCTIONS_SQL, tv(flag, true)));
        if (!r.ok)
            return internalServerError(r.error);
        Value[] res = [Value.dictOf("label", "", "value", firstValue)];
        foreach (row; r.value["rows"].list.items)
            res ~= Value.dictOf("label", row["proname"], "value", row["proname"]);
        return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
    }

    /// `data.get(name)`-style access on a data dict.
    static Value getOr(Value data, string name, Value def = Value(null)) => data.contains(name) ? data[name] : def;
}

// ------------------------------------------------------------ read-only schema children

/// A node below a schema that can only be listed, inspected and scripted (aggregates, operators...): `list`, `nodes`,
/// `node`, `properties` and `sql` with a shared structure. Subclasses set the ids and implement `sqlText`.
abstract class ReadOnlySchemaChildView : PGChildNodeView
{
    string idName;        /// the node's own id parameter ("agid")
    string icon;          /// "icon-aggregate"
    string baseTemplate;  /// "aggregates/sql/#{0}#"
    bool listUsesNodesSql = true;
    bool propertiesPass = true; /// whether `_fetch_properties` passes `datlastsysoid`

    this()
    {
        super();
        parentIds = [IdSpec("int", "gid"), IdSpec("int", "sid"), IdSpec("int", "did"), IdSpec("int", "scid")];
        setAllOps([
            makeOp("obj", ["get": "properties", "delete": "delete", "put": "update"],
                    ["get": "list", "post": "create", "delete": "delete"]),
            makeOp("delete", ["delete": "delete"], ["delete": "delete"]),
            makeOp("children", ["get": "children"]),
            makeOp("nodes", ["get": "node"], ["get": "nodes"]),
            makeOp("sql", ["get": "sql"]),
        ]);
    }

    /// The full script of an object: header, drop statement and create statement.
    abstract string sqlText(Value data);

    override Response callMethod(string name, Dict k)
    {
        if (!isAuthenticated())
            return unauthorisedResponse();
        if (name == "children")
            return children(k);
        auto err = standardPrecondition(k, name, baseTemplate);
        if (err !is null)
            return err;
        auto scid = k["scid"];
        auto id = k.has(idName) ? k[idName] : Value(null);
        switch (name)
        {
        case "list":
        {
            auto r = conn.executeDict(rt(listUsesNodesSql ? NODES_SQL : PROPERTIES_SQL, tv("scid", scid)));
            if (!r.ok)
                return internalServerError(r.error);
            return makeResponse(r.value["rows"], 200);
        }
        case "nodes":
        {
            auto r = conn.execute2darray(rt(NODES_SQL, tv("scid", scid)));
            if (!r.ok)
                return internalServerError(r.error);
            Value[] res;
            foreach (row; r.value["rows"].list.items)
                res ~= gbn(row["oid"], scid, row["name"].toString, icon,
                        kwDict("description", row["description"]));
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        case "node":
        {
            auto vars = tv("scid", scid);
            vars[idName] = id;
            auto r = conn.execute2darray(rt(NODES_SQL, vars));
            if (!r.ok)
                return internalServerError(r.error);
            foreach (row; r.value["rows"].list.items)
                return makeJsonResponse(1, Value(""), Value(""), Value(null), gbn(row["oid"], scid,
                        row["name"].toString, icon), 200);
            return gone(notFoundErrorMsg());
        }
        case "properties":
        {
            Response e2;
            auto res = fetchProperties(scid, id, e2);
            if (e2 !is null)
                return e2;
            return makeResponse(res, 200);
        }
        case "sql":
        {
            auto vars = tv("scid", scid);
            vars[idName] = id;
            auto r = conn.executeDict(rt(PROPERTIES_SQL, vars));
            if (!r.ok)
                return internalServerError(r.error);
            if (r.value["rows"].length == 0)
                return gone(notFoundErrorMsg());
            return makeResponse(Value(sqlText(r.value["rows"][0])));
        }
        default: return super.callMethod(name, k);
        }
    }

    Value fetchProperties(Value scid, Value id, out Response err)
    {
        auto vars = tv("scid", scid, "datlastsysoid", DATABASE_LAST_SYSTEM_OID_);
        vars[idName] = id;
        auto r = conn.executeDict(rt(PROPERTIES_SQL, vars));
        if (!r.ok)
        {
            err = internalServerError(r.error);
            return Value(null);
        }
        if (r.value["rows"].length == 0)
        {
            err = gone(notFoundErrorMsg());
            return Value(null);
        }
        auto row = r.value["rows"][0];
        row["is_sys_obj"] = Value(row["oid"].integer <= DATABASE_LAST_SYSTEM_OID_ || datistemplate);
        return row;
    }
}
