/// `pgadmin/tools/sqleditor/command.py`: the commands behind a Query Tool / View-Edit Data tab.
module pgadmin.tools.sqleditor.command;

import pgadmin.browser.common;
import pgadmin.utils.preferences : Preferences;
import pgadmin.tools.sqleditor.helpers;

enum VIEW_FIRST_100_ROWS = 1;
enum VIEW_LAST_100_ROWS = 2;
enum VIEW_ALL_ROWS = 3;
enum VIEW_FILTERED_ROWS = 4;

private Preferences sqleditorPrefs() => Preferences.module_("sqleditor");

/// A preference of the sqleditor module (an error rather than a null dereference for a wrong name).
private Value sqlPref(string name)
{
    auto p = sqleditorPrefs().preference(name);
    if (p is null)
        throw new Exception("unknown preference sqleditor." ~ name);
    return p.get();
}

/// `BaseCommand` + `FetchedRowTracker` + what both command families share.
abstract class BaseCommand
{
    Value sgid, sid, did;
    string connId;
    string connIdAc;
    string dbname;
    bool hasDbname;
    long fetchedRows;
    bool serverCursor;
    /// the background fiber running the query is alive (`thread_native_id` + `thread.is_alive()` in Python)
    bool queryRunning;
    bool autoCommit = true;
    bool autoRollback;
    // set once the command refers to a table (`obj_id` in Python)
    bool hasObjId;
    Value objId;
    string nspName;
    string objectName;
    string sqlPath;

    abstract string objectType() const;
    abstract string getSql(Connection defaultConn = null);
    abstract bool canEdit();
    abstract bool canFilter();

    this(Dict kw)
    {
        sgid = kw.get("sgid", Value(null));
        sid = kw.get("sid", Value(null));
        did = kw.get("did", Value(null));
    }

    long getFetchedRowCnt() => fetchedRows;
    void updateFetchedRowCnt(long n) { fetchedRows = n; }
    void setServerCursor(Value v) { serverCursor = v.truthy; }
    void setAutoCommit(Value v) { autoCommit = v.truthy; }
    void setAutoRollback(Value v) { autoRollback = v.truthy; }

    /// The filter API: only the grid commands have a real one.
    string getFilter() => null;
    Value getDataSorting() => Value(null);
    bool isFilterApplied() => false;

    /// `get_primary_keys`: (pk_names, primary_keys)
    string primaryKeyNames;
    Value primaryKeys = Value(null);
    Value getPrimaryKeys(out string pkNames, Connection conn = null)
    {
        pkNames = primaryKeyNames;
        return primaryKeys;
    }

    bool hasOids(Connection conn = null) => false;
    Value getColumnsTypes(Connection conn = null) => Value(null);

    /// `save(changed_data, columns_info, client_primary_key, default_conn)`
    SaveResult save(Value changedData, Value columnsInfo, string clientPrimaryKey, Connection conn)
    {
        // GridCommand.save returns a forbidden() Response, which the view then fails to unpack as a 4-tuple
        throw new Exception("cannot unpack non-iterable Response object");
    }

    protected ServerManager manager() => getDriver().connectionManager(sid.integer);
}

/// What unpickling a stored command gives: a copy that can be changed without touching the stored one.
T cloneCommand(T : BaseCommand)(T src)
{
    immutable size = typeid(src).initializer.length;
    auto mem = new void[size];
    mem[] = (cast(void*) src)[0 .. size];
    return cast(T) mem.ptr;
}

/// Creates the command registered for `name` (`ObjectRegistry.get_object`).
BaseCommand createCommand(string name, Dict kw)
{
    switch (name)
    {
    case "table": return new TableCommand(kw);
    case "view": return new ViewCommand(kw);
    case "mview": return new MViewCommand(kw);
    case "foreign_table": return new ForeignTableCommand(kw);
    case "catalog_object": return new CatalogCommand(kw);
    case "query_tool": return new QueryToolCommand(kw);
    default:
        throw new Exception("This feature has not been implemented for object type '" ~ name ~ "'.");
    }
}

/// `SQLFilter`
abstract class GridCommand : BaseCommand
{
    Value cmdType;
    Value limit = Value(-1);
    string rowFilter;
    bool hasRowFilter;
    Value dataSorting = Value(null);
    bool setSortingFromFilterDialog;

