import sys, json, os
from playwright.sync_api import sync_playwright
base, outdir = sys.argv[1], sys.argv[2]
os.makedirs(outdir, exist_ok=True)
reqs = []
def on_resp(r):
    url = r.request.url.replace(base, '')
    path = url.split('?')[0]
    if path.startswith('/static/') and not path.endswith('.json'): 
        reqs.append((r.request.method, url, r.status, None)); return
    try: body = r.body()
    except Exception: body = b''
    reqs.append((r.request.method, url, r.status, body))
with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page()
    pg.on("response", on_resp)
    pg.on("console", lambda m: print("console:", m.type, m.text[:300]) if m.type in ('error',) else None)
    pg.on("pageerror", lambda e: print("pageerror:", str(e)[:300]))
    pg.goto(base + '/', wait_until='networkidle', timeout=90000)
    pg.wait_for_timeout(5000)
    if len(sys.argv) > 3: pg.screenshot(path=sys.argv[3])
    b.close()
i = 0
for m, u, s, body in reqs:
    if body is None: 
        print(m, u.split('?')[0], s); continue
    name = ('%02d_%s_%s' % (i, m, u.split('?')[0].strip('/').replace('/', '_')))[:100]
    open(os.path.join(outdir, name), 'wb').write(body); i += 1
    print(m, u, s, len(body))
