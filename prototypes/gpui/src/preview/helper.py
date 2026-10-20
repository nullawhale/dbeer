#!/usr/bin/env python3
"""Disposable protocol fixture; command log contains types only, never payloads."""
import json
import pathlib
import sys
sessions = {}
grants = set()
next_session = 0
held_apply = None
def apply_success(reply, command):
    return dict(reply, type="query.result", columns=[], rows=[], rowCount=len(command["changes"]["changes"]), displayedRowCount=0, commandTag="APPLY", durationMs=0, transactionStatus="idle", truncated=False)
def mode():
    path = pathlib.Path(__file__).with_name("mode")
    return path.read_text() if path.exists() else ""
for line in sys.stdin:
    command = json.loads(line)
    kind = command['type']
    with pathlib.Path(__file__).with_name('commands').open('a') as log:
        log.write(kind + '\n')
    reply = {'requestId': command['requestId']}
    for field in ('sessionId', 'queryId'):
        if field in command:
            reply[field] = command[field]
    if kind == 'hello':
        reply.update(type='hello.ack', protocolVersion=3)
    elif kind == 'connect':
        next_session += 1
        session = 'preview-session-' + str(next_session)
        sessions[session] = command['connection']['policy']
        reply.update(type='connect.result', sessionId=session, engine='postgresql', transactionStatus='idle', capabilities=['execute','cancel','transactions','catalog','operationAssessment','executionPolicy'])
    elif kind == 'changes.preview' and mode() == 'preview-error':
        reply.update(type='error', category='validation', message='Fixture preview rejected.', connected=True, transactionStatus='idle', outcomeUnknown=False)
    elif kind == 'changes.preview':
        rows = [[change['kind'], 'EXACT GENERATED $1 DEFAULT', '[{"kind":"null"},{"kind":"text","value":"9007199254740993.123456789"},{"kind":"binary","value":"AP9c"}]'] for change in command['changes']['changes']]
        started = dict(reply, type='query.started')
        print(json.dumps(started), flush=True)
        reply.update(type='query.result', columns=[{'index': i,'name': name,'engine':'postgresql','nativeType':'text','typeOid':25} for i,name in enumerate(['operation','sql','parameters'])], rows=rows, rowCount=len(rows), displayedRowCount=len(rows), commandTag='PREVIEW', durationMs=0, transactionStatus='idle', truncated=False)
    elif kind == 'operation.assess':
        assert all(op['type'] == 'changes.apply' for op in command['operations'])
        grants.add(command['sessionId'])
        reply.update(type='operation.assessment', assessment={'decision':'confirm','policy':sessions[command['sessionId']],'operations':[{'kind':'destructive','statements':[]} for op in command['operations']],'authorization':'fixture-grant-' + command['sessionId']})
    elif kind == 'changes.apply':
        assert command['authorization'] == 'fixture-grant-' + command['sessionId']
        if command['sessionId'] not in grants:
            reply.update(type='error', category='policy', message='Fixture grant revoked.', connected=True, transactionStatus='idle', outcomeUnknown=False)
            print(json.dumps(reply), flush=True)
            continue
        grants.discard(command['sessionId'])
        print(json.dumps(dict(reply, type='query.started')), flush=True)
        if mode() == 'apply-lost-ack':
            # Simulates a submitted Apply whose terminal/COMMIT ACK is lost.
            break
        if mode() in ('apply-hold-success', 'apply-hold-rollback'):
            held_apply = (reply, command)
            continue
        if mode() == 'apply-known-rollback':
            reply.update(type='error', category='conflict', message='Fixture full-row conflict. Entire batch rolled back.', connected=True, transactionStatus='idle', outcomeUnknown=False)
        else:
            reply = apply_success(reply, command)
    elif kind == 'cancel':
        grants.discard(command['sessionId'])
        reply.update(type='cancel.ack', status='accepted' if held_apply else 'alreadyFinished')
        if held_apply:
            print(json.dumps(reply), flush=True)
            terminal, applied = held_apply
            if mode() == 'apply-hold-rollback':
                terminal.update(type='error', category='cancelled', message='Fixture entire Apply rolled back.', connected=True, transactionStatus='idle', outcomeUnknown=False)
            else:
                terminal = apply_success(terminal, applied)
            held_apply = None
            print(json.dumps(terminal), flush=True)
            continue
    elif kind == 'disconnect' and pathlib.Path(__file__).with_name('disconnect-once').exists():
        pathlib.Path(__file__).with_name('disconnect-once').unlink()
        reply.update(type='error', category='validation', message='Fixture teardown refused once.', connected=True, transactionStatus='idle', outcomeUnknown=False)
    elif kind == 'disconnect':
        sessions.pop(command['sessionId'], None)
        reply.update(type='disconnect.ack')
    elif kind == 'shutdown':
        break
    else:
        raise AssertionError('Changes fixture refuses SQL operations')
    print(json.dumps(reply), flush=True)
