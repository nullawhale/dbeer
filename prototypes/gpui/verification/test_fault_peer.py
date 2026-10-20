#!/usr/bin/env python3
"""Prepared portable-fixture conformance cases. Final integration only."""
import json
import os
from pathlib import Path
import subprocess
import unittest
import uuid

from run import REPO, executable_identity, private_directory, sha, strict_json, verify_private


class PortablePeerTests(unittest.TestCase):
    def fixture(self, flavor, mode='', marker=True):
        parent = Path(os.environ.get('DBEER_GPUI_TEST_ROOT', ''))
        self.assertTrue(parent.is_absolute() and parent.is_relative_to(REPO / 'build'), 'An explicit owned private test root is required.')
        verify_private(parent)
        root = parent / str(uuid.uuid4())
        private_directory(root)
        binary = Path(os.environ.get('DBEER_GPUI_FAULT_HELPER_PATH', ''))
        source = executable_identity(binary)
        self.assertEqual(source['sha256'], os.environ.get('DBEER_GPUI_FAULT_HELPER_SHA256'), 'The exact compiled portable fixture hash is required.')
        executable = root / ('helper.exe' if os.name == 'nt' else 'helper')
        files, immutable = {}, {}
        def create(name, data, mode=0o600):
            path = root / name
            descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
            with os.fdopen(descriptor, 'wb') as stream:
                stream.write(data)
            verify_private(path, directory=False)
            metadata = path.stat()
            files[name] = (metadata.st_dev, metadata.st_ino)
            if name not in ('counts', 'commands'):
                immutable[name] = sha(path)
        create(executable.name, binary.read_bytes(), 0o700)
        self.assertEqual(sha(executable), source['sha256'], 'Copied portable fixture bytes changed.')
        executable_identity(binary, source)
        create('fixture-kind', flavor.encode())
        create('mode', mode.encode())
        create('counts' if flavor == 'run-to-file' else 'commands', b'')
        if marker:
            create('disposable.marker', b'owned-dbeer-parity-only-v1')
        record = {'root': root, 'rootIdentity': verify_private(root), 'files': files, 'immutable':immutable, 'exited': False, 'pid':None}
        if not hasattr(self, 'fixtures'): self.fixtures = {}
        self.fixtures[str(executable)] = record
        self.addCleanup(self.cleanup_fixture, record)
        return root, executable

    def cleanup_fixture(self, record):
        root = record['root']
        self.assertTrue(record['exited'], 'Unproven peer exit preserves fixture files.')
        self.assertEqual(verify_private(root), record['rootIdentity'], 'Changed root preserved.')
        journal = root / 'fault-peer-started.json'
        if journal.exists():
            verify_private(journal, directory=False)
            value = strict_json(journal)
            self.assertTrue(value.get('ownedPid') == record['pid'] and value.get('nonce') == root.name
                            and value.get('disposableMarker') == 'owned-dbeer-parity-only-v1', 'Changed peer ownership journal preserved.')
            metadata = journal.stat()
            record['files'][journal.name] = (metadata.st_dev, metadata.st_ino)
        self.assertEqual({p.name for p in root.iterdir()}, set(record['files']), 'Foreign fixture files are preserved.')
        final = {}
        for name, identity in record['files'].items():
            path = root / name
            self.assertEqual(verify_private(path, directory=False), identity, 'Changed fixture file preserved.')
            if name in record['immutable']:
                self.assertEqual(sha(path), record['immutable'][name], 'Changed immutable fixture bytes preserved.')
            final[name] = (path.stat().st_size, path.stat().st_mtime_ns, sha(path))
        for name, identity in record['files'].items():
            path = root / name
            self.assertEqual(verify_private(path, directory=False), identity)
            self.assertEqual((path.stat().st_size, path.stat().st_mtime_ns, sha(path)), final[name])
            path.unlink()
        self.assertEqual(verify_private(root), record['rootIdentity'])
        root.rmdir()

    def run_peer(self, executable, commands=None, raw=None):
        payload = raw if raw is not None else b''.join((json.dumps(c) + '\n').encode() for c in commands)
        process = subprocess.Popen([str(executable)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        record = self.fixtures[str(executable)]
        record['pid'] = process.pid
        try:
            output, _ = process.communicate(payload, timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()  # Retained exact owned child, never a discovered PID.
            process.wait(timeout=5)
            self.fail('The owned fixture exceeded its bounded protocol deadline.')
        finally:
            record['exited'] = process.poll() is not None
        return process.returncode, [json.loads(line) for line in output.splitlines()]

    def connect(self):
        return {'type':'connect','requestId':'connect','connection':{'policy':{'environment':'development','readOnly':False},'password':'private-synthetic-marker'}}

    def test_missing_disposable_marker_refuses_before_journal_or_payload(self):
        root, executable = self.fixture('preview', marker=False)
        code, output = self.run_peer(executable, [{'type':'hello','requestId':'hello'}])
        self.assertTrue(code == 2 and not output and not (root / 'fault-peer-started.json').exists(), 'Unmarked state was not refused safely.')

    def test_preview_cancel_ack_precedes_exact_authoritative_held_terminal(self):
        root, executable = self.fixture('preview', 'apply-hold-success')
        request = {'changes':[{'kind':'update'}]}
        commands = [{'type':'hello','requestId':'hello'}, self.connect(),
                    {'type':'changes.preview','requestId':'preview','queryId':'preview-query','sessionId':'preview-session-1','changes':request},
                    {'type':'operation.assess','requestId':'assess','sessionId':'preview-session-1','operations':[{'type':'changes.apply','changes':request}]},
                    {'type':'changes.apply','requestId':'apply','queryId':'apply-query','sessionId':'preview-session-1','changes':request,'authorization':'fixture-grant-preview-session-1'},
                    {'type':'cancel','requestId':'cancel','queryId':'apply-query','sessionId':'preview-session-1'},
                    {'type':'disconnect','requestId':'disconnect','sessionId':'preview-session-1'}, {'type':'shutdown','requestId':'shutdown'}]
        code, output = self.run_peer(executable, commands)
        ack = [i for i,r in enumerate(output) if r['type']=='cancel.ack']
        terminal = [i for i,r in enumerate(output) if r['type']=='query.result' and r.get('queryId')=='apply-query']
        self.assertTrue(code == 0 and len(ack)==len(terminal)==1 and ack[0]<terminal[0], 'Held terminal/cancel ordering was incorrect.')
        log = (root / 'commands').read_text().splitlines()
        self.assertTrue(log == [c['type'] for c in commands], 'Fixture log contained unexpected data.')

    def test_lost_apply_terminal_is_actual_owned_peer_exit_without_retry(self):
        root, executable = self.fixture('preview', 'apply-lost-ack')
        commands = [{'type':'hello','requestId':'hello'}, self.connect(),
                    {'type':'operation.assess','requestId':'assess','sessionId':'preview-session-1','operations':[{'type':'changes.apply'}]},
                    {'type':'changes.apply','requestId':'apply','queryId':'q','sessionId':'preview-session-1','authorization':'fixture-grant-preview-session-1','changes':{'changes':[]}}]
        code, output = self.run_peer(executable, commands)
        self.assertTrue(code == 0 and output[-1]['type']=='query.started' and not any(r['type']=='query.result' for r in output), 'Lost terminal peer invented a completion.')
        self.assertTrue((root / 'commands').read_text().splitlines().count('changes.apply') == 1, 'Apply was repeated.')

    def test_export_exact_grant_ack_and_late_stop_keep_full_count(self):
        root, executable = self.fixture('run-to-file', 'hold')
        operation = {'type':'execute','sql':'private-synthetic-marker','export':{'path':str(root/'owned.json'),'format':'json'}}
        commands = [{'type':'hello','requestId':'hello'}, self.connect(),
                    {'type':'operation.assess','requestId':'assess','sessionId':'original-sql','operations':[operation]},
                    dict(operation,requestId='execute',queryId='export-query',sessionId='original-sql',authorization='single-use'),
                    {'type':'stream.ack','requestId':'ack','queryId':'export-query','sessionId':'original-sql','sequence':1},
                    {'type':'cancel','requestId':'cancel','queryId':'export-query','sessionId':'original-sql'},
                    {'type':'shutdown','requestId':'shutdown'}]
        code, output = self.run_peer(executable, commands)
        terminal = [r for r in output if r['type']=='query.result']
        self.assertTrue(code == 0 and len(terminal)==1 and terminal[0]['exportRowCount']==9001, 'Full export terminal was incorrect.')
        self.assertTrue((root/'counts').read_text().splitlines() == [c['type'] for c in commands], 'Fixture log retained a payload.')

    def test_oversized_frame_has_no_echo_or_success(self):
        _, executable = self.fixture('preview')
        code, output = self.run_peer(executable, raw=b'x'*(16*1024*1024+1)+b'\n')
        self.assertTrue(code == 2 and not output, 'Oversized frame was not refused safely.')


if __name__ == '__main__':
    unittest.main(verbosity=2)
