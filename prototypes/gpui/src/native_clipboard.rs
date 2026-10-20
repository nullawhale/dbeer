//! Native interoperable formats; never treat GPUI metadata itself as a MIME format.
use crate::grid_clipboard::Publication;
#[cfg(any(test, target_os = "linux"))]
use crate::grid_clipboard::{MIME, TYPE};

#[cfg(any(test, target_os = "linux"))]
pub(super) fn linux_envelope(data: &Publication) -> String {
    serde_json::json!({"dbeerNativeClipboardV1": [
        {"mime": TYPE, "data": data.json},
        {"mime": MIME, "data": data.json},
        {"mime": "text/tab-separated-values", "data": data.text}
    ]})
    .to_string()
}

#[cfg(any(test, target_os = "windows"))]
fn windows_buffers(data: &Publication) -> (Vec<u8>, Vec<u8>) {
    let text = data
        .text
        .encode_utf16()
        .chain([0])
        .flat_map(u16::to_le_bytes)
        .collect();
    let json = [data.json.as_bytes(), &[0]].concat();
    (text, json)
}

pub(super) fn publish(
    data: Publication,
    window: &mut gpui_kit::Window,
    cx: &mut gpui_kit::App,
) -> Result<(), &'static str> {
    #[cfg(target_os = "linux")]
    {
        let _ = window;
        // The maintained backend consumes this bounded envelope and serves actual
        // Wayland MIME offers / X11 TARGETS. Ordinary GPUI text copies are unchanged.
        let envelope = linux_envelope(&data);
        if envelope.len() > 64 * 1024 * 1024 {
            return Err("The selection exceeds the native clipboard limit.");
        }
        let before = dbeer_gpui_linux::native_clipboard_publication();
        cx.write_to_clipboard(gpui_kit::ClipboardItem::new_string_with_metadata(
            data.text, envelope,
        ));
        let after = dbeer_gpui_linux::native_clipboard_publication();
        if after != before && after & 1 == 1 {
            Ok(())
        } else {
            Err(
                "The native clipboard is unavailable or has no current input serial. Retry Copy from the grid.",
            )
        }
    }
    #[cfg(target_os = "macos")]
    {
        let _ = window;
        mac::publish(&data, cx)
    }
    #[cfg(target_os = "windows")]
    {
        let _ = cx;
        windows::publish(&data, window)
    }
}

#[cfg(target_os = "macos")]
mod mac {
    use super::*;
    use objc::runtime::Object;
    use objc::{class, msg_send, sel, sel_impl};

    #[allow(unexpected_cfgs)]
    pub fn publish(data: &Publication, cx: &mut gpui_kit::App) -> Result<(), &'static str> {
        // Keep the platform's official text publication path, then attach the exact
        // Swift pasteboard type to that same publication on the UI thread.
        unsafe {
            let ty: *mut Object = msg_send![class!(NSString), alloc];
            let ty: *mut Object = msg_send![ty, initWithBytes: crate::grid_clipboard::TYPE.as_ptr() length: crate::grid_clipboard::TYPE.len() encoding: 4usize];
            let bytes: *mut Object = msg_send![class!(NSData), dataWithBytes: data.json.as_ptr() length: data.json.len()];
            if ty.is_null() || bytes.is_null() {
                return Err("The native clipboard could not prepare the selection.");
            }
            cx.write_to_clipboard(gpui_kit::ClipboardItem::new_string(data.text.clone()));
            let board: *mut Object = msg_send![class!(NSPasteboard), generalPasteboard];
            let types: *mut Object = msg_send![class!(NSArray), arrayWithObject: ty];
            let _: isize = msg_send![board, addTypes: types owner: std::ptr::null_mut::<Object>()];
            let ok: bool = msg_send![board, setData: bytes forType: ty];
            let _: () = msg_send![ty, release];
            if ok {
                Ok(())
            } else {
                Err(
                    "The clipboard contains TSV, but its typed format could not be published. Retry Copy.",
                )
            }
        }
    }
}