    this(Dict kw)
    {
        super(kw);
        // SQLFilter
        enforceKw(kw, "sid");
        enforceKw(kw, "did");
        enforceKw(kw, "obj_id");
        objId = kw["obj_id"];
        hasObjId = true;
        auto sf = kw.get("sql_filter", Value(null));
        if (sf.isString)
        {
            rowFilter = sf.str;
            hasRowFilter = true;
        }
        dataSorting = kw.get("data_sorting", Value(null));
        auto mgr = manager();
        auto conn = mgr.connection(null, null, true, did);
        sqlPath = "sqleditor/sql/#" ~ to!string(mgr.version_) ~ "#";
        if (conn.connected())
        {
            auto r = conn.executeDict(renderTemplate(sqlPath ~ "/objectname.sql", tv("obj_id", objId)));
            if (!r.ok)
                throw new ExecuteError(r.error);
            if (r.value["rows"].length == 0)
                throw new ObjectGone(gettext("The specified object could not be found."));
            nspName = r.value["rows"][0]["nspname"].toString;
            objectName = r.value["rows"][0]["relname"].toString;
        }
        else
            throw new HTTPException(500, SERVER_CONNECTION_CLOSED);
        // GridCommand
        connId = kw.has("conn_id") ? kw["conn_id"].toString : null;
        cmdType = kw.get("cmd_type", Value(null));
        if (cmdType == Value(VIEW_FIRST_100_ROWS) || cmdType == Value(VIEW_LAST_100_ROWS))
            limit = Value(100);
        else if (cmdType == Value(VIEW_ALL_ROWS))
        {
            auto def = sqlPref("view_data_default_row_limit");
            if (def.isInt && def.integer > 0)
                limit = def;
        }
        auto sc = kw.get("server_cursor", Value(null));
        serverCursor = sc.truthy;
    }

    private static void enforceKw(Dict kw, string k)
    {
        if (!kw.has(k))
            throw new Exception("AssertionError");
    }

    override string getFilter() => hasRowFilter ? rowFilter : null;

    /// `set_filter`: validates and stores; (status, message)
    Res setFilter(Value f)
    {
        string newFilter = f.isString ? f.str : null;
        auto r = validateFilter(newFilter);
        if (r.ok)
        {
            rowFilter = newFilter;
            hasRowFilter = newFilter !is null;
        }
        return r;
    }

    override Value getDataSorting()
    {
        if (!dataSorting.isNone && dataSorting.truthy)
            return dataSorting;
        return Value(null);
    }

    void setDataSorting(Value filter, bool fromFilterDialog = false)
    {
        dataSorting = filter["data_sorting"];
        setSortingFromFilterDialog = fromFilterDialog;
    }

    bool isSortingSetFromFilterDialog() => setSortingFromFilterDialog;

    override bool isFilterApplied()
    {
        bool applied = true;
        if (!hasRowFilter || rowFilter == "")
            applied = false;
        if (!applied && dataSorting.truthy)
            applied = true;
        return applied;
    }

    void removeFilter()
    {
        rowFilter = null;
        hasRowFilter = false;
        dataSorting = Value(null);
    }

    void appendFilter(string f)
    {
        auto existing = getFilter();
        if (existing is null || existing == "")
        {
            rowFilter = f;
            hasRowFilter = true;
        }
        else
            rowFilter = existing ~ " \n    AND " ~ f;
    }

    Res validateFilter(string f)
    {
        if (f !is null && f != "")
        {
            auto mgr = manager();
            auto conn = mgr.connection(null, null, true, did);
            if (conn.connected())
            {
                auto sql = renderTemplate(sqlPath ~ "/validate.sql", tv("nsp_name", nspName, "object_name", objectName,
                        "row_filter", f));
                auto r = conn.executeScalar(sql);
                if (!r.ok)
                {
                    auto msg = r.error;
                    auto nl = msg.indexOf('\n');
                    return Res(false, Value(nl >= 0 ? msg[0 .. nl] : msg));
                }
                return r;
            }
        }
        return Res(true, Value(null));
    }

    Value getAllColumnsWithOrder()
    {
        auto ds = getDataSorting();
        return ds.truthy ? ds : Value.newList();
    }

    Value getLimit() => limit;
    void setLimit(Value l) { limit = l; }

    string getPkOrder() => cmdType == Value(VIEW_LAST_100_ROWS) ? "desc" : "asc";

    override Value getPrimaryKeys(out string pkNames, Connection conn = null)
    {
        pkNames = null;
        return Value(null);
    }

    protected string objectQuery(Connection defaultConn, bool withOids, bool tableCmd)
    {
        auto sqlFilter = getFilter();
        auto ds = getDataSorting();
        Value[string] vars = tv("object_name", objectName, "nsp_name", nspName, "limit", limit, "data_sorting", ds);
        if (tableCmd)
            vars["has_oids"] = Value(withOids);
        if (sqlFilter !is null)
            vars["sql_filter"] = Value(sqlFilter);
        return renderTemplate(sqlPath ~ "/objectquery.sql", vars);
    }
}

