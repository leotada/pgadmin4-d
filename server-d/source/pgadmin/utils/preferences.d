/// Per-module user preferences (`pgadmin/utils/preferences.py`).
///
/// Modules register preferences at start-up (ids live in module_preference / preference_category / preferences);
/// values are per user in user_preferences, stored as text and converted back by type on read.
module pgadmin.utils.preferences;

import std.algorithm : canFind;
import std.array : split, replace;
import std.conv : to;
import std.string : strip;
import pgadmin.core.log;
import pgadmin.core.value;
import pgadmin.model : db;
import pgadmin.web.context : currentUserId;

private immutable string[] allowedTypes = [
    "boolean", "integer", "numeric", "date", "datetime", "options", "multiline", "switch", "node", "text",
    "radioModern", "keyboardshortcut", "select", "selectFile", "threshold"
];

/// One registered preference (`_Preference`).
final class Preference
{
    long cid;
    long pid;
    string name;
    Value default_;
    Value label;
    string type;
    Value helpStr, controlProps, minVal, maxVal, options, select, fields, hidden, allowBlanks, disabled, dependents;

    this(long cid, string name, Value label, string type, Value default_, Dict kw)
    {
        this.cid = cid;
        this.name = name;
        this.label = label;
        this.type = type;
        this.default_ = default_;
        Value k(string n, Value d = Value(null)) => kw is null ? d : kw.get(n, d);
        helpStr = k("help_str");
        controlProps = k("control_props");
        minVal = k("min_val");
        maxVal = k("max_val");
        options = k("options");
        select = k("select");
        fields = k("fields");
        hidden = k("hidden");
        allowBlanks = k("allow_blanks");
        disabled = k("disabled", Value(false));
        dependents = k("dependents");

        auto row = db.queryOne("SELECT id FROM preferences WHERE name = ? AND cid = ?", Value(name), Value(cid));
        if (row.isNone)
        {
            db.exec("INSERT INTO preferences (cid, name) VALUES (?, ?)", Value(cid), Value(name));
            row = db.queryOne("SELECT id FROM preferences WHERE name = ? AND cid = ?", Value(name), Value(cid));
        }
        pid = row["id"].integer;
    }

    /// The value for the current user (or the default).
    Value get() => getFor(currentUserId());

    Value getFor(long uid)
    {
        if (uid < 0)
            return default_;
        auto row = db.queryOne("SELECT value FROM user_preferences WHERE pid = ? AND uid = ?", Value(pid), Value(uid));
        if (row.isNone)
            return default_;
        auto value = row["value"].toString;

        // _get_format_data
        if (type == "boolean" || type == "switch" || type == "node")
            return Value(value == "True");
        if (type == "options")
        {
            if (options.isList)
                foreach (opt; options.list.items)
                    if (opt.isDict && opt.contains("value") && opt["value"] == Value(value))
                        return Value(value);
            if (controlProps.isDict && controlProps.get("creatable").truthy)
                return Value(value);
            if (select.isDict && select.get("tags").truthy)
                return Value(value);
            return default_;
        }
        if (type == "select")
        {
            if (value.length)
            {
                auto v = value.replace("[", "").replace("]", "").replace("'", "");
                Value[] r;
                foreach (x; v.split(","))
                    r ~= Value(x.strip);
                return Value(r);
            }
            return Value(null);
        }
        if (type == "text" && value == "" && !allowBlanks.truthy)
            return default_;
        try
        {
            switch (type)
            {
            case "integer": return Value(to!long(value.strip));
            case "numeric":
                // Python returns decimal.Decimal; it serializes as a float
                return Value(to!double(value.strip));
            case "keyboardshortcut": return parseJson(value);
            default: return Value(value);
            }
        }
        catch (Exception e)
        {
            logException(e);
            return default_;
        }
    }

