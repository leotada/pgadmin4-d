/// `pgadmin/preferences`: the preferences dialog data and storage.
module pgadmin.preferences;

import std.algorithm : sort, SwapStrategy;
import std.conv : to;
import pgadmin.core.config;
import pgadmin.core.i18n;
import pgadmin.core.templates : renderTemplate;
import pgadmin.core.value;
import pgadmin.utils.constants;
import pgadmin.utils.preferences;
import pgadmin.web.auth;
import pgadmin.web.context : session, request;
import pgadmin.web.flask;
import pgadmin.web.http;

private string labelOf(Value p) => gettext(p["label"].toString);

private void sortByLabel(ref Value[] items)
{
    sort!((a, b) => labelOf(a) < labelOf(b), SwapStrategy.stable)(items);
}

final class PreferencesModule : Blueprint
{
    this()
    {
        super("preferences");
    }

    override string[] getExposedUrlEndpoints()
    {
        return ["preferences.index", "preferences.get_by_name", "preferences.get_all", "preferences.get_all_cli",
            "preferences.update_pref"];
    }

    override void setup()
    {
        route("/preferences.js", "script", ["GET"], loginRequired((Dict a) =>
                new Response(renderTemplate("preferences/preferences.js"), 200, MIMETYPE_APP_JS)));
        View index = loginRequired((Dict a) {
            if (a.has("module") && a.has("preference"))
            {
                try
                {
                    auto m = Preferences.module_(a["module"].str, false);
                    if (m is null)
                        return new Response("", 404);
                    auto p = m.preference(a["preference"].str);
                    if (p is null)
                        return new Response("", 404);
                    return makeResponse(p.toJson(), 200);
                }
                catch (Exception e)
                    return internalServerError(e.msg);
            }
            auto pref = Preferences.preferences();
            Value[] res;
            foreach (prefD; pref.list.items)
                if (prefD["categories"].length)
                    iterateCategories(prefD, res);
            sortByLabel(res);
            return makeResponse(Value(res), 200);
        });
        route("/", "index", ["GET"], index);
        route("/<module>/<preference>", "get_by_name", ["GET"], index);
        route("/get_all", "get_all", ["GET"], loginRequired((Dict a) {
            Value[] res;
            foreach (m; Preferences.preferences().list.items)
                foreach (c; m["categories"].list.items)
                    foreach (p; c["preferences"].list.items)
                    {
                        p["module"] = m["name"];
                        res ~= p;
                    }
            return makeResponse(Value(res), 200);
        }));
        route("/get_all_cli", "get_all_cli", ["GET"], loginRequired((Dict a) {
            auto res = new Dict;
            foreach (m; Preferences.preferences().list.items)
                foreach (c; m["categories"].list.items)
                    foreach (p; c["preferences"].list.items)
                        res[m["label"].toString ~ ":" ~ p["label"].toString ~ ":" ~ c["label"].toString]
                            = Value(m["name"].toString ~ ":" ~ c["name"].toString ~ ":" ~ p["name"].toString);
            return makeResponse(Value(res), 200);
        }), true);
        route("/", "update", ["PUT"], loginRequired((Dict a) {
            auto prefData = getData();
            Value[] items = prefData.isList ? prefData.list.items : [prefData];
            bool explicitProvider;
            foreach (i; items)
                if (i.get("name").toString == "default_provider")
                    explicitProvider = true;
            foreach (data; items)
            {
                if (isTitlePlaceholder(data["name"].toString) && data["value"].isString && isSpace(data["value"].str))
                    data["value"] = Value("");
                string msg;
                bool res = Preferences.save(data["mid"].integer, data["category_id"].integer, data["id"].integer,
                        data["value"], msg);
                if (data["name"].toString == "save_app_state" && data["value"].isBool && !data["value"].boolean)
                {
                    import pgadmin.settings : deleteToolData;
                    string m2;
                    deleteToolData(0, m2);
                }
                if (res && !explicitProvider)
                    setDefaultProviderFrom(data);
                if (!res)
                    return internalServerError(msg);
            }
            auto response = successReturn();
            auto lang = Preferences.module_("misc").preference("user_language");
            string language = "en";
            if (lang !is null && lang.get().truthy)
                language = lang.get().toString;
            CookieSpec c;
            c.name = "PGADMIN_LANGUAGE";
            c.value = language;
            c.path = cfgStr("SESSION_COOKIE_PATH");
            c.secure = cfgBool("SESSION_COOKIE_SECURE");
            c.httpOnly = cfgBool("SESSION_COOKIE_HTTPONLY");
            c.sameSite = cfgStr("SESSION_COOKIE_SAMESITE");
            response.setCookie(c);
            return response;
        }));
        route("/update", "update_pref", ["PUT"], loginRequired((Dict a) {
            auto pd = parseJson(getData()["pref_data"].toString);
            bool explicitProvider;
            foreach (i; pd.iterItems())
                if (i.get("name").toString == "default_provider")
                    explicitProvider = true;
            foreach (data; pd.iterItems())
            {
                if (isTitlePlaceholder(data["name"].toString) && data["value"].isString && isSpace(data["value"].str))
                    data["value"] = Value("");
                auto pm = Preferences.module_(data["module"].str);
                auto pref = pm.preference(data["name"].str);
                string err;
                pref.set(data["value"], err);
                if (!explicitProvider)
                    setDefaultProviderFrom(data);
            }
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value.dictOf("data", "Success"), 200);
        }));
        route("/", "reset_prefs", ["DELETE"], loginRequired((Dict a) {
            string err;
            if (!Preferences.reset(err))
                return internalServerError(err);
            return successReturn();
        }));
    }
}

