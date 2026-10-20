"""Concrete current-DSL action fragments; deliberately not an execution plan.

Every fragment requires observed native selectors for its exact artifact and
explicit preconditions. Partial assertions cannot close a frozen feature. No
selector role/native ID, engine orchestration or review flag is fabricated here.
"""
from __future__ import annotations

try:
    from .oracle import ENGINES, export_expectation, head_rows, native_text_sha
except ImportError:
    from oracle import ENGINES, export_expectation, head_rows, native_text_sha


def native(action, selector, **fields):
    return {"op": "native", "action": action, "selector": selector, **fields}


def fragment(identifier, preconditions, actions, limitations, assertions):
    return {"id": identifier, "kind": "source-expected-current-dsl-fragment",
            "nativeObserved": False, "selectorIntegrationReviewed": False,
            "standaloneScenario": False, "preconditions": preconditions,
            "addresses": assertions, "limitations": limitations, "actions": actions}


def create_disconnected(engine):
    if engine not in ENGINES:
        raise ValueError("Unsupported engine.")
    p = "profiles." + engine + "."
    actions = [{"op": "capture-profile-set", "capture": engine + "-before-create"},
               native("invoke", "profiles.add"), native("select", "profiles.engine." + engine)]
    for field in ("host", "port", "database", "user"):
        actions.append(native("set-text", "profiles." + field, input="connection." + engine + "." + field))
    actions += [native("set-text", "profiles.name", input="synthetic.profileName"),
                native("select", "profiles.tls.verify-full"),
                native("invoke", "profiles.ca.choose"),
                native("set-text", "chooser.path", input="connection." + engine + ".caFile", window=p + "ca"),
                native("invoke", "chooser.accept", window=p + "ca"),
                native("select", "profiles.policy.development"),
                native("select", "profiles.policy.readonly"),
                native("invoke", "profiles.save"),
                {"op": "capture-profile-id", "engine": engine, "capture": engine + "-profile",
                 "before": engine + "-before-create", "nameInput": "synthetic.profileName"},
                {"op": "wait-server-count", "engine": engine, "query": "connections-" + engine,
                 "equals": 0, "assertion": "F01-S01-A01"}]
    return fragment("create-disconnected-" + engine,
                    ["Fresh isolated library; no profile for this engine; exact observer sessions already idle.",
                     "Password remains untouched; metadata-only Save must not create any credential.",
                     "Each chooser key names this first observed modal lifetime; reopening needs a fresh key."],
                    actions,
                    ["Server zero after Save proves disconnected state only; Save-and-Connect needs a physical new-session receipt/counter.",
                     "CA public fixture uses CN localhost; the connection host must be localhost before verify-full Connect.",
                     "Actual default NEW profile is separately tested before changing TLS/policy."],
                    ["F01-S01-A01", "F01-S01-A03"])


def first_credential_write(engine, *, empty):
    if engine not in ENGINES:
        raise ValueError("Unsupported engine.")
    capture = engine + ("-empty-credential" if empty else "-credential")
    profile = engine + "-profile"
    actions = [{"op": "credential-reserve", "profileId": "capture." + profile, "capture": capture},
               {"op": "credential-verify", "capture": capture, "absent": True, "empty": False,
                "assertion": "F04-S01-A01"},
               native("invoke", "profiles." + engine + ".edit"),
               native("select", "profiles.password.replace"),
               {"op": "credential-arm-ui-write", "capture": capture,
                "value": "empty" if empty else "connection." + engine + ".password"},
               native("set-text", "profiles.password", input="synthetic.typedEmpty" if empty else "connection." + engine + ".password"),
               native("invoke", "profiles.save"),
               {"op": "credential-verify", "capture": capture, "absent": False, "empty": empty,
                "assertion": "F04-S01-A01", "outcome": "written"}]
    return fragment("credential-first-write-" + engine + ("-empty" if empty else "-nonempty"),
                    ["Exactly one UI-created metadata-only profile for this engine in this isolated library.",
                     "Native absence reservation succeeds before UI write; collision or locked lookup refuses.",
                     "This first-write fragment needs the profile-id capture created by the creation fragment; empty/nonempty first writes use separate fresh accounts."],
                    actions,
                    ["Conditional UI update/delete intents are available; each branch must retain its original account and verify its exact explicit outcome.",
                     "Do not reread password controls; verification uses only exact owned native store account and known input hash.",
                     "Deleting a profile before credential-owned cleanup currently makes removal verification unsupported."],
                    ["F04-S01-A01", "F51-S01-A01"])


