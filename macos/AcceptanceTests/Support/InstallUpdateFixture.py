import atexit
import argparse
import datetime
import hashlib
import json
import os
import pathlib
import plistlib
import pwd
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import uuid
import zipfile

root = pathlib.Path(sys.argv[1]).resolve()
arguments = argparse.ArgumentParser(description="Isolated signed application update acceptance")
arguments.add_argument("--baseline-archive", type=pathlib.Path)
arguments.add_argument("--candidate-app", type=pathlib.Path)
options = arguments.parse_args(sys.argv[2:])
if (options.baseline_archive is None) != (options.candidate_app is None):
    arguments.error("--baseline-archive and --candidate-app are required together")
candidate_mode = options.candidate_app is not None
service = "dev.dbeer.connections"
bundle_id = "dev.dbeer.app"
docker = shutil.which("docker")
runner = root / "macos/AcceptanceTests/run.sh"
if not docker or not runner.is_file():
    raise SystemExit("Docker and the standalone acceptance runner are required.")
if not os.environ.get("DBEER_TEST_DSN") or not os.environ.get("DBEER_TEST_MYSQL_PORT"):
    raise SystemExit("Both disposable database fixtures are required.")

class Failure(Exception):
    pass

def require(condition, message):
    if not condition:
        raise Failure(message)

def run(arguments, operation, timeout=30, environment=None):
    result = subprocess.run(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            timeout=timeout, env=environment)
    require(result.returncode == 0, operation + " failed; diagnostics were not printed to protect fixture data.")
    return result.stdout

def private_json(path, value):
    descriptor, temporary = tempfile.mkstemp(prefix=".acceptance.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as output:
            json.dump(value, output, indent=2)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)

def process_table():
    data = run(["/bin/ps", "-ww", "-axo", "pid=,ppid=,comm="], "Process inventory").decode()
    records = {}
    for line in data.splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) == 3:
            records[int(fields[0])] = {"parentPID": int(fields[1]), "path": fields[2]}
    return records

def assert_no_other_apps(allowed=()):
    unexpected = [pid for pid, item in process_table().items()
                  if pathlib.Path(item["path"]).name in {"DBeer", "dbeer-core"} and pid not in allowed]
    require(not unexpected, "A DBeer application/helper outside this run is active; it was left untouched.")

assert_no_other_apps()
base = root / "build/install-update"
base.mkdir(parents=True, exist_ok=True)
state = pathlib.Path(tempfile.mkdtemp(prefix="run.", dir=base))
state.chmod(0o700)
data_directory = state / "UserData"
data_directory.mkdir(mode=0o700)
support = data_directory / "Library/Application Support/DBeer"
support.mkdir(parents=True, mode=0o700)
installed = state / "Applications/DBeer.app"
installed.parent.mkdir(mode=0o700)
owned_app_paths = [installed] if candidate_mode else [installed, state / "archive-5/DBeer.app", state / "archive-6/DBeer.app"]
profiles_path = support / "connections.json"
workspace_path = support / "workspace.json"
owned_path = state / "owned-accounts.json"
report_path = state / "report.json"
run_id = state.name
report = {"version": 1, "runID": run_id, "status": "RUNNING", "phases": [],
          "mode": "archive-to-candidate" if candidate_mode else "legacy-archives",
          "bundleIdentifier": bundle_id, "installAppPath": str(installed),
          "dataHome": str(data_directory), "keychainService": service,
          "initialPrivateLibraryEmpty": True, "ownedAccounts": [], "archiveVerification": []}
owned = set()
known_profiles = {}
expected_documents = []
secret_files = []
def remove_owned_password_files():
    for path in secret_files:
        try:
            path.unlink()
        except FileNotFoundError:
            pass
atexit.register(remove_owned_password_files)
active_app = None
active_output = None
active_helpers = {}
active_input_source = None
failure = None

