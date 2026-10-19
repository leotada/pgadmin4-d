/// Socket.IO v4 / Engine.IO v4 protocol support over WebSocket and HTTP polling.
module pgadmin.web.socketio;

import core.sync.mutex : Mutex;
import core.time : seconds;
import std.algorithm : canFind;
import std.array : appender, split;
import std.conv : to;
import std.format : format;
import std.random : unpredictableSeed, Random, uniform;
import std.string : indexOf;
import std.uuid : randomUUID;

import andaime.http.types : Method;
import andaime.http.websocket : WsConn, WsMessage;
import andaime.web.application : App, ws, get, post;
import andaime.web.context : Context;
import andaime.web.websocket : WebSocket;

import pgadmin.core.log;
import pgadmin.core.value;

alias SocketIoHandler = void delegate(SocketIoClient client, Value data);

struct SocketIoPacket
{
    char engineType;  /// '0'=open, '1'=close, '2'=ping, '3'=pong, '4'=message
    char socketType;  /// '0'=connect, '1'=disconnect, '2'=event, '3'=ack, '4'=error
    string nsp = "/";
    long ackId = -1;
    string eventName;
    Value payload;
}

bool parseSocketIoPacket(string s, out SocketIoPacket pkt)
{
    if (s.length == 0)
        return false;

    pkt.engineType = s[0];
    if (pkt.engineType != '4')
        return true;

    if (s.length < 2)
        return true;

    pkt.socketType = s[1];
    size_t idx = 2;

    // Parse optional ack id
    string ackStr;
    while (idx < s.length && s[idx] >= '0' && s[idx] <= '9')
        ackStr ~= s[idx++];
    if (ackStr.length)
        pkt.ackId = to!long(ackStr);

    // Parse optional namespace (starts with / until ,)
    if (idx < s.length && s[idx] == '/')
    {
        auto comma = s[idx .. $].indexOf(',');
        if (comma != -1)
        {
            pkt.nsp = s[idx .. idx + comma];
            idx += comma + 1;
        }
    }

    if (idx < s.length)
    {
        string jsonPart = s[idx .. $];
        try
        {
            auto val = parseJson(jsonPart);
            if (pkt.socketType == '2' && val.isList && val.list.items.length > 0)
            {
                pkt.eventName = val.list.items[0].toString;
                if (val.list.items.length > 1)
                    pkt.payload = val.list.items[1];
                else
                    pkt.payload = Value(null);
            }
            else
            {
                pkt.payload = val;
            }
        }
        catch (Exception)
        {
            pkt.payload = Value(jsonPart);
        }
    }
    return true;
}

string formatSocketIoEvent(string nsp, string eventName, Value data)
{
    string prefix;
    if (nsp == "/" || nsp.length == 0)
        prefix = "42";
    else
        prefix = "42" ~ nsp ~ ",";

    auto arr = Value.newList();
    arr.list.items ~= Value(eventName);
    if (!data.isNone)
        arr.list.items ~= data;
    else
        arr.list.items ~= Value.newDict();

    return prefix ~ arr.toJson;
}

final class SocketIoClient
{
    string sid;
    WsConn ws;
    bool[string] namespaces;
    private SocketIoServer server;

    this(string sid, WsConn ws, SocketIoServer server)
    {
        this.sid = sid;
        this.ws = ws;
        this.server = server;
    }

    void emit(string nsp, string eventName, Value data = Value(null))
    {
        if (ws !is null && ws.isOpen)
        {
            auto payload = formatSocketIoEvent(nsp, eventName, data);
            try
            {
                ws.send(payload);
            }
            catch (Exception e)
            {
                logError("SocketIoClient.emit error: " ~ e.msg);
            }
        }
    }

    void emit(string eventName, Value data = Value(null))
    {
        emit("/", eventName, data);
    }

    void disconnect(string nsp = null)
    {
        if (nsp.length && nsp != "/")
        {
            if (ws !is null && ws.isOpen)
            {
                try
                {
                    ws.send("41" ~ nsp ~ ",");
                }
                catch (Exception) {}
            }
            namespaces.remove(nsp);
        }
        else if (ws !is null && ws.isOpen)
        {
            try
            {
                ws.close(1000, "Normal closure");
            }
            catch (Exception) {}
        }
    }
}

final class SocketIoServer
{
    private SocketIoHandler[][string][string] handlers; // handlers[nsp][event]
    private SocketIoClient[string] clients;
    private Mutex lock;

    this()
    {
        lock = new Mutex();
    }

    void on(string nsp, string event, SocketIoHandler handler)
    {
        synchronized (lock)
        {
            if (nsp !in handlers)
                handlers[nsp] = null;
            handlers[nsp][event] ~= handler;
        }
    }

    void emit(string nsp, string event, Value data, string toSid = null)
    {
        SocketIoClient[] targetClients;
        synchronized (lock)
        {
            if (toSid.length)
            {
                if (auto c = toSid in clients)
                    targetClients ~= *c;
            }
            else
            {
                foreach (c; clients.values)
                {
                    if (nsp in c.namespaces)
                        targetClients ~= c;
                }
            }
        }

        foreach (c; targetClients)
            c.emit(nsp, event, data);
    }

