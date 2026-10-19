/// `schemas/types`: composite, enum, range, base, shell types (and the EPAS ones).
module pgadmin.browser.server_groups.servers.databases.schemas.types;

import std.regex : regex, matchFirst;
import pgadmin.browser.common;
import pgadmin.browser.server_groups.servers.databases.schemas.utils;

final class TypeModule : SchemaChildModule
{
    enum NODE_TYPE = "type";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "Types";
        minVer = Value(null);
        maxVer = Value(null);
        staticDir("browser/server_groups/servers/databases/schemas/types");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => "database";
    override bool nodeInode() => false;

    override Value[] getNodes(Dict kwargs)
    {
        if (hasNodes(kwargs["sid"], kwargs["did"], kwargs["scid"], Value(null), Value(null), TypeView.BASE_TEMPLATE_PATH))
            return [generateBrowserCollectionNode(kwargs["scid"])];
        return null;
    }

    override void setup()
    {
        registerNodeView!TypeView(this);
    }
}

/// What `TypeView.get_sql` yields: the SQL (or a bare "-- definition incomplete" string), the name and whether the
/// type has a dependent type, or an error response.
private struct TypeSql
{
    string sql;
    string name;
    bool hasDependent;
    Response err;
    bool bare; /// the Python code returns a plain string instead of a tuple
}

final class TypeView : PGChildNodeView
{
    enum BASE_TEMPLATE_PATH = "types/{0}/sql/#{1}#";
    string[] acl = ["U"];
    private bool hasSqrBracket;

