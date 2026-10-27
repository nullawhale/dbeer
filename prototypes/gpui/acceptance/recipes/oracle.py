"""Pure synthetic expectations. No application, transport, store or DB imports.

Values follow the checked-in SQL corpus, not a response or exported file. Public
functions never print values. These are assertion inputs, not native evidence.
"""
from __future__ import annotations

import hashlib
import json

ENGINES = ("postgresql", "mysql")
SPECIAL = 'e\u0301, "\U0001f600"\r\n\u4e16\u754c'
COUNT = {"postgresql": 1205, "mysql": 1005}
NULL_MARKER = "<DBEER-SQL-NULL>"


def engine_check(engine):
    if engine not in ENGINES:
        raise ValueError("An exact supported engine family is required.")


def canonical(value):
    """Matches acceptance.core canonical: ASCII escapes, sorted keys, final LF."""
    return (json.dumps(value, ensure_ascii=True, sort_keys=True,
                       separators=(",", ":")) + "\n").encode()


def sha(data):
    return hashlib.sha256(data).hexdigest()


def native_text_sha(text):
    if not isinstance(text, str):
        raise ValueError("Native text hash needs exact known synthetic text.")
    return sha(text.encode())


def columns(engine, shape):
    """Pinned metadata for direct table fields; never takes actual columns.

    MySQL TEXT is a nonbinary BLOB field. Its BLOB payload has Base64 encoding.
    PostgreSQL native names/OIDs follow the declared types and the pgx type map.
    COUNT/routine/literal expressions deliberately have no guessed metadata.
    """
    engine_check(engine)
    declared = {
        "values-head": [("id", "int8", "BIGINT", 20),
                        ("label", "text", "VARCHAR", 25),
                        ("exact_value", "numeric", "DECIMAL", 1700),
                        ("payload", "bytea", "BLOB", 17),
                        ("computed_length", "int4", "INT", 23)],
        "duplicate-values": [("x", "text", "VARCHAR", 25),
                             ("x", "numeric", "DECIMAL", 1700),
                             ("payload", "bytea", "BLOB", 17)],
        "composite": [("a", "int4", "INT", 23), ("b", "int4", "INT", 23),
                      ("label", "text", "BLOB", 25)],
        "acceptance-effects": [("case_id", "text", "VARCHAR", 25), ("commits", "int4", "INT", 23)],
        "acceptance-receipts": [("case_id", "text", "VARCHAR", 25),
                                ("statement_ordinal", "int4", "INT", 23), ("marker", "int4", "INT", 23)],
        "acceptance-apply": [("id", "int4", "INT", 23), ("label", "text", "VARCHAR", 25),
                             ("exact_value", "numeric", "DECIMAL", 1700),
                             ("payload", "bytea", "BLOB", 17), ("computed_length", "int4", "INT", 23)],
    }
    if shape not in declared:
        raise ValueError("No independently reviewed metadata for this shape.")
    result = []
    for index, (name, pg_type, my_type, oid) in enumerate(declared[shape]):
        column = {"index": index, "name": name, "engine": engine,
                  "nativeType": pg_type if engine == "postgresql" else my_type}
        if oid == 17:
            column["encoding"] = "base64"
        if engine == "postgresql":
            column["typeOid"] = oid
        result.append(column)
    return result


def head_rows():
    return [["1", None, "9007199254740993.123456789000000000", "AP8=", None],
            ["2", "", "-0.000000000000000001", "", "0"],
            ["3", "NULL", None, None, "4"],
            ["4", SPECIAL, "1.000000000000000000", "AA==", "11"],
            ["5", "\\N", "2.000000000000000000", None, "2"]]


def composite_rows(suffix=""):
    if suffix not in ("", "!", "!!"):
        raise ValueError("Only fixed exactly-once fixture outcomes are allowed.")
    return [["1", "1", "one"], ["1", "2", "two"], ["2", "1", "three" + suffix]]


def snapshot(engine, shape, *, suffix=""):
    engine_check(engine)
    if shape == "values-head":
        rows = head_rows()
    elif shape == "composite":
        rows = composite_rows(suffix)
    elif shape == "acceptance-effects":
        rows = [["apply-commit", "0"], ["full-export", "0"], ["sql-commit", "0"]]
    elif shape == "acceptance-receipts":
        rows = [["script-first-error", "0", "0"], ["script-middle-error", "0", "0"]]
    elif shape == "acceptance-apply":
        rows = [["1", "before", "1.000000000000000000", "AP8=", "6"],
                ["2", "second", "2.000000000000000000", None, "6"]]
    else:
        raise ValueError("Unsupported fixed observer case.")
    return {"columns": columns(engine, shape), "rows": rows}


def effect_baseline(engine, completed=()):
    completed = tuple(completed)
    if (len(set(completed)) != len(completed)
            or set(completed) - {'apply-commit', 'full-export', 'sql-commit'}):
        raise ValueError('Only original verified fixed effect cases can seed the baseline.')
    expected = snapshot(engine, 'acceptance-effects')
    for row in expected['rows']:
        if row[0] in completed:
            row[1] = '1'
    return expected


