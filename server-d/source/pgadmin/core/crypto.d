/// Cryptography over OpenSSL's libcrypto (dlopen): hashes, HMAC, PBKDF2, AES and random bytes.
///
/// Compatibility targets:
///  - `pgadmin.utils.crypto.encrypt/decrypt`: AES-CFB8 with the key padded with `}` to 32 bytes (16/24/32-byte keys
///    are used as is), output `base64(iv + ciphertext)`;
///  - Flask-Security `hash_password`/`verify_password` with `SECURITY_PASSWORD_HASH = 'pbkdf2_sha512'`:
///    `passlib.pbkdf2_sha512(base64(HMAC-SHA512(SECURITY_PASSWORD_SALT, password)))`.
module pgadmin.core.crypto;

import core.sys.posix.dlfcn : dlopen, dlsym, RTLD_NOW;
import std.algorithm : startsWith;
import std.array : split, replace;
import std.base64 : Base64, Base64URL;
import std.conv : to;
import std.string : representation;

private struct EVP_MD;
private struct EVP_CIPHER;
private struct EVP_CIPHER_CTX;

private struct Api
{
    extern (C) nothrow @nogc:
    const(EVP_MD)* function() EVP_sha1;
    const(EVP_MD)* function() EVP_sha256;
    const(EVP_MD)* function() EVP_sha512;
    const(EVP_MD)* function() EVP_md5;
    ubyte* function(const(EVP_MD)*, const(void)*, int, const(ubyte)*, size_t, ubyte*, uint*) HMAC;
    int function(const(void)*, size_t, ubyte*, uint*, const(EVP_MD)*, void*) EVP_Digest;
    int function(const(char)*, int, const(ubyte)*, int, int, const(EVP_MD)*, int, ubyte*) PKCS5_PBKDF2_HMAC;
    const(EVP_CIPHER)* function() EVP_aes_128_cfb8;
    const(EVP_CIPHER)* function() EVP_aes_192_cfb8;
    const(EVP_CIPHER)* function() EVP_aes_256_cfb8;
    const(EVP_CIPHER)* function() EVP_aes_256_cbc;
    const(EVP_CIPHER)* function() EVP_aes_128_cbc;
    EVP_CIPHER_CTX* function() EVP_CIPHER_CTX_new;
    void function(EVP_CIPHER_CTX*) EVP_CIPHER_CTX_free;
    int function(EVP_CIPHER_CTX*, const(EVP_CIPHER)*, void*, const(ubyte)*, const(ubyte)*, int) EVP_CipherInit_ex;
    int function(EVP_CIPHER_CTX*, ubyte*, int*, const(ubyte)*, int) EVP_CipherUpdate;
    int function(EVP_CIPHER_CTX*, ubyte*, int*) EVP_CipherFinal_ex;
    int function(ubyte*, int) RAND_bytes;
}

private __gshared Api api;
private __gshared bool loaded;
private __gshared Object lock;

shared static this()
{
    lock = new Object;
}

class CryptoError : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line);
    }
}

private void ensureLoaded() @trusted
{
    synchronized (lock)
    {
        if (loaded)
            return;
        void* h;
        // OpenSSL 3 first: on some systems `libcrypto.so` is LibreSSL
        foreach (n; ["libcrypto.so.3\0", "libcrypto.so.1.1\0", "libcrypto.so\0", "libcrypto.dylib\0"])
            if ((h = dlopen(n.ptr, RTLD_NOW)) !is null)
                break;
        if (h is null)
            throw new CryptoError("libcrypto (OpenSSL) not found");
        static foreach (m; __traits(allMembers, Api))
        {
            {
                auto p = dlsym(h, (m ~ "\0").ptr);
                if (p is null)
                    throw new CryptoError("missing symbol in libcrypto: " ~ m);
                __traits(getMember, api, m) = cast(typeof(__traits(getMember, api, m))) p;
            }
        }
        loaded = true;
    }
}

enum Digest
{
    sha1,
    sha256,
    sha512,
    md5,
}

private const(EVP_MD)* md(Digest d) @trusted
{
    ensureLoaded();
    final switch (d)
    {
    case Digest.sha1: return api.EVP_sha1();
    case Digest.sha256: return api.EVP_sha256();
    case Digest.sha512: return api.EVP_sha512();
    case Digest.md5: return api.EVP_md5();
    }
}

