CREATE TABLE alembic_version (
	version_num VARCHAR(32) NOT NULL, 
	CONSTRAINT alembic_version_pkc PRIMARY KEY (version_num)
);
CREATE TABLE version (
	name VARCHAR(32) NOT NULL, 
	value INTEGER NOT NULL, 
	PRIMARY KEY (name)
);
CREATE TABLE role (
	id INTEGER NOT NULL, 
	name VARCHAR(128) NOT NULL, 
	description VARCHAR(256) NOT NULL, permissions TEXT, 
	PRIMARY KEY (id), 
	UNIQUE (name)
);
CREATE TABLE roles_users (
	user_id INTEGER, 
	role_id INTEGER, 
	FOREIGN KEY(role_id) REFERENCES role (id) ON DELETE CASCADE, 
	FOREIGN KEY(user_id) REFERENCES "user" (id) ON DELETE CASCADE
);
CREATE TABLE servergroup (
	id INTEGER NOT NULL, 
	user_id INTEGER NOT NULL, 
	name VARCHAR(128) NOT NULL, 
	PRIMARY KEY (id), 
	FOREIGN KEY(user_id) REFERENCES "user" (id) ON DELETE CASCADE, 
	UNIQUE (user_id, name)
);
CREATE TABLE module_preference (
	id INTEGER NOT NULL, 
	name VARCHAR(256) NOT NULL, 
	PRIMARY KEY (id)
);
CREATE TABLE preference_category (
	id INTEGER NOT NULL, 
	mid INTEGER, 
	name VARCHAR(256) NOT NULL, 
	PRIMARY KEY (id), 
	FOREIGN KEY(mid) REFERENCES module_preference (id)
);
CREATE TABLE preferences (
	id INTEGER NOT NULL, 
	cid INTEGER NOT NULL, 
	name VARCHAR(256) NOT NULL, 
	PRIMARY KEY (id), 
	FOREIGN KEY(cid) REFERENCES preference_category (id)
);
CREATE TABLE user_preferences (
	pid INTEGER NOT NULL, 
	uid INTEGER NOT NULL, 
	value VARCHAR(1024) NOT NULL, 
	PRIMARY KEY (pid, uid), 
	FOREIGN KEY(pid) REFERENCES preferences (id) ON DELETE CASCADE, 
	FOREIGN KEY(uid) REFERENCES "user" (id) ON DELETE CASCADE
);
CREATE TABLE process (
	user_id INTEGER NOT NULL, 
	pid VARCHAR NOT NULL, 
	"desc" VARCHAR NOT NULL, 
	command VARCHAR NOT NULL, 
	arguments VARCHAR, 
	start_time VARCHAR, 
	end_time VARCHAR, 
	logdir VARCHAR, 
	exit_code INTEGER, 
	acknowledge VARCHAR, utility_pid INTEGER, process_state INTEGER DEFAULT '0', server_id INTEGER DEFAULT '0', 
	PRIMARY KEY (pid), 
	FOREIGN KEY(user_id) REFERENCES "user" (id) ON DELETE CASCADE
);
CREATE TABLE keys (
	name VARCHAR NOT NULL, 
	value VARCHAR NOT NULL, 
	PRIMARY KEY (name)
);
CREATE TABLE query_history (
	srno INTEGER NOT NULL, 
	uid INTEGER NOT NULL, 
	sid INTEGER NOT NULL, 
	dbname VARCHAR NOT NULL, 
	query_info VARCHAR NOT NULL, 
	last_updated_flag VARCHAR NOT NULL, 
	PRIMARY KEY (srno, uid, sid, dbname), 
	FOREIGN KEY(sid) REFERENCES "server" (id) ON DELETE CASCADE, 
	FOREIGN KEY(uid) REFERENCES "user" (id) ON DELETE CASCADE
);
CREATE TABLE macros (
	id INTEGER NOT NULL, 
	alt BOOLEAN NOT NULL, 
	control BOOLEAN NOT NULL, 
	"key" VARCHAR(128) NOT NULL, 
	key_code INTEGER NOT NULL, 
	PRIMARY KEY (id)
);
CREATE TABLE "user" (
	id INTEGER NOT NULL, 
	email VARCHAR(256), 
	password VARCHAR, 
	active BOOLEAN NOT NULL, 
	confirmed_at DATETIME, 
	masterpass_check VARCHAR(256), 
	username VARCHAR(256) DEFAULT ('') NOT NULL, 
	auth_source VARCHAR(256) DEFAULT 'internal' NOT NULL, 
	fs_uniquifier VARCHAR NOT NULL, locked BOOLEAN DEFAULT 'false', login_attempts INTEGER DEFAULT '0', 
	PRIMARY KEY (id), 
	CONSTRAINT user_unique_constraint UNIQUE (username, auth_source)
);
CREATE TABLE user_mfa (
	user_id INTEGER NOT NULL, 
	mfa_auth VARCHAR(256) NOT NULL, 
	options VARCHAR, 
	PRIMARY KEY (user_id, mfa_auth), 
	FOREIGN KEY(user_id) REFERENCES "user" (id) ON DELETE CASCADE
);
CREATE TABLE "setting" (
	user_id INTEGER NOT NULL, 
	setting VARCHAR(256) NOT NULL, 
	value TEXT, 
	PRIMARY KEY (user_id, setting), 
	FOREIGN KEY(user_id) REFERENCES user (id) ON DELETE CASCADE
);
CREATE TABLE user_macros (
	id INTEGER NOT NULL, 
	mid INTEGER, 
	uid INTEGER NOT NULL, 
	name VARCHAR(1024) NOT NULL, 
	sql VARCHAR, 
	PRIMARY KEY (id), 
	FOREIGN KEY(mid) REFERENCES macros (id) ON DELETE CASCADE, 
	FOREIGN KEY(uid) REFERENCES user (id) ON DELETE CASCADE
);
CREATE TABLE "server" (
	id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, 
	user_id INTEGER NOT NULL, 
	servergroup_id INTEGER NOT NULL, 
	name VARCHAR(128) NOT NULL, 
	host VARCHAR(128), 
	port INTEGER, 
	maintenance_db VARCHAR(64), 
	username VARCHAR(64), 
	comment VARCHAR(1024), 
	password VARCHAR, 
	role VARCHAR(64), 
	discovery_id VARCHAR, 
	db_res VARCHAR, 
	bgcolor VARCHAR(10), 
	fgcolor VARCHAR(10), 
	service VARCHAR, 
	use_ssh_tunnel INTEGER DEFAULT '0', 
	tunnel_host VARCHAR, 
	tunnel_port VARCHAR, 
	tunnel_username VARCHAR, 
	tunnel_authentication INTEGER DEFAULT '0', 
	tunnel_identity_file VARCHAR, 
	tunnel_password VARCHAR, 
	save_password INTEGER DEFAULT '0', 
	shared BOOLEAN, 
	kerberos_conn BOOLEAN DEFAULT 'false', 
	cloud_status INTEGER DEFAULT '0', 
	passexec_cmd VARCHAR, 
	passexec_expiration INTEGER, 
	connection_params JSON, 
	shared_username VARCHAR(64), 
	prepare_threshold INTEGER, 
	tunnel_keep_alive INTEGER DEFAULT '0', 
	tags JSON, 
	is_adhoc INTEGER DEFAULT '0', post_connection_sql VARCHAR, db_res_type VARCHAR(32) DEFAULT 'databases', tunnel_prompt_password INTEGER DEFAULT '0', 
	FOREIGN KEY(user_id) REFERENCES user (id) ON DELETE CASCADE, 
	FOREIGN KEY(servergroup_id) REFERENCES servergroup (id)
);
CREATE TABLE "application_state" (
	uid INTEGER NOT NULL, 
	id INTEGER NOT NULL, 
	connection_info JSON, 
	tool_data VARCHAR, 
	PRIMARY KEY (id, uid), 
	FOREIGN KEY(uid) REFERENCES user (id) ON DELETE CASCADE
);
CREATE TABLE "database" (
	id BIGINT NOT NULL, 
	schema_res VARCHAR, 
	server INTEGER NOT NULL, 
	PRIMARY KEY (id, server), 
	FOREIGN KEY(server) REFERENCES server (id) ON DELETE CASCADE
);
CREATE TABLE debugger_function_arguments (
	user_id INTEGER NOT NULL, 
	server_id INTEGER NOT NULL, 
	database_id INTEGER NOT NULL, 
	schema_id INTEGER NOT NULL, 
	function_id INTEGER NOT NULL, 
	arg_id INTEGER NOT NULL, 
	is_null INTEGER NOT NULL, 
	is_expression INTEGER NOT NULL, 
	use_default INTEGER NOT NULL, 
	value VARCHAR, 
	PRIMARY KEY (user_id, server_id, database_id, schema_id, function_id, arg_id), 
	CHECK (is_null >= 0 AND is_null <= 1), 
	CHECK (is_expression >= 0 AND is_expression <= 1), 
	CHECK (use_default >= 0 AND use_default <= 1), 
	FOREIGN KEY(user_id) REFERENCES user (id)
);
CREATE INDEX ix_server_user_id ON server (user_id);
CREATE INDEX ix_server_servergroup_id ON server (servergroup_id);
CREATE INDEX ix_servergroup_user_id ON servergroup (user_id);
CREATE TABLE "sharedserver" (
	id INTEGER NOT NULL, 
	user_id INTEGER NOT NULL, 
	server_owner VARCHAR(64), 
	servergroup_id INTEGER NOT NULL, 
	name VARCHAR(128) NOT NULL, 
	host VARCHAR(128), 
	port INTEGER, 
	maintenance_db VARCHAR(64), 
	username VARCHAR(64), 
	password VARCHAR, 
	role VARCHAR(64), 
	comment VARCHAR(1024), 
	discovery_id VARCHAR(128), 
	bgcolor VARCHAR(10), 
	fgcolor VARCHAR(10), 
	service VARCHAR, 
	use_ssh_tunnel INTEGER DEFAULT '0', 
	tunnel_host VARCHAR, 
	tunnel_port VARCHAR, 
	tunnel_username VARCHAR, 
	tunnel_authentication INTEGER DEFAULT '0', 
	tunnel_identity_file VARCHAR, 
	shared BOOLEAN NOT NULL, 
	save_password INTEGER DEFAULT '0', 
	tunnel_password VARCHAR, 
	osid INTEGER, 
	connection_params JSON, 
	prepare_threshold INTEGER, 
	tunnel_keep_alive INTEGER DEFAULT '0', 
	tunnel_prompt_password INTEGER DEFAULT '0', 
	passexec_cmd TEXT, 
	passexec_expiration INTEGER, 
	kerberos_conn BOOLEAN DEFAULT 0 NOT NULL, 
	tags JSON, 
	post_connection_sql VARCHAR, 
	PRIMARY KEY (id), 
	CONSTRAINT uq_sharedserver_osid_user UNIQUE (osid, user_id), 
	FOREIGN KEY(user_id) REFERENCES user (id) ON DELETE CASCADE, 
	FOREIGN KEY(servergroup_id) REFERENCES servergroup (id)
);
CREATE INDEX ix_sharedserver_osid ON sharedserver (osid);
CREATE INDEX ix_sharedserver_user_id ON sharedserver (user_id);
