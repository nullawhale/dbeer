// Shared-source activation is a root build.rs including this file.
// Nothing discovers or executes this preparation file on its own.
use std::{
    env, fs,
    path::{Path, PathBuf},
    process::{Command, Stdio},
};

fn checked(command: &mut Command) {
    assert!(
        command
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .is_ok_and(|status| status.success()),
        "DBeer product build input or native resource verification failed"
    );
}

fn regular_file(path: &Path) -> Vec<u8> {
    let metadata = fs::symlink_metadata(path).expect("DBeer product input is missing");
    assert!(
        metadata.is_file() && !metadata.file_type().is_symlink(),
        "DBeer product input must be a regular file"
    );
    fs::read(path).expect("DBeer product input cannot be read")
}

fn main() {
    let project = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let repository = project.parent().and_then(Path::parent).unwrap();
    for name in [
        "DBEER_PRODUCT_BUILD_IDENTITY",
        "DBEER_PRODUCT_IDENTITY_FILE",
        "DBEER_PRODUCT_BUILD_PYTHON",
        "DBEER_PRODUCT_NATIVE_RESOURCES",
    ] {
        println!("cargo:rerun-if-env-changed={name}");
    }
    println!("cargo:rerun-if-changed=packaging/build-hook.rs");
    println!("cargo:rerun-if-changed=../../VERSION");
    println!("cargo:rerun-if-changed=../../BUILD_NUMBER");
    let host_feature = env::var_os("CARGO_FEATURE_PRODUCT_WINDOWS_RESOURCES").is_some();
    let Some(marker) = env::var_os("DBEER_PRODUCT_BUILD_IDENTITY") else {
        assert!(
            !host_feature
                && env::var_os("DBEER_PRODUCT_NATIVE_RESOURCES").is_none()
                && env::var_os("DBEER_PRODUCT_IDENTITY_FILE").is_none(),
            "DBeer host resources require an exact product build identity"
        );
        return;
    };
    let marker = marker
        .into_string()
        .expect("DBeer product identity must be ASCII");
    assert!(
        !marker.is_empty()
            && marker.len() <= 4096
            && marker.is_ascii()
            && !marker.contains('\r')
            && !marker.contains('\n'),
        "DBeer embedded product identity must be bounded canonical ASCII without a newline"
    );
    let target = env::var("TARGET").unwrap();
    assert!(
        env::var("HOST").as_deref() == Ok(target.as_str())
            && env::var("PROFILE").as_deref() == Ok("release")
            && env::var_os("CARGO_FEATURE_NATIVE_SMOKE").is_none(),
        "DBeer product builds require a native release binary, separate from test/smoke artifacts"
    );
    let product_target = match target.as_str() {
        "x86_64-pc-windows-msvc" if host_feature => "windows-x86_64-msvc",
        "x86_64-unknown-linux-gnu" if !host_feature => "linux-x86_64-gnu",
        _ => panic!("DBeer product target or host resource feature is unsupported"),
    };
    let identity = PathBuf::from(
        env::var_os("DBEER_PRODUCT_IDENTITY_FILE")
            .expect("DBeer product identity file is required"),
    );
    assert!(
        identity.is_absolute(),
        "DBeer product identity path must be absolute"
    );
    assert_eq!(
        regular_file(&identity),
        [marker.as_bytes(), b"\n"].concat(),
        "DBeer embedded identity differs from the canonical file"
    );
    let python = PathBuf::from(
        env::var_os("DBEER_PRODUCT_BUILD_PYTHON").expect("DBeer product Python is required"),
    );
    assert!(
        python.is_absolute(),
        "DBeer product Python path must be absolute"
    );
    checked(
        Command::new(&python)
            .arg("-B")
            .arg(project.join("packaging/package.py"))
            .args(["verify-identity", "--target", product_target, "--identity"])
            .arg(&identity),
    );
    for relative in [
        "src",
        "vendor",
        "assets",
        "packaging",
        "Cargo.toml",
        "Cargo.lock",
        "../../helper",
        "../../protocol",
        "../../scripts/gpui-prototype.sh",
        "../../scripts/build-gpui-client.sh",
        "../../scripts/build-gpui-client.ps1",
        "../../scripts/package-gpui-client.sh",
        "../../scripts/package-gpui-client.ps1",
        "../../macos/Resources/AppIcon.svg",
        "../../macos/Resources/AppIcon.png",
        "../../CHANGELOG.md",
    ] {
        println!("cargo:rerun-if-changed={relative}");
    }
    if product_target == "linux-x86_64-gnu" {
        assert!(
            env::var_os("DBEER_PRODUCT_NATIVE_RESOURCES").is_none(),
            "DBeer Linux builds cannot consume Windows native resource inputs"
        );
        return;
    }
    let resources = PathBuf::from(
        env::var_os("DBEER_PRODUCT_NATIVE_RESOURCES")
            .expect("DBeer Windows resources are required"),
    );
    assert!(
        resources.is_absolute() && resources.starts_with(repository.join("build")),
        "DBeer Windows resource inputs belong under ignored build/"
    );
    checked(
        Command::new(&python)
            .arg("-B")
            .arg(project.join("packaging/native-resources/generate.py"))
            .arg("verify-inputs")
            .arg("--identity")
            .arg(&identity)
            .arg("--inputs")
            .arg(&resources),
    );
    let compiled = PathBuf::from(env::var_os("OUT_DIR").unwrap()).join("dbeer-gui.res");
    checked(
        Command::new("rc.exe")
            .current_dir(&resources)
            .args(["/nologo", "/c65001", "/fo"])
            .arg(&compiled)
            .arg("gui.rc"),
    );
    assert!(
        !regular_file(&compiled).is_empty(),
        "DBeer GUI resource compilation is empty"
    );
    println!("cargo:rustc-link-arg-bin=dbeer-gpui={}", compiled.display());
    println!("cargo:rustc-link-arg-bin=dbeer-gpui=/MANIFEST:NO");
}
