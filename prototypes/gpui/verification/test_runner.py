#!/usr/bin/env python3
"""Prepared runner safety cases. Execute only at final integration after Task 32."""
import io
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import run
import owned_databases
import dependency_inputs


@contextmanager
def private_temporary():
    with tempfile.TemporaryDirectory(dir=run.REPO / 'build') as directory:
        root = Path(directory) / 'owned'
        run.private_directory(root)
        yield root


class ProofTests(unittest.TestCase):
    def test_report_publication_retains_current_user_privacy_and_preserves_existing_record(self):
        with private_temporary() as root:
            report = root / 'completed.json'
            value = {'status': 'owned-fixture'}
            run.write_json(report, value)
            run.verify_private(report, directory=False)
            original = report.read_bytes()
            with self.assertRaises(FileExistsError):
                run.write_json(report, {'status': 'replacement'})
            self.assertEqual(report.read_bytes(), original)
            self.assertEqual(json.loads(original), value)
            self.assertEqual(list(root.iterdir()), [report])

    def child(self, output, code=0, kind='rust'):
        process = mock.Mock()
        process.stdout = io.BytesIO(output)
        process.pid = 12345
        process.poll.return_value = code
        process.wait.return_value = code
        with mock.patch.object(subprocess, 'Popen', return_value=process), mock.patch.object(run, 'expected_go_packages', return_value={'dbeer/helper/internal/postgres'}):
            return run.collect(['owned-test-child'], {}, 10, kind)

    def test_success_without_completed_summary_is_rejected(self):
        self.assertFalse(self.child(b'test one ... ok\n')['completed'])

    def test_empty_filter_is_rejected(self):
        self.assertFalse(self.child(b'test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 12 filtered out;\n')['completed'])

    def test_summary_failure_exit_and_ignored_are_preserved(self):
        proof = self.child(b'test sample::ignored ... ignored, sensitive details suppressed\ntest sample::case ... ok\ntest result: ok. 1 passed; 0 failed; 1 ignored; 0 measured; 0 filtered out;\n')
        self.assertTrue(proof['completed'])
        self.assertEqual(proof['ignored'], ['sample::ignored'])
        self.assertNotIn('sensitive', json.dumps(proof))
        self.assertFalse(self.child(b'test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out;\n', 1)['completed'])

    def test_export_fixture_cleanup_refusal_cannot_leave_required_db_proof_passed(self):
        name = 'run_to_file::database_tests::both_engines_full_counts_independent_observer_temp_set_transaction_and_exact_once_mutations'
        proof = self.child(('test ' + name + ' ... FAILED\n'
                            'test result: FAILED. 0 passed; 1 failed; 0 ignored; 0 measured; 0 filtered out;\n').encode(), code=101)
        self.assertFalse(proof['completed'])
        self.assertEqual(proof['tests'], [{'id': name, 'outcome': 'FAILED'}])

    def test_arbitrary_diagnostics_and_results_are_never_retained(self):
        marker = 'PRIVATE_FIXTURE_VALUE'
        proof = self.child((marker + '\nSELECT synthetic\npassword=synthetic\ntest sample::case ... ok\ntest result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out;\n').encode())
        text = json.dumps(proof)
        self.assertTrue(proof['completed'])
        for forbidden in (marker, 'SELECT', 'password='):
            self.assertNotIn(forbidden, text)

    def test_oversized_line_is_drained_without_becoming_a_summary(self):
        proof = self.child(b'x' * (run.MAX_LINE + 50) + b'\ntest sample::case ... ok\ntest result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out;\n')
        self.assertEqual(proof['truncatedLines'], 1)
        self.assertFalse(proof['completed'])

    def test_go_json_skips_retain_root_symbol_without_output_or_subtest_values(self):
        messages = [{'Action':'start','Package':'dbeer/helper/internal/postgres'},
                    {'Action':'pass','Package':'dbeer/helper/internal/postgres','Test':'TestSynthetic'},
                    {'Action':'skip','Package':'dbeer/helper/internal/postgres','Test':'TestSynthetic/private-synthetic-value','Output':'private-output'},
                    {'Action':'pass','Package':'dbeer/helper/internal/postgres'}]
        proof = self.child(('\n'.join(json.dumps(m) for m in messages)+'\n').encode(), kind='go')
        self.assertTrue(proof['completed'])
        self.assertEqual(proof['ignored'], ['dbeer/helper/internal/postgres/TestSynthetic'])
        self.assertFalse('private-' in json.dumps(proof), 'Go subtest payload leaked into proof.')

    def test_duplicate_json_is_refused(self):
        with tempfile.TemporaryDirectory(dir=run.REPO / 'build') as directory:
            path = Path(directory) / 'duplicate.json'
            path.write_text('{"version":1,"version":2}')
            with self.assertRaises(ValueError):
                run.strict_json(path)

    def test_cross_build_override_is_refused_before_any_child(self):
        with tempfile.TemporaryDirectory(dir=run.REPO / 'build') as directory:
            with mock.patch.dict(os.environ, {'CARGO_BUILD_TARGET': 'foreign-target'}):
                with self.assertRaises(ValueError):
                    run.clean_environment(Path(directory))

    def test_production_settings_are_excluded(self):
        with tempfile.TemporaryDirectory(dir=run.REPO / 'build') as directory:
            with mock.patch.dict(os.environ, {'DBEER_TEST_DSN': 'private-value', 'DBEER_GPUI_TLS_MANIFEST': 'private-path',
                                             'DBEER_PRODUCT_BUILD_IDENTITY':'private-identity','PGPASSWORD':'private-password',
                                             'RUSTFLAGS':'private-flags','GOFLAGS':'private-link-flags',
                                             'CARGO_PROFILE_DEV_DEBUG':'2', 'CARGO_PROFILE_TEST_DEBUG':'2',
                                             'CARGO_INCREMENTAL':'1'}):
                environment = run.clean_environment(Path(directory))
                self.assertFalse('DBEER_TEST_DSN' in environment, 'Inherited DB setting was retained.')
                self.assertFalse('DBEER_GPUI_TLS_MANIFEST' in environment, 'Inherited TLS setting was retained.')
                self.assertFalse('private-value' in json.dumps(environment), 'Inherited fixture value was retained.')
                self.assertFalse('private-' in json.dumps(environment), 'Inherited compiler, identity or DB fixture value was retained.')
                self.assertEqual(environment['CARGO_TARGET_DIR'], str(run.REPO / 'build/gpui/verification-target'))
                self.assertEqual(environment['CARGO_NET_OFFLINE'], 'true')
                self.assertEqual(environment['CARGO_PROFILE_DEV_DEBUG'], '0')
                self.assertEqual(environment['CARGO_PROFILE_TEST_DEBUG'], '0')
                self.assertEqual(environment['CARGO_INCREMENTAL'], '0')

    def test_summary_count_must_match_actual_assertion_rows(self):
        summary = b'test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out;\n'
        self.assertFalse(self.child(summary)['completed'])
        self.assertFalse(self.child(b'test same ... ok\ntest same ... ok\n' + summary)['completed'])
        self.assertFalse(self.child(b'test same ... ok\n' + summary + summary)['completed'])

    def test_missing_go_package_and_swift_only_summary_are_incomplete(self):
        self.assertFalse(self.child(b'{"Action":"pass","Package":"dbeer/helper/internal/postgres"}\n', kind='go')['completed'])
        self.assertFalse(self.child(b'Test run with 5 tests passed after 1 second.\n', kind='swift')['completed'])
        self.assertFalse(self.child(b'{"Action":"pass","Package":"dbeer/helper/internal/postgres","Output":"private-value"}\n', kind='go')['completed'])

    def test_python_zero_or_missing_completion_is_refused(self):
        self.assertFalse(self.child(b'Ran 0 tests in 0.001s\nOK\n', kind='python')['completed'])
        self.assertFalse(self.child(b'test_case (__main__.ProofTests.test_case) ... ok\nRan 1 test in 0.001s\n', kind='python')['completed'])
        self.assertTrue(self.child(b'test_case (__main__.ProofTests.test_case) ... ok\nRan 1 test in 0.001s\nOK\n', kind='python')['completed'])

    def test_missing_peer_hash_refuses_before_test_child(self):
        with tempfile.TemporaryDirectory(dir=run.REPO / 'build') as directory:
            root = Path(directory)
            with mock.patch.object(run, 'verify_private', return_value=(1, 2)), mock.patch.object(run, 'executable_identity', return_value={'sha256':'a'*64}), mock.patch.object(subprocess, 'Popen') as spawn:
                for digest in ('', 'b'*64):
                    with self.assertRaises(ValueError):
                        run.verify_fixture_environment({'DBEER_GPUI_TEST_ROOT':str(root), 'DBEER_GPUI_FAULT_HELPER_SHA256':digest})
                spawn.assert_not_called()

    def test_executable_replacement_or_changed_bytes_refuse_original_identity(self):
        with private_temporary() as directory:
            path = directory / ('synthetic.exe' if os.name == 'nt' else 'synthetic')
            header = bytearray(256)
            if os.name == 'nt':
                header[:2] = b'MZ'
                header[60:64] = (64).to_bytes(4, 'little')
                header[64:70] = b'PE\0\0\x64\x86'
                header[88:90] = b'\x0b\x02'
            else:
                header[:6] = b'\x7fELF\x02\x01'
                header[18:20] = b'\x3e\x00'
            path.write_bytes(header)
            if os.name != 'nt': path.chmod(0o700)
            expected = run.executable_identity(path)
            path.rename(path.with_name('original-owned'))
            path.write_bytes(header)
            if os.name != 'nt': path.chmod(0o700)
            with self.assertRaises(ValueError):
                run.executable_identity(path, expected)
            latest = run.executable_identity(path)
            with path.open('ab') as stream: stream.write(b'x')
            with self.assertRaises(ValueError):
                run.executable_identity(path, latest)

    def test_cargo_success_requires_artifact_and_one_complete_terminal(self):
        self.assertFalse(self.child(b'{"reason":"build-finished","success":true}\n', kind='cargo')['completed'])
        self.assertFalse(self.child(b'{"reason":"build-finished","success":false}\n', kind='cargo')['completed'])

    def test_retained_child_cleanup_does_not_search_or_kill_foreign_processes(self):
        process = mock.Mock()
        process.poll.return_value = None
        with mock.patch.object(subprocess, 'run') as spawn:
            run.stop_child(process)
            process.terminate.assert_called_once()
            process.wait.assert_called_once_with(timeout=8)
            spawn.assert_not_called()

    def test_cleanup_refuses_a_changed_container_owner(self):
        with private_temporary() as directory:
            owner = object.__new__(owned_databases.OwnedDatabases)
            owner.records = [{'containerId': 'a' * 64}]
            owner.nonce = 'b' * 32
            owner.directory = Path(directory)
            owner.cleanup = []
            owner.counter = 0
            owner.host_arch = 'linux/amd64'
            with mock.patch.object(owned_databases, 'quiet', return_value='foreign-owner') as command:
                self.assertFalse(owner.close())
                self.assertEqual(command.call_count, 1)
                self.assertNotIn('rm', command.call_args.args[0])

    def test_private_cleanup_preserves_same_byte_foreign_inode(self):
        with private_temporary() as directory:
            owner = object.__new__(owned_databases.OwnedDatabases)
            owner.records, owner.cleanup, owner.private_cleanup = [], [], []
            owner.nonce, owner.counter, owner.host_arch = 'b'*32, 0, 'linux/amd64'
            owner.directory = Path(directory)
            run.private_directory(owner.directory/'postgres')
            path = owner.directory/'postgres/password'
            owned_databases.write_private(path, 'private-synthetic-marker')
            owner.private_files = {'postgres/password': owned_databases.private_identity(path)}
            path.rename(path.with_name('original-owned'))
            owned_databases.write_private(path, 'private-synthetic-marker')
            self.assertFalse(owner.close())
            self.assertTrue(path.exists(), 'A same-byte foreign replacement was deleted.')

    def test_matrix_static_references_are_real(self):
        self.assertEqual(run.validate()['nativeAcceptance']['cells'], 171)

    def test_matrix_validation_reads_utf8_sources_under_windows_legacy_encoding(self):
        original = Path.read_text
        def legacy_read(path, *args, **kwargs):
            if not args and kwargs.get('encoding') is None:
                kwargs['encoding'] = 'cp1252'
            return original(path, *args, **kwargs)
        with mock.patch.object(Path, 'read_text', legacy_read):
            self.assertEqual(run.validate()['nativeAcceptance']['cells'], 171)

    def test_required_go_database_assertions_cannot_pass_via_skip_or_duplicate(self):
        required = ['dbeer/helper/internal/postgres/TestRequired']
        proof = {'completed': True, 'tests': [{'id': required[0], 'outcome': 'ok'}], 'ignored': [required[0]]}
        self.assertFalse(run.require_go_assertions(proof, required)['completed'])
        proof.update(completed=True, ignored=[], tests=proof['tests'] * 2)
        self.assertFalse(run.require_go_assertions(proof, required)['completed'])

    def test_behavior_requires_actual_unique_assertions_and_keeps_native_open(self):
        matrix = {'rustStages': [{'id':'owned', 'hosts':['Linux']}], 'databaseStages':[], 'sharedStages':[], 'f57Requirements':{}}
        cases = {'cases':[{'id':'CASE', 'remainingNative':['actual desktop'], 'executions':[{'assertion':'source.rs#original', 'stages':['owned']}]}]}
        ledger = {'host':{'os':'Linux'}, 'stages':[{'id':'owned', 'status':'passed', 'runs':[{'tests':[{'id':'tests::other', 'outcome':'ok'}]}]}]}
        evidence = run.behavior_evidence(matrix, cases, ledger)
        self.assertEqual(evidence['cases'][0]['assertions'][0]['stages'][0]['status'], 'failed')
        ledger['stages'][0]['runs'][0]['tests'] = [{'id':'tests::original', 'outcome':'ok'}]
        evidence = run.behavior_evidence(matrix, cases, ledger)
        self.assertEqual(evidence['cases'][0]['assertions'][0]['stages'][0]['status'], 'passed-in-declared-layer')
        self.assertFalse(evidence['nativeAcceptanceEstablished'])
        self.assertFalse(evidence['f57Complete'])
        ledger['stages'][0]['runs'][0]['ignored'] = ['tests::original']
        self.assertEqual(run.behavior_evidence(matrix, cases, ledger)['cases'][0]['assertions'][0]['stages'][0]['status'], 'failed')

    def test_every_standalone_command_uses_all_current_maintained_patches(self):
        command = run.cargo_plan({'manifest':'prototypes/gpui/vendor/gpui-component/Cargo.toml', 'lib':True, 'integrationTests':True})
        for crate in ('gpui-pre', 'gpui-base', 'gpui-component', 'gpui-pre-linux'):
            self.assertIn('patch.crates-io.' + crate + '.path="' + (run.REPO / 'prototypes/gpui/vendor' / crate).as_posix() + '"', command)
        self.assertIn('--tests', command)

    def test_new_root_integration_directory_is_bound_by_the_source_contract(self):
        self.assertIn('prototypes/gpui/tests', run.source_contract.ROOTS)
        with tempfile.TemporaryDirectory(dir=run.REPO / 'build') as directory:
            root = Path(directory)
            path = root / dependency_inputs.PUBLIC_ELEMENT_SOURCE
            path.parent.mkdir(parents=True)
            path.write_text('// inventoried integration fixture\n')
            with mock.patch.object(run.source_contract, 'ROOTS', ('prototypes/gpui/tests',)), \
                    mock.patch.object(run.source_contract, 'FILES', ()):
                self.assertEqual(run.source_contract.paths(root), [path])

    def test_native_hwnd_stage_cannot_run_on_a_nonwindows_host(self):
        with mock.patch.object(run.platform, 'system', return_value='Linux'):
            with self.assertRaises(ValueError):
                run.verify_interactive_windows()



