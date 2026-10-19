/// `tables/utils.py` and `base_partition_table.py`: the base of the table and partition views.
module pgadmin.browser.server_groups.servers.databases.schemas.tables.utils;

import std.algorithm : canFind, min;
import std.array : join, split, replace;
import std.conv : to;
import std.regex : regex, replaceAll;
import std.string : strip, startsWith, endsWith, indexOf;
import pgadmin.browser.common;
import pgadmin.browser.server_groups.servers.databases.schemas.utils;
import columnUtils = pgadmin.browser.server_groups.servers.databases.schemas.tables.columns.utils;
import fkeyUtils = pgadmin.browser.server_groups.servers.databases.schemas.tables.constraints.foreign_key.utils;
import checkUtils = pgadmin.browser.server_groups.servers.databases.schemas.tables.constraints.check_constraint.utils;
import exclusionUtils = pgadmin.browser.server_groups.servers.databases.schemas.tables.constraints.exclusion_constraint.utils;
import idxconsUtils = pgadmin.browser.server_groups.servers.databases.schemas.tables.constraints.index_constraint.utils;
import triggerUtils = pgadmin.browser.server_groups.servers.databases.schemas.tables.triggers.utils;
import compoundTriggerUtils = pgadmin.browser.server_groups.servers.databases.schemas.tables.compound_triggers.utils;
import indexUtils = pgadmin.browser.server_groups.servers.databases.schemas.tables.indexes.utils;
import policyUtils = pgadmin.browser.server_groups.servers.databases.schemas.tables.row_security_policies.utils;
import pgadmin.utils.preferences : Preferences;

/// `int(x)` for the numbers the driver returns (ints, floats, numeric strings).
long pyInt(Value v)
{
    if (v.isInt)
        return v.integer;
    if (v.type == VType.floating)
        return cast(long) v.floating;
    if (v.isNone)
        return 0;
    return to!long(v.toString);
}

abstract class BaseTableView : PGChildNodeView
{
    enum BASE_TEMPLATE_PATH = "tables/sql/#{0}#";
    enum pattern = "\n{2,}";
    enum doubleNewline = "\n\n";

    string tableTemplatePath;
    string dataTypeTemplatePath;
    string partitionTemplatePath;
    string columnTemplatePath;
    string indexTemplatePath;
    string rowSecurityPoliciesTemplatePath;
    string triggerTemplatePath;
    string compoundTriggerTemplatePath;
    string rulesTemplatePath;
    string[] acl;
    string[] columnAcl;
    string[] tablesSubModules;

    /// `cmd` of the Python view: set to "delete" while the drop SQL of a table is built.
    string cmdOverride;
    override bool checkCascadeOperation(bool onlySql = false) => cmdOverride == "delete" || super.checkCascadeOperation(onlySql);

    /// `BaseTableView.check_precondition`: returns an error response or null.
    Response tablePrecondition(Dict k)
    {
        manager = getDriver().connectionManagerOrNull(k["sid"].integer);
        if (manager is null)
            return gone(gettext("Could not find the server."));
        if (k.has("conn_id"))
            conn = manager.connection(null, k["conn_id"].toString, true, k["did"]);
        else
            conn = manager.connection(null, null, true, k["did"]);
        immutable ver = manager.version_;
        immutable serverType = manager.serverType;
        tableTemplatePath = "tables/sql/#" ~ to!string(ver) ~ "#";
        templatePath = tableTemplatePath;
        dataTypeTemplatePath = "datatype/sql/#" ~ to!string(ver) ~ "#";
        partitionTemplatePath = "partitions/sql/" ~ serverType ~ "/#" ~ serverType ~ "#" ~ to!string(ver) ~ "#";
        columnTemplatePath = "columns/sql/#" ~ to!string(ver) ~ "#";
        indexTemplatePath = "indexes/sql/#" ~ to!string(ver) ~ "#";
        rowSecurityPoliciesTemplatePath = "row_security_policies/sql/#" ~ to!string(ver) ~ "#";
        triggerTemplatePath = "triggers/sql/" ~ serverType ~ "/#" ~ to!string(ver) ~ "#";
        compoundTriggerTemplatePath = "compound_triggers/sql/" ~ serverType ~ "/#" ~ to!string(ver) ~ "#";
        rulesTemplatePath = "rules/sql";
        acl = ["a", "r", "w", "d", "D", "x", "t"];
        if (ver >= 170000)
            acl = ["a", "r", "w", "d", "D", "x", "t", "m"];
        columnAcl = ["a", "r", "w", "x"];
        tablesSubModules = ["index", "rule", "trigger"];
        if (serverType == "ppas" && ver >= 120000)
            tablesSubModules ~= "compound_trigger";
        if (ver >= 90500)
            tablesSubModules ~= "row_security_policy";
        return null;
    }

    string tt(string name, Value[string] vars = null) => renderTemplate(tableTemplatePath ~ "/" ~ name, vars);

    // ---------------------------------------------------------------- partition helpers (BasePartitionTable)

    bool isTablePartitioned(Value tableInfo)
        => nodeType == "partition" || (tableInfo.contains("is_partitioned") && tableInfo["is_partitioned"].truthy);

    string getIconCssClass(Value tableInfo, string defaultVal = "icon-table")
    {
        if (isTablePartitioned(tableInfo))
            return "icon-partition_table";
        return defaultVal;
    }

    string getPartitionIconCssClass(Value tableInfo, string defaultVal = "icon-partition")
    {
        if (tableInfo.contains("is_sub_partitioned") && tableInfo["is_sub_partitioned"].truthy)
            return "icon-sub_partition_table";
        return defaultVal;
    }

    // ---------------------------------------------------------------- formatting

    Value formatter(Value did, Value scid, Value tid, Value data, bool withSerialCols = true)
    {
        if (data.contains("seclabels") && !data["seclabels"].isNone)
        {
            Value[] seclabels;
            foreach (s; data["seclabels"].iterItems())
            {
                auto parts = s.toString.split("=");
                if (parts.length != 2)
                    throw new Exception("too many values to unpack (expected 2)");
                seclabels ~= Value.dictOf("provider", parts[0], "label", parts[1]);
            }
            data["seclabels"] = Value(seclabels);
        }
        auto a = conn.executeDict(tt(ACL_SQL, tv("tid", tid, "scid", scid)));
        if (!a.ok)
            throw new ExecuteError(a.error);
        setPrivilegesForProperties(data, a.value);
        data["vacuum_table"] = parseVacuumData(conn, data, "table").deepCopy();
        data["vacuum_toast"] = parseVacuumData(conn, data, "toast").deepCopy();
        Value[] otherColumns;
        string tableOrType;
        if (data["typoid"].truthy)
        {
            auto r = conn.executeDict(tt("get_columns_for_table.sql", tv("tid", data["typoid"], "conn", conn)));
            if (!r.ok)
                throw new ExecuteError(r.error);
            otherColumns = r.value["rows"].list.items.dup;
            tableOrType = "type";
        }
        else if (data["coll_inherits"].truthy && data["coll_inherits"].length > 0)
        {
            getInheritedTables(scid, data, otherColumns);
            tableOrType = "table";
        }
        data = columnUtils.getFormattedColumns(conn, tid, data, otherColumns, tableOrType, null, withSerialCols);
        addConstraintsToOutput(data, did, tid);
        return data;
    }