def effect_snapshot(engine, case, *, completed=()):
    """Exactly one current-case commit; original verified prior cases stay at one."""
    if case not in ("apply-commit", "full-export", "sql-commit"):
        raise ValueError("Only fixed owned effect cases are supported.")
    if case in completed:
        raise ValueError('A new effect cannot replay its original verified case.')
    expected = effect_baseline(engine, completed)
    for row in expected["rows"]:
        if row[0] == case:
            row[1] = "1"
    return expected


def assert_apply_committed(actual, engine):
    expected = snapshot(engine, 'acceptance-apply')
    expected['rows'][0][1], expected['rows'][0][4] = 'applied', '7'
    if canonical(actual) != canonical(expected):
        raise ValueError('Physical Apply rows differ from the fixed single-cell commit.')
    return {'typedSha256': sha(canonical(expected)), 'rowCount': 2,
            'fixedOriginalRowOneAppliedLabelVerified': True, 'unchangedOriginalRowTwoVerified': True}


def assert_effect_snapshot(actual, engine, case, *, completed=()):
    expected = effect_snapshot(engine, case, completed=completed)
    if canonical(actual) != canonical(expected):
        raise ValueError("Exactly one independent committed effect is required.")
    return {"engine": engine, "caseId": case, "effectCount": 1,
            "typedSha256": sha(canonical(expected))}


def duplicate_rows(engine, *, complete):
    """Sorted independently of MySQL's unordered synthetic INSERT allocation.

    Required query ORDER BY CASE WHEN id <= 5 THEN id ELSE exact_value + 6 END.
    Never use these rows as an expectation for MySQL's ORDER BY id tail.
    """
    engine_check(engine)
    rows = [row[1:4] for row in head_rows()]
    numbers = range(1, 1201) if engine == "postgresql" else range(1000)
    rows += [["synthetic row " + str(n), str(n) + ".000000000000000000", None]
             for n in numbers]
    return rows if complete else rows[:1000]


def result_set(engine, *, complete):
    rows = duplicate_rows(engine, complete=complete)
    total = COUNT[engine]
    return {"columns": columns(engine, "duplicate-values"), "rows": rows,
            "commandTag": "SELECT " + str(total) if engine == "postgresql" else "SELECT",
            "rowCount": total, "displayedRowCount": len(rows), "truncated": not complete}


def wide_grid(engine):
    """Fixed 1000x32 original grid, from the same explicitly sorted base rows."""
    base_columns = columns(engine, "duplicate-values")
    output_columns = []
    for index in range(32):
        column = dict(base_columns[index % 3], index=index, name="c%02d" % index)
        output_columns.append(column)
    return {"columns": output_columns,
            "rows": [[row[index % 3] for index in range(32)]
                     for row in duplicate_rows(engine, complete=False)]}


def selected_head(engine, selection):
    choices = {"cell-empty": ([1], [1]), "rectangle": ([0, 1, 2], [1, 2]),
               "sparse-rows": ([0, 3], [0, 1, 2, 3, 4])}
    if selection not in choices:
        raise ValueError("Only fixed original selection fixtures are supported.")
    row_ids, ordinals = choices[selection]
    base = snapshot(engine, "values-head")
    return {"columns": [base["columns"][index] for index in ordinals],
            "rows": [[base["rows"][row][column] for column in ordinals] for row in row_ids]}


def go_json(value):
    """Fixed corpus subset of Go encoding/json, including HTML and U+2028/29.

    Object insertion order is explicit in the protocol schema constructors.
    This serializer is independent of the product export implementation.
    """
    text = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    for ch, escaped in (("&", "\\u0026"), ("<", "\\u003c"), (">", "\\u003e"),
                        ("\u2028", "\\u2028"), ("\u2029", "\\u2029")):
        text = text.replace(ch, escaped)
    return text.encode()


def complete_json(engine):
    """Exact helper Run-to-File schema, rows preceding metadata, no final LF."""
    result = result_set(engine, complete=True)
    metadata = {key: result[key] for key in
                ("columns", "commandTag", "rowCount", "displayedRowCount", "truncated")}
    return go_json({"version": 1, "resultSets": [{"rows": result["rows"], "metadata": metadata}]})


def loaded_json(engine):
    """Loaded export is sorted pretty JSON; unlike helper, metadata comes first."""
    result = result_set(engine, complete=False)
    metadata = {key: result[key] for key in
                ("columns", "commandTag", "rowCount", "displayedRowCount", "truncated")}
    return json.dumps({"version": 1, "resultSets": [{"metadata": metadata, "rows": result["rows"]}]},
                      ensure_ascii=False, sort_keys=True, indent=2).encode()


