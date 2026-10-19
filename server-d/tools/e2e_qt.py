"""e2e_qt.py base outdir -- drives the pgAdmin UI with Chromium: connect to the server, open the Query Tool, run a query."""
import sys, os, time
from playwright.sync_api import sync_playwright
base, outdir = sys.argv[1], sys.argv[2]
os.makedirs(outdir, exist_ok=True)
errs = []
with sync_playwright() as p:
    b = p.chromium.launch()
    ctx = b.new_context(viewport={'width': 1500, 'height': 900})
    pg = ctx.new_page()
    pg.on("console", lambda m: errs.append(('console', m.text[:300])) if m.type == 'error' else None)
    pg.on("pageerror", lambda e: errs.append(('pageerror', str(e)[:300])))
    pg.on("response", lambda r: errs.append(('http', r.status, r.request.method, r.url.replace(base, '')[:120])) if r.status >= 400 else None)
    def dump(r):
        if '/sqleditor/panel' in r.url:
            try: print('PANEL', r.request.method, r.url.replace(base,''), r.request.headers.get('content-type'), (r.request.post_data or '')[:300], r.status, r.text()[:300])
            except Exception as e: print('PANEL err', e)
        if '/connect/' in r.url or 'server/connect' in r.url:
            try: print('CONNECT', r.request.method, r.url.replace(base,''), r.request.post_data, r.status, r.text()[:600])
            except Exception as e: print('CONNECT err', e)
    pg.on("response", dump)
    seq = []
    bodies = []
    def keep(r):
        u = r.url.replace(base,'').split('?')[0]
        if '/static/' in u or u.endswith(('.js','.css','.png','.svg','.woff2','.woff','.ico')): return
        try: bodies.append((r.request.method, u, r.text()))
        except Exception: bodies.append((r.request.method, u, '<binary>'))
    pg.on('response', keep)
    pg.on("response", lambda r: seq.append((r.request.method, r.url.replace(base,'').split('?')[0], r.status)) if not r.url.split('?')[0].endswith(('.js','.css','.png','.svg','.woff2','.woff','.ico','.json')) and '/static/' not in r.url else None)
    pg.goto(base + '/', wait_until='networkidle', timeout=90000)
    pg.wait_for_timeout(3000)
    pg.screenshot(path=outdir + '/01_tree.png')
    # expand Servers and connect
    pg.get_by_text('Servers', exact=True).first.dblclick()
    pg.wait_for_timeout(1500)
    pg.screenshot(path=outdir + '/02_servers.png')
    pg.evaluate('''() => { const n = pgAdmin.Browser.notifier; const o = n.warning.bind(n); n.warning = function(...a){ console.error('WARN-CALL ' + JSON.stringify(a).slice(0,100) + ' ' + new Error().stack.split('\\n').slice(1,4).join(' | ')); return o(...a); }; }''')
    pg.get_by_text('pg18', exact=True).first.dblclick()
    for k in range(8):
        pg.wait_for_timeout(400)
        txt = pg.evaluate('document.body.innerText').count('plague of frogs')
        print('T', k, 'warning-count', txt)
    pg.screenshot(path=outdir + '/03_connect.png')
    print('VERSION', pg.evaluate('JSON.stringify(Object.entries(pgAdmin.Browser.serverInfo||{}).map(([k,v])=>[k,v.version,typeof v.version]))'))
    # expand to the database and open the Query Tool
    pg.get_by_text('pg18', exact=True).first.click()
    pg.keyboard.press('ArrowRight')
    pg.wait_for_timeout(1500)
    pg.screenshot(path=outdir + '/035_expanded.png')
    for _try in range(3):
        if pg.get_by_text('postgres', exact=True).count(): break
        pg.get_by_text('Databases', exact=False).first.dblclick()
        pg.wait_for_timeout(2500)
    pg.screenshot(path=outdir + '/04_dbs.png')
    pg.get_by_text('postgres', exact=True).first.click()
    pg.wait_for_timeout(500)
    pg.get_by_text('Tools', exact=True).first.click()
    pg.wait_for_timeout(500)
    pg.screenshot(path=outdir + '/05_tools.png')
    pg.get_by_role('menuitem', name='Query Tool').first.click()
    pg.wait_for_timeout(5000)
    pg.screenshot(path=outdir + '/06_qt.png')
    # run a query
    pg.mouse.click(700, 300)
    pg.keyboard.type("select id, name, email, created from shop.customers order by id limit 5")
    pg.keyboard.press('F5')
    pg.wait_for_timeout(4000)
    pg.screenshot(path=outdir + '/07_result.png')
    print('RESULT-TEXT', pg.evaluate('document.body.innerText').count('shop') )
    b.close()
for e in errs: print(e)
import json as _j
open(outdir + '/bodies.json','w').write(_j.dumps(bodies))
open(outdir + '/seq.txt','w').write('\n'.join(' '.join(map(str,x)) for x in seq))
