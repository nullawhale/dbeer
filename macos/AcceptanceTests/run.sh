#!/bin/bash
set -euo pipefail
umask 077
runner_root="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$runner_root/../.." && pwd)"
output="$repo_root/build/AcceptanceTests"
developer_directory="/Applications/Xcode.app/Contents/Developer"
acceptance_kind="installed"
test_identifier="DBeerAcceptanceUITests/InstalledApplicationTests/testInstalledAppQueryAndQuit"
mkdir -p "$output"
chmod 700 "$output"
if [[ "${1:-}" == --build-only && "$#" == 1 ]]; then
    sdk_path="$(DEVELOPER_DIR="$developer_directory" /usr/bin/xcrun --sdk macosx --show-sdk-path)"
    DEVELOPER_DIR="$developer_directory" /usr/bin/xcrun --sdk macosx swiftc \
        -target arm64-apple-macosx14.0 -sdk "$sdk_path" \
        -module-cache-path "$output/input-source-cache" \
        "$runner_root/Support/InputSourceGuard.swift" -o "$output/input-source-guard"
    DEVELOPER_DIR="$developer_directory" /usr/bin/xcrun --sdk macosx swiftc \
        -parse-as-library -target arm64-apple-macosx14.0 -sdk "$sdk_path" \
        -module-cache-path "$output/input-source-cache" \
        "$runner_root/Support/SSHApplicationLauncher.swift" -o "$output/ssh-application-launcher"
    DEVELOPER_DIR="$developer_directory" "$developer_directory/usr/bin/xcodebuild" \
        build-for-testing -project "$runner_root/DBeerAcceptanceTests.xcodeproj" \
        -scheme DBeerAcceptanceUITests -configuration Debug -destination 'platform=macOS,arch=arm64' \
        -derivedDataPath "$output/derived-data" \
        CLANG_MODULE_CACHE_PATH="$output/clang-cache" \
        SWIFT_MODULE_CACHE_PATH="$output/swift-cache"
    exit
fi
if [[ "${1:-}" == --ssh ]]; then
    acceptance_kind="ssh"
    test_identifier="DBeerAcceptanceUITests/SSHApplicationTests/testSSHConnectionLifecycle"
    shift
