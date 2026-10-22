#!/usr/bin/env python3
"""Owned signed-application SSH acceptance fixture and external observer."""
import base64
import datetime
import fcntl
import hashlib
import json
import os
import pathlib
import plistlib
import pwd
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid

ROOT = pathlib.Path(sys.argv[1]).resolve()
SERVICE = "dev.dbeer.connections"
BUNDLE = "dev.dbeer.app"
DOCKER = shutil.which("docker")

class Failure(Exception):
    pass

def require(condition, message):
    if not condition:
        raise Failure(message)

def command(arguments, description, timeout=45, data=None, environment=None):
    result = subprocess.run(arguments, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            timeout=timeout, env=environment)
    require(result.returncode == 0, description + " failed; private fixture diagnostics were suppressed.")
    return result.stdout

def private_json(path, value):
    descriptor, name = tempfile.mkstemp(prefix=".fixture-", dir=path.parent)
    with os.fdopen(descriptor, "w") as output:
        json.dump(value, output, indent=2, sort_keys=True)
        output.write("\n")
        output.flush()
        os.fsync(output.fileno())
    os.replace(name, path)

def processes():
    result = {}
    for line in command(["/bin/ps", "-ww", "-axo", "pid=,ppid=,comm="], "Read-only process inventory").decode().splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) == 3:
            result[int(fields[0])] = {"parent": int(fields[1]), "path": fields[2]}
    return result

def process_arguments():
    # Arguments never enter logs/evidence. Extract only owned process roles and
    # the loopback forwarding port, which cannot contain authentication secrets.
    result = {}
    for line in command(["/bin/ps", "-ww", "-axo", "pid=,args="], "Owned SSH process role observation").decode().splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) == 2:
            result[int(fields[0])] = fields[1]
    return result

def fingerprint(path):
    if not path.exists():
        return None
    require(path.is_file() and not path.is_symlink(), "Owner data path is not a regular file.")
    return hashlib.sha256(path.read_bytes()).hexdigest()

owner_home = pathlib.Path(pwd.getpwuid(os.getuid()).pw_dir)
owner_support = owner_home / "Library/Application Support/DBeer"
owner_paths = [owner_support / "connections.json", owner_support / "workspace.json"]
owner_before = {str(path): fingerprint(path) for path in owner_paths}
unexpected = [pid for pid, row in processes().items() if pathlib.Path(row["path"]).name in {"DBeer", "dbeer-core"}]
require(not unexpected, "A DBeer app/helper outside this fixture is running; it was left untouched.")
base = ROOT / "build/SSHAcceptance"
base.mkdir(parents=True, exist_ok=True)
state = pathlib.Path(tempfile.mkdtemp(prefix="run.", dir=base))
state.chmod(0o700)
fixture = state / "Fixture"
fixture.mkdir(mode=0o700)
data_home = state / "UserData"
support = data_home / "Library/Application Support/DBeer"
support.mkdir(parents=True, mode=0o700)
installed = state / "Applications/DBeer.app"
installed.parent.mkdir(mode=0o700)
profile_id = str(uuid.uuid4()).upper()
credential_helper = ROOT / "build/AcceptanceTests/ssh-fixture-credentials"
input_guard = ROOT / "build/AcceptanceTests/input-source-guard"
launcher = ROOT / "build/AcceptanceTests/ssh-application-launcher"
runner = ROOT / "macos/AcceptanceTests/run.sh"
report_path = state / "report.json"
report = {"version": 1, "status": "RUNNING", "profileID": profile_id,
          "stateDirectory": str(state), "installAppPath": str(installed),
          "ownerDataBefore": owner_before, "fixtureDatabasePublished": False}