    private void getInheritedTables(Value scid, Value data, ref Value[] otherColumns)
    {
        auto r = conn.execute2darray(tt("get_inherits.sql", tv("show_system_objects", false, "scid", scid)));
        if (!r.ok)
            throw new ExecuteError(r.error);
        foreach (row; r.value["rows"].list.items)
            if (data["coll_inherits"].iterItems().canFind(row["inherits"]))
            {
                auto c = conn.executeDict(tt("get_columns_for_table.sql", tv("tid", row["oid"], "conn", conn)));
                if (!c.ok)
                    throw new ExecuteError(c.error);
                otherColumns ~= c.value["rows"].list.items;
            }
    }

    static void setPrivilegesForProperties(Value data, Value acl)
    {
        foreach (row; acl["rows"].list.items)
        {
            auto priv = parsePrivFromDb(row);
            auto t = row["deftype"].toString;
            if (data.contains(t))
                data[t].append(priv);
            else
                data[t] = Value([priv]);
        }
    }

    private void addConstraintsToOutput(Value data, Value did, Value tid)
    {
        foreach (pair; [["p", "primary_key"], ["u", "unique_constraint"]])
        {
            data[pair[1]] = Value.newList();
            auto r = idxconsUtils.getIndexConstraints(conn, did, tid, pair[0]);
            if (r.ok)
                foreach (cons; r.value.list.items)
                    if (!isPartitionAndConstraintInherited(cons, data))
                        data[pair[1]].append(cons);
        }
        auto fk = fkeyUtils.getForeignKeys(conn, tid);
        if (fk.ok)
            foreach (f; fk.value.list.items)
                if (!isPartitionAndConstraintInherited(f, data))
                    appendTo(data, "foreign_key", f);
        auto cc = checkUtils.getCheckConstraints(conn, tid);
        if (cc.ok)
            foreach (c; cc.value.list.items)
                if (!isPartitionAndConstraintInherited(c, data))
                    appendTo(data, "check_constraint", c);
        auto ex = exclusionUtils.getExclusionConstraints(conn, did, tid);
        if (ex.ok)
            foreach (e; ex.value.list.items)
                appendTo(data, "exclude_constraint", e);
    }

    private static void appendTo(Value data, string key, Value item)
    {
        if (!data.contains(key))
            data[key] = Value.newList();
        data[key].append(item);
    }

    private static bool isPartitionAndConstraintInherited(Value constraint, Value data)
        => data.contains("relispartition") && data["relispartition"] == Value(true) && constraint.contains("conislocal")
            && constraint["conislocal"] == Value(false);

    // ---------------------------------------------------------------- dependents, statistics...

    Response getTableDependents(Value tid)
    {
        auto where = "WHERE dep.refobjid=" ~ tid.toString ~ "::OID";
        auto result = getDependents(conn, tid);
        auto r = conn.executeDict(tt("depend.sql", tv("where", where)));
        if (!r.ok)
            return internalServerError(r.error);
        foreach (row; r.value["rows"].list.items)
        {
            if (row["refname"].isNone)
                continue;
            string depType;
            auto ds = row["deptype"].toString;
            if (ds == "a")
                depType = "auto";
            else if (ds == "n")
                depType = "normal";
            else if (ds == "i")
                depType = "internal";
            result.append(Value.dictOf("type", "sequence", "name", row["refname"], "field", depType));
        }
        return makeResponse(result, 200);
    }

    Response getTableDependencies(Value tid) => makeResponse(getDependencies(conn, tid), 200);

    Res getFkRefTables(Value tid)
    {
        auto r = conn.executeDict(tt("fk_ref_tables.sql", tv("oid", tid)));
        if (!r.ok)
            return r;
        return Res(true, r.value["rows"]);
    }

    Response getTableStatistics(Value scid, Value tid)
    {
        auto s = conn.executeScalar(tt("get_schema.sql", tv("conn", conn, "scid", scid)));
        if (!s.ok)
            return internalServerError(s.error);
        Res res;
        if (tid.isNone)
            res = conn.executeDict(tt("coll_table_stats.sql", tv("conn", conn, "schema_name", s.value)));
        else
        {
            auto p = checkPgstattuple(conn, tid);
            if (!p.ok)
                return internalServerError(p.error);
            auto t = conn.executeScalar(tt("get_table.sql", tv("conn", conn, "scid", scid, "tid", tid)));
            if (!t.ok)
                return internalServerError(t.error);
            res = conn.executeDict(tt("stats.sql", tv("conn", conn, "schema_name", s.value, "table_name", t.value,
                    "is_pgstattuple", p.value, "tid", tid)));
        }
        if (!res.ok)
            return internalServerError(res.error);
        return makeJsonResponse(1, Value(""), Value(""), Value(null), res.value, 200);
    }

    string getTypesConditionSql(bool showSystemObjects)
        => tt("get_types_where_condition.sql", tv("show_system_objects", showSystemObjects));

    private static void checkRlspolicySupport(Value res)
    {
        auto row = res["rows"][0];
        if (row.contains("rlspolicy"))
        {
            if (row["rlspolicy"] == Value("true"))
                row["rlspolicy"] = Value(true);
            if (row["forcerlspolicy"] == Value("true"))
                row["forcerlspolicy"] = Value(true);
        }
    }

    /// `_fetch_table_properties` -> the result set (`{'rows': [...]}`) or an error response.
    Value fetchTableProperties(Value did, Value scid, Value tid, out Response err)
    {
        auto r = conn.executeDict(tt(PROPERTIES_SQL, tv("did", did, "scid", scid, "tid", tid,
                "datlastsysoid", DATABASE_LAST_SYSTEM_OID_, "conn", conn)));
        if (!r.ok)
        {
            err = internalServerError(r.error);
            return Value(null);
        }
        if (r.value["rows"].length == 0)
        {
            err = gone(gettext(notFoundErrorMsg()));
            return Value(null);
        }
        auto res = r.value;
        auto row = res["rows"][0];
        updateAutovacuumProperties(row);
        auto thresholdPref = Preferences.module_("browser").preference("table_row_count_threshold");
        auto threshold = thresholdPref.get().integer;
        auto estimated = pyInt(row.dict.get("reltuples", Value(0)));
        checkRlspolicySupport(res);
        if (!estimated || estimated < 0)
            row["rows_cnt"] = Value(0);
        else if (estimated > threshold)
            row["rows_cnt"] = Value(to!string(threshold) ~ "+");
        else if (0 < estimated && estimated <= threshold)
        {
            auto c = conn.executeScalar(tt("get_table_row_count.sql", tv("data", row)));
            if (!c.ok)
            {
                err = internalServerError(c.error);
                return Value(null);
            }
            row["rows_cnt"] = c.value;
        }
        auto a = conn.executeDict(tt(ACL_SQL, tv("tid", tid, "scid", scid)));
        if (!a.ok)
        {
            err = internalServerError(r.error);
            return Value(null);
        }
        Value[] privileges;
        foreach (aclRow; a.value["rows"].list.items)
            privileges ~= parsePrivFromDb(aclRow);
        row["acl"] = Value(privileges);
        return res;
    }

