"""Prepared packaging/ownership cases. Execute only at final integration after Task 32 code."""
import argparse
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import struct
import tarfile
import tempfile
import unittest
from unittest import mock
import zipfile

HERE = Path(__file__).absolute().parent


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


pack = module('dbeer_package', HERE / 'package.py')
integration = module('dbeer_integration', HERE / 'linux/integrate-linux.py')


class OwnedFixture(unittest.TestCase):
    def setUp(self):
        root = pack.ROOT / 'build/gpui/task31-packaging-tests'
        root.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix='owned-', dir=root)
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.identity = json.loads((HERE.parent / 'fixtures/packaging/build-identity.json').read_bytes())

    def write(self, name, data=b'fixture'):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path


class MetadataCases(OwnedFixture):
    def test_ubuntu_system_release_link_is_resolved_without_relaxing_package_inputs(self):
        release = self.write('usr/lib/os-release', b'ID=ubuntu\nVERSION_ID="24.04"\n')
        link = self.root / 'etc/os-release'
        link.parent.mkdir()
        try:
            link.symlink_to('../usr/lib/os-release')
        except OSError:
            self.skipTest('Standard-user symlink fixture unavailable.')
        with mock.patch.object(pack.platform, 'machine', return_value='x86_64'), \
                mock.patch.object(pack.sys, 'platform', 'linux'), \
                mock.patch.dict(os.environ, {}, clear=True), \
                mock.patch.object(pack, 'LINUX_OS_RELEASE', link):
            pack.native('linux-x86_64-gnu')
            release.write_bytes(b'ID=ubuntu\nVERSION_ID="26.04"\n')
            with self.assertRaises(pack.Refused):
                pack.native('linux-x86_64-gnu')
        with self.assertRaises(pack.Refused):
            pack.safe(link)

    def test_build_identity_file_requires_exact_canonical_sorted_ascii_and_one_lf(self):
        canonical = pack.json_bytes(self.identity)
        self.assertEqual(pack.canonical_identity(canonical, 'linux-x86_64-gnu'), self.identity)
        for data in [canonical[:-1], canonical + b'\n', b' ' + canonical,
                     json.dumps(self.identity, indent=2).encode() + b'\n']:
            with self.subTest(length=len(data)), self.assertRaises(pack.Refused):
                pack.canonical_identity(data, 'linux-x86_64-gnu')

    def test_owned_build_info_output_is_capped_before_parsing(self):
        class CountingStream(io.BytesIO):
            count = 0
            def read1(self, size=-1):
                value = super().read1(size)
                self.count += len(value)
                return value
        stream = CountingStream(b'x'*100_000)
        process = mock.Mock(stdout=stream)
        process.poll.return_value = 0
        process.wait.return_value = 0
        with mock.patch.object(pack.subprocess, 'Popen', return_value=process) as spawn:
            with self.assertRaises(pack.Refused):
                pack.checked_output(['owned-exact-child', '--build-info'], limit=8192, timeout=1)
        self.assertLessEqual(stream.count, 8193)
        self.assertIs(spawn.call_args.kwargs['stdin'], pack.subprocess.DEVNULL)
        self.assertIs(spawn.call_args.kwargs['stderr'], pack.subprocess.DEVNULL)

    def test_strict_schema_duplicate_version_target_capability_and_unknown_fields(self):
        for field, value in [('schemaVersion', True), ('protocolVersion', True), ('buildNumber', '01'),
                             ('productId', 'foreign.application'), ('contractRevision', 'old-v3'),
                             ('capabilities', []), ('sourceSha256', 'a'*63), ('version', '../1')]:
            with self.subTest(field=field):
                identity = dict(self.identity, **{field: value})
                with self.assertRaises(pack.Refused):
                    pack.validate_identity(identity, 'linux-x86_64-gnu')
        for invalid in [dict(self.identity, extra='unsupported'), dict(self.identity, target='linux-arm64-gnu')]:
            with self.assertRaises(pack.Refused):
                pack.validate_identity(invalid, 'linux-x86_64-gnu')
        with self.assertRaises(pack.Refused):
            pack.strict_json(b'{"version":1,"version":1}')

    def test_exact_gui_helper_report_and_missing_old_build_semantics(self):
        path = self.write('exact gui')
        complete = {'component': 'gui', 'identity': self.identity}
        def response(value):
            return pack.json_bytes(value)
        with mock.patch.object(pack, 'checked_output', return_value=response(complete)) as run:
            pack.reported_build(path, 'gui', self.identity)
            self.assertEqual(run.call_args.args[0], [str(path), '--build-info'])
            self.assertEqual(run.call_args.kwargs['limit'], 8192)
            self.assertEqual(run.call_args.kwargs['timeout'], 10)
        for value in [{'component': 'helper', 'identity': self.identity}, {'component': 'gui'},
                      {'component': 'gui', 'identity': dict(self.identity, buildNumber='2')}]:
            with mock.patch.object(pack, 'checked_output', return_value=response(value)):
                with self.assertRaises(pack.Refused):
                    pack.reported_build(path, 'gui', self.identity)

    def test_native_import_inventory_rejects_newer_glibc_and_records_actual_imports(self):
        for text in [b'Name: GLIBC_2.40', b'Name: GLIBC_2.39.1']:
            with mock.patch.object(pack, 'checked_output', return_value=text):
                with self.assertRaises(pack.Refused):
                    pack.native_dependencies(self.root / 'gui', 'linux-x86_64-gnu')
        text = b'(NEEDED) Shared library: [libfontconfig.so.1]\nName: GLIBC_2.39\n'
        with mock.patch.object(pack, 'checked_output', return_value=text):
            value = pack.native_dependencies(self.root / 'gui', 'linux-x86_64-gnu')
            self.assertEqual(value['needed'], ['libfontconfig.so.1'])
            self.assertEqual(value['glibcVersions'], ['2.39'])
        with mock.patch.object(pack, 'checked_output', return_value=b'    VCRUNTIME140.dll\n    KERNEL32.dll\n'):
            self.assertEqual(pack.native_dependencies(self.root / 'gui.exe', 'windows-x86_64-msvc')['imports'], ['kernel32.dll', 'vcruntime140.dll'])

    def test_platform_builds_refuse_mac_arm_cross_environment_and_other_ubuntu(self):
        with mock.patch.dict(os.environ, {'GOARCH': 'amd64'}):
            with self.assertRaises(pack.Refused):
                pack.native('linux-x86_64-gnu')
        with mock.patch.object(pack.platform, 'machine', return_value='arm64'):
            with self.assertRaises(pack.Refused):
                pack.native('linux-x86_64-gnu')
        with mock.patch.object(pack.platform, 'machine', return_value='x86_64'), mock.patch.object(pack.sys, 'platform', 'darwin'):
            with self.assertRaises(pack.Refused):
                pack.native('linux-x86_64-gnu')
        with mock.patch.object(pack.platform, 'machine', return_value='x86_64'), mock.patch.object(pack.sys, 'platform', 'linux'), mock.patch.dict(os.environ, {}, clear=True), mock.patch.object(pack, 'bounded', return_value=b'ID=ubuntu\nVERSION_ID="26.04"\n'):
            with self.assertRaises(pack.Refused):
                pack.native('linux-x86_64-gnu')


