"""Semantic native actions with a fresh exact-owner check at every boundary."""
import os
from pathlib import Path
import time
from core import Pending, Refused, bounded_call, canonical, parse, sha

HERE = Path(__file__).resolve().parent


class Driver:
    def __init__(self, artifact, child, desktop, env, contract, acknowledged):
        if contract.get('schemaVersion') != 1 or contract.get('nativeObserved') is not True:
            raise Pending('Actual native selector contract has not been observed.')
        if (contract.get('desktop') != desktop or contract.get('guiSha256') != artifact.files[artifact.gui_name]['sha256']
                or contract.get('sourceSha256') != artifact.identity['sourceSha256']):
            raise Pending('Native selector contract is not pinned to this exact artifact.')
        self.artifact, self.child, self.desktop, self.env = artifact, child, desktop, env
        self.contract, self.acknowledged = contract, acknowledged
        self.window_keys, self.bindings = {}, {}
        self.commands = ([os.environ.get('SYSTEMROOT', r'C:\Windows') + r'\System32\WindowsPowerShell\v1.0\powershell.exe',
                          '-NoLogo', '-NoProfile', '-NonInteractive', '-File', str(HERE / 'uia_driver.ps1')]
                         if desktop == 'windows11-x64' else ['/usr/bin/python3', str(HERE / 'atspi_driver.py')])
        self.driver_hash = sha(HERE / ('uia_driver.ps1' if desktop == 'windows11-x64' else 'atspi_driver.py'))

    def action(self, action, semantic=None, *, text=None, read_value=False, expected_hash=None, native_action=None, pin=None, allow_exit=False, window=None, text_range=None, text_hash=None, read_semantics=False):
        if action not in ('inspect', 'assert', 'wait', 'focus', 'invoke', 'select', 'scroll', 'set-text', 'read-text-range', 'select-text-range'):
            raise Pending('Native keyboard, clipboard, screen-reader, IME or system-session action requires explicit manual evidence.')
        self.artifact.verify()
        owner = self.child.identity()
        selector = None
        if semantic:
            selector = self.contract.get('selectors', {}).get(semantic)
            if not selector:
                raise Pending('Required real native semantic selector is unavailable.')
            if (selector.get('identitySensitive') or pin is not None) and not selector.get('nativeId'):
                raise Pending('Original row/result/capture native identity is unavailable.')
        if text_range is not None or action in ('read-text-range', 'select-text-range') or read_semantics:
            if not selector or selector.get('secret') or not selector.get('nativeId') or pin is None:
                raise Pending('Original observed nonsecret native identity and retained binding are required.')
        window_name = window or 'main'
        window_selector = self.contract['window'] if window is None else self.contract.get('windows', {}).get(window)
        if not window_selector:
            raise Pending('Observed owned native dialog/window selector is required.')
        window_key = self.window_keys.get(window_name)
        request = {'schemaVersion': 1, 'owner': owner, 'window': window_selector, 'selector': selector,
                   'action': action, 'readValue': read_value, 'disposableDesktopAcknowledged': self.acknowledged,
                   'expectExit': allow_exit, 'expectedWindowKey': window_key, 'expectedBinding': self.bindings.get(pin) if pin else None}
        if action in ('read-text-range', 'select-text-range'):
            request.update(textRange=text_range, expectedTextSha256=text_hash)
        if read_semantics:
            request['readSemantics'] = True
        if text is not None:
            request['text'] = text
        if native_action:
            request['nativeAction'] = native_action
        data = canonical(request)
        if len(data) > 65536:
            raise Refused('Native request exceeds bounds.')
        current_hash = sha(HERE / ('uia_driver.ps1' if self.desktop == 'windows11-x64' else 'atspi_driver.py'))
        if current_hash != self.driver_hash:
            raise Refused('Driver source changed during acceptance.')
        result = parse(bounded_call(self.commands, self.env, data, limit=8192, timeout=15))
        if not (allow_exit and self.child.process.poll() is not None):
            self.child.verify()
        self.artifact.verify()
        if (result.get('schemaVersion') != 1 or result.get('ownedPid') != self.child.process.pid
                or result.get('startTime') != self.child.start or result.get('actionCompleted') is not True):
            raise Refused('Native action lacks exact-owner completion.')
        if window_key is not None and result['windowKey'] != window_key:
            raise Refused('Original native window changed.')
        self.window_keys[window_name] = result['windowKey']
        if pin is not None:
            if pin in self.bindings and self.bindings[pin] != result['binding']:
                raise Refused('Original semantic target changed.')
            self.bindings[pin] = result['binding']
        if expected_hash is not None and result.get('valueSha256') != expected_hash:
            raise Refused('Native exact typed/text value hash differs.')
        return result

    def wait(self, semantic, *, expected_hash=None, focused=None, timeout=20, window=None, pin=None):
        deadline = time.monotonic() + min(timeout, 60)
        while time.monotonic() < deadline:
            try:
                result = self.action('wait', semantic, read_value=expected_hash is not None, window=window, pin=pin)
                if ((expected_hash is None or result.get('valueSha256') == expected_hash)
                        and (focused is None or result.get('focused') is focused)):
                    return result
            except Pending:
                raise
            except Refused:
                self.child.verify()
                self.artifact.verify()
            time.sleep(0.1)
        raise Refused('Native semantic condition timed out.')
