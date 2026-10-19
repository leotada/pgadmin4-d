/// Login checks shared by the views (`pga_login_required`, `permissions_required`) and the unauthorised handler.
module pgadmin.web.auth;

import std.algorithm : canFind;
import pgadmin.core.config;
import pgadmin.core.value;
import pgadmin.model : userHasPermission;
import pgadmin.web.context;
import pgadmin.web.flask;
import pgadmin.web.http;

/// Flask-Login's `login_url(view, next_url)`.
string loginUrl(string view, string nextUrl = null)
{
    auto d = new Dict;
    if (nextUrl.length)
        d["next"] = nextUrl;
    return flaskApp.urlFor(view, d);
}

/// `pga_unauthorised()`: a redirect to the login page, or a JSON 401 when there is no login view.
Response unauthorisedResponse()
{
    auto view = flaskApp.loginView;
    if (view.length == 0)
        return makeJsonResponse(0, Value("Unauthorised access, permission denied."), Value("PGADMIN_LOGIN_REQUIRED"),
                Value(null), Value(null), 401);
    return redirect(loginUrl(view, request().url));
}

/// True when the request may go on (authenticated; MFA is checked by the MFA module's hook when enabled).
bool pgaLoginRequired() => isAuthenticated();

Response loginRedirect() => unauthorisedResponse();

/// Wraps a view with `@pga_login_required`.
View loginRequired(View v)
{
    return (Dict a) {
        if (!pgaLoginRequired())
            return unauthorisedResponse();
        return v(a);
    };
}

/// `@permissions_required(...)`: 403 JSON when the user lacks one of them.
View permissionsRequired(View v, string[] perms...)
{
    return (Dict a) {
        if (!isAuthenticated())
            return unauthorisedResponse();
        foreach (p; perms)
            if (!userHasPermission(currentUserId(), p))
                return forbidden("Unauthorised access, permission denied.");
        return v(a);
    };
}

/// `@roles_required(...)`: 403 JSON when the user lacks the role.
View rolesRequired(string role, View v)
{
    return (Dict a) {
        if (!isAuthenticated())
            return unauthorisedResponse();
        if (!currentUserHasRole(role))
            return forbidden("Unauthorised access, permission denied.");
        return v(a);
    };
}

