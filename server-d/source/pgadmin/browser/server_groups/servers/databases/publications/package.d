/// `databases/publications`: logical replication publications.
module pgadmin.browser.server_groups.servers.databases.publications;

import pgadmin.browser.common;

final class PublicationModule : CollectionNodeModule
{
    enum NODE_TYPE = "publication";

    this()
    {
        super(NODE_TYPE);
        collectionLabelText = "Publications";
        minVer = Value(100000);
        minPpasVer = Value(100000);
        maxVer = Value(null);
        staticDir("browser/server_groups/servers/databases/publications");
    }

    override string nodeType() => NODE_TYPE;
    override string scriptLoad() => "database";
    override bool nodeInode() => false;
    override bool moduleUseTemplateJavascript() => false;

    override Value[] getNodes(Dict kwargs)
    {
        if (hasNodes(kwargs["sid"], kwargs["did"], Value(null), Value(null), Value(null), PublicationView.BASE_TEMPLATE_PATH))
            return [generateBrowserCollectionNode(kwargs["did"])];
        return null;
    }

    override void setup()
    {
        registerNodeView!PublicationView(this);
    }
}

final class PublicationView : PGChildNodeView
{
    enum BASE_TEMPLATE_PATH = "publications/{0}/#{1}#/sql";
    enum GET_PUB_SCHEMAS_SQL = "get_pub_schemas.sql";

    this()
    {
        super();
        nodeType = PublicationModule.NODE_TYPE;
        parentIds = [IdSpec("int", "gid"), IdSpec("int", "sid"), IdSpec("int", "did")];
        ids = [IdSpec("int", "pbid")];
        setAllOps([
            makeOp("obj", ["get": "properties", "delete": "delete", "put": "update"],
                    ["get": "list", "post": "create", "delete": "delete"]),
            makeOp("nodes", ["get": "node"], ["get": "nodes"]),
            makeOp("sql", ["get": "sql"]),
            makeOp("msql", ["get": "msql"], ["get": "msql"]),
            makeOp("stats", ["get": "statistics"]),
            makeOp("dependency", ["get": "dependencies"]),
            makeOp("dependent", ["get": "dependents"]),
            makeOp("get_schemas", null, ["get": "get_schemas"]),
            makeOp("get_tables", null, ["get": "get_tables"]),
            makeOp("get_all_columns", null, ["get": "get_all_columns"]),
            makeOp("delete", ["delete": "delete"], ["delete": "delete"]),
        ]);
    }

    private static string notFoundPub() => gettext("Could not find the publication information.");

