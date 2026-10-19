"""gentest.py <nodetype> <parent-path-with-trailing-slash> [limit]  e.g. aggregate /1/1/5/16391/
Asks the reference for the nodes and prints a path list exercising the standard endpoints of each."""
import sys, json, urllib.request, http.cookiejar, re
node, parent = sys.argv[1], sys.argv[2]
limit = int(sys.argv[3]) if len(sys.argv) > 3 else 3
base = 'http://127.0.0.1:5055'
jar = http.cookiejar.CookieJar(); op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
def req(m, p, data=None, h={}):
    r = urllib.request.Request(base + p, data=data, method=m, headers=h)
    try: x = op.open(r); return x.status, x.read().decode()
    except urllib.error.HTTPError as e: return e.code, e.read().decode()
req('GET', '/browser/'); st, js = req('GET', '/browser/js/utils.js')
tok = re.search(r"csrf_token'\] = '([^']*)'", js).group(1)
h = {'X-pgA-CSRFToken': tok, 'Content-Type': 'application/json'}
req('POST', '/browser/server/connect/1/1', b'{"password":"postgres"}', h); req('POST', '/browser/database/connect/1/1/5', b'', h)
st, t = req('GET', '/browser/%s/nodes%s' % (node, parent), None, h)
d = json.loads(t).get('data') if st == 200 else []
if isinstance(d, dict): d = [d]
print('# %s nodes: %d' % (node, len(d or [])))
print('POST /browser/server/connect/1/1 {"password":"postgres"}'); print('POST /browser/database/connect/1/1/5')
for cmd in ['nodes', 'obj', 'sql', 'stats', 'dependency', 'dependent', 'children', 'msql']:
    print('GET /browser/%s/%s%s' % (node, cmd, parent))
for n in (d or [])[:limit]:
    i = n['_id']
    for cmd in ['nodes', 'obj', 'sql', 'stats', 'dependency', 'dependent', 'children', 'msql']:
        print('GET /browser/%s/%s%s%s' % (node, cmd, parent, i))
