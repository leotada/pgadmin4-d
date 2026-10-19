/// `pgadmin/tools/schema_diff/model`: Schema Diff session and model tracking.
module pgadmin.tools.schema_diff.model;

import core.sync.mutex : Mutex;
import std.conv : to;
import pgadmin.core.value;

final class SchemaDiffModel
{
    private Value[string] _comparisonResult;

    void clearData()
    {
        _comparisonResult.clear();
    }

    void setResult(string nodeName, Value compareResult)
    {
        _comparisonResult[nodeName] = compareResult;
    }

    Value getResult(string nodeName = null)
    {
        if (nodeName.length)
        {
            if (auto p = nodeName in _comparisonResult)
                return *p;
            return Value(null);
        }
        return Value(_comparisonResult);
    }
}

final class SchemaDiffSession
{
    long transId;
    SchemaDiffModel diffModel;
    Dict data;

    this(long transId)
    {
        this.transId = transId;
        this.diffModel = new SchemaDiffModel();
        this.data = new Dict;
    }
}

private __gshared Mutex storeLock;
private __gshared SchemaDiffSession[long][string] schemaDiffStore;

shared static this()
{
    storeLock = new Mutex();
}

void initSchemaDiffSession(string sid, long transId)
{
    synchronized (storeLock)
    {
        if (sid !in schemaDiffStore)
            schemaDiffStore[sid] = null;
        schemaDiffStore[sid][transId] = new SchemaDiffSession(transId);
    }
}

SchemaDiffSession getSchemaDiffSession(string sid, long transId)
{
    synchronized (storeLock)
    {
        if (auto p = sid in schemaDiffStore)
            if (auto s = transId in *p)
                return *s;
        return null;
    }
}

void closeSchemaDiffSession(string sid, long transId)
{
    synchronized (storeLock)
    {
        if (auto p = sid in schemaDiffStore)
        {
            (*p).remove(transId);
            if ((*p).length == 0)
                schemaDiffStore.remove(sid);
        }
    }
}

unittest
{
    auto model = new SchemaDiffModel();
    model.setResult("table", Value.dictOf("count", 5));
    assert(model.getResult("table")["count"].integer == 5);
    model.clearData();
    assert(model.getResult("table").isNone);

    initSchemaDiffSession("session-1", 100);
    auto sess = getSchemaDiffSession("session-1", 100);
    assert(sess !is null);
    assert(sess.transId == 100);

    closeSchemaDiffSession("session-1", 100);
    assert(getSchemaDiffSession("session-1", 100) is null);
}
