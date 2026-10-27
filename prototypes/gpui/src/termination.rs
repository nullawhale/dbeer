//! Platform termination hooks. Window close and workspace Quit always use the
//! asynchronous transaction review. Owned Windows session-end queries and Mac
//! development-host AppKit Quit enter it before teardown. Ubuntu session-manager
//! logout uses the separately owned GNOME client and common terminal readiness.

use async_channel::Receiver;

#[cfg(any(target_os = "macos", target_os = "windows"))]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum TerminationRequest {
    #[cfg(target_os = "macos")]
    ApplicationQuit,
    #[cfg(target_os = "windows")]
    SessionEnd,
}
#[cfg(not(any(target_os = "macos", target_os = "windows")))]
pub(super) type TerminationRequest = ();

/// Forced exit is outside the acknowledged close protocol. This is also the
/// fallback for a session manager for which this backend exposes no veto hook.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum ExitOutcome {
    Reviewed,
    Unknown,
}
static EXIT_PERMITTED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
fn classify_exit(reviewed: bool) -> ExitOutcome {
    if reviewed {
        ExitOutcome::Reviewed
    } else {
        ExitOutcome::Unknown
    }
}

pub(super) fn exit_outcome() -> ExitOutcome {
    classify_exit(EXIT_PERMITTED.load(std::sync::atomic::Ordering::Acquire))
}

pub(super) fn install_window(window: &gpui_kit::Window) -> Result<(), &'static str> {
    #[cfg(target_os = "windows")]
    return windows::install_window(window);
    #[cfg(not(target_os = "windows"))]
    {
        let _ = window;
        Ok(())
    }
}

/// Other desktops close the workspace window or dispatch its Quit action.
/// AppKit requires this additional hook before GPUI's on_app_quit callback.
pub(super) fn install() -> Option<Receiver<TerminationRequest>> {
    #[cfg(target_os = "macos")]
    {
        Some(macos::install())
    }
    #[cfg(target_os = "windows")]
    {
        Some(windows::install())
    }
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    {
        None
    }
}

/// Called only after the final workspace window has completed its close flow.
pub(super) fn permit_exit() {
    EXIT_PERMITTED.store(true, std::sync::atomic::Ordering::Release);
}

#[cfg(all(feature = "native-smoke", target_os = "macos"))]
pub(super) fn request_native_quit() {
    macos::request_native_quit();
}

#[cfg(target_os = "macos")]
mod macos {

    #![allow(unexpected_cfgs)] // objc 0.2 macros check the legacy cargo-clippy feature.

    use super::{ExitOutcome, TerminationRequest, exit_outcome};
    use async_channel::{Receiver, Sender};
    use objc::{
        class, msg_send,
        runtime::{Class, Imp, NO, Object, Sel, class_addMethod, object_getClass},
        sel, sel_impl,
    };
    use std::sync::OnceLock;

    static REQUESTS: OnceLock<Sender<TerminationRequest>> = OnceLock::new();

    type ShouldTerminate = extern "C" fn(&Object, Sel, *mut Object) -> usize;

    extern "C" fn should_terminate(_: &Object, _: Sel, _: *mut Object) -> usize {
        if exit_outcome() == ExitOutcome::Reviewed {
            return 1; // NSTerminateNow
        }
        // Never borrow GPUI state from an AppKit callback. A request can arrive while
        // GPUI is dispatching an event; the foreground receiver reviews it afterwards.
        if let Some(requests) = REQUESTS.get() {
            _ = requests.try_send(TerminationRequest::ApplicationQuit);
        }
        0 // NSTerminateCancel; successful workspace cleanup requests termination again.
    }

