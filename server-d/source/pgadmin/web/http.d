/// Request and response objects with Flask/Werkzeug semantics, and the helpers of `pgadmin/utils/ajax.py`.
module pgadmin.web.http;

import std.algorithm : canFind, startsWith, endsWith;
import std.array : appender, split, join;
import std.conv : to;
import std.string : toLower, strip, indexOf, representation;
import std.uri : decodeComponent;
import pgadmin.core.value;

// ------------------------------------------------------------ MultiDict

/// Werkzeug's `MultiDict` (query string and form fields): every key may have several values.
final class MultiDict
{
    private string[] order;
    private string[][string] values_;

    void add(string k, string v)
    {
        if (k !in values_)
            order ~= k;
        values_[k] ~= v;
    }

    bool has(string k) const => (k in values_) !is null;
    size_t length() const => order.length;
    bool empty() const => order.length == 0;

    /// First value, or `def`.
    string get(string k, string def = null) const
    {
        if (auto p = k in values_)
            return (*p).length ? (*p)[0] : def;
        return def;
    }

    string[] getList(string k) const
    {
        if (auto p = k in values_)
            return (*p).dup;
        return null;
    }

    string[] keys() const => order.dup;

    /// `to_dict()`: first value of each key, as a Value dict.
    Value toDict() const
    {
        auto d = new Dict;
        foreach (k; order)
            d[k] = Value(values_[k][0]);
        return Value(d);
    }

    /// `to_dict(flat=False)`
    Value toDictLists() const
    {
        auto d = new Dict;
        foreach (k; order)
            d[k] = Value(values_[k].dup);
        return Value(d);
    }
}

/// Parses `a=1&b=2` (form-urlencoded: `+` is a space). Keys without `=` have an empty value.
MultiDict parseQueryString(const(char)[] q)
{
    auto md = new MultiDict;
    foreach (pair; q.split("&"))
    {
        if (pair.length == 0)
            continue;
        auto eq = pair.indexOf('=');
        auto k = eq < 0 ? pair : pair[0 .. eq];
        auto v = eq < 0 ? "" : pair[eq + 1 .. $];
        md.add(urlUnquotePlus(k), urlUnquotePlus(v));
    }
    return md;
}

/// Percent-decoding with `+` as a space; invalid escapes are kept as they are (like Werkzeug).
string urlUnquotePlus(const(char)[] s)
{
    auto a = appender!string;
    size_t i;
    while (i < s.length)
    {
        char c = s[i];
        if (c == '+')
        {
            a.put(' ');
            i++;
        }
        else if (c == '%' && isHex(s, i + 1) && isHex(s, i + 2))
        {
            a.put(cast(char)(hexVal(s[i + 1]) * 16 + hexVal(s[i + 2])));
            i += 3;
        }
        else
        {
            a.put(c);
            i++;
        }
    }
    return sanitizeUtf8(a.data);
}

/// Percent-decoding of a path (no `+` handling).
string urlUnquote(const(char)[] s)
{
    auto a = appender!string;
    size_t i;
    while (i < s.length)
    {
        char c = s[i];
        if (c == '%' && isHex(s, i + 1) && isHex(s, i + 2))
        {
            a.put(cast(char)(hexVal(s[i + 1]) * 16 + hexVal(s[i + 2])));
            i += 3;
        }
        else
        {
            a.put(c);
            i++;
        }
    }
    return sanitizeUtf8(a.data);
}

private bool isHex(const(char)[] s, size_t i)
{
    if (i >= s.length)
        return false;
    auto c = s[i];
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

private int hexVal(char c)
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    return c - 'A' + 10;
}

/// Replaces invalid UTF-8 with U+FFFD (Werkzeug decodes with errors='replace').
string sanitizeUtf8(string s)
{
    import std.utf : validate, decode;
    try
    {
        validate(s);
        return s;
    }
    catch (Exception)
    {
        auto a = appender!string;
        size_t i;
        while (i < s.length)
        {
            try
            {
                auto d = decode(s, i);
                putUtf(a, d);
            }
            catch (Exception)
            {
                putUtf(a, 0xFFFD);
                i++;
            }
        }
        return a.data;
    }
}

