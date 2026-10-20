use super::PopupAction;
use crate::language_service::SignatureInformation;
use std::{ops::Range, rc::Rc};
use unicode_segmentation::UnicodeSegmentation;

pub(super) const VISIBLE_OVERLOADS: usize = 8;

/// Exact labels, order and active arguments supplied by Go. Display expansion
/// affects only composed-character highlighting; it never changes SQL semantics.
pub(super) struct Signatures {
    pub rows: Vec<Row>,
    pub active: usize,
}
pub(super) struct Row {
    pub label: Rc<str>,
    pub active_range: Option<Range<usize>>,
}
impl Signatures {
    pub fn new(signatures: Vec<SignatureInformation>, active: usize) -> Option<Self> {
        if signatures.is_empty() || signatures.len() > 32 || active >= signatures.len() {
            return None;
        }
        let mut rows = Vec::with_capacity(signatures.len());
        for signature in signatures {
            let mut end = 0;
            if signature.label.is_empty()
                || signature.label.len() > 8192
                || signature.parameter_ranges.len() > 256
                || signature.parameter_ranges.iter().any(|range| {
                    let invalid = range.start < end
                        || range.start >= range.end
                        || range.end > signature.label.len()
                        || !signature.label.is_char_boundary(range.start)
                        || !signature.label.is_char_boundary(range.end);
                    end = range.end;
                    invalid
                })
                || signature
                    .active_parameter
                    .is_some_and(|index| index >= signature.parameter_ranges.len())
            {
                return None;
            }
            let active_range = signature.active_parameter.and_then(|index| {
                display_range(&signature.label, &signature.parameter_ranges[index])
            });
            rows.push(Row {
                label: Rc::from(signature.label),
                active_range,
            });
        }
        Some(Self { rows, active })
    }

    /// Native Swift shows the selected/ranked overload first, then the original
    /// service order, capped at eight. Navigation exposes every retained overload.
    pub fn order(&self, selected: usize) -> Vec<usize> {
        std::iter::once(selected)
            .chain((0..self.rows.len()).filter(|index| *index != selected))
            .take(VISIBLE_OVERLOADS)
            .collect()
    }

    pub fn navigate(&self, selected: usize, action: PopupAction) -> Option<usize> {
        if selected >= self.rows.len() {
            return None;
        }
        match action {
            PopupAction::PreviousOverload => Some(selected.saturating_sub(1)),
            PopupAction::NextOverload => Some((selected + 1).min(self.rows.len() - 1)),
            PopupAction::ChooseOverload(index) if index < self.rows.len() => Some(index),
            _ => None,
        }
    }
}

fn display_range(label: &str, range: &Range<usize>) -> Option<Range<usize>> {
    let mut start = None;
    let mut end = None;
    for (offset, grapheme) in label.grapheme_indices(true) {
        let limit = offset + grapheme.len();
        if limit > range.start && offset < range.end {
            start.get_or_insert(offset);
            end = Some(limit);
        }
    }
    Some(start?..end?)
}
