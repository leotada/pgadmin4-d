/// `schemas/packages/edbfuncs`: EPAS Package Functions and Procedures node module.
module pgadmin.browser.server_groups.servers.databases.schemas.packages.edbfuncs;

import std.array : join, split;
import std.conv : to;
import std.string : strip;
import pgadmin.browser.common;
import pgadmin.browser.utils;
import pgadmin.core.i18n;
import pgadmin.core.templates : renderTemplate, tv;
import pgadmin.core.value;
import pgadmin.db.driver : Connection, ServerManager, getDriver, Res;
import pgadmin.web.auth;
import pgadmin.web.http;

final class EdbFuncModule : CollectionNodeModule
{
    enum NODE_TYPE = "edbfunc";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "Functions";
        minVer = Value(90100);
        serverTypes = ["ppas"];
        staticDir("browser/server_groups/servers/databases/schemas/packages/edbfuncs");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => "package";
    override bool nodeInode() => false;
    override bool moduleUseTemplateJavascript() => false;

    override Value[] getNodes(Dict kwargs) => [generateBrowserCollectionNode(kwargs["pkgid"])];

    override void setup()
    {
        registerNodeView!EdbFuncView(this);
    }
}

final class EdbProcModule : CollectionNodeModule
{
    enum NODE_TYPE = "edbproc";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "Procedures";
        minVer = Value(90100);
        serverTypes = ["ppas"];
        staticDir("browser/server_groups/servers/databases/schemas/packages/edbfuncs");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => "package";
    override bool nodeInode() => false;
    override bool moduleUseTemplateJavascript() => false;

    override Value[] getNodes(Dict kwargs) => [generateBrowserCollectionNode(kwargs["pkgid"])];

    override void setup()
    {
        registerNodeView!EdbProcView(this);
    }
}

class EdbFuncView : PGChildNodeView
{
    this()
    {
        super();
        nodeType = EdbFuncModule.NODE_TYPE;
        nodeLabel = "Function";
        parentIds = [
            IdSpec("int", "gid"), IdSpec("int", "sid"), IdSpec("int", "did"),
            IdSpec("int", "scid"), IdSpec("int", "pkgid")
        ];
        ids = [IdSpec("int", "edbfnid")];
        setAllOps([
            makeOp("obj", ["get": "properties"], ["get": "list"]),
            makeOp("nodes", ["get": "nodes"], ["get": "nodes"]),
            makeOp("sql", ["get": "sql"]),
            makeOp("dependency", ["get": "dependencies"]),
            makeOp("dependent", ["get": "dependents"]),
        ]);
    }

    protected Response edbFuncPrecondition(Dict k)
    {
        if (!k.has("sid") || !k.has("did"))
            return preconditionRequired(gettext("Required properties are missing."));
        manager = getDriver().connectionManager(k["sid"].integer);
        if (manager is null)
            return gone(gettext("Could not find the server."));
        conn = manager.connection(null, null, true, k["did"]);
        if (!conn.connected())
            return preconditionRequired(gettext("Connection to the server has been lost."));

        string prefix = (nodeType == EdbProcModule.NODE_TYPE) ? "edbprocs" : "edbfuncs";
        templatePath = prefix ~ "/ppas/#" ~ to!string(manager.version_) ~ "#";
        return null;
    }

    private void formatArgumentsFromDb(Value data)
    {
        string[] proargtypes;
        if (data.contains("proargtypenames") && !data["proargtypenames"].isNone && data["proargtypenames"].toString.length > 0)
            proargtypes = data["proargtypenames"].toString.split(",");

        string[] proargmodes;
        if (data.contains("proargmodes") && data["proargmodes"].isList)
            foreach (m; data["proargmodes"].list.items)
                proargmodes ~= m.toString;

        string[] proargnames;
        if (data.contains("proargnames") && data["proargnames"].isList)
            foreach (n; data["proargnames"].list.items)
                proargnames ~= n.toString;

        string[] proargdefaultvals;
        if (data.contains("proargdefaultvals") && !data["proargdefaultvals"].isNone && data["proargdefaultvals"].toString.length > 0)
            proargdefaultvals = data["proargdefaultvals"].toString.split(",");

        string[string] proargmodenames = [
            "i": "IN", "o": "OUT", "b": "INOUT", "v": "VARIADIC", "t": "TABLE"
        ];

        string[] proargmodesFltrd;
        string[] proargnamesFltrd;
        foreach (i, m; proargmodes)
        {
            if (m == "v" || m == "o")
            {
                if (i <= proargdefaultvals.length)
                    proargdefaultvals = proargdefaultvals[0 .. i] ~ "" ~ proargdefaultvals[i .. $];
                else
                    proargdefaultvals ~= "";
                proargmodesFltrd ~= m;
            }
            else if (m == "t")
            {
                if (i < proargnames.length)
                    proargnamesFltrd ~= proargnames[i];
            }
            else
            {
                proargmodesFltrd ~= m;
            }
        }

        foreach (ref m; proargmodesFltrd)
            if (m in proargmodenames)
                m = proargmodenames[m];

        string[] newProargnames;
        foreach (n; proargnames)
        {
            bool removed = false;
            foreach (fn; proargnamesFltrd)
                if (n == fn) { removed = true; break; }
            if (!removed)
                newProargnames ~= n;
        }
        proargnames = newProargnames;

        while (proargmodesFltrd.length > proargdefaultvals.length)
            proargdefaultvals = "" ~ proargdefaultvals;

        Value[] argsList;
        string[] proargsStrList;

        for (size_t i = 0; i < proargtypes.length; ++i)
        {
            auto mode = (i < proargmodesFltrd.length) ? proargmodesFltrd[i] : "";
            auto ptype = proargtypes[i].strip();
            auto name = (i < proargnames.length) ? proargnames[i] : "";
            auto defval = (i < proargdefaultvals.length) ? proargdefaultvals[i] : "";
            if (mode == "INOUT" && defval == "-")
                defval = "";

            argsList ~= Value.dictOf(
                "argid", Value(cast(long) i),
                "argtype", Value(ptype),
                "argmode", Value(mode),
                "argname", Value(name),
                "argdefval", Value(defval)
            );

            string piece;
            if (mode.length) piece ~= mode ~ " ";
            if (name.length) piece ~= name ~ " ";
            if (ptype.length) piece ~= ptype ~ " ";
            if (defval.length) piece ~= "DEFAULT " ~ defval;
            proargsStrList ~= piece.strip();
        }

        data["arguments"] = Value(argsList);
        data["proargs"] = Value(proargsStrList.join(", "));
    }