# Pass the real owner environment unchanged where required, never a replacement HOME.
public_environment_names = ("HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "SHELL", "__CF_USER_TEXT_ENCODING")
public_environment = {name: os.environ[name] for name in public_environment_names if name in os.environ}
ui_environment = dict(public_environment, PATH="/usr/bin:/bin:/usr/sbin:/sbin")
app_environment = dict(public_environment, PATH="/usr/bin:/bin", CFFIXED_USER_HOME=str(data_directory))

def file_fingerprint(path):
    if not path.exists():
        return {"exists": False}
    require(path.is_file(), "An owner data path is not a regular file.")
    return {"exists": True, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}

owner_support = pathlib.Path(pwd.getpwuid(os.getuid()).pw_dir) / "Library/Application Support/DBeer"
owner_paths = {name: owner_support / name for name in ("connections.json", "workspace.json")}
owner_before = {name: file_fingerprint(path) for name, path in owner_paths.items()}
report["ownerDataBefore"] = owner_before

def preferences_snapshot(path):
    result = subprocess.run(["/usr/bin/defaults", "export", bundle_id, "-"],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=ui_environment)
    if result.returncode == 0:
        values = plistlib.loads(result.stdout)
        require(isinstance(values, dict), "Preference export did not contain a domain.")
        present = True
    else:
        diagnostic = (result.stdout + result.stderr).decode(errors="replace").lower()
        require("does not exist" in diagnostic or "not found" in diagnostic, "Read-only preference export failed.")
        values, present = {}, False
    with path.open("xb") as output:
        output.write(plistlib.dumps({"present": present, "values": values}, fmt=plistlib.FMT_BINARY))
    path.chmod(0o600)
    return values

preferences_before = preferences_snapshot(state / "preferences-before.plist")

def fixture_connections():
    parsed = urllib.parse.urlsplit(os.environ["DBEER_TEST_DSN"])
    options = urllib.parse.parse_qs(parsed.query)
    pg = {"engine": "postgresql", "host": parsed.hostname, "port": parsed.port or 5432,
          "database": parsed.path.lstrip("/"), "user": urllib.parse.unquote(parsed.username or ""),
          "sslMode": options.get("sslmode", ["disable"])[0]}
    if options.get("sslrootcert"):
        pg["sslRootCert"] = options["sslrootcert"][0]
    mysql = {"engine": "mysql", "host": os.environ.get("DBEER_TEST_MYSQL_HOST", "localhost"),
             "port": int(os.environ["DBEER_TEST_MYSQL_PORT"]),
             "database": os.environ.get("DBEER_TEST_MYSQL_DATABASE", "dbeer"),
             "user": os.environ.get("DBEER_TEST_MYSQL_USER", "dbeer"), "sslMode": "verify-full"}
    ca = os.environ.get("DBEER_TEST_MYSQL_CA_FILE")
    require(ca and pathlib.Path(ca).is_file(), "The trusted MySQL CA fixture is required.")
    mysql["sslRootCert"] = ca
    connections = {"postgresql": pg, "mysql": mysql}
    passwords = {"postgresql": urllib.parse.unquote(parsed.password or ""),
                 "mysql": os.environ.get("DBEER_TEST_MYSQL_PASSWORD", "")}
    for engine, settings in connections.items():
        require(settings["host"] and settings["database"] and settings["user"] and passwords[engine], "Incomplete database fixture.")
        path = state / (engine + "-password")
        with path.open("xb") as output:
            secret_files.append(path)
            output.write(passwords[engine].encode())
        path.chmod(0o600)
        settings["passwordFile"] = str(path)
    passwords.clear()
    return connections

connections = fixture_connections()
os.environ.pop("DBEER_TEST_DSN", None)
os.environ.pop("DBEER_TEST_MYSQL_PASSWORD", None)

def container_for(engine):
    settings = connections[engine]
    exposed = "5432/tcp" if engine == "postgresql" else "3306/tcp"
    found = []
    for identifier in run([docker, "ps", "--format", "{{.ID}}"], "Container inventory").decode().splitlines():
        ports = json.loads(run([docker, "inspect", "--format", "{{json .NetworkSettings.Ports}}", identifier], "Container port lookup"))
        if any(item.get("HostIp") in {"127.0.0.1", "localhost"} and item.get("HostPort") == str(settings["port"])
               for item in (ports.get(exposed) or [])):
            found.append(identifier)
    require(len(found) == 1, "Expected one disposable database container for the assigned localhost port.")
    return found[0]

containers = {engine: container_for(engine) for engine in connections}

def database_sessions(engine):
    if engine == "postgresql":
        settings = connections[engine]
        query = "SELECT pid,state,COALESCE(wait_event,'') FROM pg_stat_activity WHERE datname=current_database() AND usename=current_user AND application_name='DBeer' AND pid<>pg_backend_pid() ORDER BY pid"
        arguments = [docker, "exec", containers[engine], "psql", "-X", "-U", settings["user"], "-d", settings["database"], "-At", "-F", "\t", "-c", query]
    else:
        query = "SELECT ID,COMMAND,COALESCE(STATE,'') FROM information_schema.PROCESSLIST WHERE USER='dbeer' AND DB='dbeer' ORDER BY ID"
        arguments = [docker, "exec", containers[engine], "sh", "-ec",
                     'MYSQL_PWD="$(cat /fixtures/root-password)" mysql --user=root --batch --skip-column-names --execute="$1"', "observer", query]
    output = run(arguments, "Database session observation", timeout=10).decode()
    return [line.split("\t", 2) for line in output.splitlines() if line]

def wait_no_sessions():
    deadline = time.monotonic() + 8
    while True:
        if all(not database_sessions(engine) for engine in connections):
            return
        require(time.monotonic() < deadline, "An owned database session remained after application termination.")
        time.sleep(0.2)

def load_profiles(require_two=True):
    require(profiles_path.is_file(), "The private profile library is missing.")
    library = json.loads(profiles_path.read_text())
    require(library.get("version") in ((2, 3, 4, 5) if candidate_mode else (2,)), "Unexpected private profile library version.")
    values = library.get("connections", [])
    require(isinstance(values, list) and len(values) <= 2, "Unexpected profiles in the private fixture library.")
    result = {}
    for value in values:
        engine = value.get("engine")
        require(engine in connections and engine not in result, "Unexpected or duplicate imported engine.")
        identifier = str(uuid.UUID(value["id"])).upper()
        require(value["id"] == identifier, "Fixture UUID is not in Swift UUID.uuidString form.")
        expected = {key: item for key, item in connections[engine].items() if key != "passwordFile"}
        expected["name"] = "Acceptance " + ("PostgreSQL " if engine == "postgresql" else "MySQL ") + run_id
        require(all(value.get(key) == item for key, item in expected.items()), "Imported profile metadata does not match the owned fixture.")
        require("password" not in value, "A private profile unexpectedly contains a password.")
        result[engine] = value
    if require_two:
        require(len(result) == 2, "The UI did not import exactly two fixture profiles.")
    return result

def recover_owned_accounts():
    if profiles_path.exists():
        for value in load_profiles(require_two=False).values():
            owned.add(value["id"])
    private_json(owned_path, {"service": service, "accounts": sorted(owned),
        "origin": "UUID() allocated by unchanged archived UI import into an initially empty private library; no pre-existing account enumeration or secret reads."})
    report["ownedAccounts"] = sorted(owned)

def semantic_preservation():
    values = load_profiles()
    require({engine: value["id"] for engine, value in values.items()} == {engine: value["id"] for engine, value in known_profiles.items()}, "Profile UUID changed across application launches.")
    if candidate_mode:
        require(all(all(values[engine].get(key) == item for key, item in original.items())
                    for engine, original in known_profiles.items()), "Baseline profile settings changed during migration.")
    snapshot = json.loads(workspace_path.read_text())
    stored = {value["id"]: value for value in snapshot.get("documents", [])}
    preserved = all(value["id"] in stored and all(stored[value["id"]].get(key) == item for key, item in value.items())
                    for value in expected_documents) if candidate_mode else all(stored.get(value["id"]) == value for value in expected_documents)
    require(preserved, "A seeded draft/title/profile binding changed across application launches.")
    if candidate_mode:
        ids = [value["id"] for value in snapshot.get("documents", [])]
        require([identifier for identifier in ids if identifier in {value["id"] for value in expected_documents}]
                == [value["id"] for value in expected_documents], "Restored drafts changed order.")

def verified_archives():
    apps, requirements, helper_hashes, app_hashes = {}, [], [], []
    for build in (5, 6):
        archive = root / f"build/releases/DBeer-0.1.0-{build}-macos-arm64.zip"
        checksum = archive.with_suffix(".zip.sha256").read_text().split()
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        require(checksum == [digest, archive.name], "Archive SHA256 mismatch.")
        with zipfile.ZipFile(archive) as source:
            require(source.testzip() is None, "Archive CRC mismatch.")
            require(all(not pathlib.PurePosixPath(name).is_absolute() and ".." not in pathlib.PurePosixPath(name).parts for name in source.namelist()), "Unsafe archive member path.")
        destination = state / ("archive-" + str(build))
        destination.mkdir(mode=0o700)
        run(["/usr/bin/ditto", "-x", "-k", str(archive), str(destination)], "Archive extraction")
        app = destination / "DBeer.app"
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        require(info.get("CFBundleIdentifier") == bundle_id and info.get("CFBundleShortVersionString") == "0.1.0" and info.get("CFBundleVersion") == str(build) and info.get("DBeerBuildKind") == "local", "Archive application metadata mismatch.")
        run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], "Archive signature verification")
        pair_requirements, pair_hashes = [], []
        for target in (app, app / "Contents/Helpers/dbeer-core"):
            details = subprocess.run(["/usr/bin/codesign", "-d", "--verbose=4", "-r-", str(target)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            require(details.returncode == 0, "Archive signature metadata unavailable.")
            text = (details.stdout + details.stderr).decode()
            require("DBeer CI Ephemeral Signing" not in text and "Authority=Apple Development:" in text, "Archive is not signed with the owner development identity.")
            pair_requirements.append(next(line for line in text.splitlines() if line.startswith("designated =>")))
            pair_hashes.append(re.search(r"^CDHash=(\S+)$", text, re.M).group(1))
        for executable in (app / "Contents/MacOS/DBeer", app / "Contents/Helpers/dbeer-core"):
            require(run(["/usr/bin/lipo", "-archs", str(executable)], "Archive architecture lookup").strip() == b"arm64", "Archive executable is not arm64.")
        requirements.append(pair_requirements)
        app_hashes.append(pair_hashes[0])
        helper_hashes.append(pair_hashes[1])
        apps[build] = app
        report["archiveVerification"].append({"build": build, "sha256": digest, "strictSignature": True, "arm64": True})
    require(requirements[0] == requirements[1] and helper_hashes[0] == helper_hashes[1] and app_hashes[0] != app_hashes[1], "Archive update identity/code-hash contract changed.")
    return apps

def verify_signed_app(app):
    require(app.is_dir() and not app.is_symlink(), "Application input must be a regular bundle directory.")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    require(info.get("CFBundleIdentifier") == bundle_id and info.get("DBeerBuildKind") == "local",
            "Application identity or build kind is not an owner development build.")
    require(re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}", info.get("CFBundleShortVersionString", "")) and
            re.fullmatch(r"[0-9]+", info.get("CFBundleVersion", "")), "Invalid application version metadata.")
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], "Application signature verification")
    requirements, hashes, teams = [], [], []
    for target in (app, app / "Contents/Helpers/dbeer-core"):
        details = subprocess.run(["/usr/bin/codesign", "-d", "--verbose=4", "-r-", str(target)],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        require(details.returncode == 0, "Application signature metadata unavailable.")
        output = (details.stdout + details.stderr).decode()
        require("DBeer CI Ephemeral Signing" not in output and "Authority=Apple Development:" in output,
                "Application is not signed with the owner development identity.")
        requirement = re.search(r"^designated => (.+)$", output, re.M)
        digest = re.search(r"^CDHash=(\S+)$", output, re.M)
        team = re.search(r"^TeamIdentifier=(\S+)$", output, re.M)
        require(requirement and digest and team and team.group(1) != "not", "Incomplete application signing identity.")
        requirements.append(requirement.group(1))
        hashes.append(digest.group(1))
        teams.append(team.group(1))
    require(teams[0] == teams[1], "Application and helper signing teams differ.")
    for executable in (app / "Contents/MacOS/DBeer", app / "Contents/Helpers/dbeer-core"):
        require(run(["/usr/bin/lipo", "-archs", str(executable)], "Application architecture lookup").strip() == b"arm64",
                "Application executable is not arm64.")
    return {"version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
            "requirements": requirements, "codeHashes": hashes, "team": teams[0], "strictSignature": True, "arm64": True}

def verified_candidate_pair():
    archive_input = options.baseline_archive.expanduser().absolute()
    candidate_input = options.candidate_app.expanduser().absolute()
    require(archive_input.is_file() and not archive_input.is_symlink(), "Baseline archive must be a regular ZIP file.")
    checksum_file = archive_input.with_suffix(".zip.sha256")
    require(checksum_file.is_file() and not checksum_file.is_symlink(), "Baseline checksum file is missing.")
    digest = hashlib.sha256(archive_input.read_bytes()).hexdigest()
    require(checksum_file.read_text().split() == [digest, archive_input.name], "Baseline archive SHA256 mismatch.")
    with zipfile.ZipFile(archive_input) as source:
        require(source.testzip() is None, "Baseline archive CRC mismatch.")
        require(all(not pathlib.PurePosixPath(name).is_absolute() and ".." not in pathlib.PurePosixPath(name).parts
                    for name in source.namelist()), "Unsafe baseline archive member path.")
        require(not any(stat.S_ISLNK(member.external_attr >> 16) for member in source.infolist()),
                "Baseline archive contains unsupported symbolic-link entries.")
    baseline_directory = state / "baseline"
    baseline_directory.mkdir(mode=0o700)
    baseline = baseline_directory / "DBeer.app"
    owned_app_paths.append(baseline)
    run(["/usr/bin/ditto", "-x", "-k", str(archive_input), str(baseline_directory)], "Baseline archive extraction")
    candidate_directory = state / "candidate"
    candidate_directory.mkdir(mode=0o700)
    candidate = candidate_directory / "DBeer.app"
    owned_app_paths.append(candidate)
    candidate_source = verify_signed_app(candidate_input)
    candidate_source_contents = bundle_contents(candidate_input)
    run(["/usr/bin/ditto", str(candidate_input), str(candidate)], "Candidate snapshot copy")
    baseline_identity, candidate_identity = verify_signed_app(baseline), verify_signed_app(candidate)
    require((baseline_identity["version"], baseline_identity["build"]) in {("0.1.0", "6"), ("0.2.0", "8")},
            "This migration fixture supports the accepted 0.1.0/build 6 and 0.2.0/build 8 baselines only.")
    require(candidate_identity == candidate_source and bundle_contents(candidate) == candidate_source_contents,
            "Candidate changed while its private snapshot was copied.")
    require(baseline_identity["requirements"] == candidate_identity["requirements"] and
            baseline_identity["team"] == candidate_identity["team"], "Baseline and candidate signing identities differ.")
    require(bundle_contents(baseline) != candidate_source_contents, "Baseline and candidate contain identical application code.")
    report["archiveVerification"].append(dict(baseline_identity, sha256=digest))
    report["candidateVerification"] = dict(candidate_identity, sourcePath=str(candidate_input),
        completeBundleSHA256=hashlib.sha256(json.dumps(candidate_source_contents, sort_keys=True).encode()).hexdigest())
    report["sameVersionAndBuild"] = (baseline_identity["version"], baseline_identity["build"]) == (candidate_identity["version"], candidate_identity["build"])
    return baseline, baseline_identity, candidate, candidate_identity, archive_input, digest, candidate_input, candidate_source_contents

def provision_initial_credentials(app):
    utility = state / "upgrade-fixture-credentials"
    developer = "/Applications/Xcode.app/Contents/Developer"
    environment = dict(ui_environment, DEVELOPER_DIR=developer)
    sdk = run(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"], "Acceptance SDK lookup", environment=environment).decode().strip()
    run(["/usr/bin/xcrun", "--sdk", "macosx", "swiftc", "-target", "arm64-apple-macosx14.0", "-sdk", sdk,
         "-module-cache-path", str(state / "credential-cache"),
         str(root / "macos/AcceptanceTests/Support/UpgradeFixtureCredentials.swift"), "-o", str(utility)],
        "Owned credential utility compilation", timeout=120, environment=environment)
    certificate_directory = state / "credential-signing"
    certificate_directory.mkdir(mode=0o700)
    run(["/usr/bin/codesign", "--display", "--extract-certificates=" + str(certificate_directory / "cert"), str(app)],
        "Owned application certificate extraction")
    identity = run(["/usr/bin/openssl", "x509", "-inform", "DER", "-in", str(certificate_directory / "cert0"),
                    "-noout", "-fingerprint", "-sha1"], "Owned application certificate identity").decode().strip().split("=", 1)[-1].replace(":", "")
    require(re.fullmatch(r"[A-Fa-f0-9]{40}", identity), "The owner signing certificate could not be identified.")
    keychain = os.environ.get("DBEER_SIGNING_KEYCHAIN", str(pathlib.Path(pwd.getpwuid(os.getuid()).pw_dir) / "Library/Keychains/login.keychain-db"))
    run(["/usr/bin/codesign", "--force", "--timestamp=none", "--keychain", keychain, "--sign", identity,
         "--identifier", "dev.dbeer.upgrade-fixture-credentials", str(utility)], "Owned credential utility signing")
    run(["/usr/bin/codesign", "--verify", "--strict", str(utility)], "Owned credential utility verification")
    def credential_operation(engine, request, expected):
        result = subprocess.run([str(utility)], input=json.dumps(request).encode(), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                timeout=30, env=ui_environment)
        try:
            outcome = json.loads(result.stdout)
        except (json.JSONDecodeError, UnicodeDecodeError):
            outcome = {}
        diagnostic = {"engine": engine, "action": request["action"], "returnCode": result.returncode,
                      "resultJSON": isinstance(outcome, dict), "stderrPresent": bool(result.stderr)}
        if isinstance(outcome, dict):
            for key in ("created", "emptyVerified", "returnedData", "returnedEmptyData"):
                if isinstance(outcome.get(key), bool):
                    diagnostic[key] = outcome[key]
            for key in ("lookupStatus", "securityStatus"):
                if type(outcome.get(key)) is int:
                    diagnostic[key] = outcome[key]
            if outcome.get("stage") in ("request", "owned-manifest", "empty-item-lookup", "absent-item-lookup", "trusted-application",
                                         "trusted-utility", "create-access", "add-item"):
                diagnostic["stage"] = outcome["stage"]
        report.setdefault("initialCredentialOperations", []).append(diagnostic)
        require(result.returncode == 0 and isinstance(outcome, dict) and outcome.get(expected) is True,
                "Initial synthetic Keychain credential provisioning failed.")
    for engine, profile in known_profiles.items():
        require(profile["id"] in owned and keychain_presence(profile["id"]), "Initial credentials lack an app-created owned profile.")
        request = {"action": "inspect-empty", "profileID": profile["id"], "appPath": str(installed),
                   "ownedAccountsFile": str(owned_path)}
        credential_operation(engine, request, "emptyVerified")
        # The custom signed utility cannot edit the baseline item's owner ACL.
        # The system utility deletes only the just-verified empty, imported UUID;
        # create then independently requires absence before adding its secret.
        run(["/usr/bin/security", "delete-generic-password", "-s", service, "-a", profile["id"]],
            "Owned empty Keychain fixture deletion")
        request.update(action="create", databasePassword=pathlib.Path(connections[engine]["passwordFile"]).read_text())
        credential_operation(engine, request, "created")
    report["initialCredentialsProvisionedBeforeBaselineQueries"] = True

def install(app):
    assert_no_other_apps()
    if installed.exists():
        require(installed.resolve().parent == (state / "Applications").resolve(), "Unexpected installation path.")
        shutil.rmtree(installed)
    run(["/usr/bin/ditto", str(app), str(installed)], "Application installation")
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(installed)], "Installed application signature verification")

