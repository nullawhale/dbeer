"""Validate the exact manually reviewed standalone unit graphs before building."""
from pathlib import Path
import hashlib
import json
import re
import textwrap

CRATES = ('gpui-pre', 'gpui-base', 'gpui-component', 'gpui-pre-linux')
UNIT_MANIFESTS = {crate: 'prototypes/gpui/vendor/' + crate + '/Cargo.toml'
                  for crate in ('gpui-base', 'gpui-component')}
UNIT_MANIFESTS['gpui-pre-linux'] = 'prototypes/gpui/verification/pre-linux-unit/Cargo.toml'
PUBLIC_ELEMENT_SOURCE = 'prototypes/gpui/tests/maintained_pre_disabled.rs'
DIV_SOURCE = 'prototypes/gpui/vendor/gpui-pre/src/elements/div.rs'
DISABLED_UNIT = 'test_explicit_disabled_semantics_preserve_the_unspecified_default'


def public_element_unit(repo):
    """Bind the independent assertions to the actual maintained public writer.

    The original own test needs private Interactivity access. Public Element
    delegates to that same writer; only that access and unused local mutability
    differ. No production logic is copied into this integration target.
    """
    original = (repo / DIV_SOURCE).read_text(encoding='utf-8')
    matches = re.findall(r'^    #\[test\]\n    fn ' + DISABLED_UNIT + r'\(\) \{\n.*?^    \}\n', original, re.M | re.S)
    if len(matches) != 1:
        raise ValueError('The exact original maintained Div unit is required once.')
    unit = matches[0]
    adapted = textwrap.dedent(unit).replace('.interactivity().write_a11y_info(', '.write_a11y_info(')
    for local in ('ordinary', 'disabled', 'enabled'):
        adapted = adapted.replace('let mut ' + local + ' =', 'let ' + local + ' =')
    expected = '//! Faithful public Element-path alternative for the maintained Div disabled unit.\n'
    expected += 'use gpui_kit::{Element, InteractiveElement, StatefulInteractiveElement, accesskit, div};\n\n' + adapted
    if (repo / PUBLIC_ELEMENT_SOURCE).read_text(encoding='utf-8') != expected:
        raise ValueError('Public Element integration differs from the exact original unit adaptation.')
    return {'kind': 'faithful-public-element-integration', 'manifest': 'prototypes/gpui/Cargo.toml',
            'lock': 'prototypes/gpui/Cargo.lock', 'testTarget': 'maintained_pre_disabled', 'test': DISABLED_UNIT,
            'source': PUBLIC_ELEMENT_SOURCE, 'sourceSha256': digest(repo / PUBLIC_ELEMENT_SOURCE),
            'originalSource': DIV_SOURCE, 'originalSourceSha256': digest(repo / DIV_SOURCE),
            'originalUnit': 'elements::div::tests::' + DISABLED_UNIT,
            'originalUnitBodySha256': hashlib.sha256(unit.encode()).hexdigest(),
            'adaptation': 'Public Element writer replaces private Interactivity access; remove only the three unused element mut bindings.',
            'originalStandaloneLibraryUnit': 'not-executed-upstream-cfg-test-prerequisites',
            'graph': 'existing-root-lock-850-packages-no-dependency-change'}


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def lock_packages(path):
    # Cargo's generated lock format has bounded quoted ASCII identity fields.
    # Dependency arrays remain bound by the exact complete lock-file digest.
    result = {}
    for block in re.findall(r'^\[\[package\]\]\n(.*?)(?=^\[\[|\Z)', Path(path).read_text(encoding='utf-8'), re.M | re.S):
        fields = re.findall(r'^(name|version|source|checksum) = "([^"\n]+)"$', block, re.M)
        row = dict(fields)
        if len(row) != len(fields) or not {'name', 'version'} <= set(row):
            raise ValueError('Generated Cargo lock package identity is invalid.')
        identity = (row['name'], row['version'])
        if identity in result:
            raise ValueError('Duplicate Cargo package identity requires explicit source review.')
        result[identity] = row
    if not result:
        raise ValueError('Nonempty generated Cargo package graph required.')
    return result


def graph_delta(root_lock, unit_lock):
    root, unit = lock_packages(root_lock), lock_packages(unit_lock)
    root_names = {name for name, _ in root}
    return {'rootPackageCount': len(root), 'unitPackageCount': len(unit),
            'rootKnownAdditionalVersions': [list(key) for key in sorted(unit.keys() - root.keys()) if key[0] in root_names],
            'rootKnownSourceOrChecksumChanges': [
                {'name': key[0], 'version': key[1], 'root': {k: root[key].get(k) for k in ('source', 'checksum')},
                 'unit': {k: unit[key].get(k) for k in ('source', 'checksum')}}
                for key in sorted(root.keys() & unit.keys()) if any(root[key].get(k) != unit[key].get(k) for k in ('source', 'checksum'))],
            'unitOnlyPackages': [list(key) for key in sorted(unit.keys() - root.keys())],
            'rootOnlyPackages': [list(key) for key in sorted(root.keys() - unit.keys())]}