    pub(super) fn install() -> Receiver<TerminationRequest> {
        let (sender, receiver) = async_channel::bounded(1);
        REQUESTS
            .set(sender)
            .expect("The native termination guard must be installed once");
        // Called on the main thread after GPUI has created its NSApplication delegate.
        // The pinned GPUI release does not implement this optional delegate method.
        // Add only the missing method, retaining all GPUI delegate behavior.
        unsafe {
            let app: *mut Object = msg_send![class!(NSApplication), sharedApplication];
            let delegate: *mut Object = msg_send![app, delegate];
            assert!(
                !delegate.is_null(),
                "The GPUI application delegate is missing"
            );
            let class = object_getClass(delegate) as *mut Class;
            let selector = sel!(applicationShouldTerminate:);
            assert!(
                (&*class).instance_method(selector).is_none(),
                "GPUI now implements applicationShouldTerminate; review the termination guard"
            );
            let implementation = std::mem::transmute::<ShouldTerminate, Imp>(should_terminate);
            assert_ne!(
                class_addMethod(class, selector, implementation, c"Q@:@".as_ptr()),
                NO,
                "Failed to install the native termination guard"
            );
            // AppKit caches optional delegate selectors when assigning its delegate.
            let _: *mut Object = msg_send![delegate, retain];
            let _: () = msg_send![app, setDelegate: std::ptr::null_mut::<Object>()];
            let _: () = msg_send![app, setDelegate: delegate];
            let _: () = msg_send![delegate, release];
        }
        receiver
    }

    #[cfg(feature = "native-smoke")]
    pub(super) fn request_native_quit() {
        // Exercise the same NSApplication entry point used by Dock Quit.
        unsafe {
            let app: *mut Object = msg_send![class!(NSApplication), sharedApplication];
            let _: () = msg_send![app, terminate: std::ptr::null_mut::<Object>()];
        }
    }
}

