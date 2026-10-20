//! Compile-only dependency wiring. This library has no application entry point,
//! tests, window creation or credential/clipboard runtime calls.
pub fn shared_string(value: &'static str) -> gpui_kit::SharedString {
    value.into()
}