ubyte[] hmac(Digest d, const(ubyte)[] key, const(ubyte)[] data) @trusted
{
    auto m = md(d);
    ubyte[64] out_;
    uint len;
    if (api.HMAC(m, key.ptr, cast(int) key.length, data.ptr, data.length, out_.ptr, &len) is null)
        throw new CryptoError("HMAC failed");
    return out_[0 .. len].dup;
}

ubyte[] hmac(Digest d, string key, string data) => hmac(d, key.representation, data.representation);

ubyte[] digest(Digest d, const(ubyte)[] data) @trusted
{
    auto m = md(d);
    ubyte[64] out_;
    uint len;
    if (!api.EVP_Digest(data.ptr, data.length, out_.ptr, &len, m, null))
        throw new CryptoError("digest failed");
    return out_[0 .. len].dup;
}

ubyte[] sha256(const(ubyte)[] data) => digest(Digest.sha256, data);

ubyte[] pbkdf2(Digest d, const(ubyte)[] password, const(ubyte)[] salt, int rounds, int keyLen) @trusted
{
    auto m = md(d);
    auto out_ = new ubyte[keyLen];
    if (!api.PKCS5_PBKDF2_HMAC(cast(const(char)*) password.ptr, cast(int) password.length, salt.ptr,
            cast(int) salt.length, rounds, m, keyLen, out_.ptr))
        throw new CryptoError("PBKDF2 failed");
    return out_;
}

/// Cryptographically secure random bytes.
ubyte[] randomBytes(size_t n) @trusted
{
    ensureLoaded();
    auto b = new ubyte[n];
    if (api.RAND_bytes(b.ptr, cast(int) n) != 1)
        throw new CryptoError("RAND_bytes failed");
    return b;
}

/// `secrets.token_urlsafe(n)` / `base64.urlsafe_b64encode(os.urandom(n))`.
string tokenUrlsafe(size_t n, bool padded = false)
{
    auto s = Base64URL.encode(randomBytes(n)).idup;
    if (!padded)
        while (s.length && s[$ - 1] == '=')
            s = s[0 .. $ - 1];
    return s;
}