/// `urllib.parse.quote(s, safe)`.
string urlQuote(string s, string safe = "/")
{
    auto a = appender!string;
    static immutable hex = "0123456789ABCDEF";
    foreach (ubyte c; s.representation)
    {
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '.'
                || c == '-' || c == '~' || safe.canFind(cast(char) c))
            a.put(cast(char) c);
        else
        {
            a.put('%');
            a.put(hex[c >> 4]);
            a.put(hex[c & 15]);
        }
    }
    return a.data;
}

/// Werkzeug's `url_encode` for query strings (`+` for spaces is not used: Werkzeug quotes with %20).
string urlEncodeQuery(string[2][] pairs)
{
    string[] parts;
    foreach (p; pairs)
        parts ~= urlQuote(p[0], "") ~ "=" ~ urlQuote(p[1], "");
    return parts.join("&");
}

// ------------------------------------------------------------ uploaded files

/// A file of a multipart form (`werkzeug.FileStorage`).
final class FileStorage
{
    string name;        /// form field name
    string filename;
    string contentType;
    immutable(ubyte)[] data;

    /// `file.save(path)`
    void save(string path)
    {
        import std.file : write;
        write(path, data);
    }
}

// ------------------------------------------------------------ request

/// The current request (`flask.request`).
final class Request
{
    string method;          /// "GET", "POST"...
    string path;            /// percent-decoded path ("/browser/nodes/")
    string rawPath;         /// as received (still encoded)
    string queryString;     /// raw query string, without '?'
    string[2][] headers;    /// copies of the request headers
    immutable(ubyte)[] data;/// raw body (`request.data` / `get_data()`)
    MultiDict args;         /// query string
    MultiDict form;         /// form fields (urlencoded or multipart text parts)
    FileStorage[][string] files;
    string[string] cookies;
    string remoteAddr;
    string scheme = "http";
    string host;            /// "localhost:5050"
    string scriptRoot;      /// application root (SCRIPT_NAME), "" by default

    // filled by the router
    string endpoint;
    string blueprint;
    Value viewArgs;

    private Value jsonCache;
    private bool jsonParsed;

    string header(string name) const
    {
        foreach (h; headers)
            if (h[0].toLower == name.toLower)
                return h[1];
        return null;
    }

    string contentType() const => header("Content-Type");
    string mimetype() const
    {
        auto ct = contentType;
        auto semi = ct.indexOf(';');
        return (semi < 0 ? ct : ct[0 .. semi]).strip.toLower;
    }

    /// `request.is_json`
    bool isJson() const
    {
        auto m = mimetype;
        return m == "application/json" || (m.startsWith("application/") && m.endsWith("+json"));
    }

    /// `request.get_json(silent=...)`. Flask parses only JSON content types unless `force`.
    Value getJson(bool silent = false, bool force = false)
    {
        if (!force && !isJson)
        {
            if (silent)
                return Value(null);
            throw new HTTPException(415, "Did not attempt to load JSON data because the request Content-Type was not 'application/json'.");
        }
        if (!jsonParsed)
        {
            jsonParsed = true;
            try
                jsonCache = parseJson(cast(string) data);
            catch (Exception e)
            {
                jsonCache = Value.undefined;
            }
        }
        if (jsonCache.isUndefined)
        {
            if (silent)
                return Value(null);
            throw new HTTPException(400, "Failed to decode JSON object");
        }
        return jsonCache;
    }

    /// `request.data` as text.
    string text() const => cast(string) data;

    /// `request.url_root`
    string urlRoot() const => scheme ~ "://" ~ host ~ scriptRoot ~ "/";

    /// `request.url`
    string url() const => scheme ~ "://" ~ host ~ scriptRoot ~ rawPath ~ (queryString.length ? "?" ~ queryString : "");

