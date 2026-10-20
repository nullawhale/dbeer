"""Independent complete Settings/library DTO expectations from fixed source."""
from __future__ import annotations
import uuid
from core import Refused, canonical, digest_bytes, parse, read


def color(value):
    digits = value.removeprefix('#')
    if len(digits) == 6:
        digits += 'ff'
    return dict(zip(('red', 'green', 'blue', 'alpha'), (int(digits[i:i + 2], 16) / 255.0 for i in (0, 2, 4, 6))))


def imported_theme(identifier):
    try:
        suffix = identifier.removeprefix('imported-')
        valid = identifier.startswith('imported-') and str(uuid.UUID(suffix)) == suffix and uuid.UUID(suffix).int != 0
    except (ValueError, AttributeError):
        valid = False
    if not valid:
        raise Refused('A genuinely discovered canonical imported theme UUID is required.')
    return {'id': identifier, 'name': 'Library Preview Fixture', 'appearance': 'dark', 'isImported': True,
            'colors': {'editor.background': color('#18232D'), 'editor.foreground': color('#FAF1DC'),
                       'editor.selectionBackground': color('#DDAA6633')},
            'tokenRules': [{'scopes': [scope], 'style': {'foreground': color(foreground), 'background': None, 'fontStyle': style}}
                           for scope, foreground, style in [('keyword.control.sql', '#EDAB61', 'bold'),
                                                            ('string.quoted.sql', '#83CEADCC', '')]]}


def library(root):
    value = parse(read(root / 'themes.json', 16 * 1024 * 1024))
    if (not isinstance(value, dict) or set(value) != {'version', 'themes'} or type(value['version']) is not int
            or value['version'] != 1 or not isinstance(value['themes'], list) or len(value['themes']) > 64):
        raise Refused('Exact normalized imported library schema required.')
    ids = [theme.get('id') for theme in value['themes'] if isinstance(theme, dict)]
    if len(ids) != len(value['themes']) or any(not isinstance(identifier, str) for identifier in ids) or len(set(ids)) != len(ids):
        raise Refused('Normalized imported library identities are invalid or duplicated.')
    return value


def discover_imported(before, root):
    actual = library(root)
    previous = {theme['id']: theme for theme in before['themes']}
    current = {theme['id']: theme for theme in actual['themes']}
    added = set(current) - set(previous)
    if (len(added) != 1 or not set(previous).issubset(current)
            or any(canonical(current[key]) != canonical(value) for key, value in previous.items())):
        raise Refused('Exactly one committed normalized import with original library preserved is required.')
    identifier = next(iter(added))
    if canonical(current[identifier]) != canonical(imported_theme(identifier)):
        raise Refused('Committed theme differs from independent source colors/scopes/styles.')
    return identifier


def expect(root, key, theme=None):
    base = {'version': 1, 'appearanceTheme': 'light', 'applicationColorTheme': 'native', 'editorColorTheme': 'native-dark'}
    appearance = {
        'independentChoices': base,
        'systemFollowing': {**base, 'appearanceTheme': 'system', 'editorColorTheme': 'automatic'},
        'afterImported': {**base, 'editorColorTheme': theme},
        'newerEditorChoice': {**base, 'editorColorTheme': 'solarized-light'},
        'afterRemoved': {**base, 'editorColorTheme': 'automatic'},
        'unrelatedChoiceAfterRemoved': {**base, 'editorColorTheme': 'solarized-light'},
        'appearanceDefaults': {**base, 'appearanceTheme': 'system', 'editorColorTheme': 'automatic'},
    }
    if key in ('afterImported', 'libraryImported'):
        imported_theme(theme)
    if key in appearance:
        filename, expected = 'appearance.json', appearance[key]
    elif key in ('explicitUnbind', 'shortcutDefaults'):
        filename = 'shortcuts.json'
        expected = {'version': 1, 'overrides': [] if key == 'shortcutDefaults' else
                    [{'command': 'query.runCurrent', 'binding': {'state': 'unbound'}}]}
    elif key in ('libraryImported', 'libraryEmpty'):
        filename, expected = 'themes.json', {'version': 1, 'themes': [imported_theme(theme)] if key == 'libraryImported' else []}
    else:
        raise Refused('Unsupported independent complete Settings expectation.')
    actual = parse(read(root / filename, 16 * 1024 * 1024))
    if canonical(actual) != canonical(expected):
        raise Refused('Complete saved Settings DTO differs from the fixed independent expectation.')
    return {'settingsKey': key, 'settingsSha256': digest_bytes(canonical(expected)), 'independentExpectedDTO': True}
