//! Maintained DBeer AccessKit text extension; see DBEER-PATCH.md.
//! Text exists only in native assistive-technology state, never diagnostics.
use gpui::{
    A11ySubtreeBuilder,
    accesskit::{Node, NodeId, Role, TextPosition, TextSelection},
};
use std::{
    cell::{Cell, RefCell},
    rc::Rc,
};
use unicode_segmentation::UnicodeSegmentation as _;

pub(crate) const MAX_TEXT_BYTES: usize = 16 * 1024 * 1024;
const MAX_RUNS: usize = 65_536;

/// UI-thread-only captured action ownership. Retain one with the original
/// EditorState. Invalidate BEFORE changing source/document/modal ownership and
/// pass the same guard to the next Editor/Input render. It carries no user data.
#[derive(Clone)]
pub struct InputAccessibilityGuard(Rc<Cell<u64>>, Option<Rc<NativeOwner>>);
type NativeOwner = dyn Fn(&mut gpui::Window, &mut gpui::App) -> bool;
impl Default for InputAccessibilityGuard {
    fn default() -> Self {
        Self(Rc::new(Cell::new(1)), None)
    }
}
impl InputAccessibilityGuard {
    /// Live owner validation runs immediately before every native action.
    pub fn with_owner(
        mut self,
        owner: impl Fn(&mut gpui::Window, &mut gpui::App) -> bool + 'static,
    ) -> Self {
        self.1 = Some(Rc::new(owner));
        self
    }
    pub(crate) fn allows(&self, window: &mut gpui::Window, cx: &mut gpui::App) -> bool {
        self.epoch() != 0 && self.1.as_ref().is_none_or(|owner| owner(window, cx))
    }
    pub fn invalidate(&self) {
        let epoch = self.0.get();
        self.0.set(if epoch == 0 {
            0
        } else {
            epoch.checked_add(1).unwrap_or(0)
        });
    }
    pub fn epoch(&self) -> u64 {
        self.0.get()
    }
}