final class TableCommand : GridCommand
{
    bool dataSortingByPk;

    this(Dict kw)
    {
        super(kw);
        dataSortingByPk = sqlPref("table_view_data_by_pk").truthy;
    }

    override string objectType() const => "table";
    override bool canEdit() => true;
    override bool canFilter() => true;

    override string getSql(Connection defaultConn = null)
    {
        string pkn;
        auto pks = getPrimaryKeys(pkn, defaultConn);
        auto oids = hasOids(defaultConn);
        auto sqlFilter = getFilter();
        auto ds = getDataSorting();
        if (ds.isNone && !isSortingSetFromFilterDialog()
                && (cmdType == Value(VIEW_FIRST_100_ROWS) || cmdType == Value(VIEW_LAST_100_ROWS)
                    || (cmdType == Value(VIEW_ALL_ROWS) && dataSortingByPk)))
        {
            Value[] sorted;
            foreach (pk, _; pks.dict)
                sorted ~= Value.dictOf("name", pk, "order", getPkOrder());
            setDataSorting(Value.dictOf("data_sorting", Value(sorted)));
            ds = getDataSorting();
        }
        Value[string] vars = tv("object_name", objectName, "nsp_name", nspName, "limit", limit, "has_oids", oids,
                "data_sorting", ds);
        if (sqlFilter !is null)
            vars["sql_filter"] = Value(sqlFilter);
        return renderTemplate(sqlPath ~ "/objectquery.sql", vars);
    }

    override Value getPrimaryKeys(out string pkNames, Connection defaultConn = null)
    {
        auto driver = getDriver();
        Connection conn = defaultConn !is null ? defaultConn : manager().connection(null, connId, true, did);
        auto pks = Value.newDict();
        pkNames = "";
        if (conn.connected())
        {
            auto q = renderTemplate(sqlPath ~ "/primary_keys.sql", tv("table_name", objectName, "table_nspname", nspName,
                    "conn", conn));
            auto r = conn.executeDict(q);
            if (!r.ok)
                throw new ExecuteError(r.error);
            foreach (row; r.value["rows"].list.items)
            {
                pkNames ~= qtIdentStr(row["attname"].toString) ~ ",";
                pks[row["attname"].toString] = row["typname"];
            }
            if (pkNames != "")
                pkNames = pkNames[0 .. $ - 1];
        }
        else
            throw new HTTPException(500, SERVER_CONNECTION_CLOSED);
        return pks;
    }

    override bool hasOids(Connection defaultConn = null)
    {
        auto mgr = manager();
        if (mgr.sversion >= 120000)
            return false;
        Connection conn = defaultConn !is null ? defaultConn : mgr.connection(null, connId, true, did);
        if (conn.connected())
        {
            auto r = conn.executeScalar(renderTemplate(sqlPath ~ "/has_oids.sql", tv("obj_id", objId)));
            if (!r.ok)
                throw new ExecuteError(r.error);
            return r.value.truthy;
        }
        throw new HTTPException(500, SERVER_CONNECTION_CLOSED);
    }

    override SaveResult save(Value changedData, Value columnsInfo, string clientPrimaryKey, Connection defaultConn)
    {
        Connection conn = defaultConn !is null ? defaultConn : manager().connection(null, connId, true, did);
        return saveChangedData(changedData, columnsInfo, conn, this, clientPrimaryKey, true);
    }

    override Value getColumnsTypes(Connection conn = null)
    {
        auto info = conn.getColumnInfo();
        auto oids = hasOids();
        string tableName, tableNsp;
        auto tableOid = checkSingleTable(info);
        if (tableOid.isNone)
        {
            tableName = objectName;
            tableNsp = nspName;
        }
        return getColumnsTypesFor(conn, info, oids, tableOid, false, tableName, tableNsp);
    }
}

class ViewCommand : GridCommand
{
    this(Dict kw) { super(kw); }
    override string objectType() const => "view";
    override bool canEdit() => false;
    override bool canFilter() => true;
    override string getSql(Connection defaultConn = null) => objectQuery(defaultConn, false, false);
}

final class MViewCommand : ViewCommand
{
    this(Dict kw) { super(kw); }
    override string objectType() const => "mview";
}

final class ForeignTableCommand : GridCommand
{
    this(Dict kw) { super(kw); }
    override string objectType() const => "foreign_table";
    override bool canEdit() => false;
    override bool canFilter() => true;
    override string getSql(Connection defaultConn = null) => objectQuery(defaultConn, false, false);
}

final class CatalogCommand : GridCommand
{
    this(Dict kw) { super(kw); }
    override string objectType() const => "catalog_object";
    override bool canEdit() => false;
    override bool canFilter() => true;
    override string getSql(Connection defaultConn = null) => objectQuery(defaultConn, false, false);
}