    override Response callMethod(string name, Dict k)
    {
        if (!isAuthenticated())
            return unauthorisedResponse();
        auto err = standardPrecondition(k, name, BASE_TEMPLATE_PATH);
        if (err !is null)
            return err;
        auto did = k["did"];
        auto pbid = k.has("pbid") ? k["pbid"] : Value(null);
        switch (name)
        {
        case "list":
        {
            auto r = conn.executeDict(rt(PROPERTIES_SQL));
            if (!r.ok)
                return internalServerError(r.error);
            foreach (row; r.value["rows"].list.items)
                if (!row["all_table"].truthy)
                {
                    auto t = conn.executeDict(rt(GET_TABLE_FOR_PUBLICATION, tv("pbid", row["oid"])));
                    string[] names;
                    foreach (tr; t.value["rows"].list.items)
                        names ~= tr["table_name"].toString;
                    row["pubtable"] = Value(names.join(", "));
                }
            return makeResponse(r.value["rows"], 200);
        }
        case "nodes":
        {
            auto r = conn.execute2darray(rt(NODES_SQL));
            if (!r.ok)
                return internalServerError(r.error);
            Value[] res;
            foreach (row; r.value["rows"].list.items)
                res ~= gbn(row["oid"], did, row["name"].toString, "icon-publication");
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        case "node":
        {
            auto r = conn.execute2darray(rt(PROPERTIES_SQL, tv("pbid", pbid)));
            if (!r.ok)
                return internalServerError(r.error);
            foreach (row; r.value["rows"].list.items)
                return makeJsonResponse(1, Value(""), Value(""), Value(null),
                        gbn(row["oid"], did, row["name"].toString, "icon-publication"), 200);
            return gone(gettext("Could not find the specified publication."));
        }
        case "properties":
        {
            Response e2;
            auto res = fetchProperties(pbid, e2);
            if (e2 !is null)
                return e2;
            return makeResponse(res, 200);
        }
        case "create": return create(did);
        case "update": return update(did, pbid);
        case "delete": return delete_(pbid);
        case "msql":
        {
            auto data = msqlData("description");
            try
            {
                Response e2;
                string nm;
                auto sql = getSql(data, pbid, nm, e2);
                if (e2 !is null)
                    return e2;
                if (sql == "")
                    sql = "--modified SQL";
                return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(sql), 200);
            }
            catch (HTTPException e)
                throw e;
            catch (Exception e)
                return internalServerError(e.msg);
        }
        case "sql": return sqlView(pbid);
        case "dependents": return makeResponse(getDependents(conn, pbid), 200);
        case "dependencies":
        {
            Response e2;
            auto res = pubDependencies(pbid, e2);
            if (e2 !is null)
                return e2;
            return makeResponse(res, 200);
        }
        case "get_schemas":
        {
            auto r = conn.execute2darray(rt("get_all_schemas.sql", tv("conn", conn)));
            if (!r.ok)
                return internalServerError(r.error);
            Value[] res;
            foreach (row; r.value["rows"].list.items)
                res ~= Value.dictOf("label", row["nspname"], "value", row["nspname"]);
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        case "get_tables":
        {
            auto r = conn.execute2darray(rt("get_all_tables.sql",
                    tv("show_sys_objects", Value(blueprint.showSystemObjectsFlag), "server_type", manager.serverType)));
            if (!r.ok)
                return internalServerError(r.error);
            Value[] res;
            foreach (row; r.value["rows"].list.items)
                res ~= Value.dictOf("label", row["table"], "value", row["table"], "tid", row["tid"]);
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        case "get_all_columns":
        {
            auto args = request().args;
            if (!args.has("tid"))
                throw new HTTPException(400);
            auto r = conn.execute2darray(rt("get_all_columns.sql", tv("tid", args.get("tid"), "conn", conn)));
            if (!r.ok)
                return internalServerError(r.error);
            Value[] res;
            foreach (row; r.value["rows"].list.items)
                res ~= Value.dictOf("label", row["column"], "value", row["column"]);
            return makeJsonResponse(1, Value(""), Value(""), Value(null), Value(res), 200);
        }
        default: return super.callMethod(name, k);
        }
    }

    private Value schemaNames(Value pbid)
    {
        Value[] names;
        if (manager.version_ >= 150000)
        {
            auto s = conn.executeDict(rt(GET_PUB_SCHEMAS_SQL, tv("pbid", pbid)));
            foreach (row; s.value["rows"].list.items)
                names ~= row["sname"];
        }
        return Value(names);
    }

    /// Tables of a publication as `pubtable` entries.
    private Value tableEntries(Value pbid)
    {
        auto t = conn.executeDict(rt(GET_TABLE_FOR_PUBLICATION, tv("pbid", pbid)));
        Value[] pub;
        foreach (table; t.value["rows"].list.items)
        {
            if (table.contains("columns") && table.contains("where"))
                pub ~= Value.dictOf("table_name", table["table_name"], "columns", table["columns"], "where", table["where"]);
            else
                pub ~= table["table_name"];
        }
        return Value(pub);
    }

    Value fetchProperties(Value pbid, out Response err)
    {
        auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("pbid", pbid)));
        if (!r.ok)
        {
            err = internalServerError(r.error);
            return Value(null);
        }
        if (r.value["rows"].length == 0)
        {
            err = gone(notFoundPub());
            return Value(null);
        }
        auto row = r.value["rows"][0];
        if (!row["all_table"].truthy)
        {
            if (manager.version_ >= 150000)
            {
                auto names = schemaNames(pbid);
                if (names.length != 0)
                    row["pubschema"] = names;
            }
            auto pub = tableEntries(pbid);
            string[] tnames;
            auto t = conn.executeDict(rt(GET_TABLE_FOR_PUBLICATION, tv("pbid", pbid)));
            foreach (table; t.value["rows"].list.items)
                tnames ~= table["table_name"].toString;
            row["pubtable"] = pub;
            row["pubtable_names"] = Value(tnames.join(", "));
        }
        return row;
    }

