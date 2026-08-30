"""Render dashboard.html from the template, the string catalogue and the data.

A stray apostrophe in the catalogue once shipped a blank page to production, so
nothing is written to disk until the page's own <script> block parses.
"""
import json, os, re, subprocess, sys, tempfile

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

data = json.load(open('data/processed/dashboard.json', encoding='utf-8'))
tpl  = open('scripts/template.html', encoding='utf-8').read()
i18n = open('scripts/i18n.js', encoding='utf-8').read()

html = tpl.replace('__I18N__', i18n)
html = html.replace('__DATA__', json.dumps(data, ensure_ascii=False, separators=(',', ':')))

# ---- gates, all before anything is written --------------------------------
assert '__DATA__' not in html and '__I18N__' not in html, 'placeholder left unreplaced'

m = re.search(r'<script>(.*)</script>', html, re.S)
assert m, 'no <script> block found'
fd, tmp = tempfile.mkstemp(suffix='.js')
os.close(fd)
open(tmp, 'w', encoding='utf-8').write(m.group(1))
r = subprocess.run(['node', '--check', tmp], capture_output=True, text=True)
os.unlink(tmp)
if r.returncode:
    print('JS SYNTAX ERROR — refusing to write dashboard.html')
    print(r.stderr[:1200])
    raise SystemExit(1)

for key in ('DICT', 'function T(', 'render()'):
    assert key in html, f'missing {key!r}'

open('dashboard.html', 'w', encoding='utf-8').write(html)
print(f'dashboard.html {len(html):,} bytes — js syntax ok, checks ok')