    /// Fetches all tables (or a specific table) formatted for ERD/schema diff.
    Res fetchTables(Value sid, Value did, Value scid, Value tid = Value(null), bool withSerialCols = true)
    {
        if (!tid.isNone && tid.truthy)
        {
            Response err;
            auto data = fetchTableProperties(did, scid, tid, err);
            if (err !is null)
                return Res(false, Value(err.body));
            auto props = baseProperties(Value(0), sid, did, scid, tid, data, withSerialCols);
            return Res(true, props);
        }
        else
        {
            auto sql = tt(NODES_SQL, tv("scid", scid, "schema_diff", Value(true)));
            auto r = conn.execute2darray(sql);
            if (!r.ok)
                return r;
            auto res = Value.newDict();
            foreach (row; r.value["rows"].list.items)
            {
                Response err;
                auto data = fetchTableProperties(did, scid, row["oid"], err);
                if (err is null && !data.isNone)
                {
                    auto props = baseProperties(Value(0), sid, did, scid, row["oid"], data, withSerialCols);
                    res[row["name"].toString] = props;
                }
            }
            return Res(true, res);
        }
    }

    private void formatColumnList(Value data)
    {
        if (data.contains("columns"))
            foreach (c; data["columns"].iterItems())
            {
                if (c.contains("attacl"))
                    c["attacl"] = parsePrivToDb(c["attacl"], columnAcl);
                if (c.contains("cltype"))
                {
                    bool sqr;
                    auto t = columnUtils.typeFormatter(c["cltype"].toString, sqr);
                    c["cltype"] = Value(t);
                    c["hasSqrBracket"] = Value(sqr);
                }
            }
    }

    // ---------------------------------------------------------------- reverse engineered SQL

    private void getResqlForTable(Value did, Value scid, Value tid, Value data, bool jsonResp, ref string[] mainSql,
            bool addNotExistsClause = false)
    {
        data = formatter(did, scid, tid, data);
        formatColumnList(data);
        if (jsonResp)
        {
            auto header = "-- Table: " ~ data["schema"].toString ~ "." ~ data["name"].toString ~ "\n\n-- ";
            header ~= tt(DELETE_SQL, tv("data", data, "conn", conn));
            header = header.strip("\n");
            header ~= "\n";
            mainSql ~= header;
        }
        if (data.contains("relacl"))
            data["relacl"] = parsePrivToDb(data["relacl"], acl);
        if (data.contains("acl"))
        {
            data["revoke_all"] = Value.newList();
            foreach (a; data["acl"].iterItems())
                if (a["privileges"].length > 0 && a["privileges"].length < 7)
                    data["revoke_all"].append(a["grantee"] != Value("PUBLIC") ? Value(qtIdentStr(a["grantee"].toString)) : Value("PUBLIC"));
        }
        string tableSql;
        if (data.contains("relispartition") && data["relispartition"].truthy)
            tableSql = renderTemplate(partitionTemplatePath ~ "/" ~ CREATE_SQL, tv("data", data, "conn", conn,
                    "add_not_exists_clause", addNotExistsClause));
        else
            tableSql = tt(CREATE_SQL, tv("data", data, "conn", conn, "is_sql", true,
                    "add_not_exists_clause", addNotExistsClause));
        tableSql = replaceAll(tableSql, regex(pattern), doubleNewline);
        mainSql ~= tableSql.strip("\n");
    }

    private void getResqlForIndex(Value did, Value tid, ref string[] mainSql, bool jsonResp, string schema, string table,
            bool addNotExistsClause = false)
    {
        auto r = conn.execute2darray(renderTemplate(indexTemplatePath ~ "/" ~ NODES_SQL, tv("tid", tid)));
        if (!r.ok)
            throw new ExecuteError(r.error);
        foreach (row; r.value["rows"].list.items)
        {
            if (row.contains("is_inherited") && row["is_inherited"] == Value(true))
                continue;
            auto indexSql = indexUtils.getReverseEngineeredSql(conn, schema, table, did, tid, row["oid"],
                    Value(DATABASE_LAST_SYSTEM_OID_), null, jsonResp, addNotExistsClause);
            indexSql = "\n" ~ indexSql;
            indexSql = replaceAll(indexSql, regex(pattern), doubleNewline);
            mainSql ~= indexSql.strip("\n");
        }
    }

    private void getResqlForRowSecurityPolicy(Value scid, Value tid, bool jsonResp, ref string[] mainSql, string schema,
            string table)
    {
        if (manager.version_ < 90500)
            return;
        auto r = conn.execute2darray(renderTemplate(rowSecurityPoliciesTemplatePath ~ "/" ~ NODES_SQL, tv("tid", tid)));
        if (!r.ok)
            throw new ExecuteError(r.error);
        foreach (row; r.value["rows"].list.items)
        {
            auto policySql = policyUtils.getReverseEngineeredSql(conn, schema, table, scid, row["oid"], tid,
                    Value(DATABASE_LAST_SYSTEM_OID_), null, jsonResp);
            policySql = "\n" ~ policySql;
            policySql = replaceAll(policySql, regex(pattern), doubleNewline);
            mainSql ~= policySql.strip("\n");
        }
    }

    private void getResqlForTriggers(Value tid, bool jsonResp, ref string[] mainSql, string schema, string table)
    {
        auto r = conn.execute2darray(renderTemplate(triggerTemplatePath ~ "/" ~ NODES_SQL, tv("tid", tid)));
        if (!r.ok)
            throw new ExecuteError(r.error);
        foreach (row; r.value["rows"].list.items)
        {
            auto triggerSql = triggerUtils.getReverseEngineeredSql(conn, schema, table, tid, row["oid"],
                    Value(DATABASE_LAST_SYSTEM_OID_), bpModule.showSystemObjectsFlag, null, jsonResp);
            triggerSql = "\n" ~ triggerSql;
            triggerSql = replaceAll(triggerSql, regex(pattern), doubleNewline);
            mainSql ~= triggerSql;
        }
    }

    private void getResqlForCompoundTriggers(Value tid, ref string[] mainSql, string schema, string table)
    {
        if (!(manager.serverType == "ppas" && manager.version_ >= 120000))
            return;
        auto r = conn.execute2darray(renderTemplate(compoundTriggerTemplatePath ~ "/" ~ NODES_SQL, tv("tid", tid)));
        if (!r.ok)
            throw new ExecuteError(r.error);
        foreach (row; r.value["rows"].list.items)
        {
            auto sql = compoundTriggerUtils.getReverseEngineeredSql(conn, schema, table, tid, row["oid"],
                    Value(DATABASE_LAST_SYSTEM_OID_));
            sql = "\n" ~ sql;
            sql = replaceAll(sql, regex(pattern), doubleNewline);
            mainSql ~= sql;
        }
    }

    private void getResqlForRules(Value tid, ref string[] mainSql, string table, bool jsonResp)
    {
        auto r = conn.execute2darray(renderTemplate(rulesTemplatePath ~ "/" ~ NODES_SQL, tv("tid", tid)));
        if (!r.ok)
            throw new ExecuteError(r.error);
        foreach (row; r.value["rows"].list.items)
        {
            string rulesSql = "\n";
            auto p = conn.executeDict(renderTemplate(rulesTemplatePath ~ "/" ~ PROPERTIES_SQL,
                    tv("rid", row["oid"], "datlastsysoid", DATABASE_LAST_SYSTEM_OID_)));
            if (!p.ok)
                throw new ExecuteError(p.error);
            bool displayComments = jsonResp;
            auto resData = parseRuleDefinition(p.value);
            if (resData.contains("view"))
                resData["view"] = Value(table);
            rulesSql ~= renderTemplate(rulesTemplatePath ~ "/" ~ CREATE_SQL, tv("data", resData,
                    "display_comments", displayComments, "add_replace_clause", true, "conn", conn));
            rulesSql = replaceAll(rulesSql, regex(pattern), doubleNewline);
            mainSql ~= rulesSql;
        }
    }

