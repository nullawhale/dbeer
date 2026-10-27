#!/usr/bin/env python3
"""Owned installed previous -> candidate -> restart acceptance. Never publishes."""
from __future__ import annotations
import argparse
import os
from pathlib import Path
import re
import sys
sys.dont_write_bytecode = True
import time
import uuid

from core import (Artifact, Child, Journal, Pending, Refused, OUTPUT, REPO, TARGETS, canonical,
                  clean_environment, digest_bytes, native, now, parse, private_directory, read,
                  safe, sha, state_snapshot, verify_build_info, write_new)
from credentials import OwnedCredential, BoundedStore
from driver import Driver
from observer import DatabasePair, Observer
from scenarios import catalog, new_ledger, record
from state import assert_same, check_transfer, typed_state, assert_expected, assert_settings, policy_expectation
from inputs import corpus_inputs, StagedInputs
from files import HeldFile, ReplacementBarrier
from persistence_cases import PersistenceCase
from text_contract import expected_text, assert_text, assert_semantics
import settings_contract
from db_relay import APPLY_SOURCE_PINS, OwnedRelay, require_sequential_apply_source
from plan import validate_action, validate_plan, validate_scenario, required_plan
from recipes import oracle
from proof_join import MatrixJoin
from recipes.identity import discover_created, resolve_profile

FIXTURES = REPO / 'prototypes/gpui/fixtures/installed-acceptance'


def request_file(path):
    value = parse(read(path, 1024 * 1024))
    allowed = {'schemaVersion', 'desktop', 'previous', 'candidate', 'selectorContracts', 'executionPlan', 'databasePair', 'completedProofs'}
    if (not isinstance(value, dict) or set(value) - allowed or value.get('schemaVersion') != 1
            or value.get('desktop') not in TARGETS):
        raise Refused('Installed acceptance request schema mismatch.')
    return value


def contracts(request, artifacts):
    result = {}
    for phase in ('previous', 'candidate'):
        descriptor = request.get('selectorContracts', {}).get(phase)
        if not descriptor or set(descriptor) != {'path', 'sha256'}:
            raise Pending('Native-observed selectors for both exact artifacts are required.')
        path = safe(descriptor['path'])
        if sha(path) != descriptor['sha256']:
            raise Refused('Selector contract digest mismatch.')
        value = parse(read(path, 1024 * 1024))
        if value.get('nativeObserved') is not True or not value.get('selectors'):
            raise Pending('Real semantic selector integration is not available.')
        if (value.get('desktop') != request['desktop']
                or value.get('guiSha256') != artifacts[phase].files[artifacts[phase].gui_name]['sha256']
                or value.get('sourceSha256') != artifacts[phase].identity['sourceSha256']):
            raise Refused('Native selectors do not describe the exact pinned artifact.')
        result[phase] = value
    return result


def plans(request):
    descriptor = request.get('executionPlan')
    if not descriptor or set(descriptor) != {'path', 'sha256'}:
        raise Pending('Reviewed concrete native action plans are required.')
    path = safe(descriptor['path'])
    if sha(path) != descriptor['sha256']:
        raise Refused('Execution plan digest mismatch.')
    value = parse(read(path, 4 * 1024 * 1024))
    if value.get('selectorIntegrationReviewed') is not True:
        raise Pending('Actual native selector review is unavailable.')
    try:
        return validate_plan(value, catalog(), request['desktop'])
    except (ValueError, KeyError, TypeError):
        raise Refused('Reviewed concrete plan has incomplete strict assertion coverage.') from None


def resolve_input(key, inputs, databases, fixture=None):
    if key.startswith('synthetic.'):
        name = key.split('.', 1)[1]
        if name not in inputs:
            raise Refused('Unknown bounded synthetic UI input.')
        return inputs[name]
    if key.startswith('fixture.'):
        paths = {'loadedJson': 'outputs/loaded.json', 'completeJson': 'outputs/complete.json',
                 'loadedCsv': 'outputs/loaded.csv', 'completeCsv': 'outputs/complete.csv',
                 'profileExport': 'outputs/profiles.json', 'sqlFile': 'inputs/synthetic.sql'}
        name = key.split('.', 1)[1]
        if fixture is None or name not in paths:
            raise Refused('Only exact owned fixture paths may enter native choosers.')
        return str(fixture / paths[name])
    if key.startswith('connection.'):
        _, engine, field = key.split('.')
        if engine not in ('postgresql', 'mysql') or field not in ('host', 'port', 'database', 'user', 'password', 'sslMode', 'caFile', 'untrustedCaFile', 'missingCaFile', 'unreadableCaDirectory'):
            raise Refused('Unsupported owned DB UI input.')
        if field in ('caFile', 'untrustedCaFile', 'missingCaFile', 'unreadableCaDirectory'):
            return databases.public_ca_path(engine, field)
        return str(databases.connection(engine)[field])
    raise Refused('Only synthetic or exact-owned DB values may enter UI actions.')