def bundle_contents(app):
    require(app.is_dir() and not app.is_symlink(), "An owned application bundle is not a directory.")
    contents = {}
    def visit(directory):
        for child in sorted(directory.iterdir()):
            relative = str(child.relative_to(app))
            if child.is_symlink():
                contents[relative] = ["symlink", os.readlink(child)]
            elif child.is_dir():
                contents[relative] = ["directory"]
                visit(child)
            else:
                require(child.is_file(), "An application bundle contains an unexpected file type.")
                contents[relative] = ["file", hashlib.sha256(child.read_bytes()).hexdigest()]
    visit(app)
    return contents

def cleanup_owned_bundles():
    evidence = {"paths": [str(path) for path in owned_app_paths], "unregisteredPaths": [], "removedPaths": []}
    report["applicationBundleCleanup"] = evidence
    executable_paths = {str(app / relative) for app in owned_app_paths
                        for relative in ("Contents/MacOS/DBeer", "Contents/Helpers/dbeer-core")}
    deadline = time.monotonic() + 8
    while any(item["path"] in executable_paths for item in process_table().values()):
        require(time.monotonic() < deadline, "An owned app/helper is still running; application bundles were retained.")
        time.sleep(0.2)
    evidence["ownedProcessesGone"] = True
    lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    for app in owned_app_paths:
        require(not app.is_symlink(), "An owned application path became a symlink; it was retained.")
        run([lsregister, "-u", str(app)], "Scoped application unregistration", environment=ui_environment)
        evidence["unregisteredPaths"].append(str(app))
        if app.exists():
            require(app.is_dir(), "An owned application path is not a bundle directory.")
            shutil.rmtree(app)
        require(not app.exists() and not app.is_symlink(), "An owned application bundle could not be removed.")
        evidence["removedPaths"].append(str(app))
    dump = run([lsregister, "-dump"], "Read-only LaunchServices registration verification", environment=ui_environment).decode(errors="replace")
    registered = {re.sub(r" \(0x[0-9A-Fa-f]+\)$", "", line.split(":", 1)[1].strip())
                  for line in dump.splitlines() if re.match(r"^\s*path:", line)}
    require(registered, "LaunchServices dump contained no readable path records.")
    evidence["registeredPathsRemaining"] = [str(app) for app in owned_app_paths if str(app) in registered]
    require(not evidence["registeredPathsRemaining"], "An owned application path remained registered in LaunchServices.")
    evidence["passed"] = True

