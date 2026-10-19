"""Derive bounded format facts from a pinned public Hancom source snapshot.

Input: JSON {commit, sources:{path:{content,sha}}, enums:{content,sha}}.
This is a lexical catalog, NOT a C++ compiler, schema validator, or editor.
Never reads or executes installed Hancom binaries. Python is development-only.
"""
import argparse
import hashlib
import json
import re
from pathlib import Path

TOKEN = re.compile(r'//[^\n]*|/\*[\s\S]*?\*/|L?"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'')


def lexical(source, mask_strings=False):
    def replace(match):
        text = match.group()
        if text.startswith('//') or text.startswith('/*') or mask_strings:
            return ''.join('\n' if c == '\n' else ' ' for c in text)
        return text
    return TOKEN.sub(replace, source)


def parse_enums(source):
    clean = lexical(source)
    return {m[1]: re.findall(r'L"([^"\\]*)"', m[2]) for m in re.finditer(
        r'\bstatic\s+const\s+ENUMLIST\s+(g_\w+)\s*\[\s*\]\s*=\s*\{([\s\S]*?)\};', clean)}


def parse_classes(path, source):
    clean = lexical(source)
    masked = lexical(source, True)
    result = {}
    for method in re.finditer(r'\b(\w+)::(WriteElement|WriteAttribute|SetAttribute|ReadAttribute|InitMap)\s*\([^;{}]*\)\s*\{', masked):
        name, action = method[1], method[2]
        depth, end = 1, method.end()
        while end < len(masked) and depth:
            if masked[end] == '{':
                depth += 1
            elif masked[end] == '}':
                depth -= 1
            end += 1
        if depth:
            raise ValueError(f'Unbalanced {path}:{name}::{action}')
        body = clean[method.end():end - 1]
        facts = result.setdefault(name, dict(source=path, writeAttributes=[], readAttributes=[],
                                           children=[], baseCalls=[], unresolvedAttributeCalls=0))
        if action in ('WriteElement', 'WriteAttribute', 'SetAttribute', 'ReadAttribute'):
            verb = 'GetAttribute' if action == 'ReadAttribute' else 'SetAttribute'
            attributes = []
            for call in re.finditer(r'\b' + verb + r'\s*\(([^;]*?)\)\s*;', body):
                literal = re.match(r'\s*att\s*,\s*L"([^"\\]+)"\s*,([\s\S]*)', call[1])
                if not literal:
                    facts['unresolvedAttributeCalls'] += 1
                    continue
                attribute = {'name': literal[1]}
                enum = re.search(r'\b(g_\w+)\b', literal[2])
                if enum:
                    attribute['enum'] = enum[1]
                if attribute not in attributes:
                    attributes.append(attribute)
            key = 'readAttributes' if action == 'ReadAttribute' else 'writeAttributes'
            for attribute in attributes:
                if attribute not in facts[key]:
                    facts[key].append(attribute)
        if action == 'InitMap':
            facts['children'] = [dict(element=m[1], **{'class': m[2]}, id=m[3]) for m in re.finditer(
                r'\bOWPML_\w*ADD_REDIRECT_FUNC\s*\(\s*(\w+)\s*,\s*(\w+)\s*,\s*(\w+)\s*\)', body)]
        for base in re.finditer(r'\b(\w+)::(WriteElement|WriteAttribute|SetAttribute|ReadAttribute|InitMap)\s*\(', body):
            value = base[1] + '::' + base[2]
            if base[1] not in (name, 'CXMLAttConverter') and value not in facts['baseCalls']:
                facts['baseCalls'].append(value)
    return result


def build(snapshot):
    classes, files = {}, []
    for path, source in sorted(snapshot['sources'].items()):
        if not path.startswith('OWPML/Class/') or not path.endswith('.cpp'):
            raise ValueError('Snapshot contains a file outside OWPML/Class/*.cpp')
        parsed = parse_classes(path, source['content'])
        for name, facts in parsed.items():
            if name in classes:
                raise ValueError(f'Duplicate model class {name}')
            classes[name] = facts
        files.append(dict(path=path, gitBlob=source['sha'],
                          sha256=hashlib.sha256(source['content'].encode('utf-8')).hexdigest(),
                          classes=len(parsed)))
    enums = parse_enums(snapshot['enums']['content'])
    element_names = {}
    for facts in classes.values():
        for child in facts['children']:
            element_names.setdefault(child['class'], set()).add(child['element'])
    for name, facts in classes.items():
        facts['elements'] = sorted(element_names.get(name, []))
        facts['baseCalls'].sort()
    return dict(version='1.0', source=dict(repository='hancom-io/hwpx-owpml-model',
                commit=snapshot['commit'], license='Apache-2.0', files=files,
                enumGitBlob=snapshot['enums']['sha']),
                scope='Literal read/write attributes, child registrations and enum strings only.',
                semanticAuditComplete=False, inheritanceResolved=False,
                limitations=['Not a schema validator or all-features implementation.',
                             'Base method calls, conditions, defaults and native layout are not evaluated.',
                             'Element aliases are observed registrations, not a unique XPath.'],
                counts=dict(files=len(files), classes=len(classes), enums=len(enums),
                            writeAttributes=sum(len(x['writeAttributes']) for x in classes.values()),
                            childRegistrations=sum(len(x['children']) for x in classes.values()),
                            unresolvedAttributeCalls=sum(x['unresolvedAttributeCalls'] for x in classes.values())),
                classes=dict(sorted(classes.items())), enums=dict(sorted(enums.items())))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('snapshot', type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    data = build(json.loads(args.snapshot.read_text(encoding='utf-8-sig')))
    args.output.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(data['counts']))
