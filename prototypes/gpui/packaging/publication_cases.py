"""Prepared synthetic actual-package-path regressions; never native evidence."""
import argparse
import importlib.util
from pathlib import Path
import struct
import shutil
import tarfile
import tempfile
import unittest
from unittest import mock

HERE = Path(__file__).absolute().parent
spec = importlib.util.spec_from_file_location('dbeer_publication_fixture_package', HERE / 'package.py')
pack = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pack)


class PublicationCases(unittest.TestCase):
    def setUp(self):
        base = pack.ROOT / 'build/gpui/task31-publication-parser-tests'
        base.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix='owned-', dir=base)
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.sources = {}
        def source(name, data=b'owned synthetic source bytes\n'):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            self.sources[name] = path
        source('VERSION', b'1.2.3\n')
        source('BUILD_NUMBER', b'77\n')
        source('prototypes/gpui/Cargo.lock', b'[[package]]\nname="dbeer-gpui"\nversion="1.2.3"\n')
        source('helper/go.mod', b'module synthetic\ngo 1.27.1\n')
        source('helper/go.sum', b'owned synthetic checksum fixture\n')
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
        paths_patch = mock.patch.object(pack, 'source_files', side_effect=lambda: [self.sources[name] for name in sorted(self.sources)])
        root_patch.start(); paths_patch.start()
        self.addCleanup(root_patch.stop); self.addCleanup(paths_patch.stop)
        self.identity = pack.new_identity('linux-x86_64-gnu')
        identity_path = self.root / 'BUILD-IDENTITY.json'
        identity_path.write_bytes(pack.json_bytes(self.identity))
        header = bytearray(64)
        header[:6] = b'\x7fELF\x02\x01'
        struct.pack_into('<H', header, 18, 62)
        gui, helper = self.root / 'gui', self.root / 'helper-binary'
        for binary in (gui, helper):
            binary.write_bytes(header + pack.json_bytes(self.identity)[:-1])
        notices = self.root / 'owned-notices'
        packages, files = [], {}
        for name in ('go-standard-library', 'rust-standard-library'):
            relative = 'runtime/' + name + '-1/LICENSE'
            path = notices / relative
            path.parent.mkdir(parents=True)
            data = ('original synthetic ' + name + ' notice\n').encode()
            path.write_bytes(data)
            files[relative] = pack.sha(data)
            packages.append({'ecosystem': 'runtime', 'name': name, 'version': '1', 'license': 'synthetic',
                             'upstream': 'synthetic-parser-fixture', 'notices': ['LICENSE']})
        self.notice_index = notices / 'INDEX.json'
        self.notice_index.write_bytes(pack.json_bytes({'version': 1,
            'cargoLockSha256': pack.sha(self.sources['prototypes/gpui/Cargo.lock'].read_bytes()),
            'goSumSha256': pack.sha(self.sources['helper/go.sum'].read_bytes()), 'packages': packages, 'files': files}))
        self.args = argparse.Namespace(target='linux-x86_64-gnu', identity=identity_path,
                                       gui=gui, helper=helper, notices=notices, output=self.root / 'build/candidates')
        self.args.output.mkdir(parents=True)
        self.prior = self.args.output / 'prior.candidate'
        self.prior.mkdir()
        (self.prior / 'preserve').write_bytes(b'immutable prior candidate')

    def invoke(self):
        # The actual serializer/archive/publication path runs against owned
        # synthetic bytes. Native executable/store/database inspection never runs.
        with mock.patch.object(pack, 'native'), mock.patch.object(pack, 'reported_build'), \
                mock.patch.object(pack, 'native_dependencies', return_value={'synthetic': True}), mock.patch('builtins.print'):
            pack.package(self.args)

    def assert_refused_before_publication(self):
        self.assertEqual(list(self.args.output.glob('DBeer-*.candidate')), [])
        self.assertEqual((self.prior / 'preserve').read_bytes(), b'immutable prior candidate')
        self.assertEqual(list(self.args.output.glob('*.claim')), [])
        self.assertEqual(list(self.args.output.glob('.dbeer-package-*')), [])

    def test_changed_packaged_document_after_source_capture_refuses_before_candidate(self):
        original = pack.source_snapshot
        def capture(identity):
            result = original(identity)
            self.sources['prototypes/gpui/packaging/RUNTIME.md'].write_bytes(b'changed after captured proof')
            return result
        with mock.patch.object(pack, 'source_snapshot', side_effect=capture), self.assertRaises(pack.Refused):
            self.invoke()
        self.assert_refused_before_publication()

    def test_changed_original_notice_or_index_after_validation_refuses_before_candidate(self):
        original = pack.verify_notices
        legal = self.args.notices / 'runtime/go-standard-library-1/LICENSE'
        original_legal, original_index = legal.read_bytes(), self.notice_index.read_bytes()
        for path in (legal, self.notice_index):
            with self.subTest(input=path.name):
                def verify(directory, snapshot=None):
                    result = original(directory, snapshot)
                    if directory == self.args.notices:
                        path.write_bytes(b'changed original legal input after validation')
                    return result
                with mock.patch.object(pack, 'verify_notices', side_effect=verify), self.assertRaises(pack.Refused):
                    self.invoke()
                self.assert_refused_before_publication()
                legal.write_bytes(original_legal)
                self.notice_index.write_bytes(original_index)

    def test_unchanged_actual_package_path_joins_provenance_legal_manifest_and_archive(self):
        self.invoke()
        candidates = list(self.args.output.glob('DBeer-*.candidate'))
        self.assertEqual(len(candidates), 1)
        archive = next(candidates[0].glob('*.tar.gz'))
        self.assertEqual(archive.with_name(archive.name + '.sha256').read_text().split()[0], pack.sha(archive.read_bytes()))
        with tarfile.open(archive) as value:
            members = {item.name.split('/', 1)[1]: value.extractfile(item).read() for item in value.getmembers()}
        provenance = pack.strict_json(members['SOURCE-PROVENANCE.json'])
        self.assertEqual(provenance, pack.source_provenance(self.identity))
        self.assertEqual(pack.sha(members['RUNTIME.md']), provenance['files']['prototypes/gpui/packaging/RUNTIME.md']['sha256'])
        index = pack.strict_json(members['notices/dependencies/INDEX.json'])
        for name, digest in index['files'].items():
            self.assertEqual(pack.sha(members['notices/dependencies/' + name]), digest)
        manifest = pack.strict_json(members['MANIFEST.json'])
        self.assertEqual(set(manifest['files']), set(members) - {'MANIFEST.json'})
        for name, receipt in manifest['files'].items():
            self.assertEqual(receipt['sha256'], pack.sha(members[name]))
            self.assertEqual(receipt['size'], len(members[name]))
        self.assertEqual((self.prior / 'preserve').read_bytes(), b'immutable prior candidate')

    def test_changed_source_failure_preserves_foreign_replacement_claim_and_stage_entry(self):
        original = pack.source_snapshot
        preserved = {}
        def capture(identity):
            result = original(identity)
            claim = next(self.args.output.glob('*.claim'))
            claim.rename(self.root / 'retained-original-claim')
            claim.write_bytes(b'foreign replacement claim')
            stage = next(self.args.output.glob('.dbeer-package-*'))
            (stage / 'foreign.txt').write_bytes(b'foreign new stage entry')
            preserved.update(claim=claim, stage=stage)
            self.sources['prototypes/gpui/packaging/RUNTIME.md'].write_bytes(b'changed before publication')
            return result
        with mock.patch.object(pack, 'source_snapshot', side_effect=capture), self.assertRaises(pack.Refused):
            self.invoke()
        self.assertEqual(list(self.args.output.glob('DBeer-*.candidate')), [])
        self.assertEqual(preserved['claim'].read_bytes(), b'foreign replacement claim')
        self.assertEqual((preserved['stage'] / 'foreign.txt').read_bytes(), b'foreign new stage entry')
        self.assertEqual((self.prior / 'preserve').read_bytes(), b'immutable prior candidate')

    def test_paired_driver_late_source_change_cannot_publish_before_failed_build_result(self):
        spec = importlib.util.spec_from_file_location('dbeer_publication_fixture_driver', HERE / 'build.py')
        build = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(build)
        original_capture = pack.source_snapshot
        def capture(identity):
            result = original_capture(identity)
            self.sources['prototypes/gpui/packaging/RUNTIME.md'].write_bytes(b'changed in paired package interval')
            return result
        modules = self.root / 'owned-go-modules.json'
        modules.write_bytes(b'{}')
        prepare = mock.Mock(return_value=modules)
        class CacheLoader:
            def create_module(self, spec):
                return None
            def exec_module(self, module):
                module.prepare, module.core = prepare, pack
        cache_spec = importlib.util.spec_from_loader('owned_publication_cache', CacheLoader())
        original_spec = build.importlib.util.spec_from_file_location
        def module_spec(name, path):
            return cache_spec if Path(path).name == 'prepare-go-cache.py' else original_spec(name, path)
        def compile_only(command, environment, *, cwd=None, output=None, phase=None, verification=False):
            if output is not None:
                output.write_bytes(b'{}')
            if command[:2] == ['go', 'build']:
                path = Path(command[command.index('-o') + 1])
            elif command[:2] == ['cargo', 'build']:
                path = Path(environment['CARGO_TARGET_DIR']) / pack.TARGETS[self.args.target] / 'release/dbeer-gpui'
            else:
                return
            header = bytearray(64)
            header[:6] = b'\x7fELF\x02\x01'
            struct.pack_into('<H', header, 18, 62)
            path.write_bytes(header + environment['DBEER_PRODUCT_BUILD_IDENTITY'].encode())
        def collect_notices(args):
            shutil.copytree(self.args.notices, args.output)
        with mock.patch.object(build, 'core', pack), mock.patch.object(build, 'native_toolchains', return_value={}), \
                mock.patch.object(build, 'build_environment', side_effect=lambda root: {'CARGO_TARGET_DIR': str(root / 'target')}), \
                mock.patch.object(build, 'run', side_effect=compile_only), \
                mock.patch.object(build.importlib.util, 'spec_from_file_location', side_effect=module_spec), \
                mock.patch.object(pack, 'native'), mock.patch.object(pack, 'reported_build'), \
                mock.patch.object(pack, 'native_dependencies', return_value={'synthetic': True}), \
                mock.patch.object(pack, 'collect_notices', side_effect=collect_notices), \
                mock.patch.object(pack, 'source_snapshot', side_effect=capture):
            with self.assertRaises(pack.Refused):
                build.execute(argparse.Namespace(target=self.args.target, test=False, package=True))
        prepare.assert_called_once_with()
        self.assertEqual(list((self.root / 'build/gpui/candidates').glob('DBeer-*.candidate')), [])
        self.assertEqual(list((self.root / 'build/gpui/product-builds').rglob('BUILD-RESULT.json')), [])
        self.assertEqual((self.prior / 'preserve').read_bytes(), b'immutable prior candidate')

    def test_stage_cleanup_preserves_unknown_file_and_same_byte_replacement(self):
        for replacement in (False, True):
            stage = self.root / ('stage-' + str(replacement))
            stage.mkdir()
            original = stage.stat()
            owner = pack.StageOwner(stage)
            pack.put(stage, 'owned', b'owned fixture', owner=owner)
            if replacement:
                (stage / 'owned').rename(self.root / 'retained-owned')
                (stage / 'owned').write_bytes(b'owned fixture')
            else:
                (stage / 'foreign').write_bytes(b'preserve foreign fixture')
            pack.owned_cleanup(stage, original, owner.entries)
            self.assertTrue((stage / 'owned').exists())
            if not replacement:
                self.assertEqual((stage / 'foreign').read_bytes(), b'preserve foreign fixture')
