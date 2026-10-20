"""Owned opaque loopback DB leases; no protocol or payload diagnostics.

The reverse hold is acknowledged under the SAME lock used for every client
send. Thus no reverse byte received after arm can cross the barrier. A retained
socket is dropped only after a separate direct observer sees the fixed commit.
One original connection is the default. The explicit Apply admission alone may
retain that pinned catalog passthrough plus one fresh original Apply connection.
Any third connection refuses. This is not helper process-death evidence.
"""
from __future__ import annotations
import select
import socket
import threading
import time
import uuid
from core import REPO, Refused, digest_bytes, read

BOUND = 65536
APPLY_SOURCE_PINS = {
    'helper/internal/postgres/changes.go': '586473837d5bd0d8bc3eae663677ecb933bdf8b7d679fbcf43bca2a6ea09441e',
    'helper/internal/mysql/changes.go': 'e81029a13972c110b8baea48d4891c010324c949535edf49aaa61a5d75757ae8',
    'prototypes/gpui/fixtures/installed-acceptance/recipes/effects/postgresql.sql': '6e1b660839d4fe87ef8717d52609e12239315dc5bf49075652ffd6262e227878',
    'prototypes/gpui/fixtures/installed-acceptance/recipes/effects/mysql.sql': '650a31afd0bf7d6d56a4c94fc8ef4d83c522311725c4de71f2b1b0fc0018237d',
}


def require_sequential_apply_source():
    # Explicitly reviewed: synchronous per-statement reply drain, transactional
    # fixed trigger/effects, COMMIT only after every prior reply. Drift refuses.
    for relative, expected in APPLY_SOURCE_PINS.items():
        if digest_bytes(read(REPO / relative, 128 * 1024)) != expected:
            raise Refused('Reviewed sequential Apply/MVCC effect source changed.')