    void handleWsConnection(scope WsConn ws)
    {
        auto sid = randomUUID().toString();
        auto client = new SocketIoClient(sid, ws, this);

        synchronized (lock)
        {
            clients[sid] = client;
        }

        scope (exit)
        {
            synchronized (lock)
            {
                clients.remove(sid);
            }
            // Trigger disconnect for all joined namespaces
            foreach (nsp; client.namespaces.keys)
            {
                dispatch(client, nsp, "disconnect", Value(null));
            }
        }

        // Send Engine.IO open handshake
        auto handshakeJson = format(
            `0{"sid":"%s","upgrades":[],"pingInterval":25000,"pingTimeout":120000,"maxPayload":1000000}`,
            sid
        );
        ws.send(handshakeJson);

        foreach (msg; ws)
        {
            if (!msg.isText)
                continue;

            SocketIoPacket pkt;
            if (!parseSocketIoPacket(msg.text, pkt))
                continue;

            if (pkt.engineType == '2') // ping
            {
                ws.send("3"); // pong
                continue;
            }

            if (pkt.engineType == '4') // Socket.IO message
            {
                if (pkt.socketType == '0') // connect to namespace
                {
                    client.namespaces[pkt.nsp] = true;
                    // Respond with connect ack
                    string resp;
                    if (pkt.nsp == "/" || pkt.nsp.length == 0)
                        resp = format(`40{"sid":"%s"}`, sid);
                    else
                        resp = format(`40%s,{"sid":"%s"}`, pkt.nsp, sid);
                    ws.send(resp);

                    // Trigger connect event handler for this namespace
                    dispatch(client, pkt.nsp, "connect", pkt.payload);
                }
                else if (pkt.socketType == '1') // disconnect from namespace
                {
                    client.namespaces.remove(pkt.nsp);
                    dispatch(client, pkt.nsp, "disconnect", Value(null));
                }
                else if (pkt.socketType == '2') // custom event
                {
                    dispatch(client, pkt.nsp, pkt.eventName, pkt.payload);
                }
            }
        }
    }

    private void dispatch(SocketIoClient client, string nsp, string event, Value data)
    {
        SocketIoHandler[] toRun;
        synchronized (lock)
        {
            if (auto pNsp = nsp in handlers)
                if (auto pEvt = event in *pNsp)
                    toRun = (*pEvt).dup;
        }
        foreach (h; toRun)
        {
            try
            {
                h(client, data);
            }
            catch (Exception e)
            {
                logError(format("Error in Socket.IO handler [%s:%s]: %s", nsp, event, e.msg));
            }
        }
    }
}

private __gshared SocketIoServer _instance;

SocketIoServer getSocketIo()
{
    if (_instance is null)
        _instance = new SocketIoServer();
    return _instance;
}

WebSocket handleSocketIoWs()
{
    return WebSocket((scope WsConn ws) {
        getSocketIo().handleWsConnection(ws);
    });
}

WebSocket handleSocketIoWsRest(string rest)
{
    return handleSocketIoWs();
}

void handleSocketIoGet(Context ctx)
{
    auto openMsg = format(
        `0{"sid":"%s","upgrades":["websocket"],"pingInterval":25000,"pingTimeout":120000,"maxPayload":1000000}`,
        randomUUID().toString()
    );
    ctx.response.status = 200;
    ctx.response.setHeader("Content-Type", "text/plain; charset=UTF-8");
    ctx.response.body.put(openMsg);
}

void handleSocketIoGetRest(Context ctx, string rest)
{
    handleSocketIoGet(ctx);
}

void handleSocketIoPost(Context ctx)
{
    ctx.response.status = 200;
    ctx.response.setHeader("Content-Type", "text/plain; charset=UTF-8");
    ctx.response.body.put("ok");
}

void handleSocketIoPostRest(Context ctx, string rest)
{
    handleSocketIoPost(ctx);
}

/// Registers Socket.IO WebSocket endpoints and polling fallback on the Andaime App.
void installSocketIo(App app)
{
    app.ws!("/socket.io", handleSocketIoWs);
    app.ws!("/socket.io/{*rest}", handleSocketIoWsRest);
    app.get!("/socket.io", handleSocketIoGet);
    app.get!("/socket.io/{*rest}", handleSocketIoGetRest);
    app.post!("/socket.io", handleSocketIoPost);
    app.post!("/socket.io/{*rest}", handleSocketIoPostRest);
}

unittest
{
    SocketIoPacket pkt;
    assert(parseSocketIoPacket("2", pkt));
    assert(pkt.engineType == '2');

    assert(parseSocketIoPacket("40/pty,", pkt));
    assert(pkt.engineType == '4');
    assert(pkt.socketType == '0');
    assert(pkt.nsp == "/pty");

    assert(parseSocketIoPacket("42/pty,[\"start_process\",{\"sid\":1}]", pkt));
    assert(pkt.engineType == '4');
    assert(pkt.socketType == '2');
    assert(pkt.nsp == "/pty");
    assert(pkt.eventName == "start_process");
    assert(pkt.payload.isDict && pkt.payload["sid"].integer == 1);

    auto evt = formatSocketIoEvent("/pty", "pty-output", Value.dictOf("result", "ok"));
    assert(evt.canFind("pty-output") && evt.canFind("/pty,"));
}