    /// `request.full_path`
    string fullPath() const => path ~ "?" ~ queryString;

    string userAgent() const => header("User-Agent");

    /// `request.accept_mimetypes.accept_json`-style check.
    bool acceptsJson() const
    {
        auto a = header("Accept");
        return a.canFind("application/json");
    }
}

// ------------------------------------------------------------ exceptions

/// Werkzeug's `HTTPException` (`abort(404)`).
class HTTPException : Exception
{
    int code;
    string description;
    Response response; /// a ready response (abort(response))

    this(int code, string description = null, string file = __FILE__, size_t line = __LINE__)
    {
        super(statusName(code) ~ (description.length ? ": " ~ description : ""), file, line);
        this.code = code;
        this.description = description.length ? description : defaultDescription(code);
    }

    this(Response r, string file = __FILE__, size_t line = __LINE__)
    {
        super(statusName(r.status), file, line);
        code = r.status;
        response = r;
    }

    /// The HTML error page Werkzeug renders.
    Response toResponse()
    {
        if (response !is null)
            return response;
        auto name = statusName(code);
        auto body_ = "<!doctype html>\n<html lang=en>\n<title>" ~ to!string(code) ~ " " ~ name ~ "</title>\n<h1>" ~ name
            ~ "</h1>\n<p>" ~ description ~ "</p>\n";
        auto r = new Response(body_, code);
        r.mimetype = "text/html";
        return r;
    }
}

noreturn abort(int code, string description = null)
{
    throw new HTTPException(code, description);
}

noreturn abort(Response r)
{
    throw new HTTPException(r);
}

string statusName(int code)
{
    switch (code)
    {
    case 200: return "OK";
    case 201: return "Created";
    case 202: return "Accepted";
    case 204: return "No Content";
    case 301: return "Moved Permanently";
    case 302: return "Found";
    case 303: return "See Other";
    case 304: return "Not Modified";
    case 307: return "Temporary Redirect";
    case 308: return "Permanent Redirect";
    case 400: return "Bad Request";
    case 401: return "Unauthorized";
    case 403: return "Forbidden";
    case 404: return "Not Found";
    case 405: return "Method Not Allowed";
    case 406: return "Not Acceptable";
    case 409: return "Conflict";
    case 410: return "Gone";
    case 413: return "Request Entity Too Large";
    case 415: return "Unsupported Media Type";
    case 422: return "Unprocessable Entity";
    case 428: return "Precondition Required";
    case 429: return "Too Many Requests";
    case 500: return "Internal Server Error";
    case 501: return "Not Implemented";
    case 502: return "Bad Gateway";
    case 503: return "Service Unavailable";
    case 504: return "Gateway Timeout";
    default: return "Unknown";
    }
}

private string defaultDescription(int code)
{
    switch (code)
    {
    case 400: return "The browser (or proxy) sent a request that this server could not understand.";
    case 401: return "The server could not verify that you are authorized to access the URL requested. You either "
        ~ "supplied the wrong credentials (e.g. a bad password), or your browser doesn't understand how to supply the "
        ~ "credentials required.";
    case 403: return "You don't have the permission to access the requested resource. It is either read-protected or "
        ~ "not readable by the server.";
    case 404: return "The requested URL was not found on the server. If you entered the URL manually please check your "
        ~ "spelling and try again.";
    case 405: return "The method is not allowed for the requested URL.";
    case 410: return "The requested URL is no longer available on this server and there is no forwarding address.";
    case 413: return "The data value transmitted exceeds the capacity limit.";
    case 415: return "The server does not support the media type transmitted in the request.";
    case 500: return "The server encountered an internal error and was unable to complete your request. Either the "
        ~ "server is overloaded or there is an error in the application.";
    default: return "";
    }
}

// ------------------------------------------------------------ response

