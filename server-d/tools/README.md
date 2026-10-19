# Testing tools

Differential testing of the D port against the original Python pgAdmin 4 (the "reference").

* `pyview.py file [lo hi]`  - prints Python without comments/docstrings (compact reading while porting).
* `api.py <base> METHOD /path [json]` - one API call with CSRF handling.
* `apidiff.py paths.txt`  - runs every path on the reference (:5055) and on the D server (:5056) and diffs the JSON.
* `gentest.py <node> /1/1/5/<scid>/` - builds a paths file exercising the standard endpoints of a node type.
* `rec2.py <base> <outdir> [png]` + `cmpbodies.py` - headless-Chromium recording of the UI boot, and body comparison.
* `dump_prefs.py` - regenerates `resources/prefs_*.json` from the Python application.
* `fixtures*.sql` - objects of every kind for a throw-away PostgreSQL (e.g. `podman run postgres:18-alpine`).
* `jinja_cli.d` - renders the SQL templates, to diff against Jinja2 (`dub build -c jinja-cli`).
