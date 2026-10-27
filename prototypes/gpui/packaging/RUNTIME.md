# Native runtime and build provenance

Supported product targets: Windows 11 x64 with the MSVC Rust toolchain, and Ubuntu
24.04 x64 glibc with separate Wayland and X11 acceptance. No other architecture,
distribution, Windows version or headless/remote GPU configuration is accepted.
Mac GPUI is a development tool; macOS DBeer remains SwiftUI/AppKit.

## Windows

The exact locked `gpui-pre-windows` 0.3.9 backend uses Direct3D 11/DXGI, not a
Vulkan requirement. Its `directx_devices.rs` requests feature levels 11.1, 11.0
and 10.1 and additionally checks StructuredBuffer/compute support. A functioning
supported Windows graphics driver is required; source feature presence does not
prove a particular GPU, virtual machine or remote desktop works. Do not install
a graphics driver automatically.

Use the x64 Microsoft Visual C++ Redistributable when the actual binary imports
require its runtime. Do not redistribute arbitrary DLLs from a development PC.
Packaging statically inspects each PE with `dumpbin /DEPENDENTS` and records the
actual DLL names in NATIVE-DEPENDENCIES.json. Transitive imports/dynamic modules
and clean-machine VC runtime resolution still require installed acceptance.
Credential storage uses built-in Windows Credential Manager and requires no
external password-store service. Application files need a user-writable folder;
run as a standard user.

Build prerequisites are Rust 1.92+ (CI pins 1.99.1), the native
x86_64-pc-windows-msvc toolchain, Go from helper/go.mod, Visual Studio 2022 C++
Build Tools/Windows SDK, CMake and Python 3.11+ (`py -3`) for packaging. Use a
Developer PowerShell with dumpbin on PATH. These build tools are not application
runtime prerequisites.

## Ubuntu

Native builds and packaging use Ubuntu 24.04 x64, with glibc 2.39 as the maximum
baseline. An archive is dynamically linked, not a static Linux executable.
Packaging statically reads ELF DT_NEEDED and GLIBC version requirements using
`readelf --dynamic --version-info`; it refuses versions newer than GLIBC_2.39
and records the exact observed names/versions. It never runs `ldd` on input
executables. Install the Ubuntu runtime packages corresponding to this actual
inventory. A source-level list cannot substitute for that artifact inspection.

The exact locked Linux backend is gpui-pre-linux 0.3.9, using gpui-pre-wgpu 0.3.9
and wgpu 29. The desktop instance enables Vulkan and GL backends; the published
GPUI Kit installation baseline uses a working Vulkan driver. A Vulkan loader
(`libvulkan1`) alone does not supply a GPU driver. Mesa/proprietary driver choice
belongs to the supported machine. GL fallback is compiled, but is not an
accepted substitute until the actual supported desktop passes the same flows.

Wayland/X11 sessions need their respective runtime libraries, font discovery/text
rendering, native keyboard mapping and a working desktop portal for native file
pickers. Expected facilities include fontconfig/FreeType, libxkbcommon with the
X11 extension on X11, Wayland client/cursor support or X11/XCB, and the user session
D-Bus. The actual DT_NEEDED inventory decides which libraries are linked, while
graphics loaders/driver ICDs and portal services can be loaded dynamically.
Ubuntu's normal GNOME desktop supplies many of these facilities. A minimal or
headless image is insufficient. Do not install development packages merely to
satisfy a runtime claim.

Saved passwords use an installed, running and unlocked Secret Service provider
(such as GNOME Keyring) on the user's session D-Bus. Missing/locked/unavailable
stores are errors, not empty passwords. The GTK/KDE desktop portal backend must
match the session. The GNOME session-end adapter uses the existing session bus;
`dbus-daemon` in private test fixtures is not an additional product daemon.
AT-SPI/Orca observations require a real accessibility-enabled desktop.

The existing native CI build dependency list includes compiler/CMake/pkg-config,
fontconfig, Wayland, xkbcommon-X11/X11-XCB, DBus, WebKit, SSL and zstd development
packages plus Vulkan loader/validation layers. It is a toolchain preparation
list, not proof that every package is linked by this feature set. ALSA/speech is
not enabled by this product. `scripts/build-gpui-client.sh --package` builds the
exact marked pair and invokes hardened candidate preparation; without that
option it compiles only. See BUILD_INTEGRATION.md in the source distribution.
Python 3.11+ and binutils/readelf are packaging tools; Python is needed by optional
per-user desktop integration, not by GUI/helper execution.

## Exact-source inspection

The backend archives were inspected against Cargo.lock checksums (no native GUI
was built/run during preparation):

- gpui-pre-windows 0.3.9: SHA256
  `513d4f0fc7d596d3bdef2a73a524ffb83dabc95bf484f2855a698e7f431290a9`;
  src/directx_devices.rs and src/platform.rs.
- gpui-pre-wgpu 0.3.9: SHA256
  `5b1cdb26c1503bf9662ee8fbc5ab0b44b2deeee4b5c12dc67491ba6fb5fc544b`;
  Cargo.toml Linux wgpu features and src/wgpu_context.rs instance backends.
- Both record the GPUI snapshot at Zed revision
  `93d745668805029476e6d7fbb19652116fed51de`.

Primary source archives: [Windows](https://static.crates.io/crates/gpui-pre-windows/gpui-pre-windows-0.3.9.crate),
[wgpu](https://static.crates.io/crates/gpui-pre-wgpu/gpui-pre-wgpu-0.3.9.crate).
See [GPUI Kit's installation guide](https://gpui-kit.com/docs/installation/)
for upstream build guidance, [Microsoft's runtime guidance](https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist)
for the current redistributable and [Desktop Entry specification](https://specifications.freedesktop.org/desktop-entry-spec/latest/)
for launcher value/Exec rules. These notes summarize inspected source and provide
links; they do not reproduce upstream documentation prose.
