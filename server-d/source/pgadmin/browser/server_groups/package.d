/// `pgadmin/browser/server_groups`: the top level of the object tree.
module pgadmin.browser.server_groups;

import pgadmin.browser.utils;
import pgadmin.core.config;
import pgadmin.core.i18n;
import pgadmin.core.templates : renderTemplate;
import pgadmin.core.value;
import pgadmin.model;
import pgadmin.core.sqlite : SqliteIntegrity;
import pgadmin.utils.preferences;
import pgadmin.utils.server_access;
import pgadmin.web.auth;
import pgadmin.web.context;
import pgadmin.web.flask;
import pgadmin.web.http;
import pgadmin.browser.server_groups.servers : ServerModule;

enum SG_NOT_FOUND_ERROR = "The specified server group could not be found.";

struct IconInfo
{
    string icon;
    bool isShared;
}

/// `get_icon_css_class(is_shared_group)`
IconInfo getIconCssClass(bool isSharedGroup, string def = "icon-server_group")
{
    if (cfgBool("SERVER_MODE") && isSharedGroup)
        return IconInfo("icon-server_group_shared", true);
    return IconInfo(def, false);
}

final class ServerGroupModule : BrowserPluginModule
{
    enum NODE_TYPE = "server_group";

    this()
    {
        super(NODE_TYPE);
        staticDir("browser/server_groups");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => null;

    override string[] csssnippets()
    {
        string[] snippets = [renderTemplate("css/server_group.css")];
        foreach (m; submodules)
            if (auto b = cast(BrowserPluginModule) m)
                snippets ~= b.csssnippets;
        return snippets;
    }

    Value nodeFor(Value group)
    {
        auto ic = getIconCssClass(group["is_shared_group"].truthy);
        auto kw = new Dict;
        kw["can_delete"] = Value(!(group["is_first_user_group"].truthy || group["is_shared_group"].truthy));
        kw["can_edit"] = Value(!group["is_shared_group"].truthy);
        kw["is_shared"] = Value(ic.isShared);
        return generateBrowserNode(Value(group["id"].toString), Value(null), group["name"].str, ic.icon, true, NODE_TYPE, kw);
    }

    override Value[] getNodes(Dict kwargs)
    {
        Value[] nodes;
        foreach (g; ServerGroupView.getAllServerGroups())
            nodes ~= nodeFor(g);
        return nodes;
    }

    override void setup()
    {
        submodules ~= new ServerModule;
        registerNodeView!ServerGroupView(this);
    }
}

final class ServerGroupView : NodeView
{
    this()
    {
        super();
        nodeType = ServerGroupModule.NODE_TYPE;
        nodeLabel = "Server Group";
        nodeIcon_ = "icon-" ~ ServerGroupModule.NODE_TYPE;
        parentIds = [];
        ids = [IdSpec("int", "gid")];
    }

    private ServerGroupModule sgm() => cast(ServerGroupModule) bpModule;

    override Response callMethod(string name, Dict k)
    {
        if (!isAuthenticated())
            return unauthorisedResponse();
        switch (name)
        {
        case "list": return list();
        case "delete": return delete_(k["gid"]);
        case "update": return update(k["gid"]);
        case "properties": return properties(k["gid"]);
        case "create": return create();
        case "sql", "modified_sql", "statistics", "dependencies", "dependents":
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(null), 422);
        case "nodes": return nodes(k.has("gid") ? k["gid"] : Value(null));
        case "node": return nodes(k["gid"]);
        default: return super.callMethod(name, k);
        }
    }

    Response list()
    {
        Value[] res;
        foreach (sg; db.query("SELECT id, name FROM servergroup WHERE user_id = ? ORDER BY name", Value(currentUserId())))
            res ~= Value.dictOf("id", sg["id"], "name", sg["name"]);
        return makeResponse(Value(res), 200);
    }

