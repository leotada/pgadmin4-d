import sys, os, json, builtins, tempfile
mode = sys.argv[1]  # 'desktop' | 'server'
out = sys.argv[2]
d = tempfile.mkdtemp()
web = '/home/leonardo/Projetos/pgadmin4-9.18/web'
cfgdir = tempfile.mkdtemp()
open(os.path.join(cfgdir, 'config_local.py'), 'w').write(f"""
DATA_DIR = {d!r}
LOG_FILE = {d + '/log'!r}
SQLITE_PATH = {d + '/pgadmin4.db'!r}
SESSION_DB_PATH = {d + '/sessions'!r}
STORAGE_DIR = {d + '/storage'!r}
UPGRADE_CHECK_ENABLED = False
MASTER_PASSWORD_REQUIRED = {mode == 'server'!r}
""")
os.environ['PGADMIN_SETUP_EMAIL'] = 'a@b.com'; os.environ['PGADMIN_SETUP_PASSWORD'] = 'secret123'
sys.path[:0] = [cfgdir, web]
os.chdir(web)
builtins.SERVER_MODE = (mode == 'server')
import logging; logging.disable(logging.CRITICAL)
import config, setup
from pgadmin import create_app
app = create_app()
setup.setup_db(app) if not os.path.exists(config.SQLITE_PATH) else None
app = create_app()
app.PGADMIN_RUNTIME = False
app.run_before_app_start()
from pgadmin.utils.preferences import Preferences
res = []
for m in Preferences.modules.values():
    mods = {'name': m.name, 'label': m.label, 'categories': []}
    for cn, cat in m.categories.items():
        c = {'name': cn, 'label': cat['label'], 'preferences': []}
        for pn, p in cat['preferences'].items():
            c['preferences'].append({
                'name': p.name, 'label': p.label, 'type': p._type, 'default': p.default,
                'help_str': p.help_str, 'control_props': p.control_props, 'min_val': p.min_val, 'max_val': p.max_val,
                'options': p.options, 'select': p.select, 'fields': p.fields, 'hidden': p.hidden,
                'allow_blanks': p.allow_blanks, 'disabled': p.disabled, 'dependents': p.dependents})
        mods['categories'].append(c)
    res.append(mods)
json.dump(res, open(out, 'w'), indent=1, default=str)
print(mode, sum(len(c['preferences']) for m in res for c in m['categories']), 'preferences in', len(res), 'modules')
