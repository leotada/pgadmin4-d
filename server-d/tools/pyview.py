"""Print Python source without comments, docstrings and blank lines (compact reading)."""
import sys, io, tokenize, ast
src = open(sys.argv[1]).read()
tree = ast.parse(src)
doc_lines = set()
for node in ast.walk(tree):
    if isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
        if node.body and isinstance(node.body[0], ast.Expr) and isinstance(getattr(node.body[0], 'value', None), ast.Constant) and isinstance(node.body[0].value.value, str):
            for l in range(node.body[0].lineno, node.body[0].end_lineno + 1): doc_lines.add(l)
# lines inside multi-line string literals must be kept verbatim (blank lines matter there)
keep = set()
for tok in tokenize.generate_tokens(io.StringIO(src).readline):
    if tok.type == tokenize.STRING and tok.end[0] > tok.start[0]:
        for l in range(tok.start[0] + 1, tok.end[0] + 1): keep.add(l)
    if tok.type == tokenize.FSTRING_MIDDLE if hasattr(tokenize, 'FSTRING_MIDDLE') else False:
        pass
out = []
for i, line in enumerate(src.split('\n'), 1):
    if i in keep and i not in doc_lines:
        out.append(line.rstrip()); continue
    if i in doc_lines: continue
    s = line.rstrip()
    # drop full-line comments
    if s.strip().startswith('#'): continue
    if not s.strip(): continue
    out.append(s)
lo = int(sys.argv[2]) if len(sys.argv) > 2 else 0
hi = int(sys.argv[3]) if len(sys.argv) > 3 else len(out)
print('\n'.join(out[lo:hi]))
