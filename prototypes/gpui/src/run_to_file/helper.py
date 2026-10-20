#!/usr/bin/env python3
"""Disposable full-export protocol fixture. The log contains command types only."""
import json
import pathlib
import sys
root = pathlib.Path(__file__).parent
policy = {'environment': 'production', 'readOnly': False}
grants = {}
held = None
pending = None
mode = (root / 'mode').read_text()
def send(reply):
    print(json.dumps(reply), flush=True)
def terminal(reply, command):
    if mode == 'publication-failure':
        send(dict(reply, type='error', category='export', message='SQL completed; publication failed.', connected=True, outcomeUnknown=False, transactionStatus='transaction', sqlCompleted=True, exportPublication='notPublished', resultSets=[], streamed=True))
    else:
        send(dict(reply, type='query.result', columns=[], rows=[], resultSets=[], streamed=True, rowCount=9001, displayedRowCount=0, commandTag='EXPORT', durationMs=1, transactionStatus='transaction', truncated=True, exportPath=command['export']['path'], exportFormat=command['export']['format'], exportRowCount=9001))
for line in sys.stdin:
    command = json.loads(line)
    kind = command['type']
    with (root / 'counts').open('a') as log:
        log.write(kind + '\n')
    reply = {k: command[k] for k in ('requestId', 'sessionId', 'queryId') if k in command}
    if kind == 'hello':
        send(dict(reply, type='hello.ack', protocolVersion=3, capabilities=[] if mode=='legacy-helper' else ['capturedExportV1']))
    elif kind == 'connect':
        send(dict(reply, type='connect.result', sessionId='original-sql', engine='postgresql', transactionStatus='idle', capabilities=['execute','cancel','transactions','catalog','operationAssessment','executionPolicy']))
    elif kind == 'operation.assess':
        assert len(command['operations']) == 1 and command['operations'][0]['type'] == 'execute'
        assert 'export' in command['operations'][0]
        grants[command['sessionId']] = command['operations'][0]
        send(dict(reply, type='operation.assessment', assessment={'decision':'confirm', 'policy':policy, 'operations':[{'kind':'write','statements':[]}], 'authorization':'single-use'}))
    elif kind == 'execute':
        operation = {k: command[k] for k in ('type','sql','export')}
        if command.get('authorization') != 'single-use' or grants.pop(command['sessionId'], None) != operation:
            send(dict(reply, type='error', category='policy', message='Exact operation binding refused.', connected=True, outcomeUnknown=False, transactionStatus='transaction'))
            continue
        send(dict(reply, type='query.started'))
        if mode == 'helper-loss':
            break
        send(dict(reply, type='query.progress', resultIndex=2050, rowCount=9001, sequence=1))
        pending = (reply, command)
    elif kind == 'stream.ack':
        assert command['sequence'] == 1
        if mode == 'hold':
            held, pending = pending, None
        else:
            terminal(*pending)
            pending = None
    elif kind == 'cancel':
        grants.pop(command['sessionId'], None)
        send(dict(reply, type='cancel.ack', status='accepted' if held else 'alreadyFinished'))
        if held:
            terminal(*held)
            held = None
    elif kind == 'disconnect':
        send(dict(reply, type='disconnect.ack'))
    elif kind == 'shutdown':
        break
    else:
        raise AssertionError('Unexpected fixture command')
