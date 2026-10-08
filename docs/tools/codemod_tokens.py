import re, sys, pathlib
SP = {4:'xs', 5:'xs', 6:'s', 8:'s', 9:'s', 10:'m', 12:'m', 14:'l', 16:'l', 18:'l', 24:'xl', 32:'xxl'}
def radius(n):
    return 'Radius.small' if n <= 12 else 'Radius.card' if n <= 22 else 'Radius.hero'
pad_re = re.compile(r'(\.padding\((?:\.[A-Za-z]+(?:, *\.[A-Za-z]+)*, *)?)(\d+)\)')
rad_re = re.compile(r'RoundedRectangle\(cornerRadius: (\d+)\)')
spc_re = re.compile(r'\bspacing: *(\d+)\b')
changed = {}
for p in pathlib.Path('TripPlanner').rglob('*.swift'):
    s = str(p)
    if '/DesignSystem/' in s or '/Services/' in s or '/Models/' in s: continue
    t = p.read_text(); o = t
    t = rad_re.sub(lambda m: f'Radius.shape({radius(int(m.group(1)))})', t)
    t = pad_re.sub(lambda m: m.group(1) + (f'Spacing.{SP[int(m.group(2))]})' if int(m.group(2)) in SP else m.group(2) + ')'), t)
    out = []
    for line in t.split('\n'):
        if 'Stack(' in line or 'Grid(' in line:
            line = spc_re.sub(lambda m: f'spacing: Spacing.{SP[int(m.group(1))]}' if int(m.group(1)) in SP else m.group(0), line)
        out.append(line)
    t = '\n'.join(out)
    if t != o:
        p.write_text(t); changed[s] = 1
print(len(changed), 'files changed')
