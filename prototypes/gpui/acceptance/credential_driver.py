#!/usr/bin/env python3
"""Bound native store calls in a private exact child; never emit payload errors."""
import base64
import json
import re
import sys
sys.dont_write_bytecode = True
from core import Refused, digest_bytes, parse
from credentials import native_store


def main():
    data = sys.stdin.buffer.read(16385)
    if len(data) > 16384:
        raise Refused('Credential request bound.')
    request = parse(data)
    account = request.get('account', '')
    if not re.fullmatch(r'(?:dbeer-acceptance-[0-9a-f]{32}-[a-z0-9-]{1,32}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})', account):
        raise Refused('Reserved account required.')
    store = native_store()
    operation = request.get('operation')
    if operation == 'exists':
        print(json.dumps({'present': store.exists(account)}))
        return
    if operation == 'create' and store.exists(account):
        raise Refused('Credential collision preserved without reading its value.')
    value = None if operation == 'create' else store.read(account)
    if operation == 'read':
        # Output is a bounded anonymous pipe, never a log/proof or disk file.
        print(json.dumps({'absent': value is None, 'valueBase64': None if value is None else base64.b64encode(value).decode()}))
        return
    if operation == 'create':
        if value is not None:
            raise Refused('Credential collision preserved.')
        secret = base64.b64decode(request['valueBase64'], validate=True)
        store.write(account, secret)
        if store.read(account) != secret:
            raise Refused('Credential readback differs.')
    elif operation == 'delete':
        if value is None:
            print('{"completed":true,"absent":true}')
            return
        if digest_bytes(value) != request.get('expectedSha256'):
            raise Refused('Foreign credential replacement preserved.')
        store.delete(account)
        if store.read(account) is not None:
            raise Refused('Credential absence unproven.')
    else:
        raise Refused('Unknown credential operation.')
    print('{"completed":true}')


if __name__ == '__main__':
    try:
        main()
    except Exception:
        print('{"refused":true}')
        sys.exit(2)
