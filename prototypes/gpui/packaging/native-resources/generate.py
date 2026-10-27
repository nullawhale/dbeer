#!/usr/bin/env python3
"""Prepare deterministic Windows resource inputs; never build, sign or execute a binary."""
import argparse
import ctypes
from ctypes import wintypes
import importlib.util
from pathlib import Path
import struct
import sys
import tempfile
import zlib

if sys.version_info < (3, 11):
    print('DBeer native resource preparation requires Python 3.11 or later.', file=sys.stderr)
    sys.exit(2)

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
TARGET = 'windows-x86_64-msvc'
ICON_SIZES = (16, 20, 24, 32, 40, 48, 64, 96, 128, 256)
PNG_SIGNATURE = b'\x89PNG\r\n\x1a\n'


def load_packaging_core():
    """The existing packaging BuildIdentity schema remains the sole authority."""
    spec = importlib.util.spec_from_file_location('dbeer_packaging_core', HERE.parent / 'package.py')
    core = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(core)
    return core


core = load_packaging_core()
Refused = core.Refused


def decode_source_png(data):
    """Decode the existing non-interlaced 8-bit RGBA source, with bounded inflation."""
    if not data.startswith(PNG_SIGNATURE) or len(data) > 4 * 1024 * 1024:
        raise Refused('Expected the bounded authoritative PNG icon.')
    offset, compressed, seen = 8, bytearray(), []
    width = height = None
    while offset < len(data):
        if offset + 12 > len(data):
            raise Refused('Truncated icon PNG chunk.')
        size = struct.unpack_from('>I', data, offset)[0]
        kind = data[offset + 4:offset + 8]
        end = offset + 12 + size
        if end > len(data):
            raise Refused('Truncated icon PNG payload.')
        payload = data[offset + 8:offset + 8 + size]
        checksum = struct.unpack_from('>I', data, offset + 8 + size)[0]
        if zlib.crc32(kind + payload) != checksum:
            raise Refused('Corrupt icon PNG chunk.')
        if kind == b'IHDR':
            if seen or size != 13:
                raise Refused('Unexpected icon PNG header.')
            width, height, depth, color, compression, filtering, interlace = struct.unpack('>IIBBBBB', payload)
            if (width, height, depth, color, compression, filtering, interlace) != (1024, 1024, 8, 6, 0, 0, 0):
                raise Refused('The source icon must be the existing 1024px RGBA PNG.')
        elif kind == b'IDAT':
            if not seen or seen[0] != b'IHDR' or (b'IDAT' in seen and seen[-1] != b'IDAT'):
                raise Refused('Unexpected icon PNG data order.')
            compressed.extend(payload)
        elif kind == b'IEND':
            if size or not compressed or end != len(data):
                raise Refused('Unexpected icon PNG end.')
        elif not kind[0] & 32 or kind in (b'acTL', b'fcTL', b'fdAT'):
            raise Refused('Unsupported icon PNG chunk.')
        seen.append(kind)
        offset = end
    if not seen or seen[-1] != b'IEND' or width is None:
        raise Refused('Incomplete icon PNG.')
    stride = width * 4
    expected = (stride + 1) * height
    inflater = zlib.decompressobj()
    raw = inflater.decompress(bytes(compressed), expected + 1)
    if len(raw) != expected or not inflater.eof or inflater.unused_data or inflater.unconsumed_tail:
        raise Refused('Invalid or oversized icon PNG pixels.')
    pixels, previous = bytearray(), bytearray(stride)
    for row in range(height):
        start = row * (stride + 1)
        method, current = raw[start], bytearray(raw[start + 1:start + 1 + stride])
        if method > 4:
            raise Refused('Unsupported icon PNG filter.')
        for index in range(stride):
            left = current[index - 4] if index >= 4 else 0
            above = previous[index]
            upper_left = previous[index - 4] if index >= 4 else 0
            if method == 0:
                predictor = 0
            elif method == 1:
                predictor = left
            elif method == 2:
                predictor = above
            elif method == 3:
                predictor = (left + above) // 2
            else:
                estimate = left + above - upper_left
                distances = (abs(estimate - left), abs(estimate - above), abs(estimate - upper_left))
                predictor = (left, above, upper_left)[distances.index(min(distances))]
            current[index] = (current[index] + predictor) & 255
        pixels.extend(current)
        previous = current
    return width, height, bytes(pixels)


