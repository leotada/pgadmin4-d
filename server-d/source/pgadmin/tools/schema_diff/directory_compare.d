/// `pgadmin/tools/schema_diff/directory_compare`: Dictionary and property comparison for schema diff.
module pgadmin.tools.schema_diff.directory_compare;

import std.algorithm : canFind, filter;
import std.array : array;
import std.conv : to;
import std.string : strip;
import std.uni : isWhite;
import pgadmin.core.i18n;
import pgadmin.core.value;

private string stripAllWhite(string s)
{
    return s.filter!(c => !isWhite(c)).array.to!string;
}

bool areStringsIdentical(string s1, string s2, bool ignoreWhitespaces)
{
    if (ignoreWhitespaces)
        return stripAllWhite(s1) == stripAllWhite(s2);
    return s1 == s2;
}

bool areValuesIdentical(Value v1, Value v2, string[] ignoreKeys, bool ignoreWhitespaces)
{
    if (v1.isNone && v2.isNone)
        return true;
    if (v1.isNone || v2.isNone)
        return false;

    if (v1.isDict && v2.isDict)
        return areDictionariesIdentical(v1, v2, ignoreKeys, ignoreWhitespaces);

    if (v1.isList && v2.isList)
        return areListsIdentical(v1.list.items, v2.list.items, ignoreKeys, ignoreWhitespaces);

    if (v1.isString && v2.isString)
        return areStringsIdentical(v1.toString, v2.toString, ignoreWhitespaces);

    return v1 == v2;
}

bool areDictionariesIdentical(Value dict1, Value dict2, string[] ignoreKeys, bool ignoreWhitespaces)
{
    if (!dict1.isDict || !dict2.isDict)
        return false;

    auto d1 = dict1.dict;
    auto d2 = dict2.dict;

    foreach (k, v1; d1)
    {
        if (ignoreKeys.canFind(k))
            continue;
        if (!d2.has(k))
            return false;
        if (!areValuesIdentical(v1, d2[k], ignoreKeys, ignoreWhitespaces))
            return false;
    }

    foreach (k, v2; d2)
    {
        if (ignoreKeys.canFind(k))
            continue;
        if (!d1.has(k))
            return false;
    }

    return true;
}

bool areListsIdentical(Value[] l1, Value[] l2, string[] ignoreKeys, bool ignoreWhitespaces)
{
    if (l1.length != l2.length)
        return false;
    foreach (i; 0 .. l1.length)
    {
        if (!areValuesIdentical(l1[i], l2[i], ignoreKeys, ignoreWhitespaces))
            return false;
    }
    return true;
}