    private Value normalizeRange(Value v)
    {
        if (!minVal.isNone && v.opCmp(minVal) < 0)
            return minVal;
        if (!maxVal.isNone && v.opCmp(maxVal) > 0)
            return maxVal;
        return v;
    }

    /// Stores `value` for the current user (or `userId`); returns false with a message on a type error.
    bool set(Value value, out string err, long userId = -1)
    {
        string text;
        try
        {
            if (type == "boolean" || type == "switch" || type == "node")
            {
                if (!value.isBool)
                    throw new Exception("not a bool");
                text = value.boolean ? "True" : "False";
            }
            else if (type == "options")
            {
                bool has;
                if (options.isList)
                    foreach (opt; options.list.items)
                        if (opt.isDict && opt.contains("value") && opt["value"] == value)
                            has = true;
                if (!(has || (controlProps.isDict && (controlProps.get("tags").truthy
                        || controlProps.get("creatable").truthy))))
                    throw new Exception("not an option");
                text = value.toString;
            }
            else if (type == "integer")
            {
                auto v = Value(value.integer);
                if (value.isFloat || (value.isString && !isIntText(value.str)))
                    throw new Exception("not an integer");
                text = normalizeRange(v).toString;
            }
            else if (type == "numeric")
            {
                auto v = Value(value.floating);
                text = normalizeRange(v).toString;
            }
            else if (type == "keyboardshortcut")
                text = value.toJsonSpaced();
            else
                text = value.toString;
        }
        catch (Exception e)
        {
            logException(e);
            err = "Invalid value for " ~ (type == "keyboardshortcut" ? "keyboard shortcut" : type) ~ " option.";
            return false;
        }

        auto uid = userId >= 0 ? userId : currentUserId();
        auto existing = db.queryOne("SELECT pid FROM user_preferences WHERE pid = ? AND uid = ?", Value(pid), Value(uid));
        if (existing.isNone)
            db.exec("INSERT INTO user_preferences (pid, uid, value) VALUES (?, ?, ?)", Value(pid), Value(uid),
                    Value(text));
        else
            db.exec("UPDATE user_preferences SET value = ? WHERE pid = ? AND uid = ?", Value(text), Value(pid),
                    Value(uid));
        return true;
    }

    private static bool isIntText(string s)
    {
        try
        {
            to!long(s.strip);
            return true;
        }
        catch (Exception)
            return false;
    }

    Value toJson()
    {
        auto d = new Dict;
        d["id"] = Value(pid);
        d["cid"] = Value(cid);
        d["name"] = Value(name);
        d["label"] = label.truthy ? label : Value(name);
        d["type"] = Value(type);
        d["help_str"] = helpStr;
        d["control_props"] = controlProps;
        d["min_val"] = minVal;
        d["max_val"] = maxVal;
        d["options"] = options;
        d["select"] = select;
        d["value"] = get();
        d["fields"] = fields;
        d["hidden"] = hidden;
        d["disabled"] = disabled;
        d["dependents"] = dependents;
        return Value(d);
    }
}

private final class Category
{
    long id;
    string name;
    Value label;
    Preference[string] prefs;
    string[] order;
}

/// The preferences of one module (`Preferences`).
final class Preferences
{
    private __gshared Preferences[string] modules_;
    private __gshared string[] moduleOrder;

    string name;
    Value label;
    long mid;
    private Category[string] categories;
    private string[] catOrder;

    this(string name, Value label = Value(null))
    {
        this.name = name;
        this.label = label;
        auto row = db.queryOne("SELECT id FROM module_preference WHERE name = ?", Value(name));
        if (row.isNone)
        {
            db.exec("INSERT INTO module_preference (name) VALUES (?)", Value(name));
            row = db.queryOne("SELECT id FROM module_preference WHERE name = ?", Value(name));
        }
        mid = row["id"].integer;
        if (auto m = name in modules_)
        {
            categories = (*m).categories;
            catOrder = (*m).catOrder;
        }
        else
        {
            modules_[name] = this;
            moduleOrder ~= name;
        }
    }