struct CookieSpec
{
    string name;
    string value;
    string path = "/";
    string domain;
    long maxAge = -1;       /// -1 = session cookie
    string expires;         /// HTTP date, when set
    bool secure;
    bool httpOnly;
    string sameSite;        /// "Lax", "Strict", "None" or null
}

import andaime.web.stream : EventWriter;

/// A streamed body: called with a sink that sends each chunk.
alias StreamBody = void delegate(scope void delegate(const(char)[]) write);
alias EventStreamFn = void delegate(scope EventWriter w) @system;

/// `flask.Response`.
final class Response : Obj
{
    int status = 200;
    string mimetype = "text/html";
    string charset = "utf-8";
    string body;
    string[2][] headers;
    CookieSpec[] cookies;
    StreamBody stream;          /// when set, the body is produced by this delegate
    EventStreamFn eventStream;  /// when set, SSE events are produced by this delegate
    string sendFilePath;        /// when set, the file is sent (send_file)
    long contentLength = -1;

    /// A response that only carries SQL text (`only_sql=True` paths return the string in Python).
    string sqlText;
    static Response sqlOnly(string sql)
    {
        auto r = new Response;
        r.sqlText = sql;
        return r;
    }

    /// Creates an SSE (Server-Sent Events) streaming response.
    static Response sse(EventStreamFn fn)
    {
        auto r = new Response("", 200, "text/event-stream");
        r.eventStream = fn;
        r.setHeader("Cache-Control", "no-cache, no-store, must-revalidate");
        r.setHeader("Pragma", "no-cache");
        r.setHeader("Expires", "0");
        r.setHeader("X-Accel-Buffering", "no");
        return r;
    }

    this() {}

    this(string body_, int status = 200, string mimetype = "text/html")
    {
        this.body = body_;
        this.status = status;
        this.mimetype = mimetype;
    }

    /// The Content-Type header value (Flask adds the charset to text types and JSON is charset-less).
    string contentType() const
    {
        foreach (h; headers)
            if (h[0].toLower == "content-type")
                return h[1];
        if (mimetype.startsWith("text/") || mimetype == "application/javascript" || mimetype == "application/xml")
            return mimetype ~ "; charset=" ~ charset;
        return mimetype;
    }

    void setHeader(string name, string value)
    {
        foreach (ref h; headers)
            if (h[0].toLower == name.toLower)
            {
                h[1] = value;
                return;
            }
        headers ~= [name, value];
    }

    void addHeader(string name, string value)
    {
        headers ~= [name, value];
    }

    string getHeader(string name) const
    {
        foreach (h; headers)
            if (h[0].toLower == name.toLower)
                return h[1];
        return null;
    }

    void removeHeader(string name)
    {
        string[2][] keep;
        foreach (h; headers)
            if (h[0].toLower != name.toLower)
                keep ~= h;
        headers = keep;
    }

    void setCookie(CookieSpec c)
    {
        cookies ~= c;
    }

    void deleteCookie(string name, string path = "/", string domain = null)
    {
        CookieSpec c;
        c.name = name;
        c.value = "";
        c.path = path;
        c.domain = domain;
        c.maxAge = 0;
        c.expires = "Thu, 01 Jan 1970 00:00:00 GMT";
        cookies ~= c;
    }
}

/// `Set-Cookie` header value for a cookie (Werkzeug's dump_cookie ordering).
string cookieHeader(CookieSpec c)
{
    string s = c.name ~ "=" ~ quoteCookieValue(c.value);
    if (c.domain.length)
        s ~= "; Domain=" ~ c.domain;
    if (c.expires.length)
        s ~= "; Expires=" ~ c.expires;
    if (c.maxAge >= 0)
        s ~= "; Max-Age=" ~ to!string(c.maxAge);
    if (c.secure)
        s ~= "; Secure";
    if (c.httpOnly)
        s ~= "; HttpOnly";
    if (c.path.length)
        s ~= "; Path=" ~ c.path;
    if (c.sameSite.length)
        s ~= "; SameSite=" ~ c.sameSite;
    return s;
}