def cancel_running(engine):
    if engine not in ENGINES:
        raise ValueError("Unsupported engine.")
    suffix = "Postgresql" if engine == "postgresql" else "Mysql"
    actions = [native("focus", "editor.original"),
               native("set-text", "editor.original", input="synthetic.cancel" + suffix),
               native("invoke", "execution.run-current"),
               {"op": "wait-server-count", "engine": engine, "query": "active-" + engine + "-sleep",
                "equals": 1, "assertion": "F11-S01-A02"},
               native("invoke", "execution.stop-original"),
               {"op": "wait-server-count", "engine": engine, "query": "active-" + engine + "-sleep",
                "equals": 0, "assertion": "F11-S01-A02"}]
    return fragment("physical-stop-" + engine,
                    ["Original SQL tab explicitly connected; no other sleep on this dedicated owned server.",
                     "Run and Stop selectors retain the original document/operation owner."], actions,
                    ["This checks physical cancellation only. Held chunk ACK, terminal idle/failed state, bounds and owned helper death are separate required gates.",
                     "No expected UI status string is invented; observe the terminal surface before pinning its source-known exact text."],
                    ["F11-S01-A02", "F53-S01-A02"])


def cancel_profile_edit():
    return fragment("cancel-profile-edit", ["Original synthetic profile selected and dialog may edit it."],
                    [{"op": "capture-state", "capture": "before-profile-cancel"},
                     native("invoke", "profiles.postgresql.edit"),
                     native("set-text", "profiles.name", input="synthetic.typedLiteralNull"),
                     native("invoke", "profiles.cancel"),
                     {"op": "assert-state-same", "capture": "before-profile-cancel", "assertion": "F01-S01-A04"}],
                    ["Persisted equality does not prove credential unchanged; verify already reserved credential separately."],
                    ["F01-S01-A04"])


def native_text_roundtrip():
    # Existing input resolver only exposes this fixed CRLF text today. Rich
    # Unicode corpus is prepared separately and requires fixed input integration.
    text = "SELECT 1;\r\n-- synthetic editor input"
    return fragment("editor-existing-input-exact", ["Original editable SQL tab, no marked text or modal."],
                    [native("focus", "editor.original"),
                     native("set-text", "editor.original", input="synthetic.plainText"),
                     native("assert", "editor.original", expectedSha256=native_text_sha(text),
                            assertion="F14-S01-A01")],
                    ["Semantic SetValue is not paste/keyboard/IME/Undo proof; rich Unicode, selection and multi-tab source checks stay required."],
                    ["F14-S01-A01"])


def typed_observer(engine):
    return fragment("typed-observer-head-" + engine,
                    ["Fresh unmodified checked-in dbeer_parity_v1 corpus on exact owned server."],
                    [{"op": "assert-observer-oracle", "engine": engine, "query": "values-head",
                      "oracle": "snapshot", "assertion": "F27-S01-A02"}],
                    ["The engine compares independently declared metadata and typed values; this alone does not establish native grid fidelity.",
                     "Server rows do not prove native displayed typed values. NULL and text NULL share native text; typed role/description must also be checked."],
                    ["F27-S01-A01", "F27-S01-A02"])


