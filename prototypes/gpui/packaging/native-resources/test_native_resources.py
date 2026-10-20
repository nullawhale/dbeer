"""Prepared cases only. Run after Tasks 30-32 implementation is integrated."""
import importlib.util
import json
import os
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest import mock
import xml.etree.ElementTree as ET

HERE = Path(__file__).absolute().parent
spec = importlib.util.spec_from_file_location('dbeer_native_resources', HERE / 'generate.py')
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)
FIXTURES = HERE.parents[1] / 'fixtures/native-resources'


class ResourceCases(unittest.TestCase):
    def setUp(self):
        self.identity_data = (FIXTURES / 'windows-build-identity.json').read_bytes()
        self.identity = json.loads(self.identity_data)

    def render(self):
        # Fixture source hashes deliberately do not claim to identify the live tree.
        with mock.patch.object(native.core, 'new_identity', return_value=self.identity):
            return native.render_resources(self.identity_data)

    def test_fixed_version_boundaries_from_fixture_never_wrap_or_truncate(self):
        fixture = json.loads((FIXTURES / 'version-cases.json').read_bytes())
        for item in fixture['accepted']:
            with self.subTest(item=item):
                self.assertEqual(native.fixed_version(item['version'], item['build']), tuple(item['fixed']))
        for item in fixture['rejected']:
            with self.subTest(item=item), self.assertRaises(native.Refused):
                native.fixed_version(item['version'], item['build'])

    def test_identity_is_exact_current_shared_contract_and_windows_msvc_target(self):
        mutations = [('target', 'linux-x86_64-gnu'), ('target', 'windows-x86_64-gnu'),
                     ('productId', 'dev.dbeer.gpui-prototype'), ('version', '0.3.0'),
                     ('buildNumber', '2'), ('sourceSha256', 'b' * 64),
                     ('capabilities', []), ('protocolVersion', True), ('extra', 'unsupported')]
        for key, value in mutations:
            identity = dict(self.identity, **{key: value})
            with self.subTest(key=key, value=value), mock.patch.object(native.core, 'new_identity', return_value=self.identity):
                with self.assertRaises(native.Refused):
                    native.render_resources(native.core.json_bytes(identity))
        for data in (self.identity_data.rstrip(), b'{"schemaVersion":1,"schemaVersion":1}', b' ' * 4097):
            with self.subTest(data_length=len(data)), self.assertRaises(native.Refused):
                native.render_resources(data)

    def test_both_components_use_shared_version_strings_and_exact_word_versions(self):
        files = self.render()
        for component, filename in [('gui', 'dbeer-gpui.exe'), ('helper', 'dbeer-core.exe')]:
            text = files[component + '.rc'].decode('ascii')
            self.assertIn('FILEVERSION 0,2,0,1', text)
            self.assertIn('PRODUCTVERSION 0,2,0,1', text)
            self.assertIn('VALUE "FileVersion", "0.2.0.1\\0"', text)
            self.assertIn('VALUE "ProductVersion", "0.2.0\\0"', text)
            self.assertIn('VALUE "BuildNumber", "1\\0"', text)
            self.assertIn(f'VALUE "OriginalFilename", "{filename}\\0"', text)
            self.assertIn('VALUE "ProductId", "app.dbeer.DBeer\\0"', text)
            self.assertIn('VALUE "Translation", 0x0409, 1200', text)
            self.assertIn('FILEFLAGS VS_FF_PRERELEASE', text)
            self.assertNotIn('@', text)
        self.assertIn('1 ICON "dbeer.ico"', files['gui.rc'].decode())
        self.assertNotIn('1 ICON', files['helper.rc'].decode())
        self.assertEqual(files['BUILD-IDENTITY.json'], self.identity_data)

    def test_manifest_privileges_amd64_and_pinned_backend_requirements(self):
        files = self.render()
        for component in ('gui', 'helper'):
            root = ET.fromstring(files[component + '.manifest'])
            identity = root.find('{urn:schemas-microsoft-com:asm.v1}assemblyIdentity')
            self.assertEqual(identity.attrib, {'type': 'win32', 'name': 'app.dbeer.DBeer',
                                              'version': '0.2.0.1', 'processorArchitecture': 'amd64'})
            level = root.find('.//{urn:schemas-microsoft-com:asm.v3}requestedExecutionLevel')
            self.assertEqual(level.attrib, {'level': 'asInvoker', 'uiAccess': 'false'})
            supported = root.findall('.//{urn:schemas-microsoft-com:compatibility.v1}supportedOS')
            self.assertEqual([item.attrib for item in supported], [{'Id': '{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}'}])
            self.assertIsNone(root.find('.//{urn:schemas-microsoft-com:compatibility.v1}maxversiontested'))
        gui = ET.fromstring(files['gui.manifest'])
        self.assertEqual(gui.find('.//{http://schemas.microsoft.com/SMI/2005/WindowsSettings}dpiAware').text, 'true/pm')
        self.assertEqual(gui.find('.//{http://schemas.microsoft.com/SMI/2016/WindowsSettings}dpiAwareness').text, 'PerMonitorV2')
        self.assertEqual(gui.find('.//{http://schemas.microsoft.com/SMI/2020/WindowsSettings}heapType').text, 'SegmentHeap')
        controls = gui.find('.//{urn:schemas-microsoft-com:asm.v1}dependentAssembly/{urn:schemas-microsoft-com:asm.v1}assemblyIdentity')
        self.assertEqual(controls.attrib['name'], 'Microsoft.Windows.Common-Controls')
        self.assertEqual(controls.attrib['version'], '6.0.0.0')
        self.assertEqual(controls.attrib['publicKeyToken'], '6595b64144ccf1df')
        self.assertNotIn(b'dpiAware', files['helper.manifest'])

    def test_additional_or_wrong_manifest_language_refuses_before_resource_acceptance(self):
        files = self.render()
        for inventory in [(1, []), (1, [0x0409, 0]), (2, [0x0409]), (1, [0])]:
            with self.subTest(inventory=inventory), mock.patch.object(native.core, 'native'), mock.patch.object(native.core, 'safe'), mock.patch.object(native.core, 'binary_header'), mock.patch.object(native, 'manifest_inventory', return_value=inventory), mock.patch.object(native, 'native_resource') as read:
                with self.assertRaises(native.Refused):
                    native.verify_native_pe(Path('owned-native-gui.exe'), 'gui', files)
                read.assert_not_called()

    def test_icon_is_reproducible_from_unchanged_source_without_converter(self):
        source = (native.ROOT / 'macos/Resources/AppIcon.png').read_bytes()
        before = native.core.sha(source)
        self.assertEqual(native.derive_icon(source), (HERE / 'dbeer.ico').read_bytes())
        self.assertEqual(native.core.sha((native.ROOT / 'macos/Resources/AppIcon.png').read_bytes()), before)
        self.assertEqual(native.icon_input(), (HERE / 'dbeer.ico').read_bytes())

    def test_corrupt_truncated_and_unsupported_png_inputs_refuse(self):
        source = (native.ROOT / 'macos/Resources/AppIcon.png').read_bytes()
        corrupt = bytearray(source)
        corrupt[40] ^= 1
        for data in (b'', source[:-1], bytes(corrupt), source + b'extra', source * 40):
            with self.subTest(length=len(data)), self.assertRaises(native.Refused):
                native.decode_source_png(data)

    def test_alpha_weighted_resampling_preserves_color_at_transparent_edges(self):
        pixels = bytes((255, 0, 0, 255, 0, 255, 0, 0, 0, 0, 255, 0, 255, 255, 255, 0))
        self.assertEqual(native.resize_rgba(pixels, 2, 2, 1), bytes((255, 0, 0, 64)))
        self.assertEqual(native.resize_rgba(bytes((200, 50, 10, 0)) * 4, 2, 2, 1), bytes(4))

    def test_ico_frames_use_all_sizes_bgra_bottom_rows_and_padded_masks(self):
        icon = (HERE / 'dbeer.ico').read_bytes()
        self.assertEqual(struct.unpack_from('<HHH', icon), (0, 1, 10))
        end = 6 + 16 * len(native.ICON_SIZES)
        for index, size in enumerate(native.ICON_SIZES):
            width, height, colors, reserved, planes, bits, length, offset = struct.unpack_from('<BBBBHHII', icon, 6 + 16 * index)
            self.assertEqual((width, height, colors, reserved, planes, bits), (size % 256, size % 256, 0, 0, 1, 32))
            self.assertEqual(offset, end)
            frame = icon[offset:offset + length]
            self.assertEqual(struct.unpack_from('<IiiHHI', frame), (40, size, size * 2, 1, 32, 0))
            self.assertEqual(length, 40 + size * size * 4 + ((size + 31) // 32) * 4 * size)
            end += length
        self.assertEqual(end, len(icon))
        frame = native.dib_image(bytes((255, 0, 0, 255, 0, 0, 0, 0, 0, 255, 0, 255, 0, 0, 255, 0)), 2)
        self.assertEqual(frame[40:56], bytes((0, 255, 0, 255, 255, 0, 0, 0, 0, 0, 255, 255, 0, 0, 0, 0)))
        self.assertEqual(frame[56:], b'\x40\0\0\0\x40\0\0\0')

    def test_input_manifest_hashes_and_no_replace_output_ownership(self):
        files = self.render()
        inventory = json.loads(files['NATIVE-RESOURCES.json'])
        self.assertEqual(set(inventory['files']), set(files) - {'NATIVE-RESOURCES.json'})
        for name, entry in inventory['files'].items():
            self.assertEqual(entry, {'sha256': native.core.sha(files[name]), 'size': len(files[name])})
        root = native.ROOT / 'build/gpui/native-resource-tests'
        root.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='owned-', dir=root) as temporary:
            output = Path(temporary) / 'inputs'
            native.write_outputs(files, output)
            native.verify_inputs(files, output)
            with self.assertRaises((native.Refused, OSError)):
                native.write_outputs(files, output)
            self.assertEqual((output / 'gui.rc').read_bytes(), files['gui.rc'])
            (output / 'extra').write_bytes(b'unexpected')
            with self.assertRaises(native.Refused):
                native.verify_inputs(files, output)

    def test_native_resource_checks_refuse_a_non_native_host_before_loading(self):
        files = self.render()
        with mock.patch.object(native.core.sys, 'platform', 'darwin'), mock.patch.object(native.core.platform, 'machine', return_value='x86_64'):
            with self.assertRaises(native.Refused):
                native.verify_native_pe(Path('not-executed.exe'), 'gui', files)


@unittest.skipUnless(sys.platform == 'win32' and os.environ.get('DBEER_NATIVE_RESOURCE_GUI')
                     and os.environ.get('DBEER_NATIVE_RESOURCE_IDENTITY')
                     and os.environ.get('DBEER_NATIVE_RESOURCE_INPUTS'),
                     'Requires exact native Windows x64 binaries and current generated inputs.')
class NativeArtifactCases(unittest.TestCase):
    def test_exact_native_artifact_resources_without_executable_startup(self):
        identity = native.core.bounded(Path(os.environ['DBEER_NATIVE_RESOURCE_IDENTITY']), 4096)
        files = native.render_resources(identity)
        native.verify_inputs(files, Path(os.environ['DBEER_NATIVE_RESOURCE_INPUTS']))
        native.verify_native_pe(Path(os.environ['DBEER_NATIVE_RESOURCE_GUI']), 'gui', files)
        helper = os.environ.get('DBEER_NATIVE_RESOURCE_HELPER')
        if helper:
            native.verify_native_pe(Path(helper), 'helper', files)


if __name__ == '__main__':
    unittest.main()
