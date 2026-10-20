use gpui_kit::accesskit::{Action, ActionData, Role};
use std::{
    cell::RefCell,
    collections::BTreeMap,
    rc::Rc,
    thread::{self, ThreadId},
};

pub(crate) const MAX_NODES: usize = 8192;
const MAX_DEPTH: usize = 64;
pub(crate) const MAX_VALUE_BYTES: usize = 16 * 1024 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub(crate) enum NodePart {
    Control,
    Grid,
    Header,
    Row,
    Cell,
}

/// Uses original loaded row IDs/column ordinals, never display strings, SQL,
/// primary-key values, database names, addresses or credentials.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub(crate) struct NodeKey {
    pub document: u128,
    pub surface: u32,
    pub part: NodePart,
    pub instance: u64,
    pub item: u64,
    pub column: u32,
}

/// Capture all owners of an asynchronous action. Selection/source/draft edits
/// increment revision; result replacement increments result/snapshot. A modal
/// owner changes owner. A NodeKey survives selection/viewport changes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Capture {
    pub document: u128,
    pub result: u64,
    pub snapshot: u64,
    pub revision: u64,
    pub owner: u64,
}

/// Deliberately has no Debug/Serialize implementation.
#[derive(Clone, PartialEq, Eq)]
pub(crate) enum Value {
    Null,
    Empty,
    Text(String),
    Binary { base64: String, byte_count: usize },
    Default,
}
impl Value {
    pub(crate) fn text(&self) -> &str {
        match self {
            Self::Null => "NULL",
            Self::Empty => "",
            Self::Text(value) => value,
            Self::Binary { base64, .. } => base64,
            Self::Default => "DEFAULT",
        }
    }
    pub(crate) fn kind_description(&self) -> String {
        match self {
            Self::Null => "SQL NULL".into(),
            Self::Empty => "Empty string".into(),
            Self::Text(value) if value.is_empty() => "Empty string".into(),
            Self::Text(_) => "Text value".into(),
            Self::Binary { byte_count, .. } => format!("Binary value; {byte_count} bytes; Base64"),
            Self::Default => "Database DEFAULT assignment".into(),
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct GridMetadata {
    /// AccessKit indexes are zero-based, including virtualized rows. This is
    /// the display position; NodeKey uses original source identity separately.
    pub row_index: Option<usize>,
    pub column_index: Option<usize>,
    pub row_count: Option<usize>,
    pub column_count: Option<usize>,
}

/// Bounds refer only to the rendered/realized slice. Do not expand this to all
/// server rows. Scrolling actions ask the retained grid to realize another slice.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Viewport {
    pub first_row: usize,
    pub end_row: usize,
    pub total_rows: usize,
    pub first_column: usize,
    pub end_column: usize,
    pub total_columns: usize,
}
impl Viewport {
    pub(super) fn valid(self) -> bool {
        self.first_row <= self.end_row
            && self.end_row <= self.total_rows
            && self.first_column <= self.end_column
            && self.end_column <= self.total_columns
    }
}

/// Counts include offscreen selection without materializing unbounded children.
/// Each realized Row/GridCell still receives its exact selected state.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct SelectionSummary {
    pub full_rows: usize,
    pub sparse_cells: usize,
}

/// No Debug: names, descriptions and values can contain user data.
#[derive(Clone)]
pub(crate) struct SemanticNode {
    pub key: NodeKey,
    pub capture: Capture,
    pub parent: Option<NodeKey>,
    pub role: Role,
    pub name: String,
    pub description: String,
    pub value: Option<Value>,
    pub grid: GridMetadata,
    pub viewport: Option<Viewport>,
    pub selection: Option<SelectionSummary>,
    pub selected: Option<bool>,
    pub read_only: bool,
    pub disabled: bool,
    pub multiselectable: bool,
    pub active_descendant: bool,
    pub actions: Vec<Action>,
}
impl SemanticNode {
    pub(crate) fn native_id(&self) -> String {
        let key = self.key;
        format!(
            "dbeer-{}-{}-{:?}-{}-{}-{}-{}-{}",
            key.document,
            key.surface,
            key.part,
            key.instance,
            key.item,
            key.column,
            self.capture.result,
            self.capture.snapshot
        )
    }
    pub(crate) fn description_with_state(&self) -> String {
        let mut pieces = vec![self.description.clone()];
        if let Some(value) = &self.value {
            pieces.push(value.kind_description());
        }
        if let Some(selection) = self.selection {
            pieces.push(format!(
                "{} full rows and {} individual cells selected",
                selection.full_rows, selection.sparse_cells
            ));
        }
        if let Some(viewport) = self.viewport {
            pieces.push(format!(
                "Rows {} through {} of {}; columns {} through {} of {} realized",
                viewport
                    .first_row
                    .saturating_add(1)
                    .min(viewport.total_rows),
                viewport.end_row,
                viewport.total_rows,
                viewport
                    .first_column
                    .saturating_add(1)
                    .min(viewport.total_columns),
                viewport.end_column,
                viewport.total_columns
            ));
        }
        pieces.retain(|piece| !piece.is_empty());
        pieces.join(". ")
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum TreeError {
    WrongThread,
    TooManyNodes,
    TooMuchText,
    DuplicateIdentity,
    InvalidParent,
    InvalidFocus,
    InvalidGrid,
    InvalidAction,
    InvalidCapture,
    InvalidValue,
    GenerationExhausted,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Binding {
    pub(crate) publication: u64,
    pub(crate) key: NodeKey,
    pub(crate) capture: Capture,
}

/// Owned only on the UI thread. Rc additionally makes the actual bridge !Send
/// and !Sync. Native adapter callbacks marshal to GPUI's UI executor before
/// reaching decorate's handlers; no cross-thread UI borrow is permitted.
pub(crate) struct RetainedTree {
    thread: ThreadId,
    publication: u64,
    nodes: BTreeMap<NodeKey, SemanticNode>,
    focus: Option<NodeKey>,
}
pub(crate) type SharedTree = Rc<RefCell<RetainedTree>>;
impl RetainedTree {
    pub(crate) fn new() -> SharedTree {
        Rc::new(RefCell::new(Self {
            thread: thread::current().id(),
            publication: 0,
            nodes: BTreeMap::new(),
            focus: None,
        }))
    }
    fn check_thread(&self) -> Result<(), TreeError> {
        if self.thread == thread::current().id() {
            Ok(())
        } else {
            Err(TreeError::WrongThread)
        }
    }
    /// Atomically replace a complete semantic capture. Failed validation retains
    /// the last valid tree. Caller must also invalidate before removing a widget,
    /// opening a modal, editing a source/draft, or replacing any captured owner.
    pub(crate) fn publish(
        &mut self,
        nodes: Vec<SemanticNode>,
        focus: Option<NodeKey>,
    ) -> Result<(), TreeError> {
        self.check_thread()?;
        if nodes.len() > MAX_NODES {
            return Err(TreeError::TooManyNodes);
        }
        let mut bytes = 0usize;
        let mut next = BTreeMap::new();
        for node in nodes {
            bytes = bytes
                .saturating_add(node.name.len())
                .saturating_add(node.description.len())
                .saturating_add(node.value.as_ref().map_or(0, |v| v.text().len()));
            if bytes > MAX_VALUE_BYTES {
                return Err(TreeError::TooMuchText);
            }
            if node.role == Role::PasswordInput && node.value.is_some() {
                return Err(TreeError::InvalidValue);
            }
            if node.key.document != node.capture.document {
                return Err(TreeError::InvalidCapture);
            }
            if node.viewport.is_some_and(|v| !v.valid()) {
                return Err(TreeError::InvalidGrid);
            }
            if node
                .grid
                .row_index
                .zip(node.grid.row_count)
                .is_some_and(|(i, n)| i >= n)
                || node
                    .grid
                    .column_index
                    .zip(node.grid.column_count)
                    .is_some_and(|(i, n)| i >= n)
            {
                return Err(TreeError::InvalidGrid);
            }
            if node.disabled && !node.actions.is_empty() {
                return Err(TreeError::InvalidAction);
            }
            if node.actions.iter().any(|action| {
                !supported(*action)
                    || (node.read_only
                        && matches!(action, Action::SetValue | Action::ReplaceSelectedText))
            }) {
                return Err(TreeError::InvalidAction);
            }
            if next.insert(node.key, node).is_some() {
                return Err(TreeError::DuplicateIdentity);
            }
        }
        for node in next.values() {
            let mut parent = node.parent;
            let mut depth = 0;
            while let Some(key) = parent {
                depth += 1;
                if depth > MAX_DEPTH || key == node.key {
                    return Err(TreeError::InvalidParent);
                }
                parent = next.get(&key).ok_or(TreeError::InvalidParent)?.parent;
            }
        }
        if focus.is_some_and(|key| !next.contains_key(&key)) {
            return Err(TreeError::InvalidFocus);
        }
        let publication = self
            .publication
            .checked_add(1)
            .ok_or(TreeError::GenerationExhausted)?;
        self.nodes = next;
        self.focus = focus;
        self.publication = publication;
        Ok(())
    }
    pub(crate) fn invalidate(&mut self) {
        // Exhaustion fails closed by removing every target even if the epoch
        // cannot advance; a subsequent publish will refuse.
        self.publication = self.publication.saturating_add(1);
        self.nodes.clear();
        self.focus = None;
    }
    pub(crate) fn binding(&self, key: NodeKey) -> Option<(Binding, SemanticNode)> {
        self.check_thread().ok()?;
        let node = self.nodes.get(&key)?;
        Some((
            Binding {
                publication: self.publication,
                key,
                capture: node.capture,
            },
            node.clone(),
        ))
    }
    pub(crate) fn accepts(
        &self,
        binding: Binding,
        action: Action,
        data: Option<&ActionData>,
    ) -> bool {
        if self.check_thread().is_err() || binding.publication != self.publication {
            return false;
        }
        let Some(node) = self.nodes.get(&binding.key) else {
            return false;
        };
        !node.disabled
            && node.capture == binding.capture
            && node.actions.contains(&action)
            && valid_data(action, data)
    }
}
fn supported(action: Action) -> bool {
    matches!(
        action,
        Action::Focus
            | Action::Blur
            | Action::Click
            | Action::ShowContextMenu
            | Action::ScrollIntoView
            | Action::ScrollDown
            | Action::ScrollUp
            | Action::ScrollLeft
            | Action::ScrollRight
            | Action::SetValue
            | Action::ReplaceSelectedText
            | Action::SetTextSelection
            | Action::Expand
            | Action::Collapse
    )
}
fn valid_data(action: Action, data: Option<&ActionData>) -> bool {
    match action {
        Action::SetValue | Action::ReplaceSelectedText => {
            matches!(data, Some(ActionData::Value(value)) if value.len() <= MAX_VALUE_BYTES)
        }
        Action::SetTextSelection => matches!(data, Some(ActionData::SetTextSelection(_))),
        Action::ScrollIntoView => data.is_none() || matches!(data, Some(ActionData::ScrollHint(_))),
        Action::ScrollDown | Action::ScrollUp | Action::ScrollLeft | Action::ScrollRight => {
            data.is_none() || matches!(data, Some(ActionData::ScrollUnit(_)))
        }
        _ => data.is_none(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn node(item: u64) -> SemanticNode {
        SemanticNode {
            key: NodeKey {
                document: 1,
                surface: 1,
                part: NodePart::Control,
                instance: 1,
                item,
                column: 0,
            },
            capture: Capture {
                document: 1,
                result: 2,
                snapshot: 3,
                revision: 4,
                owner: 0,
            },
            parent: None,
            role: Role::GridCell,
            name: "Cell".into(),
            description: String::new(),
            value: None,
            grid: GridMetadata::default(),
            viewport: None,
            selection: None,
            selected: None,
            read_only: true,
            disabled: false,
            multiselectable: false,
            active_descendant: false,
            actions: vec![Action::Focus],
        }
    }
    #[test]
    fn platform_value_fixture_preserves_exact_native_values_and_type_descriptions() {
        let fixture: serde_json::Value =
            serde_json::from_str(include_str!("../../fixtures/platform/semantic-values.json"))
                .unwrap();
        let cases = [
            ("sqlNull", Value::Null),
            ("empty", Value::Empty),
            ("literalNull", Value::Text("NULL".into())),
            ("exactNumeric", Value::Text("9007199254740993.0001".into())),
            (
                "binary",
                Value::Binary {
                    base64: "AAE=".into(),
                    byte_count: 2,
                },
            ),
            ("default", Value::Default),
        ];
        for (name, value) in cases {
            assert_eq!(fixture[name]["nativeValue"].as_str(), Some(value.text()));
            assert_eq!(
                fixture[name]["description"].as_str(),
                Some(value.kind_description().as_str())
            );
        }
    }
    #[test]
    fn values_keep_null_empty_literal_binary_exact_and_default_distinct() {
        let values = [
            Value::Null,
            Value::Empty,
            Value::Text("NULL".into()),
            Value::Binary {
                base64: "AAE=".into(),
                byte_count: 2,
            },
            Value::Text("9007199254740993.0001".into()),
            Value::Default,
        ];
        assert_eq!(values[0].text(), values[2].text());
        assert_ne!(values[0].kind_description(), values[2].kind_description());
        assert_eq!(values[1].text(), "");
        assert_eq!(values[3].text(), "AAE=");
        assert_eq!(values[4].text(), "9007199254740993.0001");
        assert_ne!(
            values[5].kind_description(),
            Value::Text("DEFAULT".into()).kind_description()
        );
    }
    #[test]
    fn old_callbacks_refuse_selection_source_modal_result_and_document_changes() {
        let tree = RetainedTree::new();
        let original = node(0);
        let key = original.key;
        tree.borrow_mut()
            .publish(vec![original.clone()], Some(key))
            .unwrap();
        let (binding, _) = tree.borrow().binding(key).unwrap();
        assert!(tree.borrow().accepts(binding, Action::Focus, None));
        for kind in 0..5 {
            tree.borrow_mut()
                .publish(vec![original.clone()], Some(key))
                .unwrap();
            let (old, _) = tree.borrow().binding(key).unwrap();
            let mut replacement = original.clone();
            match kind {
                0 => replacement.capture.revision += 1,
                1 => replacement.capture.result += 1,
                2 => replacement.capture.snapshot += 1,
                3 => replacement.capture.owner += 1,
                _ => {
                    replacement.capture.document += 1;
                    replacement.key.document += 1;
                }
            }
            let new_key = replacement.key;
            tree.borrow_mut()
                .publish(vec![replacement], Some(new_key))
                .unwrap();
            assert!(!tree.borrow().accepts(old, Action::Focus, None));
        }
        assert!(!tree.borrow().accepts(binding, Action::Focus, None));
        tree.borrow_mut().invalidate();
        assert!(tree.borrow().binding(key).is_none());
    }
    #[test]
    fn invalid_tree_is_atomic_and_cycles_duplicate_ids_and_bad_focus_refuse() {
        let tree = RetainedTree::new();
        let a = node(1);
        let mut b = node(2);
        tree.borrow_mut().publish(vec![a.clone()], None).unwrap();
        b.parent = Some(b.key);
        assert_eq!(
            tree.borrow_mut().publish(vec![b], None),
            Err(TreeError::InvalidParent)
        );
        assert!(tree.borrow().binding(a.key).is_some());
        assert_eq!(
            tree.borrow_mut().publish(vec![a.clone(), a.clone()], None),
            Err(TreeError::DuplicateIdentity)
        );
        assert_eq!(
            tree.borrow_mut().publish(vec![], Some(a.key)),
            Err(TreeError::InvalidFocus)
        );
    }
    #[test]
    fn source_row_identity_survives_virtual_position_and_selection_change() {
        let tree = RetainedTree::new();
        let mut a = node(723);
        a.grid = GridMetadata {
            row_index: Some(900),
            column_index: Some(0),
            row_count: Some(1000000),
            column_count: Some(10),
        };
        a.selected = Some(true);
        tree.borrow_mut()
            .publish(vec![a.clone()], Some(a.key))
            .unwrap();
        a.grid.row_index = Some(2);
        a.selected = Some(false);
        tree.borrow_mut()
            .publish(vec![a.clone()], Some(a.key))
            .unwrap();
        let (_, actual) = tree.borrow().binding(a.key).unwrap();
        assert_eq!(actual.key.item, 723);
        assert_eq!(actual.grid.row_index, Some(2));
    }
    #[test]
    fn bounds_read_only_disabled_and_action_data_are_enforced() {
        let tree = RetainedTree::new();
        let mut a = node(1);
        a.actions.push(Action::SetValue);
        assert_eq!(
            tree.borrow_mut().publish(vec![a.clone()], None),
            Err(TreeError::InvalidAction)
        );
        a.read_only = false;
        tree.borrow_mut().publish(vec![a.clone()], None).unwrap();
        let (binding, _) = tree.borrow().binding(a.key).unwrap();
        assert!(!tree.borrow().accepts(binding, Action::SetValue, None));
        assert!(tree.borrow().accepts(
            binding,
            Action::SetValue,
            Some(&ActionData::Value("x".into()))
        ));
        a.disabled = true;
        assert_eq!(
            tree.borrow_mut().publish(vec![a], None),
            Err(TreeError::InvalidAction)
        );
        assert_eq!(
            tree.borrow_mut()
                .publish((0..=MAX_NODES).map(|n| node(n as u64)).collect(), None),
            Err(TreeError::TooManyNodes)
        );
    }
}

#[cfg(test)]
mod thread_tests {
    use super::*;
    #[test]
    fn ui_thread_ownership_is_checked_before_publication_or_binding() {
        let tree = RetainedTree::new();
        let foreign = std::thread::spawn(|| std::thread::current().id())
            .join()
            .unwrap();
        tree.borrow_mut().thread = foreign;
        assert_eq!(
            tree.borrow_mut().publish(vec![], None),
            Err(TreeError::WrongThread)
        );
        assert!(
            tree.borrow()
                .binding(NodeKey {
                    document: 0,
                    surface: 0,
                    part: NodePart::Control,
                    instance: 0,
                    item: 0,
                    column: 0
                })
                .is_none()
        );
    }
}