    private void getResqlForPartitions(Value data, Value rset, bool jsonResp, bool diffPartitionSql, ref string[] mainSql,
            Value did)
    {
        string sqlHeader;
        string[] partitionSqlArr;
        if (rset["rows"].length == 0)
            return;
        if (jsonResp)
            sqlHeader = "\n-- Partitions SQL";
        foreach (row; rset["rows"].list.items)
        {
            auto partData = Value.newDict();
            partData["partitioned_table_name"] = data["name"];
            partData["parent_schema"] = data["schema"];
            partData["spcname"] = row["spcname"];
            partData["schema"] = jsonResp ? row["schema_name"] : data["schema"];
            partData["relispartition"] = Value(true);
            partData["name"] = row["name"];
            partData["partition_value"] = row["partition_value"];
            partData["is_partitioned"] = row["is_partitioned"];
            partData["partition_scheme"] = row["partition_scheme"];
            partData["description"] = row["description"];
            partData["relowner"] = row["relowner"];
            partData["default_amname"] = data.dict.get("default_amname", Value(null));
            partData["amname"] = row.dict.get("amname", Value(null));
            updateAutovacuumProperties(row);
            foreach (key; ["fillfactor", "autovacuum_custom", "autovacuum_enabled", "autovacuum_vacuum_threshold",
                    "autovacuum_vacuum_scale_factor", "autovacuum_analyze_threshold", "autovacuum_analyze_scale_factor",
                    "autovacuum_vacuum_cost_delay", "autovacuum_vacuum_cost_limit", "autovacuum_freeze_min_age",
                    "autovacuum_freeze_max_age", "autovacuum_freeze_table_age", "toast_autovacuum",
                    "toast_autovacuum_enabled", "toast_autovacuum_vacuum_threshold", "toast_autovacuum_vacuum_scale_factor",
                    "toast_autovacuum_analyze_threshold", "toast_autovacuum_analyze_scale_factor",
                    "toast_autovacuum_vacuum_cost_delay", "toast_autovacuum_vacuum_cost_limit",
                    "toast_autovacuum_freeze_min_age", "toast_autovacuum_freeze_max_age",
                    "toast_autovacuum_freeze_table_age"])
                partData[key] = row[key];
            partData["vacuum_table"] = parseVacuumData(conn, row, "table").deepCopy();
            partData["vacuum_toast"] = parseVacuumData(conn, row, "toast").deepCopy();
            auto scid = row["schema_id"];
            auto schema = partData["schema"].toString;
            auto table = partData["name"].toString;
            addConstraintsToOutput(partData, did, row["oid"]);
            auto partitionSql = renderTemplate(partitionTemplatePath ~ "/" ~ CREATE_SQL, tv("data", partData, "conn", conn)) ~ "\n";
            partitionSql = replaceAll(partitionSql, regex(pattern), doubleNewline).strip("\n");
            partitionSqlArr ~= partitionSql.strip("\n");
            getResqlForIndex(did, row["oid"], partitionSqlArr, jsonResp, schema, table);
            getResqlForRowSecurityPolicy(scid, row["oid"], jsonResp, partitionSqlArr, schema, table);
            getResqlForTriggers(row["oid"], jsonResp, partitionSqlArr, schema, table);
            getResqlForCompoundTriggers(row["oid"], partitionSqlArr, schema, table);
            getResqlForRules(row["oid"], partitionSqlArr, table, jsonResp);
        }
        if (!diffPartitionSql)
        {
            mainSql ~= sqlHeader ~ "\n";
            mainSql ~= partitionSqlArr;
        }
    }

    /// `get_reverse_engineered_sql(...)`: the script of a table and what hangs off it. With `jsonResp` the response
    /// holds the SQL; otherwise `sqlOut` does.
    Response getReverseEngineeredSql(Value did, Value scid, Value tid, ref string[] mainSql, Value data, bool jsonResp,
            bool diffPartitionSql, bool ifExistsFlag, out string sqlOut)
    {
        auto schema = data["schema"].toString;
        auto table = data["name"].toString;
        bool isPartitioned = data.contains("is_partitioned") && data["is_partitioned"].truthy;
        getResqlForTable(did, scid, tid, data, jsonResp, mainSql, ifExistsFlag);
        getResqlForIndex(did, tid, mainSql, jsonResp, schema, table, ifExistsFlag);
        getResqlForRowSecurityPolicy(scid, tid, jsonResp, mainSql, schema, table);
        getResqlForTriggers(tid, jsonResp, mainSql, schema, table);
        getResqlForCompoundTriggers(tid, mainSql, schema, table);
        getResqlForRules(tid, mainSql, table, jsonResp);
        if (isPartitioned)
        {
            auto r = conn.execute2darray(renderTemplate(partitionTemplatePath ~ "/" ~ NODES_SQL,
                    tv("scid", scid, "tid", tid, "did", did)));
            if (!r.ok)
                return internalServerError(r.error);
            getResqlForPartitions(data, r.value, jsonResp, diffPartitionSql, mainSql, did);
        }
        sqlOut = mainSql.join("\n");
        if (!jsonResp)
            return null;
        return makeResponse(Value(sqlOut.strip("\n")), 200);
    }

