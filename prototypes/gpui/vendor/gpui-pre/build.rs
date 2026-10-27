#![allow(clippy::disallowed_methods, reason = "build scripts are exempt")]

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo::rustc-check-cfg=cfg(gles)");

    // Leak detection does bookkeeping on every entity handle, so `test-support`
    // does not enable it: that feature must stay cheap enough to compile into
    // every build. CI sets `GPUI_LEAK_DETECTION`; the `leak-detection` feature
    // turns it on explicitly.
    println!("cargo::rustc-check-cfg=cfg(gpui_leak_detection)");
    println!("cargo::rerun-if-env-changed=GPUI_LEAK_DETECTION");
    let requested_by_environment =
        std::env::var_os("GPUI_LEAK_DETECTION").is_some_and(|value| !value.is_empty());
    if requested_by_environment || std::env::var_os("CARGO_FEATURE_LEAK_DETECTION").is_some() {
        println!("cargo::rustc-cfg=gpui_leak_detection");
    }

    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();

    if target_os == "windows" {
        #[cfg(feature = "windows-manifest-provided-by-host")]
        require_host_manifest();
        #[cfg(not(feature = "windows-manifest-provided-by-host"))]
        #[cfg(feature = "windows-manifest")]
        embed_resource();
    }
}

#[cfg(all(
    feature = "windows-manifest",
    not(feature = "windows-manifest-provided-by-host")
))]
fn embed_resource() {
    let resource_dir = std::path::Path::new("resources/windows");
    let manifest = resource_dir.join("gpui.manifest.xml");
    let rc_file = resource_dir.join("gpui.rc");
    println!("cargo:rerun-if-changed={}", manifest.display());
    println!("cargo:rerun-if-changed={}", rc_file.display());
    embed_resource::compile(rc_file, embed_resource::ParamsIncludeDirs([resource_dir]))
        .manifest_required()
        .unwrap();
}

// Additive Cargo feature unification cannot remove windows-manifest defaults.
// A host opting in owns the sole manifest; absence never silently disables it.
#[cfg(feature = "windows-manifest-provided-by-host")]
fn require_host_manifest() {
    use std::{env, fs, path::PathBuf};
    for name in [
        "DBEER_PRODUCT_BUILD_IDENTITY",
        "DBEER_PRODUCT_NATIVE_RESOURCES",
    ] {
        println!("cargo:rerun-if-env-changed={name}");
    }
    let target = env::var("TARGET").expect("DBeer host manifest requires native MSVC");
    assert!(
        target == "x86_64-pc-windows-msvc"
            && env::var("HOST").as_deref() == Ok(target.as_str())
            && env::var("PROFILE").as_deref() == Ok("release"),
        "DBeer host manifest requires a native x64 MSVC release build"
    );
    let identity = env::var("DBEER_PRODUCT_BUILD_IDENTITY")
        .expect("DBeer host manifest requires product identity");
    assert!(
        !identity.is_empty()
            && identity.len() <= 4096
            && identity.is_ascii()
            && !identity.contains('\n')
            && !identity.contains('\r'),
        "DBeer host manifest requires an exact embedded identity"
    );
    let directory = PathBuf::from(
        env::var_os("DBEER_PRODUCT_NATIVE_RESOURCES")
            .expect("DBeer host manifest requires generated resources"),
    );
    assert!(
        directory.is_absolute(),
        "DBeer host resources require an absolute path"
    );
    for name in [
        "BUILD-IDENTITY.json",
        "gui.rc",
        "gui.manifest",
        "dbeer.ico",
        "NATIVE-RESOURCES.json",
    ] {
        let path = directory.join(name);
        let metadata = fs::symlink_metadata(&path).expect("DBeer host resources are missing");
        assert!(
            metadata.is_file() && !metadata.file_type().is_symlink(),
            "DBeer host resources require regular original inputs"
        );
        println!("cargo:rerun-if-changed={}", path.display());
    }
    assert_eq!(
        fs::read(directory.join("BUILD-IDENTITY.json")).expect("DBeer host identity is missing"),
        [identity.as_bytes(), b"\n"].concat(),
        "DBeer host identity differs from its generated resources"
    );
}
