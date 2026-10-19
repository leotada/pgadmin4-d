/// Extension checks (`pgadmin.utils.check_extension_exists`).
module pgadmin.utils.extensions;

import pgadmin.core.value;
import pgadmin.db.driver;

/// `check_extension_exists(conn, extension_name)` -> (status, exists or error)
Res checkExtensionExists(Connection conn, string name)
{
    auto r = conn.executeScalar("SELECT 1 FROM pg_catalog.pg_extension WHERE extname = %s", Value.tuple(Value(name)));
    if (r.ok)
        return Res(true, Value(r.value.truthy));
    return r;
}