def axis_weights(source_size, destination_size):
    """Exact integer overlap weights; no host floating-point or imaging library."""
    result = []
    for destination in range(destination_size):
        left, right = destination * source_size, (destination + 1) * source_size
        result.append([(source, min(right, (source + 1) * destination_size) - max(left, source * destination_size))
                       for source in range(left // destination_size, (right - 1) // destination_size + 1)])
    return result


def resize_rgba(pixels, width, height, size):
    """Area-average unchanged sRGB pixels with alpha-weighted color to avoid dark fringes."""
    if len(pixels) != width * height * 4 or not 0 < size <= min(width, height):
        raise Refused('Invalid icon resize dimensions.')
    horizontal = []
    columns = axis_weights(width, size)
    for row in range(height):
        line = []
        for weights in columns:
            red = green = blue = alpha = 0
            for column, weight in weights:
                offset = (row * width + column) * 4
                r, g, b, a = pixels[offset:offset + 4]
                red += r * a * weight
                green += g * a * weight
                blue += b * a * weight
                alpha += a * weight
            line.append((red, green, blue, alpha))
        horizontal.append(line)
    result = bytearray()
    area = width * height
    for weights in axis_weights(height, size):
        for column in range(size):
            sums = [sum(horizontal[row][column][channel] * weight for row, weight in weights)
                    for channel in range(4)]
            alpha = (sums[3] + area // 2) // area
            colors = [(value + sums[3] // 2) // sums[3] for value in sums[:3]] if alpha else [0, 0, 0]
            result.extend((*colors, alpha))
    return bytes(result)


def dib_image(pixels, size):
    """32-bit straight-alpha BGRA DIB plus DWORD-aligned AND mask, bottom row first."""
    if len(pixels) != size * size * 4:
        raise Refused('Invalid icon pixel count.')
    color, mask = bytearray(), bytearray()
    mask_stride = ((size + 31) // 32) * 4
    for row in reversed(range(size)):
        mask_row = bytearray(mask_stride)
        for column in range(size):
            offset = (row * size + column) * 4
            red, green, blue, alpha = pixels[offset:offset + 4]
            color.extend((blue, green, red, alpha))
            if alpha == 0:
                mask_row[column // 8] |= 0x80 >> (column % 8)
        mask.extend(mask_row)
    header = struct.pack('<IiiHHIIiiII', 40, size, size * 2, 1, 32, 0, len(color) + len(mask), 0, 0, 0, 0)
    return header + color + mask


def derive_icon(source_png):
    """Return a multi-size ICO, derived only from the unchanged source PNG."""
    width, height, pixels = decode_source_png(source_png)
    images = [dib_image(resize_rgba(pixels, width, height, size), size) for size in ICON_SIZES]
    offset, entries = 6 + len(images) * 16, bytearray()
    for size, image in zip(ICON_SIZES, images):
        entries.extend(struct.pack('<BBBBHHII', size % 256, size % 256, 0, 0, 1, 32, len(image), offset))
        offset += len(image)
    return struct.pack('<HHH', 0, 1, len(images)) + entries + b''.join(images)


def fixed_version(version, build):
    """Windows fixed/assembly versions contain four WORDs. Refuse overflow, never mask it."""
    values = tuple(int(value) for value in (*version.split('.'), build))
    if len(values) != 4 or any(value < 0 or value > 65535 for value in values):
        raise Refused('VERSION components and BUILD_NUMBER must fit Windows 16-bit version fields.')
    return values


def validate_build_identity(identity_data):
    if not isinstance(identity_data, bytes) or len(identity_data) > 4096:
        raise Refused('A bounded canonical BuildIdentity is required.')
    identity = core.validate_identity(core.strict_json(identity_data), TARGET)
    if identity_data != core.json_bytes(identity):
        raise Refused('Use the exact canonical identity file produced by package.py identity.')
    if identity != core.new_identity(TARGET):
        raise Refused('Resource metadata differs from current VERSION/BUILD_NUMBER or source inputs.')
    fixed_version(identity['version'], identity['buildNumber'])
    return identity


def icon_input():
    provenance = core.strict_json(core.bounded(HERE / 'icon-provenance.json', 4096))
    png = core.bounded(ROOT / 'macos/Resources/AppIcon.png', 4 * 1024 * 1024)
    svg = core.bounded(ROOT / 'macos/Resources/AppIcon.svg', 1024 * 1024)
    icon = core.bounded(HERE / 'dbeer.ico', 2 * 1024 * 1024)
    if (not isinstance(provenance, dict) or provenance.get('schemaVersion') != 1
            or provenance.get('sizes') != list(ICON_SIZES)
            or provenance.get('sourcePngSha256') != core.sha(png)
            or provenance.get('sourceSvgSha256') != core.sha(svg)
            or provenance.get('icoSha256') != core.sha(icon)):
        raise Refused('Icon provenance does not match the unchanged authoritative source assets.')
    return icon


def version_strings(identity, component):
    filename = 'dbeer-gpui.exe' if component == 'gui' else 'dbeer-core.exe'
    return {'CompanyName': 'DBeer', 'FileDescription': 'DBeer' if component == 'gui' else 'DBeer helper',
            'FileVersion': identity['version'] + '.' + identity['buildNumber'],
            'InternalName': filename[:-4], 'OriginalFilename': filename, 'ProductName': 'DBeer',
            'ProductVersion': identity['version'], 'BuildNumber': identity['buildNumber'],
            'ProductId': identity['productId'], 'BuildTarget': identity['target'],
            'Comments': 'Unsigned development candidate'}


def template(name, substitutions):
    value = core.bounded(HERE / name, 16384).decode('ascii')
    for key, replacement in substitutions.items():
        value = value.replace('@' + key + '@', replacement)
    if '@' in value:
        raise Refused('Unresolved native resource template field.')
    return value.encode('ascii')


def render_resources(identity_data):
    """Public API: exact current Windows BuildIdentity bytes -> relative-name/bytes mapping."""
    identity = validate_build_identity(identity_data)
    fixed = fixed_version(identity['version'], identity['buildNumber'])
    result = {'dbeer.ico': icon_input(), 'BUILD-IDENTITY.json': identity_data}
    for component in ('gui', 'helper'):
        result[component + '.manifest'] = template('application.manifest.in', {
            'VERSION': '.'.join(map(str, fixed)),
            'WINDOWS_SETTINGS': core.bounded(HERE / 'gui-settings.xml', 4096).decode('ascii') if component == 'gui' else '',
            'DESCRIPTION': 'DBeer' if component == 'gui' else 'DBeer helper',
        })
        strings = '\n'.join(f'            VALUE "{key}", "{value}\\0"'
                            for key, value in version_strings(identity, component).items())
        result[component + '.rc'] = template('application.rc.in', {
            'FIXED_VERSION': ','.join(map(str, fixed)), 'STRINGS': strings,
            'MANIFEST': component + '.manifest',
            'ICON': '1 ICON "dbeer.ico"' if component == 'gui' else '',
        })
    result['NATIVE-RESOURCES.json'] = core.json_bytes({
        'schemaVersion': 1, 'target': TARGET, 'identity': identity,
        'iconResourceId': 1, 'manifestResourceId': 1, 'versionResourceId': 1,
        'files': {name: {'sha256': core.sha(data), 'size': len(data)} for name, data in sorted(result.items())},
    })
    return result


def write_outputs(files, destination):
    """Publish a new complete directory under ignored build/. Never replace existing output."""
    destination = core.safe(destination, directory=True, missing=True)
    if not destination.is_relative_to(ROOT / 'build'):
        raise Refused('Native resource outputs belong under ignored build/.')
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    stage = Path(tempfile.mkdtemp(prefix='.native-resources-', dir=destination.parent))
    stage.chmod(0o700)
    original = stage.stat(follow_symlinks=False)
    try:
        for name, data in files.items():
            with (stage / name).open('xb') as output:
                output.write(data)
        core.publish_directory(stage, destination)
    finally:
        core.owned_cleanup(stage, original)


def verify_inputs(files, directory):
    directory = core.safe(directory, directory=True)
    if {path.name for path in directory.iterdir()} != set(files):
        raise Refused('Incomplete or extra native resource inputs.')
    for name, expected in files.items():
        if core.bounded(directory / name, 2 * 1024 * 1024) != expected:
            raise Refused('Stale or altered native resource input.')


def native_resource(binary, kind, name):
    """Read a PE resource as data with Win32 APIs; no entry point or DLL initialization runs."""
    library = ctypes.WinDLL('kernel32', use_last_error=True)
    library.LoadLibraryExW.argtypes = [wintypes.LPCWSTR, wintypes.HANDLE, wintypes.DWORD]
    library.LoadLibraryExW.restype = wintypes.HMODULE
    library.FreeLibrary.argtypes = [wintypes.HMODULE]
    library.FreeLibrary.restype = wintypes.BOOL
    library.FindResourceW.argtypes = [wintypes.HMODULE, ctypes.c_void_p, ctypes.c_void_p]
    library.FindResourceW.restype = wintypes.HRSRC
    library.SizeofResource.argtypes = [wintypes.HMODULE, wintypes.HRSRC]
    library.SizeofResource.restype = wintypes.DWORD
    library.LoadResource.argtypes = [wintypes.HMODULE, wintypes.HRSRC]
    library.LoadResource.restype = wintypes.HGLOBAL
    library.LockResource.argtypes = [wintypes.HGLOBAL]
    library.LockResource.restype = ctypes.c_void_p
    handle = library.LoadLibraryExW(str(binary), None, 0x00000002 | 0x00000020)
    if not handle:
        raise Refused('Cannot map the native PE as resource data.')
    try:
        resource = library.FindResourceW(handle, name, kind)
        size = library.SizeofResource(handle, resource) if resource else 0
        loaded = library.LoadResource(handle, resource) if resource else None
        pointer = library.LockResource(loaded) if loaded else None
        if not pointer or not 0 < size <= 2 * 1024 * 1024:
            raise Refused('Missing or oversized native PE resource.')
        return ctypes.string_at(pointer, size)
    finally:
        library.FreeLibrary(handle)


def manifest_inventory(binary):
    """Enumerate every manifest name/language; FindResource alone could hide extras."""
    library = ctypes.WinDLL('kernel32', use_last_error=True)
    library.LoadLibraryExW.argtypes = [wintypes.LPCWSTR, wintypes.HANDLE, wintypes.DWORD]
    library.LoadLibraryExW.restype = wintypes.HMODULE
    library.FreeLibrary.argtypes = [wintypes.HMODULE]
    library.FreeLibrary.restype = wintypes.BOOL
    names_type = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HMODULE, ctypes.c_void_p,
                                   ctypes.c_void_p, ctypes.c_ssize_t)
    languages_type = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HMODULE, ctypes.c_void_p,
                                       ctypes.c_void_p, wintypes.WORD, ctypes.c_ssize_t)
    library.EnumResourceNamesW.argtypes = [wintypes.HMODULE, ctypes.c_void_p, names_type, ctypes.c_ssize_t]
    library.EnumResourceNamesW.restype = wintypes.BOOL
    library.EnumResourceLanguagesW.argtypes = [wintypes.HMODULE, ctypes.c_void_p, ctypes.c_void_p,
                                              languages_type, ctypes.c_ssize_t]
    library.EnumResourceLanguagesW.restype = wintypes.BOOL
    names, languages = [], []
    @names_type
    def name_callback(_handle, _kind, name, _parameter):
        names.append(name if name is not None and name <= 0xffff else 'named-resource')
        return len(names) <= 32
    @languages_type
    def language_callback(_handle, _kind, _name, language, _parameter):
        languages.append(language)
        return len(languages) <= 32
    handle = library.LoadLibraryExW(str(binary), None, 0x00000002 | 0x00000020)
    if not handle:
        raise Refused('Cannot map the native PE manifest inventory.')
    try:
        if not library.EnumResourceNamesW(handle, 24, name_callback, 0) or names != [1]:
            raise Refused('The native GUI must contain exactly one manifest resource, ID 1.')
        if not library.EnumResourceLanguagesW(handle, 24, 1, language_callback, 0):
            raise Refused('Cannot enumerate the native manifest languages.')
        return names[0], languages
    finally:
        library.FreeLibrary(handle)


def verify_native_versions(binary, identity, component):
    version = ctypes.WinDLL('version', use_last_error=True)
    version.GetFileVersionInfoSizeW.argtypes = [wintypes.LPCWSTR, ctypes.POINTER(wintypes.DWORD)]
    version.GetFileVersionInfoSizeW.restype = wintypes.DWORD
    version.GetFileVersionInfoW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, ctypes.c_void_p]
    version.GetFileVersionInfoW.restype = wintypes.BOOL
    version.VerQueryValueW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR, ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(wintypes.UINT)]
    version.VerQueryValueW.restype = wintypes.BOOL
    ignored = wintypes.DWORD()
    size = version.GetFileVersionInfoSizeW(str(binary), ctypes.byref(ignored))
    if not 0 < size <= 65536:
        raise Refused('Missing or oversized native version information.')
    buffer = ctypes.create_string_buffer(size)
    if not version.GetFileVersionInfoW(str(binary), 0, size, buffer):
        raise Refused('Cannot read native version information.')
    pointer, length = ctypes.c_void_p(), wintypes.UINT()
    if not version.VerQueryValueW(buffer, '\\', ctypes.byref(pointer), ctypes.byref(length)) or length.value != 52:
        raise Refused('Missing fixed native version information.')
    fixed = struct.unpack('<13I', ctypes.string_at(pointer, length.value))
    major, minor, patch, build = fixed_version(identity['version'], identity['buildNumber'])
    packed = (major << 16 | minor, patch << 16 | build)
    if fixed[:6] != (0xfeef04bd, 0x00010000, *packed, *packed):
        raise Refused('Native fixed version information differs from the build identity.')
    for key, expected in version_strings(identity, component).items():
        query = '\\StringFileInfo\\040904b0\\' + key
        if not version.VerQueryValueW(buffer, query, ctypes.byref(pointer), ctypes.byref(length)):
            raise Refused('Missing native version string.')
        if not 0 < length.value <= 256 or ctypes.wstring_at(pointer, length.value - 1) != expected:
            raise Refused('Native version string differs from the build identity.')


def verify_native_pe(binary, component, files):
    """Native Windows x64 resource verification without launching either executable."""
    core.native(TARGET)
    binary = core.safe(binary)
    core.binary_header(binary, TARGET)
    if component not in ('gui', 'helper'):
        raise Refused('Unknown product component.')
    if manifest_inventory(binary) != (1, [0x0409]):
        raise Refused('The native product must contain only its exact English host manifest.')
    if native_resource(binary, 24, 1) != files[component + '.manifest']:
        raise Refused('Native application manifest differs from the generated input.')
    identity = core.strict_json(files['BUILD-IDENTITY.json'])
    verify_native_versions(binary, identity, component)
    if component == 'gui':
        icon = files['dbeer.ico']
        group = native_resource(binary, 14, 1)
        if group[:6] != icon[:6] or len(group) != 6 + 14 * len(ICON_SIZES):
            raise Refused('Native icon group does not contain the expected images.')
        identifiers = set()
        for index in range(len(ICON_SIZES)):
            expected = struct.unpack_from('<BBBBHHII', icon, 6 + index * 16)
            actual = struct.unpack_from('<BBBBHHIH', group, 6 + index * 14)
            if actual[:7] != expected[:7] or not actual[7] or actual[7] in identifiers:
                raise Refused('Native icon image metadata differs from the derived ICO.')
            identifiers.add(actual[7])
            if native_resource(binary, 3, actual[7]) != icon[expected[7]:expected[7] + expected[6]]:
                raise Refused('Native icon pixels differ from the derived ICO.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    icon = commands.add_parser('derive-icon', help='derive source ICO/provenance into a new build/ directory')
    icon.add_argument('--output', required=True, type=Path)
    for command in ('generate', 'verify-inputs', 'verify-native-pe'):
        child = commands.add_parser(command)
        child.add_argument('--identity', required=True, type=Path)
        child.add_argument('--output' if command == 'generate' else '--inputs', required=True, type=Path)
        if command == 'verify-native-pe':
            child.add_argument('--gui', required=True, type=Path)
            child.add_argument('--helper', type=Path, help='optional until the Go resource build hook is integrated')
    args = parser.parse_args()
    if args.command == 'derive-icon':
        png = core.bounded(ROOT / 'macos/Resources/AppIcon.png', 4 * 1024 * 1024)
        svg = core.bounded(ROOT / 'macos/Resources/AppIcon.svg', 1024 * 1024)
        icon = derive_icon(png)
        provenance = {'schemaVersion': 1, 'sourcePng': 'macos/Resources/AppIcon.png',
                      'sourcePngSha256': core.sha(png), 'sourceSvg': 'macos/Resources/AppIcon.svg',
                      'sourceSvgSha256': core.sha(svg), 'icoSha256': core.sha(icon),
                      'sizes': list(ICON_SIZES), 'encoding': '32-bit BGRA DIB with AND mask',
                      'resampling': 'integer area average in source sRGB with alpha-weighted color'}
        write_outputs({'dbeer.ico': icon, 'icon-provenance.json': core.json_bytes(provenance)}, args.output)
        return
    files = render_resources(core.bounded(args.identity, 4096))
    if args.command == 'generate':
        write_outputs(files, args.output)
    else:
        verify_inputs(files, args.inputs)
        if args.command == 'verify-native-pe':
            verify_native_pe(args.gui, 'gui', files)
            if args.helper:
                verify_native_pe(args.helper, 'helper', files)
    if args.command == 'verify-native-pe':
        print('DBeer native PE resources match the current build identity.')
    else:
        print('DBeer native resource inputs match the current build identity.')


if __name__ == '__main__':
    try:
        main()
    except (Refused, OSError, ValueError, KeyError, TypeError, struct.error, zlib.error):
        print('DBeer native resources refused unsafe, stale, unsupported or mismatched inputs. Existing artifacts are preserved.', file=sys.stderr)
        sys.exit(2)
