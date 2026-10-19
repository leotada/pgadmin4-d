/// Helpers shared by the nodes below a schema (`schemas/utils.py`): the module base class, the data type reader,
/// trigger/rule parsing and vacuum settings.
module pgadmin.browser.server_groups.servers.databases.schemas.utils;

import std.algorithm : canFind, endsWith, startsWith;
import std.array : join, replace;
import std.conv : to;
import std.regex : regex, matchFirst, matchAll, replaceAll;
import std.string : indexOf, strip, stripRight;
import pgadmin.browser.utils;
import pgadmin.core.i18n;
import pgadmin.core.log;
import pgadmin.core.templates;
import pgadmin.core.value;
import pgadmin.db.driver;
import pgadmin.utils.constants;
import pgadmin.web.http;

/// `SchemaChildModule`: a node module that lives below a schema or a catalog.
abstract class SchemaChildModule : CollectionNodeModule
{
    bool catalogDbSupported = true;
    string[] supportedSchemas; /// empty = any

    this(string nodeTypeName)
    {
        super(nodeTypeName);
    }

    override bool backendSupported(ServerManager manager, Dict kwargs)
    {
        bool isCatalog = kwargs["is_catalog"].truthy;
        bool a;
        if (isCatalog)
        {
            // evaluated lazily like the Python expression (a catalog lookup always passes db_support)
            bool dbSupport = kwargs["db_support"].truthy;
            a = (catalogDbSupported && dbSupport) || (!catalogDbSupported && !dbSupport
                    && (supportedSchemas.length == 0 || supportedSchemas.canFind(kwargs["schema_name"].toString)));
        }
        else
            a = catalogDbSupported;
        return a && super.backendSupported(manager, kwargs);
    }
}

// ------------------------------------------------------------ DataTypeReader

/// Reads the data types of a database for the column/type dialogs (`DataTypeReader`).
struct DataTypeReader
{
    /// `get_types(conn, condition, add_serials, schema_oid)` -> list of type descriptors.
    static Res getTypes(Connection conn, string condition, bool addSerials = false, Value schemaOid = Value(""))
    {
        Value[] res;
        try
        {
            auto path = "datatype/sql/#" ~ to!string(conn.manager.version_) ~ "#";
            auto sql = renderTemplate(path ~ "/get_types.sql", tv("condition", condition, "add_serials", addSerials,
                    "schema_oid", schemaOid));
            auto r = conn.execute2darray(sql);
            if (!r.ok)
                return r;
            string typeval; // not reset per row in the Python code: rows without an element oid reuse the previous value
            foreach (row; r.value["rows"].list.items)
            {
                bool precision, length;
                if (row["elemoid"].truthy)
                    getLengthPrecision(row["elemoid"], row["typname"].toString, length, precision, typeval);
                long minVal, maxVal;
                typesLengthChecks(length, typeval, precision, minVal, maxVal);
                res ~= Value.dictOf("label", row["typname"], "value", row["typname"], "typval", typeval, "precision",
                        precision, "length", length, "min_val", minVal, "max_val", maxVal, "is_collatable",
                        row["is_collatable"], "oid", row["oid"]);
            }
        }
        catch (Exception e)
            return Res(false, Value(e.msg));
        return Res(true, Value(res));
    }

    static void typesLengthChecks(bool length, string typeval, bool precision, out long minVal, out long maxVal)
    {
        minVal = 0;
        maxVal = 0;
        if (length)
        {
            minVal = typeval == "D" ? 0 : 1;
            if (precision)
                maxVal = 1000;
            else if (minVal)
                maxVal = 2_147_483_647;
            else
                maxVal = typeval == "D" ? 6 : 10;
        }
    }

    static Res getGeometryTypes(Connection conn)
    {
        import pgadmin.utils.extensions : checkExtensionExists;
        auto ex = checkExtensionExists(conn, "postgis");
        if (!ex.ok)
            return ex;
        Value[] types;
        if (ex.value.truthy)
        {
            auto r = conn.execute2darray("SELECT postgis_typmod_type(i) FROM\n            generate_series(4, 63) AS i;");
            if (!r.ok)
                return r;
            foreach (row; r.value["rows"].list.items)
                types ~= Value.dictOf("label", row["postgis_typmod_type"], "value", row["postgis_typmod_type"]);
        }
        return Res(true, Value(types));
    }

