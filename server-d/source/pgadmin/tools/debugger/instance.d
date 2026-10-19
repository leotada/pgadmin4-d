/// `tools/debugger/instance`: Debugger session instance.
module pgadmin.tools.debugger.instance;

import core.sync.mutex : Mutex;
import std.conv : to;
import std.random : uniform;
import pgadmin.core.value;
import pgadmin.web.context : session;

private __gshared Mutex debuggerStoreLock;
private __gshared DebuggerInstance[string][string] debuggerStore;

shared static this()
{
    debuggerStoreLock = new Mutex();
}

final class DebuggerInstance
{
    private string _transId;
    Value functionData;
    Value debuggerData;

    this(string transId = null)
    {
        if (transId.length == 0)
            _transId = to!string(uniform(1, 9999999));
        else
            _transId = transId;
        functionData = Value(null);
        debuggerData = Value(null);
        loadFromSession();
    }

    this(long transId)
    {
        this(to!string(transId));
    }

    @property string transId() const { return _transId; }

    static string[] getTransIds()
    {
        synchronized (debuggerStoreLock)
        {
            auto sid = session().sid;
            if (auto p = sid in debuggerStore)
                return (*p).keys;
            return [];
        }
    }

    void loadFromSession()
    {
        synchronized (debuggerStoreLock)
        {
            auto sid = session().sid;
            if (auto p = sid in debuggerStore)
            {
                if (auto inst = _transId in *p)
                {
                    this.functionData = (*inst).functionData;
                    this.debuggerData = (*inst).debuggerData;
                }
            }
        }
    }

    void updateSession()
    {
        synchronized (debuggerStoreLock)
        {
            auto sid = session().sid;
            if (sid !in debuggerStore)
                debuggerStore[sid] = null;
            debuggerStore[sid][_transId] = this;
        }
    }

    void clear()
    {
        synchronized (debuggerStoreLock)
        {
            auto sid = session().sid;
            if (auto p = sid in debuggerStore)
            {
                (*p).remove(_transId);
            }
        }
    }
}
