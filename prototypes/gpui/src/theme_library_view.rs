//! Retained theme library Settings section; the owner controls all I/O and saves.
//! Production Settings retains this section and owns every asynchronous operation.

mod model;
#[cfg(test)]
mod tests;
mod view;

pub use model::{
    ImportMode, ImportRequest, ImportReview, LibraryAccess, LibraryAction, LibraryEvent,
    Presentation, PreviewToken, RemovalRequest, Workflow,
};
pub use view::ThemeLibraryView;

/// Fixed synthetic text. Never a document, helper request or query execution.
pub const PREVIEW_SQL: &str = include_str!("../fixtures/settings-theme-library/preview.sql");
