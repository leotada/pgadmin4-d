/// PostgreSQL keyword categories (generated from pgadmin/utils/driver/psycopg3/keywords.py).
module pgadmin.db.keywords;

/// 0 = unreserved, 1 = column name, 2 = type/function name, 3 = reserved; -1 = not a keyword.
int scanKeyword(string key) @safe pure nothrow
{
    switch (key)
    {
    case "abort", "absolute", "access", "action", "add", "admin":
    case "after", "aggregate", "also", "alter", "always", "assertion":
    case "assignment", "at", "attribute", "backward", "before", "begin":
    case "by", "cache", "called", "cascade", "cascaded", "catalog":
    case "chain", "characteristics", "checkpoint", "class", "close", "cluster":
    case "comment", "comments", "commit", "committed", "configuration", "conflict":
    case "connection", "constraints", "content", "continue", "conversion", "copy":
    case "cost", "csv", "cube", "current", "cursor", "cycle":
    case "data", "database", "day", "deallocate", "declare", "defaults":
    case "deferred", "definer", "delete", "delimiter", "delimiters", "dictionary":
    case "disable", "discard", "document", "domain", "double", "drop":
    case "each", "enable", "encoding", "encrypted", "enum", "escape":
    case "event", "exclude", "excluding", "exclusive", "execute", "explain":
    case "extension", "external", "family", "filter", "first", "following":
    case "force", "forward", "function", "functions", "global", "granted":
    case "handler", "header", "hold", "hour", "identity", "if":
    case "immediate", "immutable", "implicit", "import", "including", "increment":
    case "index", "indexes", "inherit", "inherits", "inline", "input":
    case "insensitive", "insert", "instead", "invoker", "isolation", "key":
    case "label", "language", "large", "last", "leakproof", "level":
    case "listen", "load", "local", "location", "lock", "locked":
    case "logged", "mapping", "match", "materialized", "maxvalue", "minute":
    case "minvalue", "mode", "month", "move", "name", "names":
    case "next", "no", "nothing", "notify", "nowait", "nulls":
    case "object", "of", "off", "oids", "operator", "option":
    case "options", "ordinality", "over", "owned", "owner", "parser":
    case "partial", "partition", "passing", "password", "plans", "policy":
    case "preceding", "prepare", "prepared", "preserve", "prior", "privileges":
    case "procedural", "procedure", "program", "quote", "range", "read":
    case "reassign", "recheck", "recursive", "ref", "refresh", "reindex":
    case "relative", "release", "rename", "repeatable", "replace", "replica":
    case "reset", "restart", "restrict", "returns", "revoke", "role":
    case "rollback", "rollup", "rows", "rule", "savepoint", "schema":
    case "scroll", "search", "second", "security", "sequence", "sequences":
    case "serializable", "server", "session", "set", "sets", "share":
    case "show", "simple", "skip", "snapshot", "sql", "stable":
    case "standalone", "start", "statement", "statistics", "stdin", "stdout":
    case "storage", "strict", "strip", "sysid", "system", "tables":
    case "tablespace", "temp", "template", "temporary", "text", "transaction":
    case "transform", "trigger", "truncate", "trusted", "type", "types":
    case "unbounded", "uncommitted", "unencrypted", "unknown", "unlisten", "unlogged":
    case "until", "update", "vacuum", "valid", "validate", "validator":
    case "value", "varying", "version", "view", "views", "volatile":
    case "whitespace", "within", "without", "work", "wrapper", "write":
    case "xml", "year", "yes", "zone":
        return 0;
    case "between", "bigint", "bit", "boolean", "char", "character":
    case "coalesce", "dec", "decimal", "exists", "extract", "float":
    case "greatest", "grouping", "inout", "int", "integer", "interval":
    case "least", "national", "nchar", "none", "nullif", "numeric":
    case "out", "overlay", "position", "precision", "real", "row":
    case "setof", "smallint", "substring", "time", "timestamp", "treat":
    case "trim", "values", "varchar", "xmlattributes", "xmlconcat", "xmlelement":
    case "xmlexists", "xmlforest", "xmlparse", "xmlpi", "xmlroot", "xmlserialize":
        return 1;
    case "authorization", "binary", "collation", "concurrently", "cross", "current_schema":
    case "freeze", "full", "ilike", "inner", "is", "isnull":
    case "join", "left", "like", "natural", "notnull", "outer":
    case "overlaps", "right", "similar", "tablesample", "verbose":
        return 2;
    case "all", "analyze", "and", "any", "array", "as":
    case "asc", "asymmetric", "both", "case", "cast", "check":
    case "collate", "column", "constraint", "create", "current_catalog", "current_date":
    case "current_role", "current_time", "current_timestamp", "current_user", "default", "deferrable":
    case "desc", "distinct", "do", "else", "end", "except":
    case "false", "fetch", "for", "foreign", "from", "grant":
    case "group", "having", "in", "initially", "intersect", "into":
    case "lateral", "leading", "limit", "localtime", "localtimestamp", "not":
    case "null", "offset", "on", "only", "or", "order":
    case "placing", "primary", "references", "returning", "select", "session_user":
    case "some", "symmetric", "table", "then", "to", "trailing":
    case "true", "union", "unique", "user", "using", "variadic":
    case "when", "where", "window", "with":
        return 3;
    default:
        return -1;
    }
}
