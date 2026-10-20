"""Prepared paired-build safety cases; execute only after all Task 32 source."""
import importlib.util
import json
import os
import re
from pathlib import Path
import shlex
import struct
import tempfile
import unittest
from unittest import mock

HERE = Path(__file__).absolute().parent
spec = importlib.util.spec_from_file_location('dbeer_product_build', HERE / 'build.py')
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)


class PairedBuildCases(unittest.TestCase):
    def setUp(self):
        root = build.core.ROOT / 'build/gpui/task31-build-tests'
        root.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix='owned-', dir=root)
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.identity = json.loads((HERE.parent / 'fixtures/packaging/build-identity.json').read_bytes())

    def test_go_link_parser_receives_exact_canonical_marker_and_shared_version(self):
        values = shlex.split(build.go_link_flags(self.identity), posix=True)
        self.assertEqual(values, ['-X', 'main.productBuildIdentity=' + build.core.json_bytes(self.identity)[:-1].decode(),
                                  '-X', 'main.productVersion=' + self.identity['version'],
                                  '-X', 'main.productBuildNumber=' + self.identity['buildNumber']])

    def test_product_environment_removes_legacy_helper_marker_credentials_and_loader_injection(self):
        with mock.patch.dict(os.environ, {'DBEER_PRODUCT_BUILD_IDENTITY': 'foreign',
                                         'DBEER_GPUI_HELPER_PATH': 'foreign-helper',
                                         'DBEER_TEST_DSN': 'fixture-redacted', 'PGPASSWORD': 'fixture-redacted',
                                         'MYSQL_PWD': 'fixture-redacted', 'LD_PRELOAD': 'foreign',
                                         'DYLD_INSERT_LIBRARIES': 'foreign'}, clear=True):
            environment = build.build_environment(self.root)
        self.assertFalse(any(name.startswith(('DBEER_', 'PG', 'MYSQL', 'LD_', 'DYLD_')) for name in environment))
        self.assertEqual(environment['CARGO_TARGET_DIR'], str(self.root / 'target'))
        self.assertNotIn('verification-target', environment['CARGO_TARGET_DIR'])
        self.assertEqual(environment['GOENV'], 'off')
        for name in ['TMPDIR', 'TMP', 'TEMP', 'GOTMPDIR']:
            self.assertEqual(environment[name], str(self.root / 'tmp'))

    def test_compiler_linker_wrappers_cannot_change_a_product_build(self):
        for name in ['RUSTFLAGS', 'CARGO_ENCODED_RUSTFLAGS', 'RUSTC_WRAPPER', 'GOFLAGS',
                     'CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_LINKER', 'CARGO_BUILD_RUSTFLAGS', 'LDFLAGS']:
            with self.subTest(name=name), mock.patch.dict(os.environ, {name: 'injected'}, clear=True):
                with self.assertRaises(build.Refused):
                    build.build_environment(self.root)

    def test_untracked_cargo_cache_configuration_cannot_change_a_product_build(self):
        configuration = self.root / 'build/gpui/cargo/config.toml'
        configuration.parent.mkdir(parents=True)
        configuration.write_text('[build]\nrustflags = ["owned-fixture-override"]\n')
        with mock.patch.object(build.core, 'ROOT', self.root), mock.patch.dict(os.environ, {}, clear=True):
            with self.assertRaises(build.Refused):
                build.build_environment(self.root)

    def test_source_identity_covers_every_literal_embedded_rust_input(self):
        inputs = set(build.core.source_files())
        for source in (HERE.parent / 'src').rglob('*.rs'):
            text = source.read_text()
            for relative in re.findall(r'include_(?:str|bytes)!\(\s*"([^"\n]+)"', text):
                embedded = (source.parent / relative).resolve()
                with self.subTest(source=source.name, embedded=relative):
                    self.assertIn(embedded, inputs)
        self.assertFalse(any('build' in path.relative_to(build.core.ROOT).parts
                             or any(name in {'.git', '.cache', 'target', '__pycache__'} for name in path.parts)
                             for path in inputs))

    def test_go_cache_preparation_allows_extra_sums_only_in_its_private_module_copy(self):
        spec = importlib.util.spec_from_file_location('dbeer_cache_preparation', HERE / 'prepare-go-cache.py')
        preparation = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(preparation)
        helper = self.root / 'helper'
        helper.mkdir()
        original = {'go.mod': b'module owned-fixture\ngo 1.27.1\n', 'go.sum': b'owned original checksum fixture\n'}
        for name, data in original.items():
            (helper / name).write_bytes(data)
        def download(command, **kwargs):
            alternate = Path(next(argument.split('=', 1)[1] for argument in command
                                  if argument.startswith('-modfile=')))
            self.assertNotEqual(alternate, helper / 'go.mod')
            alternate.with_suffix('.sum').write_bytes(b'owned additional cache checksums\n')
            if command[1] == 'list':
                kwargs['stdout'].write(b'{"Main":true,"Path":"owned-fixture"}')
            return type('Completed', (), {'returncode': 0})()
        with mock.patch.object(preparation.core, 'ROOT', self.root), \
                mock.patch.object(preparation.subprocess, 'run', side_effect=download), \
                mock.patch('builtins.print'):
            preparation.main()
        for name, data in original.items():
            self.assertEqual((helper / name).read_bytes(), data)

    def test_source_change_refuses_between_gui_and_helper(self):
        with mock.patch.object(build.core, 'new_identity', return_value=dict(self.identity, sourceSha256='b' * 64)):
            with self.assertRaises(build.Refused):
                build.assert_frozen(self.identity)

    def test_static_pair_validation_never_launches_old_or_unmarked_binaries(self):
        elf = bytearray(64)
        elf[:6] = b'\x7fELF\x02\x01'
        struct.pack_into('<H', elf, 18, 62)
        gui, helper = self.root / 'dbeer-gpui', self.root / 'dbeer-core'
        gui.write_bytes(elf + build.core.json_bytes(self.identity)[:-1])
        helper.write_bytes(elf)
        with mock.patch.object(build.subprocess, 'run') as process:
            with self.assertRaises(build.Refused):
                build.verify_pair(gui, helper, self.identity)
            process.assert_not_called()

    def test_native_rust_and_go_hosts_must_both_match_exact_target(self):
        for rust, go in [('aarch64-unknown-linux-gnu', ('linux', 'amd64', '')),
                         ('x86_64-unknown-linux-gnu', ('linux', 'arm64', '')),
                         ('x86_64-unknown-linux-gnu', ('linux', 'amd64', '-race'))]:
            outputs = [f'host: {rust}\n'.encode(), build.core.json_bytes(dict(zip(['GOHOSTOS', 'GOHOSTARCH', 'GOFLAGS'], go)))]
            with self.subTest(rust=rust, go=go), mock.patch.object(build.core, 'checked_output', side_effect=outputs):
                with self.assertRaises(build.Refused):
                    build.native_toolchains('linux-x86_64-gnu', {})


if __name__ == '__main__':
    unittest.main()