    Response delete_(Value gid)
    {
        auto groups = db.query("SELECT * FROM servergroup WHERE user_id = ? ORDER BY id", Value(currentUserId()));
        auto first = groups.length ? groups[0] : Value(null);
        if (db.queryOne("SELECT 1 AS x FROM server WHERE servergroup_id = ? AND shared", gid).isDict)
            return makeJsonResponse(0, Value(gettext("The specified server group cannot be deleted. Shared servers are present in this group.")),
                    Value(""), Value(null), Value(null), 417);
        if (first.isDict && first["id"] == gid)
            return makeJsonResponse(0, Value(gettext("The specified server group cannot be deleted. The first server group is not deletable.")),
                    Value(""), Value(null), Value(null), 417);
        auto sg = db.queryOne("SELECT * FROM servergroup WHERE id = ? AND user_id = ?", gid, Value(currentUserId()));
        if (sg.isNone)
            return makeJsonResponse(0, Value(gettext(SG_NOT_FOUND_ERROR)), Value(""), Value(null), Value(null), 410);
        try
        {
            db.transaction({
                db.exec("DELETE FROM server WHERE servergroup_id = ?", gid);
                db.exec("DELETE FROM sharedserver WHERE servergroup_id = ?", gid);
                db.exec("DELETE FROM servergroup WHERE id = ?", gid);
            });
        }
        catch (Exception e)
            return makeJsonResponse(0, Value(e.msg), Value(""), Value(null), Value(null), 410);
        return makeJsonResponse(1, Value(""), Value(""), request().form.toDict);
    }

    Response update(Value gid)
    {
        auto sg = getServerGroup(gid, true);
        auto data = formOrJson(request());
        if (sg.isNone)
            return makeJsonResponse(0, Value(gettext(SG_NOT_FOUND_ERROR)), Value(""), Value(null), Value(null), 417);
        try
        {
            if (data.contains("name"))
            {
                db.exec("UPDATE servergroup SET name = ? WHERE id = ?", data["name"], gid);
                sg["name"] = data["name"];
            }
        }
        catch (SqliteIntegrity)
        {
            return badRequest(gettext("The specified server group already exists."));
        }
        catch (Exception e)
            return makeJsonResponse(0, Value(e.msg), Value(""), Value(null), Value(null), 410);
        auto ic = getIconCssClass(sg["is_shared_group"].truthy);
        auto kw = new Dict;
        kw["can_delete"] = Value(!(sg["is_first_user_group"].truthy || sg["is_shared_group"].truthy));
        kw["can_edit"] = Value(!sg["is_shared_group"].truthy);
        kw["is_shared"] = Value(ic.isShared);
        auto node = bpModule.generateBrowserNode(gid, Value(null), sg["name"].str, ic.icon, true, nodeType, kw);
        return jsonify(Value.dictOf("node", node));
    }

    Response properties(Value gid)
    {
        auto sg = getServerGroup(gid);
        if (sg.isNone)
            return makeJsonResponse(0, Value(gettext(SG_NOT_FOUND_ERROR)), Value(""), Value(null), Value(null), 410);
        return makeResponse(Value.dictOf("id", sg["id"], "name", sg["name"], "user_id", sg["user_id"]), 200);
    }

    Response create()
    {
        auto data = formOrJson(request());
        if (data["name"].toString != "")
        {
            try
            {
                db.exec("INSERT INTO servergroup (user_id, name) VALUES (?, ?)", Value(currentUserId()), data["name"]);
                auto groupId = db.lastInsertId();
                auto sg = getServerGroup(Value(groupId));
                data["id"] = sg["id"];
                data["name"] = sg["name"];
                return jsonify(Value.dictOf("node", sgm.nodeFor(sg)));
            }
            catch (SqliteIntegrity)
            {
                return badRequest(gettext("The specified server group already exists."));
            }
            catch (Exception e)
                return makeJsonResponse(0, Value(e.msg), Value(""), Value(null), Value(null), 410);
        }
        return makeJsonResponse(0, Value(gettext("No server group name was specified")), Value(""), Value(null),
                Value(null), 417);
    }

    static Value[] getAllServerGroups()
    {
        auto pref = Preferences.module_("browser");
        auto item = pref.preference("hide_shared_server");
        bool hideShared = item !is null && item.get().truthy;
        return getServerGroupsForUser(hideShared);
    }

    Response nodes(Value gid)
    {
        Value result;
        if (gid.isNone)
        {
            Value[] list;
            auto groups = cfgBool("SERVER_MODE") ? getAllServerGroups() : getServerGroupsForUser(true);
            foreach (g; groups)
                list ~= sgm.nodeFor(g);
            result = Value(list);
        }
        else
        {
            auto group = getServerGroup(gid);
            if (group.isNone)
                return gone(gettext("Could not find the server group."));
            result = sgm.nodeFor(group);
        }
        return makeJsonResponse(1, Value(""), Value(""), Value(null), result);
    }
}
