/// `sqleditor/autocomplete`: SQL autocomplete provider for the Query Tool.
module pgadmin.tools.sqleditor.autocomplete;

import std.algorithm : canFind, startsWith, endsWith;
import std.array : split;
import std.conv : to;
import std.regex : regex, matchFirst, matchAll;
import std.string : strip, toLower, toUpper, indexOf, lastIndexOf;
import pgadmin.core.templates : renderTemplate, tv;
import pgadmin.core.value;
import pgadmin.db.driver : Connection, ServerManager, getDriver, Res;

private immutable string[] DEFAULT_KEYWORDS = [
    "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE",
    "CREATE", "TABLE", "VIEW", "INDEX", "DROP", "ALTER", "ADD", "COLUMN", "CONSTRAINT",
    "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "UNIQUE", "CHECK", "NOT", "NULL",
    "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "OUTER", "CROSS", "ON", "USING",
    "GROUP", "BY", "ORDER", "HAVING", "LIMIT", "OFFSET", "ASC", "DESC",
    "UNION", "ALL", "EXCEPT", "INTERSECT", "DISTINCT", "AS", "CASE", "WHEN", "THEN",
    "ELSE", "END", "AND", "OR", "IN", "IS", "LIKE", "ILIKE", "BETWEEN", "EXISTS",
    "WITH", "RECURSIVE", "RETURNING", "TRUNCATE", "VACUUM", "ANALYZE", "EXPLAIN",
    "BEGIN", "COMMIT", "ROLLBACK", "TRANSACTION", "SAVEPOINT", "RELEASE",
    "GRANT", "REVOKE", "TO", "CASCADE", "RESTRICT", "DATABASE", "SCHEMA", "FUNCTION",
    "PROCEDURE", "TRIGGER", "TYPE", "DOMAIN", "SEQUENCE", "TEXT", "INTEGER",
    "BIGINT", "SMALLINT", "BOOLEAN", "NUMERIC", "TIMESTAMP", "TIMESTAMPTZ", "DATE",
    "TIME", "JSON", "JSONB", "UUID", "BYTEA", "SERIAL", "BIGSERIAL"
];

final class SQLAutoComplete
{
    private long sid;
    private long did;
    private Connection conn;
    private string[] keywords;

    this(long sid, long did, Connection conn)
    {
        this.sid = sid;
        this.did = did;
        this.conn = conn;
        loadKeywords();
    }

    private void loadKeywords()
    {
        keywords = DEFAULT_KEYWORDS.dup;
        if (conn !is null && conn.connected())
        {
            try
            {
                auto r = conn.executeDict("SELECT word FROM pg_get_keywords()");
                if (r.ok)
                {
                    string[] dbKeywords;
                    foreach (row; r.value["rows"].list.items)
                    {
                        auto w = row["word"].toString.toUpper();
                        if (w != "PUBLIC" && !dbKeywords.canFind(w))
                            dbKeywords ~= w;
                    }
                    if (dbKeywords.length > 0)
                        keywords = dbKeywords;
                }
            }
            catch (Exception)
            {
                // fallback to default
            }
        }
    }

