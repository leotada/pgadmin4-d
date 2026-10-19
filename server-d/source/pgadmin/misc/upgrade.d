/// Version check against pgadmin.org.
module pgadmin.misc.upgrade;

import pgadmin.core.value;
import pgadmin.web.http;

/// The online check is not implemented in this build: reports "up to date".
Response upgradeCheck(bool trigger)
{
    return makeJsonResponse(1, Value(""), Value(""), Value(null), Value.dictOf("outdated", false), 200);
}