    /// `get_length_precision(elemoid_or_name, typname)`
    static void getLengthPrecision(Value elemoidOrName, string typname, out bool length, out bool precision,
            out string typeval)
    {
        length = false;
        precision = false;
        typeval = "";
        if (!elemoidOrName.truthy)
            return;
        auto en = elemoidOrName;
        static bool inList(Value v, long[] oids, string[] names)
        {
            if (v.isInt)
                return oids.canFind(v.integer);
            if (v.isString)
                return names.canFind(v.str);
            return false;
        }

        if (isDataTypeWithLength(en) || (typname !is null && typname.length && DATA_TYPE_WITH_LENGTH_NAMES.canFind(typname)))
            typeval = "L";
        else if (inList(en, [1083, 1114, 1115, 1183, 1184, 1185, 1186, 1187, 1266, 1270], [
                "time", DATATYPE_TIME_WITHOUT_TIMEZONE, "timestamp", DATATYPE_TIMESTAMP_WITHOUT_TIMEZONE, "timestamp[]",
                "timestamp without time zone[]", "time[]", "time without time zone[]", "timestamptz",
                DATATYPE_TIMESTAMP_WITH_TIMEZONE, "timestamptz[]", "timestamp with time zone[]", "interval",
                "interval[]", "timetz", DATATYPE_TIME_WITH_TIMEZONE, "time with time zone[]"]))
            typeval = "D";
        else if (inList(en, [1231, 1700], ["numeric[]", "numeric"]))
            typeval = "P";
        else
            typeval = " ";
        if (typeval == "P")
            precision = true;
        if (precision || typeval == "L" || typeval == "D")
            length = true;
    }

    static string checkTypmod(long typmod, string name)
    {
        string length = "(";
        if (name == "numeric")
        {
            long len = (typmod - 4) >> 16;
            long prec = (typmod - 4) & 0xffff;
            length ~= to!string(len) ~ "," ~ to!string(prec);
        }
        else if (["time", "timetz", DATATYPE_TIME_WITHOUT_TIMEZONE, DATATYPE_TIME_WITH_TIMEZONE, "timestamp", "timestamptz",
                DATATYPE_TIMESTAMP_WITHOUT_TIMEZONE, DATATYPE_TIMESTAMP_WITH_TIMEZONE, "bit", "bit varying", "varbit",
                "vector", "halfvec", "sparsevec"].canFind(name))
            length ~= to!string(typmod);
        else if (name == "interval")
        {
            long len = typmod & 0xffff;
            length ~= len > 6 ? "" : to!string(len);
        }
        else if (name == "date")
            length = "";
        else
            length ~= to!string(typmod - 4);
        if (length.length > 0)
            length ~= ")";
        return length;
    }

    static string getFullTypeValue(string name, string schema, string length, string array)
    {
        if (name == "char" && schema == "pg_catalog")
            return "\"char\"" ~ array;
        if (name == DATATYPE_TIME_WITH_TIMEZONE)
            return "time" ~ length ~ " with time zone" ~ array;
        if (name == DATATYPE_TIME_WITHOUT_TIMEZONE)
            return "time" ~ length ~ " without time zone" ~ array;
        if (name == DATATYPE_TIMESTAMP_WITH_TIMEZONE)
            return "timestamp" ~ length ~ " with time zone" ~ array;
        if (name == DATATYPE_TIMESTAMP_WITHOUT_TIMEZONE)
            return "timestamp" ~ length ~ " without time zone" ~ array;
        return name ~ length ~ array;
    }

    /// Python indexes a single character here (`typname[len(schema) + 3]`), which is a pgAdmin quirk we keep.
    static string checkSchemaInName(string typname, string schema)
    {
        if (typname.indexOf(schema ~ "\".") >= 0)
        {
            auto i = schema.length + 3;
            return i < typname.length ? typname[i .. i + 1] : "";
        }
        if (typname.indexOf(schema ~ ".") >= 0)
        {
            auto i = schema.length + 1;
            return i < typname.length ? typname[i .. i + 1] : "";
        }
        return typname;
    }

