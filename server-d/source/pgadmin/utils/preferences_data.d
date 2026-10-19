/// Registers every preference of the application from a table generated from the Python implementation.
///
/// The preference definitions (names, labels, types, defaults, help texts, options) are declarative data spread over
/// ~100 modules in the original code. They were dumped from `Preferences.modules` of the Python application, once for
/// desktop mode and once for server mode, in registration order, and are embedded here (`resources/prefs_*.json`).
/// Definitions whose options depend on the configuration (languages, themes, binary paths) use the default
/// configuration. Regenerate with `tools/dump_prefs.py` when upgrading pgAdmin.
module pgadmin.utils.preferences_data;

import pgadmin.core.config;
import pgadmin.core.value;
import pgadmin.utils.preferences;

private __gshared bool done;

void registerAllPreferences()
{
    if (done)
        return;
    done = true;
    auto text = cfgBool("SERVER_MODE") ? import("prefs_server.json") : import("prefs_desktop.json");
    auto modules = parseJson(text);
    foreach (m; modules.list.items)
    {
        auto prefs = new Preferences(m["name"].str, m["label"]);
        foreach (c; m["categories"].list.items)
        {
            foreach (p; c["preferences"].list.items)
            {
                auto kw = new Dict;
                foreach (k; ["help_str", "control_props", "min_val", "max_val", "options", "select", "fields", "hidden",
                        "allow_blanks", "disabled", "dependents"])
                    kw[k] = p[k];
                kw["category_label"] = c["label"];
                prefs.register(c["name"].str, p["name"].str, p["label"], p["type"].str, p["default"], kw);
            }
        }
    }
}