class Workflow:
    def __init__(self, root, data_root, driver, journal, databases, observers, lifecycle=None):
        self.root, self.data_root, self.driver, self.journal = root, data_root, driver, journal
        self.databases, self.observers, self.lifecycle = databases, observers, lifecycle
        self.inputs = parse(read(FIXTURES / 'synthetic-inputs.json', 65536))
        self.corpus = corpus_inputs()
        self.staged = StagedInputs(root / 'inputs', journal)
        self.captures, self.capture_epochs, self.credentials = {}, {}, {}
        self.profile_receipts, self.files, self.barriers, self.relays = {}, {}, {}, {}
        self.relay_catalog, self.relay_apply = {}, {}
        self.effect_cases = {engine: set() for engine in ('postgresql', 'mysql')}
        self.epoch, self.store = 0, None
        self.completed_proofs = []
        self.persistence_original_case = None
        self.assertions, self.proofs, self.coverage = set(), [], set()
        metadata = safe(data_root, directory=True).stat()
        self.root_identity = (metadata.st_dev, metadata.st_ino)
        self.fixture_identity = (safe(root, directory=True).stat().st_dev, root.stat().st_ino)
        outputs = safe(root / 'outputs', directory=True).stat()
        self.outputs_identity = (outputs.st_dev, outputs.st_ino)

    def proof(self, kind, value):
        result = {'kind': kind, **value}
        if kind == 'independent-physical-database-observer' and value.get('engine') in self.observers:
            result.update(self.observers[value['engine']].version_proof)
        self.proofs.append(result)
        return result

    def verify_root(self):
        parent = safe(self.root, directory=True).stat()
        outputs = safe(self.root / 'outputs', directory=True).stat()
        if ((parent.st_dev, parent.st_ino) != self.fixture_identity
                or (outputs.st_dev, outputs.st_ino) != self.outputs_identity):
            raise Refused('Original private fixture/output directory changed.')
        metadata = safe(self.data_root, directory=True).stat()
        if (metadata.st_dev, metadata.st_ino) != self.root_identity:
            raise Refused('Original isolated data owner changed.')

    def remember(self, name, value, kind):
        if name in self.captures:
            raise Refused('Original capture key cannot be rebound.')
        self.captures[name] = value
        self.capture_epochs[name] = (self.epoch, kind)

    def captured(self, name, kind):
        if self.capture_epochs.get(name) != (self.epoch, kind):
            raise Refused('Capture is absent, stale or has a different typed owner.')
        return self.captures[name]

    def profiles(self):
        typed_state(self.data_root)
        return parse(read(self.data_root / 'connections.json', 4 * 1024 * 1024))['connections']

    def profile_id(self, reference):
        if not isinstance(reference, str) or not reference.startswith('capture.'):
            raise Refused('Only genuinely UI-created captured profile references are accepted.')
        name = reference.split('.', 1)[1]
        self.captured(name, 'profile-id')
        try:
            account = resolve_profile(reference, self.captures, [p['id'] for p in self.profiles()])
        except ValueError:
            raise Refused('Original UI-created profile identity is stale or invalid.') from None
        if self.profile_receipts.get(account) != self.epoch:
            raise Refused('Current capture epoch does not own this UI-created profile.')
        return account

    def input(self, key):
        if key.startswith('relay.'):
            fields = key.split('.')
            if len(fields) != 3 or fields[1] not in self.relays:
                raise Refused('Original owned relay endpoint is unavailable.')
            return self.relays[fields[1]].endpoint(fields[2])
        if key.startswith('corpus.'):
            if key[7:] not in self.corpus:
                raise Refused('Unknown fixed corpus input.')
            return self.corpus[key[7:]]
        if key.startswith('fixture.source.'):
            return self.staged.path(key[len('fixture.source.'):])
        return resolve_input(key, self.inputs, self.databases, self.root)

    def artifact_path(self, relative):
        # Output paths are fixed. An arbitrary private file is not an export.
        if relative not in {'outputs/loaded.json', 'outputs/complete.json', 'outputs/loaded.csv',
                            'outputs/complete.csv', 'outputs/profiles.json'}:
            raise Refused('Only enumerated isolated output files may be asserted.')
        return safe(self.root / relative)

    def export(self, item):
        mode = item['oracle'].split('-')
        if len(mode) != 2 or mode[0] not in ('loaded', 'complete') or mode[1] not in ('json', 'csv'):
            raise Refused('Only independent fixed export oracles are supported.')
        complete, format_name = mode[0] == 'complete', mode[1]
        expected = oracle.export_expectation(item['engine'], format_name, complete=complete)
        expected_path = 'outputs/' + mode[0] + '.' + format_name
        if item['path'] != expected_path:
            raise Refused('Export mode and original owned output differ.')
        data = read(self.artifact_path(item['path']), 128 * 1024 * 1024)
        if len(data) != expected['expectedSize'] or digest_bytes(data) != expected['expectedSha256']:
            raise Refused('Export bytes differ from the source-derived typed/count/metadata oracle.')
        # Exact byte equality proves the independently serialized rows/metadata,
        # NULL/binary and CSV records. Physical count remains an additional check.
        count = oracle.COUNT[item['engine']] if complete else 1000
        if complete:
            result = self.observers[item['engine']].query('values-count')
            if result['rows'] != [[str(count)]]:
                raise Refused('Complete export differs from independent physical server count.')
        return self.proof('independent-export-bytes-and-counts',
                          {'engine': item['engine'], 'sha256': expected['expectedSha256'],
                           'size': len(data), 'format': format_name, 'rowCount': count,
                           'sourceDerivedOracle': item['oracle']})

    def restart(self):
        if self.lifecycle is None:
            raise Pending('Exact pinned artifact restart controller is unavailable.')
        before = typed_state(self.data_root, require_populated=True)
        if self.driver.child.process.poll() is None:
            self.lifecycle.close(self)
        elif not getattr(self.driver.child, 'normal_exit', False):
            raise Refused('Restart requires the original successful common Close.')
        self.driver = self.lifecycle.relaunch(self)
        self.verify_root()
        after = typed_state(self.data_root, require_populated=True)
        result = assert_same(before, after)
        for engine in ('postgresql', 'mysql'):
            observed = self.observers[engine].wait_scalar('connections-' + engine, lambda count: count == 0, timeout=10)
            self.proof('ordinary-restart-disconnected', {'engine': engine, **observed})
        self.epoch += 1
        # Only independently preserved current created IDs may renew after a new
        # exact child/window binding. Removed IDs and old target pins stay retired.
        current = set(after['profileIds'])
        self.profile_receipts = {account: self.epoch for account in self.profile_receipts if account in current}
        for key, (epoch, kind) in list(self.capture_epochs.items()):
            if kind == 'profile-id' and self.captures[key] in self.profile_receipts:
                self.capture_epochs[key] = (self.epoch, kind)
            elif kind == 'theme-id':
                themes = settings_contract.library(self.data_root)['themes']
                if any(theme['id'] == self.captures[key] for theme in themes):
                    self.capture_epochs[key] = (self.epoch, kind)
        self.proof('independent-persisted-typed-state', result)
        return self.proof('exact-artifact-ordinary-restart', {'captureEpoch': self.epoch, 'normalPriorExit': True})

    def persistence_case(self, item):
        if self.lifecycle is None:
            raise Pending('Original artifact/common Close controller is required for a destructive subfixture.')
        # Use a new canonical owner and fixed empty source-only state. Never
        # clone production/UI profile UUIDs into a second credential namespace.
        before = typed_state(self.data_root, require_populated=True)
        self.lifecycle.close(self)
        fixture = PersistenceCase(self.root, self.driver.desktop, item['case'], self.journal)
        nested = None
        try:
            child, driver = launch(self.driver.artifact, fixture.env, self.driver.desktop,
                                   self.driver.contract, self.driver.acknowledged, self.journal)
            self.lifecycle.children.append(child)
            lifecycle = Lifecycle(self.driver.artifact, fixture.env, self.driver.desktop,
                                  self.driver.contract, self.driver.acknowledged, self.journal,
                                  self.lifecycle.actions, self.lifecycle.children)
            nested = Workflow(fixture.root, fixture.data_root, driver, self.journal,
                              self.databases, self.observers, lifecycle)
            nested.files['original'] = fixture.original
            nested.persistence_original_case = fixture.case
            nested.execute(item['actions'])
            lifecycle.close(nested)
            self.proofs.extend(nested.proofs)
        finally:
            if nested is not None:
                nested.close_file_receipts()
            fixture.close()
        # Fresh Driver and capture epoch: the old native target pins stay retired.
        self.restart()
        result = assert_same(before, typed_state(self.data_root, require_populated=True))
        return self.proof('fresh-owned-destructive-persistence-case',
                          {'case': item['case'], 'originalRootPreserved': True, **result})

    def lost_commit_ack(self, item):
        relay = self.relays[item['capture']]
        engine, observer = item['engine'], self.observers[item['engine']]
        if relay.engine != engine or relay.verified_loss or 'sql-commit' in self.effect_cases[engine]:
            raise Refused('Original one-shot relay/engine owner differs or was already consumed.')
        self.driver.child.verify()
        relay.verify()
        # Fixed effects are still invisible outside the original open
        # transaction; the complete independent baseline must be exact zero.
        try:
            if canonical(observer.query('acceptance-effects')) != canonical(oracle.effect_baseline(engine, self.effect_cases[engine])):
                raise ValueError('Original effect baseline differs.')
        except ValueError:
            raise Refused('Fresh zero-effect baseline is required before ACK loss.') from None
        observer.wait_scalar('connections-' + engine, lambda count: count == 1, timeout=5)
        physical = observer.session_snapshot()
        if len(physical['sessions']) != 1:
            raise Refused('Exactly one original physical relay session is required before Commit.')
        if engine == 'postgresql' and (physical['sessions'][0]['state'] != 'idle in transaction'
                                      or physical['sessions'][0]['transactionOpen'] is not True):
            raise Refused('Original PostgreSQL relay session is not idle in an active transaction.')
        # All four refer to the original observed SQL-tab owner. The source
        # plan supplies reviewed exact Idle/Open labels, never a generic flag.
        self.driver.action('assert', item['idleSelector'], pin=item['idlePin'], read_value=True, expected_hash=item['idleExpectedSha256'])
        self.driver.action('assert', item['transactionSelector'], pin=item['transactionPin'], read_value=True, expected_hash=item['transactionExpectedSha256'])
        original_source = self.driver.action('read-text-range', item['editorSelector'], pin=item['editorPin'],
                                             text_hash=digest_bytes(b'COMMIT;'))
        if original_source.get('textRange', {}).get('textSha256') != digest_bytes(b'COMMIT;'):
            raise Refused('Held ACK loss permits only the fixed original COMMIT statement.')
        commit = self.driver.action('inspect', item['commitSelector'], pin=item['commitPin'], read_semantics=True)
        stop = self.driver.action('inspect', item['stopSelector'], pin=item['stopPin'], read_semantics=True)
        assert_semantics(commit.get('semantics', {}), {'enabled': True})
        assert_semantics(stop.get('semantics', {}), {'enabled': False})
        arm = relay.arm()
        self.driver.child.verify()
        # No split begin/commit DSL exists: one guarded invocation consumes the
        # original arm, with reverse bytes held until independent commit proof.
        self.driver.action('invoke', item['commitSelector'], pin=item['commitPin'])
        self.journal.append('original-native-commit-invoked-once', engine=engine, **arm)
        deadline = time.monotonic() + 15
        while True:
            relay.verify()
            actual = observer.query('acceptance-effects')
            try:
                committed = oracle.assert_effect_snapshot(actual, engine, 'sql-commit', completed=self.effect_cases[engine])
                break
            except ValueError:
                try:
                    if canonical(actual) != canonical(oracle.effect_baseline(engine, self.effect_cases[engine])):
                        raise ValueError('Original effect baseline differs.')
                except ValueError:
                    raise Refused('Unexpected/duplicate physical effect before intentional ACK loss.') from None
            if time.monotonic() >= deadline:
                raise Refused('Independent fixed commit did not cross the held ACK boundary.')
            # Poll pacing only. Exact physical effect, not delay, is authority.
            time.sleep(0.05)
        self.driver.child.verify()
        relay.drop_held()
        self.driver.wait(item['unknownSelector'], pin=item['unknownPin'], expected_hash=item['unknownExpectedSha256'], timeout=20)
        retry = self.driver.action('inspect', item['retrySelector'], pin=item['retryPin'], read_semantics=True)
        assert_semantics(retry.get('semantics', {}), {'enabled': False})
        observer.wait_scalar('connections-' + engine, lambda count: count == 0, timeout=10)
        # No retry is attempted while unknown. A second independent snapshot
        # rejects any automatic duplicate before explicit verification/recovery.
        try:
            after = oracle.assert_effect_snapshot(observer.query('acceptance-effects'), engine, 'sql-commit', completed=self.effect_cases[engine])
        except ValueError:
            raise Refused('Physical effect changed/duplicated while the original UI remained unknown.') from None
        relay.verified_loss = True
        self.effect_cases[engine].add('sql-commit')
        return self.proof('real-installed-owned-database-commit-ack-loss',
                          {'engine': engine, **arm, 'independentCommittedEffect': committed,
                           'effectAfterUnknown': after, 'commitInvocations': 1, 'retryDisabledObserved': True,
                           'originalPhysicalSessionSha256': digest_bytes(canonical(physical)),
                           'originalPhysicalSessionClosedObserved': True,
                           'reverseBytesReleasedAfterArm': False, 'helperProcessDeathProven': False})

    def relay_profile(self, relay, reference):
        account = self.profile_id(reference)
        matching = [profile for profile in self.profiles() if profile['id'] == account]
        if (len(matching) != 1 or matching[0]['engine'] != relay.engine or matching[0]['host'] != 'localhost'
                or matching[0]['port'] != relay.port or matching[0]['sslMode'] != 'verify-full'
                or matching[0].get('sslRootCert') != self.databases.public_ca_path(relay.engine, 'caFile')):
            raise Refused('Original synthetic relay profile/TLS metadata differs.')
        return account

    def pin_relay_catalog(self, item):
        relay = self.relays[item['capture']]
        if relay.engine != item['engine'] or item['capture'] in self.relay_catalog:
            raise Refused('Original catalog relay pin cannot be substituted/rebound.')
        profile = self.relay_profile(relay, item['profileId'])
        self.driver.action('assert', item['selector'], pin=item['pin'], read_value=True, expected_hash=item['expectedSha256'])
        snapshot = self.observers[relay.engine].session_snapshot()
        if len(snapshot['sessions']) != 1:
            raise Refused('Explicit original catalog Connect must own the only physical product session.')
        relay.pin_catalog()
        self.relay_catalog[item['capture']] = {'epoch': self.epoch, 'profileReference': item['profileId'],
                                             'profileId': profile, 'physical': snapshot,
                                             'catalogGeneration': relay.generation}

    @staticmethod
    def require_catalog_preserved(original, current, *, count):
        if (any(original[key] != current[key] for key in ('engine', 'containerId', 'ownedImageId'))
                or len(original['sessions']) != 1 or len(current['sessions']) != count):
            raise Refused('Original catalog/Apply physical server or session count differs.')
        saved = original['sessions'][0]
        matching = [session for session in current['sessions'] if session['id'] == saved['id']]
        if len(matching) != 1 or ('backendStart' in saved and matching[0]['backendStart'] != saved['backendStart']):
            raise Refused('Original catalog physical lifetime was replaced or lost.')

    def prepare_relay_apply(self, item):
        relay = self.relays[item['capture']]
        catalog = self.relay_catalog[item['capture']]
        if (relay.engine != item['engine'] or catalog['epoch'] != self.epoch
                or catalog['catalogGeneration'] != relay.generation or item['capture'] in self.relay_apply
                or item['reviewPin'] in self.driver.bindings):
            raise Refused('Fresh original Apply review/admission owner is stale or already bound.')
        if self.relay_profile(relay, catalog['profileReference']) != catalog['profileId']:
            raise Refused('Original catalog profile changed before fresh Apply preparation.')
        observer = self.observers[relay.engine]
        self.require_catalog_preserved(catalog['physical'], observer.session_snapshot(), count=1)
        prepare = self.driver.action('inspect', item['prepareSelector'], pin=item['preparePin'], read_semantics=True)
        assert_semantics(prepare.get('semantics', {}), {'enabled': True})
        relay.admit_second()
        self.driver.action('invoke', item['prepareSelector'], pin=item['preparePin'])
        second = relay.second_lease()
        # Actual fresh Purpose::Apply review, not Standalone Preview. Its
        # observed native dialog generation and original target pin stay fixed.
        self.driver.wait(item['reviewSelector'], expected_hash=item['reviewExpectedSha256'], pin=item['reviewPin'])
        current = observer.session_snapshot()
        self.require_catalog_preserved(catalog['physical'], current, count=2)
        self.relay_apply[item['capture']] = {'epoch': self.epoch, 'reviewSelector': item['reviewSelector'],
                                           'reviewPin': item['reviewPin'], 'reviewBinding': self.driver.bindings[item['reviewPin']],
                                           'reviewExpectedSha256': item['reviewExpectedSha256'],
                                           'connectionGeneration': second.generation, 'physical': current}
        self.journal.append('original-fresh-native-apply-review-bound', engine=relay.engine,
                            relayNonce=relay.nonce, connectionGeneration=second.generation,
                            catalogGeneration=relay.generation, nativeReviewBinding=self.driver.bindings[item['reviewPin']])

    def lost_apply_ack(self, item):
        require_sequential_apply_source()
        source = self.driver.artifact.require_reviewed_source({path: digest for path, digest in APPLY_SOURCE_PINS.items()
                                                               if path.startswith('helper/')})
        relay, catalog = self.relays[item['capture']], self.relay_catalog[item['capture']]
        review = self.relay_apply[item['capture']]
        second = relay.second_lease()
        if (relay.engine != item['engine'] or review['epoch'] != self.epoch or catalog['epoch'] != self.epoch
                or second.generation != review['connectionGeneration'] or second.verified_loss
                or 'apply-commit' in self.effect_cases[relay.engine]
                or self.driver.bindings.get(review['reviewPin']) != review['reviewBinding']):
            raise Refused('Original fresh Apply lease/review was replaced or consumed.')
        self.relay_profile(relay, catalog['profileReference'])
        observer = self.observers[relay.engine]
        self.require_catalog_preserved(catalog['physical'], observer.session_snapshot(), count=2)
        self.driver.action('assert', review['reviewSelector'], pin=review['reviewPin'], read_value=True,
                           expected_hash=review['reviewExpectedSha256'])
        apply = self.driver.action('inspect', item['applySelector'], pin=item['applyPin'], read_semantics=True)
        assert_semantics(apply.get('semantics', {}), {'enabled': True})
        try:
            if canonical(observer.query('acceptance-effects')) != canonical(oracle.effect_baseline(relay.engine, self.effect_cases[relay.engine])):
                raise ValueError('Original effect baseline differs.')
            oracle.assert_snapshot(observer.query('acceptance-apply'), relay.engine, 'acceptance-apply')
        except ValueError:
            raise Refused('Fresh exact fixed Apply rows/effects are required before the original submission.') from None
        arm = second.arm(chunks=True)
        self.driver.action('invoke', item['applySelector'], pin=item['applyPin'])
        self.journal.append('original-native-apply-invoked-once', engine=relay.engine, **arm)
        deadline, released = time.monotonic() + 60, 0
        while True:
            if released >= 512 or time.monotonic() >= deadline:
                raise Refused('Original chunk-gated Apply exceeded bounded chunks/time.')
            self.driver.child.verify()
            token = second.next_chunk(timeout=min(10, deadline - time.monotonic()))
            actual = observer.query('acceptance-effects')
            try:
                committed = oracle.assert_effect_snapshot(actual, relay.engine, 'apply-commit', completed=self.effect_cases[relay.engine])
                rows = oracle.assert_apply_committed(observer.query('acceptance-apply'), relay.engine)
            except ValueError:
                try:
                    if canonical(actual) != canonical(oracle.effect_baseline(relay.engine, self.effect_cases[relay.engine])):
                        raise ValueError('Original effect baseline differs.')
                except ValueError:
                    raise Refused('Unexpected/duplicate committed Apply effect at the exact held chunk.') from None
                second.release_chunk(token)
                released += 1
                continue
            # This exact chunk and every later byte remain held. A fresh
            # autocommit observer cannot see effect1 before the real commit.
            second.drop_held(token)
            break
        self.driver.wait(item['unknownSelector'], pin=item['unknownPin'], expected_hash=item['unknownExpectedSha256'])
        retry = self.driver.action('inspect', item['retrySelector'], pin=item['retryPin'], read_semantics=True)
        assert_semantics(retry.get('semantics', {}), {'enabled': False})
        observer.wait_scalar('connections-' + relay.engine, lambda count: count == 1, timeout=10)
        self.require_catalog_preserved(catalog['physical'], observer.session_snapshot(), count=1)
        try:
            after = oracle.assert_effect_snapshot(observer.query('acceptance-effects'), relay.engine, 'apply-commit', completed=self.effect_cases[relay.engine])
            oracle.assert_apply_committed(observer.query('acceptance-apply'), relay.engine)
        except ValueError:
            raise Refused('Original committed Apply effect/rows changed while Unknown.') from None
        second.verified_loss = True
        self.effect_cases[relay.engine].add('apply-commit')
        return self.proof('real-installed-owned-database-apply-ack-loss',
                          {'engine': relay.engine, **arm, 'applyInvocations': 1, 'retryDisabledObserved': True,
                           'earlierExactChunksReleased': released, 'committedChunkReleased': False,
                           'independentCommittedEffect': committed, 'committedRows': rows, 'effectAfterUnknown': after,
                           'originalCatalogSocketPreserved': True, 'helperProcessDeathProven': False,
                           'reviewedPairedSource': source})

    def physical_sessions(self, item):
        engine = item['engine']
        before = self.captured(item['capture'], 'physical-sessions-' + engine)
        after = self.observers[engine].session_snapshot()
        if any(before[key] != after[key] for key in ('engine', 'containerId', 'ownedImageId')):
            raise Refused('Original physical server lifetime changed.')
        old, current = ({session['id']: session for session in value['sessions']} for value in (before, after))
        added, removed = set(current) - set(old), set(old) - set(current)
        if len(added) != item['added'] or len(removed) != item['removed']:
            raise Refused('Independent physical SQL/service-session delta differs.')
        if engine == 'postgresql' and any(old[key]['backendStart'] != current[key]['backendStart'] for key in set(old) & set(current)):
            raise Refused('Original PostgreSQL backend ID was reused by a new lifetime.')
        if 'postgresTransaction' in item:
            # An exact one-session controlled procedure is required; unrelated
            # simultaneous tabs cannot be inferred from a set/count.
            if len(current) != 1:
                raise Refused('Exact single original physical transaction owner required.')
            session = next(iter(current.values()))
            expected = {'open': ('idle in transaction', True), 'idle': ('idle', False),
                        'failed': ('idle in transaction (aborted)', True)}[item['postgresTransaction']]
            if (session['state'], session['transactionOpen']) != expected:
                raise Refused('Independent original PostgreSQL transaction state differs.')
        return self.proof('independent-physical-database-observer',
                          {'engine': engine, 'sessionSnapshotSha256': digest_bytes(canonical(after)),
                           'addedSessionCount': len(added), 'removedSessionCount': len(removed),
                           'originalServerPreserved': True, 'backendCreationTimeObserved': engine == 'postgresql',
                           'mysqlTransactionOwnershipEstablished': False})

    def execute(self, actions):
        if not isinstance(actions, list) or not 1 <= len(actions) <= 4096:
            raise Refused('Workflow action count is invalid.')
        for index, item in enumerate(actions):
            try:
                validate_action(item)
            except (ValueError, TypeError, KeyError):
                raise Refused('Concrete workflow schema differs.') from None
            op, assertion = item['op'], item.get('assertion')
            self.verify_root()
            self.driver.artifact.verify()
            if op in ('manual-required', 'capability-required'):
                self.journal.append('mandatory-capability-pending', actionIndex=index,
                                    capability=item.get('capability', 'native-manual'), assertion=assertion)
                raise Pending('Required native/manual/fault capability remains incomplete.')
            if op != 'restart':
                self.driver.child.verify()
            if op == 'native':
                text = self.input(item['input']) if 'input' in item else None
                result = self.driver.action(item['action'], item.get('selector'), text=text,
                                            read_value=item.get('readValue', False) or item['action'] == 'assert',
                                            expected_hash=item.get('expectedSha256'), native_action=item.get('nativeAction'),
                                            pin=item.get('pin'), window=item.get('window'))
                self.proof('exact-owned-native-actions', {'actionIndex': index, 'action': item['action'],
                                                        'ownedPid': result['ownedPid'], 'windowKey': result['windowKey'],
                                                        'binding': result['binding']})
            elif op in ('native-text-select', 'native-text-assert'):
                expected = expected_text(self.input(item['input']), item['start'], item['end'])
                result = self.driver.action('select-text-range' if op == 'native-text-select' else 'read-text-range',
                                            item['selector'], pin=item['pin'], window=item.get('window'),
                                            text_range={'start': item['start'], 'end': item['end']},
                                            text_hash=expected['textSha256'])
                proof = assert_text(result.get('textRange'), expected)
                self.proof('original-native-text-selection', proof)
            elif op == 'native-semantic-assert':
                result = self.driver.action('inspect', item['selector'], pin=item['pin'], window=item.get('window'), read_semantics=True)
                self.proof('original-native-typed-semantics', assert_semantics(result.get('semantics', {}), item['expected']))
            elif op == 'wait-native':
                self.driver.wait(item['selector'], expected_hash=item.get('expectedSha256'), focused=item.get('focused'),
                                 timeout=item.get('timeout', 20), window=item.get('window'))
            elif op == 'stage-input':
                self.staged.stage(item['source'])
            elif op == 'capture-state':
                if item.get('populated', True) is not True:
                    raise Refused('State assertions require populated independent metadata.')
                self.remember(item['capture'], typed_state(self.data_root, require_populated=True), 'state')
            elif op == 'assert-state-same':
                result = assert_same(self.captured(item['capture'], 'state'), typed_state(self.data_root, require_populated=True))
                self.proof('independent-persisted-typed-state', result)
            elif op == 'assert-state-expected':
                result = assert_expected(self.data_root, item['expected'], self.profile_id, self.corpus)
                self.proof('independent-persisted-typed-state', result)
            elif op == 'assert-settings-expected':
                result = settings_contract.expect(self.data_root, item['expected'],
                                                  self.captured(item['theme'], 'theme-id') if 'theme' in item else None)
                self.proof('independent-persisted-typed-state', result)
            elif op == 'capture-theme-set':
                self.remember(item['capture'], settings_contract.library(self.data_root), 'theme-set')
            elif op == 'capture-imported-theme':
                self.staged.path(item['source'])
                identifier = settings_contract.discover_imported(self.captured(item['before'], 'theme-set'), self.data_root)
                self.remember(item['capture'], identifier, 'theme-id')
            elif op == 'capture-recovered-theme':
                if self.persistence_original_case not in ('themes-corrupt', 'themes-future'):
                    raise Refused('Recovered theme discovery requires this fresh exact destructive library fixture.')
                self.staged.path(item['source'])
                self.files['original'].discover_backup()
                identifier = settings_contract.discover_imported({'version': 1, 'themes': []}, self.data_root)
                self.remember(item['capture'], identifier, 'theme-id')
            elif op == 'settings-close-restart':
                if self.lifecycle is None:
                    raise Pending('Exact common Close controller required for latest Settings flush.')
                theme = self.captured(item['theme'], 'theme-id') if 'theme' in item else None
                self.lifecycle.close(self)
                for key in item['expected']:
                    self.proof('independent-latest-settings-after-common-close', settings_contract.expect(self.data_root, key, theme))
                self.restart()
                for key in item['expected']:
                    self.proof('independent-latest-settings-after-common-close', settings_contract.expect(self.data_root, key, theme))
            elif op == 'capture-profile-set':
                self.remember(item['capture'], [p['id'] for p in self.profiles()], 'profile-set')
            elif op == 'capture-physical-sessions':
                self.remember(item['capture'], self.observers[item['engine']].session_snapshot(), 'physical-sessions-' + item['engine'])
            elif op == 'assert-physical-sessions':
                self.physical_sessions(item)
            elif op == 'capture-profile-id':
                try:
                    name = self.input(item['nameInput'])
                    account = discover_created(self.captured(item['before'], 'profile-set'), self.profiles(),
                                               engine=item['engine'], name_sha256=digest_bytes(name.encode()),
                                               text_hash=lambda text: digest_bytes(text.encode()))
                except ValueError:
                    raise Refused('Exactly one new matching UI-created UUID is required.') from None
                self.remember(item['capture'], account, 'profile-id')
                self.profile_receipts[account] = self.epoch
            elif op == 'assert-profile-policy':
                account = self.profile_id(item['profileId'])
                expected = policy_expectation(item['expected'], self.databases)
                matching = [p for p in self.profiles() if p['id'] == account]
                if len(matching) != 1 or any(canonical(matching[0].get(k)) != canonical(v) for k, v in expected.items()):
                    raise Refused('Independent saved policy/TLS values differ.')
                self.proof('independent-persisted-typed-state', {'profileId': account, 'policySha256': digest_bytes(canonical(expected))})
            elif op in ('observer-capture', 'assert-observer-same', 'assert-observer-rows', 'assert-observer-oracle', 'wait-server-count'):
                engine = item['engine']
                observer = self.observers.get(engine)
                if observer is None:
                    raise Pending('Independent owned physical DB observer is required.')
                if op == 'observer-capture':
                    self.remember(item['capture'], observer.query(item['query']), 'observer-' + engine)
                elif op == 'wait-server-count':
                    result = observer.wait_scalar(item['query'], lambda count: count == item['equals'], timeout=item.get('timeout', 20))
                    self.proof('independent-physical-database-observer', {'engine': engine, **result})
                else:
                    actual = observer.query(item['query'])
                    if op == 'assert-observer-oracle':
                        try:
                            if item['oracle'] == 'effect-once':
                                if item['query'] != 'acceptance-effects':
                                    raise ValueError('Effect query differs.')
                                result = oracle.assert_effect_snapshot(actual, engine, item['case'],
                                                                      completed=self.effect_cases[engine] - {item['case']})
                                self.effect_cases[engine].add(item['case'])
                            elif item['oracle'] == 'snapshot':
                                result = oracle.assert_snapshot(actual, engine, item['query'], suffix=item.get('suffix', ''))
                            elif item['oracle'] == 'script-receipts':
                                if item['query'] != 'acceptance-receipts':
                                    raise ValueError('Receipt query differs.')
                                result = oracle.assert_script_receipts(actual, engine, item['case'])
                            else:
                                raise ValueError('Fixed typed oracle differs.')
                        except ValueError:
                            raise Refused('Independent fixed metadata/typed/effect oracle differs.') from None
                    else:
                        expected = self.captured(item['capture'], 'observer-' + engine) if op == 'assert-observer-same' else {'columns': item['columns'], 'rows': item['rows']}
                        if canonical(actual) != canonical(expected):
                            raise Refused('Independent physical DB typed metadata/values differ.')
                        result = {'queryId': item['query'], 'typedSha256': digest_bytes(canonical(actual)), 'rowCount': len(actual['rows'])}
                    self.proof('independent-physical-database-observer', {'engine': engine, **result})
            elif op == 'join-completed-matrix':
                MatrixJoin(self.completed_proofs, self.driver.desktop,
                           self.driver.artifact.require_verification_source()).require_complete()
            elif op == 'effects-setup':
                result = self.databases.setup_effects(item['engine'])
                self.proof('exact-owned-effects-corpus', result)
            elif op == 'relay-start':
                if item['capture'] in self.relays:
                    raise Refused('Original relay capture key cannot be rebound.')
                self.relays[item['capture']] = OwnedRelay(self.databases, item['engine'], self.journal)
            elif op == 'relay-lost-commit-ack':
                self.lost_commit_ack(item)
            elif op == 'relay-pin-catalog':
                self.pin_relay_catalog(item)
            elif op == 'relay-prepare-apply':
                self.prepare_relay_apply(item)
            elif op == 'relay-lost-apply-ack':
                self.lost_apply_ack(item)
            elif op == 'transfer-check':
                result = check_transfer(self.artifact_path(item['path']))
                if 'expectedSource' not in item:
                    raise Refused('Transfer requires an independently pinned exact expected source.')
                expected_path = self.staged.path(item['expectedSource'])
                if canonical(parse(read(expected_path))) != canonical(parse(read(self.artifact_path(item['path'])))):
                    raise Refused('Transfer metadata differs from independent fixed expected source.')
                self.proof('independent-profile-transfer', result)
            elif op == 'export-check':
                self.export(item)
            elif op == 'credential-reserve':
                if item['capture'] in self.credentials:
                    raise Refused('Credential capture key cannot be rebound.')
                if self.store is None:
                    self.store = BoundedStore(self.driver.env)
                account = self.profile_id(item['profileId'])
                self.credentials[item['capture']] = OwnedCredential(self.store, self.journal.nonce, account, self.journal, [account])
            elif op in ('credential-create', 'credential-arm-ui-write', 'credential-arm-ui-update', 'credential-arm-ui-delete', 'credential-verify'):
                credential = self.credentials[item['capture']]
                if op == 'credential-verify':
                    result = credential.verify(item.get('outcome'))
                    if result['absent'] is not item['absent'] or result['empty'] is not item['empty']:
                        raise Refused('Credential absence versus empty differs.')
                    self.proof('native-credential-absence-and-roundtrip', result)
                elif op == 'credential-arm-ui-delete':
                    credential.arm_ui_delete()
                else:
                    secret = b'' if item['value'] == 'empty' else self.input(item['value']).encode()
                    method = {'credential-create': 'create', 'credential-arm-ui-write': 'arm_ui_write',
                              'credential-arm-ui-update': 'arm_ui_update'}[op]
                    getattr(credential, method)(secret)
            elif op == 'file-capture':
                if item['capture'] in self.files:
                    raise Refused('Original held file capture cannot be rebound.')
                held = HeldFile(self.data_root, item['file'])
                self.files[item['capture']] = held
                self.journal.append('file-identity-captured', fileKey=item['file'], capture=item['capture'],
                                    device=held.identity[0], inode=held.identity[1], sha256=held.expected)
            elif op in ('file-assert-same', 'file-backup-check', 'file-backup-discover'):
                held = self.files[item['capture']]
                result = (held.assert_same() if op == 'file-assert-same' else held.discover_backup()
                          if op == 'file-backup-discover' else held.backup_matches(self.data_root, item['file']))
                self.proof('exact-owned-file-receipt', result)
            elif op == 'file-block-replacement':
                if item['barrier'] in self.barriers:
                    raise Refused('Original publication barrier key cannot be rebound.')
                barrier = ReplacementBarrier(self.files[item['capture']])
                self.barriers[item['barrier']] = barrier
                self.journal.append('exact-file-publication-barrier-held', barrier=item['barrier'],
                                    sha256=barrier.original.expected, nativeDenyWriteDeleteSharing=True)
            elif op == 'file-check-barrier':
                self.proof('exact-owned-file-publication-barrier', self.barriers[item['barrier']].verify())
            elif op == 'file-release-barrier':
                barrier = self.barriers[item['barrier']]
                barrier.verify()
                barrier.close()
                self.journal.append('exact-file-publication-barrier-released', barrier=item['barrier'])
            elif op == 'persistence-case':
                self.persistence_case(item)
            elif op == 'normal-close':
                if self.lifecycle is None:
                    raise Pending('Exact common Close controller required.')
                self.lifecycle.close(self)
            elif op == 'restart':
                self.restart()
            else:
                raise Refused('Unsupported operation is never silently skipped.')
            if assertion:
                self.assertions.add(assertion)
                self.coverage.add((assertion, item.get('requirement'), item.get('engine', 'native')))
            self.journal.append('workflow-action-completed', actionIndex=index, operation=op,
                                assertion=assertion, exactOwnerVerified=True, captureEpoch=self.epoch)

    def cleanup_credentials(self):
        clean = True
        for credential in self.credentials.values():
            try:
                credential.remove()
            except Exception:
                clean = False
        return clean

    def close_file_receipts(self):
        for barrier in self.barriers.values():
            barrier.close()
        for held in self.files.values():
            held.close()

    def close_relays(self):
        clean = True
        for relay in self.relays.values():
            try:
                relay.close()
            except Exception:
                clean = False
        return clean