/// Compares two sets of objects (by name -> properties dict) and returns the list of diff rows.
Value[] compareDictionaries(
    Value[string] sourceDict,
    Value[string] targetDict,
    string node,
    string nodeLabel,
    string groupName,
    string targetSchema,
    string sourceSchemaName,
    string[] ignoreKeys,
    bool ignoreOwner,
    bool ignoreWhitespaces,
    bool ignoreTablespace,
    bool ignoreGrants,
    ref long count
)
{
    if (ignoreOwner)
    {
        ignoreKeys ~= ["owner", "eventowner", "funcowner", "fdwowner",
                       "fsrvowner", "lanowner", "relowner", "seqowner", "typeowner"];
    }
    if (ignoreTablespace)
    {
        ignoreKeys ~= ["spcname", "spcoid"];
    }
    if (ignoreGrants)
    {
        ignoreKeys ~= ["relacl", "acl", "datacl", "fdwacl", "lanacl", "fsrvacl"];
    }

    Value[] sourceOnly;
    Value[] targetOnly;
    Value[] different;
    Value[] identical;

    // Source only
    foreach (item, srcVal; sourceDict)
    {
        if (item !in targetDict)
        {
            Value srcOid = Value(null);
            if (srcVal.isDict && srcVal.contains("oid"))
                srcOid = srcVal["oid"];

            auto row = Value.newDict();
            row["id"] = Value(count++);
            row["type"] = Value(node);
            row["label"] = Value(nodeLabel);
            row["title"] = Value(item);
            row["oid"] = srcOid;
            row["status"] = Value(gettext("Source Only"));
            row["source_ddl"] = Value("");
            row["target_ddl"] = Value("");
            row["diff_ddl"] = Value("");
            row["group_name"] = Value(groupName);
            row["dependencies"] = Value.newList();
            row["source_schema_name"] = Value(sourceSchemaName);
            sourceOnly ~= row;
        }
    }

    // Target only
    foreach (item, tgtVal; targetDict)
    {
        if (item !in sourceDict)
        {
            Value tgtOid = Value(null);
            if (tgtVal.isDict && tgtVal.contains("oid"))
                tgtOid = tgtVal["oid"];

            auto row = Value.newDict();
            row["id"] = Value(count++);
            row["type"] = Value(node);
            row["label"] = Value(nodeLabel);
            row["title"] = Value(item);
            row["oid"] = tgtOid;
            row["status"] = Value(gettext("Target Only"));
            row["source_ddl"] = Value("");
            row["target_ddl"] = Value("");
            row["diff_ddl"] = Value("");
            row["group_name"] = Value(groupName);
            row["dependencies"] = Value.newList();
            row["source_schema_name"] = Value(sourceSchemaName);
            targetOnly ~= row;
        }
    }

    // Both
    foreach (item, srcVal; sourceDict)
    {
        if (auto p = item in targetDict)
        {
            auto tgtVal = *p;
            Value srcOid = Value(null);
            if (srcVal.isDict && srcVal.contains("oid"))
                srcOid = srcVal["oid"];

            bool isIdentical = areDictionariesIdentical(srcVal, tgtVal, ignoreKeys, ignoreWhitespaces);
            auto row = Value.newDict();
            row["id"] = Value(count++);
            row["type"] = Value(node);
            row["label"] = Value(nodeLabel);
            row["title"] = Value(item);
            row["oid"] = srcOid;
            row["group_name"] = Value(groupName);
            row["dependencies"] = Value.newList();
            row["source_schema_name"] = Value(sourceSchemaName);
            row["source_ddl"] = Value("");
            row["target_ddl"] = Value("");
            row["diff_ddl"] = Value("");

            if (isIdentical)
            {
                row["status"] = Value(gettext("Identical"));
                identical ~= row;
            }
            else
            {
                row["status"] = Value(gettext("Different"));
                different ~= row;
            }
        }
    }

    return sourceOnly ~ targetOnly ~ different ~ identical;
}

unittest
{
    // String comparison tests
    assert(areStringsIdentical("SELECT 1;", "SELECT 1;", false));
    assert(!areStringsIdentical("SELECT   1;", "SELECT 1;", false));
    assert(areStringsIdentical("SELECT   1;\n", "SELECT 1;", true));

    // Dictionary comparison tests
    auto d1 = Value.newDict();
    d1["name"] = Value("tbl1");
    d1["oid"] = Value(12345);
    d1["owner"] = Value("postgres");

    auto d2 = Value.newDict();
    d2["name"] = Value("tbl1");
    d2["oid"] = Value(54321);
    d2["owner"] = Value("app_user");

    string[] ignore = ["oid"];
    assert(!areDictionariesIdentical(d1, d2, ignore, false)); // owner differs

    ignore ~= ["owner"];
    assert(areDictionariesIdentical(d1, d2, ignore, false)); // oid and owner ignored

    // CompareDictionaries test
    Value[string] src;
    src["t1"] = d1;
    src["t2"] = Value.dictOf("name", "t2");

    Value[string] tgt;
    tgt["t1"] = d2;
    tgt["t3"] = Value.dictOf("name", "t3");

    long count = 1;
    auto diff = compareDictionaries(src, tgt, "table", "Table", "public", "public", "public", ["oid", "owner"], false, false, false, false, count);
    assert(diff.length == 3); // 1 source only (t2), 1 target only (t3), 1 identical (t1)
}
