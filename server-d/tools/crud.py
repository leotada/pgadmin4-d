"""crud.py steps-file  -- replays a scenario (create/update/delete...) on the reference (5055) and then on the D server
(5056) and diffs every response. Run sequentially so both see the same database state; the scenario must clean up
after itself. Lines:  METHOD /path [json]   (# comments).  Only POST responses are captured: `{id}` in a path or body is
the `_id` of the most recent created node, `{id1}`, `{id2}`... the first, second... one; oids in the output are
normalised to <ID>."""
import sys, json, urllib.request, http.cookiejar, re, difflib
def client(base):
    jar = http.cookiejar.CookieJar()
    op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    def req(m, p, data=None, h={}):
        r = urllib.request.Request(base + p, data=data, method=m, headers=h)
        try:
            x = op.open(r); return x.status, x.read().decode()
        except urllib.error.HTTPError as e: return e.code, e.read().decode()
    req('GET', '/browser/')
    st, js = req('GET', '/browser/js/utils.js')
    tok = re.search(r"csrf_token'\] = '([^']*)'", js).group(1)
    hdr = {'X-pgA-CSRFToken': tok, 'Content-Type': 'application/json'}
    return lambda m, p, body=None: req(m, p, body.encode() if body else None, hdr)
steps = []
for line in open(sys.argv[1]):
    line = line.strip()
    if not line or line.startswith('#'): continue
    p = line.split(' ', 2)
    steps.append((p[0], p[1], p[2] if len(p) > 2 else None))
def run(call):
    out, ids = [], []
    for m, path, body in steps:
        def sub(s):
            if not s: return s
            s = s.replace('{id}', str(ids[-1]) if ids else '0')
            for n in range(1, 9):
                s = s.replace('{id%d}' % n, str(ids[n - 1]) if len(ids) >= n else '0')
            return s
        st, txt = call(m, sub(path), sub(body))
        try:
            j = json.loads(txt)
            node = j.get('node') if isinstance(j, dict) else None
            if node and '_id' in node and m == 'POST': ids.append(node['_id'])
        except Exception: pass
        out.append((m, sub(path), st, txt, list(ids)))
    return out
def norm(txt, ids):
    try: txt = json.dumps(json.loads(txt), indent=1, sort_keys=True)
    except Exception: pass
    for i in sorted(set(ids), key=lambda x: -len(str(x))):
        txt = re.sub(r'(?<![\d.])%s(?![\d.])' % i, '<ID>', txt)
    return txt
ra = run(client('http://127.0.0.1:5055')); rb = run(client('http://127.0.0.1:5056'))
bad = 0
for a, b in zip(ra, rb):
    na, nb = norm(a[3], a[4]), norm(b[3], b[4])
    if a[2] == b[2] and na == nb: print('OK   ', a[0], a[1], a[2])
    else:
        bad += 1
        print('DIFF ', a[0], a[1], a[2], b[2])
        for l in list(difflib.unified_diff(na.splitlines(), nb.splitlines(), 'ref', 'D', lineterm='', n=1))[:16]: print('     ', l[:200])
print('differences:', bad)