class Lifecycle:
    """Only retained exact children; a restart always creates a fresh Driver."""
    def __init__(self, artifact, env, desktop, contract, acknowledged, journal, actions, children):
        self.artifact, self.env, self.desktop, self.contract = artifact, env, desktop, contract
        self.acknowledged, self.journal, self.actions, self.children = acknowledged, journal, actions, children

    def close(self, workflow):
        normal_close(workflow, self.actions, self.journal)

    def relaunch(self, workflow):
        child, driver = launch(self.artifact, self.env, self.desktop, self.contract, self.acknowledged, self.journal)
        self.children.append(child)
        if driver.window_keys or driver.bindings:
            # launch inspect establishes a NEW current main window, never old pins.
            if driver.bindings:
                raise Refused('Restart inherited stale native target bindings.')
        return driver


def expected_assertions(scenario):
    return {'%s-S%02d-A%02d' % (scenario['feature'], s + 1, a + 1)
            for s, step in enumerate(scenario['procedure']) for a, _ in enumerate(step['assertions'])}


def launch(artifact, env, desktop, contract, acknowledged, journal):
    artifact.verify()
    child = Child(artifact.gui, artifact.files[artifact.gui_name]['sha256'], env)
    journal.append('exact-child-created', owner=child.identity(), identity=artifact.identity)
    try:
        driver = Driver(artifact, child, desktop, env, contract, acknowledged)
        deadline = time.monotonic() + 25
        while True:
            try:
                driver.action('inspect')
                return child, driver
            except Refused:
                child.verify()
                if time.monotonic() >= deadline:
                    raise Pending('Exact owned native window did not become available.') from None
                time.sleep(0.1)
    except Exception:
        child.stop()
        raise