    override Response callMethod(string name, Dict k)
    {
        if (!isAuthenticated())
            return unauthorisedResponse();

        auto err = edbFuncPrecondition(k);
        if (err !is null)
            return err;

        auto pkgid = k.has("pkgid") ? k["pkgid"] : Value(null);
        auto edbfnid = k.has("edbfnid") ? k["edbfnid"] : Value(null);

        switch (name)
        {
        case "list":
        {
            auto sql = renderTemplate(templatePath ~ "/node.sql", tv("pkgid", pkgid, "conn", conn));
            auto r = conn.executeDict(sql);
            if (!r.ok)
                return internalServerError(r.error);
            return makeResponse(r.value["rows"], 200);
        }
        case "nodes":
        {
            auto sql = renderTemplate(templatePath ~ "/node.sql",
                    tv("pkgid", pkgid, "fnid", edbfnid, "conn", conn));
            auto r = conn.execute2darray(sql);
            if (!r.ok)
                return internalServerError(r.error);

            if (!edbfnid.isNone)
            {
                if (r.value["rows"].length == 0)
                    return gone(gettext("Could not find the function"));
                auto row = r.value["rows"][0];
                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                        gbn(row["oid"], pkgid, row["name"].toString, "icon-" ~ nodeType), 200);
            }

            Value[] res;
            foreach (row; r.value["rows"].list.items)
                res ~= gbn(row["oid"], pkgid, row["name"].toString, "icon-" ~ nodeType);
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        case "properties":
        {
            auto sql = renderTemplate(templatePath ~ "/properties.sql",
                    tv("pkgid", pkgid, "edbfnid", edbfnid));
            auto r = conn.executeDict(sql);
            if (!r.ok)
                return internalServerError(r.error);
            if (r.value["rows"].length == 0)
                return gone(gettext("Could not find the function in the database."));
            auto row = r.value["rows"][0];
            formatArgumentsFromDb(row);
            return makeResponse(row, 200);
        }
        case "sql":
        {
            auto bodySql = renderTemplate(templatePath ~ "/get_body.sql", tv("edbfnid", edbfnid));
            auto br = conn.executeDict(bodySql);
            if (!br.ok)
                return internalServerError(br.error);
            if (br.value["rows"].length == 0)
                return gone(gettext("Could not find the function in the database."));

            string bodyText = br.value["rows"][0].contains("funcdef") && !br.value["rows"][0]["funcdef"].isNone
                ? br.value["rows"][0]["funcdef"].toString : "";

            auto nameSql = renderTemplate(templatePath ~ "/get_name.sql", tv("edbfnid", edbfnid));
            auto nr = conn.executeScalar(nameSql);
            if (!nr.ok)
                return internalServerError(nr.error);

            auto outSql = "-- Package " ~ (nodeType == EdbFuncModule.NODE_TYPE ? "Function" : "Procedure") ~
                          ": " ~ nr.value.toString;
            if (bodyText.length > 0)
                outSql ~= "\n\n" ~ bodyText;

            return makeResponse(Value(outSql), 200);
        }
        case "dependents":
            return makeResponse(getDependents(conn, edbfnid), 200);
        case "dependencies":
            return makeResponse(getDependencies(conn, edbfnid), 200);
        default:
            return super.callMethod(name, k);
        }
    }
}

final class EdbProcView : EdbFuncView
{
    this()
    {
        super();
        nodeType = EdbProcModule.NODE_TYPE;
        nodeLabel = "Procedure";
    }
}
