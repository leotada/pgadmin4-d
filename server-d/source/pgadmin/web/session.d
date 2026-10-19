/// Server-side sessions (`pgadmin/utils/session.py`).
///
/// Same browser contract: cookie `pga4_session = <sid>!<hmac>`, where the HMAC-SHA256 is computed over
/// `sid:randval` with SECRET_KEY. On disk each session is `hex(HMAC(ciphertext)) + AES-256-CBC(JSON)`; the key is
/// derived from SECRET_KEY with HKDF-SHA256 (same salt/info as the Python version). The body is JSON instead of a
/// pickle, so session files are not interchangeable with the Python version (users log in again after switching).
module pgadmin.web.session;

import std.algorithm : startsWith;
import std.base64 : Base64;
import std.datetime : Clock;
import std.file : exists, mkdirRecurse, read, write, remove, dirEntries, SpanMode, timeLastModified, setAttributes;
import std.path : buildPath;
import std.string : representation;
import core.sync.mutex : Mutex;
import pgadmin.core.config;
import pgadmin.core.crypto;
import pgadmin.core.log;
import pgadmin.core.value;

/// `ManagedSession`: a dict with change tracking.
final class Session
{
    string sid;
    string randval;
    string hmacDigest;
    Dict data;
    bool modified;
    bool isNew;
    bool forceWrite;
    long lastWrite;

    this(string sid, Dict data = null)
    {
        this.sid = sid;
        this.data = data is null ? new Dict : data;
    }

    bool has(string k) => data.has(k);
    Value get(string k, Value def = Value(null)) => data.get(k, def);

    Value opIndex(string k) => data[k];

    void opIndexAssign(Value v, string k)
    {
        data[k] = v;
        modified = true;
    }

    void opIndexAssign(T)(T v, string k) if (!is(T == Value))
    {
        opIndexAssign(Value(v), k);
    }

    Value pop(string k, Value def = Value(null))
    {
        if (data.has(k))
            modified = true;
        return data.pop(k, def);
    }

    void clear()
    {
        data.clear();
        modified = true;
    }

    /// Marks the session as changed (nested values mutated in place, like Flask's `session.modified = True`).
    void touch()
    {
        modified = true;
    }

    bool empty() => data.length == 0;

    void sign(string secret)
    {
        if (hmacDigest.length == 0)
        {
            randval = randomString(20, "abcdefghijklmnopqrstuvwxyz0123456789");
            hmacDigest = Base64.encode(hmac(Digest.sha256, secret, sid ~ ":" ~ randval)).idup;
        }
    }
}

private __gshared Mutex lock;
shared static this()
{
    lock = new Mutex;
}

/// Validates a session id coming from a cookie: it names a file, so only uuid characters are allowed.
private bool safeSid(string sid)
{
    if (sid.length == 0 || sid.length > 64)
        return false;
    foreach (c; sid)
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || c == '-'))
            return false;
    return true;
}

final class SessionManager
{
    string path;
    string secret;
    long diskWriteDelay;
    string[] skipPaths;
    private Session[string] cache;
    private string[] cacheOrder;
    private enum maxCache = 1000;
    private ubyte[] fernetKey;

    this(string path, string secret, long diskWriteDelay, string[] skipPaths)
    {
        if (secret.length == 0)
            throw new Exception("SECRET_KEY must be non-empty");
        this.path = path;
        this.secret = secret;
        this.diskWriteDelay = diskWriteDelay;
        this.skipPaths = skipPaths;
        if (!path.exists)
            mkdirRecurse(path);
        fernetKey = hkdfSha256(secret.representation, "pga-session-body-v1".representation,
                "pgadmin session body encryption v1".representation, 32);
    }

    private bool skipped(string requestPath)
    {
        foreach (s; skipPaths)
            if (requestPath.startsWith(s))
                return true;
        return false;
    }

    private string file(string sid) => buildPath(path, sid);

    Session newSession(string requestPath)
    {
        string sid = uuid4();
        while (file(sid).exists)
            sid = uuid4();
        auto s = new Session(sid);
        s.isNew = true;
        if (!skipped(requestPath))
        {
            synchronized (lock)
                remember(s);
        }
        return s;
    }

    private void remember(Session s)
    {
        if (s.sid !in cache)
            cacheOrder ~= s.sid;
        cache[s.sid] = s;
        if (cache.length > maxCache)
        {
            while (cache.length > maxCache * 8 / 10 && cacheOrder.length)
            {
                cache.remove(cacheOrder[0]);
                cacheOrder = cacheOrder[1 .. $];
            }
        }
    }

