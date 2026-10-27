#!/usr/bin/env python3
"""Test-only native AT-SPI driver. Never enumerates foreign application children."""
import hashlib
import json
import os
from pathlib import Path
import sys
sys.dont_write_bytecode = True

# No tree/name/value dump is ever written, including on failure.
def main():
    import gi
    gi.require_version('Atspi', '2.0')
    from gi.repository import Atspi
    from core import parse, sha, Refused
    request = parse(sys.stdin.buffer.read(65537))
    if len(json.dumps(request)) > 65536:
        raise Refused('Request limit.')
    owner = request['owner']
    pid = owner['pid']
    def verify():
        data = Path('/proc', str(pid), 'stat').read_text()
        start = data[data.rfind(')') + 2:].split()[19]
        if (start != owner['startTime'] or Path('/proc', str(pid), 'exe').resolve() != Path(owner['executable'])
                or sha(owner['executable']) != owner['sha256']):
            raise Refused('Owned process changed.')
    verify()
    desktop = Atspi.get_desktop(0)
    apps = [desktop.get_child_at_index(i) for i in range(desktop.get_child_count())]
    apps = [app for app in apps if app.get_process_id() == pid]
    if len(apps) != 1:
        raise Refused('Exact owned AT-SPI application unavailable.')
    app = apps[0]
    windows = [app.get_child_at_index(i) for i in range(app.get_child_count())]
    windows = [w for w in windows if w.get_process_id() == pid and w.get_role_name() in ('frame', 'dialog', 'window')]
    selector = request['window']
    windows = [w for w in windows if w.get_role_name() == selector['role'] and w.get_name() == selector['name']]
    if len(windows) != 1:
        raise Refused('Exact owned window is ambiguous or absent.')
    window = windows[0]
    # ACTIVE belongs to the owned toplevel. No desktop keyboard/mouse synthesis.
    active = window.get_state_set().contains(Atspi.StateType.ACTIVE)
    action = request['action']
    readonly = ('inspect', 'assert', 'wait', 'read-text-range')
    if action not in readonly and (not request.get('disposableDesktopAcknowledged') or not active):
        raise Refused('Owned foreground/disposable desktop required.')
    target = request.get('selector')
    node = window
    def aid(item):
        # This property is optional. Never equate a GPUI ElementId to this ID.
        getter = getattr(item, 'get_accessible_id', None)
        return getter() if getter else ''
    if target:
        if target.get('identitySensitive') and not target.get('nativeId'):
            raise Refused('Stable original identity is required.')
        matches, stack, count = [], [(window, [])], 0
        while stack:
            item, parents = stack.pop()
            count += 1
            if count > 8192 or len(parents) > 64:
                raise Refused('Tree bound.')
            if item.get_process_id() != pid:
                continue
            role, name = item.get_role_name(), item.get_name()
            matches_self = role == target['role'] and (target.get('name') is None or name == target['name'])
            if target.get('nativeId'):
                matches_self = matches_self and aid(item) == target['nativeId']
            expected = target.get('ancestors', [])
            if matches_self and len(parents) >= len(expected):
                actual = parents[-len(expected):] if expected else []
                if all(a['role'] == b[0] and (a.get('nativeId') is None or a['nativeId'] == b[1]) for a, b in zip(expected, actual)):
                    matches.append(item)
            for index in range(item.get_child_count() - 1, -1, -1):
                stack.append((item.get_child_at_index(index), [*parents, (role, aid(item))]))
        if len(matches) != 1:
            raise Refused('Semantic target is ambiguous or unavailable.')
        node = matches[0]
    verify()
    window_path, node_path = getattr(window, 'path', None), getattr(node, 'path', None)
    if not window_path or not node_path:
        raise Refused('Native object lifetime path is unavailable.')
    window_key = hashlib.sha256((str(pid) + ':' + owner['startTime'] + ':' + window_path + ':' + aid(window)).encode()).hexdigest()
    binding = hashlib.sha256((window_key + ':' + node_path + ':' + aid(node)).encode()).hexdigest()
    if request.get('expectedWindowKey') not in (None, window_key) or request.get('expectedBinding') not in (None, binding):
        raise Refused('Original native target changed before action.')
    state = node.get_state_set()
    if action not in readonly:
        if not state.contains(Atspi.StateType.ENABLED) or not state.contains(Atspi.StateType.SENSITIVE):
            raise Refused('Target disabled.')
        if not window.get_state_set().contains(Atspi.StateType.ACTIVE):
            raise Refused('Owned foreground changed.')
    focused = state.contains(Atspi.StateType.FOCUSED)
    def bounded_text(interface):
        count = Atspi.Text.get_character_count(interface)
        if not 0 <= count <= 65536:
            raise Refused('Original native text exceeds bounded range support.')
        value = Atspi.Text.get_text(interface, 0, count)
        if len(value.encode()) > 65536:
            raise Refused('Original native text exceeds bounded range support.')
        return value
    if request.get('expectExit') and action != 'invoke':
        raise Refused('Only an actual common close invocation may expect exit.')
    if action == 'focus':
        if not Atspi.Component.grab_focus(node.get_component_iface()):
            raise Refused('Native focus refused.')
    elif action in ('invoke', 'select', 'scroll'):
        interface = node.get_action_iface()
        wanted = request.get('nativeAction', 'click' if action == 'invoke' else action)
        indices = [i for i in range(Atspi.Action.get_n_actions(interface)) if Atspi.Action.get_name(interface, i) == wanted]
        if len(indices) != 1 or not Atspi.Action.do_action(interface, indices[0]):
            raise Refused('Exact native action unavailable.')
    elif action == 'set-text':
        if target and target.get('identitySensitive'):
            raise Refused('Direct cell edit bypass refused.')
        if not Atspi.EditableText.set_text_contents(node.get_editable_text_iface(), request['text']):
            raise Refused('Native text action refused.')
    elif action == 'select-text-range':
        from text_contract import codepoint_offset
        if not target or target.get('secret') or not target.get('nativeId'):
            raise Refused('Original nonsecret text identity required.')
        interface = node.get_text_iface()
        value = bounded_text(interface)
        if len(value.encode()) > 65536 or hashlib.sha256(value.encode()).hexdigest() != request['expectedTextSha256']:
            raise Refused('Original fixed text changed before range selection.')
        first = codepoint_offset(value, request['textRange']['start'])
        last = codepoint_offset(value, request['textRange']['end'])
        count = Atspi.Text.get_n_selections(interface)
        if count not in (0, 1):
            raise Refused('Selection would replace unrelated native ranges.')
        verify()
        if not window.get_state_set().contains(Atspi.StateType.ACTIVE):
            raise Refused('Original foreground changed before range selection.')
        if first == last:
            accepted = Atspi.Text.set_caret_offset(interface, first)
        elif count == 1:
            accepted = Atspi.Text.set_selection(interface, 0, first, last)
        else:
            accepted = Atspi.Text.add_selection(interface, first, last)
        if not accepted:
            raise Refused('Original native text selection refused.')
    elif action not in readonly:
        raise Refused('Manual native capability required.')
    if not request.get('expectExit'):
        verify()
        focused = node.get_state_set().contains(Atspi.StateType.FOCUSED)
    text_hash = None
    if request.get('readValue'):
        if not target or target.get('secret'):
            raise Refused('Secret value capture refused.')
        property_name = target.get('valueProperty', 'text')
        if property_name == 'name':
            value = node.get_name()
        elif property_name == 'description':
            value = node.get_description()
        elif property_name == 'text':
            value = bounded_text(node.get_text_iface())
        else:
            raise Refused('Observed native text property is unsupported.')
        if len(value.encode()) > 65536:
            raise Refused('Original native value exceeds bounds.')
        text_hash = hashlib.sha256(value.encode()).hexdigest()
    text_range = None
    if action in ('read-text-range', 'select-text-range'):
        from text_contract import utf16_length
        if not target or target.get('secret') or not target.get('nativeId'):
            raise Refused('Original nonsecret text identity required.')
        interface = node.get_text_iface()
        value = bounded_text(interface)
        if len(value.encode()) > 65536 or hashlib.sha256(value.encode()).hexdigest() != request['expectedTextSha256']:
            raise Refused('Original source changed during text-range read.')
        count = Atspi.Text.get_n_selections(interface)
        if not 0 <= count <= 16:
            raise Refused('Original text selection count exceeds bounds.')
        spans = []
        if count == 0:
            caret = Atspi.Text.get_caret_offset(interface)
            if not 0 <= caret <= len(value):
                raise Refused('Original caret is unavailable.')
            spans.append((caret, caret))
        else:
            for index in range(count):
                selection = Atspi.Text.get_selection(interface, index)
                spans.append((selection.start_offset, selection.end_offset))
        if any(not 0 <= first <= last <= len(value) for first, last in spans):
            raise Refused('Original text range is invalid.')
        text_range = {'textSha256': hashlib.sha256(value.encode()).hexdigest(), 'utf16Length': utf16_length(value),
                      'selections': [{'start': utf16_length(value[:first]), 'end': utf16_length(value[:last]),
                                      'textSha256': hashlib.sha256(value[first:last].encode()).hexdigest()}
                                     for first, last in spans]}
    semantics = None
    if request.get('readSemantics'):
        if not target or target.get('secret'):
            raise Refused('Secret/native semantic capture refused.')
        state = node.get_state_set()
        semantics = {'enabled': state.contains(Atspi.StateType.ENABLED) and state.contains(Atspi.StateType.SENSITIVE),
                     'focused': state.contains(Atspi.StateType.FOCUSED),
                     'nameSha256': hashlib.sha256(node.get_name().encode()).hexdigest(),
                     'descriptionSha256': hashlib.sha256(node.get_description().encode()).hexdigest()}
        if state.contains(Atspi.StateType.SELECTABLE):
            semantics['selected'] = state.contains(Atspi.StateType.SELECTED)
        interface = node.get_text_iface()
        if interface is not None:
            semantics['readOnly'] = not state.contains(Atspi.StateType.EDITABLE)
        table = node.get_table_iface()
        if table is not None:
            semantics.update(rowCount=Atspi.Table.get_n_rows(table), columnCount=Atspi.Table.get_n_columns(table))
        cell = node.get_table_cell_iface()
        if cell is not None:
            if not state.contains(Atspi.StateType.VISIBLE) or not state.contains(Atspi.StateType.SHOWING):
                raise Refused('Unrealized grid position cannot provide native evidence.')
            row, column, row_span, column_span = Atspi.TableCell.get_row_column_span(cell)
            semantics.update(row=row, column=column, rowSpan=row_span, columnSpan=column_span)
    verify()
    # IDs are retained in memory as opaque hashes; no app labels/values returned.
    print(json.dumps({'schemaVersion': 1, 'ownedPid': pid, 'startTime': owner['startTime'], 'windowKey': window_key,
                      'binding': binding, 'focused': focused,
                      'active': active, 'valueSha256': text_hash, 'actionCompleted': True,
                      'textRange': text_range, 'semantics': semantics}))

if __name__ == '__main__':
    try:
        main()
    except Exception:
        # Native exceptions may include accessible values, paths or D-Bus details.
        print('{"schemaVersion":1,"refused":true}')
        sys.exit(2)