def csv_bytes(engine, *, complete, null_marker=NULL_MARKER):
    """Go csv.Writer's LF records; quoted fields preserve embedded CRLF.

    Python csv minimal quoting differs for leading whitespace and the special
    backslash-dot record. This explicit encoder covers those rules too.
    """
    if not isinstance(null_marker, str) or not null_marker or "\0" in null_marker:
        raise ValueError("A nonempty safe NULL marker is required.")
    rows = duplicate_rows(engine, complete=complete)
    if any(value == null_marker for row in rows for value in row if value is not None):
        raise ValueError("NULL marker collision must refuse publication.")

    def record(row):
        encoded = []
        for cell in row:
            value = null_marker if cell is None else cell
            quote = (any(ch in value for ch in ',"\r\n') or
                     bool(value) and value[0].isspace() or value == "\\.")
            encoded.append('"' + value.replace('"', '""') + '"' if quote else value)
        return (",".join(encoded) + "\n").encode()

    return record([column["name"] for column in columns(engine, "duplicate-values")]) + b"".join(map(record, rows))


def loaded_csv(engine):
    """Current loaded CSV uses CRLF records, while helper full CSV uses LF."""
    rows = [[column["name"] for column in columns(engine, "duplicate-values")]]
    rows += duplicate_rows(engine, complete=False)
    encoded = []
    for row in rows:
        fields = []
        for cell in row:
            value = NULL_MARKER if cell is None else cell
            fields.append('"' + value.replace('"', '""') + '"'
                          if any(ch in value for ch in ',"\r\n') else value)
        encoded.append(",".join(fields) + "\r\n")
    return "".join(encoded).encode()


def export_expectation(engine, format_name, *, complete=True):
    engine_check(engine)
    if format_name == "json":
        data = complete_json(engine) if complete else loaded_json(engine)
        detail = {"rowCounts": [COUNT[engine] if complete else 1000]}
    elif format_name == "csv":
        data = csv_bytes(engine, complete=True) if complete else loaded_csv(engine)
        detail = {"csvRecordCount": (COUNT[engine] if complete else 1000) + 1}
    else:
        raise ValueError("Unsupported exact export fixture format.")
    return {"format": format_name, "expectedSha256": sha(data), "expectedSize": len(data),
            "complete": complete, "engine": engine, "countQuery": "values-count", **detail}


def assert_snapshot(actual, engine, shape, *, suffix=""):
    """Fail closed: independent columns AND rows, exact keys, no zero-case pass."""
    expected = snapshot(engine, shape, suffix=suffix)
    if canonical(actual) != canonical(expected):
        raise ValueError("Independent synthetic typed snapshot differs.")
    return {"engine": engine, "queryId": shape, "rowCount": len(expected["rows"]),
            "columnCount": len(expected["columns"]), "typedSha256": sha(canonical(expected))}


def expected_manifest():
    return {"schemaVersion": 1, "origin": "declared-synthetic-corpus-and-protocol-schema",
            "applicationOutputUsed": False, "runtimeObserved": False,
            "engines": {engine: {
                "valuesCount": COUNT[engine],
                "observer": {shape: snapshot(engine, shape) for shape in ("values-head", "composite")},
                "exports": {mode + "-" + format_name:
                            export_expectation(engine, format_name, complete=mode == "complete")
                            for mode in ("loaded", "complete") for format_name in ("json", "csv")},
                "exactlyOnceComposite": snapshot(engine, "composite", suffix="!"),
                "wideGrid": {"rowCount": 1000, "columnCount": 32,
                             "typedSha256": sha(canonical(wide_grid(engine)))},
                "selectedHead": {selection: selected_head(engine, selection)
                                 for selection in ("cell-empty", "rectangle", "sparse-rows")},
                "largeText": {"byteCount": 1048576, "sha256": sha(b"x" * 1048576)},
                "additionalSetupObservers": {
                    "baseline": {shape: snapshot(engine, shape) for shape in
                                 ("acceptance-effects", "acceptance-receipts", "acceptance-apply")},
                    "exactlyOnce": {case: effect_snapshot(engine, case) for case in
                                    ("apply-commit", "full-export", "sql-commit")},
                    "currentObserverAllowlistSupported": True,
                    "setupApi": "OwnedDatabases.setup_acceptance_effects(original_record)",
                    "setupInstalled": False,
                    "scriptReceipts": {case: script_receipts(engine, case) for case in
                                       ("script-success", "script-first-error", "script-middle-error")},
                },
            } for engine in ENGINES}}


def script_receipts(engine, case):
    additions = {
        'script-success': [['script-success', '1', '11'], ['script-success', '2', '22'], ['script-success', '3', '33']],
        'script-first-error': [],
        'script-middle-error': [['script-middle-error', '1', '11']],
    }
    if case not in additions:
        raise ValueError('Fixed script receipt case required.')
    expected = snapshot(engine, 'acceptance-receipts')
    expected['rows'] += additions[case]
    expected['rows'].sort(key=lambda row: (row[0], int(row[1])))
    return expected


def assert_script_receipts(actual, engine, case):
    expected = script_receipts(engine, case)
    if canonical(actual) != canonical(expected):
        raise ValueError('Independent exact statement receipts differ.')
    return {'engine': engine, 'caseId': case, 'typedSha256': sha(canonical(expected)),
            'receiptCount': len(expected['rows']), 'seedReceiptsPreserved': True}
