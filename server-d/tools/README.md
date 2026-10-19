# Developer & Testing Tools

Utilities for development and verification of the D backend port:

* `jinja_cli.d` - renders the SQL templates via the D Jinja parser (`dub build -c jinja-cli`).
* `driver_probe.d` - probes PostgreSQL libpq connectivity and type encodings.
* `rund.sh` - helper runner script for the D backend.
* `fixtures*.sql` - test schema objects for testing against PostgreSQL (`fixtures.sql`, `fixtures2.sql`).