class StandaloneDependencyTests(unittest.TestCase):
    @contextmanager
    def fixture(self, crate='gpui-component'):
        import tarfile
        with tempfile.TemporaryDirectory(dir=run.REPO / 'build') as directory:
            root = Path(directory)
            component = root / 'prototypes/gpui/vendor' / crate
            component.mkdir(parents=True)
            home = root / 'cargo'
            name = 'gpui-fast-0.1.9'
            source = home / 'registry/src/owned-index' / name
            source.mkdir(parents=True)
            archive = home / 'registry/cache/owned-index' / (name + '.crate')
            archive.parent.mkdir(parents=True)
            files = {'Cargo.toml': b'[package]\nname="gpui-fast"\nversion="0.1.9"\n',
                     'src/gpui.rs': b'pub fn owned_source() {}\n', 'build.rs': b'fn main() {}\n'}
            with tarfile.open(archive, 'w:gz') as packed:
                for relative, data in files.items():
                    path = source / relative
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(data)
                    member = tarfile.TarInfo(name + '/' + relative)
                    member.size = len(data)
                    packed.addfile(member, io.BytesIO(data))
            digest = run.sha(archive)
            (component / 'Cargo.lock').write_text('[[package]]\nname = "gpui-fast"\nversion = "0.1.9"\n'
                'source = "registry+https://github.com/rust-lang/crates.io-index"\nchecksum = "' + digest + '"\n')
            message = {'reason': 'compiler-artifact',
                       'package_id': 'registry+https://github.com/rust-lang/crates.io-index#gpui-fast@0.1.9',
                       'manifest_path': str(source / 'Cargo.toml'),
                       'features': ['test-support', 'windows-manifest-provided-by-host'],
                       'target': {'kind': ['lib'], 'name': 'gpui', 'src_path': str(source / 'src/gpui.rs')},
                       'profile': {'test': False}, 'executable': None}
            with mock.patch.object(run, 'REPO', root):
                command = run.cargo_plan({'manifest': 'prototypes/gpui/vendor/' + crate + '/Cargo.toml',
                    'lib': True, 'features': 'test-support' if crate == 'gpui-base' else 'test-support,tree-sitter,tree-sitter-sql'})
                yield root, source, archive, message, command, {'CARGO_HOME': str(home), 'CARGO_TARGET_DIR': str(root / 'target')}

    def test_exact_base_library_recipe_authenticates_the_same_locked_source(self):
        import copy
        with self.fixture('gpui-base') as (_, _, _, message, command, env):
            accepted = run.verify_cargo_artifact(message, command, env)
            self.assertEqual((accepted['package'], accepted['sourceFiles']), ('gpui-fast', 3))
            for changed in (command + ['--all-features'], command + ['--tests'],
                            [part for part in command if part != '--lib'],
                            [part.replace('test-support', 'test-support,tree-sitter') for part in command],
                            [part.replace('/gpui-base/Cargo.toml', '/gpui-pre/Cargo.toml') for part in command]):
                with self.subTest(command=changed), self.assertRaises(ValueError):
                    run.verify_cargo_artifact(message, changed, env)
            for key, value in (('package_id', message['package_id'].replace('gpui-fast@', 'gpui-pre@')),
                               ('package_id', message['package_id'].replace('0.1.9', '0.1.8')),
                               ('manifest_path', message['manifest_path'].replace('/registry/src/', '/foreign/')),
                               ('profile', {'test': True}), ('executable', '/foreign/test'),
                               ('features', message['features'] + ['product-windows-resources'])):
                changed = copy.deepcopy(message)
                changed[key] = value
                with self.subTest(field=key), self.assertRaises(ValueError):
                    run.verify_cargo_artifact(changed, command, env)

    def test_only_named_compatibility_recipes_with_exact_features_authenticate(self):
        recipes = {'gpui-base': ('element_ext',),
                   'gpui-component': ('base_compat', 'controlled_change_callbacks', 'legacy_button_compat',
                                      'legacy_controls_compat', 'legacy_language_config_compat',
                                      'table_dump_range', 'theme_compat')}
        for crate, targets in recipes.items():
            with self.fixture(crate) as (_, _, _, message, _, env):
                features = 'test-support' if crate == 'gpui-base' else 'test-support,tree-sitter,tree-sitter-sql'
                for target in targets:
                    stage = {'manifest': 'prototypes/gpui/vendor/' + crate + '/Cargo.toml',
                             'testTarget': target, 'features': features}
                    command = run.cargo_plan(stage)
                    with self.subTest(crate=crate, target=target):
                        self.assertIsNotNone(run.verify_cargo_artifact(message, command, env))
                    for changed in (dict(stage, testTarget=target + '_unreviewed'),
                                    dict(stage, features=features + ',unreviewed'),
                                    dict(stage, integrationTests=True), dict(stage, lib=True)):
                        with self.subTest(crate=crate, target=target, variant=changed), self.assertRaises(ValueError):
                            run.verify_cargo_artifact(message, run.cargo_plan(changed), env)
                    for changed in (command + ['--all-features'],
                                    [part.replace('--test', '--example') if part == '--test' else part for part in command]):
                        with self.subTest(command=changed), self.assertRaises(ValueError):
                            run.verify_cargo_artifact(message, changed, env)

    def test_exact_standalone_dependency_does_not_claim_maintained_gpui_or_test_completion(self):
        with self.fixture() as (root, source, archive, message, command, env):
            accepted = run.verify_cargo_artifact(message, command, env)
            self.assertEqual((accepted['package'], accepted['version'], accepted['sourceFiles']), ('gpui-fast', '0.1.9', 3))
            output = (json.dumps(message) + '\n' + json.dumps({'reason': 'build-finished', 'success': True}) + '\n').encode()
            child = mock.Mock(stdout=io.BytesIO(output), pid=12345)
            child.wait.return_value = child.poll.return_value = 0
            with mock.patch.object(subprocess, 'Popen', return_value=child):
                proof = run.collect(command, env, 10, kind='cargo')
            self.assertNotIn('gpui-pre', proof['maintainedDependencies'])
            self.assertEqual(proof['standaloneDevelopmentDependencies']['gpui-fast'], accepted)
            self.assertFalse(proof['completed'], 'A dependency cannot prove a test executable was built.')

    def test_other_package_version_manifest_or_command_cannot_use_host_feature(self):
        import copy
        with self.fixture() as (root, source, archive, message, command, env):
            variants = []
            for key, value in [('package_id', message['package_id'].replace('gpui-fast@', 'gpui-pre@')),
                               ('package_id', message['package_id'].replace('0.1.9', '0.1.8')),
                               ('manifest_path', str(root / 'foreign/Cargo.toml')),
                               ('manifest_path', str(root / 'prototypes/gpui/vendor/gpui-pre/Cargo.toml')),
                               ('profile', {'test': True}), ('executable', str(root / 'candidate'))]:
                changed = copy.deepcopy(message)
                changed[key] = value
                variants.append((changed, command))
            variants += [(message, run.cargo_plan({})), (message, command + ['--all-features']), (message, command[:-1])]
            for index, (changed, invocation) in enumerate(variants):
                with self.subTest(variant=index), self.assertRaises(ValueError):
                    run.verify_cargo_artifact(changed, invocation, env)

    def test_product_feature_is_refused_for_exact_unrelated_dependency(self):
        with self.fixture() as (_, _, _, message, command, env):
            message['features'].append('product-windows-resources')
            with self.assertRaises(ValueError):
                run.verify_cargo_artifact(message, command, env)

    def test_changed_archive_or_source_cannot_use_host_feature(self):
        with self.fixture() as (_, source, archive, message, command, env):
            original = archive.read_bytes()
            archive.write_bytes(original + b'changed')
            with self.assertRaises(ValueError):
                run.verify_cargo_artifact(message, command, env)
            archive.write_bytes(original)
            (source / 'src/gpui.rs').write_bytes(b'changed source')
            with self.assertRaises(ValueError):
                run.verify_cargo_artifact(message, command, env)

    def archive_source_replacement_at_parse(self, in_place, crate):
        import tarfile
        with self.fixture(crate) as (_, source, archive, message, command, env):
            self.assertIsNotNone(run.verify_cargo_artifact(message, command, env))
            locked = hashlib.sha256(archive.read_bytes()).hexdigest()
            original_source = (source / 'src/gpui.rs').read_bytes()
            replacement_source = b'pub fn replaced_source() {}\n'
            replacement = archive.with_suffix('.replacement')
            real_open = tarfile.open
            with real_open(replacement, 'w:gz') as packed:
                for path in sorted(source.rglob('*')):
                    if path.is_file():
                        relative = path.relative_to(source)
                        data = replacement_source if relative == Path('src/gpui.rs') else path.read_bytes()
                        member = tarfile.TarInfo(source.name + '/' + relative.as_posix())
                        member.size = len(data)
                        packed.addfile(member, io.BytesIO(data))
            original_identity = (archive.stat().st_dev, archive.stat().st_ino)
            replaced = False

            def replace_before_parse(*args, **kwargs):
                nonlocal replaced
                self.assertFalse(replaced, 'The guard must parse one archive snapshot.')
                replaced = True
                if in_place:
                    archive.write_bytes(replacement.read_bytes())
                else:
                    os.replace(replacement, archive)
                staged = source / 'src/gpui.replacement'
                staged.write_bytes(replacement_source)
                os.replace(staged, source / 'src/gpui.rs')
                return real_open(*args, **kwargs)

            accepted = None
            with mock.patch.object(tarfile, 'open', side_effect=replace_before_parse) as parse:
                try:
                    accepted = run.verify_cargo_artifact(message, command, env)
                except ValueError:
                    pass
            self.assertTrue(replaced, 'The actual checksum/parse boundary was not exercised.')
            self.assertEqual(parse.call_count, 1)
            self.assertNotEqual(hashlib.sha256(archive.read_bytes()).hexdigest(), locked)
            self.assertNotEqual((source / 'src/gpui.rs').read_bytes(), original_source)
            current_identity = (archive.stat().st_dev, archive.stat().st_ino)
            self.assertEqual(current_identity == original_identity, in_place)
            self.assertIsNone(accepted, 'Replaced archive/source bytes inherited the original locked checksum.')

    def test_atomic_archive_and_source_replacement_at_parse_cannot_inherit_checksum(self):
        for crate in ('gpui-component', 'gpui-base'):
            with self.subTest(crate=crate):
                self.archive_source_replacement_at_parse(in_place=False, crate=crate)

    def test_in_place_archive_and_source_replacement_at_parse_cannot_inherit_checksum(self):
        for crate in ('gpui-component', 'gpui-base'):
            with self.subTest(crate=crate):
                self.archive_source_replacement_at_parse(in_place=True, crate=crate)

    def test_symlink_manifest_is_not_a_registry_source(self):
        with self.fixture() as (_, source, _, message, command, env):
            manifest = source / 'Cargo.toml'
            if os.name == 'nt':
                # Exercise the same refusal without requiring symlink privileges.
                original = Path.is_symlink
                with mock.patch.object(Path, 'is_symlink', lambda path: path == manifest or original(path)):
                    with self.assertRaises(ValueError):
                        run.verify_cargo_artifact(message, command, env)
            else:
                original = source / 'original.toml'
                manifest.rename(original)
                manifest.symlink_to(original.name)
                with self.assertRaises(ValueError):
                    run.verify_cargo_artifact(message, command, env)


