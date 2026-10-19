/// Server heartbeat bookkeeping (`pgadmin/utils/heartbeat.py`): connections of tabs that stop pinging are released.
module pgadmin.utils.heartbeat;

import std.conv : to;
import std.datetime : Clock;
import pgadmin.core.config;
import pgadmin.core.i18n;
import pgadmin.core.log;
import pgadmin.core.value;
import pgadmin.db.driver;
import pgadmin.web.context;

private struct Beat
{
    long timestamp;
    ServerManager manager;
}

private __gshared Beat[string][string] heartbeats; // session -> sid -> beat

struct HeartbeatResult
{
    bool ok;
    string msg;
}

HeartbeatResult logServerHeartbeat(Value data)
{
    auto sid = data["sid"].integer;
    auto manager = getDriver().connectionManager(sid);
    auto ssid = session().sid;
    if (manager is null)
    {
        stopServerHeartbeat(data);
        logError("Manager not found. Stopped Heartbeat logging for the session id: " ~ ssid ~ " and server id: "
                ~ to!string(sid));
        return HeartbeatResult(false, gettext("Manager not found. Stopped Heartbeat logging."));
    }
    heartbeats[ssid][data["sid"].toString] = Beat(Clock.currTime.toUnixTime, manager);
    logDebug("Heartbeat logged for the session id: " ~ ssid ~ " and server id: " ~ to!string(sid));
    return HeartbeatResult(true, gettext("Heartbeat logged successfully."));
}

HeartbeatResult stopServerHeartbeat(Value data)
{
    auto ssid = session().sid;
    if (auto per = ssid in heartbeats)
        (*per).remove(data["sid"].toString);
    return HeartbeatResult(true, gettext("Stopped Heartbeat logging."));
}

/// The heartbeat of a server for this session (as the JSON the Python module returns).
Value getServerHeartbeat(long sid)
{
    auto ssid = session().sid;
    if (auto per = ssid in heartbeats)
        if (auto b = to!string(sid) in *per)
        {
            auto d = new Dict;
            d["timestamp"] = Value(b.timestamp);
            return Value(d);
        }
    return Value(null);
}

/// Releases the connections of servers whose tabs have not sent a heartbeat for 4 x SERVER_HEARTBEAT_TIMEOUT.
void releaseStaleHeartbeats()
{
    auto limit = cfgInt("SERVER_HEARTBEAT_TIMEOUT") * 4;
    auto now = Clock.currTime.toUnixTime;
    foreach (ssid; heartbeats.keys)
    {
        auto per = heartbeats[ssid];
        foreach (sid; per.keys)
        {
            if (now - per[sid].timestamp > limit)
            {
                foreach (k, c; per[sid].manager.connections)
                {
                    try
                    {
                        if (c.wasConnected)
                        {
                            c.release();
                            c.wasConnected = true;
                            logDebug("Heartbeat not received. Released connection for the session id##server id: "
                                    ~ ssid ~ "##" ~ sid);
                        }
                    }
                    catch (Exception e)
                        logException(e);
                }
                heartbeats[ssid].remove(sid);
                if (heartbeats[ssid].length == 0)
                    heartbeats.remove(ssid);
            }
        }
    }
}
