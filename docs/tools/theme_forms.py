"""Themes every `Form { ... }` in the given Swift files: hides the system grouped background, uses
Theme.background, and gives every Section's rows Theme.surface (the section's row closure is wrapped in
`Group { ... }.listRowBackground(Theme.surface)`). Safe to run twice. Run from the repo root.
Usage: python3 theme_forms.py File.swift [...]"""
import re, sys

def match_brace(s, i):
    depth = 0
    while i < len(s):
        c = s[i]
        if c == '"':                       # skip a string literal
            i += 1
            while s[i] != '"':
                i += 2 if s[i] == '\\' else 1
        elif c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                return i
        i += 1
    raise ValueError("unbalanced")

SECTION = re.compile(r'(?m)^([ ]*)Section(\([^)]*\))? \{\n')

def wrap_sections(s):
    out, pos = [], 0
    for m in SECTION.finditer(s):
        if m.start() < pos: continue
        indent = m.group(1)
        open_i = m.end() - 2
        close_i = match_brace(s, open_i)
        body = s[open_i + 1:close_i]
        if 'listRowBackground' in body: continue
        lines = body.split('\n')
        inner = lines[1:-1]
        indented = '\n'.join(('    ' + l if l.strip() else l) for l in inner)
        out.append(s[pos:open_i + 1])
        out.append('\n' + indent + '    Group {\n' + indented + '\n' + indent + '    }\n' + indent + '    .listRowBackground(Theme.surface)\n' + indent)
        pos = close_i
    out.append(s[pos:])
    return ''.join(out)

def theme_file(s):
    result, pos = [], 0
    for m in re.finditer(r'(?m)^([ ]*)Form \{\n', s):
        if m.start() < pos: continue
        indent = m.group(1)
        open_i = m.end() - 2
        close_i = match_brace(s, open_i)
        body = s[open_i:close_i + 1]
        after = s[close_i + 1:close_i + 120]
        new_body = wrap_sections(body)
        result.append(s[pos:open_i])
        result.append(new_body)
        if '.scrollContentBackground(.hidden)' not in after:
            result.append('\n' + indent + '.scrollContentBackground(.hidden)\n' + indent + '.background(Theme.background)')
        pos = close_i + 1
    result.append(s[pos:])
    return ''.join(result)

for path in sys.argv[1:]:
    s = open(path).read()
    open(path, 'w').write(theme_file(s))
    print('themed', path)
