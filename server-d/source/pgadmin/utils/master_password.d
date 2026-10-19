/// Encryption key handling for saved passwords (`pgadmin/utils/master_password.py`, `KeyManager`).
module pgadmin.utils.master_password;

import core.sync.mutex : Mutex;
import pgadmin.core.config;
import pgadmin.core.crypto;
import pgadmin.core.value;
import pgadmin.model;
import pgadmin.web.context;

enum MASTERPASS_CHECK_TEXT = "ideas are bulletproof";

private struct KeyEntry
{
    long sessionCount;
    string key;
}

/// In-memory keys per user (the master password / account password), shared by all of a user's sessions.
final class KeyManager
{
    private KeyEntry[long] users;
    private Mutex lock;

    this()
    {
        lock = new Mutex;
    }

    string get()
    {
        if (!isAuthenticated)
            return null;
        synchronized (lock)
            if (auto p = currentUserId() in users)
                return (*p).key;
        return null;
    }

    void set(string key, bool newLogin = true)
    {
        synchronized (lock)
        {
            auto uid = currentUserId();
            if (auto p = uid in users)
            {
                if (newLogin)
                    (*p).sessionCount++;
                (*p).key = key;
            }
            else
                users[uid] = KeyEntry(1, key);
        }
    }

    void reset()
    {
        synchronized (lock)
        {
            auto uid = currentUserId();
            if (auto p = uid in users)
            {
                (*p).sessionCount--;
                if ((*p).sessionCount == 0)
                    users.remove(uid);
            }
        }
    }

    void hardReset()
    {
        synchronized (lock)
            users.remove(currentUserId());
    }
}

private __gshared KeyManager keyManager_;

KeyManager keyManager()
{
    if (keyManager_ is null)
        keyManager_ = new KeyManager;
    return keyManager_;
}

struct CryptKey
{
    bool present;
    string key;
}

/// `get_crypt_key()`
CryptKey getCryptKey()
{
    auto enc = keyManager.get();
    if (enc is null)
    {
        if (cfgBool("SERVER_MODE"))
        {
            if (cfgBool("MASTER_PASSWORD_REQUIRED"))
                return CryptKey(false, null);
            auto s = session();
            if (s !is null && s.has("pass_enc_key"))
                return CryptKey(true, s.get("pass_enc_key").toString);
        }
        else
        {
            if (!cfgBool("MASTER_PASSWORD_REQUIRED") && !cfgBool("USE_OS_SECRET_STORAGE"))
                return CryptKey(true, currentUserAttr("password").strOr(""));
        }
        return CryptKey(false, null);
    }
    return CryptKey(true, enc);
}

void setCryptKey(string key, bool newLogin = true)
{
    keyManager.set(key, newLogin);
}

/// `validate_master_password(password)`
bool validateMasterPassword(string password)
{
    try
    {
        auto check = binaryColumn(currentUserAttr("masterpass_check"));
        return check !is null && decryptStr(check, password) == MASTERPASS_CHECK_TEXT;
    }
    catch (Exception)
        return false;
}

/// `set_masterpass_check_text(password, clear)`
void setMasterpassCheckText(string password, bool clear = false)
{
    Value v = Value(null);
    if (!clear)
        v = Value(encrypt(MASTERPASS_CHECK_TEXT, password));
    db.exec(`UPDATE "user" SET masterpass_check = ? WHERE id = ?`, v, Value(currentUserId()));
}