private string quoteCookieValue(string v)
{
    bool needs;
    foreach (c; v)
        if (c < 0x21 || c > 0x7e || c == '"' || c == ',' || c == ';' || c == '\\')
            needs = true;
    if (!needs)
        return v;
    auto a = appender!string;
    a.put('"');
    foreach (ubyte c; v.representation)
    {
        if (c == '"' || c == '\\')
        {
            a.put('\\');
            a.put(cast(char) c);
        }
        else if (c < 0x20 || c > 0x7e)
        {
            import std.format : format;
            a.put(format("\\%03o", c));
        }
        else
            a.put(cast(char) c);
    }
    a.put('"');
    return a.data;
}

/// Parses a Cookie request header.
string[string] parseCookies(string header)
{
    string[string] r;
    foreach (part; header.split(";"))
    {
        auto p = part.strip;
        auto eq = p.indexOf('=');
        if (eq <= 0)
            continue;
        auto k = p[0 .. eq].strip;
        auto v = p[eq + 1 .. $].strip;
        if (v.length >= 2 && v[0] == '"' && v[$ - 1] == '"')
            v = v[1 .. $ - 1];
        if (k !in r)
            r[k] = v;
    }
    return r;
}

/// An HTTP date (RFC 7231) for a Unix time.
string httpDate(long unixTime)
{
    import std.datetime.systime : SysTime, unixTimeToStdTime;
    import std.datetime.timezone : UTC;
    import std.format : format;
    auto t = SysTime(unixTimeToStdTime(unixTime), UTC());
    static immutable days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
    static immutable months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    import std.datetime.date : DayOfWeek;
    int dow = cast(int) t.dayOfWeek; // 0 = Sunday
    auto dname = days[(dow + 6) % 7];
    return format("%s, %02d %s %04d %02d:%02d:%02d GMT", dname, t.day, months[t.month - 1], t.year, t.hour,
            t.minute, t.second);
}

// ------------------------------------------------------------ ajax helpers (pgadmin/utils/ajax.py)

private void noCache(Response r)
{
    r.setHeader("Cache-Control", "no-cache, no-store, must-revalidate");
    r.setHeader("Pragma", "no-cache");
    r.setHeader("Expires", "0");
}

/// `make_json_response(success, errormsg, info, result, data, status)`.
Response makeJsonResponse(long success = 1, Value errormsg = Value(""), Value info = Value(""),
        Value result = Value(null), Value data = Value(null), int status = 200)
{
    auto doc = new Dict;
    doc["success"] = Value(success);
    doc["errormsg"] = errormsg;
    doc["info"] = info;
    doc["result"] = result;
    doc["data"] = data;
    auto r = new Response(Value(doc).toJson, status, "application/json");
    noCache(r);
    return r;
}

/// `make_json_response` with a non-integer `success` (Python callers sometimes pass `True`).
Response makeJsonResponseAny(Value success, Value errormsg = Value(""), Value info = Value(""), Value result = Value(null),
        Value data = Value(null), int status = 200)
{
    auto doc = new Dict;
    doc["success"] = success;
    doc["errormsg"] = errormsg;
    doc["info"] = info;
    doc["result"] = result;
    doc["data"] = data;
    auto r = new Response(Value(doc).toJson, status, "application/json");
    noCache(r);
    return r;
}

/// Keyword-style builder: `jsonResponse().data(x).status(410)...`
struct JsonResponseArgs
{
    long success = 1;
    Value errormsg = Value("");
    Value info = Value("");
    Value result = Value(null);
    Value data = Value(null);
    int status = 200;

    Response make() => makeJsonResponse(success, errormsg, info, result, data, status);
}

Response makeJsonResponse(JsonResponseArgs a) => a.make();

/// `make_response(response, status)`: any value as JSON.
Response makeResponse(Value response = Value(null), int status = 200)
{
    auto r = new Response(response.toJson, status, "application/json");
    noCache(r);
    return r;
}

private Value msgValue(string s) => Value(s is null ? "" : s);

