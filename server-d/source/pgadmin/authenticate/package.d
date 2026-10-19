/// Authentication: the Flask-Security login/logout views and pgAdmin's `authenticate` module with the internal source.
///
/// Only internal authentication (the user table of the configuration database) is ported. LDAP, Kerberos, OAuth2 and
/// web server authentication, and two-factor authentication, are not implemented in this build.
module pgadmin.authenticate;

import std.algorithm : canFind;
import std.array : split;
import std.regex : regex, matchFirst;
import std.string : startsWith, toLower, strip, indexOf;
import pgadmin.core.config;
import pgadmin.core.crypto;
import pgadmin.core.i18n;
import pgadmin.core.log;
import pgadmin.core.templates : renderTemplate;
import pgadmin.core.value;
import pgadmin.db.driver : getDriver;
import pgadmin.model;
import pgadmin.utils.constants;
import pgadmin.utils.master_password;
import pgadmin.web.auth;
import pgadmin.web.context;
import pgadmin.web.flask;
import pgadmin.web.http;

/// Flash categories as Python stores them (some `MessageType` members are 1-tuples there).
Value messageType(MessageType t)
{
    final switch (t)
    {
    case MessageType.WARNING: return Value("Warning");
    case MessageType.SUCCESS: return Value.tuple(Value("Success"));
    case MessageType.ERROR: return Value.tuple(Value("Error"));
    case MessageType.INFO: return Value.tuple(Value("Info"));
    case MessageType.CLOSE: return Value.tuple(Value("Close"));
    }
}

void flashValue(string message, Value category)
{
    auto s = session();
    auto list = s.get("_flashes");
    if (!list.isList)
        list = Value.newList();
    list.append(Value.tuple(category, Value(message)));
    s["_flashes"] = list;
}

/// `validate_email`: a pragmatic check (the original uses the email_validator package).
bool validateEmail(string email)
{
    auto m = matchFirst(email, regex(`^[^@\s]+@[^@\s]+\.[^@\s]+$`));
    return !m.empty;
}

/// `get_post_login_redirect` + the allow-list of `get_safe_post_login_redirect`.
string safePostLoginRedirect()
{
    auto indexUrl = flaskApp.urlFor("browser.index");
    string url = request().args.get("next", request().form.get("next", ""));
    if (url.length == 0)
        url = "/";
    // only same-site paths below the browser are allowed
    if (url.startsWith(indexUrl))
        return url;
    return indexUrl;
}

string safePostLogoutRedirect()
{
    auto loginUrl_ = flaskApp.urlFor("security.login");
    string url = request().args.get("next", request().form.get("next", ""));
    if (url.length && url.startsWith(loginUrl_))
        return url;
    return loginUrl_;
}

/// The URL-safe state kept in the session after a login (`AuthSourceManager.as_dict()`).
private Value authSourceManagerDict(string[] sources)
{
    auto d = Value.newDict();
    d["source_friendly_name"] = INTERNAL;
    Value[] srcs;
    foreach (s; sources)
        srcs ~= Value(s);
    d["auth_sources"] = Value(srcs);
    d["current_source"] = INTERNAL;
    return d;
}

/// The Flask-Security login page and logout (`security.login`, `security.logout`).
final class SecurityModule : Blueprint
{
    this()
    {
        super("security", "/");
    }

    override void setup()
    {
        route("/login", "login", ["GET", "POST"], (Dict a) {
            if (isAuthenticated())
                return redirect(safePostLoginRedirect());
            if (request().method == "POST")
                return authenticateLogin();
            return new Response(renderTemplate("security/login_user.html"));
        }, true);
        route("/logout", "logout", ["GET", "POST"], (Dict a) {
            if (isAuthenticated())
            {
                runLogoutHooks();
                flaskApp.logoutUser();
            }
            return redirect(safePostLogoutRedirect());
        }, true);
    }
}