class ArchiveCases(OwnedFixture):
    def test_path_sanitization_uses_shared_bad_name_fixture(self):
        fixture = json.loads((HERE.parent / 'fixtures/packaging/cases.json').read_bytes())
        for name in fixture['rejectArchiveNames']:
            with self.subTest(name=repr(name)), self.assertRaises(pack.Refused):
                pack.archive_name(name)
        self.assertEqual(pack.archive_name('DBeer/themes/dbeer-light.json'), 'DBeer/themes/dbeer-light.json')

    def test_binary_headers_reject_architecture_os_and_truncation(self):
        elf = bytearray(64)
        elf[:6] = b'\x7fELF\x02\x01'
        struct.pack_into('<H', elf, 18, 62)
        path = self.write('gui', elf)
        self.assertEqual(pack.binary_header(path, 'linux-x86_64-gnu'), elf)
        elf[18] = 183
        path.write_bytes(elf)
        with self.assertRaises(pack.Refused):
            pack.binary_header(path, 'linux-x86_64-gnu')
        with self.assertRaises(pack.Refused):
            pack.binary_header(path, 'windows-x86_64-msvc')
        path.write_bytes(b'MZ')
        with self.assertRaises(pack.Refused):
            pack.binary_header(path, 'windows-x86_64-msvc')

    def test_symlink_input_and_symlink_parent_refuse_without_touching_target(self):
        if not hasattr(os, 'symlink'):
            self.skipTest('Platform cannot create the fixture symlink.')
        original = self.write('outside', b'preserve')
        link = self.root / 'input-link'
        try:
            link.symlink_to(original)
        except OSError:
            self.skipTest('Standard-user symlink fixture unavailable; native junction coverage remains required.')
        with self.assertRaises(pack.Refused):
            pack.bounded(link)
        self.assertEqual(original.read_bytes(), b'preserve')

    def test_tar_and_zip_contents_checksums_modes_and_bytes_are_deterministic(self):
        content = self.root / 'content'
        pack.put(content, 'dbeer-gpui', b'gui', 0o755)
        pack.put(content, 'themes/theme.json', b'{}')
        for target, suffix in [('linux-x86_64-gnu', '.tar.gz'), ('windows-x86_64-msvc', '.zip')]:
            paths = [self.root / ('first'+suffix), self.root / ('second'+suffix)]
            for path in paths:
                pack.write_archive(path, content, 'DBeer-fixture', target)
            self.assertEqual(paths[0].read_bytes(), paths[1].read_bytes())
            self.assertEqual(pack.sha(paths[0].read_bytes()), pack.sha(paths[1].read_bytes()))
            if suffix == '.zip':
                with zipfile.ZipFile(paths[0]) as archive:
                    self.assertEqual(archive.namelist(), ['DBeer-fixture/dbeer-gpui', 'DBeer-fixture/themes/theme.json'])
                    self.assertEqual((archive.getinfo('DBeer-fixture/dbeer-gpui').external_attr >> 16) & 0o777, 0o755)
            else:
                with tarfile.open(paths[0]) as archive:
                    entries = archive.getmembers()
                    self.assertEqual([entry.name for entry in entries], ['DBeer-fixture/dbeer-gpui', 'DBeer-fixture/themes/theme.json'])
                    self.assertEqual([(entry.uid, entry.gid, entry.mtime) for entry in entries], [(0, 0, 0), (0, 0, 0)])
                    self.assertEqual([entry.mode for entry in entries], [0o755, 0o644])

    def test_atomic_publication_never_overwrites_even_an_empty_directory(self):
        source, existing = self.root / 'source', self.root / 'existing'
        source.mkdir()
        existing.mkdir()
        with self.assertRaises((pack.Refused, OSError)):
            pack.publish_directory(source, existing)
        self.assertTrue(source.is_dir())
        self.assertEqual(list(existing.iterdir()), [])

    def test_owned_cleanup_preserves_a_replacement_and_unrelated_directory(self):
        stage = self.root / 'stage'
        stage.mkdir()
        identity = stage.stat()
        stage.rename(self.root / 'original-stage')
        stage.mkdir()
        (stage / 'foreign').write_bytes(b'preserve')
        pack.owned_cleanup(stage, identity)
        self.assertEqual((stage / 'foreign').read_bytes(), b'preserve')

    @unittest.skipUnless(os.name != 'nt', 'Unix private-mode assertion; native Windows ACL acceptance is separate.')
    def test_private_staging_and_metadata_modes(self):
        private = Path(tempfile.mkdtemp(dir=self.root))
        self.assertEqual(stat.S_IMODE(private.stat().st_mode), 0o700)
        pack.put(private, 'BUILD-IDENTITY.json', pack.json_bytes(self.identity), 0o600)
        self.assertEqual(stat.S_IMODE((private/'BUILD-IDENTITY.json').stat().st_mode), 0o600)

    def test_stale_dependency_notices_are_rejected(self):
        root = self.root / 'notices'
        root.mkdir()
        (root/'INDEX.json').write_bytes(pack.json_bytes({'version': 1, 'cargoLockSha256': 'a'*64,
                                                       'goSumSha256': 'b'*64, 'packages': [], 'files': {}}))
        with self.assertRaises(pack.Refused):
            pack.verify_notices(root)

    def test_pinned_original_workspace_notices_require_exact_archive_manifest_vcs_and_bytes(self):
        root = self.root
        source = root / 'registry/owned-fixture-1.0.0'
        source.mkdir(parents=True)
        manifest = b'[package]\nname = "owned-fixture"\nversion = "1.0.0"\nlicense = "MIT"\n'
        vcs = pack.json_bytes({'git': {'sha1': 'b' * 40}, 'path_in_vcs': 'fixture'})
        (source / 'Cargo.toml').write_bytes(manifest)
        (source / '.cargo_vcs_info.json').write_bytes(vcs)
        original = b'owned synthetic original permission fixture\n'
        notice = self.write('prototypes/gpui/packaging/notices/upstream/texts/fixture/LICENSE', original)
        self.write('prototypes/gpui/Cargo.lock',
                   b'[[package]]\nname = "owned-fixture"\nversion = "1.0.0"\nchecksum = "' + b'a' * 64 + b'"\n')
        entry = {'name': 'owned-fixture', 'version': '1.0.0', 'archiveSha256': 'a' * 64,
                 'manifestSha256': pack.sha(manifest), 'vcsInfoSha256': pack.sha(vcs),
                 'revision': 'b' * 40, 'notices': [{'path': 'texts/fixture/LICENSE',
                 'sha256': pack.sha(original), 'upstreamUrl': 'https://example.invalid/' + 'b' * 40 + '/LICENSE'}]}
        catalog = root / 'prototypes/gpui/packaging/notices/upstream/INDEX.json'
        def save():
            catalog.write_bytes(pack.json_bytes({'schemaVersion': 1, 'packages': [entry]}))
        save()
        value = {'name': 'owned-fixture', 'version': '1.0.0', 'license': 'MIT'}
        with mock.patch.object(pack, 'ROOT', root):
            _, files = pack.pinned_rust_notices(value, source)
            self.assertEqual(files[0][1], original)
            for field in ['archiveSha256', 'manifestSha256', 'vcsInfoSha256']:
                expected = entry[field]
                entry[field] = 'c' * 64
                save()
                with self.subTest(field=field), self.assertRaises(pack.Refused):
                    pack.pinned_rust_notices(value, source)
                entry[field] = expected
            save()
            notice.write_bytes(b'changed synthetic legal bytes')
            with self.assertRaises(pack.Refused):
                pack.pinned_rust_notices(value, source)
            notice.write_bytes(original)
            publisher = self.write('prototypes/gpui/packaging/notices/upstream/texts/fixture/NOTICE-Cargo.toml', manifest)
            terms = b'owned synthetic official-term fixture\n'
            self.write('prototypes/gpui/packaging/notices/upstream/texts/fixture/LICENSE-MIT', terms)
            entry['notices'] += [
                {'path': 'texts/fixture/NOTICE-Cargo.toml', 'sha256': pack.sha(manifest),
                 'upstreamUrl': 'https://static.crates.io/crates/owned-fixture/owned-fixture-1.0.0.crate'},
                {'path': 'texts/fixture/LICENSE-MIT', 'sha256': pack.sha(terms),
                 'upstreamUrl': 'https://raw.githubusercontent.com/spdx/license-list-data/' + 'd' * 40 + '/text/MIT.txt',
                 'declaredBy': {'path': 'texts/fixture/NOTICE-Cargo.toml', 'sha256': pack.sha(manifest),
                                'licenseExpression': 'MIT', 'licenseId': 'MIT',
                                'referenceUrl': 'https://doc.rust-lang.org/cargo/reference/manifest.html'}}]
            save()
            self.assertEqual(len(pack.pinned_rust_notices(value, source)[1]), 3)
            entry['notices'][-1]['declaredBy']['licenseId'] = 'Apache-2.0'
            save()
            with self.assertRaises(pack.Refused):
                pack.pinned_rust_notices(value, source)
            entry['notices'][-1]['declaredBy']['licenseId'] = 'MIT'
            save()
            publisher.write_bytes(b'changed synthetic publisher declaration')
            with self.assertRaises(pack.Refused):
                pack.pinned_rust_notices(value, source)

    def test_standard_library_notices_require_original_toolchain_files(self):
        rust = self.root / 'rust-toolchain'
        go = self.root / 'go-toolchain'
        go.mkdir()
        self.write('rust-toolchain/share/doc/rust/COPYRIGHT-library.html', b'owned original-runtime fixture')
        self.write('rust-toolchain/share/doc/rust/licenses/MIT.txt', b'owned original-license fixture')
        self.write('go-toolchain/PATENTS', b'owned original-patents fixture')
        responses = [b'host: x86_64-unknown-linux-gnu\nrelease: 1.99.1\n',
                     (str(rust) + '\n').encode(), pack.json_bytes({'GOROOT': str(go), 'GOVERSION': 'go1.27.1'})]
        stage = self.root / 'runtime-notices'
        stage.mkdir()
        with mock.patch.object(pack, 'checked_output', side_effect=responses):
            with self.assertRaises(pack.Refused):
                pack.collect_runtime_notices(stage, {})
        self.assertFalse((stage / 'runtime/go-standard-library-go1.27.1/LICENSE').exists())

    def test_packaging_refuses_old_metadata_before_executing_either_input(self):
        path = self.write('identity.json', pack.json_bytes(self.identity))
        args = argparse.Namespace(target='linux-x86_64-gnu', identity=path, gui=self.root/'gui', helper=self.root/'helper', notices=self.root/'notices', output=self.root/'output')
        with mock.patch.object(pack, 'native'), mock.patch.object(pack, 'new_identity', return_value=dict(self.identity, sourceSha256='b'*64)), mock.patch.object(pack, 'reported_build') as report:
            with self.assertRaises(pack.Refused):
                pack.package(args)
            report.assert_not_called()
        self.assertFalse((self.root/'output').exists())

    def prepared_package(self):
        sources = {}
        def source(name, data=b'owned synthetic reviewed source\n'):
            sources[name] = self.write(name, data)
        source('VERSION', b'0.2.0\n')
        source('BUILD_NUMBER', b'1\n')
        for name in ('CHANGELOG.md', 'macos/Resources/AppIcon.svg', 'macos/Resources/AppIcon.png',
                     'prototypes/gpui/packaging/INSTALL.md', 'prototypes/gpui/packaging/RUNTIME.md',
                     'prototypes/gpui/packaging/notices/NOTICES.md',
                     'prototypes/gpui/packaging/linux/integrate-linux.py',
                     'prototypes/gpui/packaging/notices/upstream/INDEX.json'):
            source(name)
        for name in pack.THEMES:
            source('prototypes/gpui/assets/themes/' + name)
        for vendor in ('gpui-pre-linux', 'gpui-pre', 'gpui-component', 'gpui-base'):
            names = ['LICENSE-APACHE', 'README.md'] if vendor == 'gpui-pre-linux' else [
                'LICENSE-APACHE', 'DBEER-PATCH.md', 'UPSTREAM.sha256', 'LOCAL-CHANGES.json']
            if vendor == 'gpui-pre':
                names.append('README.md')
            elif vendor != 'gpui-pre-linux':
                names.append('.cargo_vcs_info.json')
            if vendor == 'gpui-component':
                names.append('LICENSE-LUCIDE')
            for name in names:
                source('prototypes/gpui/vendor/' + vendor + '/' + name)
        root_patch = mock.patch.object(pack, 'ROOT', self.root)
        paths_patch = mock.patch.object(pack, 'source_files', side_effect=lambda: [sources[name] for name in sorted(sources)])
        root_patch.start()
        self.addCleanup(root_patch.stop)
        paths_patch.start()
        self.addCleanup(paths_patch.stop)
        self.identity = pack.new_identity('linux-x86_64-gnu')
        elf = bytearray(64)
        elf[:6] = b'\x7fELF\x02\x01'
        struct.pack_into('<H', elf, 18, 62)
        marker = pack.json_bytes(self.identity).strip()
        gui = self.write('inputs/gui', elf + b'gui-fixture'+marker)
        helper = self.write('inputs/helper', elf + b'helper-fixture'+marker)
        identity = self.write('inputs/identity.json', pack.json_bytes(self.identity))
        notices = self.root / 'inputs/notices'
        notices.mkdir()
        self.write('inputs/notices/LICENSE-fixture', b'owned synthetic license fixture')
        return argparse.Namespace(target='linux-x86_64-gnu', identity=identity, gui=gui, helper=helper,
                                  notices=notices, output=self.root/'build/output')

    def test_archive_bundle_manifest_checksum_and_no_overwrite(self):
        args = self.prepared_package()
        with mock.patch.object(pack, 'native'), mock.patch.object(pack, 'reported_build'), mock.patch.object(pack, 'native_dependencies', return_value={'needed': []}), mock.patch.object(pack, 'verify_notices'), mock.patch('builtins.print'):
            pack.package(args)
            bundle = next(args.output.glob('*.candidate'))
            archive = next(bundle.glob('*.tar.gz'))
            original = archive.read_bytes()
            expected = pack.sha(original) + '  ' + archive.name + '\n'
            self.assertEqual(Path(str(archive)+'.sha256').read_text(), expected)
            with tarfile.open(archive) as opened:
                name = opened.getnames()[0].split('/')[0]
                manifest = json.load(opened.extractfile(name+'/MANIFEST.json'))
                provenance = json.load(opened.extractfile(name+'/SOURCE-PROVENANCE.json'))
                self.assertEqual(manifest['status'], 'unsigned-development-candidate')
                self.assertEqual(manifest['identity'], self.identity)
                self.assertEqual(provenance, pack.source_snapshot(self.identity)[0])
                for relative, facts in manifest['files'].items():
                    data = opened.extractfile(name+'/'+relative).read()
                    self.assertEqual(pack.sha(data), facts['sha256'])
                    self.assertEqual(len(data), facts['size'])
                for filename in pack.THEMES:
                    self.assertIn('themes/'+filename, manifest['files'])
            with self.assertRaises(pack.Refused):
                pack.package(args)
            self.assertEqual(archive.read_bytes(), original)
            self.assertFalse(list(args.output.glob('.dbeer-package-*')))
            self.assertFalse(list(args.output.glob('*.claim')))

    def test_an_old_binary_is_not_launched_to_probe_an_unknown_flag(self):
        args = self.prepared_package()
        args.gui.write_bytes(args.gui.read_bytes()[:64])
        with mock.patch.object(pack, 'native'), mock.patch.object(pack, 'reported_build') as report:
            with self.assertRaises(pack.Refused):
                pack.package(args)
            report.assert_not_called()
        self.assertFalse(args.output.exists())

    def test_stale_claim_is_preserved_and_publication_failure_cleans_owned_stage(self):
        args = self.prepared_package()
        args.output.mkdir(parents=True)
        claim = args.output/'DBeer-0.2.0-1-linux-x86_64.claim'
        claim.write_bytes(b'pre-existing claim; no PID inference')
        with mock.patch.object(pack, 'native'), mock.patch.object(pack, 'reported_build'), mock.patch.object(pack, 'native_dependencies', return_value={'needed': []}), mock.patch.object(pack, 'verify_notices'):
            with self.assertRaises(FileExistsError):
                pack.package(args)
            self.assertEqual(claim.read_bytes(), b'pre-existing claim; no PID inference')
            # Only this test owns that exact prior fixture; product code never
            # deletes a stale claim to force packaging.
            claim.unlink()
            with mock.patch.object(pack, 'publish_directory', side_effect=pack.Refused('injected fixture failure')):
                with self.assertRaises(pack.Refused):
                    pack.package(args)
            self.assertEqual(list(args.output.iterdir()), [])