def export_check(engine, *, complete, format_name):
    mode = ("complete" if complete else "loaded") + "-" + format_name
    path = "outputs/" + ("complete" if complete else "loaded") + "." + format_name
    assertion = "F39-S01-A01" if complete else "F38-S01-A01"
    return fragment(("complete" if complete else "loaded") + "-" + format_name + "-" + engine,
                    ["Use prepared duplicate-values query with explicit numeric sort independent of MySQL INSERT allocation.",
                     "Set exact collision-free marker <DBEER-SQL-NULL> for CSV; use original captured result.",
                     "Export already completed via real native workflow and exact owned destination; same file cannot be reused across engines."],
                    [{"op": "export-check", "path": path, "engine": engine, "oracle": mode, "assertion": assertion}],
                    ["Exact bytes/count alone do not prove run-once, no SQL for loaded export, cancellation or failed publication.",
                     "Fixed corpus inputs and pinned source staging must be explicitly selected; publication and run-once effects require their separate independent receipts."],
                    [assertion])


def base_catalog():
    fragments = [cancel_profile_edit(), native_text_roundtrip()]
    for engine in ENGINES:
        fragments += [create_disconnected(engine), first_credential_write(engine, empty=False),
                      first_credential_write(engine, empty=True), cancel_running(engine), typed_observer(engine)]
        fragments += [export_check(engine, complete=complete, format_name=format_name)
                      for complete in (False, True) for format_name in ("json", "csv")]
    return {"schemaVersion": 1, "kind": "source-expected-recipe-fragments",
            "nativeObserved": False, "selectorIntegrationReviewed": False,
            "notAnExecutionPlan": True, "fragments": fragments}


def integrated_fragments():
    rich = '-- Synthetic \U0001f600 e\u0301\r\nSELECT \'straight "quotes" -- dash\';\r\nSELECT 2;'
    prepared = [fragment('editor-unicode-fixed-corpus', ['Original editable synthetic document retains its native owner.'],
                         [native('set-text', 'editor.original', input='corpus.editorUnicodeCRLF'),
                          native('assert', 'editor.original', expectedSha256=native_text_sha(rich), assertion='F14-S01-A01')],
                         ['Actual paste, caret, selection, Undo and IME are mandatory separate observations.'], ['F14-S01-A01'])]
    for engine in ENGINES:
        prepared.append(fragment('fixed-effect-baseline-' + engine,
                                 ['Fresh exact owned database corpus; additive effects have never been attempted.'],
                                 [{'op': 'effects-setup', 'engine': engine},
                                  {'op': 'assert-observer-oracle', 'engine': engine, 'query': 'acceptance-effects',
                                   'oracle': 'snapshot', 'assertion': 'F39-S01-A01'}],
                                 ['Baseline count zero is a precondition, never successful exactly-once proof.'], ['F39-S01-A01']))
        for case, assertion in (('sql-commit', 'F36-S01-A01'), ('apply-commit', 'F36-S01-A02'), ('full-export', 'F39-S01-A01')):
            prepared.append(fragment('independent-once-' + case + '-' + engine,
                                     ['Fresh effect baseline verified; original GUI issued the fixed case exactly once.'],
                                     [{'op': 'assert-observer-oracle', 'engine': engine, 'query': 'acceptance-effects',
                                       'oracle': 'effect-once', 'case': case, 'assertion': assertion}],
                                     ['This is an exact committed effect count; lost-ACK boundary/original unknown UI and retry refusal still require real native proofs.'], [assertion]))
    return prepared



def catalog():
    value = base_catalog()
    value['fragments'] += integrated_fragments()
    value['fragments'] += final_fragments()
    return value


