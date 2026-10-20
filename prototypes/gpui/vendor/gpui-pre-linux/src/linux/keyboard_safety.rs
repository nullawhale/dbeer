//! DBeer native shortcut-recorder evidence, scoped to actual synchronous native
//! key dispatch. No process-wide hook, persisted key data, or synthesized event.
use std::cell::Cell;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KeyInputSafety {
    Clear,
    Composing,
    Unknown,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ComposeEvidence {
    Idle,
    Composing,
    Composed,
    Cancelled,
    Unavailable,
}
thread_local! { static CURRENT: Cell<Option<KeyInputSafety>> = const { Cell::new(None) }; }

/// Returns evidence only inside the original Wayland/X11 KeyDown handler on its
/// UI thread. None outside that dispatch, during repeat/KeyUp/synthetic events,
/// or on another thread. Consumers must separately check their actual retained
/// input's marked-text state, event repeat/priority and modifier restrictions.
pub fn current_key_input_safety() -> Option<KeyInputSafety> {
    CURRENT.with(Cell::get)
}
pub(crate) fn classify(
    raw_keysym_name: &str,
    compose: ComposeEvidence,
    has_preedit: bool,
) -> KeyInputSafety {
    if has_preedit
        || raw_keysym_name.starts_with("dead_")
        || raw_keysym_name == "Multi_key"
        || compose == ComposeEvidence::Composing
    {
        return KeyInputSafety::Composing;
    }
    if raw_keysym_name.is_empty() || raw_keysym_name == "NoSymbol" {
        return KeyInputSafety::Unknown;
    }
    match compose {
        ComposeEvidence::Idle | ComposeEvidence::Composed => KeyInputSafety::Clear,
        _ => KeyInputSafety::Unknown,
    }
}
pub(crate) fn with_key_input_safety<R>(safety: KeyInputSafety, callback: impl FnOnce() -> R) -> R {
    struct Restore(Option<KeyInputSafety>);
    impl Drop for Restore {
        fn drop(&mut self) {
            CURRENT.with(|current| current.set(self.0));
        }
    }
    let previous = CURRENT.with(|current| current.replace(Some(safety)));
    let _restore = Restore(previous);
    callback()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn raw_dead_key_preedit_and_compose_evidence_survive_ascii_key_fallback() {
        assert_eq!(
            classify("a", ComposeEvidence::Idle, false),
            KeyInputSafety::Clear
        );
        assert_eq!(
            classify("dead_a", ComposeEvidence::Idle, false),
            KeyInputSafety::Composing
        );
        assert_eq!(
            classify("a", ComposeEvidence::Composing, false),
            KeyInputSafety::Composing
        );
        assert_eq!(
            classify("a", ComposeEvidence::Idle, true),
            KeyInputSafety::Composing
        );
        assert_eq!(
            classify("a", ComposeEvidence::Cancelled, false),
            KeyInputSafety::Unknown
        );
        assert_eq!(
            classify("a", ComposeEvidence::Unavailable, false),
            KeyInputSafety::Unknown
        );
        assert_eq!(
            classify("NoSymbol", ComposeEvidence::Idle, false),
            KeyInputSafety::Unknown
        );
    }
    #[test]
    fn synchronous_nested_dispatch_and_unwind_restore_thread_local_evidence() {
        assert_eq!(current_key_input_safety(), None);
        with_key_input_safety(KeyInputSafety::Clear, || {
            assert_eq!(current_key_input_safety(), Some(KeyInputSafety::Clear));
            assert_eq!(
                std::thread::spawn(current_key_input_safety).join().unwrap(),
                None
            );
            let result = std::panic::catch_unwind(|| {
                with_key_input_safety(KeyInputSafety::Composing, || {
                    panic!("synthetic fixture unwind")
                })
            });
            assert!(result.is_err());
            assert_eq!(current_key_input_safety(), Some(KeyInputSafety::Clear));
        });
        assert_eq!(current_key_input_safety(), None);
    }
}
