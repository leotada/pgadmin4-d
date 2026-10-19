import os, sys, re, difflib
a, b = sys.argv[1], sys.argv[2]
def norm(x):
    x = re.sub(rb"nonce-[A-Za-z0-9_-]+", b"nonce-X", x)
    x = re.sub(rb"csrf_token'\] = '[^']*'", b"csrf_token'] = 'X'", x)
    x = re.sub(rb'"ver=\d+"', b'', x)
    return x
fa = {re.sub(r'^\d+_', '', f): f for f in os.listdir(a)}
fb = {re.sub(r'^\d+_', '', f): f for f in os.listdir(b)}
for k in sorted(fa):
    if k not in fb: print('MISSING in D:', k); continue
    x, y = norm(open(os.path.join(a, fa[k]), 'rb').read()), norm(open(os.path.join(b, fb[k]), 'rb').read())
    if x == y: print('same   ', k)
    else:
        print('DIFF   ', k, len(x), len(y))
        if len(sys.argv) > 3 and sys.argv[3] in k:
            for l in list(difflib.unified_diff(x.decode().splitlines(), y.decode().splitlines(), lineterm='', n=0))[:int(sys.argv[4]) if len(sys.argv) > 4 else 20]: print('   ', l[:200])