def source_inputs(repo):
    paths = []
    for crate in CRATES:
        for path in (repo / 'prototypes/gpui/vendor' / crate).rglob('*'):
            if any(part in ('target', '__pycache__', '.git') for part in path.relative_to(repo).parts):
                continue
            if path.is_symlink():
                raise ValueError('Reviewed maintained source cannot contain a symlink.')
            if path.is_file():
                paths.append(path)
    paths += [repo / name for name in ('prototypes/gpui/Cargo.toml', 'prototypes/gpui/Cargo.lock', 'prototypes/gpui/README.md',
                                      'prototypes/gpui/verification/pre-linux-unit/Cargo.toml',
                                      'prototypes/gpui/verification/pre-linux-unit/Cargo.lock',
                                      'prototypes/gpui/verification/pre-linux-unit/inputs.json')]
    return {path.relative_to(repo).as_posix(): digest(path) for path in sorted(paths)}


def verify_provenance(repo):
    result = {}
    for crate in ('gpui-pre', 'gpui-base', 'gpui-component'):
        root = repo / 'prototypes/gpui/vendor' / crate
        original = {}
        for line in (root / 'UPSTREAM.sha256').read_text(encoding='utf-8').splitlines():
            checksum, relative = line.split('  ', 1)
            if not re.fullmatch('[0-9a-f]{64}', checksum) or relative in original:
                raise ValueError('Upstream source digest inventory is invalid.')
            original[relative] = checksum
        audit = json.loads((root / 'LOCAL-CHANGES.json').read_text(encoding='utf-8'))
        changed = {row['path']: row for row in audit['changes']}
        omitted = {item.split(' (', 1)[0] for item in audit['omitted']}
        if len(changed) != len(audit['changes']) or audit['upstream_package'] != crate:
            raise ValueError('Maintained source change inventory is invalid.')
        for relative, row in changed.items():
            if row['upstream_sha256'] != original.get(relative) or row['local_sha256'] != digest(root / relative):
                raise ValueError('Maintained source differs from its declared exact local patch.')
        for relative, checksum in original.items():
            if relative not in changed and relative not in omitted and digest(root / relative) != checksum:
                raise ValueError('Unchanged maintained source differs from its original upstream bytes.')
        result[crate] = {'originalFiles': len(original), 'declaredChanges': len(changed),
                         'localAuditSha256': digest(root / 'LOCAL-CHANGES.json')}
    return result


def verify_dependency_review(repo):
    path = repo / 'prototypes/gpui/verification/dependency-inputs.json'
    review = json.loads(path.read_text(encoding='utf-8'))
    expected = {crate: 'prototypes/gpui/vendor/' + crate for crate in CRATES}
    if (review['schemaVersion'] != 1 or review['patches'] != expected
            or review['files'] != source_inputs(repo) or review['testsExecuted'] is not False):
        raise ValueError('Reviewed maintained source/patch inputs changed; no automatic drift acceptance.')
    if review.get('publicElementUnit') != public_element_unit(repo):
        raise ValueError('The faithful public Element integration contract changed.')
    units = review['unitGraphs']
    if len(units) != len(UNIT_MANIFESTS) or {unit['id'] for unit in units} != set(UNIT_MANIFESTS):
        raise ValueError('Every exact maintained changed unit graph is required once.')
    for unit in units:
        manifest = UNIT_MANIFESTS[unit['id']]
        if (unit['manifest'] != manifest or unit['lock'] != manifest.replace('Cargo.toml', 'Cargo.lock')
                or digest(repo / unit['manifest']) != unit['manifestSha256']
                or digest(repo / unit['lock']) != unit['lockSha256']
                or graph_delta(repo / 'prototypes/gpui/Cargo.lock', repo / unit['lock']) != unit['graphDelta']
                or unit['graphDelta']['rootKnownSourceOrChecksumChanges']):
            raise ValueError('Standalone graph differs from its exact reviewed dependency/source delta.')
    return {'reviewSha256': digest(path), 'rootLockSha256': digest(repo / 'prototypes/gpui/Cargo.lock'),
            'patches': expected, 'sourceFiles': len(review['files']), 'provenance': verify_provenance(repo)}
