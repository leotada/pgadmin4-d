/// Constants of `pgadmin/utils/constants.py`.
module pgadmin.utils.constants;

enum MIMETYPE_APP_HTML = "text/html";
enum MIMETYPE_APP_JS = "application/javascript";
enum MIMETYPE_APP_JSON = "application/json";
enum NO_CACHE_CONTROL = "no-cache, no-store, must-revalidate";

enum PREF_LABEL_KEYBOARD_SHORTCUTS = "Keyboard shortcuts";
enum PREF_LABEL_DISPLAY = "Display";
enum PREF_LABEL_BREADCRUMBS = "Object Breadcrumbs";
enum PREF_LABEL_OPTIONS = "Options";
enum PREF_LABEL_EXPLAIN = "Explain";
enum PREF_LABEL_EDITOR = "Editor";
enum PREF_LABEL_CSV_TXT = "CSV/TXT Output";
enum PREF_LABEL_RESULTS_GRID = "Results grid";
enum PREF_LABEL_SQL_FORMATTING = "SQL formatting";
enum PREF_LABEL_TABS_SETTINGS = "Tab settings";
enum PREF_LABEL_REFRESH_RATES = "Refresh rates";
enum PREF_LABEL_GRAPH_VISUALISER = "Graph Visualiser";
enum PREF_LABEL_GEOMETRY_VIEWER = "Geometry Viewer";
enum PREF_LABEL_USER_INTERFACE = "User Interface";
enum PREF_LABEL_FILE_DOWNLOADS = "File Downloads";
enum PREF_LABEL_AI = "AI";

enum PGADMIN_STRING_SEPARATOR = "_$PGADMIN$_";
enum PGADMIN_NODE = "pgadmin.node.%s";
enum UNAUTH_REQ = "Unauthorized request.";
enum SERVER_CONNECTION_CLOSED = "Not connected to server or connection with the server has been closed.";
enum QT_DEFAULT_PLACEHOLDER = "%DATABASE%/%USERNAME%@%SERVER%";
enum VW_EDT_DEFAULT_PLACEHOLDER = "%SCHEMA%.%TABLE%/%DATABASE%/%USERNAME%@%SERVER%";

enum DATATYPE_TIME_WITH_TIMEZONE = "time with time zone";
enum DATATYPE_TIME_WITHOUT_TIMEZONE = "time without time zone";
enum DATATYPE_TIMESTAMP_WITH_TIMEZONE = "timestamp with time zone";
enum DATATYPE_TIMESTAMP_WITHOUT_TIMEZONE = "timestamp without time zone";

enum ERROR_MSG_TRANS_ID_NOT_FOUND = "Transaction ID not found in the session.";
enum ERROR_MSG_FAIL_TO_PROMOTE_QT = "FAIL TO PROMOTE VIEW/EDIT DATA TO QUERY TOOL";
enum ERROR_FETCHING_ROLE_INFORMATION = "Error fetching role information from the database server.";
enum ERROR_FETCHING_DATA = "Unable to fetch data.";
enum ERROR_SERVER_ID_NOT_SPECIFIED = "Server ID not specified.";

enum INTERNAL = "internal";
enum LDAP = "ldap";
enum KERBEROS = "kerberos";
enum OAUTH2 = "oauth2";
enum WEBSERVER = "webserver";
immutable string[] SUPPORTED_AUTH_SOURCES = [INTERNAL, LDAP, KERBEROS, OAUTH2, WEBSERVER];

immutable string[] UTILITIES_ARRAY = ["pg_dumpall", "pg_dump", "pg_restore", "psql"];
enum ENTER_EMAIL_ADDRESS = "Email address: ";
enum USER_NOT_FOUND = "The specified user ID (%s) could not be found.";
enum DATABASE_LAST_SYSTEM_OID = 16383;
enum PSYCOPG3 = "psycopg3";
enum MY_STORAGE = "my_storage";
enum ACCESS_DENIED_MESSAGE = "Access denied: You’re having limited access. You’re not allowed to Rename, Delete or Create any files/folders";
enum KEY_RING_SERVICE_NAME = "pgAdmin4";
enum KEY_RING_USER_NAME = "pgadmin4-master-password";
enum DBMS_JOB_SCHEDULER_ID = 999999;
enum IP_ADDRESS_STRING = "%s/%s";
enum TWO_PARAM_STRING = "%s/%s";

/// Flash categories (`MessageType` values are 1-tuples in Python; only the name matters to the templates).
enum MessageType : string
{
    SUCCESS = "Success",
    ERROR = "Error",
    INFO = "Info",
    CLOSE = "Close",
    WARNING = "Warning",
}

enum SERVER_NOT_FOUND = "Could not find the specified server.";
immutable string[] SSL_MODES = ["prefer", "require", "verify-ca", "verify-full"];
enum RESTRICTION_TYPE_DATABASES = "databases";
enum RESTRICTION_TYPE_SQL = "sql";
enum RESTRICT_COMMAND = "\\restrict";

/// Data types that take a length (`DATA_TYPE_WITH_LENGTH`): OIDs and names.
immutable string[] DATA_TYPE_WITH_LENGTH_NAMES = [
    "bit", "bit[]", "varbit", "bit varying", "varbit[]", "bit varying[]", "bpchar", "character", "varchar",
    "character varying", "bpchar[]", "character[]", "varchar[]", "character varying[]", "vector", "vector[]", "halfvec",
    "halfvec[]", "sparsevec", "sparsevec[]",
];
immutable long[] DATA_TYPE_WITH_LENGTH_OIDS = [1560, 1561, 1562, 1563, 1042, 1043, 1014, 1015];

import pgadmin.core.value : Value;

/// `elemoid_or_name in DATA_TYPE_WITH_LENGTH`
bool isDataTypeWithLength(Value v)
{
    import std.algorithm : canFind;
    if (v.isInt)
        return DATA_TYPE_WITH_LENGTH_OIDS.canFind(v.integer);
    if (v.isString)
        return DATA_TYPE_WITH_LENGTH_NAMES.canFind(v.str);
    return false;
}