    bool exists_(string sid)
    {
        if (!safeSid(sid))
            return false;
        synchronized (lock)
            if (sid in cache)
                return true;
        return file(sid).exists;
    }

    void remove_(string sid)
    {
        if (!safeSid(sid))
            return;
        synchronized (lock)
        {
            cache.remove(sid);
            foreach (i, x; cacheOrder)
                if (x == sid)
                {
                    cacheOrder = cacheOrder[0 .. i] ~ cacheOrder[i + 1 .. $];
                    break;
                }
        }
        if (file(sid).exists)
            remove(file(sid));
    }

    Session get(string sid, string digest, string requestPath)
    {
        synchronized (lock)
        {
            if (auto p = sid in cache)
            {
                if ((*p).hmacDigest == digest && !(*p).empty)
                    return *p;
                if ((*p).hmacDigest != digest && (*p).hmacDigest.length)
                    return newSession2(requestPath);
            }
        }
        auto s = load(sid, digest);
        if (s is null)
            return newSession2(requestPath);
        if (!skipped(requestPath))
            synchronized (lock)
                remember(s);
        return s;
    }

    private Session newSession2(string requestPath) => newSession(requestPath);

    private Session load(string sid, string digest)
    {
        if (!safeSid(sid))
            return null;
        auto fname = file(sid);
        if (!fname.exists)
            return null;
        try
        {
            auto raw = cast(ubyte[]) read(fname);
            enum hdr = 64; // hex SHA-256
            if (raw.length <= hdr)
                return null;
            auto header = raw[0 .. hdr];
            auto body_ = raw[hdr .. $];
            auto expected = hexOf(hmac(Digest.sha256, secret.representation, body_));
            if (!constantTimeEquals(header, expected.representation))
            {
                logWarning("session file rejected: bad file-HMAC for sid=" ~ sid[0 .. 8]);
                return null;
            }
            auto plain = cast(string) aesCbcDecrypt(fernetKey, body_).idup;
            auto doc = parseJson(plain);
            auto data = doc["data"];
            if (!data.isDict || data.dict.length == 0)
                return null;
            if (doc["digest"].toString != digest)
                return null;
            auto s = new Session(sid, data.dict);
            s.randval = doc["randval"].toString;
            s.hmacDigest = doc["digest"].toString;
            return s;
        }
        catch (Exception e)
        {
            logWarning("session file for " ~ sid ~ " unreadable: " ~ e.msg);
            return null;
        }
    }

    void put(Session s, string requestPath)
    {
        immutable now = Clock.currTime.toUnixTime;
        if (s.hmacDigest.length == 0)
            s.sign(secret);
        else if (!s.forceWrite && s.lastWrite != 0 && now - s.lastWrite < diskWriteDelay)
            return;
        s.lastWrite = now;
        s.forceWrite = false;
        if (skipped(requestPath))
            return;
        auto doc = Value.newDict();
        doc["randval"] = s.randval;
        doc["digest"] = s.hmacDigest;
        doc["data"] = Value(s.data);
        auto body_ = aesCbcEncrypt(fernetKey, doc.toJson.representation);
        auto header = hexOf(hmac(Digest.sha256, secret.representation, body_));
        auto fname = file(s.sid);
        write(fname, header.representation ~ body_);
        version (Posix)
        {
            import std.conv : octal;
            try
                setAttributes(fname, octal!600);
            catch (Exception)
            {
            }
        }
        synchronized (lock)
            remember(s);
    }

    /// Deletes session files older than the session lifetime plus a day.
    void cleanup(long lifetimeSeconds)
    {
        auto limit = Clock.currTime.toUnixTime - lifetimeSeconds - 86_400;
        foreach (e; dirEntries(path, SpanMode.shallow))
        {
            try
            {
                if (e.isFile && e.timeLastModified.toUnixTime < limit)
                    remove(e.name);
            }
            catch (Exception)
            {
            }
        }
    }
}

private string hexOf(const(ubyte)[] b)
{
    static immutable digits = "0123456789abcdef";
    char[] r = new char[b.length * 2];
    foreach (i, x; b)
    {
        r[2 * i] = digits[x >> 4];
        r[2 * i + 1] = digits[x & 15];
    }
    return cast(string) r.idup;
}