fi
if [[ "$#" != 1 || "$1" != /* || ! -f "$1" ]]; then
    printf 'Usage: %s --build-only | [--ssh] /absolute/private-config.json\n' "$0" >&2
    exit 2
fi
configuration="$1"
phase_run="$(mktemp -d "$output/run.XXXXXX")"
python3 - "$configuration" "$output/derived-data/Build/Products" "$phase_run/Acceptance.xctestrun" <<'PY'
import json, os, pathlib, plistlib, stat, sys
config, products, output = map(pathlib.Path, sys.argv[1:])
mode = config.lstat()
if not stat.S_ISREG(mode.st_mode) or mode.st_uid != os.getuid() or mode.st_mode & 0o077:
    raise SystemExit('Acceptance config must be a private regular file owned by the current user.')
settings = json.loads(config.read_text())
if settings.get('launchPolicy') != 'attach' or settings.get('bundleIdentifier') != 'dev.dbeer.app':
    raise SystemExit('Only an explicitly owned, already running archived app can be tested.')
candidates = list(products.glob('*.xctestrun'))
if len(candidates) != 1:
    raise SystemExit('Build the standalone UI test runner first; expected exactly one xctestrun.')
document = plistlib.loads(candidates[0].read_bytes())
targets = []
if 'TestConfigurations' in document:
    for configuration in document['TestConfigurations']:
        targets.extend(configuration.get('TestTargets', []))
else:
    targets = [value for key, value in document.items() if key != '__xctestrun_metadata__' and isinstance(value, dict)]
if len(targets) != 1:
    raise SystemExit('The acceptance runner must contain exactly one test target.')
target = targets[0]
target.setdefault('EnvironmentVariables', {})['DBEER_ACCEPTANCE_CONFIG'] = str(config)
target['SystemAttachmentLifetime'] = 'keepNever'
target['UserAttachmentLifetime'] = 'keepAlways'
target['PreferredScreenCaptureFormat'] = 'screenshots'
def rebase(value):
    if isinstance(value, str):
        return value.replace('__TESTROOT__', str(products.resolve()))
    if isinstance(value, dict):
        return {key: rebase(item) for key, item in value.items()}
    if isinstance(value, list):
        return [rebase(item) for item in value]
    return value
output.write_bytes(plistlib.dumps(rebase(document)))
PY
set +e
DEVELOPER_DIR="$developer_directory" "$developer_directory/usr/bin/xcodebuild" \
    test-without-building -xctestrun "$phase_run/Acceptance.xctestrun" \
    -destination 'platform=macOS,arch=arm64' -resultBundlePath "$phase_run/Acceptance.xcresult" \
    -collect-test-diagnostics never \
    -parallel-testing-enabled NO \
    "-only-testing:$test_identifier" \
    2>&1 | tee "$phase_run/xcodebuild.log"
test_status=${PIPESTATUS[0]}
set -e
if [[ "$test_status" != 0 ]]; then
    if [[ -d "$phase_run/Acceptance.xcresult" ]]; then
        "$developer_directory/usr/bin/xcresulttool" export attachments \
            --path "$phase_run/Acceptance.xcresult" --output-path "$phase_run/attachments" || true
    fi
    printf 'Application UI test failed; private artifacts: %s\n' "$phase_run" >&2
    exit "$test_status"
fi
"$developer_directory/usr/bin/xcresulttool" export attachments \
    --path "$phase_run/Acceptance.xcresult" --output-path "$phase_run/attachments"
python3 - "$configuration" "$phase_run/xcodebuild.log" "$phase_run/attachments" "$acceptance_kind" <<'PY'
import json, os, pathlib, sys
config, log, attachments = map(pathlib.Path, sys.argv[1:4])
kind = sys.argv[4]
settings = json.loads(config.read_text())
prefix = 'DBEER_ACCEPTANCE_EVIDENCE '
records = [json.loads(line.split(prefix, 1)[1]) for line in log.read_text().splitlines() if prefix in line]
if not records:
    for path in attachments.glob('*.json'):
        if path.name == 'manifest.json':
            continue
        try:
            candidate = json.loads(path.read_text())
        except (ValueError, UnicodeDecodeError):
            continue
        if isinstance(candidate, dict) and candidate.get('phase') == settings['phase'] and candidate.get('passed') is True:
            records.append(candidate)
if len(records) != 1:
    raise SystemExit('XCTest did not publish exactly one acceptance evidence record.')
record = records[0]
ssh_crash = kind == 'ssh' and settings['phase'] == 'ssh-crash'
expected_normal_quit = not ssh_crash
if (record.get('passed') is not True or record.get('normalQuit') is not expected_normal_quit or
    record.get('phase') != settings['phase'] or record.get('pid') != settings['ownedPID'] or
    record.get('expectedBuild') != settings['expectedBuild']):
    raise SystemExit('Acceptance evidence does not match the owned fixture phase.')
if kind == 'ssh':
    required = ('firstConnect', 'encryptedKey', 'readyForForcedTermination') if ssh_crash else (
                'firstConnect', 'hostKeyReview', 'hostKeyCancelled', 'encryptedKey',
                'twoTabs', 'independentSessions', 'stoppedQuery', 'otherTabUnaffected',
                'profileDisconnected')
    if not all(record.get(key) is True for key in required):
        raise SystemExit('SSH UI acceptance did not prove every requested lifecycle scenario.')
record['xcresultPath'] = str(log.parent / 'Acceptance.xcresult')
record['screenshotPaths'] = [str(path) for path in sorted(attachments.glob('*.png'))]
if not record['screenshotPaths']:
    raise SystemExit('The successful UI test did not export its window-only screenshot evidence.')
output = pathlib.Path(settings['resultFile'])
temporary = output.with_name(output.name + '.tmp')
with temporary.open('x') as stream:
    json.dump(record, stream, sort_keys=True)
    stream.write('\n')
os.chmod(temporary, 0o600)
os.replace(temporary, output)
print('PASS: installed application phase', settings['phase'])
PY
