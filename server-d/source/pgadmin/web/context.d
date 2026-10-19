/// Request-scoped state: Flask's `request`, `session`, `g`, Flask-Login's `current_user`, and flashed messages.
///
/// andaime runs each request in its own fiber, and a fiber runs one request at a time, so the state is kept per fiber.
/// Code that runs outside a request (start-up, background jobs) sees a fallback context without a request or user.
module pgadmin.web.context;

import core.thread : Fiber;
import std.algorithm : canFind;
import pgadmin.core.value;
import pgadmin.web.http : Request;
import pgadmin.web.session : Session;

final class RequestContext
{
    Request request;
    Session session;
    Dict g;
    /// The logged-in user row (`user` table) or None.
    Value user;
    string[] roles;
    string cspNonce;
    /// Opaque handle to the framework context (andaime's Context) for streaming and WebSockets.
    Object raw;

    this()
    {
        g = new Dict;
        user = Value(null);
    }
}

private RequestContext[void*] byFiber;
private RequestContext fallback;

private void* fiberKey() @trusted
{
    return cast(void*) Fiber.getThis();
}

/// Binds `c` to the running fiber (the dispatcher calls this at the start of a request).
void bindContext(RequestContext c)
{
    auto k = fiberKey();
    if (k is null)
        fallback = c;
    else
        byFiber[k] = c;
}

void unbindContext()
{
    auto k = fiberKey();
    if (k is null)
        fallback = null;
    else
        byFiber.remove(k);
}

/// The current context (never null: outside a request a fresh, empty one).
RequestContext reqctx()
{
    auto k = fiberKey();
    if (k !is null)
        if (auto p = k in byFiber)
            return *p;
    if (fallback is null)
        fallback = new RequestContext;
    return fallback;
}

bool hasRequestContext()
{
    auto k = fiberKey();
    if (k !is null)
        return (k in byFiber) !is null;
    return fallback !is null && fallback.request !is null;
}

Request request() => reqctx().request;
Session session() => reqctx().session;
Dict g() => reqctx().g;

/// `current_user` (the user row) or None.
Value currentUser() => reqctx().user;

bool isAuthenticated() => reqctx().user.isDict;

/// `current_user.id`, or -1 when nobody is logged in.
long currentUserId()
{
    auto u = reqctx().user;
    return u.isDict ? u["id"].integer : -1;
}

/// `current_user.<attr>` (None when not logged in).
Value currentUserAttr(string attr)
{
    auto u = reqctx().user;
    return u.isDict ? u.get(attr) : Value(null);
}

bool currentUserHasRole(string role) => reqctx().roles.canFind(role);

/// `flash(message, category)`: queued in the session, shown on the next rendered page.
void flash(string message, string category = "message")
{
    auto s = session();
    if (s is null)
        return;
    auto list = s.get("_flashes");
    if (!list.isList)
        list = Value.newList();
    list.append(Value.tuple(Value(category), Value(message)));
    s["_flashes"] = list;
}

/// `get_flashed_messages(with_categories)`: removes them from the session.
Value getFlashedMessages(bool withCategories = false)
{
    auto s = session();
    if (s is null)
        return Value.newList();
    auto list = s.pop("_flashes");
    if (!list.isList)
        return Value.newList();
    if (withCategories)
        return list;
    Value[] msgs;
    foreach (t; list.list.items)
        msgs ~= t[1];
    return Value(msgs);
}