private void iterateCategories(Value prefD, ref Value[] res)
{
    auto om = Value.newDict();
    om["id"] = prefD["id"];
    om["label"] = Value(gettext(prefD["label"].toString));
    om["inode"] = Value(true);
    om["open"] = Value(true);
    om["children"] = Value.newList();
    om["value"] = Value(gettext(prefD["label"].toString));
    om["name"] = prefD["name"];
    Value[] children;
    foreach (c; prefD["categories"].list.items)
    {
        foreach (p; c["preferences"].list.items)
        {
            if (p.contains("label") && !p["label"].isNone)
                p["label"] = Value(gettext(p["label"].toString));
            if (p.contains("help_str") && !p["help_str"].isNone)
                p["help_str"] = Value(gettext(p["help_str"].toString));
        }
        auto prefs = c["preferences"].list.items.dup;
        sortByLabel(prefs);
        auto oc = Value.newDict();
        oc["id"] = c["id"];
        oc["mid"] = prefD["id"];
        oc["name"] = c["name"];
        oc["label"] = Value(gettext(c["label"].toString));
        oc["value"] = Value(c["id"].toString ~ gettext(c["label"].toString));
        oc["inode"] = Value(false);
        oc["open"] = Value(false);
        oc["preferences"] = Value(prefs);
        oc["showCheckbox"] = Value(false);
        children ~= oc;
    }
    sortByLabel(children);
    om["children"] = Value(children);
    res ~= om;
}

private Value getData()
{
    auto req = request();
    auto d = req.form.empty ? parseJson(req.text) : req.form.toDict;
    if (!d.truthy)
        throw new Exception("Please provide the valid preferences data to save.");
    return d;
}

private bool isTitlePlaceholder(string n)
{
    return n == "vw_edt_tab_title_placeholder" || n == "qt_tab_title_placeholder" || n == "debugger_tab_title_placeholder";
}

private bool isSpace(string s)
{
    import std.uni : isWhite;
    if (s.length == 0)
        return false;
    foreach (dchar c; s)
        if (!isWhite(c))
            return false;
    return true;
}

private void setDefaultProviderFrom(Value data)
{
    static immutable string[string] providerMap = [
        "anthropic_api_key_file": "anthropic", "openai_api_key_file": "openai", "ollama_api_url": "ollama",
        "docker_api_url": "docker",
    ];
    auto name = data["name"].toString;
    if (auto p = name in providerMap)
        if (data["value"].truthy)
        {
            auto ai = Preferences.module_("ai", false);
            if (ai !is null)
            {
                auto dp = ai.preference("default_provider");
                string err;
                if (dp !is null && !dp.get().truthy)
                    dp.set(Value(*p), err);
            }
        }
}