/// What happens when a user logs out (`current_user_cleanup`): release connections and forget the key.
void runLogoutHooks()
{
    foreach (b; flaskApp.logoutHooks)
    {
        try
            b.onLogout();
        catch (Exception e)
            logException(e);
    }
    getDriver().gcOwn();
    keyManager.reset();
}

/// POST /authenticate/login (also reached through /login): the internal source.
Response authenticateLogin()
{
    auto req = request();
    auto username = req.form.get("email", "");
    auto password = req.form.get("password", "");
    auto maxAttempts = cfgInt("MAX_LOGIN_ATTEMPTS");

    auto user = db.queryOne(`SELECT * FROM "user" WHERE username = ? AND auth_source = ?`, Value(username), Value(INTERNAL));
    if (user.isDict)
    {
        bool lock = maxAttempts > 0 && user["login_attempts"].integer >= maxAttempts;
        db.exec(`UPDATE "user" SET locked = ? WHERE id = ?`, Value(lock ? 1 : 0), user["id"]);
        if (lock)
        {
            flashValue(gettext("Your account is locked. Please contact the Administrator."), messageType(MessageType.WARNING));
            return redirect(safePostLogoutRedirect());
        }
    }

    // validation: email syntax, presence and credentials (errors by field, like a WTForms form)
    string emailErr, passErr;
    if (!validateEmail(username))
        emailErr = gettext("Email/Username is not valid");
    else if (password.length == 0)
        passErr = gettext("Password not provided");
    else
    {
        auto u = db.queryOne(`SELECT * FROM "user" WHERE lower(email) = ?`, Value(username.toLower));
        if (u.isNone)
        {
            hashPassword(password, cfgStr("SECURITY_PASSWORD_SALT"));
            emailErr = gettext("Incorrect username or password.");
        }
        else if (!verifyPassword(password, binaryColumn(u["password"]), cfgStr("SECURITY_PASSWORD_SALT")))
            passErr = gettext("Incorrect username or password.");
        else if (!u["active"].truthy)
            emailErr = gettext("Account is disabled.");
        else
            user = u;
    }

    bool failed = emailErr.length || passErr.length;
    if (failed)
    {
        string attemptNote;
        if (passErr.length && user.isDict && cfgStr("LOGIN_ATTEMPT_FIELDS").length)
        {
            if (maxAttempts > 0)
            {
                db.exec(`UPDATE "user" SET login_attempts = login_attempts + 1 WHERE id = ?`, user["id"]);
                auto left = maxAttempts - (user["login_attempts"].integer + 1);
                import std.conv : to;
                attemptNote = left > 1 ? gettext(to!string(left) ~ " more attempts remaining.")
                    : gettext(to!string(left) ~ " more attempt remaining.");
            }
        }
        if (emailErr.length)
            flashValue(emailErr, messageType(MessageType.WARNING));
        if (passErr.length)
            flashValue(passErr ~ attemptNote, messageType(MessageType.WARNING));
        return redirect(safePostLogoutRedirect());
    }

    // login
    flaskApp.loginUser(user);
    session()["auth_source_manager"] = authSourceManagerDict(ConfigAccess.get("AUTHENTICATION_SOURCES").toStrings);
    db.exec(`UPDATE "user" SET login_attempts = 0 WHERE id = ?`, user["id"]);
    logInfo("Internal user " ~ username ~ " logged in.");
    // a user's key (for saved passwords) is the account password unless a master password is used
    if (cfgBool("SERVER_MODE") && password.length)
        keyManager.set(password);
    return redirect(safePostLoginRedirect());
}

string[] toStrings(Value v)
{
    string[] r;
    foreach (x; v.iterItems())
        r ~= x.toString;
    return r;
}

final class AuthenticateModule : Blueprint
{
    this()
    {
        super("authenticate");
        staticUrlPath = "";
    }

    override string[] getExposedUrlEndpoints() => ["authenticate.login"];

    override void setup()
    {
        route("/login", "login", ["GET", "POST"], (Dict a) => authenticateLogin(), true);
    }
}
