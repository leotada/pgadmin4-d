/// Master password endpoints (`browser.set_master_password` & friends) and the cleanup of saved passwords.
module pgadmin.browser.master_password;

import pgadmin.core.config;
import pgadmin.core.i18n;
import pgadmin.core.log;
import pgadmin.core.value;
import pgadmin.db.driver;
import pgadmin.model;
import pgadmin.utils.constants;
import pgadmin.utils.master_password;
import pgadmin.web.context;
import pgadmin.web.http;

Response formMasterPasswordResponse(bool existing = true, bool present = false, string errmsg = null,
        string keyringName = "", bool masterPasswordHook = false)
{
    auto d = Value.newDict();
    d["present"] = Value(present);
    d["reset"] = Value(existing);
    d["errmsg"] = errmsg.length ? Value(errmsg) : Value(null);
    d["keyring_name"] = Value(keyringName);
    d["master_password_hook"] = Value(masterPasswordHook);
    d["is_error"] = Value(errmsg.length > 0);
    return makeJsonResponse(1, Value(""), Value(""), Value(null), d);
}

/// `remove_saved_passwords(user_id)`: clears every password stored for the user's servers.
void removeSavedPasswords(long userId)
{
    db.exec("UPDATE server SET password = NULL, tunnel_password = NULL, save_password = 0 WHERE user_id = ?", Value(userId));
    db.exec("UPDATE sharedserver SET password = NULL, tunnel_password = NULL, save_password = 0 WHERE user_id = ?", Value(userId));
}

void cleanupMasterPassword()
{
    setMasterpassCheckText("", true);
    removeSavedPasswords(currentUserId());
    keyManager.hardReset();
    foreach (server; db.query("SELECT * FROM server WHERE user_id = ?", Value(currentUserId())))
    {
        auto manager = getDriver().connectionManager(server["id"].integer);
        if (manager !is null)
            manager.update(server);
    }
}

/// `process_masterpass_disabled()`
bool processMasterpassDisabled()
{
    if (!cfgBool("SERVER_MODE") && !cfgBool("MASTER_PASSWORD_REQUIRED")
            && !currentUserAttr("masterpass_check").isNone)
    {
        cleanupMasterPassword();
        return true;
    }
    return false;
}

/// Re-encrypts saved passwords with a new key (`reencrpyt_server_passwords`).
void reencryptServerPasswords(long userId, string oldKey, string newKey)
{
    import pgadmin.core.crypto : decryptStr, encrypt;
    foreach (table; ["server", "sharedserver"])
        foreach (row; db.query("SELECT id, password, tunnel_password FROM " ~ table ~ " WHERE user_id = ?", Value(userId)))
        {
            Value pw = row["password"], tp = row["tunnel_password"];
            try
            {
                if (!pw.isNone)
                    pw = toBinaryColumn(encrypt(decryptStr(binaryColumn(pw), oldKey), newKey));
                if (!tp.isNone)
                    tp = toBinaryColumn(encrypt(decryptStr(binaryColumn(tp), oldKey), newKey));
            }
            catch (Exception)
            {
                pw = Value(null);
                tp = Value(null);
            }
            db.exec("UPDATE " ~ table ~ " SET password = ?, tunnel_password = ? WHERE id = ?", pw, tp, row["id"]);
        }
}

/// `set_master_password()` view.
Response setMasterPassword()
{
    auto req = request();
    Value data = Value(null);
    if (!req.form.empty)
        data = req.form.toDict;
    else if (req.data.length)
    {
        auto text = req.text;
        data = text.length ? parseJson(text) : Value("");
    }
    string keyringName, errmsg;
    bool hook;

    auto get = (string k) => data.isDict ? data.get(k) : Value(null);

    // Desktop mode without an OS keyring behaves like Python without a keyring backend: the master password flow
    if (!cfgBool("SERVER_MODE") || cfgBool("MASTER_PASSWORD_REQUIRED") && false)
    {
    }

    if (!cfgBool("SERVER_MODE") || ConfigAccess.get("AUTHENTICATION_SOURCES").contains(OAUTH2)
            || ConfigAccess.get("AUTHENTICATION_SOURCES").contains(KERBEROS)
            || ConfigAccess.get("AUTHENTICATION_SOURCES").contains(WEBSERVER) && cfgBool("MASTER_PASSWORD_REQUIRED"))
    {
        auto check = currentUserAttr("masterpass_check");
        if (!check.isNone && get("submit_password").truthy && !validateMasterPassword(get("password").toString))
        {
            errmsg = gettext("Incorrect master password");
            return formMasterPasswordResponse(true, false, errmsg, keyringName, hook);
        }
        if (data.isDict && get("password").toString.length)
        {
            auto pw = get("password").toString;
            setCryptKey(pw);
            if (check.isNone)
                reencryptServerPasswords(currentUserId(), currentUserAttr("password").strOr(""), pw);
            setMasterpassCheckText(pw);
        }
        else if (!getCryptKey().present && !check.isNone)
            return formMasterPasswordResponse(true, false, null, keyringName);
        else if (getCryptKey().key.length == 0)
        {
            string e;
            if (get("submit_password").truthy && get("password").toString == "")
                e = gettext("Master password cannot be empty");
            return formMasterPasswordResponse(false, false, e, keyringName);
        }
    }

    processMasterpassDisabled();

    if (cfgBool("SERVER_MODE") && currentUserAttr("masterpass_check").isNone)
    {
        auto key = getCryptKey().key;
        reencryptServerPasswords(currentUserId(), currentUserAttr("password").strOr(""), key);
        setMasterpassCheckText(key);
    }
    return formMasterPasswordResponse(true, true);
}