class DesktopIntegrationCases(OwnedFixture):
    def setUp(self):
        super().setUp()
        self.package = self.root / 'package with spaces % and Unicode-\u03bb'
        self.package.mkdir()
        self.gui = self.package / 'dbeer-gpui'
        self.gui.write_bytes(b'not executed')
        (self.package/'icons').mkdir()
        (self.package/'icons'/f'{integration.APP_ID}.svg').write_bytes(b'<svg/>')
        self.data = self.root / 'per-user data'

    def test_exec_quoting_roundtrips_desktop_then_exec_escaping(self):
        # https://specifications.freedesktop.org/desktop-entry/latest/exec-variables.html
        # Decode the string layer, then the four Exec quoted escapes, then %%.
        for path in ('/home/fixture/App "quoted" \\ $literal `literal` 100% \u03bb/dbeer-gpui',
                     '/home/fixture/single\'quote ;&|<>~*?#() and %%/dbeer-gpui',
                     '/home/fixture/trailing\\', '/home/fixture/"',
                     '/home/fixture/$', '/home/fixture/`'):
            with self.subTest(path=path):
                encoded = integration.desktop_exec(path)
                decoded, index = '', 0
                escapes = {'s': ' ', 'n': '\n', 't': '\t', 'r': '\r', '\\': '\\'}
                while index < len(encoded):
                    if encoded[index] == '\\':
                        index += 1
                        self.assertLess(index, len(encoded))
                        self.assertIn(encoded[index], escapes)
                        decoded += escapes[encoded[index]]
                    else:
                        decoded += encoded[index]
                    index += 1
                self.assertTrue(decoded.startswith('"') and decoded.endswith('"'))
                argument, index = '', 1
                while index < len(decoded) - 1:
                    character = decoded[index]
                    if character == '\\':
                        index += 1
                        self.assertLess(index, len(decoded) - 1)
                        self.assertIn(decoded[index], '\\"$`')
                        character = decoded[index]
                    else:
                        self.assertNotIn(character, '"$`', 'Quoted special characters must be escaped.')
                    argument += character
                    index += 1
                literal, index = '', 0
                while index < len(argument):
                    if argument[index] == '%':
                        self.assertEqual(argument[index:index + 2], '%%')
                        index += 1
                    literal += argument[index]
                    index += 1
                self.assertEqual(literal, path)
        for bad in ['path\nargument', 'path\0argument', 'path\rargument']:
            with self.assertRaises(integration.Refused):
                integration.desktop_exec(bad)

    def test_standard_user_install_remove_preserves_package_and_private_data(self):
        private = self.write('legacy-data/workspace.json', b'opaque private fixture')
        integration.install(self.package, self.data)
        paths = integration.paths_for(self.data)
        self.assertIn(integration.desktop_exec(self.gui).encode(), paths['desktop'].read_bytes())
        integration.remove(self.data)
        self.assertFalse(any(path.exists() for path in paths.values()))
        self.assertTrue(self.gui.exists())
        self.assertEqual(private.read_bytes(), b'opaque private fixture')

    def test_install_collision_never_overwrites_foreign_desktop_file(self):
        paths = integration.paths_for(self.data)
        paths['desktop'].parent.mkdir(parents=True)
        paths['desktop'].write_bytes(b'foreign application')
        with self.assertRaises(integration.Refused):
            integration.install(self.package, self.data)
        self.assertEqual(paths['desktop'].read_bytes(), b'foreign application')
        self.assertFalse(paths['manifest'].exists())

    def test_remove_changed_icon_refuses_before_any_delete(self):
        integration.install(self.package, self.data)
        paths = integration.paths_for(self.data)
        paths['icon'].write_bytes(b'changed by user')
        with self.assertRaises(integration.Refused):
            integration.remove(self.data)
        self.assertTrue(paths['desktop'].exists())
        self.assertTrue(paths['manifest'].exists())
        self.assertEqual(paths['icon'].read_bytes(), b'changed by user')

    def test_same_bytes_replacement_is_not_the_owned_installed_file(self):
        integration.install(self.package, self.data)
        paths = integration.paths_for(self.data)
        original = paths['icon'].read_bytes()
        paths['icon'].rename(self.root/'retained-original-icon')
        paths['icon'].write_bytes(original)
        with self.assertRaises(integration.Refused):
            integration.remove(self.data)
        self.assertTrue(paths['desktop'].exists())
        self.assertTrue(paths['manifest'].exists())
        self.assertEqual(paths['icon'].read_bytes(), original)

    def test_install_failure_cleans_only_owned_partial_files(self):
        original = integration.owned_create
        def fail_manifest(path, data, mode):
            if path.name.endswith('.json'):
                raise OSError('injected owned fixture failure')
            return original(path, data, mode)
        with mock.patch.object(integration, 'owned_create', side_effect=fail_manifest):
            with self.assertRaises(OSError):
                integration.install(self.package, self.data)
        self.assertFalse(any(path.exists() for path in integration.paths_for(self.data).values()))
        self.assertTrue(self.gui.exists())

    def test_failed_install_cleanup_preserves_a_foreign_replacement(self):
        original = integration.owned_create
        def fail_manifest(path, data, mode):
            if path.name.endswith('.json'):
                icon = integration.paths_for(self.data)['icon']
                icon.rename(self.root/'retained-owned-icon')
                icon.write_bytes(b'foreign replacement')
                raise OSError('injected fixture failure')
            return original(path, data, mode)
        with mock.patch.object(integration, 'owned_create', side_effect=fail_manifest):
            with self.assertRaises(OSError):
                integration.install(self.package, self.data)
        self.assertEqual(integration.paths_for(self.data)['icon'].read_bytes(), b'foreign replacement')
        self.assertFalse(integration.paths_for(self.data)['desktop'].exists())


# Include actual-package-path synthetic regressions in the supported suite.
from publication_cases import PublicationCases


if __name__ == '__main__':
    unittest.main()