    Value getCompletions(string fullSql, string textBeforeCursor)
    {
        auto result = Value.newDict();
        auto stripped = textBeforeCursor.strip();
        if (stripped.length == 0)
            return result;

        // Extract last token or qualified token
        auto lastSpace = textBeforeCursor.lastIndexOf(' ');
        auto lastNewline = textBeforeCursor.lastIndexOf('\n');
        auto lastSep = lastSpace > lastNewline ? lastSpace : lastNewline;
        auto currentToken = (lastSep != -1) ? textBeforeCursor[lastSep + 1 .. $] : textBeforeCursor;
        currentToken = currentToken.strip();

        // Check if cursor is following a dot (e.g. "schema.table" or "table.column")
        auto dotIdx = currentToken.lastIndexOf('.');
        if (dotIdx != -1)
        {
            auto prefix = currentToken[0 .. dotIdx].strip("\"");
            auto colPrefix = currentToken[dotIdx + 1 .. $].toLower();

            // Try to find table columns or schema tables
            if (conn !is null && conn.connected())
            {
                // Check columns of table named `prefix`
                auto colSql = "SELECT a.attname FROM pg_attribute a " ~
                              "JOIN pg_class c ON c.oid = a.attrelid " ~
                              "JOIN pg_namespace n ON n.oid = c.relnamespace " ~
                              "WHERE c.relname = '" ~ prefix ~ "' AND a.attnum > 0 AND NOT a.attisdropped";
                auto r = conn.executeDict(colSql);
                if (r.ok && r.value["rows"].length > 0)
                {
                    foreach (row; r.value["rows"].list.items)
                    {
                        auto colName = row["attname"].toString;
                        if (colPrefix.length == 0 || colName.toLower().startsWith(colPrefix))
                            result[colName] = Value.dictOf("object_type", Value("column"));
                    }
                    return result;
                }

                // Check tables in schema named `prefix`
                auto schSql = "SELECT c.relname, c.relkind FROM pg_class c " ~
                              "JOIN pg_namespace n ON n.oid = c.relnamespace " ~
                              "WHERE n.nspname = '" ~ prefix ~ "' AND c.relkind IN ('r', 'v', 'm', 'f', 'p')";
                auto sr = conn.executeDict(schSql);
                if (sr.ok && sr.value["rows"].length > 0)
                {
                    foreach (row; sr.value["rows"].list.items)
                    {
                        auto tName = row["relname"].toString;
                        auto rk = row["relkind"].toString;
                        auto objType = (rk == "v" || rk == "m") ? "view" : "table";
                        if (colPrefix.length == 0 || tName.toLower().startsWith(colPrefix))
                            result[tName] = Value.dictOf("object_type", Value(objType));
                    }
                    return result;
                }
            }
        }

        auto upperBefore = textBeforeCursor.toUpper();
        auto tokenLower = currentToken.toLower();

        // Check if typing after FROM or JOIN
        bool inFromOrJoin = false;
        auto lastFrom = upperBefore.lastIndexOf(" FROM ");
        auto lastJoin = upperBefore.lastIndexOf(" JOIN ");
        auto lastWhere = upperBefore.lastIndexOf(" WHERE ");
        auto fromPos = lastFrom > lastJoin ? lastFrom : lastJoin;
        if (fromPos != -1 && (lastWhere == -1 || fromPos > lastWhere))
            inFromOrJoin = true;

        if (conn !is null && conn.connected())
        {
            // Suggest schemas
            auto nspSql = "SELECT nspname FROM pg_namespace WHERE nspname NOT LIKE 'pg_temp%' AND nspname NOT LIKE 'pg_toast%'";
            auto nr = conn.executeDict(nspSql);
            if (nr.ok)
            {
                foreach (row; nr.value["rows"].list.items)
                {
                    auto nName = row["nspname"].toString;
                    if (tokenLower.length == 0 || nName.toLower().startsWith(tokenLower))
                        result[nName] = Value.dictOf("object_type", Value("schema"));
                }
            }

            // Suggest tables and views
            auto tblSql = "SELECT c.relname, c.relkind FROM pg_class c " ~
                          "JOIN pg_namespace n ON n.oid = c.relnamespace " ~
                          "WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') " ~
                          "AND c.relkind IN ('r', 'v', 'm', 'f', 'p')";
            auto tr = conn.executeDict(tblSql);
            if (tr.ok)
            {
                foreach (row; tr.value["rows"].list.items)
                {
                    auto tName = row["relname"].toString;
                    auto rk = row["relkind"].toString;
                    auto objType = (rk == "v" || rk == "m") ? "view" : "table";
                    if (tokenLower.length == 0 || tName.toLower().startsWith(tokenLower))
                        result[tName] = Value.dictOf("object_type", Value(objType));
                }
            }
        }

        // Suggest keywords
        auto tokenUpper = currentToken.toUpper();
        foreach (kw; keywords)
        {
            if (tokenUpper.length == 0 || kw.startsWith(tokenUpper))
                result[kw] = Value.dictOf("object_type", Value("keyword"));
        }

        return result;
    }
}
