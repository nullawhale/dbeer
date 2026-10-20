use super::{Binding, NodeKey, SharedTree};
use gpui_kit::{
    App, Div, InteractiveElement, Stateful, StatefulInteractiveElement, Window,
    accesskit::{Action, ActionData},
    div,
};
use std::rc::Rc;

/// Runs only on GPUI's UI thread after both native marshaling and core capture
/// validation. The Workspace callback MUST recheck live document/result/draft/
/// modal ownership as well, then use the SAME retained focus/editor/grid/common
/// command route used by keyboard input. No direct helper calls or applying
/// writes is permitted here. Value/selection payloads must never be logged.
pub(crate) type NativeActionHandler =
    Rc<dyn Fn(Binding, Action, Option<&ActionData>, &mut Window, &mut App)>;

/// Decorate the ACTUAL rendered control container, with a stable `.id(...)`.
/// This is a native publishing route: GPUI writes these properties to AccessKit,
/// its existing Linux adapters emit AT-SPI, and its Windows adapter emits UIA.
/// Nothing is serialized or sent to an external accessibility process by us.
///
/// Parent/child visual wrappers MUST match SemanticNode.parent. Use this for
/// retained grid/table rows/cells, inspector/dialog/settings containers and
/// controls. Preserve the existing widget bounds and FocusHandle; the caller
/// supplies `.track_focus(...)` on real focus owners. For a grid with focus on
/// the container, set active_descendant on exactly the active realized cell.
///
/// The retained SQL EditorState owns keyboard/IME/text geometry. DO NOT
/// decorate its inner div or overlay a second input. Use retained_editor and
/// the maintained component's actual native TextRun/TextSelection/action route.
/// Guard invalidation must precede each source/document/modal-owner change.
///
/// Calling this requires a fresh published capture. None means the caller must
/// render without stale actions and schedule a new capture, never reuse a tree.
pub(crate) fn decorate<E: StatefulInteractiveElement>(
    mut element: E,
    tree: &SharedTree,
    key: NodeKey,
    handler: NativeActionHandler,
) -> Option<E> {
    let (binding, node) = tree.borrow().binding(key)?;
    let author_id = node.native_id();
    element = element
        .role(node.role)
        .accessibility_id(author_id)
        .aria_label(node.name.clone())
        .aria_description(node.description_with_state());
    if let Some(value) = &node.value {
        element = element.aria_value(value.text().to_owned());
    }
    if let Some(selected) = node.selected {
        element = element.aria_selected(selected);
    }
    if let Some(index) = node.grid.row_index {
        element = element.aria_row_index(index);
    }
    if let Some(index) = node.grid.column_index {
        element = element.aria_column_index(index);
    }
    if let Some(count) = node.grid.row_count {
        element = element.aria_row_count(count);
    }
    if let Some(count) = node.grid.column_count {
        element = element.aria_column_count(count);
    }
    if node.active_descendant {
        element = element.aria_active_descendant();
    }
    for action in node.actions.iter().copied() {
        let tree = Rc::clone(tree);
        let handler = Rc::clone(&handler);
        element = element.on_a11y_action(action, move |data, window, cx| {
            // Drop the RefCell borrow before calling Workspace, which may publish
            // a new capture or invalidate this one synchronously.
            let accepts = tree.borrow().accepts(binding, action, data);
            if accepts {
                handler(binding, action, data, window, cx);
            }
        });
    }
    Some(element.a11y_synthetic_children(move |builder| {
        let native = builder.parent_node();
        if node.read_only {
            native.set_read_only();
        }
        if node.disabled {
            native.set_disabled();
        }
        if node.multiselectable {
            native.set_multiselectable();
        }
    }))
}

/// Create the actual visual wrapper with its stable native identity. Add the
/// existing cell/control content and style/bounds to this same div. This avoids
/// an invisible duplicate tree and protects replaced-result IDs from reuse.
pub(crate) fn container(
    tree: &SharedTree,
    key: NodeKey,
    handler: NativeActionHandler,
) -> Option<Stateful<Div>> {
    let (_, node) = tree.borrow().binding(key)?;
    decorate(div().id(node.native_id()), tree, key, handler)
}

/// Keep the original EditorState entity and all of its editing/IME/Undo logic.
/// Maintained Editor -> Input publishes full value plus actual native text runs
/// and selection while accessibility is active. SetValue/ReplaceSelectedText
/// preserve Undo and honor readonly/disabled/composition/capture guards. This
/// hook also accepts Task 26's independent engine palette at the render boundary.
/// Native UIA/AT-SPI behavior still requires target compilation/acceptance.
pub(crate) fn retained_editor(
    state: &gpui_kit::Entity<gpui_kit::component::input::EditorState>,
    name: impl Into<gpui_kit::SharedString>,
    read_only: bool,
    disabled: bool,
    guard: gpui_kit::component::input::InputAccessibilityGuard,
    palette: Option<gpui_kit::base::input::InputEditorStyle>,
) -> gpui_kit::component::input::Editor {
    let editor = gpui_kit::component::input::Editor::new(state)
        .role(gpui_kit::Role::MultilineTextInput)
        .aria_label(name)
        .readonly(read_only)
        .disabled(disabled)
        .accessibility_guard(guard);
    match palette {
        Some(palette) => editor.editor_style(palette),
        None => editor,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::accessibility::{
        Capture, GridMetadata, NodePart, RetainedTree, SemanticNode, Value,
    };
    use gpui_kit::{
        Element,
        accesskit::{Node, Role},
    };
    #[test]
    fn actual_gpui_container_writes_native_role_identity_exact_value_and_metadata() {
        let key = NodeKey {
            document: 4,
            surface: 1,
            part: NodePart::Cell,
            instance: 2,
            item: 918,
            column: 7,
        };
        let capture = Capture {
            document: 4,
            result: 3,
            snapshot: 5,
            revision: 1,
            owner: 0,
        };
        let tree = RetainedTree::new();
        let semantic = SemanticNode {
            key,
            capture,
            parent: None,
            role: Role::GridCell,
            name: "Amount".into(),
            description: String::new(),
            value: Some(Value::Text("9007199254740993.0001".into())),
            grid: GridMetadata {
                row_index: Some(100),
                column_index: Some(2),
                row_count: Some(1000000),
                column_count: Some(10),
            },
            viewport: None,
            selection: None,
            selected: Some(true),
            read_only: true,
            disabled: false,
            multiselectable: false,
            active_descendant: false,
            actions: vec![Action::Focus, Action::ShowContextMenu],
        };
        let id = semantic.native_id();
        tree.borrow_mut().publish(vec![semantic], None).unwrap();
        let element = container(&tree, key, Rc::new(|_, _, _, _, _| {})).unwrap();
        assert_eq!(element.a11y_role(), Some(Role::GridCell));
        let mut native = Node::new(element.a11y_role().unwrap());
        element.write_a11y_info(&mut native);
        assert_eq!(native.author_id(), Some(id.as_str()));
        assert_eq!(native.value(), Some("9007199254740993.0001"));
        assert_eq!(native.row_index(), Some(100));
        assert_eq!(native.column_index(), Some(2));
        assert_eq!(native.row_count(), Some(1000000));
        assert_eq!(native.is_selected(), Some(true));
        assert!(native.supports_action(Action::ShowContextMenu));
        tree.borrow_mut().invalidate();
        assert!(container(&tree, key, Rc::new(|_, _, _, _, _| {})).is_none());
    }
}
