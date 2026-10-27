//! Selection identities are original rows, never positions in a sorted/filtered view.
use std::collections::BTreeSet;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct CellPoint {
    pub row: u64,
    pub column: usize,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(super) struct Selection {
    pub anchor: Option<CellPoint>,
    pub focus: Option<CellPoint>,
    pub rows: BTreeSet<u64>,
    pub columns: Option<std::ops::RangeInclusive<usize>>,
    pub whole_rows: bool,
}

impl Selection {
    pub fn select(
        &mut self,
        visible: &[u64],
        cell: CellPoint,
        extend: bool,
        whole: bool,
        columns: usize,
    ) {
        if columns == 0 || cell.column >= columns || !visible.contains(&cell.row) {
            return;
        }
        let anchor = self
            .anchor
            .filter(|a| extend && visible.contains(&a.row))
            .unwrap_or(cell);
        let a = visible.iter().position(|id| *id == anchor.row).unwrap();
        let b = visible.iter().position(|id| *id == cell.row).unwrap();
        self.rows = visible[a.min(b)..=a.max(b)].iter().copied().collect();
        self.columns = Some(if whole {
            0..=columns - 1
        } else {
            anchor.column.min(cell.column)..=anchor.column.max(cell.column)
        });
        self.anchor = Some(anchor);
        self.focus = Some(cell);
        self.whole_rows = whole;
    }

    pub fn toggle_row(&mut self, cell: CellPoint, columns: usize) {
        if columns == 0 {
            return;
        }
        if !self.rows.remove(&cell.row) {
            self.rows.insert(cell.row);
        }
        self.whole_rows = true;
        self.columns = (!self.rows.is_empty()).then_some(0..=columns - 1);
        self.focus = self
            .rows
            .contains(&cell.row)
            .then_some(cell)
            .or_else(|| self.rows.last().map(|&row| CellPoint { row, column: 0 }));
        self.anchor = self.focus;
    }

    pub fn retain(&mut self, rows: &[u64]) {
        self.rows.retain(|id| rows.contains(id));
        self.anchor = self.anchor.filter(|a| self.rows.contains(&a.row));
        self.focus = self.focus.filter(|a| self.rows.contains(&a.row));
        if self.focus.is_none() {
            *self = Self::default();
        }
    }
}
