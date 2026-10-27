# Maintained DBeer native clipboard patch

Upstream package: `gpui-pre-linux` 0.3.9, the actual GPUI Kit 0.7.3 default
Linux backend. Original archive:
https://static.crates.io/crates/gpui-pre-linux/gpui-pre-linux-0.3.9.crate

Archive SHA256: `e28213c3fde6f13e91ba0b74b90cbaadec9373e36a031eda98561d31059870f3`.
Upstream package records Zed revision `93d745668805029476e6d7fbb19652116fed51de`.
The original Cargo.toml, source tree and LICENSE-APACHE are bundled; no build
fetch/script or ignored documentation supplies the patch. Cargo.lock resolves
this local path through the root `[patch.crates-io]`. Optional GPUI Fast is not
patched or enabled. Preserve the Apache license and include it in Task 31 notices.

Local changes are limited to Cargo.toml (`serde_json`), Linux/native public
module exports, `linux/native_formats.rs`, Wayland clipboard/client and X11
clipboard/client. The parser accepts exactly three fixed targets under a 64 MiB
envelope, requires matching JSON aliases and matching TSV text, and rejects
ordinary metadata/unknown targets. It exposes only bounded publication status,
never payload diagnostics. The application serializes all representations first.

Wayland offers exact native types using the original data source/input serial
and async FD sender; no ownership request mutates cached data without a valid
serial. X11 prepares/interns every target before replacing the existing native
selection, retaining TARGETS/INCR/clipboard-manager/thread lifecycle. Ordinary
text copy still serves text. No external clipboard utility or daemon is used.

The envelope parser/serialization has prepared development-host cases. Windows
and Linux cfg branches/native interoperability remain uncompiled/unrun here;
Mac static checks cannot establish Linux build or Wayland/X11 acceptance. See
../../GRID.md for format mapping and deferred external-consumer acceptance.

## Additional maintained native keyboard evidence patch (Task 29)

The preceding file list describes the original Task 16 clipboard portion. That
real Wayland/X11 multi-MIME patch and original archive/license/provenance remain
unchanged. Task 29 additionally owns linux/keyboard_safety.rs, its linux.rs /
gpui_linux.rs exports and narrowly scoped original KeyDown dispatch wrappers in
Wayland/client.rs and X11/client.rs. No clipboard payload or transport logic is
replaced by this addition.

current_key_input_safety() exposes Clear / Composing / Unknown only during an
actual synchronous native original KeyDown on its UI thread. The classification
uses raw xkb keysym names before GPUI's ASCII fallback, native compose status and
backend preedit. Dead/Compose keys and composing/preedit remain Composing; absent
or cancelled compose information and NoSymbol are Unknown. RAII restores prior
evidence after dispatch, including nested callbacks/unwinding. Other threads,
KeyUp, synthetic events and Wayland held repeats have no such evidence. The
recorder separately checks its retained input's marked-text state, repeat,
prefer_character_input and modifier restrictions. No key data is persisted or
logged, and no global input hook or external process is installed.

The source classifier and TLS lifetime tests are included by the application
for host compile checking. Actual Linux branches remain uncompiled/unrun on the
Mac development host; target native builds and input/IME/AltGr/dead-key/layout
acceptance remain required. This addition does not establish target coverage.