/// `QueryToolCommand`
final class QueryToolCommand : BaseCommand
{
    bool isUpdatableResultset;
    bool tableHasOids;
    Value columnsTypes = Value(null);

    this(Dict kw)
    {
        super(kw);
        connId = kw.has("conn_id") ? kw["conn_id"].toString : null;
        connIdAc = kw.has("conn_id_ac") ? kw["conn_id_ac"].toString : null;
    }

    override string objectType() const => "query_tool";
    override string getSql(Connection defaultConn = null) => null;
    override bool canEdit() => isUpdatableResultset;
    override bool canFilter() => false;
    override bool hasOids(Connection conn = null) => tableHasOids;
    override Value getColumnsTypes(Connection conn = null) => columnsTypes;

    void setConnectionId(string id) { connId = id; }
    void setConnectionIdAc(string id) { connIdAc = id; }

    /// `check_updatable_results_pkeys_oids`
    bool checkUpdatableResultsPkeysOids()
    {
        auto mgr = manager();
        auto conn = mgr.connection(null, connId, true, did);
        auto path = "sqleditor/sql/#" ~ to!string(mgr.version_) ~ "#";
        auto u = isQueryResultsetUpdatable(conn, path);
        isUpdatableResultset = u.updatable;
        tableHasOids = u.hasOids;
        primaryKeys = u.primaryKeys;
        columnsTypes = u.columnTypes;
        if (!u.pkNames.isNone)
        {
            primaryKeyNames = "";
            foreach (n; u.pkNames.iterItems())
                primaryKeyNames ~= qtIdentStr(n.toString) ~ ",";
            if (primaryKeyNames != "")
                primaryKeyNames = primaryKeyNames[0 .. $ - 1];
        }
        if (isUpdatableResultset)
        {
            sqlPath = path;
            objId = u.tableOid;
            hasObjId = true;
            if (conn.connected())
            {
                auto r = conn.executeDict(renderTemplate(sqlPath ~ "/objectname.sql", tv("obj_id", objId)));
                if (!r.ok)
                    throw new ExecuteError(r.error);
                nspName = r.value["rows"][0]["nspname"].toString;
                objectName = r.value["rows"][0]["relname"].toString;
            }
            else
                throw new HTTPException(500, SERVER_CONNECTION_CLOSED);
        }
        return isUpdatableResultset;
    }

    override SaveResult save(Value changedData, Value columnsInfo, string clientPrimaryKey, Connection defaultConn)
    {
        if (!isUpdatableResultset)
            return SaveResult(false, Value(gettext("Resultset is not updatable.")), Value(null), Value(null));
        Connection conn = defaultConn !is null ? defaultConn : manager().connection(null, connId, true, did);
        return saveChangedData(changedData, columnsInfo, conn, this, clientPrimaryKey, autoCommit);
    }
}

/// `SQLFilter(sid, did, obj_id)` used by `validate_filter` (a bare filter object).
final class BareFilter
{
    Value sid, did, objId;
    string sqlPath, nspName, objectName;

    this(Value sid, Value did, Value objId)
    {
        this.sid = sid;
        this.did = did;
        this.objId = objId;
        auto mgr = getDriver().connectionManager(sid.integer);
        auto conn = mgr.connection(null, null, true, did);
        sqlPath = "sqleditor/sql/#" ~ to!string(mgr.version_) ~ "#";
        if (conn.connected())
        {
            auto r = conn.executeDict(renderTemplate(sqlPath ~ "/objectname.sql", tv("obj_id", objId)));
            if (!r.ok)
                throw new ExecuteError(r.error);
            if (r.value["rows"].length == 0)
                throw new ObjectGone(gettext("The specified object could not be found."));
            nspName = r.value["rows"][0]["nspname"].toString;
            objectName = r.value["rows"][0]["relname"].toString;
        }
        else
            throw new HTTPException(500, SERVER_CONNECTION_CLOSED);
    }

    Res validateFilter(string f)
    {
        if (f !is null && f != "")
        {
            auto mgr = getDriver().connectionManager(sid.integer);
            auto conn = mgr.connection(null, null, true, did);
            if (conn.connected())
            {
                auto r = conn.executeScalar(renderTemplate(sqlPath ~ "/validate.sql", tv("nsp_name", nspName,
                        "object_name", objectName, "row_filter", f)));
                if (!r.ok)
                {
                    auto msg = r.error;
                    auto nl = msg.indexOf('\n');
                    return Res(false, Value(nl >= 0 ? msg[0 .. nl] : msg));
                }
                return r;
            }
        }
        return Res(true, Value(null));
    }
}