def keychain_presence(identifier):
    result = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", service, "-a", identifier], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
    require(result.returncode in (0, 44), "Owned Keychain account metadata lookup failed.")
    return result.returncode == 0

def restore_input_source(snapshot):
    helper = root / "build/AcceptanceTests/input-source-guard"
    result = json.loads(run([str(helper), "restore", snapshot["originalID"], snapshot["asciiID"]],
                            "Scoped input source restoration", timeout=15, environment=ui_environment))
    require(result.get("status") in {"restored", "alreadyRestored"} and result.get("currentID") == snapshot["originalID"],
            "Input source restoration was not verified.")
    return result

def phase(name, build, engine=None, artifact=None):
    global active_app, active_output, active_helpers, active_input_source
    assert_no_other_apps()
    phase_directory = state / name
    phase_directory.mkdir(mode=0o700)
    input_guard = root / "build/AcceptanceTests/input-source-guard"
    require(input_guard.is_file(), "Build the scoped input source guard before launching an archived app.")
    input_source = json.loads(run([str(input_guard), "snapshot"], "Read-only input source snapshot",
                                 timeout=15, environment=ui_environment))
    require(all(isinstance(input_source.get(key), str) and input_source[key] for key in ("originalID", "asciiID")),
            "The input source snapshot is incomplete.")
    active_input_source = input_source
    private_json(phase_directory / "input-source-before.json", input_source)
    configuration = {"version": 1, "phase": name, "expectedBuild": str(build),
        "bundleIdentifier": bundle_id, "launchPolicy": "attach", "installAppPath": str(installed),
        "dataHome": str(data_directory), "profilesPath": str(profiles_path), "workspacePath": str(workspace_path),
        "stateDirectory": str(phase_directory), "resultFile": str(phase_directory / "result.json"),
        "portableProfilesPath": str(state / "portable-profiles.json"),
        "importProfileNames": ["Acceptance PostgreSQL " + run_id, "Acceptance MySQL " + run_id],
        "ownedAccountsFile": str(owned_path), "postgresql": connections["postgresql"], "mysql": connections["mysql"],
        "inputSourceOriginalID": input_source["originalID"], "inputSourceASCIIID": input_source["asciiID"]}
    if artifact is not None:
        configuration["expectedVersion"] = artifact["version"]
        configuration["artifactRole"] = "candidate" if name.startswith("candidate-") else "baseline"
        configuration["restoredDraftIDs"] = [value["id"] for value in expected_documents]
        configuration["restoredDraftTexts"] = [value["text"] for value in expected_documents]
        # The external UI runner receives no fixture credentials or paths to
        # their files. Only the installer can provision initial baseline items.
        configuration.pop("postgresql")
        configuration.pop("mysql")
    arguments = [str(installed / "Contents/MacOS/DBeer")]
    bootstrap = not candidate_mode and build == 5 and engine is not None
    if bootstrap:
        arguments.append("--connect-stdin")
    active_output = (phase_directory / "application.log").open("xb")
    active_app = subprocess.Popen(arguments, stdin=subprocess.PIPE if bootstrap else subprocess.DEVNULL,
                                  stdout=active_output, stderr=subprocess.STDOUT, env=app_environment)
    configuration["ownedPID"] = active_app.pid
    if engine:
        configuration.update(smokeProfileID=known_profiles[engine]["id"], smokeProfileEngine=engine)
    if bootstrap:
        settings = {key: value for key, value in connections[engine].items() if key != "passwordFile"}
        settings["password"] = pathlib.Path(connections[engine]["passwordFile"]).read_text()
        active_app.stdin.write(json.dumps(settings).encode())
        active_app.stdin.close()
        settings.clear()
    config_path = phase_directory / "config.json"
    private_json(config_path, configuration)
    evidence = {"phase": name, "build": build, "appPID": active_app.pid,
                "appPath": str(installed / "Contents/MacOS/DBeer"), "helperProcesses": [],
                "databaseSessionIDs": {kind: [] for kind in connections}, "postgresSleepObserved": False,
                "inputSourceBefore": input_source}
    active_helpers = {}
    stop = threading.Event()
    observer_errors = []
    def observe():
        try:
            while not stop.is_set():
                records = process_table()
                for pid, item in records.items():
                    if item["parentPID"] == active_app.pid and pathlib.Path(item["path"]).name == "dbeer-core":
                        require(item["path"] == str(installed / "Contents/Helpers/dbeer-core"), "The app started an unexpected helper path.")
                        active_helpers[pid] = item["path"]
                for kind in connections:
                    for row in database_sessions(kind):
                        require(len(row) == 3, "Unexpected observer record.")
                        identifier = int(row[0])
                        if identifier not in evidence["databaseSessionIDs"][kind]:
                            evidence["databaseSessionIDs"][kind].append(identifier)
                        if kind == "postgresql" and row[1] == "active" and row[2] == "PgSleep":
                            evidence["postgresSleepObserved"] = True
                stop.wait(0.15)
        except Exception as error:
            observer_errors.append(type(error).__name__ + ": " + str(error))
    observer = threading.Thread(target=observe, daemon=True)
    observer.start()
    print("Running archived app acceptance phase: " + name, flush=True)
    try:
        with (phase_directory / "ui-runner.log").open("xb") as output:
            tested = subprocess.run([str(runner), str(config_path)], stdout=output, stderr=subprocess.STDOUT,
                                    env=ui_environment, timeout=600)
        require(tested.returncode == 0, "XCUITest phase failed: " + name + "; inspect its private ui-runner.log.")
        active_app.wait(timeout=15)
        require(active_app.returncode == 0, "The archived application did not exit normally.")
    finally:
        evidence["applicationReturnCodeAtUICompletion"] = active_app.poll()
        evidence["uiRunnerReturnCodeAtCompletion"] = getattr(locals().get("tested"), "returncode", None)
        restoration_failure = None
        try:
            evidence["inputSourceRestoration"] = restore_input_source(input_source)
        except Exception as error:
            restoration_failure = error
            evidence["inputSourceRestoration"] = {"status": "failed", "error": type(error).__name__ + ": " + str(error)}
        stop.set()
        observer.join(timeout=25)
        evidence["helperProcesses"] = [{"pid": pid, "path": path} for pid, path in sorted(active_helpers.items())]
        private_json(phase_directory / "observer.json", evidence)
        if restoration_failure is not None:
            raise restoration_failure
    require(not observer.is_alive() and not observer_errors, "The independent process/database observer failed.")
    require(active_helpers, "The actual full application helper was not observed.")
    wait_no_sessions()
    records = process_table()
    require(all(pid not in records or records[pid]["path"] != path for pid, path in active_helpers.items()), "An owned helper remained after the archived app exited.")
    result = json.loads(pathlib.Path(configuration["resultFile"]).read_text())
    require(result.get("passed") is True and result.get("normalQuit") is True, "Missing completed UI acceptance evidence.")
    if name in {"build5-import", "baseline-import"}:
        require(result.get("importPreviewSeen") is True and result.get("importedProfilesConfirmed") is True, "The UI import preview/confirmation was not proved.")
        recover_owned_accounts()
    elif name == "candidate-disconnected":
        require(result.get("restoredDisconnected") is True and result.get("restoredDraftsVerified") is True,
                "Candidate did not prove disconnected restoration of the preserved drafts.")
        require(all(not values for values in evidence["databaseSessionIDs"].values()),
                "Candidate connected to a database during disconnected restoration.")
        semantic_preservation()
    else:
        require(result.get("connected") is True and result.get("querySucceeded") is True, "The archived app did not reconnect and execute its SQL query.")
        require(evidence["databaseSessionIDs"][engine], "No physical database session was independently observed.")
        if name == "build5-postgresql":
            require(all(result.get(key) is True for key in ("closeCancelled", "appAliveAfterCancel", "longQueryObserved", "stoppedAndClosed")) and evidence["postgresSleepObserved"], "The running-query Cancel/Stop-and-Continue close sequence was not proved.")
        semantic_preservation()
    result.update(evidence)
    result["normalExitCode"] = active_app.returncode
    result["helperAndDatabaseSessionsReaped"] = True
    report["phases"].append(result)
    private_json(report_path, report)
    active_output.close()
    active_output = None
    active_app = None
    active_helpers = {}
    active_input_source = None
    print("Archived app acceptance phase PASS: " + name, flush=True)

