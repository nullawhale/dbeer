//! Retained appearance Settings controls. Workspace owns preferences and stores.

mod model;
#[cfg(test)]
mod tests;
mod view;

pub type Presentation = model::Presentation;
pub type PersistenceState = model::PersistenceState;
pub type Choice = model::Choice;
pub type SettingsAction = model::SettingsAction;
pub type SettingsEvent = model::SettingsEvent;
pub type SettingsView = view::SettingsView;

pub fn section(
    id: &'static str,
    title: &'static str,
    description: &'static str,
    cx: &gpui_kit::App,
) -> gpui_kit::Stateful<gpui_kit::Div> {
    view::section(id, title, description, cx)
}

/// A fixed synthetic sample, never user source or a workspace document.
pub const PREVIEW_SQL: &str = include_str!("../fixtures/settings-appearance/preview.sql");
