/// `schemas/packages/edbvars`: EPAS Package Variables node module.
module pgadmin.browser.server_groups.servers.databases.schemas.packages.edbvars;

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

final class EdbVarModule : CollectionNodeModule
{
    enum NODE_TYPE = "edbvar";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "Variables";
        minVer = Value(90100);
        serverTypes = ["ppas"];
        staticDir("browser/server_groups/servers/databases/schemas/packages/edbvars");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => "package";
    override bool nodeInode() => false;
    override bool moduleUseTemplateJavascript() => false;

    override Value[] getNodes(Dict kwargs) => [generateBrowserCollectionNode(kwargs["pkgid"])];

    override void setup()
    {
        registerNodeView!EdbVarView(this);
    }
}

final class EdbVarView : PGChildNodeView
{
    this()
    {
        super();
        nodeType = EdbVarModule.NODE_TYPE;
        nodeLabel = "Variable";
        parentIds = [
            IdSpec("int", "gid"), IdSpec("int", "sid"), IdSpec("int", "did"),
            IdSpec("int", "scid"), IdSpec("int", "pkgid")
        ];
        ids = [IdSpec("int", "varid")];
        setAllOps([
            makeOp("obj", ["get": "properties"], ["get": "list"]),
            makeOp("nodes", ["get": "nodes"], ["get": "nodes"]),
            makeOp("sql", ["get": "sql"]),
        ]);
    }

    private Response edbVarPrecondition(Dict k)
    {
        if (!k.has("sid") || !k.has("did"))
            return preconditionRequired(gettext("Required properties are missing."));
        manager = getDriver().connectionManager(k["sid"].integer);
        if (manager is null)
            return gone(gettext("Could not find the server."));
        conn = manager.connection(null, null, true, k["did"]);
        if (!conn.connected())
            return preconditionRequired(gettext("Connection to the server has been lost."));
        templatePath = "edbvars/ppas";
        return null;
    }

    override Response callMethod(string name, Dict k)
    {
        if (!isAuthenticated())
            return unauthorisedResponse();

        auto err = edbVarPrecondition(k);
        if (err !is null)
            return err;

        auto pkgid = k.has("pkgid") ? k["pkgid"] : Value(null);
        auto varid = k.has("varid") ? k["varid"] : Value(null);

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
            auto sql = renderTemplate(templatePath ~ "/node.sql", tv("pkgid", pkgid, "conn", conn));
            auto r = conn.execute2darray(sql);
            if (!r.ok)
                return internalServerError(r.error);
            Value[] res;
            foreach (row; r.value["rows"].list.items)
                res ~= gbn(row["oid"], pkgid, row["name"].toString, "icon-edbvar");
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        case "properties":
        {
            auto sql = renderTemplate(templatePath ~ "/properties.sql", tv("pkgid", pkgid, "varid", varid));
            auto r = conn.executeDict(sql);
            if (!r.ok)
                return internalServerError(r.error);
            if (r.value["rows"].length == 0)
                return gone(gettext("Could not find the variables"));
            return makeResponse(r.value["rows"][0], 200);
        }
        case "sql":
        {
            auto sql = renderTemplate(templatePath ~ "/properties.sql", tv("pkgid", pkgid, "varid", varid));
            auto r = conn.executeDict(sql);
            if (!r.ok)
                return internalServerError(r.error);
            if (r.value["rows"].length == 0)
                return gone(gettext("Could not find the variables"));
            auto var = r.value["rows"][0];
            auto outSql = "-- Package Variable: " ~ var["name"].toString ~ "\n\n" ~
                          var["name"].toString ~ " " ~ var["datatype"].toString ~ ";";
            return makeResponse(Value(outSql), 200);
        }
        default:
            return super.callMethod(name, k);
        }
    }
}