def candidate_update_acceptance():
    baseline, baseline_identity, candidate, candidate_identity, archive_input, archive_digest, candidate_input, candidate_contents = verified_candidate_pair()
    private_json(profiles_path, {"version": 2, "connections": [], "selectedConnectionId": None})
    private_json(workspace_path, {"version": 1, "documents": [], "selectedDocumentID": None, "history": [], "historyEnabled": True})
    private_json(owned_path, {"service": service, "accounts": [], "origin": "Initially empty isolated profile library"})
    portable = []
    for engine in ("postgresql", "mysql"):
        value = {key: item for key, item in connections[engine].items() if key != "passwordFile"}
        value["name"] = "Acceptance " + ("PostgreSQL " if engine == "postgresql" else "MySQL ") + run_id
        portable.append(value)
    private_json(state / "portable-profiles.json", {"version": 1, "profiles": portable})
    print("Private install/update state: " + str(state), flush=True)
    with (state / "runner-build.log").open("xb") as output:
        built = subprocess.run([str(runner), "--build-only"], stdout=output, stderr=subprocess.STDOUT,
                               env=ui_environment, timeout=600)
    require(built.returncode == 0, "The standalone XCUITest runner did not build.")
    install(baseline)
    phase("baseline-import", baseline_identity["build"], artifact=baseline_identity)
    global known_profiles, expected_documents
    known_profiles = load_profiles()
    provision_initial_credentials(baseline)
    expected_documents = [{"id": str(uuid.uuid4()).upper(), "title": "Preserved " + engine + " draft",
        "text": "SELECT 1; -- preserved " + engine + " draft", "profileID": known_profiles[engine]["id"]}
        for engine in ("postgresql", "mysql")]
    private_json(workspace_path, {"version": 1, "documents": expected_documents,
        "selectedDocumentID": expected_documents[0]["id"], "history": [], "historyEnabled": True})
    phase("baseline-postgresql", baseline_identity["build"], "postgresql", baseline_identity)
    phase("baseline-mysql", baseline_identity["build"], "mysql", baseline_identity)
    baseline_bytes = {path.name: path.read_bytes() for path in (profiles_path, workspace_path)}
    baseline_versions = {name: json.loads(data)["version"] for name, data in baseline_bytes.items()}
    for path in secret_files:
        path.unlink()
    for settings in connections.values():
        settings.pop("passwordFile", None)
    report["passwordFilesRemovedBeforeCandidate"] = True
    install(candidate)
    phase("candidate-disconnected", candidate_identity["build"], artifact=candidate_identity)
    migrations = []
    for path in (profiles_path, workspace_path):
        version = json.loads(path.read_text())["version"]
        expected_version = 5 if path == profiles_path else 10
        require(version == expected_version, "The candidate did not publish the current persistent format.")
        if baseline_versions[path.name] < version:
            backups = list(support.glob(path.name + ".v" + str(baseline_versions[path.name]) + "*.backup"))
            exact = [backup for backup in backups if backup.read_bytes() == baseline_bytes[path.name]]
            require(exact and all(backup.stat().st_mode & 0o077 == 0 for backup in exact),
                    "A migration did not preserve its exact private baseline backup.")
        migrations.append({"file": path.name, "fromVersion": baseline_versions[path.name], "toVersion": version,
                           "exactPrivateBackup": baseline_versions[path.name] < version})
    report["migrations"] = migrations
    phase("candidate-postgresql", candidate_identity["build"], "postgresql", candidate_identity)
    phase("candidate-mysql", candidate_identity["build"], "mysql", candidate_identity)
    verify_signed_app(installed)
    require(bundle_contents(installed) == candidate_contents and bundle_contents(candidate_input) == candidate_contents,
            "The candidate or installed bundle changed during acceptance.")
    require(hashlib.sha256(archive_input.read_bytes()).hexdigest() == archive_digest,
            "The source release archive changed during acceptance.")
    report["sourceArchiveAndCandidateUnchanged"] = True
    report["profileAndDraftSemanticsPreserved"] = True
    report["candidateReceivedNoPasswordsOrStartupFlag"] = True

