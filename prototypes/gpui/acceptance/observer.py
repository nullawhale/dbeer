"""Separate exact helper/physical sessions on Task 30's owned DBs only."""
from __future__ import annotations
import queue
import re
import sys
import threading
import time
import uuid
from core import Child, Refused, Pending, REPO, canonical, digest_bytes, load_module, parse, read, safe

QUERIES = {
    'engine-version-postgresql': 'SHOW server_version',
    'engine-version-mysql': 'SELECT VERSION()',
    'values-head': 'SELECT id,label,exact_value,payload,computed_length FROM dbeer_parity_v1.values_grid WHERE id <= 5 ORDER BY id',
    'acceptance-effects': 'SELECT case_id,commits FROM dbeer_parity_v1.acceptance_effects ORDER BY case_id',
    'acceptance-receipts': 'SELECT case_id,statement_ordinal,marker FROM dbeer_parity_v1.acceptance_receipts ORDER BY case_id,statement_ordinal',
    'acceptance-apply': 'SELECT id,label,exact_value,payload,computed_length FROM dbeer_parity_v1.acceptance_apply ORDER BY id',
    'values-count': 'SELECT COUNT(*) FROM dbeer_parity_v1.values_grid',
    'composite': 'SELECT a,b,label FROM dbeer_parity_v1.composite_key ORDER BY a,b',
    'active-postgresql-sleep': "SELECT COUNT(*) FROM pg_stat_activity WHERE datname=current_database() AND pid<>pg_backend_pid() AND state='active' AND wait_event='PgSleep'",
    'active-mysql-sleep': "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE USER='dbeer' AND ID<>CONNECTION_ID() AND COMMAND='Query' AND INFO LIKE 'SELECT SLEEP(%'",
    'connections-postgresql': 'SELECT COUNT(*) FROM pg_stat_activity WHERE datname=current_database() AND pid<>pg_backend_pid() AND usename=current_user',
    'connections-mysql': "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE USER='dbeer' AND ID<>CONNECTION_ID()",
    'sessions-postgresql': "SELECT pid::text,backend_start::text,state,(xact_start IS NOT NULL)::text FROM pg_stat_activity WHERE datname=current_database() AND pid<>pg_backend_pid() AND usename=current_user ORDER BY pid",
    'sessions-mysql': "SELECT ID,COMMAND FROM information_schema.PROCESSLIST WHERE USER='dbeer' AND ID<>CONNECTION_ID() ORDER BY ID",
}