class DependencyGraphTests(unittest.TestCase):
    @contextmanager
    def fixture(self):
        with tempfile.TemporaryDirectory(dir=run.REPO / 'build') as directory:
            root = Path(directory)
            verification = root / 'prototypes/gpui/verification'
            verification.mkdir(parents=True)
            root_lock = root / 'prototypes/gpui/Cargo.lock'
            root_lock.write_text('[[package]]\nname = "shared"\nversion = "1.0.0"\n')
            manifests = {'gpui-base': 'vendor/gpui-base', 'gpui-component': 'vendor/gpui-component',
                         'gpui-pre-linux': 'verification/pre-linux-unit'}
            review = {'schemaVersion': 1, 'patches': {crate: 'prototypes/gpui/vendor/' + crate for crate in dependency_inputs.CRATES},
                      'files': {}, 'testsExecuted': False, 'unitGraphs': [], 'publicElementUnit': {'fixture': True}}
            for crate, relative in manifests.items():
                manifest = root / 'prototypes/gpui' / relative / 'Cargo.toml'
                manifest.parent.mkdir(parents=True, exist_ok=True)
                manifest.write_text('[package]\nname = "' + crate + '"\nversion = "1.0.0"\n')
                lock = manifest.with_name('Cargo.lock')
                lock.write_bytes(root_lock.read_bytes())
                review['unitGraphs'].append({'id': crate, 'manifest': manifest.relative_to(root).as_posix(),
                    'manifestSha256': run.sha(manifest), 'lock': lock.relative_to(root).as_posix(),
                    'lockSha256': run.sha(lock), 'graphDelta': dependency_inputs.graph_delta(root_lock, lock)})
            path = verification / 'dependency-inputs.json'
            with mock.patch.object(dependency_inputs, 'source_inputs', return_value={}), \
                    mock.patch.object(dependency_inputs, 'verify_provenance', return_value={}), \
                    mock.patch.object(dependency_inputs, 'public_element_unit', return_value={'fixture': True}):
                yield root, path, review

    def test_exact_three_standalone_graphs_and_public_integration_contract_are_required(self):
        import copy
        with self.fixture() as (root, path, review):
            path.write_text(json.dumps(review))
            dependency_inputs.verify_dependency_review(root)
            variants = []
            for crate in ('gpui-base', 'gpui-component', 'gpui-pre-linux'):
                changed = copy.deepcopy(review)
                changed['unitGraphs'] = [row for row in changed['unitGraphs'] if row['id'] != crate]
                variants.append(changed)
            changed = copy.deepcopy(review)
            changed['unitGraphs'].append(copy.deepcopy(changed['unitGraphs'][0]))
            variants.append(changed)
            changed = copy.deepcopy(review)
            changed['unitGraphs'][0]['id'] = 'unreviewed'
            variants.append(changed)
            changed = copy.deepcopy(review)
            changed['publicElementUnit'] = {'fixture': False}
            variants.append(changed)
            for changed in variants:
                with self.subTest(ids=[row['id'] for row in changed['unitGraphs']]), self.assertRaises(ValueError):
                    path.write_text(json.dumps(changed))
                    dependency_inputs.verify_dependency_review(root)

    def test_pre_graph_cannot_alias_another_manifest_or_accept_lock_drift(self):
        with self.fixture() as (root, path, review):
            pre, base = review['unitGraphs'][:2]
            original = dict(pre)
            pre.update({key: base[key] for key in ('manifest', 'manifestSha256', 'lock', 'lockSha256', 'graphDelta')})
            path.write_text(json.dumps(review))
            with self.assertRaises(ValueError):
                dependency_inputs.verify_dependency_review(root)
            pre.update(original)
            path.write_text(json.dumps(review))
            (root / pre['lock']).write_text('[[package]]\nname = "shared"\nversion = "2.0.0"\n')
            with self.assertRaises(ValueError):
                dependency_inputs.verify_dependency_review(root)

    def test_rebound_pre_graph_still_refuses_same_version_source_checksum_changes(self):
        with self.fixture() as (root, path, review):
            pre = review['unitGraphs'][0]
            lock = root / pre['lock']
            lock.write_text(lock.read_text(encoding='utf-8') + 'source = "registry+https://github.com/rust-lang/crates.io-index"\n'
                            'checksum = "' + 'a' * 64 + '"\n')
            pre['lockSha256'] = run.sha(lock)
            pre['graphDelta'] = dependency_inputs.graph_delta(root / 'prototypes/gpui/Cargo.lock', lock)
            self.assertTrue(pre['graphDelta']['rootKnownSourceOrChecksumChanges'])
            path.write_text(json.dumps(review))
            with self.assertRaises(ValueError):
                dependency_inputs.verify_dependency_review(root)