def legacy_archive_acceptance():
    global known_profiles, expected_documents
    apps = verified_archives()
    private_json(profiles_path, {"version": 2, "connections": [], "selectedConnectionId": None})
    private_json(workspace_path, {"version": 1, "documents": [], "selectedDocumentID": None, "history": [], "historyEnabled": True})
    private_json(owned_path, {"service": service, "accounts": [], "origin": "Initially empty isolated profile library"})
    portable = []
    for engine in ("postgresql", "mysql"):
        item = {key: value for key, value in connections[engine].items() if key != "passwordFile"}
        item["name"] = "Acceptance " + ("PostgreSQL " if engine == "postgresql" else "MySQL ") + run_id
        portable.append(item)
    private_json(state / "portable-profiles.json", {"version": 1, "profiles": portable})
    print("Private install/update state: " + str(state), flush=True)
    with (state / "runner-build.log").open("xb") as output:
        built = subprocess.run([str(runner), "--build-only"], stdout=output, stderr=subprocess.STDOUT,
                               env=ui_environment, timeout=600)
    require(built.returncode == 0, "The standalone XCUITest runner did not build.")
    install(apps[5])
    phase("build5-import", 5)
    known_profiles = load_profiles()
    require(all(keychain_presence(value["id"]) for value in known_profiles.values()), "UI import did not create the owned empty Keychain accounts.")
    expected_documents = [{"id": str(uuid.uuid4()).upper(), "title": "Preserved " + engine + " draft", "text": "SELECT 1;", "profileID": known_profiles[engine]["id"]} for engine in ("postgresql", "mysql")]
    private_json(workspace_path, {"version": 1, "documents": expected_documents,
        "selectedDocumentID": expected_documents[0]["id"], "history": [], "historyEnabled": True})
    phase("build5-postgresql", 5, "postgresql")
    phase("build5-mysql", 5, "mysql")
    for path in secret_files:
        path.unlink()
    for settings in connections.values():
        settings.pop("passwordFile", None)
    report["passwordFilesRemovedBeforeBuild6"] = True
    install(apps[6])
    phase("build6-postgresql", 6, "postgresql")
    phase("build6-mysql", 6, "mysql")
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(installed)], "Final installed application signature verification")
    original_contents = bundle_contents(apps[6])
    require(bundle_contents(installed) == original_contents, "The installed build 6 file/symlink contents changed during acceptance.")
    report["installedBuild6Unchanged"] = {"strictSignature": True, "completeFileAndSymlinkComparison": True,
        "entryCount": len(original_contents)}
    report["profileAndDraftSemanticsPreserved"] = True
    report["build6ReceivedNoPasswordsOrStartupFlag"] = True