// The pinned Windows backend accepts WM_QUERYENDSESSION on its private message
// window and exits on WM_ENDSESSION. Subclass only our owned workspace HWND:
// any owned window may veto a cancellable request. Never intercept other apps.
#[cfg(target_os = "windows")]
mod windows {
    use super::{ExitOutcome, TerminationRequest, exit_outcome};
    use async_channel::{Receiver, Sender};
    use raw_window_handle::{HasWindowHandle, RawWindowHandle};
    use std::{ffi::c_void, sync::OnceLock};
    static REQUESTS: OnceLock<Sender<TerminationRequest>> = OnceLock::new();
    const SUBCLASS_ID: usize = 0x4442_4545;
    const WM_QUERYENDSESSION: u32 = 0x0011;
    const WM_NCDESTROY: u32 = 0x0082;
    type SubclassProc =
        unsafe extern "system" fn(*mut c_void, u32, usize, isize, usize, usize) -> isize;
    #[link(name = "comctl32")]
    unsafe extern "system" {
        fn SetWindowSubclass(
            window: *mut c_void,
            callback: Option<SubclassProc>,
            id: usize,
            data: usize,
        ) -> i32;
        fn RemoveWindowSubclass(
            window: *mut c_void,
            callback: Option<SubclassProc>,
            id: usize,
        ) -> i32;
        fn DefSubclassProc(
            window: *mut c_void,
            message: u32,
            wparam: usize,
            lparam: isize,
        ) -> isize;
    }
    unsafe extern "system" fn callback(
        window: *mut c_void,
        message: u32,
        wparam: usize,
        lparam: isize,
        _: usize,
        _: usize,
    ) -> isize {
        if message == WM_QUERYENDSESSION && exit_outcome() != ExitOutcome::Reviewed {
            if let Some(requests) = REQUESTS.get() {
                _ = requests.try_send(TerminationRequest::SessionEnd);
            }
            // Veto this request immediately; review asynchronously on GPUI's
            // foreground executor. A later forced end is never a successful ACK.
            return 0;
        }
        if message == WM_NCDESTROY {
            unsafe {
                RemoveWindowSubclass(window, Some(callback), SUBCLASS_ID);
            }
        }
        unsafe { DefSubclassProc(window, message, wparam, lparam) }
    }
    pub(super) fn install() -> Receiver<TerminationRequest> {
        let (sender, receiver) = async_channel::bounded(1);
        REQUESTS
            .set(sender)
            .expect("Install the Windows session-end guard once");
        receiver
    }
    #[cfg(test)]
    #[test]
    fn cancellable_session_end_is_vetoed_and_repeated_requests_coalesce() {
        let requests = install();
        // Policy-only callback invocation: query handling never dereferences HWND
        // and sends no OS message. Native subclass installation is separate.
        for _ in 0..3 {
            assert_eq!(
                unsafe {
                    callback(
                        std::ptr::null_mut(),
                        WM_QUERYENDSESSION,
                        0,
                        0,
                        SUBCLASS_ID,
                        0,
                    )
                },
                0
            );
        }
        assert_eq!(requests.len(), 1);
        assert_eq!(requests.try_recv().unwrap(), TerminationRequest::SessionEnd);
        assert_eq!(exit_outcome(), ExitOutcome::Unknown);
    }
    pub(super) fn install_window(window: &gpui_kit::Window) -> Result<(), &'static str> {
        let handle = HasWindowHandle::window_handle(window)
            .map_err(|_| "The owned workspace HWND is unavailable.")?;
        let RawWindowHandle::Win32(handle) = handle.as_raw() else {
            return Err("The workspace is not a Windows window.");
        };
        install_owned_hwnd(handle.hwnd.get() as *mut c_void)
    }
    // Only install_window's owned raw handle and the explicitly ignored native
    // harness below call this. No foreign window enumeration or global hook.
    fn install_owned_hwnd(hwnd: *mut c_void) -> Result<(), &'static str> {
        if unsafe { SetWindowSubclass(hwnd, Some(callback), SUBCLASS_ID, 0) } == 0 {
            return Err("Cannot install the owned-window session-end guard.");
        }
        Ok(())
    }
    #[cfg(test)]
    #[test]
    #[ignore = "Requires a real Windows desktop and owned HWND delivery; never run headless."]
    fn owned_hwnd_subclass_lifetime_and_native_query_delivery() {
        #[link(name = "user32")]
        unsafe extern "system" {
            fn CreateWindowExW(
                ex: u32,
                class: *const u16,
                name: *const u16,
                style: u32,
                x: i32,
                y: i32,
                w: i32,
                h: i32,
                parent: *mut c_void,
                menu: *mut c_void,
                instance: *mut c_void,
                param: *mut c_void,
            ) -> *mut c_void;
            fn SendMessageW(
                window: *mut c_void,
                message: u32,
                wparam: usize,
                lparam: isize,
            ) -> isize;
            fn DestroyWindow(window: *mut c_void) -> i32;
            fn IsWindow(window: *mut c_void) -> i32;
        }
        #[link(name = "comctl32")]
        unsafe extern "system" {
            fn GetWindowSubclass(
                window: *mut c_void,
                callback: Option<SubclassProc>,
                id: usize,
                data: *mut usize,
            ) -> i32;
        }
        let requests = install();
        let class: [u16; 7] = [83, 84, 65, 84, 73, 67, 0];
        let create = || unsafe {
            CreateWindowExW(
                0,
                class.as_ptr(),
                class.as_ptr(),
                0,
                0,
                0,
                40,
                40,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        };
        let owned = create();
        let unrelated = create();
        assert!(!owned.is_null() && !unrelated.is_null());
        install_owned_hwnd(owned).unwrap();
        let mut data = 0;
        assert_ne!(
            unsafe { GetWindowSubclass(owned, Some(callback), SUBCLASS_ID, &mut data) },
            0
        );
        assert_eq!(
            unsafe { GetWindowSubclass(unrelated, Some(callback), SUBCLASS_ID, &mut data) },
            0
        );
        for _ in 0..3 {
            assert_eq!(unsafe { SendMessageW(owned, WM_QUERYENDSESSION, 0, 0) }, 0);
        }
        assert_eq!(requests.len(), 1);
        assert_eq!(requests.try_recv().unwrap(), TerminationRequest::SessionEnd);
        // Canceled OS association does not manufacture a reviewed exit.
        unsafe {
            SendMessageW(owned, 0x0016, 0, 0);
        }
        assert_eq!(exit_outcome(), ExitOutcome::Unknown);
        assert_ne!(unsafe { DestroyWindow(owned) }, 0);
        assert_eq!(unsafe { IsWindow(owned) }, 0);
        assert_eq!(
            unsafe { GetWindowSubclass(owned, Some(callback), SUBCLASS_ID, &mut data) },
            0
        );
        assert_ne!(unsafe { IsWindow(unrelated) }, 0);
        assert_ne!(unsafe { DestroyWindow(unrelated) }, 0);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn forced_or_unsupported_exit_never_implies_reviewed_database_outcome() {
        assert_eq!(classify_exit(false), ExitOutcome::Unknown);
        assert_eq!(classify_exit(true), ExitOutcome::Reviewed);
    }
}
