#!/usr/bin/env python3
"""Own disposable DB/TLS fixtures and exact Docker IDs; never adopt a DSN."""
from __future__ import annotations

import hashlib
import os
from pathlib import Path
import re
import secrets
import stat
import subprocess
import time

from run import REPO, now, private_directory, require_go_assertions, strict_json, verify_private, write_json

VERSIONS = {'postgres': ('16', '17', '18'), 'mysql': ('8.0', '8.4')}
LABEL = 'app.dbeer.parity-run'


def write_private(path, text):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'w', encoding='utf-8') as stream:
        stream.write(text)
        stream.flush()
        os.fsync(stream.fileno())


def private_identity(path):
    before = path.lstat()
    if not stat.S_ISREG(before.st_mode) or before.st_size > 65536 or getattr(before, 'st_file_attributes', 0) & 0x400:
        raise ValueError('Private fixture file is not a regular owned file.')
    descriptor = os.open(path, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0))
    try:
        metadata = os.fstat(descriptor)
        if (metadata.st_dev, metadata.st_ino) != (before.st_dev, before.st_ino):
            raise ValueError('Private fixture identity changed.')
        digest = hashlib.sha256()
        total = 0
        while block := os.read(descriptor, 1024 * 1024):
            total += len(block)
            if total > 65536:
                raise ValueError('Private fixture file grew beyond its bound.')
            digest.update(block)
        after = path.lstat()
        if (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns) != (metadata.st_dev, metadata.st_ino, metadata.st_size, metadata.st_mtime_ns):
            raise ValueError('Private fixture identity changed.')
        return {'device': metadata.st_dev, 'inode': metadata.st_ino, 'size': metadata.st_size, 'modifiedNs': metadata.st_mtime_ns, 'sha256': digest.hexdigest()}
    finally:
        os.close(descriptor)


def quiet(command, *, env=None, input_bytes=None, timeout=120, metadata=False, private_output=False):
    result = subprocess.run(command, env=env, input=input_bytes, stdout=subprocess.PIPE if metadata else subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, timeout=timeout, check=False,
                            **({'umask': 0o077} if private_output and os.name != 'nt' else {}))
    if result.returncode:
        raise ValueError('Owned database fixture command failed.')
    return result.stdout.decode('utf-8', errors='strict').strip() if metadata else ''


