//! Faithful public Element-path alternative for the maintained Div disabled unit.
use gpui_kit::{Element, InteractiveElement, StatefulInteractiveElement, accesskit, div};

#[test]
fn test_explicit_disabled_semantics_preserve_the_unspecified_default() {
    let ordinary = div().id("ordinary-disabled-state");
    let mut node = accesskit::Node::new(accesskit::Role::Button);
    ordinary.write_a11y_info(&mut node);
    assert!(!node.is_disabled());
    let disabled = div().id("explicit-disabled-state").aria_disabled(true);
    let mut node = accesskit::Node::new(accesskit::Role::Button);
    disabled.write_a11y_info(&mut node);
    assert!(node.is_disabled());
    let enabled = div().id("explicit-enabled-state").aria_disabled(false);
    let mut node = accesskit::Node::new(accesskit::Role::Button);
    enabled.write_a11y_info(&mut node);
    assert!(!node.is_disabled());
}