class PublicElementUnitTests(unittest.TestCase):
    @contextmanager
    def fixture(self):
        with tempfile.TemporaryDirectory(dir=run.REPO / 'build') as directory:
            root = Path(directory)
            for relative in (dependency_inputs.DIV_SOURCE, dependency_inputs.PUBLIC_ELEMENT_SOURCE):
                target = root / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes((run.REPO / relative).read_bytes())
            yield root

    def test_actual_public_writer_adaptation_matches_reviewed_original_unit(self):
        expected = json.loads((run.HERE / 'dependency-inputs.json').read_text(encoding='utf-8'))['publicElementUnit']
        with self.fixture() as root:
            self.assertEqual(dependency_inputs.public_element_unit(root), expected)
            self.assertEqual(expected['testTarget'], 'maintained_pre_disabled')
            self.assertEqual(expected['originalUnit'], 'elements::div::tests::' + dependency_inputs.DISABLED_UNIT)

    def test_changed_assertion_or_private_access_cannot_inherit_original_proof(self):
        with self.fixture() as root:
            path = root / dependency_inputs.PUBLIC_ELEMENT_SOURCE
            original = path.read_text(encoding='utf-8')
            for changed in (original.replace('assert!(node.is_disabled());', 'assert!(!node.is_disabled());'),
                            original.replace('disabled.write_a11y_info', 'disabled.interactivity().write_a11y_info'),
                            original + '\n#[test]\nfn unrelated() {}\n'):
                path.write_text(changed, encoding='utf-8')
                with self.assertRaises(ValueError):
                    dependency_inputs.public_element_unit(root)

    def test_original_unit_body_or_source_drift_requires_new_review(self):
        with self.fixture() as root:
            before = dependency_inputs.public_element_unit(root)
            source = root / dependency_inputs.DIV_SOURCE
            original = source.read_text(encoding='utf-8')
            source.write_text(original + '\n// unreviewed source drift\n', encoding='utf-8')
            self.assertNotEqual(dependency_inputs.public_element_unit(root), before)
            source.write_text(original.replace('assert!(node.is_disabled());', 'assert!(!node.is_disabled());'), encoding='utf-8')
            with self.assertRaises(ValueError):
                dependency_inputs.public_element_unit(root)


if __name__ == '__main__':
    unittest.main(verbosity=2)
