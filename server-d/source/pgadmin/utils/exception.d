/// Exceptions that turn into JSON responses (`pgadmin/utils/exception.py`).
module pgadmin.utils.exception;

import std.conv : to;
import pgadmin.core.value;
import pgadmin.web.http;

class ConnectionLost : HTTPException
{
    Value sid;
    string db;
    string connId;

    this(Value sid, string db, string connId)
    {
        this.sid = sid;
        this.db = db;
        this.connId = connId;
        auto data = Value.newDict();
        data["sid"] = sid;
        data["database"] = db is null ? Value(null) : Value(db);
        data["conn_id"] = connId is null ? Value(null) : Value(connId);
        super(serviceUnavailable("Connection to the server has been lost.", "CONNECTION_LOST", Value(null), data));
        msg = "Connection (id #" ~ (connId is null ? "None" : connId) ~ ") lost for the server (#" ~ sid.toString
            ~ ") on database (" ~ (db is null ? "None" : db) ~ ")";
    }
}

class SSHTunnelConnectionLost : HTTPException
{
    this(string tunnelHost)
    {
        auto data = Value.newDict();
        data["tunnel_host"] = tunnelHost;
        super(serviceUnavailable("Connection to the SSH Tunnel for host '" ~ tunnelHost
                ~ "' has been lost. Reconnect to the database server.", "SSH_TUNNEL_CONNECTION_LOST", Value(null), data));
    }
}

class CryptKeyMissing : HTTPException
{
    enum string message = "Crypt key is missing.";

    this()
    {
        super(serviceUnavailable(message, "CRYPTKEY_MISSING"));
        msg = message;
    }
}

class ObjectGone : HTTPException
{
    string errorMsg;

    this(string errorMsg)
    {
        this.errorMsg = errorMsg;
        super(gone(errorMsg));
        msg = errorMsg;
    }
}

class ExecuteError : HTTPException
{
    string errorMsg;

    this(string errorMsg)
    {
        this.errorMsg = errorMsg;
        super(internalServerError(errorMsg));
        msg = errorMsg;
    }
}