    Value toJson()
    {
        auto res = new Dict;
        res["id"] = Value(mid);
        res["label"] = label.truthy ? label : Value(name);
        res["name"] = Value(name);
        auto cats = new List;
        auto src = modules_.get(name, this);
        foreach (cn; src.catOrder)
        {
            auto cat = src.categories[cn];
            auto interm = new Dict;
            interm["id"] = Value(cat.id);
            interm["name"] = Value(cat.name);
            interm["label"] = cat.label.truthy ? cat.label : Value(cat.name);
            auto plist = new List;
            foreach (pn; cat.order)
            {
                auto pj = cat.prefs[pn].toJson();
                pj["mid"] = Value(mid);
                pj["cid"] = Value(cat.id);
                plist.items ~= pj;
            }
            interm["preferences"] = Value(plist);
            cats.items ~= Value(interm);
        }
        res["categories"] = Value(cats);
        return Value(res);
    }

    private Category category(string cname, Value clabel)
    {
        auto src = modules_.get(name, this);
        if (auto c = cname in src.categories)
        {
            if (!(*c).label.truthy)
                (*c).label = clabel;
            return *c;
        }
        auto row = db.queryOne("SELECT id FROM preference_category WHERE mid = ? AND name = ?", Value(mid), Value(cname));
        if (row.isNone)
        {
            db.exec("INSERT INTO preference_category (mid, name) VALUES (?, ?)", Value(mid), Value(cname));
            row = db.queryOne("SELECT id FROM preference_category WHERE mid = ? AND name = ?", Value(mid), Value(cname));
        }
        auto c = new Category;
        c.id = row["id"].integer;
        c.name = cname;
        c.label = clabel;
        src.categories[cname] = c;
        src.catOrder ~= cname;
        if (src !is this)
        {
            categories = src.categories;
            catOrder = src.catOrder;
        }
        return c;
    }

    /// `register(category, name, label, _type, default, **kwargs)`; `kw` holds the keyword arguments
    /// (help_str, min_val, max_val, options, select, fields, hidden, allow_blanks, disabled, dependents,
    /// control_props, category_label).
    Preference register(string cat, string pname, Value plabel, string type, Value default_, Dict kw = null)
    {
        auto c = category(cat, kw is null ? Value(null) : kw.get("category_label"));
        if (auto p = pname in c.prefs)
            return *p;
        assert(allowedTypes.canFind(type), "Type cannot be found in the defined list!");
        if (kw is null)
            kw = new Dict;
        if (!kw.has("control_props"))
            kw["control_props"] = Value.newDict();
        auto p = new Preference(c.id, pname, plabel, type, default_, kw);
        c.prefs[pname] = p;
        c.order ~= pname;
        return p;
    }

    Preference register(string cat, string pname, string plabel, string type, Value default_, Dict kw = null)
    {
        return register(cat, pname, Value(plabel), type, default_, kw);
    }

    /// `preference(name)`: the registered preference, or null.
    Preference preference(string pname)
    {
        auto src = modules_.get(name, this);
        foreach (cn; src.catOrder)
            if (auto p = pname in src.categories[cn].prefs)
                return *p;
        return null;
    }

    /// All modules' preferences as JSON (`Preferences.preferences()`).
    static Value preferences()
    {
        Value[] r;
        foreach (n; moduleOrder)
            r ~= modules_[n].toJson();
        return Value(r);
    }

    static Preferences[] allModules()
    {
        Preferences[] r;
        foreach (n; moduleOrder)
            r ~= modules_[n];
        return r;
    }

    /// `Preferences.module(name, create)`.
    static Preferences module_(string name, bool create = true)
    {
        if (auto m = name in modules_)
        {
            if (!(*m).label.truthy)
                (*m).label = Value(name);
            return *m;
        }
        if (create)
            return new Preferences(name);
        return null;
    }