try:
    if candidate_mode:
        candidate_update_acceptance()
    else:
        legacy_archive_acceptance()
except Exception as error:
    failure = type(error).__name__ + ": " + str(error)
finally:
    if active_app is not None and active_app.poll() is None:
        # Failure cleanup only; this can never count as a successful normal Quit.
        active_app.terminate()
        try:
            active_app.wait(timeout=8)
        except subprocess.TimeoutExpired:
            active_app.kill()
            active_app.wait(timeout=8)
    if active_output is not None:
        active_output.close()
    if active_input_source is not None:
        try:
            report["inputSourceRestoreAfterFailureCleanup"] = restore_input_source(active_input_source)
        except Exception as error:
            message = type(error).__name__ + ": " + str(error)
            report["inputSourceRestoreAfterFailureCleanup"] = {"status": "failed", "error": message}
            failure = failure or message
    try:
        recover_owned_accounts()
        for identifier in sorted(owned):
            deleted = subprocess.run(["/usr/bin/security", "delete-generic-password", "-s", service, "-a", identifier], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
            require(deleted.returncode in (0, 44) and not keychain_presence(identifier), "An owned Keychain fixture account could not be removed.")
        report["ownedKeychainAccountsRemoved"] = sorted(owned)
        wait_no_sessions()
        report["noFixtureDatabaseSessionsRemain"] = True
    except Exception as error:
        failure = failure or (type(error).__name__ + ": " + str(error))
        report["cleanupError"] = type(error).__name__ + ": " + str(error)
    for path in secret_files:
        if path.exists():
            path.unlink()
    try:
        cleanup_owned_bundles()
    except Exception as error:
        message = type(error).__name__ + ": " + str(error)
        report.setdefault("applicationBundleCleanup", {})["error"] = message
        failure = failure or message
    owner_after = {name: file_fingerprint(path) for name, path in owner_paths.items()}
    report["ownerDataAfter"] = owner_after
    report["ownerDataUnchanged"] = owner_before == owner_after
    if owner_before != owner_after:
        failure = failure or "Owner profile/document file fingerprint changed; no automatic restore was performed."
    try:
        preferences_after = preferences_snapshot(state / "preferences-after.plist")
        missing = object()
        changed_keys = sorted(key for key in preferences_before.keys() | preferences_after.keys()
                              if preferences_before.get(key, missing) != preferences_after.get(key, missing))
        report["preferenceChangedKeys"] = changed_keys
        report["appearanceThemeUnchanged"] = preferences_before.get("appearanceTheme", missing) == preferences_after.get("appearanceTheme", missing)
        if not report["appearanceThemeUnchanged"]:
            failure = failure or "The appearance theme preference changed; no automatic restore was performed."
    except Exception as error:
        failure = failure or (type(error).__name__ + ": " + str(error))
    report["status"] = "FAIL" if failure else "PASS"
    report["completedAtUTC"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    if failure:
        report["failure"] = failure
    private_json(report_path, report)
    print(json.dumps({"status": report["status"], "report": str(report_path), "phasesPassed": len(report["phases"]),
                      "ownerDataUnchanged": report["ownerDataUnchanged"], "preferenceChangedKeys": report.get("preferenceChangedKeys", []),
                      "failure": failure}), flush=True)
sys.exit(1 if failure else 0)
