import re, pathlib
M = {'orange': 'Theme.warning', 'red': 'Theme.danger', 'green': 'Theme.success', 'blue': 'Theme.info'}
changed = 0
for p in pathlib.Path('TripPlanner').rglob('*.swift'):
    s = str(p)
    if any(x in s for x in ('/DesignSystem/', '/Services/', '/Models/', 'Features/Transit', 'Features/Export')): continue
    t = p.read_text(); o = t
    t = re.sub(r'\bColor\.(orange|red|green|blue)\b', lambda m: M[m.group(1)], t)
    t = re.sub(r'\.(foregroundStyle|tint)\(\.(orange|red|green|blue)\)', lambda m: f'.{m.group(1)}({M[m.group(2)]})', t)
    t = re.sub(r'\bColor\.accentColor\b', 'Theme.accent', t)
    t = re.sub(r'\bColor\.secondary\b', 'Theme.inkSecondary', t)
    t = re.sub(r'\bColor\.primary\b', 'Theme.ink', t)
    t = t.replace('.foregroundStyle(.secondary)', '.foregroundStyle(Theme.inkSecondary)')
    t = t.replace('.tint(.indigo)', '.tint(Theme.accent)')
    if t != o: p.write_text(t); changed += 1
print(changed, 'files changed')
