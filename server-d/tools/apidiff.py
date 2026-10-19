"""apidiff.py paths-file  -- GETs every path on the reference (5055) and the D server (5056) and diffs the JSON."""
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
A, B = client('http://127.0.0.1:5055'), client('http://127.0.0.1:5056')
def norm(t):
    try: return json.dumps(json.loads(t), indent=1, sort_keys=True)
    except Exception: return t
bad = 0
for line in open(sys.argv[1]):
    line = line.strip()
    if not line or line.startswith('#'): continue
    parts = line.split(' ', 2)
    m, p = (parts[0], parts[1]) if parts[0] in ('GET', 'POST', 'PUT', 'DELETE') else ('GET', parts[0])
    body = parts[2] if len(parts) > 2 and parts[0] in ('POST', 'PUT', 'DELETE') else None
    sa, ta = A(m, p, body); sb, tb = B(m, p, body)
    na, nb = norm(ta), norm(tb)
    if sa == sb and na == nb: print('OK   ', m, p, sa)
    else:
        bad += 1
        print('DIFF ', m, p, sa, sb)
        for l in list(difflib.unified_diff(na.splitlines(), nb.splitlines(), 'ref', 'D', lineterm='', n=1))[:14]: print('     ', l[:160])
print('differences:', bad)
