"""Tiny API client: api.py <base> METHOD /path [json-body]  (keeps a cookie jar per base, fetches the CSRF token)"""
import sys, json, urllib.request, http.cookiejar, re, os
base, method, path = sys.argv[1], sys.argv[2], sys.argv[3]
body = sys.argv[4] if len(sys.argv) > 4 else None
jar = http.cookiejar.MozillaCookieJar('/tmp/jar_%s.txt' % base.split(':')[-1])
try: jar.load(ignore_discard=True)
except Exception: pass
op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
def req(m, p, data=None, headers={}):
    r = urllib.request.Request(base + p, data=data, method=m, headers=headers)
    try:
        resp = op.open(r); return resp.status, resp.read().decode()
    except urllib.error.HTTPError as e: return e.code, e.read().decode()
req('GET', '/browser/')
st, js = req('GET', '/browser/js/utils.js')
tok = re.search(r"csrf_token'\] = '([^']*)'", js).group(1)
h = {'X-pgA-CSRFToken': tok, 'Content-Type': 'application/json'}
st, out = req(method, path, body.encode() if body else None, h)
jar.save(ignore_discard=True)
print(st); print(out[:int(os.environ.get('MAXOUT', '3000'))])
