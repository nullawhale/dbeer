//! Retained shortcut Settings section. Workspace owns the authoritative value
//! and store; this section emits revision/epoch-bound requests only.

mod model;
#[cfg(test)]
mod tests;
mod view;

pub type Action = model::Action;
#[cfg(test)]
pub type Edit = model::Edit;
pub type Event = model::Event;
#[cfg(all(test, feature = "native-smoke"))]
pub type MappingSource = model::MappingSource;
pub type PersistenceState = model::PersistenceState;
pub type Presentation = model::Presentation;
pub type ShortcutSettingsView = view::ShortcutSettingsView;