def final_fragments():
    prepared = []
    for name, assertion in (('connections', 'F05-S01-A02'), ('workspace', 'F21-S01-A04'),
                            ('appearance', 'F47-S01-A01'), ('themes', 'F48-S01-A03'), ('shortcuts', 'F46-S01-A03')):
        for failure in ('corrupt', 'future'):
            actions = [{'op': 'file-assert-same', 'capture': 'original', 'assertion': assertion}]
            prepared.append(fragment('fresh-' + name + '-' + failure + '-preserved',
                                     ['Populated original main workspace can complete actual normal common Close.',
                                      'Fresh fixed empty canonical subfixture contains no migrated IDs or credentials.'],
                                     [{'op': 'persistence-case', 'case': name + '-' + failure,
                                       'actions': actions, 'assertion': assertion}],
                                     ['This checks exact startup/normal-close preservation. Native readonly fallback/error and attempted edits still require observed controls.',
                                      'Destructive procedures never connect, borrow credentials or overwrite the main data owner.'], [assertion]))
    prepared += [fragment('rich-editor-original-utf16-selection',
                         ['Observed original SQL editor supports actual TextPattern/AT-SPI Text and native stable identity.'],
                         [native('set-text', 'editor.original', input='corpus.editorUnicodeCRLF'),
                          {'op': 'native-text-select', 'selector': 'editor.original', 'input': 'corpus.editorUnicodeCRLF',
                           'start': 13, 'end': 15, 'pin': 'original-editor'},
                          {'op': 'native-text-assert', 'selector': 'editor.original', 'input': 'corpus.editorUnicodeCRLF',
                           'start': 13, 'end': 15, 'pin': 'original-editor', 'assertion': 'F14-S01-A01'}],
                         ['Range endpoints must be representable native endpoints; split surrogate offsets refuse.',
                          'Actual keyboard/IME/Undo/scroll/geometry and later operation ownership remain required.'], ['F14-S01-A01']),
                 fragment('latest-settings-close-full-dtos',
                          ['Real native Settings already chose Lager/native-dark, committed exactly the fixed shared-32 import, and cleared Run Current.',
                           'Actual import UUID captured as imported-theme after full independently normalized library comparison.'],
                          [{'op': 'settings-close-restart', 'expected': ['afterImported', 'libraryImported', 'explicitUnbind'],
                            'theme': 'imported-theme', 'assertion': 'F47-S01-A01'}],
                          ['Full files are checked after actual common Close and after fresh exact restart.',
                           'A deterministic held-old-save/new-reservation race and actual rendered palettes still need original owner barriers.'], ['F47-S01-A01']),
                 fragment('shortcut-explicit-default-recovery',
                          ['Owned previous main state can complete common Close; actual observed recovery control is available.'],
                          [{'op': 'persistence-case', 'case': 'shortcuts-future', 'assertion': 'F46-S01-A03', 'actions': [
                              native('invoke', 'settings.shortcuts.open'), native('invoke', 'shortcuts.recover-defaults'),
                              {'op': 'file-backup-discover', 'capture': 'original', 'assertion': 'F46-S01-A03'},
                              {'op': 'assert-settings-expected', 'expected': 'shortcutDefaults', 'assertion': 'F46-S01-A03'}]}],
                          ['Explicit recovery is separate from readonly fallback/Retry. Real native keyboard rebind/defaults remains required.'], ['F46-S01-A03'])]
    for engine in ENGINES:
        for case in ('script-success', 'script-first-error', 'script-middle-error'):
            prepared.append(fragment('script-independent-receipts-' + case + '-' + engine,
                                     ['Fresh fixed effects installed; original GUI completed only the exact fixed ' + case + ' script.'],
                                     [{'op': 'assert-observer-oracle', 'engine': engine, 'query': 'acceptance-receipts',
                                       'oracle': 'script-receipts', 'case': case, 'assertion': 'F18-S01-A01'}],
                                     ['Ordered committed write receipts distinguish skipped/duplicate writes. Read-only command ordering still requires the original runtime trace.'], ['F18-S01-A01']))
        prepared.append(fragment('physical-session-preservation-' + engine,
                                 ['Original tab A/service physical sessions captured as original-sessions before an unrelated tab action.'],
                                 [{'op': 'assert-physical-sessions', 'engine': engine, 'capture': 'original-sessions',
                                   'added': 0, 'removed': 0, 'assertion': 'F09-S01-A03'}],
                                 ['PostgreSQL backend creation is compared; MySQL PROCESSLIST supplies no creation time or transaction owner.',
                                  'Exact tab/service role correlation, temp state and MySQL transaction ownership remain separate gates.'], ['F09-S01-A03']))
    return prepared
