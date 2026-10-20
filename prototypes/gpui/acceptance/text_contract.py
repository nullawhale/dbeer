"""Independent UTF-16/text expectations; never derive expected text from UI."""
from core import Refused, canonical, digest_bytes


def utf16_length(text):
    return len(text.encode('utf-16-le')) // 2


def codepoint_offset(text, offset):
    if type(offset) is not int or offset < 0:
        raise Refused('Original UTF-16 offset is invalid.')
    total = 0
    for index, character in enumerate(text):
        if total == offset:
            return index
        total += utf16_length(character)
    if total == offset:
        return len(text)
    raise Refused('UTF-16 offset splits a surrogate or is outside the original source.')


def expected_text(text, start, end):
    if not isinstance(text, str) or len(text.encode()) > 65536 or type(end) is not int or end < start:
        raise Refused('Fixed text/range exceeds bounds or is reversed.')
    first, last = codepoint_offset(text, start), codepoint_offset(text, end)
    return {'textSha256': digest_bytes(text.encode()), 'utf16Length': utf16_length(text),
            'selections': [{'start': start, 'end': end,
                            'textSha256': digest_bytes(text[first:last].encode())}]}


def assert_text(actual, expected):
    if not isinstance(actual, dict) or canonical(actual) != canonical(expected):
        raise Refused('Original native text/UTF-16 selection differs from fixed source expectations.')
    return {'textRangeSha256': digest_bytes(canonical(expected)), 'nativeUTF16RangeVerified': True,
            'selectionCount': len(expected['selections']), 'utf16Length': expected['utf16Length']}


def assert_semantics(actual, expected):
    allowed = {'enabled', 'focused', 'readOnly', 'selected', 'nameSha256', 'descriptionSha256',
               'row', 'column', 'rowCount', 'columnCount', 'rowSpan', 'columnSpan'}
    if not isinstance(actual, dict) or not isinstance(expected, dict) or not expected or set(expected) - allowed:
        raise Refused('Independent native semantic expectation is empty or unsupported.')
    for key, value in expected.items():
        if key in ('enabled', 'focused', 'readOnly', 'selected'):
            valid = type(value) is bool
        elif key.endswith('Sha256'):
            valid = isinstance(value, str) and len(value) == 64 and all(c in '0123456789abcdef' for c in value)
        else:
            valid = type(value) is int and value >= 0
        if not valid or key not in actual or canonical(actual[key]) != canonical(value):
            raise Refused('Original typed/native semantic expectation differs or is unsupported.')
    return {'semanticExpectationSha256': digest_bytes(canonical(expected)),
            'independentNativeSemanticFields': sorted(expected)}