#[derive(Default)]
pub(crate) struct TextCache {
    source: Option<Rc<str>>,
    revision: u64,
    generation: Rc<Cell<u64>>,
    guard: InputAccessibilityGuard,
}
impl TextCache {
    #[cfg(test)]
    pub(crate) fn capture(
        &mut self,
        text: String,
        guard: Option<InputAccessibilityGuard>,
    ) -> Rc<TextSnapshot> {
        self.capture_with_revision(text, guard, 0)
    }
    pub(crate) fn capture_with_revision(
        &mut self,
        text: String,
        guard: Option<InputAccessibilityGuard>,
        revision: u64,
    ) -> Rc<TextSnapshot> {
        if self.source.as_deref() != Some(text.as_str()) || self.revision != revision {
            self.revision = revision;
            let current = self.generation.get();
            self.generation
                .set(if current == 0 && self.source.is_some() {
                    0
                } else {
                    current.checked_add(1).unwrap_or(0)
                });
            self.source = Some(text.into());
        }
        let source = self.source.clone().unwrap_or_else(|| Rc::from(""));
        let guard = guard.unwrap_or_else(|| self.guard.clone());
        let epoch = guard.epoch();
        let generation = self.generation.get();
        let runs = text_runs(&source);
        Rc::new(TextSnapshot {
            source,
            runs,
            ids: RefCell::new(Vec::new()),
            bounds: RefCell::new(Vec::new()),
            revision,
            generation,
            current_generation: self.generation.clone(),
            guard,
            epoch,
        })
    }
}
struct Run {
    start: usize,
    end: usize,
    offsets: Vec<usize>,
    lengths: Vec<u8>,
}
pub(crate) struct TextSnapshot {
    source: Rc<str>,
    runs: Option<Vec<Run>>,
    ids: RefCell<Vec<NodeId>>,
    bounds: RefCell<Vec<Option<gpui::accesskit::Rect>>>,
    pub(crate) revision: u64,
    generation: u64,
    current_generation: Rc<Cell<u64>>,
    guard: InputAccessibilityGuard,
    epoch: u64,
}
impl TextSnapshot {
    pub(crate) fn allows(&self, window: &mut gpui::Window, cx: &mut gpui::App) -> bool {
        self.current() && self.guard.allows(window, cx)
    }
    pub(crate) fn invalidate(&self) {
        self.guard.invalidate();
    }
    pub(crate) fn source(&self) -> &str {
        &self.source
    }
    pub(crate) fn current(&self) -> bool {
        self.epoch != 0
            && self.generation != 0
            && self.guard.epoch() == self.epoch
            && self.current_generation.get() == self.generation
    }
    pub(crate) fn has_text(&self) -> bool {
        self.runs.is_some()
    }
    pub(crate) fn measure(
        &self,
        mut measured: impl FnMut(&std::ops::Range<usize>) -> Option<gpui::Bounds<gpui::Pixels>>,
    ) {
        let Some(runs) = &self.runs else {
            return;
        };
        let mut bounds = self.bounds.borrow_mut();
        bounds.clear();
        for run in runs {
            let text = &self.source[run.start..run.end];
            let end = run.start + text.trim_end_matches(['\r', '\n']).len();
            bounds.push(
                measured(&(run.start..end)).map(|bounds| gpui::accesskit::Rect {
                    x0: f32::from(bounds.origin.x) as f64,
                    y0: f32::from(bounds.origin.y) as f64,
                    x1: f32::from(bounds.origin.x + bounds.size.width) as f64,
                    y1: f32::from(bounds.origin.y + bounds.size.height) as f64,
                }),
            );
        }
    }
    pub(crate) fn publish(&self, builder: &mut A11ySubtreeBuilder, selection: (usize, usize)) {
        if !self.current() {
            return;
        }
        let Some(runs) = &self.runs else {
            return;
        };
        let mut ids = self.ids.borrow_mut();
        ids.clear();
        for (index, run) in runs.iter().enumerate() {
            let id =
                builder.synthetic_node_id(("dbeer-input-text", self.generation, self.epoch, index));
            let mut node = Node::new(Role::TextRun);
            node.set_value(self.source[run.start..run.end].to_owned());
            node.set_character_lengths(run.lengths.clone());
            if let Some(Some(bounds)) = self.bounds.borrow().get(index) {
                node.set_bounds(*bounds);
            }
            if !builder.push_child(id, node) {
                ids.clear();
                return;
            }
            ids.push(id);
        }
        let position = |offset: usize| -> TextPosition {
            let offset = offset.min(self.source.len());
            let index = runs
                .iter()
                .position(|run| offset < run.end)
                .unwrap_or(runs.len() - 1);
            let run = &runs[index];
            let local = offset.saturating_sub(run.start).min(run.end - run.start);
            let character_index = run
                .offsets
                .partition_point(|value| *value <= local)
                .saturating_sub(1);
            TextPosition {
                node: ids[index],
                character_index,
            }
        };
        builder.parent_node().set_text_selection(TextSelection {
            anchor: position(selection.0),
            focus: position(selection.1),
        });
    }
    pub(crate) fn selection_offsets(&self, selection: &TextSelection) -> Option<(usize, usize)> {
        if !self.current() {
            return None;
        }
        let runs = self.runs.as_ref()?;
        let ids = self.ids.borrow();
        let offset = |position: TextPosition| -> Option<usize> {
            let index = ids.iter().position(|id| *id == position.node)?;
            let run = runs.get(index)?;
            Some(run.start + *run.offsets.get(position.character_index)?)
        };
        Some((offset(selection.anchor)?, offset(selection.focus)?))
    }
}
fn text_runs(text: &str) -> Option<Vec<Run>> {
    if text.len() > MAX_TEXT_BYTES {
        return None;
    }
    let mut ranges = Vec::new();
    let mut start = 0;
    for line in text.split_inclusive('\n') {
        if ranges.len() >= MAX_RUNS {
            return None;
        }
        ranges.push((start, start + line.len()));
        start += line.len();
    }
    if text.is_empty() || text.ends_with('\n') {
        ranges.push((text.len(), text.len()));
    }
    if ranges.len() > MAX_RUNS {
        return None;
    }
    ranges
        .into_iter()
        .map(|(start, end)| {
            let mut offsets = Vec::new();
            let mut lengths = Vec::new();
            for (offset, grapheme) in text[start..end].grapheme_indices(true) {
                offsets.push(offset);
                // AccessKit's native character-length contract is u8. A larger
                // indivisible grapheme cannot honestly be split into editor units.
                lengths.push(u8::try_from(grapheme.len()).ok()?);
            }
            offsets.push(end - start);
            Some(Run {
                start,
                end,
                offsets,
                lengths,
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn native_utf8_grapheme_units_crlf_empty_and_final_caret_are_exact() {
        let source = "a\u{301} \u{1f469}\u{200d}\u{1f4bb}\r\n\u{4e2d}\n";
        let runs = text_runs(source).unwrap();
        assert_eq!(runs.len(), 3);
        assert_eq!(runs[0].lengths, vec![3, 1, 11, 2]);
        for run in &runs {
            assert_eq!(
                run.lengths.iter().map(|n| usize::from(*n)).sum::<usize>(),
                run.end - run.start
            );
        }
        assert_eq!(runs[2].offsets, vec![0]);
        assert_eq!(text_runs("").unwrap()[0].offsets, vec![0]);
    }
    #[test]
    fn numeric_source_revision_rejects_same_text_aba_and_geometry_is_optional() {
        let mut cache = TextCache::default();
        let old = cache.capture_with_revision("same".into(), None, 1);
        let current = cache.capture_with_revision("same".into(), None, 2);
        assert!(!old.current());
        assert!(current.current());
        current.measure(|_| None);
        assert_eq!(current.bounds.borrow().len(), 1);
        assert!(current.bounds.borrow()[0].is_none());
    }
    #[test]
    fn source_and_external_capture_invalidation_refuse_old_native_actions() {
        let mut cache = TextCache::default();
        let guard = InputAccessibilityGuard::default();
        let first = cache.capture("select 1".into(), Some(guard.clone()));
        assert!(first.current());
        let same = cache.capture("select 1".into(), Some(guard.clone()));
        assert!(first.current());
        assert!(same.current());
        let changed = cache.capture("select 2".into(), Some(guard.clone()));
        assert!(!first.current());
        assert!(changed.current());
        guard.invalidate();
        assert!(!changed.current());
    }
    #[test]
    fn stale_or_foreign_run_ids_and_invalid_character_indexes_refuse() {
        let mut cache = TextCache::default();
        let snapshot = cache.capture("abc".into(), None);
        snapshot.ids.borrow_mut().push(NodeId(41));
        let position = |node, character_index| TextPosition {
            node: NodeId(node),
            character_index,
        };
        assert_eq!(
            snapshot.selection_offsets(&TextSelection {
                anchor: position(41, 3),
                focus: position(41, 1)
            }),
            Some((3, 1))
        );
        assert!(
            snapshot
                .selection_offsets(&TextSelection {
                    anchor: position(42, 0),
                    focus: position(41, 1)
                })
                .is_none()
        );
        assert!(
            snapshot
                .selection_offsets(&TextSelection {
                    anchor: position(41, 4),
                    focus: position(41, 1)
                })
                .is_none()
        );
    }
    #[test]
    fn bound_exhaustion_and_oversized_indivisible_grapheme_fail_closed() {
        let giant = format!("a{}", "\u{301}".repeat(128));
        assert!(text_runs(&giant).is_none());
        let guard = InputAccessibilityGuard::default();
        guard.0.set(u64::MAX);
        guard.invalidate();
        assert_eq!(guard.epoch(), 0);
        guard.invalidate();
        assert_eq!(guard.epoch(), 0);
    }
}
