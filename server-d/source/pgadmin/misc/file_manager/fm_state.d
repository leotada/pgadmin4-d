/// The file manager's per-session transaction store (`session['fileManagerData']`).
module pgadmin.misc.file_manager.fm_state;

import pgadmin.core.value;
import pgadmin.web.context : session;

private __gshared Value[string][string] store;

void fmStore(string transId, Value configs)
{
    auto sid = session().sid;
    if (sid !in store)
        store[sid] = null;
    store[sid][transId] = configs;
}

/// The stored configuration or None.
Value fmGet(string transId)
{
    if (auto s = session().sid in store)
        if (auto t = transId in *s)
            return *t;
    return Value(null);
}

void fmRelease(string transId)
{
    if (auto s = session().sid in store)
        (*s).remove(transId);
}