    /// `get_full_type(nsp, typname, is_dup, numdims, typmod)`
    static string getFullType(Value nsp, string typname, Value isDup, long numdims, long typmod)
    {
        string schema = nsp.isNone ? "" : nsp.toString;
        string array;
        auto name = checkSchemaInName(typname, schema);
        if (name.startsWith("_"))
        {
            if (!numdims)
                numdims = 1;
            name = name[1 .. $];
        }
        if (name.endsWith("[]"))
        {
            if (!numdims)
                numdims = 1;
            name = name[0 .. $ - 2];
        }
        if (name.startsWith("\"") && name.endsWith("\""))
            name = name[1 .. $ - 1];
        while (numdims > 0)
        {
            array ~= "[]";
            numdims--;
        }
        string length;
        if (typmod != -1)
            length = checkTypmod(typmod, name);
        return getFullTypeValue(name, schema, length, array);
    }

    static string parseTypeName(string typeName)
    {
        bool isArray;
        if (typeName.endsWith("[]"))
        {
            isArray = true;
            typeName = typeName.stripRight("[]");
        }
        auto idx = typeName.indexOf('(');
        if (idx != 0 && typeName.endsWith(")"))
            typeName = typeName[0 .. idx];
        else if (idx != 0 && typeName.startsWith("time"))
            typeName = replaceAll(typeName, regex(`(\(\d+\))`), "");
        else if (typeName.startsWith("interval"))
            typeName = "interval";
        if (isArray)
            typeName ~= "[]";
        return typeName;
    }

    static void parseLengthPrecision(string fulltype, bool isTlength, bool isPrecision, out Value tLen, out Value tPrec)
    {
        tLen = Value(null);
        tPrec = Value(null);
        if (isTlength && isPrecision)
        {
            auto m = matchFirst(fulltype, regex(`(\d+),(\d+)`));
            if (!m.empty)
            {
                tLen = Value(m[1].idup);
                tPrec = Value(m[2].idup);
            }
        }
        else if (isTlength)
        {
            auto m = matchFirst(fulltype, regex(`(\d+)`));
            if (!m.empty)
                tLen = Value(m[1].idup);
        }
    }
}

// ------------------------------------------------------------ trigger / rule parsing

/// `trigger_definition(data)`: decodes `tgtype` into the flags the dialog uses.
Value triggerDefinition(Value data)
{
    auto tgtype = data["tgtype"].integer;
    data["fires"] = Value((tgtype & (1 << 1)) ? "BEFORE" : (tgtype & (1 << 6)) ? "INSTEAD OF" : "AFTER");
    data["is_row_trigger"] = Value((tgtype & (1 << 0)) != 0);
    data["evnt_insert"] = Value((tgtype & (1 << 2)) != 0);
    data["evnt_delete"] = Value((tgtype & (1 << 3)) != 0);
    data["evnt_update"] = Value((tgtype & (1 << 4)) != 0);
    data["evnt_truncate"] = Value((tgtype & (1 << 5)) != 0);
    return data;
}

/// `parse_rule_definition(res)`: splits a rule definition into condition, statement and event.
Value parseRuleDefinition(Value res)
{
    try
    {
        auto resData = res["rows"][0];
        auto dataDef = resData["definition"].toString;
        string condition;
        auto cp = matchFirst(dataDef, regex(`(ON\s+[\s\S]+?TO\s+[\s\S]+?DO)`));
        if (!cp.empty)
        {
            auto cm = matchFirst(cp[1], regex(`WHERE\s+(\([\s\S]*\))\s+DO`));
            if (!cm.empty)
            {
                condition = cm[1].idup;
                if (condition.startsWith("(") && condition.endsWith(")"))
                    condition = condition[1 .. $ - 1];
            }
        }
        string statement;
        auto sm = matchFirst(dataDef, regex(`DO\s+(?:INSTEAD\s+)?([\s\S]*);`));
        if (!sm.empty)
        {
            statement = sm[1].idup;
            if (statement.startsWith("(") && statement.endsWith(")"))
                statement = statement[1 .. $ - 1];
        }
        immutable string[string] events = ["1": "SELECT", "2": "UPDATE", "3": "INSERT", "4": "DELETE"];
        resData["event"] = Value(events[resData["ev_type"].toString]);
        resData["do_instead"] = resData["is_instead"];
        resData["statements"] = Value(statement);
        resData["condition"] = Value(condition);
        return resData;
    }
    catch (Exception e)
        return Value(internalServerError(e.msg));
}