    Response resetStatistics(Value scid, Value tid)
    {
        string schemaName, tableName;
        getSchemaAndTableName(tid, schemaName, tableName);
        if (tableName is null)
            return gone(gettext(notFoundErrorMsg()));
        try
        {
            auto r = conn.executeScalar(tt("reset_stats.sql", tv("tid", tid)));
            if (!r.ok)
                return internalServerError(r.error);
            return makeJsonResponse(1, Value(""), Value(gettext("Table statistics have been reset")), Value(null),
                    Value.dictOf("id", tid, "scid", scid));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    string getPartitionScheme(Value data)
    {
        string scheme;
        auto partType = data.contains("sub_partition_type") ? "sub_partition_type" : "partition_type";
        auto partKeys = data.contains("sub_partition_keys") ? "sub_partition_keys" : "partition_keys";
        if (data.contains(partType) && data[partType] == Value("range"))
            scheme = "RANGE (";
        else if (data.contains(partType) && data[partType] == Value("list"))
            scheme = "LIST (";
        else if (data.contains(partType) && data[partType] == Value("hash"))
            scheme = "HASH (";
        auto keys = data.dict.get(partKeys, Value.newList());
        foreach (row; keys.iterItems())
        {
            if (row["key_type"] == Value("column"))
            {
                scheme ~= qtIdentStr(row["pt_column"].toString);
                if (row.contains("collationame") && row["collationame"].truthy)
                    scheme ~= " COLLATE " ~ row["collationame"].toString;
                if (row.contains("op_class"))
                    scheme ~= " " ~ row["op_class"].toString;
                scheme ~= ", ";
            }
            else if (row["key_type"] == Value("expression"))
                scheme ~= row["expression"].toString ~ ", ";
        }
        if (keys.length > 0)
            scheme = scheme[0 .. $ - 2];
        scheme ~= ")";
        return scheme;
    }

    static bool validateConstrains(string key, Value data)
    {
        if (key == "primary_key" || key == "unique_constraint")
            return data.contains("columns") && data["columns"].length > 0;
        if (key == "foreign_key")
            return checkForeignKey(data);
        if (key == "check_constraint")
        {
            if (!data.contains("consrc") || data["consrc"] == Value(""))
                return false;
        }
        return true;
    }

    private static bool checkForeignKey(Value data)
    {
        if (!data.contains("oid"))
        {
            if (!data.contains("columns") || (data["columns"].isList && data["columns"].length < 1))
                return false;
            if (data.contains("autoindex") && data["autoindex"].truthy
                    && (!data.contains("coveringindex") || data["coveringindex"] == Value("")))
                return false;
        }
        return true;
    }

    static Value checkAndConvertNameToString(Value data)
    {
        auto n = data["name"];
        if (n.isInt || n.type == VType.floating)
            data["name"] = Value(n.toString);
        return data;
    }

    private void getPrivilegesFromClient(Value data)
    {
        if (data.contains("relacl"))
            foreach (mode; ["added", "changed", "deleted"])
                if (data["relacl"].contains(mode))
                    data["relacl"][mode] = parsePrivToDb(data["relacl"][mode], acl);
    }

    private static Value setDiff(Value a, Value b)
    {
        Value[] r;
        foreach (x; a.iterItems())
        {
            bool found;
            foreach (y; b.iterItems())
                if (x == y)
                {
                    found = true;
                    break;
                }
            bool dup;
            foreach (z; r)
                if (z == x)
                    dup = true;
            if (!found && !dup)
                r ~= x;
        }
        return Value(r);
    }

    private static void filterNewTables(Value data, Value oldData)
    {
        if (!data.contains("coll_inherits"))
            return;
        immutable pLen = oldData["coll_inherits"].length;
        immutable cLen = data["coll_inherits"].length;
        if (cLen > pLen)
            data["coll_inherits_added"] = setDiff(data["coll_inherits"], oldData["coll_inherits"]);
        else if (cLen < pLen)
            data["coll_inherits_removed"] = setDiff(oldData["coll_inherits"], data["coll_inherits"]);
        else
        {
            data["coll_inherits_added"] = setDiff(data["coll_inherits"], oldData["coll_inherits"]);
            data["coll_inherits_removed"] = setDiff(oldData["coll_inherits"], data["coll_inherits"]);
        }
    }

    private string checkForColumnDelete(Value columns, Value data, string columnSql)
    {
        if (columns.contains("deleted"))
            foreach (c; columns["deleted"].iterItems())
            {
                c["schema"] = data["schema"];
                c["table"] = data["name"];
                if (c.dict.get("inheritedfrom", Value(null)).isNone)
                    columnSql ~= renderTemplate(columnTemplatePath ~ "/" ~ DELETE_SQL, tv("data", c, "conn", conn)).strip("\n")
                        ~ doubleNewline;
            }
        return columnSql;
    }

    private static void normaliseSerialColumn(Value data, Value oldColData)
    {
        auto cltype = data.dict.get("cltype", Value(null));
        if (cltype.isNone || !(cltype.toString in columnUtils.UNDERLYING_SERIAL_TYPES))
            return;
        data["cltype"] = Value(columnUtils.UNDERLYING_SERIAL_TYPES[cltype.toString]);
        if (data.dict.get("typname", Value(null)) == cltype)
            data["typname"] = data["cltype"];
        data.dict.pop("defval");
        foreach (key; ["seqincrement", "seqstart", "seqmin", "seqmax", "seqcache", "seqcycle"])
            data.dict.pop(key);
    }

    private string checkForColumnUpdate(Value columns, Value data, string columnSql, Value tid)
    {
        if (!columns.contains("changed"))
            return columnSql;
        foreach (c; columns["changed"].iterItems())
        {
            c["schema"] = data["schema"];
            c["table"] = data["name"];
            auto r = conn.executeDict(renderTemplate(columnTemplatePath ~ "/" ~ PROPERTIES_SQL, tv("tid", tid,
                    "clid", c.contains("attnum") ? c["attnum"] : Value(null), "show_sys_objects", bpModule.showSystemObjectsFlag)));
            if (!r.ok)
                throw new ExecuteError(r.error);
            auto oldColData = r.value["rows"][0];
            bool sqr;
            oldColData["cltype"] = Value(columnUtils.typeFormatter(oldColData["cltype"].toString, sqr));
            oldColData["hasSqrBracket"] = Value(sqr);
            oldColData = columnUtils.convertLengthPrecisionToString(oldColData);
            oldColData = columnUtils.fetchLengthPrecision(oldColData);
            oldColData["cltype"] = Value(DataTypeReader.parseTypeName(oldColData["cltype"].toString));
            normaliseSerialColumn(c, oldColData);
            if (c.dict.get("inheritedfrom", Value(null)).isNone && c.dict.get("inheritedfromtable", Value(null)).isNone)
                columnSql ~= renderTemplate(columnTemplatePath ~ "/" ~ UPDATE_SQL, tv("data", c, "o_data", oldColData,
                        "conn", conn)).strip("\n") ~ doubleNewline;
        }
        return columnSql;
    }

    private string checkForColumnAdd(Value columns, Value data, string columnSql)
    {
        if (columns.contains("added"))
            foreach (c; columns["added"].iterItems())
            {
                c["schema"] = data["schema"];
                c["table"] = data["name"];
                c = columnUtils.convertLengthPrecisionToString(c);
                if (c.dict.get("inheritedfrom", Value(null)).isNone && c.dict.get("inheritedfromtable", Value(null)).isNone)
                    columnSql ~= renderTemplate(columnTemplatePath ~ "/" ~ CREATE_SQL, tv("data", c, "conn", conn)).strip("\n")
                        ~ doubleNewline;
            }
        return columnSql;
    }

    private string checkForPartitionsInSql(Value data, Value oldData, string sql)
    {
        if (!data.contains("partitions"))
            return sql;
        auto partitions = data["partitions"];
        string partitionsSql = "\n";
        if (partitions.contains("deleted"))
            foreach (row; partitions["deleted"].iterItems())
            {
                string schemaName, tableName;
                getSchemaAndTableName(row["oid"], schemaName, tableName);
                auto tmp = Value.dictOf("parent_schema", data["schema"], "partitioned_table_name", data["name"],
                        "schema", schemaName, "name", tableName);
                partitionsSql ~= renderTemplate(partitionTemplatePath ~ "/detach.sql", tv("data", tmp, "conn", conn)).strip("\n")
                    ~ doubleNewline;
            }
        if (partitions.contains("added") && oldData.contains("partition_scheme") && oldData["partition_scheme"] != Value(""))
        {
            auto tmp = Value.dictOf("schema", data["schema"], "name", data["name"],
                    "partition_type", oldData["partition_scheme"].toString.split(" ")[0].toLower, "partitions", partitions["added"]);
            partitionsSql ~= getPartitionsSql(tmp).strip("\n") ~ doubleNewline;
        }
        sql ~= "\n" ~ partitionsSql.strip("\n");
        return sql;
    }

    private string checkForConstraints(Value indexConstraintSql, Value data, Value did, Value tid, string sql)
    {
        if (!indexConstraintSql.isNone)
            sql ~= "\n" ~ indexConstraintSql.toString;
        auto fk = fkeyUtils.getForeignKeySql(conn, tid, data);
        if (!fk.isNone)
            sql ~= "\n" ~ fk.toString;
        auto cc = checkUtils.getCheckConstraintSql(conn, tid, data);
        if (!cc.isNone)
            sql ~= "\n" ~ cc.toString;
        auto ex = exclusionUtils.getExclusionConstraintSql(conn, did, tid, data);
        if (!ex.isNone)
            sql ~= "\n" ~ ex.toString;
        return sql;
    }

    void checkFkConstraint(Value data)
    {
        if (data.contains("foreign_key"))
            foreach (c; data["foreign_key"].iterItems())
            {
                string schema, table;
                fkeyUtils.getParent(conn, c["columns"][0]["references"], schema, table);
                c["remote_schema"] = Value(schema);
                c["remote_table"] = Value(table);
            }
    }

    string checkForPartitioned(Value data)
    {
        string partitionsSql;
        if (data.contains("is_partitioned") && data["is_partitioned"].truthy)
        {
            data["relkind"] = Value("p");
            data["partition_scheme"] = Value(getPartitionScheme(data));
            partitionsSql = getPartitionsSql(data);
        }
        return partitionsSql;
    }

    private string validateConstraintData(Value data)
    {
        foreach (key; ["primary_key", "unique_constraint", "foreign_key", "check_constraint", "exclude_constraint"])
            if (data.contains(key) && data[key].length > 0)
                foreach (constraint; data[key].iterItems())
                    if (!validateConstrains(key, constraint))
                        return gettext("-- definition incomplete for " ~ key);
        return null;
    }

    /// `get_sql(did, scid, tid, data, res, add_not_exists_clause, with_drop)` -> the SQL; `name` is the table name.
    string getSql(Value did, Value scid, Value tid, Value data, Value res, out string name, bool addNotExistsClause = false,
            bool withDrop = false)
    {
        Value oldData;
        string sql;
        if (!tid.isNone)
        {
            oldData = res["rows"][0];
            oldData = formatter(did, scid, tid, oldData);
            getPrivilegesFromClient(data);
            if (!data.contains("name"))
                data["name"] = oldData["name"];
            data = checkAndConvertNameToString(data);
            if (!data.contains("schema"))
                data["schema"] = oldData["schema"];
            filterNewTables(data, oldData);
            updateVacuumSettings("vacuum_table", oldData, data);
            updateVacuumSettings("vacuum_toast", oldData, data);
            sql = tt(UPDATE_SQL, tv("o_data", oldData, "data", data, "conn", conn));
            sql = sql.strip("\n") ~ doubleNewline;
            if (data.contains("columns"))
            {
                data = columnUtils.parseFormatColumns(data, "edit");
                auto columns = data["columns"];
                string columnSql = "\n";
                columnSql = checkForColumnDelete(columns, data, columnSql);
                columnSql = checkForColumnUpdate(columns, data, columnSql, tid);
                columnSql = checkForColumnAdd(columns, data, columnSql);
                sql ~= columnSql.strip("\n");
            }
            sql = checkForPartitionsInSql(data, oldData, sql);
            data["columns_to_be_dropped"] = Value.newList();
            if (data.contains("columns") && data["columns"].contains("deleted"))
                foreach (d; data["columns"]["deleted"].iterItems())
                    data["columns_to_be_dropped"].append(d["name"]);
            auto indexConstraintSql = idxconsUtils.getIndexConstraintSql(conn, did, tid, data);
            sql = checkForConstraints(indexConstraintSql, data, did, tid, sql);
        }
        else
        {
            if (!data.contains("name"))
            {
                name = data["name"].toString; // KeyError in Python, like its caller would see
                return gettext("-- definition incomplete");
            }
            auto incomplete = validateConstraintData(data);
            convertPrivilegeToServerFormat(data);
            data = columnUtils.parseFormatColumns(data);
            data = checkAndConvertNameToString(data);
            checkFkConstraint(data);
            auto partitionsSql = checkForPartitioned(data);
            updateVacuumSettings("vacuum_table", data);
            updateVacuumSettings("vacuum_toast", data);
            sql = "";
            if (withDrop)
                sql = getDeleteSql(data) ~ "\n\n";
            sql ~= tt(CREATE_SQL, tv("data", data, "conn", conn, "add_not_exists_clause", addNotExistsClause));
            sql ~= "\n" ~ partitionsSql;
        }
        sql = replaceAll(sql, regex(pattern), doubleNewline);
        sql = sql.strip("\n");
        name = data.contains("name") ? data["name"].toString : oldData["name"].toString;
        return sql;
    }

    private void convertPrivilegeToServerFormat(Value data)
    {
        if (data.contains("relacl"))
            data["relacl"] = parsePrivToDb(data["relacl"], acl);
    }

    /// `update(...)` of `BaseTableView` (used by the table and partition views).
    Response baseUpdate(Value gid, Value sid, Value did, Value scid, Value tid, Value data, Value res,
            Value parentId = Value(null))
    {
        string schemaName, tableName;
        getSchemaAndTableName(tid, schemaName, tableName);
        if (tableName is null)
            return gone(gettext(notFoundErrorMsg()));
        try
        {
            string name;
            auto sql = getSql(did, scid, tid, data, res, name);
            sql = sql.strip("\n").strip(" ");
            auto x = conn.executeScalar(sql);
            if (!x.ok)
                return internalServerError(x.error);
            auto s = conn.execute2darray(tt(GET_SCHEMA_OID_SQL, tv("tid", tid, "conn", conn)));
            if (!s.ok)
                return internalServerError(s.error);
            if (!parentId.truthy)
                parentId = scid;
            auto partitionsOid = new Dict;
            bool isPartitioned = checkForPartitions(data, partitionsOid, res, scid);
            string icon;
            auto row = res["rows"][0];
            if (row.contains("partitioned_table_name"))
            {
                row["is_sub_partitioned"] = Value(isPartitioned);
                icon = getPartitionIconCssClass(row);
            }
            else
                icon = getIconCssClass(row);
            auto extra = new Dict;
            extra["is_partitioned"] = Value(isPartitioned);
            extra["parent_schema_id"] = scid;
            extra["schema_id"] = s.value["rows"][0]["scid"];
            extra["schema_name"] = s.value["rows"][0]["nspname"];
            extra["affected_partitions"] = Value(partitionsOid);
            if (data.contains("description"))
                extra["description"] = data["description"];
            return jsonify(Value.dictOf("node", gbn(tid, parentId, name, icon, extra)));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private bool checkForPartitions(Value data, Dict partitionsOid, Value res, Value scid)
    {
        if (data.contains("partitions"))
        {
            if (data["partitions"].contains("deleted"))
            {
                Value[] detached;
                foreach (row; data["partitions"]["deleted"].iterItems())
                {
                    auto p = conn.executeScalar(tt(GET_SCHEMA_OID_SQL, tv("tid", row["oid"], "conn", conn)));
                    if (!p.ok)
                        throw new ExecuteError(p.error);
                    detached ~= Value.dictOf("oid", row["oid"], "schema_id", p.value);
                }
                partitionsOid["detached"] = Value(detached);
            }
            fetchOidSchemaIod(data, scid, partitionsOid);
        }
        auto row = res["rows"][0];
        return row.contains("is_partitioned") ? row["is_partitioned"].truthy : false;
    }

    private void fetchOidSchemaIod(Value data, Value scid, Dict partitionsOid)
    {
        if (!data["partitions"].contains("added"))
            return;
        Value[] created, attached;
        foreach (row; data["partitions"]["added"].iterItems())
        {
            if (row["is_attach"].truthy)
            {
                auto p = conn.executeScalar(tt(GET_SCHEMA_OID_SQL, tv("tid", row["partition_name"], "conn", conn)));
                if (!p.ok)
                    throw new ExecuteError(p.error);
                attached ~= Value.dictOf("oid", row["partition_name"], "schema_id", p.value);
            }
            else
            {
                auto tmp = Value.dictOf("name", row["partition_name"]);
                auto t = conn.executeScalar(tt(OID_SQL, tv("scid", scid, "data", tmp, "conn", conn)));
                if (!t.ok)
                    throw new ExecuteError(t.error);
                created ~= Value.dictOf("oid", t.value, "schema_id", scid);
            }
        }
        partitionsOid["created"] = Value(created);
        partitionsOid["attached"] = Value(attached);
    }

    /// `properties(...)` of `BaseTableView`: the formatted table (and its partitions).
    Value baseProperties(Value gid, Value sid, Value did, Value scid, Value tid, Value res, bool withSerialCols = false)
    {
        auto data = res["rows"][0];
        data["vacuum_settings_str"] = Value("");
        string vs;
        if (!data["reloptions"].isNone)
        {
            string[] o;
            foreach (x; data["reloptions"].iterItems())
                o ~= x.toString;
            vs ~= o.join("\n");
        }
        if (!data["toast_reloptions"].isNone)
        {
            vs ~= vs != "" ? "\n" : "";
            string[] o;
            foreach (x; data["toast_reloptions"].iterItems())
                o ~= "toast." ~ x.toString;
            vs ~= o.join("\n");
        }
        data["vacuum_settings_str"] = Value(vs.replace("=", " = "));
        data = formatter(did, scid, tid, data, withSerialCols);
        if (data.contains("is_partitioned") && data["is_partitioned"].truthy)
        {
            data["partition_type"] = Value(data["partition_scheme"].toString.split(" ")[0].toLower);
            Value[] partitions;
            auto r = conn.execute2darray(renderTemplate(partitionTemplatePath ~ "/" ~ NODES_SQL,
                    tv("scid", scid, "tid", tid, "did", did)));
            if (!r.ok)
                throw new ExecuteError(r.error);
            foreach (row; r.value["rows"].list.items)
            {
                auto partitionName = row["name"].toString;
                if (data["schema"] != row["schema_name"])
                    partitionName = row["schema_name"].toString ~ "." ~ row["name"].toString;
                partitionTypeCheck(data, row, partitions, partitionName);
            }
            data["partitions"] = Value(partitions);
        }
        return data;
    }

    private static void partitionTypeCheck(Value data, Value row, ref Value[] partitions, string partitionName)
    {
        auto ptype = data["partition_type"].toString;
        auto amname = row.dict.get("amname", Value(""));
        if (ptype == "range")
        {
            Value rangeFrom, rangeTo;
            bool isDefault;
            if (row["partition_value"] == Value("DEFAULT"))
            {
                isDefault = true;
                rangeFrom = Value(null);
                rangeTo = Value(null);
            }
            else
            {
                auto pv = row["partition_value"].toString;
                auto rangePart = pv.split("FOR VALUES FROM (")[1].split(") TO");
                rangeFrom = Value(rangePart[0]);
                rangeTo = Value(rangePart[1][2 .. $ - 1]);
            }
            partitions ~= Value.dictOf("oid", row["oid"], "partition_name", partitionName, "values_from", rangeFrom,
                    "values_to", rangeTo, "is_default", isDefault, "is_sub_partitioned", row["is_sub_partitioned"],
                    "sub_partition_scheme", row["sub_partition_scheme"], "amname", amname);
        }
        else if (ptype == "list")
        {
            Value rangeIn;
            bool isDefault;
            if (row["partition_value"] == Value("DEFAULT"))
            {
                isDefault = true;
                rangeIn = Value(null);
            }
            else
            {
                auto part = row["partition_value"].toString.split("FOR VALUES IN (")[1];
                rangeIn = Value(part[0 .. $ - 1]);
            }
            partitions ~= Value.dictOf("oid", row["oid"], "partition_name", partitionName, "values_in", rangeIn,
                    "is_default", isDefault, "is_sub_partitioned", row["is_sub_partitioned"],
                    "sub_partition_scheme", row["sub_partition_scheme"], "amname", amname);
        }
        else
        {
            auto rangePart = row["partition_value"].toString.split("FOR VALUES WITH (")[1].split(",");
            // strip("modulus") / strip(" remainder") remove *characters* of those words, as in Python
            auto modulus = pyStripChars(pyStripChars(rangePart[0].strip, "modulus"), " ").strip;
            auto remainder = pyStripChars(pyStripChars(rangePart[1].strip, " remainder"), ")").strip;
            partitions ~= Value.dictOf("oid", row["oid"], "partition_name", partitionName, "values_modulus", modulus,
                    "values_remainder", remainder, "is_sub_partitioned", row["is_sub_partitioned"],
                    "sub_partition_scheme", row["sub_partition_scheme"], "amname", amname);
        }
    }

    private static string pyStripChars(string s, string chars)
    {
        import pgadmin.core.strutil : pyStrip;
        return pyStrip(s, chars);
    }

    string getPartitionsSql(Value partitions, bool schemaDiff = false)
    {
        string sql;
        foreach (row; partitions["partitions"].iterItems())
        {
            auto partData = Value.newDict();
            partData["partitioned_table_name"] = partitions["name"];
            partData["parent_schema"] = partitions["schema"];
            partData["amname"] = row.dict.get("amname", Value(null));
            if (row.contains("is_attach") && row["is_attach"].truthy)
            {
                string schemaName, tableName;
                getSchemaAndTableName(row["partition_name"], schemaName, tableName);
                partData["schema"] = Value(schemaName);
                partData["name"] = Value(tableName);
            }
            else
            {
                partData["schema"] = partitions["schema"];
                partData["relispartition"] = Value(true);
                partData["name"] = row["partition_name"];
            }
            auto ptype = partitions["partition_type"].toString;
            if (row.contains("is_default") && row["is_default"].truthy && (ptype == "range" || ptype == "list"))
                partData["partition_value"] = Value("DEFAULT");
            else if (ptype == "range")
                partData["partition_value"] = Value("FOR VALUES FROM (" ~ row["values_from"].toString.split(",").join(", ")
                        ~ ") TO (" ~ row["values_to"].toString.split(",").join(", ") ~ ")");
            else if (ptype == "list")
                partData["partition_value"] = Value("FOR VALUES IN (" ~ row["values_in"].toString.split(",").join(", ") ~ ")");
            else
                partData["partition_value"] = Value("FOR VALUES WITH (MODULUS " ~ row["values_modulus"].toString.split(",").join(", ")
                        ~ ", REMAINDER " ~ row["values_remainder"].toString.split(",").join(", ") ~ ")");
            sql ~= checkForPartitionedTable(row, partData, schemaDiff);
        }
        return sql;
    }

    private string checkForPartitionedTable(Value row, Value partData, bool schemaDiff)
    {
        if (row.contains("is_sub_partitioned") && row["is_sub_partitioned"].truthy)
        {
            partData["partition_scheme"] = row.contains("sub_partition_scheme") ? row["sub_partition_scheme"]
                : Value(getPartitionScheme(row));
            partData["is_partitioned"] = Value(true);
        }
        if (row.contains("is_attach") && row["is_attach"].truthy)
            return renderTemplate(partitionTemplatePath ~ "/attach.sql", tv("data", partData, "conn", conn));
        if (schemaDiff)
            partData["name"] = row["temp_partition_name"];
        return renderTemplate(partitionTemplatePath ~ "/" ~ CREATE_SQL, tv("data", partData, "conn", conn));
    }

    Response baseTruncate(Value gid, Value sid, Value did, Value scid, Value tid, Value res)
    {
        auto data0 = formOrJson(request());
        auto isCascade = data0.dict.get("cascade", Value(false)).truthy;
        auto isIdentity = data0.dict.get("identity", Value(false)).truthy;
        auto data = res["rows"][0];
        auto lock = getTableLocks(did, data);
        if (lock !is null)
            return lock;
        auto x = conn.executeScalar(tt("truncate.sql", tv("data", data, "cascade", isCascade, "identity", isIdentity)));
        if (!x.ok)
            return internalServerError(x.error);
        return makeJsonResponse(1, Value(""), Value(gettext("Table truncated")), Value(null),
                Value.dictOf("id", tid, "scid", scid));
    }

    string getDeleteSql(Value data)
    {
        bool cascade = checkCascadeOperation();
        return tt(DELETE_SQL, tv("data", data, "cascade", cascade, "conn", conn));
    }

    /// `delete(...)` of `BaseTableView`: returns the error message, or null when dropped.
    string baseDelete(Value res)
    {
        auto sql = getDeleteSql(res["rows"][0]);
        auto x = conn.executeScalar(sql);
        if (!x.ok)
            return x.error;
        return null;
    }

    /// `get_table_locks(did, data)`: a response describing the lock, or null.
    Response getTableLocks(Value did, Value data)
    {
        auto r = conn.executeDict(tt("locks.sql", tv("did", did)));
        foreach (row; r.value["rows"].list.items)
        {
            if (row["relation"].truthy && pyStripChars(row["relation"].toString, "\"") == data["name"].toString)
            {
                auto a = conn.executeDict(tt("get_application_name.sql", tv("pid", row["pid"])));
                auto applicationName = a.value["rows"][0]["application_name"].toString;
                return makeJsonResponse(2, Value(""), Value(gettext("The table is currently locked and the operation cannot be "
                        ~ "completed. Please try again later. \r\nBlocking Process ID : {0} Application Name : {1}")
                        .replace("{0}", row["pid"].toString).replace("{1}", applicationName)));
            }
        }
        return null;
    }

    void getSchemaAndTableName(Value tid, out string schemaName, out string tableName)
    {
        auto s = conn.executeScalar(tt(GET_SCHEMA_OID_SQL, tv("tid", tid, "conn", conn)));
        if (!s.ok)
            throw new ExecuteError(s.error);
        if (s.value.isNone)
            return;
        auto n = conn.executeScalar(tt("get_schema.sql", tv("conn", conn, "scid", s.value)));
        if (!n.ok)
            throw new ExecuteError(n.error);
        auto t = conn.executeScalar(tt("get_table.sql", tv("conn", conn, "scid", s.value, "tid", tid)));
        if (!t.ok)
            throw new ExecuteError(t.error);
        schemaName = n.value.toString;
        tableName = t.value.isNone ? null : t.value.toString;
    }

    void updateVacuumSettings(string vacuumKey, Value oldData, Value data = Value(null))
    {
        if (data.isNone)
        {
            if (oldData.contains(vacuumKey))
                foreach (opt; oldData[vacuumKey].iterItems())
                {
                    if (!oldData.contains("add_vacuum_settings_in_sql"))
                        oldData["add_vacuum_settings_in_sql"] = Value(false);
                    if (opt.contains("value") && (opt["value"].isNone || opt["value"] == Value("")))
                        opt.dict.pop("value");
                    if (opt.contains("value") && oldData.contains("add_vacuum_settings_in_sql")
                            && !oldData["add_vacuum_settings_in_sql"].truthy)
                        oldData["add_vacuum_settings_in_sql"] = Value(true);
                }
        }
        else if (data.contains(vacuumKey) && data[vacuumKey].contains("changed") && oldData.contains(vacuumKey))
        {
            Value[] setValues, resetValues;
            foreach (dataRow; data[vacuumKey]["changed"].iterItems())
                foreach (oldRow; oldData[vacuumKey].iterItems())
                    if (dataRow["name"] == oldRow["name"] && dataRow.contains("value"))
                    {
                        if (!dataRow["value"].isNone && dataRow["value"] != Value(""))
                            setValues ~= dataRow;
                        else if (oldRow.contains("value"))
                            resetValues ~= dataRow;
                    }
            if (setValues.length)
                data[vacuumKey]["set_values"] = Value(setValues);
            if (resetValues.length)
                data[vacuumKey]["reset_values"] = Value(resetValues);
        }
    }

    void updateAutovacuumProperties(Value res)
    {
        if (res.isNone)
            return;
        res["autovacuum_enabled"] = res["autovacuum_enabled"].isNone ? Value("x")
            : Value(res["autovacuum_enabled"].truthy ? "t" : "f");
        res["toast_autovacuum_enabled"] = res["toast_autovacuum_enabled"].isNone ? Value("x")
            : Value(res["toast_autovacuum_enabled"].truthy ? "t" : "f");
        bool any(string[] keys)
        {
            foreach (k; keys)
                if (res[k].truthy)
                    return true;
            return false;
        }

        auto en = res["autovacuum_enabled"].toString;
        res["autovacuum_custom"] = Value(any(["autovacuum_vacuum_threshold", "autovacuum_vacuum_scale_factor",
                "autovacuum_analyze_threshold", "autovacuum_analyze_scale_factor", "autovacuum_vacuum_cost_delay",
                "autovacuum_vacuum_cost_limit", "autovacuum_freeze_min_age", "autovacuum_freeze_max_age",
                "autovacuum_freeze_table_age"]) || en == "t" || en == "f");
        auto ten = res["toast_autovacuum_enabled"].toString;
        res["toast_autovacuum"] = Value(any(["toast_autovacuum_vacuum_threshold", "toast_autovacuum_vacuum_scale_factor",
                "toast_autovacuum_analyze_threshold", "toast_autovacuum_analyze_scale_factor",
                "toast_autovacuum_vacuum_cost_delay", "toast_autovacuum_vacuum_cost_limit", "toast_autovacuum_freeze_min_age",
                "toast_autovacuum_freeze_max_age", "toast_autovacuum_freeze_table_age"]) || ten == "t" || ten == "f");
    }

    Value getAccessMethods()
    {
        auto r = conn.execute2darray(tt("get_access_methods.sql"));
        if (!r.ok)
            throw new HTTPException(internalServerError(r.error));
        Value[] res;
        foreach (row; r.value["rows"].list.items)
            res ~= Value.dictOf("label", row["amname"], "value", row["amname"]);
        return Value(res);
    }
}