containers = []
network = None
app_pid = None
owned_processes = {}
input_snapshot = None
credential_creation_started = False
trust_alias = None
trust_path = owner_support / "ssh_known_hosts"
trust_before_exists = trust_path.exists()
trust_before_bytes = trust_path.read_bytes() if trust_before_exists else b""
observer_stop = threading.Event()
observer_errors = []
report["observerErrors"] = observer_errors
observer_thread = None
failure = None
public_names = ("HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "SHELL", "__CF_USER_TEXT_ENCODING")
public_environment = {key: os.environ[key] for key in public_names if key in os.environ}
ui_environment = dict(public_environment, PATH="/usr/bin:/bin:/usr/sbin:/sbin")

def wait(predicate, description, seconds=15):
    deadline = time.monotonic() + seconds
    while not predicate():
        require(time.monotonic() < deadline, description)
        time.sleep(0.15)

def credential(action, password=None, passphrase=None):
    if action == "delete":
        # security(1) performs the owner-authorized delete even when the item's
        # read ACL deliberately trusts only the signed application copy.
        for account in (profile_id, profile_id + ":sshPassphrase"):
            removed = subprocess.run(["/usr/bin/security", "delete-generic-password", "-s", SERVICE, "-a", account],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
            require(removed.returncode in (0, 44), "An owned synthetic Keychain account could not be deleted.")
            remaining = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", SERVICE, "-a", account],
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
            require(remaining.returncode == 44, "An owned synthetic Keychain account remained after deletion.")
        return {"deleted": True}
    request = {"action": action, "profileID": profile_id, "appPath": str(installed)}
    if action == "create":
        request.update(databasePassword=password, passphrase=passphrase)
    return json.loads(command([str(credential_helper)], "Owned credential " + action,
                              data=json.dumps(request).encode(), timeout=30))

def database_rows():
    # Only fixed, nonsecret classifications leave the observer. SQL text and
    # query values are neither copied into evidence nor printed on failure.
    query = """SELECT pid,state,COALESCE(wait_event,''),
        CASE WHEN query LIKE '%dbeer_ssh_ui_sleep%' THEN 'sleep'
             WHEN query LIKE '%dbeer_ssh_ui_other_tab%' THEN 'other'
             WHEN query LIKE '%dbeer_ssh_ui_recovered%' THEN 'recovered'
             WHEN query LIKE '%dbeer_ssh_ui_second_after_stop%' THEN 'secondAfterStop'
             ELSE '' END
        FROM pg_stat_activity WHERE datname='dbeer' AND usename='dbeer'
        AND application_name='DBeer' ORDER BY pid"""
    output = command([DOCKER, "exec", database, "psql", "-X", "-U", "dbeer", "-d", "dbeer", "-At", "-F", "\t", "-c", query],
                     "Fixture backend state observation", timeout=10).decode()
    return [line.split("\t") for line in output.splitlines() if line]

def trust_lines():
    if not trust_path.exists():
        return []
    return [line for line in trust_path.read_text().splitlines() if line.split() and line.split()[0] == trust_alias]

def restore_input():
    if input_snapshot is None:
        return
    result = json.loads(command([str(input_guard), "restore", input_snapshot["originalID"], input_snapshot["asciiID"]],
                                "Conditional input source restoration", environment=ui_environment))
    require(result.get("status") in {"restored", "alreadyRestored"}, "Original input source could not be conditionally restored.")
    require(result.get("currentID") == input_snapshot["originalID"], "Input source restoration was not verified.")
    report["inputSourceRestoration"] = result

def cleanup_trust():
    if trust_alias is None or not trust_path.exists():
        report["ownedTrustRemoved"] = True
        return
    lock_path = pathlib.Path(str(trust_path) + ".lock")
    with lock_path.open("a+b") as lock:
        deadline = time.monotonic() + 3
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                require(time.monotonic() < deadline, "Scoped SSH trust cleanup could not acquire the trust-store lock.")
                time.sleep(0.02)
        original = trust_path.read_bytes()
        remaining = b"".join(line for line in original.splitlines(keepends=True)
                             if not line.split() or line.split()[0] != trust_alias.encode())
        if remaining != original:
            # Go's atomic trust writer normalizes blank lines. Restore exact
            # original bytes only if no unrelated concurrent records changed.
            normalized_before = b"\n".join(line for line in trust_before_bytes.splitlines() if line.strip())
            if b"\n".join(line for line in remaining.splitlines() if line.strip()) == normalized_before:
                remaining = trust_before_bytes
            if not remaining.strip() and not trust_before_exists:
                trust_path.unlink()
            else:
                descriptor, temporary = tempfile.mkstemp(prefix=".ssh-fixture-cleanup-", dir=trust_path.parent)
                with os.fdopen(descriptor, "wb") as output:
                    output.write(remaining)
                    output.flush()
                    os.fsync(output.fileno())
                os.replace(temporary, trust_path)
        fcntl.flock(lock, fcntl.LOCK_UN)
    report["ownedTrustRemoved"] = not trust_lines()

try:
    require(DOCKER and all(path.is_file() for path in (credential_helper, input_guard, launcher, runner)),
            "Build the standalone acceptance runner, application launcher, and credential helper first.")
    source = ROOT / "build/DBeer.app"
    require(source.is_dir(), "Build the signed native DBeer.app before SSH UI acceptance.")
    command(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(source)], "Source application signature verification")
    command(["/usr/bin/ditto", str(source), str(installed)], "Owned signed application copy")
    command(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(installed)], "Copied application signature verification")
    metadata = plistlib.loads((installed / "Contents/Info.plist").read_bytes())
    require(metadata.get("CFBundleIdentifier") == BUNDLE, "Unexpected application bundle identity.")
    version, build = metadata["CFBundleShortVersionString"], metadata["CFBundleVersion"]
    require(version == (ROOT / "VERSION").read_text().strip() and build == (ROOT / "BUILD_NUMBER").read_text().strip(),
            "Signed application metadata does not match the current source metadata.")
    password = os.urandom(24).hex()
    passphrase = os.urandom(24).hex()
    (fixture / "password").write_text(password + "\n")
    # OpenSSH reads the generated key encryption passphrase from a private pipe.
    command(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-f", str(fixture / "id_encrypted")],
            "Encrypted SSH fixture key generation", data=(passphrase + "\n" + passphrase + "\n").encode())
    encrypted_check = subprocess.run(["/usr/bin/ssh-keygen", "-y", "-P", "", "-f", str(fixture / "id_encrypted")],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
    require(encrypted_check.returncode != 0, "The selected fixture private key is not encrypted.")
    report["privateKeyEncrypted"] = True
    command(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(fixture / "ssh_host_ed25519_key")], "SSH host key generation")
    public_blob = (fixture / "ssh_host_ed25519_key.pub").read_text().split()[1]
    host_fingerprint = "SHA256:" + base64.b64encode(hashlib.sha256(base64.b64decode(public_blob)).digest()).decode().rstrip("=")
    (fixture / "Dockerfile").write_text("FROM alpine:3.22\nRUN apk add --no-cache openssh-server && adduser -D -s /bin/sh dbeer\nCOPY start-sshd /usr/local/bin/start-sshd\nENTRYPOINT [\"/bin/sh\",\"/usr/local/bin/start-sshd\"]\n")
    (fixture / ".dockerignore").write_text("*\n!Dockerfile\n!start-sshd\n")
    (fixture / "start-sshd").write_text("""set -eu
mkdir -p /home/dbeer/.ssh /run/sshd
cp /fixtures/id_encrypted.pub /home/dbeer/.ssh/authorized_keys
chown -R dbeer:dbeer /home/dbeer/.ssh
chmod 700 /home/dbeer/.ssh
chmod 600 /home/dbeer/.ssh/authorized_keys
printf 'dbeer:%s\\n' "$(cat /fixtures/password)" | chpasswd
cp /fixtures/ssh_host_ed25519_key /run/sshd/host_key
chmod 600 /run/sshd/host_key
exec /usr/sbin/sshd -D -e -h /run/sshd/host_key -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o AllowTcpForwarding=yes -o PermitRootLogin=no -o PerSourcePenalties=no -o MaxStartups=100
""")
    image = command([DOCKER, "build", "--quiet", str(fixture)], "Owned SSH fixture image build", timeout=180).decode().strip().splitlines()[-1]
    network = command([DOCKER, "network", "create", "dbeer-ssh-ui-" + state.name], "Owned SSH fixture network").decode().strip()
    bastion = command([DOCKER, "run", "--detach", "--rm", "--network", network, "--publish", "127.0.0.1::22",
                       "--mount", "type=bind,source=" + str(fixture) + ",target=/fixtures,readonly", image], "SSH fixture startup").decode().strip()
    containers.append(bastion)
    mapping = command([DOCKER, "port", bastion, "22/tcp"], "Owned SSH port lookup").decode().strip()
    ssh_port = int(mapping.rsplit(":", 1)[1])
    database = command([DOCKER, "run", "--detach", "--rm", "--network", network,
                        "--network-alias", "postgres.ssh-ui.invalid", "--mount", "type=bind,source=" + str(fixture) + ",target=/fixtures,readonly",
                        "--env", "POSTGRES_DB=dbeer", "--env", "POSTGRES_USER=dbeer", "--env", "POSTGRES_PASSWORD_FILE=/fixtures/password",
                        os.environ.get("DBEER_TEST_POSTGRES_IMAGE", "postgres:17")], "Private PostgreSQL fixture startup").decode().strip()
    containers.append(database)
    def ready():
        return subprocess.run([DOCKER, "exec", database, "pg_isready", "-U", "dbeer", "-d", "dbeer"],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10).returncode == 0
    wait(ready, "Private PostgreSQL fixture did not become ready.", 90)
    published = json.loads(command([DOCKER, "inspect", "--format", "{{json .NetworkSettings.Ports}}", database], "Database exposure check"))
    require(not any(published.values()), "Fixture database unexpectedly has a directly published port.")
    try:
        direct = socket.create_connection(("postgres.ssh-ui.invalid", 5432), timeout=0.3)
    except OSError:
        report["directDatabaseUnreachable"] = True
    else:
        direct.close()
        raise Failure("Private fixture database is directly reachable from the app host.")
    endpoint = "[127.0.0.1]:" + str(ssh_port)
    trust_alias = "dbeer-profile-" + hashlib.sha256((profile_id + "\0" + endpoint).encode()).hexdigest()
    require(not trust_lines(), "Unexpected trust record already exists for the new fixture profile.")
    library = {"version": 4, "selectedConnectionId": profile_id, "connections": [{
        "id": profile_id, "name": "SSH Acceptance " + state.name, "engine": "postgresql", "host": "postgres.ssh-ui.invalid",
        "port": 5432, "database": "dbeer", "user": "dbeer", "sslMode": "disable", "policy": {"environment": "development", "readOnly": False},
        "ssh": {"host": "127.0.0.1", "port": ssh_port, "user": "dbeer", "authMethod": "privateKey", "identityFile": str(fixture / "id_encrypted")}}]}
    private_json(support / "connections.json", library)
    for account in (profile_id, profile_id + ":sshPassphrase"):
        existing = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", SERVICE, "-a", account],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
        require(existing.returncode == 44, "A fixture credential account already exists; it was left untouched.")
    credential_creation_started = True
    require(credential("create", password, passphrase).get("created") is True, "Synthetic Keychain credential provisioning failed.")
    password = passphrase = None
    input_snapshot = json.loads(command([str(input_guard), "snapshot"], "Input source snapshot", environment=ui_environment))
    private_json(state / "input-source-before.json", input_snapshot)
    launch_configuration = state / "launch.json"
    launch_result = state / "launch-result.json"
    private_json(launch_configuration, {"appPath": str(installed), "dataHome": str(data_home), "resultFile": str(launch_result)})
    command([str(launcher), str(launch_configuration)], "LaunchServices signed application launch", environment=ui_environment)
    launched = json.loads(launch_result.read_text())
    app_pid = int(launched["pid"])
    app_binary = str(installed / "Contents/MacOS/DBeer")
    helper_binary = str(installed / "Contents/Helpers/dbeer-core")
    require(processes().get(app_pid, {}).get("path") == app_binary, "LaunchServices launched a different application path.")
    owned_processes[app_pid] = app_binary
    configuration = {"version": 1, "phase": "ssh-lifecycle", "expectedVersion": version, "expectedBuild": build,
        "bundleIdentifier": BUNDLE, "launchPolicy": "attach", "installAppPath": str(installed), "ownedPID": app_pid,
        "smokeProfileID": profile_id, "smokeProfileEngine": "postgresql", "sshHost": "127.0.0.1", "sshPort": ssh_port,
        "sshFingerprint": host_fingerprint, "inputSourceOriginalID": input_snapshot["originalID"],
        "inputSourceASCIIID": input_snapshot["asciiID"], "resultFile": str(state / "result.json"),
        "disconnectEvidenceFile": str(state / "disconnect-evidence.json")}
    private_json(state / "config.json", configuration)
    observed = {"databasePIDs": [], "noDatabaseTrafficBeforeTrust": True, "hostKeyPinned": False,
        "longQueryActive": False, "otherTabWorkedDuringLongQuery": False, "queryRecoveredAfterStop": False,
        "profileDisconnectedWhileAppAlive": False, "distinctTemporaryNamespaces": False,
        "sshTunnelProcessSeen": False, "tunnelStoppedWhileAppAlive": False, "ownedListenerClosedWhileAppAlive": False}
    report["observer"] = observed
    def observe():
        stage = "initialization"
        try:
            while not observer_stop.is_set():
                stage = "process-inventory"
                table = processes()
                changed = True
                while changed:
                    changed = False
                    for pid, row in table.items():
                        parent = row["parent"]
                        parent_is_owned = parent in owned_processes and table.get(parent, {}).get("path") == owned_processes[parent]
                        if pid not in owned_processes and parent_is_owned:
                            require(row["path"] in {helper_binary, "/usr/bin/ssh", "/usr/bin/ssh-keyscan"},
                                    "Owned app started an unexpected child process: " + row["path"])
                            owned_processes[pid] = row["path"]
                            changed = True
                stage = "process-roles"
                arguments = process_arguments()
                live_tunnel_processes = []
                for pid, path in owned_processes.items():
                    if table.get(pid, {}).get("path") != path:
                        continue
                    is_watchdog = path == helper_binary and " --ssh-watchdog " in arguments.get(pid, "")
                    if path == "/usr/bin/ssh" or is_watchdog:
                        live_tunnel_processes.append(pid)
                        observed["sshTunnelProcessSeen"] = True
                        match = re.search(r"(?:^|\s)-D\s+127\.0\.0\.1:(\d+)(?:\s|$)", arguments.get(pid, ""))
                        if match:
                            observed["ownedSOCKSPort"] = int(match.group(1))
                stage = "host-key-record"
                lines = trust_lines()
                if lines:
                    require(len(lines) == 1 and lines[0].split()[1:] == ["ssh-ed25519", public_blob], "Accepted SSH host key differs from the fixture fingerprint.")
                    observed["hostKeyPinned"] = True
                stage = "database-sessions"
                rows = database_rows()
                if rows and not observed["hostKeyPinned"]:
                    observed["noDatabaseTrafficBeforeTrust"] = False
                    raise Failure("Database traffic occurred before SSH host-key acceptance.")
                for row in rows:
                    require(len(row) == 4, "Unexpected backend observer record.")
                    pid, status, event, kind = int(row[0]), row[1], row[2], row[3]
                    if pid not in observed["databasePIDs"]:
                        observed["databasePIDs"].append(pid)
                    if status == "active" and event == "PgSleep" and kind == "sleep":
                        observed["longQueryActive"] = True
                    if kind == "recovered" and status == "idle":
                        observed["queryRecoveredAfterStop"] = True
                sleeping = any(row[1] == "active" and row[2] == "PgSleep" and row[3] == "sleep" for row in rows)
                if sleeping and any(row[3] == "other" and row[1] == "idle" for row in rows):
                    observed["otherTabWorkedDuringLongQuery"] = True
                if rows:
                    stage = "temporary-namespaces"
                    query = "SELECT count(DISTINCT n.relnamespace) FROM pg_class n WHERE n.relname IN ('dbeer_ssh_ui_first','dbeer_ssh_ui_second') AND n.relpersistence='t'"
                    count = command([DOCKER, "exec", database, "psql", "-X", "-U", "dbeer", "-d", "dbeer", "-At", "-c", query], "Independent temporary namespace observation", timeout=10).decode().strip()
                    observed["distinctTemporaryNamespaces"] |= count == "2"
                if not rows and observed["queryRecoveredAfterStop"] and app_pid in table:
                    stage = "disconnect-acknowledgement"
                    observed["profileDisconnectedWhileAppAlive"] = True
                    if observed["sshTunnelProcessSeen"] and not live_tunnel_processes:
                        observed["tunnelStoppedWhileAppAlive"] = True
                        port = observed.get("ownedSOCKSPort")
                        if port is not None:
                            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
                                probe.settimeout(0.15)
                                listener_closed = probe.connect_ex(("127.0.0.1", port)) != 0
                                observed["ownedListenerClosedWhileAppAlive"] |= listener_closed
                            # XCTest waits for this acknowledgement before it
                            # sends Cmd-Q, so Quit cannot masquerade as profile
                            # disconnect cleanup in the external evidence.
                            disconnect_evidence = pathlib.Path(configuration["disconnectEvidenceFile"])
                            if listener_closed and not disconnect_evidence.exists() and app_pid in processes():
                                private_json(disconnect_evidence, {
                                    "profileID": profile_id, "ownedPID": app_pid,
                                    "tunnelStoppedWhileAppAlive": True,
                                    "ownedListenerClosedWhileAppAlive": True,
                                    "databaseSessionsGoneWhileAppAlive": True,
                                    "observedAtUTC": datetime.datetime.now(datetime.timezone.utc).isoformat()})
                observed["completedPolls"] = observed.get("completedPolls", 0) + 1
                observed["lastCompletedPollUTC"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
                observer_stop.wait(0.12)
        except Exception as error:
            # TimeoutExpired includes command argv (and observer SQL) in its
            # default string. Keep only the sanitized operation and error type.
            message = str(error) if isinstance(error, Failure) else type(error).__name__
            observer_errors.append(stage + ": " + message)
            private_json(state / "observer-errors.json", {"errors": observer_errors})
    observer_thread = threading.Thread(target=observe, daemon=True)
    observer_thread.start()
    print("Running signed-app SSH UI acceptance; private artifacts: " + str(state), flush=True)
    with (state / "ui-runner.log").open("xb") as output:
        tested = subprocess.run([str(runner), "--ssh", str(state / "config.json")], stdout=output, stderr=subprocess.STDOUT,
                                env=ui_environment, timeout=600)
    require(tested.returncode == 0, "SSH XCTest failed; inspect the private ui-runner.log.")
    wait(lambda: app_pid not in processes(), "Signed app did not quit normally after the UI phase.")
    observer_stop.set()
    observer_thread.join(timeout=15)
    require(not observer_errors, "External SSH observer failed: " + "; ".join(observer_errors))
    evidence = json.loads((state / "result.json").read_text())
    report["uiEvidence"] = evidence
    disconnect_evidence = pathlib.Path(configuration["disconnectEvidenceFile"])
    require(disconnect_evidence.is_file(), "The external observer did not acknowledge profile disconnect before Quit.")
    report["disconnectEvidence"] = json.loads(disconnect_evidence.read_text())
    require(evidence.get("passed") is True and evidence.get("normalQuit") is True, "UI evidence did not report normal completion.")
    require(all(observed[key] for key in ("noDatabaseTrafficBeforeTrust", "hostKeyPinned", "longQueryActive", "otherTabWorkedDuringLongQuery", "queryRecoveredAfterStop", "profileDisconnectedWhileAppAlive", "distinctTemporaryNamespaces", "tunnelStoppedWhileAppAlive", "ownedListenerClosedWhileAppAlive")),
            "External backend observer did not confirm every SSH lifecycle requirement.")
    first, second = evidence.get("firstBackendPID"), evidence.get("secondBackendPID")
    require(isinstance(first, int) and isinstance(second, int) and first != second and first in observed["databasePIDs"] and second in observed["databasePIDs"], "UI backend identities did not match distinct observed physical sessions.")
    # sshd -e writes authentication events to stderr; Docker preserves that
    # stream. Inspect both privately without copying raw diagnostics to logs.
    authentication_log = subprocess.run([DOCKER, "logs", bastion], stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, timeout=30)
    require(authentication_log.returncode == 0, "SSH authentication observation failed.")
    server_log = (authentication_log.stdout + authentication_log.stderr).decode(errors="replace")
    require("Accepted publickey for dbeer" in server_log, "The bastion did not confirm private-key authentication.")
    report["encryptedKeyAuthenticationObserved"] = True
    require(not database_rows(), "Profile disconnect left database sessions open.")
except Exception as error:
    failure = type(error).__name__ + ": " + str(error)
finally:
    observer_stop.set()
    if observer_thread:
        observer_thread.join(timeout=15)
    report["observerErrors"] = list(observer_errors)
    report["observerThreadStopped"] = observer_thread is None or not observer_thread.is_alive()
    cleanup_errors = []
    def cleanup_step(name, action):
        try:
            action()
        except Exception as error:
            cleanup_errors.append(name + ": " + type(error).__name__ + ": " + str(error))
    def cleanup_processes():
        table = processes()
        if app_pid in table and table[app_pid]["path"] == str(installed / "Contents/MacOS/DBeer"):
            os.kill(app_pid, signal.SIGTERM)
            deadline = time.monotonic() + 8
            while app_pid in processes() and time.monotonic() < deadline:
                time.sleep(0.1)
            if app_pid in processes():
                os.kill(app_pid, signal.SIGKILL)
        def owned_gone():
            table = processes()
            return not any(table.get(pid, {}).get("path") == path for pid, path in owned_processes.items())
        wait(owned_gone, "An owned app/helper/SSH process remained after fixture termination.", 15)
        report["ownedProcessesGone"] = True
    def cleanup_credentials():
        if credential_creation_started:
            require(credential("delete").get("deleted") is True, "Owned synthetic credentials could not be deleted.")
            report["ownedKeychainAccountsRemoved"] = [profile_id, profile_id + ":sshPassphrase"]
    def verify_owner_data():
        after = {str(path): fingerprint(path) for path in owner_paths}
        report["ownerDataAfter"] = after
        require(after == owner_before, "Owner profiles/documents changed; no automatic restore was attempted.")
        report["ownerDataUnchanged"] = True
    def cleanup_application():
        require(report.get("ownedProcessesGone") is True, "Owned application copy was retained because process cleanup failed.")
        if installed.exists():
            lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
            command([lsregister, "-u", str(installed)], "Owned copied app unregistration", environment=ui_environment)
            shutil.rmtree(installed)
        report["ownedAppCopyRemoved"] = True
    cleanup_step("processes", cleanup_processes)
    cleanup_step("inputSource", restore_input)
    cleanup_step("credentials", cleanup_credentials)
    cleanup_step("trust", cleanup_trust)
    cleanup_step("ownerData", verify_owner_data)
    cleanup_step("applicationCopy", cleanup_application)
    for identifier in reversed(containers):
        cleanup_step("container", lambda identifier=identifier: command([DOCKER, "rm", "--force", identifier], "Owned container cleanup", timeout=30))
    if network:
        cleanup_step("network", lambda: command([DOCKER, "network", "rm", network], "Owned network cleanup", timeout=30))
    if cleanup_errors:
        report["cleanupErrors"] = cleanup_errors
        failure = failure or "; ".join(cleanup_errors)
    shutil.rmtree(fixture, ignore_errors=True)
    report["status"] = "FAIL" if failure else "PASS"
    if failure:
        report["failure"] = failure
    private_json(report_path, report)
    print(report["status"] + ": signed-app SSH UI acceptance; evidence: " + str(report_path), flush=True)
    if failure:
        print(failure, file=sys.stderr)
        sys.exit(1)