// ------------------------------------------------------------ vacuum settings

private __gshared Value[string][long] vacuumCache; // sid -> type -> rows

/// `VacuumSettings.fetch_default_vacuum_settings(conn, sid, setting_type)`
Value fetchDefaultVacuumSettings(Connection conn, long sid, string settingType)
{
    if (auto p = sid in vacuumCache)
        if (auto q = settingType in *p)
            return *q;
    auto vacuumFields = parseJson(renderTemplate("vacuum_settings/vacuum_fields.json"));
    string[] keys;
    foreach (k; vacuumFields[settingType].dict.keys)
        keys ~= k;
    auto columns = "'" ~ keys.join("','") ~ "'";
    auto sql = renderTemplate("vacuum_settings/sql/vacuum_defaults.sql", tv("columns", columns));
    auto r = conn.executeDict(sql);
    if (!r.ok)
        throw new Exception(r.error);
    foreach (row; r.value["rows"].list.items)
    {
        auto rowName = row["name"].toString;
        auto f = vacuumFields[settingType][rowName];
        row["name"] = f[0];
        row["label"] = f[1];
        row["column_type"] = f[2];
    }
    vacuumCache[sid][settingType] = r.value["rows"];
    return r.value["rows"];
}

/// `parse_vacuum_data(conn, result, type)`
Value parseVacuumData(Connection conn, Value result, string type)
{
    auto tmp = fetchDefaultVacuumSettings(conn, conn.manager.sid.integer, type).deepCopy();
    foreach (row; tmp.list.items)
    {
        auto rowName = row["name"].toString;
        if (type == "toast")
            rowName = "toast_" ~ rowName;
        if (result.contains(rowName) && !result[rowName].isNone)
        {
            auto value = result[rowName].floating;
            import std.math : fmod;
            row["value"] = fmod(value, 1.0) == 0 ? Value(cast(long) value) : Value(value);
        }
        else
            row.dict.pop("value");
    }
    return tmp;
}

// ------------------------------------------------------------ misc

/// `get_schema(sid, did, scid)`
Res getSchema(Value sid, Value did, Value scid)
{
    auto manager = getDriver().connectionManager(sid.integer);
    auto conn = manager.connection(null, null, true, did);
    auto sql = renderTemplate("schemas/" ~ manager.serverType ~ "/#" ~ to!string(manager.version_) ~ "#/sql/get_name.sql",
            tv("conn", conn, "scid", scid));
    return conn.executeScalar(sql);
}

/// `get_schemas(conn, show_system_objects)`
Res getSchemas(Connection conn, bool showSystemObjects = false)
{
    auto sql = renderTemplate("schemas/" ~ conn.manager.serverType ~ "/#" ~ to!string(conn.manager.version_)
            ~ "#/sql/nodes.sql", tv("show_sysobj", showSystemObjects, "schema_restrictions", Value(null)));
    return conn.execute2darray(sql);
}

/// `check_pgstattuple(conn, oid)`
Res checkPgstattuple(Connection conn, Value oid)
{
    auto r = conn.executeScalar("\n        SELECT CASE WHEN (SELECT(count(extname) > 0) AS is_pgstattuple\n            FROM pg_catalog.pg_extension WHERE extname = 'pgstattuple')\n        THEN (SELECT pg_catalog.has_table_privilege(current_user, " ~ oid.toString ~ ",\n            'SELECT')) ELSE FALSE END");
    return r;
}