    private Response create(Value did)
    {
        auto data = formOrJson(request());
        auto miss = missingArg(data, ["name"]);
        if (miss !is null)
            return miss;
        try
        {
            auto c = conn.executeDict(rt(CREATE_SQL, tv("data", data, "conn", conn)));
            if (!c.ok)
                return internalServerError(c.error);
            auto p = conn.executeDict(rt("get_position.sql", tv("conn", conn, "pubname", data["name"])));
            if (!p.ok)
                return internalServerError(p.error);
            auto row = p.value["rows"][0];
            return jsonify(Value.dictOf("node", gbn(row["oid"], did, row["name"].toString, "icon-publication")));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Response update(Value did, Value pbid)
    {
        auto data = formOrJson(request());
        try
        {
            Response e2;
            string name;
            auto sql = getSql(data, pbid, name, e2);
            if (e2 !is null)
                return e2;
            sql = sql.strip("\n").strip(" ");
            auto x = conn.executeDict(sql);
            if (!x.ok)
                return internalServerError(x.error);
            return jsonify(Value.dictOf("node", gbn(pbid, did, name, "icon-" ~ nodeType)));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    Response delete_(Value pbidArg, bool onlySql = false)
    {
        Value data = pbidArg.isNone ? formOrJson(request()) : Value.dictOf("ids", Value([pbidArg]));
        bool cascade = checkCascadeOperation();
        try
        {
            foreach (pbid; data["ids"].iterItems())
            {
                auto n = conn.executeScalar(rt(DELETE_SQL, tv("pbid", pbid, "conn", conn)));
                if (!n.ok)
                    return internalServerError(n.error);
                auto sql = rt(DELETE_SQL, tv("pname", n.value, "cascade", cascade, "conn", conn));
                if (onlySql)
                    return Response.sqlOnly(sql);
                auto x = conn.executeScalar(sql);
                if (!x.ok)
                    return internalServerError(x.error);
            }
            return makeJsonResponse(1, Value(""), Value(gettext("Publication dropped")));
        }
        catch (HTTPException e)
            throw e;
        catch (Exception e)
            return internalServerError(e.msg);
    }

    private Value oldTableData(Value res, Value schemaList)
    {
        auto row = res["rows"][0];
        row["pubtable"] = tableEntries(row["oid"]);
        auto oldData = row.shallowCopy();
        if (oldData.contains("all_table") && oldData["all_table"].truthy)
            oldData["pubtable"] = Value("");
        return oldData;
    }

    string getSql(Value data, Value pbid, out string name, out Response err)
    {
        if (!pbid.isNone)
        {
            auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("pbid", pbid)));
            if (!r.ok)
            {
                err = internalServerError(r.error);
                return null;
            }
            if (r.value["rows"].length == 0)
            {
                err = gone(notFoundPub());
                return null;
            }
            auto snames = schemaNames(pbid);
            auto oldData = oldTableData(r.value, snames);
            if (snames.length != 0)
                oldData["pubschema"] = snames;

            bool dropTable, addTable, updateTable;
            Value[] dropTableData, addTableData, updateTableData;
            auto oldTables = oldData["pubtable"];
            if (manager.version_ < 150000)
            {
                if (oldTables.type != VType.str)
                    foreach (table; oldTables.iterItems())
                        if (data.contains("pubtable") && !data["pubtable"].contains(table))
                        {
                            dropTableData ~= table;
                            dropTable = true;
                        }
                if (data.contains("pubtable"))
                    foreach (table; data["pubtable"].iterItems())
                        if (!oldTables.contains(table))
                        {
                            addTableData ~= table;
                            addTable = true;
                        }
            }
            else
            {
                if (data.contains("pubtable") && data["pubtable"].contains("deleted"))
                    foreach (table; data["pubtable"]["deleted"].iterItems())
                    {
                        dropTableData ~= table;
                        dropTable = true;
                    }
                if (data.contains("pubtable") && data["pubtable"].contains("changed"))
                {
                    foreach (table; oldTables.iterItems())
                        updateTableData ~= table;
                    foreach (index, table1; oldTables.list.items)
                        foreach (table2; data["pubtable"]["changed"].iterItems())
                            if (table1["table_name"] == table2["table_name"])
                            {
                                updateTableData[index] = table2;
                                updateTable = true;
                                break;
                            }
                }
                if (data.contains("pubtable") && data["pubtable"].contains("added"))
                    foreach (table; data["pubtable"]["added"].iterItems())
                    {
                        addTableData ~= table;
                        addTable = true;
                    }
            }

            bool dropSchema, addSchema;
            Value[] dropSchemaData, addSchemaData;
            if (oldData.contains("pubschema"))
                foreach (schema; oldData["pubschema"].iterItems())
                    if (data.contains("pubschema") && !data["pubschema"].contains(schema))
                    {
                        dropSchemaData ~= schema;
                        dropSchema = true;
                    }
            if (data.contains("pubschema"))
                foreach (schema; data["pubschema"].iterItems())
                    if (!oldData.contains("pubschema") || !oldData["pubschema"].contains(schema))
                    {
                        addSchemaData ~= schema;
                        addSchema = true;
                    }

            if (!data.contains("name"))
                data["name"] = oldData["name"];
            if (data.contains("evnt_insert") || data.contains("evnt_delete") || data.contains("evnt_update")
                    || data.contains("evnt_truncate"))
            {
                foreach (e; ["evnt_insert", "evnt_delete", "evnt_update"])
                    if (!data.contains(e))
                        data[e] = oldData[e];
                if (!data.contains("evnt_truncate") && oldData.contains("evnt_truncate"))
                    data["evnt_truncate"] = oldData["evnt_truncate"];
            }
            auto sql = rt(UPDATE_SQL, tv("data", data, "o_data", oldData, "conn", conn,
                    "drop_table", dropTable, "drop_table_data", Value(dropTableData),
                    "add_table", addTable, "add_table_data", Value(addTableData),
                    "update_table", updateTable, "update_table_data", Value(updateTableData),
                    "drop_schema", dropSchema, "drop_schema_data", Value(dropSchemaData),
                    "add_schema", addSchema, "add_schema_data", Value(addSchemaData)));
            name = data.contains("name") ? data["name"].toString : oldData["name"].toString;
            return sql.strip("\n");
        }
        auto sql = rt(CREATE_SQL, tv("data", data, "conn", conn));
        name = data["name"].toString;
        return sql.strip("\n");
    }

    private Response sqlView(Value pbid, bool jsonResp = true)
    {
        auto r = conn.executeDict(rt(PROPERTIES_SQL, tv("pbid", pbid)));
        if (!r.ok)
            return internalServerError(r.error);
        if (r.value["rows"].length == 0)
            return gone(notFoundPub());
        auto snames = schemaNames(pbid);
        auto n = conn.executeScalar(rt(DELETE_SQL, tv("pbid", pbid, "conn", conn)));
        auto oldData = oldTableData(r.value, snames);
        if (snames.length != 0)
            oldData["pubschema"] = snames;
        auto sql = rt(CREATE_SQL, tv("data", oldData, "conn", conn));
        auto header = "-- Publication: " ~ oldData["name"].toString ~ "\n\n-- ";
        header ~= rt(DELETE_SQL, tv("pname", oldData["name"]));
        header ~= "\n";
        sql = header ~ sql;
        if (!jsonResp)
            return Response.sqlOnly(sql);
        return makeResponse(Value(sql));
    }

    private Value pubDependencies(Value pbid, out Response err)
    {
        auto n = conn.executeScalar(rt(DELETE_SQL, tv("pbid", pbid, "conn", conn)));
        auto t = conn.executeDict(rt("dependencies.sql", tv("pname", n.value, "conn", conn)));
        if (!t.ok)
        {
            err = internalServerError(t.error);
            return Value(null);
        }
        Value[] res;
        foreach (row; t.value["rows"].list.items)
            res ~= Value.dictOf("type", "table", "name", row["pubtable"], "field", "normal", "oid", row["oid"]);
        return Value(res);
    }
}