class DatabasePair:
    def __init__(self, pair, root, env):
        verification = REPO / 'prototypes/gpui/verification'
        # owned_databases imports its run helper by its historical local name.
        # Bind that import only during module construction; no shared file edit.
        previous = sys.modules.get('run')
        sys.modules['run'] = load_module('dbeer_task30_runner', verification / 'run.py')
        try:
            module = load_module('dbeer_task30_owned_databases', verification / 'owned_databases.py')
        finally:
            if previous is None:
                del sys.modules['run']
            else:
                sys.modules['run'] = previous
        self.owner = module.OwnedDatabases(pair, root, env)
        self.quiet = module.quiet
        self.private_identity = module.private_identity
        self.connections = {}
        self.tls_verified = set()
        try:
            for engine, version in zip(('postgres', 'mysql'), pair):
                record, directory = self.owner.create(engine, version)
                self.owner.setup(record)
                # Only this creator's returned exact container receipt is accepted.
                if not re.fullmatch('[0-9a-f]{64}', record['containerId']):
                    raise Refused('Owned DB receipt invalid.')
                self.connections['postgresql' if engine == 'postgres' else engine] = (record, directory)
        except Exception:
            self.owner.close()
            raise

    def setup_effects(self, engine):
        if engine not in self.connections:
            raise Refused('Exact owned database engine is required.')
        record, _ = self.connections[engine]
        if not hasattr(self.owner, 'setup_acceptance_effects'):
            raise Pending('Fixed owned effects corpus setup capability is unavailable.')
        try:
            return self.owner.setup_acceptance_effects(record)
        except Exception:
            raise Refused('Fixed owned effects setup failed; automatic replay is refused.') from None

    def relay_receipt(self, engine):
        if engine not in self.connections:
            raise Refused('Original exact-owned relay database engine required.')
        record, directory = self.connections[engine]
        original = self.owner.acceptance_receipts.get(id(record))
        if (not original or not any(item is record for item in self.owner.records)
                or any(record.get(key) != value for key, value in original.items())
                or record.get('acceptanceEffectsState') != 'installed'):
            raise Refused('Original installed owned effects/server receipt required for a relay.')
        root = self.owner.directory.stat()
        parent = directory.stat()
        if ((root.st_dev, root.st_ino) != self.owner.acceptance_root_identity
                or (parent.st_dev, parent.st_ino) != self.owner.acceptance_directories[id(record)]):
            raise Refused('Original owned relay database directories changed.')
        cid, nonce = original['containerId'], self.owner.nonce
        observed = self.quiet(['docker', 'inspect', '--format', '{{.Id}}|{{.Image}}|{{index .Config.Labels "app.dbeer.parity-run"}}|{{index .Config.Labels "app.dbeer.fixture"}}|{{.State.Running}}', cid], metadata=True)
        if observed != '|'.join((cid, original['imageId'], nonce, 'disposable-only-v1', 'true')):
            raise Refused('Original running relay server/nonce/image changed.')
        port = '5432' if engine == 'postgresql' else '3306'
        if self.quiet(['docker', 'port', cid, port + '/tcp'], metadata=True) != '127.0.0.1:' + str(original['loopbackPort']):
            raise Refused('Original relay database loopback mapping changed.')
        expected = {'postgresql': '6e1b660839d4fe87ef8717d52609e12239315dc5bf49075652ffd6262e227878',
                    'mysql': '650a31afd0bf7d6d56a4c94fc8ef4d83c522311725c4de71f2b1b0fc0018237d'}[engine]
        if record.get('acceptanceEffectsSourceSha256') != expected:
            raise Refused('Original relay transactional effects source differs.')
        tls = self.tls_receipt(engine)
        return {**original, 'acceptanceEffectsSourceSha256': expected, 'tlsPublicReceiptSha256': tls['sha256']}

    def tls_receipt(self, engine):
        if engine not in self.connections:
            raise Refused('Original owned TLS engine is required.')
        record, directory = self.connections[engine]
        root = safe(self.owner.directory, directory=True).stat()
        if (root.st_dev, root.st_ino) != self.owner.acceptance_root_identity:
            raise Refused('Original TLS fixture owner root changed.')
        metadata = safe(directory, directory=True).stat()
        if (metadata.st_dev, metadata.st_ino) != self.owner.acceptance_directories[id(record)]:
            raise Refused('Original TLS fixture directory changed.')
        receipts = {}
        for name in ('ca.crt', 'server.crt', 'server.ext', 'untrusted.crt'):
            path = safe(directory / name)
            expected = self.owner.private_files.get(path.relative_to(self.owner.directory).as_posix())
            if not expected or self.private_identity(path) != expected:
                raise Refused('Original producer TLS public file identity/hash is absent or changed.')
            receipts[name] = dict(expected)
        extensions = (b'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\n'
                      b'extendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost\n')
        if read(directory / 'server.ext', 4096) != extensions:
            raise Refused('Original TLS localhost/serverAuth extension source differs.')
        digest = digest_bytes(canonical(receipts))
        if digest not in self.tls_verified:
            self.quiet(['openssl', 'verify', '-CAfile', str(directory / 'ca.crt'), '-no-CApath',
                        '-verify_hostname', 'localhost', str(directory / 'server.crt')], timeout=15)
            self.tls_verified.add(digest)
        # Recheck all original identities after the bounded native verifier.
        if any(self.private_identity(directory / name) != value for name, value in receipts.items()):
            raise Refused('Original TLS public files changed during verification.')
        return {'sha256': digest, 'hostname': 'localhost', 'serverAuthSourceVerified': True,
                'ownedCaVerifiedServerCertificate': True, 'realNativeTLSConnectionStillRequired': True}

    def effects_ready(self, engine):
        return self.connections[engine][0].get('acceptanceEffectsState') == 'installed'

    def connection(self, engine):
        record, directory = self.connections[engine]
        # Never call Task30.environment(): no passwords/DSNs go to UI child env.
        original = self.owner.acceptance_directories[id(record)]
        metadata = directory.lstat()
        if (metadata.st_dev, metadata.st_ino) != original:
            raise Refused('Original owned server directory changed.')
        relative = (directory / 'password').relative_to(self.owner.directory).as_posix()
        if self.private_identity(directory / 'password') != self.owner.private_files.get(relative):
            raise Refused('Original owned server password identity changed.')
        password = read(directory / 'password', 4096).decode().strip()
        return {'engine': engine, 'host': '127.0.0.1', 'port': record['loopbackPort'], 'database': 'dbeer',
                'user': 'dbeer', 'password': password, 'sslMode': 'disable',
                'policy': {'environment': 'development', 'readOnly': True}}

    def public_ca_path(self, engine, field):
        _, directory = self.connections[engine]
        names = {'caFile': 'ca.crt', 'untrustedCaFile': 'untrusted.crt',
                 'missingCaFile': 'missing.crt', 'unreadableCaDirectory': 'unreadable-ca'}
        if field not in names:
            raise Refused('Only owned public CA fixture paths may enter the GUI.')
        self.tls_receipt(engine)
        if field == 'missingCaFile' and ((directory / names[field]).exists() or (directory / names[field]).is_symlink()):
            raise Refused('Owned missing-CA path was occupied; preserve its replacement.')
        return str(directory / names[field])

    def close(self):
        return self.owner.close()


