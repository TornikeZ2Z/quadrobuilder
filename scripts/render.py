import json, sys
try: sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception: pass
data = json.load(open('data/processed/dashboard.json', encoding='utf-8'))
tpl  = open('scripts/template.html', encoding='utf-8').read()
i18n = open('scripts/i18n.js', encoding='utf-8').read()
html = tpl.replace('__I18N__', i18n)
html = html.replace('__DATA__', json.dumps(data, ensure_ascii=False, separators=(',',':')))
open('dashboard.html','w',encoding='utf-8').write(html)
print('dashboard.html', f'{len(html):,} bytes')
assert '__DATA__' not in html and '__I18N__' not in html
print('checks ok')