def normal_close(workflow, actions, journal):
    if getattr(workflow.driver.child, 'normal_exit', False):
        raise Refused('Common Close cannot be replayed on a retired child.')
    if not actions or actions[-1].get('expectExit') is not True:
        raise Refused('Reviewed actual common Close sequence is required.')
    owner = workflow.driver.child.identity()
    for index, item in enumerate(actions):
        workflow.verify_root()
        result = workflow.driver.action(item['action'], item['selector'],
                                        text=workflow.input(item['input']) if 'input' in item else None,
                                        expected_hash=item.get('expectedSha256'), native_action=item.get('nativeAction'),
                                        pin=item.get('pin'), window=item.get('window'),
                                        allow_exit=index == len(actions) - 1)
        workflow.proof('exact-owned-native-actions', {'action': item['action'], 'ownedPid': result['ownedPid'],
                                                    'windowKey': result['windowKey'], 'binding': result['binding']})
    process = workflow.driver.child.process
    try:
        process.wait(timeout=30)
    except Exception:
        raise Refused('Normal common Close did not finish.') from None
    if process.returncode != 0:
        raise Refused('Normal common Close failed.')
    workflow.driver.artifact.verify()
    workflow.driver.child.normal_exit = True
    journal.append('normal-close-completed', owner=owner, ownedPid=process.pid, exitCode=0, forcedTermination=False)