/// `secrets.choice(alphabet)` n times.
string randomString(size_t n, string alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
{
    auto r = new char[n];
    foreach (i; 0 .. n)
    {
        // rejection sampling for an unbiased choice
        for (;;)
        {
            auto b = randomBytes(1)[0];
            auto limit = 256 - (256 % alphabet.length);
            if (b < limit)
            {
                r[i] = alphabet[b % alphabet.length];
                break;
            }
        }
    }
    return r.idup;
}

/// uuid4 as 32 hex chars (`uuid.uuid4().hex`) or the dashed form.
string uuid4(bool dashed = true)
{
    import std.format : format;
    auto b = randomBytes(16);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    string hex;
    foreach (x; b)
        hex ~= format("%02x", x);
    if (!dashed)
        return hex;
    return hex[0 .. 8] ~ "-" ~ hex[8 .. 12] ~ "-" ~ hex[12 .. 16] ~ "-" ~ hex[16 .. 20] ~ "-" ~ hex[20 .. 32];
}

private ubyte[] cipher(const(EVP_CIPHER)* c, const(ubyte)[] key, const(ubyte)[] iv, const(ubyte)[] data, bool enc) @trusted
{
    auto ctx = api.EVP_CIPHER_CTX_new();
    if (ctx is null)
        throw new CryptoError("EVP_CIPHER_CTX_new failed");
    scope (exit)
        api.EVP_CIPHER_CTX_free(ctx);
    if (!api.EVP_CipherInit_ex(ctx, c, null, key.ptr, iv.ptr, enc ? 1 : 0))
        throw new CryptoError("cipher init failed");
    auto out_ = new ubyte[data.length + 32];
    int n, m;
    if (!api.EVP_CipherUpdate(ctx, out_.ptr, &n, data.ptr, cast(int) data.length))
        throw new CryptoError("cipher update failed");
    if (!api.EVP_CipherFinal_ex(ctx, out_.ptr + n, &m))
        throw new CryptoError("cipher final failed (wrong key?)");
    return out_[0 .. n + m];
}

/// pgadmin.utils.crypto.pad
ubyte[] padKey(const(ubyte)[] key)
{
    auto k = key.length > 32 ? key[0 .. 32].dup : key.dup;
    if (k.length == 16 || k.length == 24 || k.length == 32)
        return k;
    while (k.length < 32)
        k ~= '}';
    return k;
}

private const(EVP_CIPHER)* cfb8For(size_t keyLen) @trusted
{
    ensureLoaded();
    switch (keyLen)
    {
    case 16: return api.EVP_aes_128_cfb8();
    case 24: return api.EVP_aes_192_cfb8();
    default: return api.EVP_aes_256_cfb8();
    }
}

/// pgadmin.utils.crypto.encrypt: returns base64(iv + AES-CFB8(plaintext)).
string encrypt(const(ubyte)[] plaintext, const(ubyte)[] key)
{
    auto k = padKey(key);
    auto iv = randomBytes(16);
    auto ct = cipher(cfb8For(k.length), k, iv, plaintext, true);
    return Base64.encode(iv ~ ct).idup;
}

string encrypt(string plaintext, string key) => encrypt(plaintext.representation, key.representation);

/// pgadmin.utils.crypto.decrypt.
ubyte[] decrypt(string ciphertextB64, const(ubyte)[] key)
{
    auto raw = Base64.decode(ciphertextB64);
    if (raw.length < 16)
        throw new CryptoError("invalid ciphertext");
    auto k = padKey(key);
    return cipher(cfb8For(k.length), k, raw[0 .. 16], raw[16 .. $], false);
}

string decryptStr(string ciphertextB64, string key) => cast(string) decrypt(ciphertextB64, key.representation).idup;

/// AES-256-CBC with PKCS#7 padding (session bodies): iv(16) + ciphertext.
ubyte[] aesCbcEncrypt(const(ubyte)[] key32, const(ubyte)[] plaintext) @trusted
{
    ensureLoaded();
    auto iv = randomBytes(16);
    return iv ~ cipher(api.EVP_aes_256_cbc(), key32, iv, plaintext, true);
}

ubyte[] aesCbcDecrypt(const(ubyte)[] key32, const(ubyte)[] data) @trusted
{
    ensureLoaded();
    if (data.length < 32)
        throw new CryptoError("invalid ciphertext");
    return cipher(api.EVP_aes_256_cbc(), key32, data[0 .. 16], data[16 .. $], false);
}

/// HKDF-SHA256 (RFC 5869).
ubyte[] hkdfSha256(const(ubyte)[] ikm, const(ubyte)[] salt, const(ubyte)[] info, size_t length)
{
    auto prk = hmac(Digest.sha256, salt, ikm);
    ubyte[] okm, t;
    ubyte counter = 1;
    while (okm.length < length)
    {
        t = hmac(Digest.sha256, prk, t ~ info ~ [counter]);
        okm ~= t;
        counter++;
    }
    return okm[0 .. length];
}

/// Constant-time comparison.
bool constantTimeEquals(const(ubyte)[] a, const(ubyte)[] b)
{
    if (a.length != b.length)
        return false;
    ubyte r;
    foreach (i; 0 .. a.length)
        r |= a[i] ^ b[i];
    return r == 0;
}

bool constantTimeEquals(string a, string b) => constantTimeEquals(a.representation, b.representation);

// ------------------------------------------------------------ passwords

/// passlib's "adapted base64": standard alphabet with '.' instead of '+', no padding.
string ab64Encode(const(ubyte)[] b)
{
    auto s = Base64.encode(b).idup;
    while (s.length && s[$ - 1] == '=')
        s = s[0 .. $ - 1];
    return s.replace("+", ".");
}

ubyte[] ab64Decode(string s)
{
    s = s.replace(".", "+");
    while (s.length % 4)
        s ~= "=";
    return Base64.decode(s);
}

/// Flask-Security's `get_hmac`: base64(HMAC-SHA512(salt, password)).
string securityHmac(string password, string salt)
{
    return Base64.encode(hmac(Digest.sha512, salt.representation, password.representation)).idup;
}

/// Flask-Security `hash_password` with pbkdf2_sha512 (passlib default 25000 rounds, 16-byte salt).
string hashPassword(string password, string securitySalt, int rounds = 25_000)
{
    auto secret = securityHmac(password, securitySalt);
    auto salt = randomBytes(16);
    auto dk = pbkdf2(Digest.sha512, secret.representation, salt, rounds, 64);
    return "$pbkdf2-sha512$" ~ to!string(rounds) ~ "$" ~ ab64Encode(salt) ~ "$" ~ ab64Encode(dk);
}

/// Flask-Security `verify_password` for pbkdf2_sha512 (and pbkdf2_sha256) hashes.
bool verifyPassword(string password, string hash, string securitySalt)
{
    if (hash is null || hash.length == 0)
        return false;
    auto parts = hash.split("$");
    // ["", "pbkdf2-sha512", rounds, salt, checksum]
    if (parts.length != 5)
        return false;
    Digest d;
    size_t keyLen;
    if (parts[1] == "pbkdf2-sha512")
    {
        d = Digest.sha512;
        keyLen = 64;
    }
    else if (parts[1] == "pbkdf2-sha256")
    {
        d = Digest.sha256;
        keyLen = 32;
    }
    else
        return false;
    try
    {
        auto rounds = to!int(parts[2]);
        auto salt = ab64Decode(parts[3]);
        auto expected = ab64Decode(parts[4]);
        auto secret = securityHmac(password, securitySalt);
        auto dk = pbkdf2(d, secret.representation, salt, rounds, cast(int) keyLen);
        return constantTimeEquals(dk, expected);
    }
    catch (Exception)
        return false;
}

unittest
{
    auto salt = "aZ-KhpdJpnHK7BJOwyCx3-6nj6nlsznv7UJorjQab0g=";
    assert(securityHmac("secret123", salt)
            == "1UqJfR+Thi7JMiew6V68XJ7iiuWFHy0OsSZA/uAoQtTDPBaL8T0ZoUTCZ+aOE4wBjCOkA5ULP958q7Q87evv+w==");
    auto h = "$pbkdf2-sha512$25000$MDEyMzQ1Njc4OWFiY2RlZg$Um6h/NWb51iSqSEaZ1yTbU8KyoySxcoeOoftG3b3mVa7MNZxkvL5feh1v86KBlASJEvqzKPVoi0dloouq7.6Dw";
    assert(verifyPassword("secret123", h, salt));
    assert(!verifyPassword("secret124", h, salt));
    assert(verifyPassword("abc", hashPassword("abc", salt), salt));
    assert(decryptStr("AAECAwQFBgcICQoLDA0ODxmJeEqzsWR0X3Mi", "mykey") == "hello world");
    assert(decryptStr("AAECAwQFBgcICQoLDA0OD8hvNbpecJ1C8DxO", "0123456789abcdef") == "hello world");
    assert(decryptStr(encrypt("round trip", "k"), "k") == "round trip");
}

// ------------------------------------------------------------ Fernet (cryptography.fernet)

/// Fernet token: `base64url(0x80 | time(8) | iv(16) | AES-128-CBC(plaintext) | HMAC-SHA256)`; the key is
/// base64url(signing key(16) | encryption key(16)).
string fernetEncrypt(const(ubyte)[] plaintext, string fernetKeyB64)
{
    import std.base64 : Base64URL;
    import std.datetime : Clock;
    auto key = Base64URL.decode(fernetKeyB64);
    if (key.length != 32)
        throw new CryptoError("Fernet key must be 32 url-safe base64-encoded bytes.");
    ensureLoaded();
    auto iv = randomBytes(16);
    auto ct = cipher(api.EVP_aes_128_cbc(), key[16 .. 32], iv, plaintext, true);
    ubyte[] token = [0x80];
    auto now = cast(ulong) Clock.currTime.toUnixTime;
    foreach (i; 0 .. 8)
        token ~= cast(ubyte)(now >> (8 * (7 - i)));
    token ~= iv;
    token ~= ct;
    token ~= hmac(Digest.sha256, key[0 .. 16], token);
    return Base64URL.encode(token).idup;
}

ubyte[] fernetDecrypt(string tokenB64, string fernetKeyB64)
{
    import std.base64 : Base64URL;
    auto key = Base64URL.decode(fernetKeyB64);
    if (key.length != 32)
        throw new CryptoError("Fernet key must be 32 url-safe base64-encoded bytes.");
    auto padded = tokenB64;
    while (padded.length % 4)
        padded ~= "=";
    auto token = Base64URL.decode(padded);
    if (token.length < 1 + 8 + 16 + 16 + 32 || token[0] != 0x80)
        throw new CryptoError("Invalid token");
    auto body_ = token[0 .. $ - 32];
    if (!constantTimeEquals(hmac(Digest.sha256, key[0 .. 16], body_), token[$ - 32 .. $]))
        throw new CryptoError("Invalid token");
    ensureLoaded();
    return cipher(api.EVP_aes_128_cbc(), key[16 .. 32], token[9 .. 25], token[25 .. $ - 32], false);
}
