import sys, json, urllib.request, http.cookiejar, re
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
path = sys.argv[1] if len(sys.argv) > 1 else '/usr/bin'
paths = [{"version": str(v * 10000), "next_major_version": str((v + 1) * 10000), "serverType": "PostgreSQL %d" % v,
          "binaryPath": path if v == 18 else None, "isDefault": v == 18} for v in range(13, 19)]
for base in ('http://127.0.0.1:5055', 'http://127.0.0.1:5056'):
    c = client(base)
    body = json.dumps({"pref_data": json.dumps([{"module": "paths", "name": "pg_bin_dir", "value": json.dumps(paths)}])})
    print(base, c('PUT', '/preferences/update', body))