def concurrent_refusal(owner, competing_artifact, env, journal):
    # Same private canonical data root and shared kernel .workspace.lock.
    owner.driver.child.verify()
    owner.driver.artifact.verify()
    competing_artifact.verify()
    owner.verify_root()
    if env != owner.driver.env:
        raise Refused('Competing image must use the original exact canonical owner environment.')
    before = state_snapshot(owner.data_root)
    physical = {engine: observer.session_snapshot() for engine, observer in owner.observers.items()}
    if set(physical) != {'postgresql', 'mysql'} or any(snapshot['sessions'] for snapshot in physical.values()):
        raise Refused('Repeated-launch proof requires both original physical servers independently disconnected.')
    competitor = Child(competing_artifact.gui, competing_artifact.files[competing_artifact.gui_name]['sha256'], env)
    journal.append('concurrent-child-created', owner=competitor.identity())
    try:
        try:
            competitor.process.wait(timeout=10)
        except Exception:
            raise Pending('Second exact image did not perform a bounded safe refusal.') from None
        if competitor.process.returncode == 0:
            raise Refused('Second launch did not report safe ownership refusal.')
        owner.driver.action('inspect')
        owner.verify_root()
        if before != state_snapshot(owner.data_root):
            raise Refused('Concurrent launch changed original private data.')
        after = {engine: observer.session_snapshot() for engine, observer in owner.observers.items()}
        if canonical(after) != canonical(physical):
            raise Refused('Competing launch changed original physical sessions or restored a connection.')
        return {'kind': 'concurrent-exact-image-refusal', 'competingGuiSha256': competing_artifact.files[competing_artifact.gui_name]['sha256'],
                'originalPid': owner.driver.child.process.pid, 'secondPid': competitor.process.pid,
                'safeNonzeroExit': True, 'dataPreserved': True, 'sameCanonicalOwnerEnvironment': True,
                'disconnectedBeforeAfterBothEngines': True, 'readOnlyExecutionTraceEstablished': False,
                'physicalSessionsSha256': digest_bytes(canonical(after))}
    finally:
        competitor.stop()