Response internalServerError(string errormsg = "", Value data = Value(null))
{
    return makeJsonResponse(0, msgValue(errormsg), Value(""), Value(null), data, 500);
}

Response forbidden(string errmsg = "") => makeJsonResponse(0, msgValue(errmsg), Value(""), Value(null), Value(null), 403);
Response unauthorized(string errormsg = "") => makeJsonResponse(0, msgValue(errormsg), Value(""), Value(null), Value(null), 401);
Response badRequest(string errormsg = "") => makeJsonResponse(0, msgValue(errormsg), Value(""), Value(null), Value(null), 400);
Response preconditionRequired(string errormsg = "") => makeJsonResponse(0, msgValue(errormsg), Value(""), Value(null), Value(null), 428);
Response successReturn(string message = "") => makeJsonResponse(1, Value(""), msgValue(message), Value(null), Value(null), 200);
Response gone(string errormsg = "") => makeJsonResponse(0, msgValue(errormsg), Value(""), Value(null), Value(null), 410);

Response notImplemented(string errormsg = "Not implemented.", string info = "", Value result = Value(null),
        Value data = Value(null))
{
    return makeJsonResponse(0, msgValue(errormsg), msgValue(info), result, data, 501);
}

Response serviceUnavailable(string errormsg = "Service Unavailable", string info = "", Value result = Value(null),
        Value data = Value(null))
{
    return makeJsonResponse(0, msgValue(errormsg), msgValue(info), result, data, 503);
}

Response plainTextResponse(string message = "")
{
    return new Response(message, 200, "text/plain");
}

/// `flask.redirect(location, code)`.
Response redirect(string location, int code = 302)
{
    import pgadmin.jinja.runtime : htmlEscape;
    auto r = new Response("<!doctype html>\n<html lang=en>\n<title>Redirecting...</title>\n<h1>Redirecting...</h1>\n"
            ~ "<p>You should be redirected automatically to the target URL: <a href=\"" ~ htmlEscape(location) ~ "\">"
            ~ htmlEscape(location) ~ "</a>. If not, click the link.\n", code);
    r.setHeader("Location", location);
    return r;
}

/// `jsonify(x)` (Flask: sorted keys, compact separators... Flask 3 uses `, ` and `: ` only when debugging).
Response jsonify(Value v, int status = 200)
{
    import pgadmin.jinja.builtins : sortedJson;
    auto r = new Response(compactSorted(v) ~ "\n", status, "application/json");
    return r;
}

/// JSON with sorted keys and compact separators (Flask's default provider output).
string compactSorted(Value v)
{
    import std.algorithm : sort;
    if (v.isDict)
    {
        auto keys = v.dict.keys;
        sort(keys);
        auto a = appender!string;
        a.put("{");
        foreach (i, k; keys)
        {
            if (i)
                a.put(",");
            jsonString(a, k);
            a.put(":");
            a.put(compactSorted(v.dict[k]));
        }
        a.put("}");
        return a.data;
    }
    if (v.isList)
    {
        string[] parts;
        foreach (x; v.list.items)
            parts ~= compactSorted(x);
        return "[" ~ parts.join(",") ~ "]";
    }
    return v.toJson;
}

// ------------------------------------------------------------ request body helpers

/// `json.loads(request.data.decode('utf-8'))`; None for an empty body.
Value jsonBody(Request r)
{
    auto t = r.text;
    if (t.length == 0)
        return Value(null);
    return parseJson(t);
}

/// `request.form if request.form else json.loads(request.data)` — the idiom used by most views.
Value formOrJson(Request r)
{
    if (!r.form.empty)
        return r.form.toDict;
    // json.loads(b'') raises, unlike request.get_json(silent=True)
    return parseJson(r.text);
}

/// Raised where the Python view would `return None` (Flask then answers with a bare 500 page).
class ViewReturnedNone : Exception
{
    this(string msg = "The view function did not return a valid response")
    {
        super(msg);
    }
}