    this()
    {
        super();
        nodeType = TypeModule.NODE_TYPE;
        nodeLabel = "Type";
        parentIds = [IdSpec("int", "gid"), IdSpec("int", "sid"), IdSpec("int", "did"), IdSpec("int", "scid")];
        ids = [IdSpec("int", "tid")];
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
            makeOp("get_types", ["get": "get_types"], ["get": "get_types"]),
            makeOp("get_stypes", ["get": "get_subtypes"], ["get": "get_subtypes"]),
            makeOp("get_subopclass", ["get": "get_subtype_opclass"], ["get": "get_subtype_opclass"]),
            makeOp("get_stypediff", ["get": "get_subtype_diff"], ["get": "get_subtype_diff"]),
            makeOp("get_canonical", ["get": "get_canonical"], ["get": "get_canonical"]),
            makeOp("get_collations", ["get": "get_collations"], ["get": "get_collations"]),
            makeOp("get_external_functions", ["get": "get_external_functions_list"], ["get": "get_external_functions_list"]),
        ]);
    }

    private static bool hasDependentType(Value data)
        => data.contains("rngmultirangetype") && !data["rngmultirangetype"].isNone && data["rngmultirangetype"] != Value("");

    private Dict nodeExtra(Value row, bool withDescription)
    {
        auto d = new Dict;
        if (withDescription)
            d["description"] = row["description"];
        d["has_dependent"] = Value(hasDependentType(row));
        return d;
    }

    override Response callMethod(string name, Dict k)
    {
        if (!isAuthenticated())
            return unauthorisedResponse();
        if (name == "children")
            return children(k);
        auto err = standardPrecondition(k, name, BASE_TEMPLATE_PATH);
        if (err !is null)
            return err;
        auto gid = k.has("gid") ? k["gid"] : Value(null);
        auto sid = k["sid"];
        auto scid = k["scid"];
        auto tid = k.has("tid") ? k["tid"] : Value(null);
        auto showSys = Value(bpModule.showSystemObjectsFlag);
        switch (name)
        {
        case "list":
        {
            auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("scid", scid, "datlastsysoid", DATABASE_LAST_SYSTEM_OID_,
                    "show_system_objects", showSys)));
            if (!r.ok)
                return internalServerError(r.error);
            return makeResponse(r.value["rows"], 200);
        }
        case "node":
        {
            auto r = conn.execute2darray(rt(NODES_SQL, tv("scid", scid, "tid", tid, "show_system_objects", showSys)));
            if (!r.ok)
                return internalServerError(r.error);
            if (r.value["rows"].length == 0)
                return gone(gettext("Could not find the type in the database."));
            auto row = r.value["rows"][0];
            return makeJsonResponse(1, Value(""), Value(""), Value(null),
                    gbn(row["oid"], scid, row["name"].toString, "icon-" ~ nodeType, nodeExtra(row, false)), 200);
        }
        case "nodes":
        {
            auto r = conn.execute2darray(rt(NODES_SQL, tv("scid", scid, "show_system_objects", showSys)));
            if (!r.ok)
                return internalServerError(r.error);
            Value[] res;
            foreach (row; r.value["rows"].list.items)
                res ~= gbn(row["oid"], scid, row["name"].toString, "icon-" ~ nodeType, nodeExtra(row, true));
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        case "properties":
        {
            Response e2;
            auto res = fetchProperties(scid, tid, e2);
            if (e2 !is null)
                return e2;
            return makeResponse(res, 200);
        }
        case "get_collations": return getCollations();
        case "get_types": return getTypes();
        case "get_subtypes": return getSubtypes();
        case "get_subtype_opclass": return getSubtypeOpclass();
        case "get_subtype_diff": return getSubtypeDiff();
        case "get_canonical": return getCanonical();
        case "get_external_functions_list": return getExternalFunctionsList();
        case "create": return create(scid);
        case "update": return update(gid, sid, scid, tid);
        case "delete": return delete_(scid, tid);
        case "msql": return msql(gid, sid, scid, tid);
        case "sql": return sqlView(gid, sid, scid, tid);
        case "dependents": return makeResponse(getDependents(conn, tid), 200);
        case "dependencies":
        {
            auto t = tid.toString;
            auto typeWhere = "WHERE (dep.objid=" ~ t ~ "::oid OR dep.objid=(select typrelid from pg_catalog.pg_type where oid = "
                ~ t ~ "::oid))";
            return makeResponse(getDependencies(conn, tid, typeWhere), 200);
        }
        default: return super.callMethod(name, k);
        }
    }

    // ---------------------------------------------------------------- properties

    private string cltypeFormatter(string inType)
    {
        if (inType.canFind("[]"))
        {
            inType = inType.replace("[]", "");
            hasSqrBracket = true;
        }
        else
            hasSqrBracket = false;
        return inType;
    }

    private static Value convertLengthPrecisionToString(Value data)
    {
        foreach (key; ["tlength", "precision"])
            if (data.contains(key) && !data[key].isNone)
                data[key] = Value(data[key].toString);
        return data;
    }

    private Dict additionalPropertiesComposite(Value rows)
    {
        auto res = new Dict;
        string[] propertiesList;
        Value[] compositeLst;
        foreach (row; rows.list.items)
        {
            auto typelist = row["attname"].toString ~ " " ~ row["fulltype"].toString;
            string fullCollate, collate;
            if (!row["collname"].truthy || (row["collname"] == Value("default") && row["collnspname"] == Value("pg_catalog")))
            {
            }
            else
            {
                fullCollate = qtIdentStr(row["collnspname"].toString, row["collname"].toString);
                collate = " COLLATE " ~ fullCollate;
            }
            typelist ~= collate;
            propertiesList ~= typelist;
            bool isTlength, isPrecision;
            string typeval;
            DataTypeReader.getLengthPrecision(row.dict.get("elemoid", Value(null)), row.dict.get("typname", Value(null)).isNone
                    ? "" : row["typname"].toString, isTlength, isPrecision, typeval);
            Value tLen, tPrec;
            DataTypeReader.parseLengthPrecision(row["fulltype"].toString, isTlength, isPrecision, tLen, tPrec);
            auto typeName = DataTypeReader.parseTypeName(row["typname"].toString);
            row["type"] = Value(cltypeFormatter(typeName));
            row["hasSqrBracket"] = Value(hasSqrBracket);
            row = convertLengthPrecisionToString(row);
            compositeLst ~= Value.dictOf("attnum", row["attnum"], "member_name", row["attname"], "type", typeName,
                    "collation", fullCollate, "cltype", row["type"], "tlength", tLen, "precision", tPrec,
                    "is_tlength", isTlength, "is_precision", isPrecision, "hasSqrBracket", row["hasSqrBracket"],
                    "fulltype", row["fulltype"]);
        }
        res["member_list"] = Value(propertiesList.join(", "));
        res["composite"] = Value(compositeLst);
        return res;
    }

    /// EPAS `N`/`V` types. The Python code assigns some of these with a trailing comma, which makes them 1-tuples
    /// (JSON arrays); kept as is because the dialogs read those values.
    private Value additionalPropertiesAdvancedServerType(Value data)
    {
        bool isTlength, isPrecision;
        string typeval;
        DataTypeReader.getLengthPrecision(data.dict.get("elemoid", Value(null)),
                data.dict.get("typname", Value(null)).isNone ? "" : data["typname"].toString, isTlength, isPrecision, typeval);
        Value tLen, tPrec;
        DataTypeReader.parseLengthPrecision(data["fulltype"].toString, isTlength, isPrecision, tLen, tPrec);
        data = convertLengthPrecisionToString(data);
        data["type"] = Value(cltypeFormatter(data["type"].toString));
        data["cltype"] = Value(cltypeFormatter(data["type"].toString));
        data["hasSqrBracket"] = Value(hasSqrBracket);
        data["tlength"] = Value([tLen]);
        data["precision"] = tPrec;
        data["is_tlength"] = Value([Value(isTlength)]);
        data["is_precision"] = Value([Value(isPrecision)]);
        data["maxsize"] = data["typndims"];
        return data;
    }

    private Dict additionalProperties(Value copyDict, Value tid)
    {
        auto ofType = copyDict["typtype"].toString;
        auto res = new Dict;
        auto renderArgs = tv("typtype", ofType);
        if (ofType == "c")
            renderArgs["typrelid"] = copyDict["typrelid"];
        else
            renderArgs["tid"] = tid;
        Value rset;
        if (["c", "e", "r", "N", "V", "A"].canFind(ofType))
        {
            auto r = conn.executeDict(rt("additional_properties.sql", renderArgs));
            if (!r.ok)
                throw new Exception(r.error);
            rset = r.value;
        }
        if (ofType == "c")
            res = additionalPropertiesComposite(rset["rows"]);
        if (ofType == "N" || ofType == "V")
            res = additionalPropertiesAdvancedServerType(rset["rows"][0]).dict;
        if (ofType == "e")
        {
            string[] propertiesList;
            Value[] enumList;
            foreach (row; rset["rows"].list.items)
            {
                propertiesList ~= row["enumlabel"].toString;
                enumList ~= Value.dictOf("label", row["enumlabel"], "old_label", row["enumlabel"]);
            }
            res["enum_list"] = Value(propertiesList.join(", "));
            res["enum"] = Value(enumList);
        }
        if (ofType == "r")
            res.update(rset["rows"][0].dict.copy());
        if (copyDict.contains("seclabels") && !copyDict["seclabels"].isNone)
        {
            Value[] secLabels;
            foreach (sec; copyDict["seclabels"].iterItems())
            {
                auto m = matchFirst(sec.toString, regex(`([^=]+)=(.*$)`));
                secLabels ~= Value.dictOf("provider", m[1].idup, "label", m[2].idup);
            }
            res["seclabels"] = Value(secLabels);
        }
        return res;
    }

    Value fetchProperties(Value scid, Value tid, out Response err)
    {
        auto showSys = Value(bpModule.showSystemObjectsFlag);
        auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("scid", scid, "tid", tid, "datlastsysoid", DATABASE_LAST_SYSTEM_OID_,
                "show_system_objects", showSys)));
        if (!r.ok)
        {
            err = internalServerError(r.error);
            return Value(null);
        }
        if (r.value["rows"].length == 0)
        {
            err = gone(gettext("Could not find the type in the database."));
            return Value(null);
        }
        auto copyDict = Value(r.value["rows"][0].dict.copy());
        auto a = conn.executeDict(rt(ACL_SQL, tv("scid", scid, "tid", tid)));
        if (!a.ok)
        {
            err = internalServerError(a.error);
            return Value(null);
        }
        copyDict["typacl"] = Value.newList();
        foreach (row; a.value["rows"].list.items)
        {
            auto priv = parsePrivFromDb(row);
            auto t = row["deftype"].toString;
            if (copyDict.contains(t))
                copyDict[t].append(priv);
            else
                copyDict[t] = Value([priv]);
        }
        try
            copyDict.dict.update(additionalProperties(copyDict, tid));
        catch (Exception e)
        {
            err = internalServerError(e.msg);
            return Value(null);
        }
        return copyDict;
    }

    // ---------------------------------------------------------------- pickers

    private Response getCollations()
    {
        Value[] res = [Value.dictOf("label", "", "value", "")];
        try
        {
            auto r = conn.execute2darray(rt("get_collations.sql"));
            if (!r.ok)
                return internalServerError(Value(res).toString);
            foreach (row; r.value["rows"].list.items)
                res ~= Value.dictOf("label", row["collation"], "value", row["collation"]);
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private static void setPrecisionAndLenVal(string typeval, out bool precision, out bool length, out int minVal, out int maxVal)
    {
        precision = false;
        length = false;
        minVal = 0;
        maxVal = 0;
        if (typeval == "P")
            precision = true;
        if (precision || typeval == "L" || typeval == "D")
        {
            length = true;
            minVal = typeval == "D" ? 0 : 1;
            if (precision)
                maxVal = 1000;
            else if (minVal)
                maxVal = 2147483647;
            else
                maxVal = 10;
        }
    }

    private Response getTypes()
    {
        Value[] res;
        try
        {
            auto r = conn.execute2darray(rt("get_types.sql"));
            if (!r.ok)
                return internalServerError("[]");
            string typeval;
            bool assigned;
            foreach (row; r.value["rows"].list.items)
            {
                if (row["elemoid"].truthy)
                {
                    assigned = true;
                    if (isDataTypeWithLength(row["elemoid"]) || DATA_TYPE_WITH_LENGTH_NAMES.canFind(row["typname"].toString))
                        typeval = "L";
                    else if ([1083, 1114, 1115, 1183, 1184, 1185, 1186, 1187, 1266, 1270].canFind(row["elemoid"].integer))
                        typeval = "D";
                    else if ([1231, 1700].canFind(row["elemoid"].integer))
                        typeval = "P";
                    else
                        typeval = " ";
                }
                if (!assigned)
                    throw new Exception("cannot access local variable 'typeval' where it is not associated with a value");
                bool precision, length;
                int minVal, maxVal;
                setPrecisionAndLenVal(typeval, precision, length, minVal, maxVal);
                res ~= Value.dictOf("label", row["typname"], "value", row["typname"], "typval", typeval,
                        "precision", precision, "length", length, "min_val", minVal, "max_val", maxVal,
                        "is_collatable", row["is_collatable"]);
            }
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response getSubtypes()
    {
        Value[] res = [Value.dictOf("label", "", "value", "")];
        try
        {
            auto r = conn.execute2darray(rt(GET_SUBTYPES_SQL, tv("subtype", true, "conn", conn)));
            if (!r.ok)
                return internalServerError(Value(res).toString);
            foreach (row; r.value["rows"].list.items)
                res ~= Value.dictOf("label", row["stype"], "value", row["stype"], "is_collate", row["is_collate"]);
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response getSubtypeOpclass()
    {
        Value[] res = [Value.dictOf("label", "", "value", "")];
        auto data = request().args.toDict;
        try
        {
            auto sql = rt(GET_SUBTYPES_SQL, tv("subtype_opclass", true, "data", data, "conn", conn));
            if (sql.length)
            {
                auto r = conn.execute2darray(sql);
                if (!r.ok)
                    return internalServerError(Value(res).toString);
                foreach (row; r.value["rows"].list.items)
                    res ~= Value.dictOf("label", row["opcname"], "value", row["opcname"]);
            }
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response getSubtypeDiff()
    {
        Value[] res = [Value.dictOf("label", "", "value", "")];
        auto data = request().args.toDict;
        try
        {
            auto sql = rt(GET_SUBTYPES_SQL, tv("get_opcintype", true, "data", data, "conn", conn));
            if (sql.length)
            {
                auto o = conn.executeScalar(sql);
                if (!o.ok)
                    return internalServerError(o.error);
                auto r = conn.execute2darray(rt(GET_SUBTYPES_SQL, tv("opcintype", o.value, "conn", conn)));
                if (!r.ok)
                    return internalServerError(Value(res).toString);
                foreach (row; r.value["rows"].list.items)
                    res ~= Value.dictOf("label", row["stypdiff"], "value", row["stypdiff"]);
            }
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response getCanonical()
    {
        Value[] res = [Value.dictOf("label", "", "value", "")];
        auto data = request().args.toDict;
        bool canonical = true;
        Value oid = Value(null);
        try
        {
            auto sql = rt(GET_SUBTYPES_SQL, tv("getoid", true, "data", data, "conn", conn));
            if (sql.length)
            {
                auto o = conn.executeScalar(sql);
                if (!o.ok)
                    return internalServerError(o.error);
                oid = o.value;
                if (oid.isNone)
                    canonical = false;
            }
            sql = rt(GET_SUBTYPES_SQL, tv("canonical", canonical, "conn", conn, "oid", oid));
            if (sql.length)
            {
                auto r = conn.execute2darray(sql);
                if (!r.ok)
                    return internalServerError(Value(res).toString);
                foreach (row; r.value["rows"].list.items)
                    res ~= Value.dictOf("label", row["canonical"], "value", row["canonical"]);
            }
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response getExternalFunctionsList()
    {
        Value[] res = [Value.dictOf("label", "", "value", "", "cbtype", "all")];
        try
        {
            void load(string flag, string cbtype)
            {
                auto sql = rt(GET_EXTERNAL_FUNCTIONS_SQL_, tv(flag, true));
                if (!sql.length)
                    return;
                auto r = conn.execute2darray(sql);
                if (!r.ok)
                    throw new Exception(Value(res).toString);
                foreach (row; r.value["rows"].list.items)
                    res ~= Value.dictOf("label", row["func"], "value", row["func"], "cbtype", cbtype);
            }
            load("extfunc", "all");
            load("typemodin", "typmodin");
            load("typemodout", "typmodout");
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private enum GET_EXTERNAL_FUNCTIONS_SQL_ = "get_external_functions.sql";

    // ---------------------------------------------------------------- create / update / delete

    private static Response checksForCreateType(Value data)
    {
        foreach (arg; ["name", "typtype"])
        {
            if (!data.contains(arg))
                return makeJsonResponse(0, Value(gettext("Could not find the required parameter ({}).").replace("{}", arg)),
                        Value(""), Value(null), Value(null), 410);
            if (data.truthy && data[arg] == Value("r") && (!data.contains("typname") || data["typname"].isNone))
                return makeJsonResponse(0, Value(gettext("Subtype must be defined for range types.")), Value(""), Value(null),
                        Value(null), 410);
            if (data.truthy && data[arg] == Value("b") && (!data.contains("typinput") || !data.contains("typoutput")
                    || data["typinput"].isNone || data["typoutput"].isNone))
                return makeJsonResponse(0, Value(gettext("External types require both input and output conversion functions.")),
                        Value(""), Value(null), Value(null), 410);
        }
        return null;
    }

    private Value convertForSql(Value data)
    {
        if (data.contains("typstorage") && !data["typstorage"].isNone)
        {
            switch (data["typstorage"].toString)
            {
            case "p": data["typstorage"] = Value("PLAIN"); break;
            case "e": data["typstorage"] = Value("EXTERNAL"); break;
            case "m": data["typstorage"] = Value("MAIN"); break;
            case "x": data["typstorage"] = Value("EXTENDED"); break;
            default: break;
            }
        }
        if (data.contains("typalign") && !data["typalign"].isNone)
        {
            switch (data["typalign"].toString)
            {
            case "c": data["typalign"] = Value("char"); break;
            case "s": data["typalign"] = Value("int2"); break;
            case "i": data["typalign"] = Value("int4"); break;
            case "d": data["typalign"] = Value("double"); break;
            default: break;
            }
        }
        return data;
    }

    private Response create(Value scidArg)
    {
        auto scid = scidArg;
        auto data = formOrJson(request());
        auto bad = checksForCreateType(data);
        if (bad !is null)
            return bad;
        if (data.contains("typacl") && !data["typacl"].isNone)
            data["typacl"] = parsePrivToDb(data["typacl"], acl);
        data = convertForSql(data);
        try
        {
            if (data.contains("composite") && data["composite"].length > 0)
                foreach (eachType; data["composite"].iterItems())
                {
                    convertLengthPrecisionToString(eachType);
                    eachType["cltype"] = Value(cltypeFormatter(eachType["type"].toString));
                    eachType["hasSqrBracket"] = Value(hasSqrBracket);
                }
            auto ofType = data.contains("typtype") ? data["typtype"] : Value(null);
            if (ofType == Value("N") || ofType == Value("V"))
            {
                data = convertLengthPrecisionToString(data);
                data["cltype"] = Value(cltypeFormatter(data["type"].toString));
                data["hasSqrBracket"] = Value(hasSqrBracket);
            }
            auto c = conn.executeDict(rt(CREATE_SQL, tv("data", data, "conn", conn)));
            if (!c.ok)
                return internalServerError(c.error);
            if (data.contains("schema"))
            {
                auto s = conn.executeScalar(rt("get_scid.sql", tv("schema", data["schema"], "conn", conn)));
                if (!s.ok)
                    return internalServerError(s.error);
                scid = s.value;
            }
            auto t = conn.executeScalar(rt(OID_SQL, tv("scid", scid, "data", data, "conn", conn)));
            if (!t.ok)
                return internalServerError(t.error);
            return jsonify(Value.dictOf("node", gbn(t.value, scid, data["name"].toString, "icon-type",
                    kwDict("has_dependent", hasDependentType(data)))));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response update(Value gid, Value sid, Value scid, Value tid)
    {
        auto data = formOrJson(request());
        try
        {
            auto g = getSql(gid, sid, data, scid, tid);
            if (g.err !is null)
                return g.err;
            auto sql = g.sql.strip("\n").strip(" ");
            auto r = conn.executeScalar(sql);
            if (!r.ok)
                return internalServerError(r.error);
            auto s = conn.executeScalar(rt("get_scid.sql", tv("tid", tid, "conn", conn)));
            if (!s.ok)
                return internalServerError(r.error);
            auto extra = new Dict;
            extra["has_dependent"] = Value(g.hasDependent);
            if (data.contains("description"))
                extra["description"] = data["description"];
            return jsonify(Value.dictOf("node", gbn(tid, s.value, g.name, "icon-" ~ nodeType, extra)));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    Response delete_(Value scid, Value tidArg, bool onlySql = false)
    {
        Value data = tidArg.isNone ? formOrJson(request()) : Value.dictOf("ids", Value([tidArg]));
        bool cascade = checkCascadeOperation();
        Value tid;
        try
        {
            foreach (id; data["ids"].iterItems())
            {
                tid = id;
                auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("scid", scid, "tid", tid, "datlastsysoid",
                        DATABASE_LAST_SYSTEM_OID_, "show_system_objects", bpModule.showSystemObjectsFlag)));
                if (!r.ok)
                    return internalServerError(r.error);
                if (r.value["rows"].length == 0)
                    return makeJsonResponse(0, Value(gettext("Error: Object not found.")),
                            Value(gettext("The specified type could not be found.\n")), Value(null), Value(null), 410);
                auto row = Value(r.value["rows"][0].dict.copy());
                auto sql = rt(DELETE_SQL, tv("data", row, "cascade", cascade, "conn", conn));
                if (onlySql)
                    return Response.sqlOnly(sql);
                auto x = conn.executeScalar(sql);
                if (!x.ok)
                    return internalServerError(x.error);
            }
            return makeJsonResponse(1, Value(""), Value(gettext("Type dropped")), Value(null),
                    Value.dictOf("id", tid, "scid", scid));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response msql(Value gid, Value sid, Value scid, Value tid)
    {
        auto data = Value.newDict();
        foreach (key; request().args.keys)
        {
            auto val = request().args.get(key);
            if (["composite", "enum", "seclabels", "typacl"].canFind(key))
                data[key] = parseJson(val);
            else if (["typreceive", "typsend", "typmodin", "typmodout", "typanalyze", "typsubscript", "typstorage"].canFind(key)
                    && val == "null")
                data[key] = parseJson(val);
            else
                data[key] = Value(val);
        }
        try
        {
            auto g = getSql(gid, sid, data, scid, tid);
            if (g.err !is null)
                return g.err;
            if (g.bare)
                throw new ViewReturnedNone; // Python: msql returns None
            auto sql = g.sql.strip("\n").strip(" ");
            if (sql == "")
                sql = "--modified SQL";
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(sql), 200);
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            throw e;
    }

    private TypeSql getNewSql(Value data, bool isSql)
    {
        TypeSql t;
        foreach (arg; ["name", "typtype"])
        {
            if (!data.contains(arg))
                return TypeSql("-- definition incomplete", null, false, null, true);
            auto v = data.dict.get(arg, Value(null));
            if (v == Value("r") && data.dict.get("typname", Value(null)).isNone)
                return TypeSql("-- definition incomplete", null, false, null, true);
            if (v == Value("b") && (data.dict.get("typinput", Value(null)).isNone || data.dict.get("typoutput", Value(null)).isNone))
                return TypeSql("-- definition incomplete", null, false, null, true);
        }
        if (data.dict.get("typacl", Value(null)).truthy)
            data["typacl"] = parsePrivToDb(data["typacl"], acl);
        data = convertForSql(data);
        if (data.dict.get("composite", Value.newList()).length > 0)
            foreach (eachType; data["composite"].iterItems())
            {
                convertLengthPrecisionToString(eachType);
                eachType["cltype"] = Value(cltypeFormatter(eachType["type"].toString));
                eachType["hasSqrBracket"] = Value(hasSqrBracket);
            }
        auto ofType = data.dict.get("typtype", Value(null));
        if (ofType == Value("N") || ofType == Value("V") || ofType == Value("A"))
        {
            data = convertLengthPrecisionToString(data);
            data["cltype"] = Value(cltypeFormatter(data["type"].toString));
            data["hasSqrBracket"] = Value(hasSqrBracket);
            if (ofType == Value("V"))
                data["typndims"] = data["maxsize"];
        }
        t.sql = rt(CREATE_SQL, tv("data", data, "conn", conn, "is_sql", isSql));
        t.name = data["name"].toString;
        return t;
    }

    private TypeSql getSql(Value gid, Value sid, Value data, Value scid, Value tid, bool isSql = false)
    {
        if (tid.isNone)
            return getNewSql(data, isSql);
        data = convertForSql(data);
        foreach (key; ["added", "changed", "deleted"])
        {
            if (data.contains("typacl") && data["typacl"].isDict && data["typacl"].contains(key))
                data["typacl"][key] = parsePrivToDb(data["typacl"][key], acl);
            if (data.contains("composite") && data["composite"].isDict && data["composite"].contains(key))
                foreach (eachType; data["composite"][key].iterItems())
                {
                    convertLengthPrecisionToString(eachType);
                    if (eachType.contains("type"))
                    {
                        eachType["cltype"] = Value(cltypeFormatter(eachType["type"].toString));
                        eachType["hasSqrBracket"] = Value(hasSqrBracket);
                    }
                }
            auto ofType = data.dict.get("typtype", Value(null));
            if (ofType == Value("N") || ofType == Value("V") || ofType == Value("A"))
            {
                data = convertLengthPrecisionToString(data);
                data["cltype"] = Value(cltypeFormatter(data["type"].toString));
                data["hasSqrBracket"] = Value(hasSqrBracket);
                if (ofType == Value("V"))
                    data["typndims"] = data["maxsize"];
            }
        }
        auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("scid", scid, "tid", tid, "datlastsysoid", DATABASE_LAST_SYSTEM_OID_,
                "show_system_objects", bpModule.showSystemObjectsFlag)));
        TypeSql t;
        if (!r.ok)
        {
            t.err = internalServerError(r.error);
            return t;
        }
        if (r.value["rows"].length == 0)
        {
            t.err = gone(gettext("Could not find the type in the database."));
            return t;
        }
        auto oldData = Value(r.value["rows"][0].dict.copy());
        auto a = conn.executeDict(rt(ACL_SQL, tv("scid", scid, "tid", tid)));
        if (!a.ok)
        {
            t.err = internalServerError(a.error);
            return t;
        }
        oldData["typacl"] = Value.newList();
        foreach (row; a.value["rows"].list.items)
        {
            parsePrivFromDb(row);
            // the Python code assigns the result of `list.append`, i.e. None
            oldData[row["deftype"].toString] = Value(null);
        }
        oldData.dict.update(additionalProperties(oldData, tid));
        oldData = convertForSql(oldData);
        string renderSql = UPDATE_SQL;
        foreach (key; ["typtype", "typname", "collname", "typinput", "typoutput"])
            if (data.contains(key))
                renderSql = "type_schema_diff.sql";
        t.sql = rt(renderSql, tv("data", data, "o_data", oldData, "conn", conn));
        t.name = data.contains("name") ? data["name"].toString : oldData["name"].toString;
        t.hasDependent = hasDependentType(oldData);
        return t;
    }

    private Response sqlView(Value gid, Value sid, Value scid, Value tid, string targetSchema = null, bool jsonResp = true)
    {
        auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("scid", scid, "tid", tid, "datlastsysoid", DATABASE_LAST_SYSTEM_OID_,
                "show_system_objects", bpModule.showSystemObjectsFlag)));
        if (!r.ok)
            return internalServerError(r.error);
        if (r.value["rows"].length == 0)
            return gone(gettext("Could not find the type in the database."));
        auto data = Value(r.value["rows"][0].dict.copy());
        if (targetSchema.length)
            data["schema"] = Value(targetSchema);
        auto a = conn.executeDict(rt(ACL_SQL, tv("scid", scid, "tid", tid)));
        if (!a.ok)
            return internalServerError(a.error);
        data["typacl"] = Value.newList();
        foreach (row; a.value["rows"].list.items)
        {
            auto priv = parsePrivFromDb(row);
            auto t = row["deftype"].toString;
            if (data.contains(t))
                data[t].append(priv);
            else
                data[t] = Value([priv]);
        }
        if (data.contains("typacl") && !data["typacl"].isNone)
            data["nspacl"] = parsePrivToDb(data["typacl"], acl);
        data.dict.update(additionalProperties(data, tid));
        foreach (k, v; data.dict)
            if (v == Value("-"))
                data[k] = Value(null);
        auto g = getSql(gid, sid, data, scid, Value(null), true);
        if (g.err !is null)
            return g.err;
        if (g.bare)
            return internalServerError("too many values to unpack (expected 3)");
        auto header = "-- Type: " ~ data["name"].toString ~ "\n\n-- ";
        header ~= rt(DELETE_SQL, tv("data", data, "conn", conn));
        auto sql = header ~ "\n\n" ~ g.sql;
        if (!jsonResp)
            return Response.sqlOnly(sql.strip("\n"));
        return makeResponse(Value(sql));
    }
}