def ensure_output():
    parent = OUTPUT.parent
    safe(parent, directory=True)
    if not OUTPUT.exists():
        private_directory(OUTPUT)
    native.private_path(OUTPUT, directory=True)


def execute(request, root, nonce, ledger, acknowledged, selected):
    journal = Journal(root, nonce)
    desktop = request['desktop']
    artifacts = {}
    children, observers, workflows = [], {}, []
    databases = None
    try:
        for phase in ('previous', 'candidate'):
            descriptor = request.get(phase)
            if not descriptor:
                raise Pending('Both actual trusted previous and candidate artifacts are required.')
            if descriptor.get('provenance') != ('trusted-prior-artifact' if phase == 'previous' else 'trusted-candidate-artifact'):
                raise Refused('Previous/candidate trust provenance differs from its phase.')
            try:
                artifacts[phase] = Artifact(descriptor, desktop)
            except FileNotFoundError:
                raise Pending('Required exact archive or distributed checksum is unavailable.') from None
        previous, candidate = artifacts['previous'], artifacts['candidate']
        prior_order = (*map(int, previous.identity['version'].split('.')), int(previous.identity['buildNumber']))
        candidate_order = (*map(int, candidate.identity['version'].split('.')), int(candidate.identity['buildNumber']))
        if (previous.digest == candidate.digest or previous.identity == candidate.identity or prior_order >= candidate_order):
            raise Refused('Upgrade requires a distinct actual prior version/build, never a relabeled candidate.')
        try:
            selector_contracts = contracts(request, artifacts)
            execution_plans = plans(request)
        except FileNotFoundError:
            raise Pending('Required reviewed native selector or execution plan is unavailable.') from None
        # An acknowledged disposable native desktop is required before staging/launch.
        if not acknowledged:
            raise Pending('Explicit owned disposable desktop acknowledgement is required.')
        try:
            host = native.preflight('windows' if desktop == 'windows11-x64' else 'wayland' if desktop.endswith('wayland') else 'x11')
        except (ValueError, OSError):
            raise Pending('Required supported owned native desktop stand is unavailable.') from None
        ledger['host'] = host
        fixture = root / 'fixture'
        private_directory(fixture)
        env = clean_environment(fixture, desktop)
        private_directory(fixture / 'inputs')
        private_directory(fixture / 'outputs')
        sql_descriptor = os.open(fixture / 'inputs/synthetic.sql', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(sql_descriptor, 'w', encoding='utf-8') as sql_file:
            sql_file.write(parse(read(FIXTURES / 'synthetic-inputs.json', 65536))['plainText'])
        data_root = fixture / ('data/DBeerGPUI' if desktop == 'windows11-x64' else 'config/dbeer-gpui')
        private_directory(data_root)
        for name, source in (('connections.json', 'empty-connections.json'), ('workspace.json', 'empty-workspace.json')):
            descriptor = os.open(data_root / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, 'wb') as output:
                output.write(read(FIXTURES / source, 65536))
        for phase, artifact in artifacts.items():
            artifact.stage(fixture / phase)
            journal.append('artifact-staged', phase=phase, artifact=artifact.proof())
            verify_build_info(artifact, env)
        pair = request.get('databasePair')
        if not isinstance(pair, list) or len(pair) != 2:
            raise Pending('Both exact-owned database families are required for installed upgrade acceptance.')
        database_root = fixture / nonce
        private_directory(database_root)
        databases = DatabasePair(pair, database_root, env)
        for engine in ('postgresql', 'mysql'):
            observers[engine] = Observer(candidate, env, databases, engine)
        child, driver = launch(previous, env, desktop, selector_contracts['previous'], acknowledged, journal)
        children.append(child)
        workflow = Workflow(fixture, data_root, driver, journal, databases, observers,
                            Lifecycle(driver.artifact, env, desktop, selector_contracts['previous' if driver.artifact is previous else 'candidate'],
                                      acknowledged, journal, execution_plans['normalClose'], children))
        workflows.append(workflow)
        workflow.completed_proofs = request.get('completedProofs', [])
        workflow.execute(execution_plans['preparation'])
        # Both concurrent old/new directions and same-executable repeat use the same
        # actual fixture, not copied synthetic old identities.
        concurrency = [concurrent_refusal(workflow, previous, env, journal), concurrent_refusal(workflow, candidate, env, journal)]
        normal_close(workflow, execution_plans['normalClose'], journal)
        before = typed_state(data_root, require_populated=True)
        journal.append('before-upgrade-typed-state', typedStateSha256=digest_bytes(canonical(before)))
        child, driver = launch(candidate, env, desktop, selector_contracts['candidate'], acknowledged, journal)
        children.append(child)
        workflow = Workflow(fixture, data_root, driver, journal, databases, observers,
                            Lifecycle(driver.artifact, env, desktop, selector_contracts['previous' if driver.artifact is previous else 'candidate'],
                                      acknowledged, journal, execution_plans['normalClose'], children))
        # Preserve exact credential ownership lifetimes across actual process update.
        workflow.credentials, workflow.store = workflows[0].credentials, workflows[0].store
        workflow.captures = dict(workflows[0].captures)
        workflow.effect_cases = {engine: set(cases) for engine, cases in workflows[0].effect_cases.items()}
        workflow.capture_epochs = dict(workflows[0].capture_epochs)
        workflow.epoch = workflows[0].epoch + 1
        workflow.profile_receipts = {account: workflow.epoch for account in workflows[0].profile_receipts if account in before['profileIds']}
        for key, (_, kind) in list(workflow.capture_epochs.items()):
            if kind == 'profile-id' and workflow.captures[key] in workflow.profile_receipts:
                workflow.capture_epochs[key] = (workflow.epoch, kind)
        workflow.staged = workflows[0].staged
        workflow.completed_proofs = request.get('completedProofs', [])
        workflows.append(workflow)
        preserved = assert_same(before, typed_state(data_root, require_populated=True))
        disconnected = []
        for engine, observer in observers.items():
            result = observer.wait_scalar('connections-' + engine, lambda count: count == 0, timeout=10)
            disconnected.append({'kind': 'ordinary-restart-disconnected', 'engine': engine, **result})
        concurrency.extend([concurrent_refusal(workflow, previous, env, journal), concurrent_refusal(workflow, candidate, env, journal)])
        for scenario in catalog()['scenarios']:
            feature = scenario['feature']
            if selected and feature not in selected:
                continue
            actions = execution_plans['scenarios'].get(feature)
            if not actions:
                record(ledger, feature, desktop, 'pending', reason='reviewed-native-scenario-plan-unavailable')
                continue
            if workflow.driver.child.process.poll() is not None:
                workflow.restart()
            workflow.assertions, workflow.proofs, workflow.coverage = set(), [], set()
            try:
                validate_scenario(feature, actions, required_plan(catalog()))
                workflow.execute(actions)
                if workflow.assertions != expected_assertions(scenario):
                    raise Pending('Every frozen procedure assertion needs an independent concrete check.')
                workflow.proof('completed-procedure-assertions', {'assertionIds': sorted(workflow.assertions)})
                if feature == 'F56':
                    workflow.proof('actual-trusted-prior-upgrade', {'previous': previous.proof(), 'candidate': candidate.proof()})
                    workflow.proofs.extend(concurrency + disconnected)
                    workflow.proof('independent-persisted-typed-state', preserved)
                record(ledger, feature, desktop, 'passed-scenario', workflow.proofs)
            except Pending:
                record(ledger, feature, desktop, 'pending', workflow.proofs, reason='required-native-capability-or-observation-incomplete')
            except Refused:
                record(ledger, feature, desktop, 'failed', workflow.proofs, reason='required-behavior-or-ownership-check-refused')
                raise
        if workflow.driver.child.process.poll() is None:
            normal_close(workflow, execution_plans['normalClose'], journal)
        restart_before = typed_state(data_root, require_populated=True)
        child, driver = launch(candidate, env, desktop, selector_contracts['candidate'], acknowledged, journal)
        children.append(child)
        restart = Workflow(fixture, data_root, driver, journal, databases, observers)
        workflows.append(restart)
        assert_same(restart_before, typed_state(data_root, require_populated=True))
        for engine, observer in observers.items():
            observer.wait_scalar('connections-' + engine, lambda count: count == 0, timeout=10)
        normal_close(restart, execution_plans['normalClose'], journal)
        journal.append('ordinary-update-restart-completed', disconnectedBothEngines=True)
    except Pending:
        for cell in ledger['cells']:
            if cell['target'] == desktop and cell['status'] == 'not-run' and (not selected or cell['feature'] in selected):
                cell.update(status='pending', reason='required-native-stand-artifact-selector-or-procedure-unavailable')
        ledger['runStatus'] = 'pending'
    except Exception:
        ledger['runStatus'] = 'failed'
        # Native/DB exceptions may contain SQL, credentials, results or paths.
        journal.append('run-refused', payloadDiagnosticsDiscarded=True)
    finally:
        forced = False
        for workflow in reversed(workflows):
            if workflow.driver.child.process.poll() is None:
                try:
                    normal_close(workflow, execution_plans['normalClose'], journal)
                except Exception:
                    journal.append('normal-close-cleanup-refused', ownedPid=workflow.driver.child.process.pid)
        for child in reversed(children):
            if child.process.poll() is None:
                forced = True
                try:
                    child.stop()
                except Exception:
                    journal.append('owned-child-cleanup-refused', ownedPid=child.process.pid)
        relay_clean = all([workflow.close_relays() for workflow in workflows])
        observer_clean = True
        for observer in observers.values():
            try:
                observer.close()
            except Exception:
                observer_clean = False
                journal.append('observer-cleanup-refused')
        all_children_stopped = all(child.process.poll() is not None for child in children)
        normal_shutdown = all_children_stopped and not forced and all(getattr(child, 'normal_exit', False) for child in children)
        credential_clean = all([workflow.cleanup_credentials() for workflow in workflows]) if normal_shutdown else not any(workflow.credentials for workflow in workflows)
        files_clean = True
        for workflow in workflows:
            try:
                workflow.close_file_receipts()
            except Exception:
                files_clean = False
                journal.append('held-file-receipt-close-refused')
        try:
            db_clean = databases.close() if databases else True
        except Exception:
            db_clean = False
            journal.append('database-cleanup-refused')
        ledger['cleanup'] = {'forcedOwnedChildTermination': forced, 'forcedTerminationProvesRollback': False,
                             'credentialsCleaned': credential_clean, 'databasesCleaned': bool(db_clean),
                             'normalGuiShutdown': normal_shutdown, 'observersClosedNormally': observer_clean,
                             'heldFileReceiptsClosed': files_clean,
                             'ownedDatabaseRelaysClosed': relay_clean,
                             'privateFixtureRetainedForReview': True, 'foreignProcessesEnumeratedOrKilled': False}
        # A failed final close/restart/cleanup cannot leave a scenario accepted.
        if forced or not normal_shutdown or not relay_clean or not observer_clean or not files_clean or not credential_clean or not db_clean or ledger.get('runStatus') == 'failed':
            ledger['runStatus'] = 'failed'
            for cell in ledger['cells']:
                if cell['target'] == desktop and cell['status'] == 'passed-scenario':
                    cell.update(status='failed', reason='final-lifecycle-or-cleanup-incomplete')
        elif 'runStatus' not in ledger:
            cells = [c for c in ledger['cells'] if c['target'] == desktop and (not selected or c['feature'] in selected)]
            ledger['runStatus'] = 'completed' if all(c['status'] == 'passed-scenario' for c in cells) else 'pending'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('prepare', 'run'))
    parser.add_argument('--request', type=Path, required=True)
    parser.add_argument('--owned-disposable-desktop', action='store_true')
    parser.add_argument('--scenario', action='append', choices=['F%02d' % i for i in range(1, 58)])
    args = parser.parse_args()
    request = request_file(args.request)
    ensure_output()
    nonce = uuid.uuid4().hex
    root = OUTPUT / nonce
    private_directory(root)
    ledger = new_ledger(nonce, now())
    # Pin only sanitized descriptors, never external request/paths/plaintext UI values.
    write_new(root / 'request.json', {'schemaVersion': 1, 'runNonce': nonce, 'desktop': request['desktop'],
                                    'requestSha256': sha(args.request), 'command': args.command,
                                    'disposableDesktopAcknowledged': args.owned_disposable_desktop})
    if args.command == 'prepare':
        ledger['runStatus'] = 'not-run'
        ledger['preparedScenarios'] = 57
        write_new(root / 'required-plan.json', {'schemaVersion': 1, 'nativeObserved': False,
                                               'selectorIntegrationReviewed': False, 'scenarios': required_plan(catalog())})
    else:
        execute(request, root, nonce, ledger, args.owned_disposable_desktop, set(args.scenario or []))
    ledger['finishedAt'] = now()
    write_new(root / 'completed.json', ledger)
    print('Installed acceptance ' + ledger['runStatus'] + '; private evidence: ' + str(root / 'completed.json'))
    return 0 if ledger['runStatus'] == 'completed' else 2


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception:
        print('Installed acceptance refused; no payload diagnostics retained.', file=sys.stderr)
        sys.exit(2)