    /// `register_preference(module, category, name, label, _type, **kwargs)`.
    static Preference registerPreference(string module_, string cat, string pname, Value plabel, string type, Dict kw)
    {
        Preferences m;
        if (auto p = module_ in modules_)
        {
            m = *p;
            if (!m.label.truthy && kw !is null)
                m.label = kw.get("module_label");
        }
        else
            m = new Preferences(module_, kw is null ? Value(null) : kw.get("module_label"));
        return m.register(cat, pname, plabel, type, kw is null ? Value(null) : kw.get("default"), kw);
    }

    /// `raw_value(module, preference, category, user_id)`: the stored text or None.
    static Value rawValue(string module_, string pref, string cat = null, long userId = -1)
    {
        auto m = db.queryOne("SELECT id FROM module_preference WHERE name = ?", Value(module_));
        if (m.isNone)
            return Value(null);
        if (cat is null)
            cat = module_;
        if (userId < 0)
        {
            userId = currentUserId();
            if (userId < 0)
                return Value(null);
        }
        auto c = db.queryOne("SELECT id FROM preference_category WHERE mid = ? AND name = ?", m["id"], Value(cat));
        if (c.isNone)
            return Value(null);
        auto p = db.queryOne("SELECT id FROM preferences WHERE name = ? AND cid = ?", Value(pref), c["id"]);
        if (p.isNone)
            return Value(null);
        auto up = db.queryOne("SELECT value FROM user_preferences WHERE pid = ? AND uid = ?", p["id"], Value(userId));
        return up.isNone ? Value(null) : up["value"];
    }

    private static Preference findById(long mid, long cid, long pid, out string err)
    {
        auto row = db.queryOne("SELECT name FROM module_preference WHERE id = ?", Value(mid));
        if (row.isNone)
        {
            err = "Could not find the specified module.";
            return null;
        }
        auto mname = row["name"].str;
        auto m = mname in modules_;
        if (m is null)
        {
            err = "Module '" ~ mname ~ "' is no longer in use.";
            return null;
        }
        Category category;
        foreach (cn; (*m).catOrder)
            if ((*m).categories[cn].id == cid)
                category = (*m).categories[cn];
        if (category is null)
        {
            err = "Module '" ~ mname ~ "' does not have category with id '" ~ to!string(cid) ~ "'";
            return null;
        }
        foreach (pn; category.order)
            if (category.prefs[pn].pid == pid)
                return category.prefs[pn];
        err = "Could not find the specified preference.";
        return null;
    }

    /// `Preferences.save(mid, cid, pid, value)`.
    static bool save(long mid, long cid, long pid, Value value, out string err)
    {
        auto p = findById(mid, cid, pid, err);
        if (p is null)
            return false;
        try
        {
            string e2;
            p.set(value, e2); // like Python, a type error is logged but not reported here
        }
        catch (Exception e)
        {
            logException(e);
            err = e.msg;
            return false;
        }
        return true;
    }

    static bool saveCli(long mid, long cid, long pid, long userId, Value value, out string err)
    {
        auto p = findById(mid, cid, pid, err);
        if (p is null)
            return false;
        return p.set(value, err, userId);
    }

    /// Removes every stored preference of the current user.
    static bool reset(out string err)
    {
        try
        {
            db.exec("DELETE FROM user_preferences WHERE uid = ?", Value(currentUserId()));
            return true;
        }
        catch (Exception e)
        {
            logException(e);
            err = e.msg;
            return false;
        }
    }

    void migrateUserPreferences(long pid, string delegate(string) converter)
    {
        foreach (r; db.query("SELECT uid, value FROM user_preferences WHERE pid = ?", Value(pid)))
            db.exec("UPDATE user_preferences SET value = ? WHERE pid = ? AND uid = ?",
                    Value(converter(r["value"].toString)), Value(pid), r["uid"]);
    }
}
