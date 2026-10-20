//! Captured native accessibility semantics. Values are intentionally available to
//! assistive technology, never diagnostic output. See PLATFORM_CORE.md before
//! connecting this to a retained widget; this module does not fabricate a second
//! visual tree or replace the editor's native text/IME implementation.

// Portable contracts and target-only native entry points share this module.
#![allow(dead_code, unused_imports)]

#[path = "accessibility/grid.rs"]
mod grid;
#[path = "accessibility/model.rs"]
mod model;
#[path = "accessibility/native.rs"]
mod native;
#[path = "accessibility/workspace.rs"]
mod workspace;
pub(crate) use workspace::*;

pub(crate) use grid::*;
pub(crate) use model::*;
pub(crate) use native::{NativeActionHandler, container, decorate, retained_editor};

#[cfg(test)]
#[path = "../vendor/gpui-component/src/input/accessibility.rs"]
mod text_contract;

#[cfg(test)]
#[path = "../vendor/gpui-pre-linux/src/linux/keyboard_safety.rs"]
mod keyboard_safety_contract;

impl crate::workspace::Workspace {
    /// Synchronous input/common command entry precedes any source, selection or
    /// modal mutation. Native actions separately revalidate current retained owners.
    pub(super) fn invalidate_native_actions(&self, cx: &mut gpui_kit::App) {
        self.publish_close_readiness();
        for tab in &self.tabs {
            tab.accessibility_guard.invalidate();
            for grid in tab.grid.iter().chain(tab.grid_views.values()) {
                grid.update(cx, |table, _| {
                    table.delegate_mut().invalidate_accessibility()
                });
            }
        }
    }
}