#[cfg(target_os = "windows")]
mod windows {
    use super::*;
    use raw_window_handle::{HasWindowHandle, RawWindowHandle};
    use std::ffi::c_void;
    type Handle = *mut c_void;
    #[link(name = "user32")]
    unsafe extern "system" {
        fn OpenClipboard(window: Handle) -> i32;
        fn CloseClipboard() -> i32;
        fn EmptyClipboard() -> i32;
        fn RegisterClipboardFormatW(name: *const u16) -> u32;
        fn SetClipboardData(format: u32, data: Handle) -> Handle;
    }
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn GlobalAlloc(flags: u32, bytes: usize) -> Handle;
        fn GlobalLock(data: Handle) -> Handle;
        fn GlobalUnlock(data: Handle) -> i32;
        fn GlobalFree(data: Handle) -> Handle;
    }
    struct Memory(Handle);
    impl Drop for Memory {
        fn drop(&mut self) {
            if !self.0.is_null() {
                unsafe {
                    GlobalFree(self.0);
                }
            }
        }
    }
    fn memory(bytes: &[u8]) -> Result<Memory, &'static str> {
        unsafe {
            let output = Memory(GlobalAlloc(0x42, bytes.len()));
            if output.0.is_null() {
                return Err("The native clipboard could not prepare the selection.");
            }
            let target = GlobalLock(output.0);
            if target.is_null() {
                return Err("The native clipboard could not prepare the selection.");
            }
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), target.cast::<u8>(), bytes.len());
            GlobalUnlock(output.0);
            Ok(output)
        }
    }
    pub fn publish(data: &Publication, window: &mut gpui_kit::Window) -> Result<(), &'static str> {
        let RawWindowHandle::Win32(window) = window
            .window_handle()
            .map_err(|_| "The clipboard window is unavailable.")?
            .as_raw()
        else {
            return Err("The clipboard window is unavailable.");
        };
        let (text, json_bytes) = windows_buffers(data);
        let mut text = memory(&text)?;
        // Registered native format contains UTF-8 JSON bytes with a final NUL;
        // consumers ignore the terminator. All handles exist before EmptyClipboard.
        let mut json = memory(&json_bytes)?;
        let name: Vec<u16> = crate::grid_clipboard::TYPE
            .encode_utf16()
            .chain([0])
            .collect();
        unsafe {
            let format = RegisterClipboardFormatW(name.as_ptr());
            if format == 0 || OpenClipboard(window.hwnd.get() as Handle) == 0 {
                return Err("The clipboard is busy. Retry Copy.");
            }
            struct Open;
            impl Drop for Open {
                fn drop(&mut self) {
                    unsafe {
                        CloseClipboard();
                    }
                }
            }
            let _open = Open;
            if EmptyClipboard() == 0 {
                return Err("The clipboard could not be replaced. Retry Copy.");
            }
            let typed_ok = !SetClipboardData(format, json.0).is_null();
            if typed_ok {
                json.0 = std::ptr::null_mut();
            }
            let text_ok = !SetClipboardData(13, text.0).is_null();
            if text_ok {
                text.0 = std::ptr::null_mut();
            }
            if typed_ok && text_ok {
                Ok(())
            } else {
                Err("Only part of the selection formats reached the clipboard. Retry Copy.")
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn linux_native_targets_have_identical_typed_bytes_and_separate_tsv() {
        let data = Publication {
            text: "\\N\t\"\"".into(),
            json: "{\"version\":1}".into(),
        };
        let envelope: serde_json::Value = serde_json::from_str(&linux_envelope(&data)).unwrap();
        let targets = envelope["dbeerNativeClipboardV1"].as_array().unwrap();
        assert_eq!(targets[0]["mime"], TYPE);
        assert_eq!(targets[1]["mime"], MIME);
        assert_eq!(targets[0]["data"], targets[1]["data"]);
        assert_eq!(targets[2]["data"], data.text);
    }

    #[test]
    fn windows_text_is_utf16_and_registered_type_contains_exact_utf8_json() {
        let data = Publication {
            text: "caf\u{e9}\t\u{1f642}\r\n\\N".into(),
            json: "{\"version\":1,\"value\":\"\u{1f642}\"}".into(),
        };
        let (text, json) = windows_buffers(&data);
        let units: Vec<u16> = text
            .as_chunks::<2>()
            .0
            .iter()
            .map(|b| u16::from_le_bytes([b[0], b[1]]))
            .collect();
        assert_eq!(units.last(), Some(&0));
        assert_eq!(
            String::from_utf16(&units[..units.len() - 1]).unwrap(),
            data.text
        );
        assert_eq!(&json[..json.len() - 1], data.json.as_bytes());
        assert_eq!(json.last(), Some(&0));
    }
}