class OwnedDatabases:
    def __init__(self, pair, root, env):
        if pair[0] not in VERSIONS['postgres'] or pair[1] not in VERSIONS['mysql']:
            raise ValueError('Unsupported isolated database versions.')
        self.pair, self.root, self.env = pair, root, env
        self.nonce = root.name if re.fullmatch('[0-9a-f]{32}', root.name) else secrets.token_hex(16)
        self.directory = root / 'database-fixtures'
        private_directory(self.directory)
        self.records = []
        self.acceptance_receipts = {}
        self.acceptance_directories = {}
        self.acceptance_root_identity = (self.directory.stat().st_dev, self.directory.stat().st_ino)
        self.counter = 0
        self.cleanup = []
        self.private_files = {}
        self.private_cleanup = []
        override = os.environ.get('DOCKER_HOST', '')
        if override and not override.startswith(('unix://', 'npipe://')):
            raise ValueError('Remote Docker endpoints are not disposable local fixtures.')
        endpoint = override or quiet(['docker', 'context', 'inspect', '--format', '{{.Endpoints.docker.Host}}'], metadata=True)
        if not endpoint.startswith(('unix://', 'npipe://')):
            raise ValueError('The Docker context must use a local socket or named pipe.')
        self.host_arch = quiet(['docker', 'version', '--format', '{{.Server.Os}}/{{.Server.Arch}}'], metadata=True)
        if self.host_arch not in ('linux/amd64', 'linux/arm64'):
            raise ValueError('Disposable database fixtures require a Linux Docker engine.')

    def journal(self):
        self.counter += 1
        write_json(self.directory / ('journal-%03d.json' % self.counter), {
            'schemaVersion': 1, 'runNonce': self.nonce, 'disposableMarker': 'owned-dbeer-parity-only-v1',
            'at': now(), 'dockerEngine': self.host_arch, 'containers': self.records, 'cleanup': self.cleanup,
            'privateFiles': getattr(self, 'private_files', {}), 'privateCleanup': getattr(self, 'private_cleanup', [])})

    def capture_private(self, path):
        if path.exists() or path.is_symlink():
            verify_private(path, directory=False)
            relative = path.relative_to(self.directory).as_posix()
            self.private_files[relative] = private_identity(path)
            self.journal()

    def generate_private(self, command, path):
        if path.exists() or path.is_symlink():
            raise ValueError('Private fixture generation would overwrite a file.')
        try:
            quiet(command, private_output=True)
        finally:
            self.capture_private(path)

    def certs(self, name):
        directory = self.directory / name
        private_directory(directory)
        args = ['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-sha256', '-days', '1',
                '-subj', '/CN=DBeer disposable parity CA', '-addext', 'basicConstraints=critical,CA:TRUE',
                '-addext', 'keyUsage=critical,keyCertSign,cRLSign']
        self.generate_private(args + ['-keyout', str(directory / 'ca.key'), '-out', str(directory / 'ca.crt')], directory / 'ca.key')
        self.capture_private(directory / 'ca.crt')
        self.generate_private(['openssl', 'req', '-new', '-newkey', 'rsa:2048', '-nodes', '-sha256', '-subj', '/CN=localhost',
                               '-keyout', str(directory / 'server.key'), '-out', str(directory / 'server.csr')], directory / 'server.key')
        write_private(directory / 'server.ext', 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost\n')
        self.capture_private(directory / 'server.ext')
        quiet(['openssl', 'x509', '-req', '-sha256', '-days', '1', '-in', str(directory / 'server.csr'),
               '-CA', str(directory / 'ca.crt'), '-CAkey', str(directory / 'ca.key'), '-CAcreateserial',
               '-extfile', str(directory / 'server.ext'), '-out', str(directory / 'server.crt')], private_output=True)
        self.capture_private(directory / 'server.crt')
        self.generate_private(args + ['-keyout', str(directory / 'untrusted.key'), '-out', str(directory / 'untrusted.crt')], directory / 'untrusted.key')
        self.capture_private(directory / 'untrusted.crt')
        write_private(directory / 'password', secrets.token_hex(32) + '\n')
        self.capture_private(directory / 'password')
        write_private(directory / 'root-password', secrets.token_hex(32) + '\n')
        self.capture_private(directory / 'root-password')
        # A directory cannot be read as certificate bytes on either target. The
        # desktop matrix additionally requires a genuine permission-denied file.
        private_directory(directory / 'unreadable-ca')
        return directory

    def create(self, engine, version):
        directory = self.certs(engine)
        image = engine + ':' + version
        # Never pull implicitly or accept user-supplied arbitrary images/hosts.
        image_id = quiet(['docker', 'image', 'inspect', '--format', '{{.Id}}', image], metadata=True)
        if not re.fullmatch('sha256:[0-9a-f]{64}', image_id):
            raise ValueError('Local image identity is invalid.')
        image_arch = quiet(['docker', 'image', 'inspect', '--format', '{{.Os}}/{{.Architecture}}', image], metadata=True)
        port = '5432' if engine == 'postgres' else '3306'
        reserved_name = 'dbeer-parity-' + self.nonce + '-' + engine
        record = {'engine': engine, 'version': version, 'imageId': image_id, 'imageArchitecture': image_arch,
                  'reservedName': reserved_name, 'containerId': None, 'label': LABEL, 'nonce': self.nonce, 'state': 'reserved'}
        self.records.append(record)
        self.journal()  # Reserve a unique exact name before a possibly interrupted create.
        command = ['docker', 'create', '--pull=never', '--label', LABEL + '=' + self.nonce,
                   '--name', reserved_name,
                   '--label', 'app.dbeer.fixture=disposable-only-v1', '--publish', '127.0.0.1::' + port,
                   '--mount', 'type=bind,source=' + str(directory) + ',target=/fixtures,readonly']
        if engine == 'postgres':
            command += ['--env', 'POSTGRES_USER=dbeer', '--env', 'POSTGRES_DB=dbeer',
                        '--env', 'POSTGRES_PASSWORD_FILE=/fixtures/password', '--entrypoint', 'sh', image, '-ec',
                        'mkdir /tmp/dbeer-tls; cp /fixtures/server.crt /fixtures/server.key /tmp/dbeer-tls/; '
                        'chown -R postgres:postgres /tmp/dbeer-tls; chmod 600 /tmp/dbeer-tls/server.key; '
                        'exec docker-entrypoint.sh postgres -c ssl=on -c ssl_cert_file=/tmp/dbeer-tls/server.crt '
                        '-c ssl_key_file=/tmp/dbeer-tls/server.key']
        else:
            command += ['--env', 'MYSQL_USER=dbeer', '--env', 'MYSQL_DATABASE=dbeer',
                        '--env', 'MYSQL_PASSWORD_FILE=/fixtures/password', '--env', 'MYSQL_ROOT_PASSWORD_FILE=/fixtures/root-password',
                        '--entrypoint', 'sh', image, '-ec',
                        'mkdir /tmp/dbeer-tls; cp /fixtures/ca.crt /fixtures/server.crt /fixtures/server.key /tmp/dbeer-tls/; '
                        'chown -R mysql:mysql /tmp/dbeer-tls; chmod 600 /tmp/dbeer-tls/server.key; '
                        'exec docker-entrypoint.sh mysqld --ssl-ca=/tmp/dbeer-tls/ca.crt '
                        '--ssl-cert=/tmp/dbeer-tls/server.crt --ssl-key=/tmp/dbeer-tls/server.key '
                        '--local-infile=OFF --log-bin-trust-function-creators=ON']
        container_id = quiet(command, metadata=True)
        if not re.fullmatch('[0-9a-f]{64}', container_id):
            raise ValueError('Created container identity is invalid.')
        record.update(containerId=container_id, state='created')
        self.journal()  # Capture the exact identity before starting any server.
        quiet(['docker', 'start', container_id], timeout=60)
        record['state'] = 'started'
        self.journal()
        self.wait_ready(record)
        mapping = quiet(['docker', 'port', container_id, port + '/tcp'], metadata=True)
        match = re.fullmatch(r'127\.0\.0\.1:([0-9]+)', mapping)
        if not match or not 1 <= int(match[1]) <= 65535:
            raise ValueError('Disposable database must bind loopback only.')
        record['loopbackPort'] = int(match[1])
        volumes = quiet(['docker', 'inspect', '--format', '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}} {{end}}{{end}}', container_id], metadata=True)
        record['ownedAnonymousVolumes'] = volumes.split() if volumes else []
        self.journal()
        self.acceptance_directories[id(record)] = (directory.stat().st_dev, directory.stat().st_ino)
        self.acceptance_receipts[id(record)] = {
            key: record[key] for key in ('engine', 'version', 'imageId', 'reservedName', 'containerId', 'nonce', 'loopbackPort')}
        return record, directory

    def wait_ready(self, record):
        deadline = time.monotonic() + 150
        while time.monotonic() < deadline:
            command = ['docker', 'exec', record['containerId']]
            if record['engine'] == 'postgres':
                command += ['pg_isready', '--host', '127.0.0.1', '--username', 'dbeer', '--dbname', 'dbeer']
            else:
                command += ['sh', '-ec', 'MYSQL_PWD="$(cat /fixtures/password)" mysql --host=127.0.0.1 --user=dbeer --database=dbeer --silent --skip-column-names --execute="SELECT 1"']
            result = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                    stderr=subprocess.DEVNULL, timeout=10, check=False)
            if result.returncode == 0:
                return
            # Readiness polls a physical server condition. No cancellation test
            # infers request state from this bounded readiness polling delay.
            time.sleep(0.25)
        raise ValueError('Owned database did not become ready.')

    def setup(self, record):
        path = REPO / ('prototypes/gpui/parity/fixtures/' + ('postgresql.sql' if record['engine'] == 'postgres' else 'mysql.sql'))
        if record['engine'] == 'postgres':
            command = ['docker', 'exec', '-i', record['containerId'], 'sh', '-ec',
                       'PGPASSWORD="$(cat /fixtures/password)" psql --host=127.0.0.1 --username=dbeer --dbname=dbeer -v ON_ERROR_STOP=1 -f -']
        else:
            command = ['docker', 'exec', '-i', record['containerId'], 'sh', '-ec',
                       'MYSQL_PWD="$(cat /fixtures/root-password)" mysql --user=root --database=dbeer --default-character-set=utf8mb4']
        quiet(command, input_bytes=path.read_bytes())
        if record['engine'] == 'mysql':
            # MYSQL_USER initially owns only dbeer.*. Installed GUI/observer
            # cases use this separate reserved corpus, never a production DB.
            grant = b"GRANT SELECT, INSERT, UPDATE, DELETE, EXECUTE, SHOW VIEW ON dbeer_parity_v1.* TO 'dbeer'@'%';\n"
            quiet(command, input_bytes=grant)
            record['syntheticCorpusGrants'] = ['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'EXECUTE', 'SHOW VIEW']
        record['syntheticCorpusInstalled'] = True
        self.journal()

    def setup_acceptance_effects(self, record):
        """One-shot fixed Task32 corpus; takes only this owner's original receipt.

        Any interrupted/failing DDL remains failed-unknown and cannot be replayed.
        New cases require a fresh OwnedDatabases lifetime, never DROP/reset/adopt.
        """
        if (not any(item is record for item in self.records)
                or id(record) not in self.acceptance_receipts
                or record.get('syntheticCorpusInstalled') is not True
                or 'acceptanceEffectsState' in record):
            raise ValueError('Original installed corpus receipt required for one-shot effects setup.')
        original = self.acceptance_receipts[id(record)]
        if any(record.get(key) != value for key, value in original.items()):
            raise ValueError('Original owned database receipt changed.')
        metadata = self.directory.lstat()
        if (not stat.S_ISDIR(metadata.st_mode) or getattr(metadata, 'st_file_attributes', 0) & 0x400
                or (metadata.st_dev, metadata.st_ino) != self.acceptance_root_identity):
            raise ValueError('Original private database root changed.')
        engine, cid = record['engine'], record['containerId']
        if engine not in ('postgres', 'mysql') or not re.fullmatch('[0-9a-f]{64}', cid) or record['nonce'] != self.nonce:
            raise ValueError('Exact synthetic database identity differs.')
        observed = quiet(['docker', 'inspect', '--format', '{{.Id}}|{{.Image}}|{{index .Config.Labels "app.dbeer.parity-run"}}|{{index .Config.Labels "app.dbeer.fixture"}}|{{.State.Running}}', cid], metadata=True)
        if observed != '|'.join((cid, original['imageId'], self.nonce, 'disposable-only-v1', 'true')):
            raise ValueError('Exact owned running server identity differs.')
        port = '5432' if engine == 'postgres' else '3306'
        if quiet(['docker', 'port', cid, port + '/tcp'], metadata=True) != '127.0.0.1:' + str(original['loopbackPort']):
            raise ValueError('Exact owned loopback server endpoint changed.')
        password_name = 'password' if engine == 'postgres' else 'root-password'
        engine_directory = self.directory / engine
        current_directory = engine_directory.lstat()
        if (not stat.S_ISDIR(current_directory.st_mode) or getattr(current_directory, 'st_file_attributes', 0) & 0x400
                or (current_directory.st_dev, current_directory.st_ino) != self.acceptance_directories[id(record)]):
            raise ValueError('Original owned server fixture directory changed.')
        password = engine_directory / password_name
        relative = password.relative_to(self.directory).as_posix()
        if relative not in self.private_files or private_identity(password) != self.private_files[relative]:
            raise ValueError('Original owned password file changed.')
        name, expected = {
            'postgres': ('postgresql.sql', '6e1b660839d4fe87ef8717d52609e12239315dc5bf49075652ffd6262e227878'),
            'mysql': ('mysql.sql', '650a31afd0bf7d6d56a4c94fc8ef4d83c522311725c4de71f2b1b0fc0018237d'),
        }[engine]
        source = REPO / 'prototypes/gpui/fixtures/installed-acceptance/recipes/effects' / name
        # No caller path/SQL, symlink, source override or app output is authority.
        for parent in [source, *source.parents]:
            info = parent.lstat()
            if stat.S_ISLNK(info.st_mode) or getattr(info, 'st_file_attributes', 0) & 0x400:
                raise ValueError('Fixed effects source link refused.')
        source_identity = private_identity(source)
        if source_identity['sha256'] != expected:
            raise ValueError('Fixed effects source digest changed.')
        data = source.read_bytes()
        if hashlib.sha256(data).hexdigest() != expected or len(data) > 65536:
            raise ValueError('Fixed effects source changed during read.')
        if engine == 'postgres':
            command = ['docker', 'exec', '-i', cid, 'sh', '-ec',
                       'PGPASSWORD="$(cat /fixtures/password)" psql --host=127.0.0.1 --username=dbeer --dbname=dbeer -v ON_ERROR_STOP=1 -f -']
            data = b'BEGIN;\n' + data + b'\nCOMMIT;\n'
        else:
            command = ['docker', 'exec', '-i', cid, 'sh', '-ec',
                       'MYSQL_PWD="$(cat /fixtures/root-password)" mysql --user=root --database=dbeer --default-character-set=utf8mb4']
        record['acceptanceEffectsState'] = 'installing'
        record['acceptanceEffectsSourceSha256'] = expected
        self.journal()
        try:
            quiet(command, input_bytes=data)
            if private_identity(password) != self.private_files[relative] or private_identity(source) != source_identity:
                raise ValueError('Original effects setup inputs changed.')
        except Exception:
            record['acceptanceEffectsState'] = 'failed-unknown'
            self.journal()
            raise ValueError('Owned effects setup did not complete; replay refused.') from None
        record['acceptanceEffectsState'] = 'installed'
        self.journal()
        return {'engine': 'postgresql' if engine == 'postgres' else 'mysql',
                'sourceSha256': expected, 'fixedCorpusInstalled': True}

    def environment(self, postgres, pg_dir, mysql, my_dir):
        env = self.env.copy()
        password = (pg_dir / 'password').read_text().strip()
        env.update({'DBEER_GPUI_DISPOSABLE_DATABASES': '1',
                    'DBEER_TEST_DSN': 'postgresql://dbeer:' + password + '@127.0.0.1:' + str(postgres['loopbackPort']) + '/dbeer?sslmode=disable',
                    'DBEER_REQUIRE_POSTGRES': '1', 'DBEER_REQUIRE_MYSQL': '1', 'DBEER_REQUIRE_MYSQL_TLS': '1',
                    'DBEER_REQUIRE_GPUI_TLS': '1', 'DBEER_TEST_MYSQL_HOST': 'localhost',
                    'DBEER_TEST_MYSQL_PORT': str(mysql['loopbackPort']), 'DBEER_TEST_MYSQL_USER': 'dbeer',
                    'DBEER_TEST_MYSQL_DATABASE': 'dbeer', 'DBEER_TEST_MYSQL_SSLMODE': 'disable',
                    'DBEER_TEST_MYSQL_PASSWORD': (my_dir / 'password').read_text().strip(),
                    'DBEER_TEST_MYSQL_CA_FILE': str(my_dir / 'ca.crt'),
                    'DBEER_TEST_MYSQL_UNTRUSTED_CA_FILE': str(my_dir / 'untrusted.crt'),
                    'DBEER_TEST_TLS_PORT': str(postgres['loopbackPort']), 'DBEER_TEST_TLS_CA_FILE': str(pg_dir / 'ca.crt'),
                    'DBEER_TEST_TLS_UNTRUSTED_CA_FILE': str(pg_dir / 'untrusted.crt'),
                    'DBEER_TEST_TLS_PASSWORD_FILE': str(pg_dir / 'password')})
        # The existing PostgreSQL Go TLS suite uses username/database dbeer_tls;
        # do not supply its env here. It remains in the retained supported runner.
        for key in ('DBEER_TEST_TLS_PORT', 'DBEER_TEST_TLS_CA_FILE', 'DBEER_TEST_TLS_UNTRUSTED_CA_FILE', 'DBEER_TEST_TLS_PASSWORD_FILE'):
            env.pop(key, None)
        manifest = []
        scenarios = ('disable', 'require', 'trusted-ca', 'trusted-host', 'ca-only-hostname-mismatch',
                     'hostname-mismatch', 'untrusted-ca', 'untrusted-host', 'missing-ca', 'unreadable-ca')
        for engine, record, directory in (('postgresql', postgres, pg_dir), ('mysql', mysql, my_dir)):
            for scenario in scenarios + (('allow', 'prefer') if engine == 'postgresql' else ()):
                host = '127.0.0.1' if 'mismatch' in scenario else 'localhost'
                cert = directory / ('untrusted.crt' if scenario.startswith('untrusted') else 'missing.crt' if scenario == 'missing-ca' else 'unreadable-ca' if scenario == 'unreadable-ca' else 'ca.crt')
                manifest.append({'engine': engine, 'scenario': scenario, 'host': host, 'port': record['loopbackPort'],
                                 'database': 'dbeer', 'user': 'dbeer', 'passwordFile': str(directory / 'password'),
                                 'sslRootCert': str(cert)})
        path = self.directory / 'tls-manifest.json'
        write_json(path, manifest)
        env['DBEER_GPUI_TLS_MANIFEST'] = str(path)
        return env

    def close(self):
        success = True
        for record in reversed(self.records):
            container_id = record['containerId']
            try:
                if container_id is None:
                    metadata = quiet(['docker', 'inspect', '--format', '{{.Id}} {{ index .Config.Labels "' + LABEL + '" }}', record['reservedName']], metadata=True)
                    fields = metadata.split(' ')
                    if len(fields) != 2 or not re.fullmatch('[0-9a-f]{64}', fields[0]) or fields[1] != self.nonce:
                        raise ValueError('Reserved container identity could not be recovered.')
                    container_id = fields[0]
                    record['containerId'] = container_id
                # Check only one label of our exact recorded ID, never inspect
                # environment/mount secrets or select containers by a name.
                owner = quiet(['docker', 'inspect', '--format', '{{ index .Config.Labels "' + LABEL + '" }}', container_id], metadata=True)
                if owner != self.nonce:
                    raise ValueError('Container ownership changed; cleanup refused.')
                # --volumes removes only anonymous volumes attached to this
                # exact owned container; there are no caller-supplied volumes.
                quiet(['docker', 'rm', '--force', '--volumes', container_id], timeout=60)
                self.cleanup.append({'containerId': container_id, 'status': 'removed-owned-container'})
            except (OSError, ValueError, subprocess.SubprocessError):
                success = False
                self.cleanup.append({'containerId': container_id, 'status': 'cleanup-incomplete-no-foreign-action'})
        # Preserve replacements, even a same-byte foreign file. Check identity
        # before hashing so a foreign inode/symlink is never read as our secret.
        if not hasattr(self, 'private_cleanup'):
            self.private_cleanup = []
        for engine in ('postgres', 'mysql'):
            directory = self.directory / engine
            tracked = any(p.startswith(engine + '/') for p in getattr(self, 'private_files', {}))
            if tracked and (not directory.exists() or directory.is_symlink() or not directory.is_dir() or getattr(directory.lstat(), 'st_file_attributes', 0) & 0x400):
                success = False
                self.private_cleanup.append({'path':engine, 'status':'changed-directory-preserved-cleanup-unverified'})
                continue
            if directory.is_dir() and not directory.is_symlink():
                for name in ('ca.key', 'server.key', 'untrusted.key', 'password', 'root-password'):
                    path = directory / name
                    relative = path.relative_to(self.directory).as_posix()
                    expected = getattr(self, 'private_files', {}).get(relative)
                    try:
                        if not path.exists() and not path.is_symlink():
                            continue
                        metadata = path.lstat()
                        if not expected or not stat.S_ISREG(metadata.st_mode) or (metadata.st_dev, metadata.st_ino, metadata.st_size) != (expected['device'], expected['inode'], expected['size']) or private_identity(path) != expected:
                            raise ValueError('Foreign or changed private file preserved.')
                        latest = path.lstat()
                        if (latest.st_dev, latest.st_ino, latest.st_size, latest.st_mtime_ns) != (expected['device'], expected['inode'], expected['size'], expected['modifiedNs']):
                            raise ValueError('Private fixture changed before removal.')
                        path.unlink()
                        self.private_cleanup.append({'path':relative, 'status':'removed-exact-owned-file'})
                    except (OSError, ValueError):
                        success = False
                        self.private_cleanup.append({'path':relative, 'status':'foreign-or-changed-file-preserved'})
        self.cleanup_complete = success
        self.journal()
        return success


def run_pair(pair, env, ledger, root, execute_rust, collect):
    fixtures = OwnedDatabases(pair, root, env)
    success = False
    try:
        postgres, pg_dir = fixtures.create('postgres', pair[0])
        mysql, my_dir = fixtures.create('mysql', pair[1])
        fixtures.setup(postgres)
        fixtures.setup(mysql)
        owned_env = fixtures.environment(postgres, pg_dir, mysql, my_dir)
        stages = strict_json(Path(__file__).with_name('matrix.json'))['databaseStages']
        success = True
        for stage in stages:
            success = execute_rust(stage, owned_env, ledger, root) and success
        # The real adapter COMMIT-ACK tests are a separate proof boundary from
        # the Rust fake peer, original-helper death and installed opaque relay.
        go_stage = next(stage for stage in strict_json(Path(__file__).with_name('matrix.json'))['sharedStages']
                        if stage['id'] == 'shared-go-owned-db-race')
        go_env = owned_env.copy()
        go_env.update({'GOFLAGS': '-json', 'DBEER_REQUIRE_POSTGRES': '1'})
        proof = require_go_assertions(collect(['bash', './scripts/test-go.sh', '--require-postgres'], go_env, 3600, 'go'),
                                     go_stage['requiredTests'])
        ledger['stages'].append({'id': go_stage['id'], 'layer': go_stage['layer'], 'proof': proof,
                                 'requiredAssertionsExpected': proof['requiredAssertionsExpected'],
                                 'requiredAssertionsObserved': proof['requiredAssertionsObserved'],
                                 'missingRequiredAssertions': proof['missingRequiredAssertions'],
                                 'conditionalSkips': go_stage['conditionalSkips'],
                                 'status': 'passed' if proof['completed'] else 'failed'})
        success = proof['completed'] and success
    finally:
        success = fixtures.close() and success
        ledger['databaseFixtures'] = {'postgres': pair[0], 'mysql': pair[1], 'dockerEngine': fixtures.host_arch,
                                      'journals': 'database-fixtures/journal-*.json', 'cleanupCompleted': fixtures.cleanup_complete,
                                      'notCovered': ['real desktop permissions-denied CA', 'Windows/Linux graphical workflows', 'Go TLS: retained scripts/test-tls.sh and scripts/test-mysql.sh']}
    return success