class Observer:
    def __init__(self, artifact, env, databases, engine):
        artifact.verify()
        self.artifact, self.engine, self.databases = artifact, engine, databases
        self.child = Child(artifact.helper, artifact.files[artifact.helper_name]['sha256'], env, pipe=True)
        self.queue = queue.Queue(maxsize=4)
        self.counter, self.session = 0, None
        def reader():
            try:
                while True:
                    line = self.child.process.stdout.readline(16 * 1024 * 1024 + 1)
                    if not line or len(line) > 16 * 1024 * 1024 or not line.endswith(b'\n'):
                        self.queue.put(None, timeout=1)
                        return
                    self.queue.put(parse(line), timeout=2)
            except Exception:
                try:
                    self.queue.put(None, timeout=1)
                except queue.Full:
                    pass
        self.reader = threading.Thread(target=reader, daemon=True)
        self.reader.start()
        try:
            response = self.request({'type': 'hello', 'protocolVersion': 3}, 'hello.ack')
            if (response.get('protocolVersion') != 3 or 'capturedExportV1' not in response.get('capabilities', [])
                    or response.get('buildIdentity') != artifact.identity):
                raise Pending('Observer helper build handshake integration is missing or differs.')
            response = self.request({'type': 'connect', 'connection': databases.connection(engine)}, 'connect.result')
            if response.get('engine') != engine or response.get('transactionStatus') != 'idle':
                raise Refused('Independent observer session is not fresh/idle.')
            self.session = response['sessionId']
            self.version_proof = self.verify_engine_version()
        except Exception:
            self.child.stop()
            raise

    def verify_engine_version(self):
        result = self.query('engine-version-' + self.engine)
        if len(result['rows']) != 1 or len(result['rows'][0]) != 1:
            raise Refused('Actual engine version shape differs.')
        text = result['rows'][0][0]
        record, _ = self.databases.connections[self.engine]
        family = record['version']
        if not isinstance(text, str) or len(text) > 512 or not re.match(re.escape(family) + r'\.[0-9]+(?:[. ()A-Za-z0-9+~:_-]|$)', text):
            raise Refused('Actual engine version differs from the exact owned configured family.')
        return {'engineVersionFamily': family, 'actualVersionSha256': digest_bytes(text.encode()),
                'ownedImageId': record['imageId']}

    def send(self, command):
        self.child.verify()
        self.counter += 1
        command = dict(command, requestId='acceptance-observer-' + str(self.counter))
        data = canonical(command)
        if len(data) > 16384:
            raise Refused('Observer request exceeds bounds.')
        # Short bounded control frames; writer remains separate from response drain.
        errors = queue.Queue(maxsize=1)
        def writer():
            try:
                self.child.process.stdin.write(data)
                self.child.process.stdin.flush()
                errors.put(False)
            except Exception:
                errors.put(True)
        thread = threading.Thread(target=writer, daemon=True)
        thread.start()
        try:
            if errors.get(timeout=5):
                raise Refused('Observer pipe failed.')
        except queue.Empty:
            self.child.stop()
            raise Refused('Observer write timed out.') from None
        return command['requestId']

    def receive(self, deadline):
        self.child.verify()
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise Refused('Observer response timed out.')
        try:
            response = self.queue.get(timeout=remaining)
        except queue.Empty:
            raise Refused('Observer response timed out.') from None
        if not isinstance(response, dict) or response.get('type') == 'error':
            raise Refused('Independent observer failed.')
        self.child.verify()
        return response

    def request(self, command, terminal, timeout=20):
        request_id = self.send(command)
        deadline = time.monotonic() + timeout
        while True:
            response = self.receive(deadline)
            if response.get('requestId') != request_id:
                raise Refused('Observer correlation mismatch.')
            if response.get('type') == terminal:
                return response
            if response.get('type') != 'query.started':
                raise Refused('Unexpected observer response.')

    def query(self, query_id):
        if query_id not in QUERIES:
            raise Refused('Observer permits only fixed readonly synthetic queries.')
        if query_id.startswith('acceptance-') and not self.databases.effects_ready(self.engine):
            raise Pending('Fixed independent effects require completed exact owned setup.')
        query = QUERIES[query_id]
        response = self.request({'type': 'execute', 'sessionId': self.session, 'queryId': uuid.uuid4().hex,
                                 'sql': query, 'stream': False}, 'query.result')
        if response.get('sessionId') != self.session or response.get('truncated') or response.get('transactionStatus') != 'idle':
            raise Refused('Observer did not return a complete idle snapshot.')
        rows, columns = response.get('rows'), response.get('columns')
        if not isinstance(rows, list) or not isinstance(columns, list) or len(rows) > 2048:
            raise Refused('Observer shape invalid.')
        for row in rows:
            if len(row) != len(columns) or any(value is not None and not isinstance(value, str) for value in row):
                raise Refused('Observer typed values invalid.')
        # Internal values only; caller may compare synthetic known expected rows.
        return {'columns': columns, 'rows': rows}

    def proof(self, query_id):
        value = self.query(query_id)
        return {'observer': 'independent-exact-helper-physical-session', 'engine': self.engine,
                'queryId': query_id, 'rowCount': len(value['rows']), 'columnCount': len(value['columns']),
                'typedSha256': digest_bytes(canonical(value))}

    def session_snapshot(self):
        actual = self.query('sessions-' + self.engine)
        identities, sessions = set(), []
        for row in actual['rows']:
            expected_size = 4 if self.engine == 'postgresql' else 2
            if (len(row) != expected_size or not isinstance(row[0], str)
                    or not re.fullmatch('[1-9][0-9]{0,19}', row[0]) or row[0] in identities):
                raise Refused('Physical session observer has invalid/duplicate identities.')
            identities.add(row[0])
            if self.engine == 'postgresql':
                if (not isinstance(row[1], str) or not 1 <= len(row[1]) <= 128
                        or row[2] not in ('active', 'idle', 'idle in transaction', 'idle in transaction (aborted)')
                        or row[3] not in ('true', 'false')):
                    raise Refused('Original physical PostgreSQL session lifetime/state is unavailable.')
                sessions.append({'id': row[0], 'backendStart': row[1], 'state': row[2], 'transactionOpen': row[3] == 'true'})
            else:
                if row[1] not in ('Sleep', 'Query', 'Execute', 'Prepare', 'Daemon'):
                    raise Refused('Original physical MySQL session state is unavailable.')
                # PROCESSLIST does not expose a backend creation time or
                # transaction owner. Do not invent either from TIME/Sleep.
                sessions.append({'id': row[0], 'command': row[1]})
        record, _ = self.databases.connections[self.engine]
        return {'engine': self.engine, 'containerId': record['containerId'], 'ownedImageId': record['imageId'],
                'sessions': sessions, 'backendCreationTimeObserved': self.engine == 'postgresql'}

    def wait_scalar(self, query_id, predicate, timeout=20):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            result = self.query(query_id)
            if len(result['rows']) != 1 or len(result['rows'][0]) != 1:
                raise Refused('Observer scalar shape differs.')
            text = result['rows'][0][0]
            if not isinstance(text, str) or not re.fullmatch('[0-9]{1,12}', text):
                raise Refused('Observer scalar is not an exact bounded count.')
            value = int(text)
            if predicate(value):
                return {'queryId': query_id, 'serverConditionObserved': True, 'count': value}
            # A bounded physical server poll, never a fixed-sleep cancellation proof.
            threading.Event().wait(min(0.1, max(0, deadline - time.monotonic())))
        raise Refused('Required physical server condition was not observed.')

    def close(self):
        try:
            if self.session and self.child.process.poll() is None:
                response = self.request({'type': 'disconnect', 'sessionId': self.session}, 'disconnect.ack')
                if response.get('sessionId') != self.session:
                    raise Refused('Observer disconnect identity mismatch.')
                self.session = None
            if self.child.process.poll() is None:
                self.request({'type': 'shutdown'}, 'shutdown.ack')
                self.child.process.wait(timeout=5)
                if self.child.process.returncode != 0:
                    raise Refused('Independent observer normal shutdown failed.')
            elif self.child.process.returncode != 0:
                raise Refused('Independent observer exited without normal shutdown.')
        finally:
            self.child.stop()
