/// Password commands (`pgadmin/utils/passexec.py`).
module pgadmin.utils.passexec;

import pgadmin.core.config;

/// Runs the configured command and returns its output as the password (not supported yet in this build).
string getPassexecPassword(string cmd, string host, string port, string user, long expiration)
{
    if (!cfgBool("ENABLE_SERVER_PASS_EXEC_CMD"))
        return null;
    throw new Exception("Password commands (passexec_cmd) are not implemented in this build.");
}