class OwnedRelay:
    def __init__(self, databases, engine, journal):
        self.databases, self.engine, self.journal = databases, engine, journal
        self.receipt = databases.relay_receipt(engine)
        self.nonce, self.generation = uuid.uuid4().hex, None
        self.lock, self.connected = threading.RLock(), threading.Event()
        self.condition = threading.Condition(self.lock)
        self.stop_event = threading.Event()
        self.client, self.server = None, None
        self.forward, self.reverse = bytearray(), bytearray()
        self.state, self.failed = 'listening', False
        self.arm_record, self.verified_loss = None, False
        self.chunk_sequence, self.last_released, self.chunk_token = 0, 0, None
        self.parent, self.second, self.next_admission = None, None, None
        self.catalog_pinned = False
        self.listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        # No SO_REUSEADDR/REUSEPORT: another process cannot join the owned lease.
        if hasattr(socket, 'SO_EXCLUSIVEADDRUSE'):
            self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
        self.listener.bind(('127.0.0.1', 0))
        self.listener.listen(2)
        self.listener.setblocking(False)
        self.port = self.listener.getsockname()[1]
        self.worker = threading.Thread(target=self._run, name='owned-dbeer-db-relay', daemon=True)
        self.worker.start()
        journal.append('exact-owned-db-relay-created', engine=engine, relayNonce=self.nonce,
                       databaseReceiptSha256=digest_bytes(str(sorted(self.receipt.items())).encode()),
                       opaqueEndToEndTLS=True, payloadRetainedInEvidence=False)

    def verify(self):
        if self.parent is not None:
            if self.parent.second is not self:
                raise Refused('Original second connection lease was replaced.')
            self.parent.verify()
        if self.databases.relay_receipt(self.engine) != self.receipt:
            raise Refused('Original relay database owner/endpoint changed.')
        with self.lock:
            if self.failed or self.state in ('failed', 'closed'):
                raise Refused('Original relay failed or retired.')
            if self.listener.getsockname() != ('127.0.0.1', self.port):
                raise Refused('Original relay listener lease changed.')

    @classmethod
    def _adopt_second(cls, parent, incoming):
        lease = cls.__new__(cls)
        lease.databases, lease.engine, lease.journal = parent.databases, parent.engine, parent.journal
        lease.receipt, lease.nonce = dict(parent.receipt), parent.nonce
        lease.generation = uuid.uuid4().hex
        lease.lock, lease.connected = threading.RLock(), threading.Event()
        lease.condition = threading.Condition(lease.lock)
        lease.stop_event = threading.Event()
        lease.forward, lease.reverse = bytearray(), bytearray()
        lease.arm_record, lease.verified_loss = None, False
        lease.chunk_sequence, lease.last_released, lease.chunk_token = 0, 0, None
        lease.parent, lease.second, lease.next_admission = parent, None, None
        lease.catalog_pinned = False
        lease.listener, lease.port = parent.listener, parent.port
        lease.client = incoming
        try:
            lease.server = socket.create_connection(('127.0.0.1', lease.receipt['loopbackPort']), timeout=5)
            if lease.server.getpeername() != ('127.0.0.1', lease.receipt['loopbackPort']):
                raise Refused('Second original lease reached an unexpected endpoint.')
            lease.client.setblocking(False)
            lease.server.setblocking(False)
            lease.state, lease.failed = 'forwarding', False
            lease.connected.set()
            lease.worker = threading.Thread(target=lease._run, name='owned-dbeer-apply-relay', daemon=True)
            lease.worker.start()
            return lease
        except Exception:
            incoming.close()
            if getattr(lease, 'server', None) is not None:
                lease.server.close()
            raise

    def pin_catalog(self):
        if not self.connected.wait(timeout=15):
            raise Refused('Original catalog lease was not observed.')
        self.verify()
        with self.lock:
            if self.parent is not None or self.state != 'forwarding' or self.catalog_pinned or self.second or self.arm_record:
                raise Refused('Only the original idle first lease can be pinned as catalog.')
            self.catalog_pinned = True
            self.journal.append('original-catalog-relay-lease-pinned', engine=self.engine,
                                relayNonce=self.nonce, connectionGeneration=self.generation)

    def admit_second(self):
        self.verify()
        with self.lock:
            if (not self.catalog_pinned or self.second is not None or self.next_admission is not None
                    or self.state != 'forwarding' or self.forward or self.reverse):
                raise Refused('Original idle catalog lease and fresh one-shot Apply admission required.')
            self.next_admission = uuid.uuid4().hex
            self.journal.append('original-apply-second-lease-admission-armed', engine=self.engine,
                                relayNonce=self.nonce, catalogGeneration=self.generation,
                                admissionNonce=self.next_admission)

    def second_lease(self):
        self.verify()
        deadline = time.monotonic() + 15
        with self.condition:
            while self.second is None:
                if self.failed or self.state != 'forwarding':
                    raise Refused('Original second lease admission failed.')
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise Refused('Original fresh Apply connection did not arrive.')
                self.condition.wait(timeout=remaining)
            self.second.verify()
            return self.second

    def endpoint(self, field):
        self.verify()
        if field not in ('host', 'port'):
            raise Refused('Relay exposes only its exact owned loopback endpoint.')
        return 'localhost' if field == 'host' else str(self.port)

    def _close_sockets(self):
        for stream in (self.client, self.server):
            if stream is not None:
                try:
                    stream.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                stream.close()
        self.forward.clear()
        self.reverse.clear()

    def _run(self):
        try:
            while not self.stop_event.is_set():
                with self.lock:
                    readers = [self.listener] if self.parent is None else []
                    writers = []
                    if self.client is not None and len(self.forward) < BOUND:
                        readers.append(self.client)
                    if (self.server is not None and len(self.reverse) < BOUND
                            and (self.state not in ('gated', 'releasing') or not self.reverse)):
                        readers.append(self.server)
                    if self.server is not None and self.forward:
                        writers.append(self.server)
                    if self.client is not None and self.reverse and self.state in ('forwarding', 'releasing'):
                        writers.append(self.client)
                readable, writable, _ = select.select(readers, writers, [], 0.05)
                # This lock covers all receives/sends and the arm transition.
                with self.lock:
                    if self.stop_event.is_set():
                        break
                    if self.parent is None and self.listener in readable:
                        incoming, address = self.listener.accept()
                        if address[0] != '127.0.0.1':
                            incoming.close()
                            raise Refused('Extra or nonloopback relay connection refused.')
                        if self.client is not None:
                            if not self.catalog_pinned or self.next_admission is None or self.second is not None:
                                incoming.close()
                                raise Refused('Extra relay connection lacks its original one-shot admission.')
                            if self.databases.relay_receipt(self.engine) != self.receipt:
                                incoming.close()
                                raise Refused('Original server changed during second-lease admission.')
                            self.second = self._adopt_second(self, incoming)
                            self.journal.append('original-apply-second-lease-created', engine=self.engine,
                                                relayNonce=self.nonce, catalogGeneration=self.generation,
                                                connectionGeneration=self.second.generation,
                                                admissionNonce=self.next_admission)
                            self.next_admission = None
                            self.condition.notify_all()
                            continue
                        self.client = incoming
                        # Retain only the original owner-proven endpoint. No
                        # caller can request an alternate target or resolver.
                        if self.databases.relay_receipt(self.engine) != self.receipt:
                            raise Refused('Original relay server identity changed before connect.')
                        self.server = socket.create_connection(('127.0.0.1', self.receipt['loopbackPort']), timeout=5)
                        if self.server.getpeername() != ('127.0.0.1', self.receipt['loopbackPort']):
                            raise Refused('Relay connected to an unexpected server endpoint.')
                        self.client.setblocking(False)
                        self.server.setblocking(False)
                        self.generation, self.state = uuid.uuid4().hex, 'forwarding'
                        self.connected.set()
                    for source, buffer in ((self.client, self.forward), (self.server, self.reverse)):
                        if source is not None and source in readable and len(buffer) < BOUND:
                            try:
                                block = source.recv(min(16384, BOUND - len(buffer)))
                            except BlockingIOError:
                                continue
                            if not block:
                                if self.state != 'forwarding':
                                    raise Refused('Held original relay connection ended before verified loss.')
                                self.state = 'closed'
                                self.stop_event.set()
                                break
                            buffer.extend(block)
                            if source is self.server and self.state == 'gated':
                                self.chunk_sequence += 1
                                self.chunk_token = (self.nonce, self.generation, self.chunk_sequence)
                                self.condition.notify_all()
                    for destination, buffer, allowed in ((self.server, self.forward, True),
                                                         (self.client, self.reverse, self.state in ('forwarding', 'releasing'))):
                        if destination is not None and destination in writable and buffer and allowed and not self.stop_event.is_set():
                            try:
                                sent = destination.send(buffer)
                            except BlockingIOError:
                                continue
                            del buffer[:sent]
                            if destination is self.client and not buffer and self.state == 'releasing':
                                self.last_released = self.chunk_sequence
                                self.chunk_token, self.state = None, 'gated'
                                self.condition.notify_all()
        except Exception:
            with self.lock:
                if not self.stop_event.is_set():
                    self.failed, self.state = True, 'failed'
                self.stop_event.set()
                self.connected.set()
                self.condition.notify_all()
        finally:
            with self.lock:
                self._close_sockets()

    def arm(self, *, chunks=False):
        if not self.connected.wait(timeout=15):
            raise Refused('Original single relay connection was not observed.')
        self.verify()
        with self.lock:
            if self.state != 'forwarding' or self.arm_record is not None or self.forward or self.reverse:
                raise Refused('Relay is not idle, has pending bytes, or its one-shot hold was already armed.')
            if not self.generation or self.client is None or self.server is None:
                raise Refused('Original relay connection handles are unavailable.')
            self.state = 'gated' if chunks else 'held'
            self.arm_record = {'relayNonce': self.nonce, 'connectionGeneration': self.generation,
                               'reverseHoldAcknowledged': True, 'armEpoch': uuid.uuid4().hex,
                               'reverseMode': 'one-chunk-gate' if chunks else 'complete-hold'}
            # Journal the acknowledgement before any native Commit invocation.
            self.journal.append('original-db-reverse-hold-acknowledged', engine=self.engine, **self.arm_record)
            return dict(self.arm_record)

    def next_chunk(self, *, timeout=10):
        self.verify()
        deadline = time.monotonic() + min(timeout, 15)
        with self.condition:
            while True:
                if self.failed or self.state not in ('gated', 'releasing'):
                    raise Refused('Original chunk-gated connection failed or changed state.')
                if self.state == 'gated' and self.chunk_token is not None and self.reverse:
                    return self.chunk_token
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise Refused('Original bounded reverse chunk did not arrive.')
                self.condition.wait(timeout=remaining)

    def release_chunk(self, token):
        self.verify()
        with self.condition:
            if self.state != 'gated' or token != self.chunk_token or not self.reverse:
                raise Refused('Only the exact currently held original chunk may be released once.')
            self.state = 'releasing'
            self.condition.notify_all()
            deadline = time.monotonic() + 10
            while self.last_released < token[2]:
                if self.failed or self.state not in ('gated', 'releasing'):
                    raise Refused('Original reverse chunk release did not complete.')
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise Refused('Original reverse chunk release exceeded backpressure bounds.')
                self.condition.wait(timeout=remaining)

    def drop_held(self, token=None):
        self.verify()
        with self.lock:
            if (self.state not in ('held', 'gated') or self.arm_record is None
                    or self.state == 'gated' and (self.chunk_token is None or token != self.chunk_token or not self.reverse)):
                raise Refused('Only the original acknowledged held connection can be dropped.')
            self.state = 'dropped'
            self.stop_event.set()
            self._close_sockets()
            self.condition.notify_all()
        self.worker.join(timeout=6)
        if self.worker.is_alive() or self.failed:
            raise Refused('Exact held relay teardown did not complete.')
        self.journal.append('original-held-db-connection-dropped', engine=self.engine,
                            relayNonce=self.nonce, connectionGeneration=self.generation,
                            noCurrentOrLaterChunkReleased=True, earlierExactChunksReleased=self.last_released,
                            helperProcessDeathProven=False)

    def close(self):
        child_error = False
        if self.second is not None:
            try:
                self.second.close()
            except Exception:
                child_error = True
        with self.lock:
            clean = not self.failed and (self.state == 'closed' or self.state == 'dropped' and self.verified_loss)
            self.stop_event.set()
            self._close_sockets()
            self.condition.notify_all()
        self.worker.join(timeout=6)
        if self.parent is None:
            self.listener.close()
        if self.worker.is_alive() or not clean or child_error:
            raise Refused('Relay cleanup completed without a complete original fault/lifecycle proof.')
