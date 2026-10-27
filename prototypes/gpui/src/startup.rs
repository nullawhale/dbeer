//! Explicit, one-shot stdin connection input. Ordinary launch never opens stdin.
//! No detached blocking reader survives the deadline or consumes a later retry.
use crate::{backend::Connection, connections::ConnectionProfile};
use std::time::{Duration, Instant};

/// Evaluate before feasibility, GPUI, data ownership, stdin or any helper/store.
/// A mixed/misspelled metadata invocation cannot fall through into a workspace.
pub fn build_info_request(
    arguments: &[std::ffi::OsString],
) -> Result<bool, crate::product_identity::IdentityError> {
    if arguments
        .iter()
        .any(|argument| argument.to_string_lossy().starts_with("--build-info"))
    {
        if arguments.len() == 1 && arguments[0] == "--build-info" {
            Ok(true)
        } else {
            Err(crate::product_identity::IdentityError)
        }
    } else {
        Ok(false)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LaunchOptions {
    pub disposable: bool,
    pub explicit_connection: bool,
    pub policy: crate::product_identity::StartupPolicy,
}
impl LaunchOptions {
    pub fn parse(
        platform: crate::product_identity::Platform,
        arguments: &[std::ffi::OsString],
        native_smoke: bool,
    ) -> Result<Self, crate::product_identity::IdentityError> {
        use crate::product_identity::{IdentityError, Platform, StartupPolicy};
        if arguments.len() > 1 {
            return Err(IdentityError);
        }
        let argument = arguments
            .first()
            .map(|argument| argument.to_str().ok_or(IdentityError))
            .transpose()?;
        let explicit_connection = argument == Some("--connect-stdin");
        let disposable = match argument {
            None | Some("--connect-stdin") => false,
            Some("--demo") if platform == Platform::MacDevelopment => true,
            Some("--smoke-test" | "--live-smoke-test" | "--termination-smoke-test")
                if platform == Platform::MacDevelopment && native_smoke =>
            {
                true
            }
            _ => return Err(IdentityError),
        };
        Ok(Self {
            disposable,
            explicit_connection,
            policy: StartupPolicy::new(platform, disposable),
        })
    }
    pub fn current(
        arguments: &[std::ffi::OsString],
    ) -> Result<Self, crate::product_identity::IdentityError> {
        use crate::product_identity::{BuildIdentity, IdentityError, Platform};
        let platform = Platform::current().ok_or(IdentityError)?;
        let identity = BuildIdentity::optional_embedded()?;
        if platform != Platform::MacDevelopment && identity.is_none() {
            return Err(IdentityError);
        }
        Self::parse(platform, arguments, cfg!(feature = "native-smoke"))
    }
}

pub const MAX_INPUT_BYTES: usize = 64 * 1024;
pub const INPUT_TIMEOUT: Duration = Duration::from_secs(5);
pub const INPUT_ERROR: &str =
    "Startup connection settings could not be read. Enter the connection details and connect.";

/// No Debug/Display, and overwritten when the last request owner releases it.
pub struct Secret(String);
impl Secret {
    pub fn new(value: String) -> Self {
        Self(value)
    }
    pub fn expose(&self) -> &str {
        &self.0
    }
}
impl Drop for Secret {
    fn drop(&mut self) {
        // SAFETY: zero is valid UTF-8, no references outlive this exclusive drop.
        wipe(unsafe { self.0.as_bytes_mut() });
    }
}
fn wipe(bytes: &mut [u8]) {
    for byte in bytes {
        // Volatile stores keep this cleanup from being elided as dead writes.
        unsafe { std::ptr::write_volatile(byte, 0) };
    }
    std::sync::atomic::compiler_fence(std::sync::atomic::Ordering::SeqCst);
}
struct InputBytes(Vec<u8>);
impl Drop for InputBytes {
    fn drop(&mut self) {
        wipe(&mut self.0);
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct InputError;

pub struct StartupConnection {
    pub profile: ConnectionProfile,
    pub password: Secret,
}

/// Decode the Swift ConnectionSettings shape, including its PostgreSQL and
/// unspecified/write-enabled defaults. Unknown/SQL fields are refused.
fn decode(data: &[u8]) -> Result<StartupConnection, InputError> {
    if data.is_empty() || data.len() > MAX_INPUT_BYTES {
        return Err(InputError);
    }
    let mut settings: Connection = serde_json::from_slice(data).map_err(|_| InputError)?;
    let profile = ConnectionProfile {
        name: settings.database.clone(),
        engine: settings.engine,
        host: settings.host,
        port: settings.port,
        database: settings.database,
        user: settings.user,
        ssl_mode: settings.ssl_mode,
        ssl_root_cert: settings.ssl_root_cert,
        environment: settings.policy.environment,
        readonly: settings.policy.read_only,
        ..ConnectionProfile::new()
    };
    let password = Secret::new(std::mem::take(&mut settings.password));
    profile.validate().map_err(|_| InputError)?;
    Ok(StartupConnection { profile, password })
}

pub fn load_with(
    explicit: bool,
    read: impl FnOnce() -> Result<Vec<u8>, InputError>,
) -> Option<Result<StartupConnection, InputError>> {
    if !explicit {
        return None;
    }
    Some(read().and_then(|bytes| decode(&InputBytes(bytes).0)))
}

/// Called only after normal data-directory ownership succeeds. It owns stdin
/// until EOF/error/deadline and always closes it. Manual retry uses form fields,
/// never another stdin reader or the previous secret input.
pub fn load(explicit: bool) -> Option<Result<StartupConnection, InputError>> {
    load_with(explicit, || read_stdin(INPUT_TIMEOUT))
}

#[cfg(unix)]
fn read_stdin(timeout: Duration) -> Result<Vec<u8>, InputError> {
    use std::os::fd::FromRawFd;
    // SAFETY: this is the sole explicit stdin reader; ordinary startup does not
    // construct a File/lock/stdin reader. The owned file closes on every path.
    read_file(
        unsafe { std::fs::File::from_raw_fd(libc::STDIN_FILENO) },
        timeout,
    )
}

#[cfg(unix)]
fn read_file(mut file: std::fs::File, timeout: Duration) -> Result<Vec<u8>, InputError> {
    use std::{io::Read, os::fd::AsRawFd};
    let deadline = Instant::now() + timeout;
    let mut data = InputBytes(Vec::with_capacity(MAX_INPUT_BYTES));
    let mut buffer = InputBytes(vec![0; 4096]);
    loop {
        let remaining = deadline
            .checked_duration_since(Instant::now())
            .ok_or(InputError)?;
        let millis = remaining
            .as_millis()
            .saturating_add(1)
            .min(i32::MAX as u128) as i32;
        let mut fd = libc::pollfd {
            fd: file.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        // SAFETY: poll receives exactly one valid, owned descriptor structure.
        let ready = unsafe { libc::poll(&mut fd, 1, millis) };
        if ready < 0 && std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
            continue;
        }
        if ready <= 0 || fd.revents & (libc::POLLIN | libc::POLLHUP) == 0 {
            return Err(InputError);
        }
        let count = match file.read(&mut buffer.0) {
            Ok(count) => count,
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => return Err(InputError),
        };
        if Instant::now() >= deadline {
            return Err(InputError);
        }
        if count == 0 {
            return Ok(std::mem::take(&mut data.0));
        }
        if data.0.len() + count > MAX_INPUT_BYTES {
            return Err(InputError);
        }
        data.0.extend_from_slice(&buffer.0[..count]);
    }
}

#[cfg(target_os = "windows")]
fn read_stdin(timeout: Duration) -> Result<Vec<u8>, InputError> {
    // A redirected pipe can be polled without creating an uncancellable reader.
    // A console/missing handle fails closed; use redirected bytes or the form.
    // No Console ReadFile (which can wait for a line after a signaled key event).
    use std::ffi::c_void;
    type Handle = *mut c_void;
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn GetStdHandle(kind: u32) -> Handle;
        fn GetFileType(handle: Handle) -> u32;
        fn PeekNamedPipe(
            handle: Handle,
            buffer: *mut c_void,
            size: u32,
            read: *mut u32,
            available: *mut u32,
            left: *mut u32,
        ) -> i32;
        fn ReadFile(
            handle: Handle,
            buffer: *mut c_void,
            size: u32,
            read: *mut u32,
            overlapped: *mut c_void,
        ) -> i32;
        fn GetLastError() -> u32;
        fn CloseHandle(handle: Handle) -> i32;
    }
    struct OwnedInput(Handle);
    impl Drop for OwnedInput {
        fn drop(&mut self) {
            unsafe {
                CloseHandle(self.0);
            }
        }
    }
    // SAFETY: ownership is restricted to this one launch operation; no other
    // application code uses stdin, and handles/buffers remain valid for calls.
    unsafe {
        let raw = GetStdHandle((-10i32) as u32);
        if raw.is_null() || raw as isize == -1 {
            return Err(InputError);
        }
        let input = OwnedInput(raw);
        let kind = GetFileType(input.0);
        if !matches!(kind, 1 | 3) {
            return Err(InputError);
        } // FILE_TYPE_DISK / FILE_TYPE_PIPE
        let deadline = Instant::now() + timeout;
        let mut data = InputBytes(Vec::with_capacity(MAX_INPUT_BYTES));
        let mut buffer = InputBytes(vec![0; 4096]);
        loop {
            let remaining = deadline
                .checked_duration_since(Instant::now())
                .ok_or(InputError)?;
            let mut available = buffer.0.len() as u32;
            if kind == 3
                && PeekNamedPipe(
                    input.0,
                    std::ptr::null_mut(),
                    0,
                    std::ptr::null_mut(),
                    &mut available,
                    std::ptr::null_mut(),
                ) == 0
            {
                return if GetLastError() == 109 {
                    Ok(std::mem::take(&mut data.0))
                } else {
                    Err(InputError)
                }; // ERROR_BROKEN_PIPE = EOF
            }
            if available == 0 {
                std::thread::sleep(remaining.min(Duration::from_millis(10)));
                continue;
            }
            let mut count = 0;
            let requested = available.min(buffer.0.len() as u32);
            if ReadFile(
                input.0,
                buffer.0.as_mut_ptr().cast(),
                requested,
                &mut count,
                std::ptr::null_mut(),
            ) == 0
            {
                return Err(InputError);
            }
            if Instant::now() >= deadline || data.0.len() + count as usize > MAX_INPUT_BYTES {
                return Err(InputError);
            }
            if count == 0 {
                return Ok(std::mem::take(&mut data.0));
            }
            data.0.extend_from_slice(&buffer.0[..count as usize]);
        }
    }
}

#[cfg(not(any(unix, target_os = "windows")))]
fn read_stdin(_: Duration) -> Result<Vec<u8>, InputError> {
    Err(InputError)
}

#[cfg(test)]
mod tests {
    use super::*;
    const INPUT: &[u8] = br#"{"host":"localhost","port":5432,"database":"postgres","user":"tester","password":"fixture-secret","sslMode":"verify-full"}"#;
    #[test]
    fn metadata_arguments_are_exact_and_invalid_mixes_never_fall_through() {
        let args = |values: &[&str]| {
            values
                .iter()
                .map(std::ffi::OsString::from)
                .collect::<Vec<_>>()
        };
        assert_eq!(build_info_request(&[]), Ok(false));
        assert_eq!(build_info_request(&args(&["--build-info"])), Ok(true));
        for values in [
            vec!["--build-info", "--demo"],
            vec!["--build-info=gui"],
            vec!["--build-info-extra"],
            vec!["--connect-stdin", "--build-info"],
        ] {
            assert!(build_info_request(&args(&values)).is_err());
        }
    }
    #[test]
    fn demo_and_smoke_fixtures_are_explicit_mac_development_only() {
        use crate::product_identity::Platform;
        for platform in [Platform::Windows, Platform::Linux, Platform::MacDevelopment] {
            let normal = LaunchOptions::parse(platform, &[], false).unwrap();
            assert!(!normal.disposable && !normal.policy.built_in_fixtures);
            assert!(normal.policy.restore_disconnected);
            let demo = LaunchOptions::parse(platform, &["--demo".into()], false);
            assert_eq!(demo.is_ok(), platform == Platform::MacDevelopment);
            let smoke = LaunchOptions::parse(platform, &["--smoke-test".into()], true);
            assert_eq!(smoke.is_ok(), platform == Platform::MacDevelopment);
        }
        assert!(
            LaunchOptions::parse(Platform::MacDevelopment, &["--smoke-test".into()], false)
                .is_err()
        );
        assert!(
            LaunchOptions::parse(
                Platform::MacDevelopment,
                &["--demo".into(), "--connect-stdin".into()],
                true
            )
            .is_err()
        );
        assert!(LaunchOptions::parse(Platform::Linux, &["--unknown".into()], false).is_err());
    }
    #[test]
    fn ordinary_launch_never_calls_reader() {
        assert!(load_with(false, || panic!("Ordinary launch read stdin")).is_none());
    }
    #[test]
    fn explicit_defaults_and_empty_password_match_swift() {
        let value = load_with(true, || Ok(INPUT.to_vec())).unwrap().unwrap();
        assert_eq!(value.profile.engine, "postgresql");
        assert_eq!(value.profile.environment, "unspecified");
        assert!(!value.profile.readonly);
        assert_eq!(value.password.expose(), "fixture-secret");
        let empty = String::from_utf8(INPUT.to_vec())
            .unwrap()
            .replace("fixture-secret", "");
        assert_eq!(decode(empty.as_bytes()).unwrap().password.expose(), "");
    }
    #[test]
    fn malformed_oversized_missing_and_sql_input_are_fixed_errors_and_retryable() {
        for input in [
            Vec::new(),
            b"{fixture-secret".to_vec(),
            vec![b' '; MAX_INPUT_BYTES + 1],
            br#"{"sql":"SELECT 1","password":"fixture-secret"}"#.to_vec(),
        ] {
            assert!(load_with(true, || Ok(input)).unwrap().is_err());
            assert!(load_with(true, || Ok(INPUT.to_vec())).unwrap().is_ok());
        }
        assert!(!INPUT_ERROR.contains("fixture-secret"));
    }
    #[test]
    fn engines_and_tls_are_validated_without_downgrade() {
        let source = String::from_utf8(INPUT.to_vec()).unwrap();
        for engine in ["postgresql", "mysql"] {
            let profile = ConnectionProfile {
                engine: engine.into(),
                ..ConnectionProfile::new()
            };
            for mode in profile.ssl_modes() {
                let input = source
                    .replace("{", &format!("{{\"engine\":\"{engine}\","))
                    .replace("verify-full", mode);
                assert_eq!(decode(input.as_bytes()).unwrap().profile.ssl_mode, *mode);
            }
        }
        let invalid = source
            .replace("{", "{\"engine\":\"mysql\",")
            .replace("verify-full", "prefer");
        assert!(decode(invalid.as_bytes()).is_err());
    }
    #[cfg(unix)]
    #[test]
    fn owned_pipe_eof_deadline_oversize_and_reader_cleanup() {
        use std::{
            io::Write,
            os::fd::{AsRawFd, FromRawFd},
        };
        fn pipe() -> (std::fs::File, std::fs::File) {
            let mut fds = [-1; 2];
            assert_eq!(unsafe { libc::pipe(fds.as_mut_ptr()) }, 0);
            unsafe {
                (
                    std::fs::File::from_raw_fd(fds[0]),
                    std::fs::File::from_raw_fd(fds[1]),
                )
            }
        }
        let (reader, mut writer) = pipe();
        writer.write_all(INPUT).unwrap();
        drop(writer);
        let fd = reader.as_raw_fd();
        assert_eq!(read_file(reader, Duration::from_secs(1)).unwrap(), INPUT);
        assert_eq!(unsafe { libc::fcntl(fd, libc::F_GETFD) }, -1);
        let (reader, writer) = pipe();
        let fd = reader.as_raw_fd();
        assert!(read_file(reader, Duration::from_millis(10)).is_err());
        assert_eq!(unsafe { libc::fcntl(fd, libc::F_GETFD) }, -1);
        drop(writer);
        let (reader, mut writer) = pipe();
        let producer = std::thread::spawn(move || {
            let _ = writer.write_all(&vec![b' '; MAX_INPUT_BYTES + 1]);
        });
        assert!(read_file(reader, Duration::from_secs(1)).is_err());
        producer.join().unwrap();
    }
}
