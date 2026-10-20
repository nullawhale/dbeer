//! Exact paired-binary proof before the optional offline LSP process starts.
//! No database handshake, application state, credentials, or detached reader.
use super::{BuildIdentity, BuildInfo, Component, IdentityError, NativeTarget};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File, OpenOptions},
    io::{self, Read, Seek, SeekFrom},
    path::{Path, PathBuf},
    process::{Child, ChildStdout, Command, Stdio},
    time::{Duration, Instant},
};

const MAX_BINARY: u64 = 512 * 1024 * 1024;
const MAX_INFO: usize = 4160;
const PROBE_TIMEOUT: Duration = Duration::from_secs(10);

/// The original file remains retained for the offline child's whole lifetime.
/// Windows denies write/delete sharing; Linux executes this retained descriptor.
pub(crate) struct VerifiedHelper {
    path: PathBuf,
    file: File,
    digest: [u8; 32],
    #[cfg(windows)]
    _parents: Vec<File>,
}

pub(crate) fn prepare_helper(path: &Path) -> Result<Option<VerifiedHelper>, IdentityError> {
    BuildIdentity::optional_embedded()?
        .map(|identity| VerifiedHelper::prepare(path, &identity))
        .transpose()
}

fn no_links(path: &Path) -> Result<(), IdentityError> {
    if !path.is_absolute() {
        return Err(IdentityError);
    }
    for parent in path.ancestors() {
        let metadata = fs::symlink_metadata(parent).map_err(|_| IdentityError)?;
        if metadata.file_type().is_symlink() {
            return Err(IdentityError);
        }
        #[cfg(windows)]
        {
            use std::os::windows::fs::MetadataExt;
            if metadata.file_attributes() & 0x400 != 0 {
                return Err(IdentityError);
            }
        }
    }
    Ok(())
}

fn open(path: &Path) -> Result<File, IdentityError> {
    no_links(path)?;
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.share_mode(1).custom_flags(0x0020_0000); // read sharing only; open reparse point
    }
    let file = options.open(path).map_err(|_| IdentityError)?;
    let metadata = file.metadata().map_err(|_| IdentityError)?;
    if !metadata.is_file() || metadata.len() > MAX_BINARY {
        return Err(IdentityError);
    }
    Ok(file)
}

fn file_identity(file: &File) -> Result<(u64, u64), IdentityError> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        let metadata = file.metadata().map_err(|_| IdentityError)?;
        Ok((metadata.dev(), metadata.ino()))
    }
    #[cfg(windows)]
    {
        crate::files::windows_file_identity(file)
            .map(|(volume, index)| (u64::from(volume), index))
            .map_err(|_| IdentityError)
    }
    #[cfg(not(any(unix, windows)))]
    {
        let _ = file;
        Err(IdentityError)
    }
}

fn scan(file: &mut File, marker: &[u8]) -> Result<([u8; 32], bool), IdentityError> {
    file.seek(SeekFrom::Start(0)).map_err(|_| IdentityError)?;
    let mut hasher = Sha256::new();
    let mut total = 0_u64;
    let mut chunk = [0_u8; 64 * 1024];
    let mut tail = Vec::new();
    let mut found = false;
    loop {
        let count = file.read(&mut chunk).map_err(|_| IdentityError)?;
        if count == 0 {
            return Ok((hasher.finalize().into(), found));
        }
        total = total.checked_add(count as u64).ok_or(IdentityError)?;
        if total > MAX_BINARY {
            return Err(IdentityError);
        }
        hasher.update(&chunk[..count]);
        if !marker.is_empty() && !found {
            tail.extend_from_slice(&chunk[..count]);
            found = tail.windows(marker.len()).any(|window| window == marker);
            let keep = marker.len().saturating_sub(1).min(tail.len());
            let start = tail.len() - keep;
            tail.copy_within(start.., 0);
            tail.truncate(keep);
        }
    }
}

fn native_header(file: &mut File, target: NativeTarget) -> Result<(), IdentityError> {
    file.seek(SeekFrom::Start(0)).map_err(|_| IdentityError)?;
    let mut header = [0_u8; 64];
    file.read_exact(&mut header).map_err(|_| IdentityError)?;
    let valid = match target {
        NativeTarget::UbuntuX64 => header[..6] == *b"\x7fELF\x02\x01" && header[18..20] == [62, 0],
        NativeTarget::WindowsX64 => {
            let offset = u32::from_le_bytes(header[60..64].try_into().unwrap());
            if header[..2] != *b"MZ" || offset > 1024 * 1024 {
                return Err(IdentityError);
            }
            file.seek(SeekFrom::Start(u64::from(offset)))
                .map_err(|_| IdentityError)?;
            let mut pe = [0_u8; 26];
            file.read_exact(&mut pe).map_err(|_| IdentityError)?;
            pe[..4] == *b"PE\0\0" && pe[4..6] == [0x64, 0x86] && pe[24..26] == [0x0b, 0x02]
        }
    };
    valid.then_some(()).ok_or(IdentityError)
}

impl VerifiedHelper {
    fn prepare(path: &Path, expected: &BuildIdentity) -> Result<Self, IdentityError> {
        expected.validate()?;
        let mut file = open(path)?;
        native_header(&mut file, expected.target)?;
        let (digest, marker) = scan(&mut file, expected.canonical_json()?.as_bytes())?;
        if !marker {
            // An old helper may ignore an unknown metadata flag and start its
            // normal protocol. Never launch it just to find out.
            return Err(IdentityError);
        }
        #[cfg(windows)]
        let parents = path
            .ancestors()
            .skip(1)
            .map(|parent| crate::files::windows_parent(parent).map_err(|_| IdentityError))
            .collect::<Result<Vec<_>, _>>()?;
        let mut verified = Self {
            path: path.to_owned(),
            file,
            digest,
            #[cfg(windows)]
            _parents: parents,
        };
        verified.verify()?;
        let mut command = Command::new(verified.execution_path());
        command
            .arg("--build-info")
            .env_clear()
            .envs(crate::language_service::transport::sanitized_environment(
                std::env::vars_os(),
                cfg!(windows),
            ))
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            command.creation_flags(0x0800_0000);
        }
        let mut child = OwnedProbe(command.spawn().map_err(|_| IdentityError)?);
        let output = read_probe(&mut child.0, PROBE_TIMEOUT)?;
        validate_report(&output, expected)?;
        verified.verify()?;
        Ok(verified)
    }

    pub(crate) fn verify(&mut self) -> Result<(), IdentityError> {
        let named = open(&self.path)?;
        if file_identity(&named)? != file_identity(&self.file)?
            || scan(&mut self.file, &[])?.0 != self.digest
        {
            return Err(IdentityError);
        }
        Ok(())
    }

    pub(crate) fn execution_path(&self) -> PathBuf {
        #[cfg(target_os = "linux")]
        {
            use std::os::fd::AsRawFd;
            PathBuf::from(format!("/proc/self/fd/{}", self.file.as_raw_fd()))
        }
        #[cfg(not(target_os = "linux"))]
        self.path.clone()
    }
}

fn validate_report(output: &[u8], expected: &BuildIdentity) -> Result<(), IdentityError> {
    if output.len() > MAX_INFO {
        return Err(IdentityError);
    }
    let info: BuildInfo = serde_json::from_slice(output).map_err(|_| IdentityError)?;
    if info.component != Component::Helper || info.identity != *expected {
        return Err(IdentityError);
    }
    info.identity.validate()
}

struct OwnedProbe(Child);
impl Drop for OwnedProbe {
    fn drop(&mut self) {
        if !matches!(self.0.try_wait(), Ok(Some(_))) {
            _ = self.0.kill();
        }
        _ = self.0.wait();
    }
}

fn read_probe(child: &mut Child, timeout: Duration) -> Result<Vec<u8>, IdentityError> {
    let mut output = child.stdout.take().ok_or(IdentityError)?;
    #[cfg(unix)]
    {
        use std::os::fd::AsRawFd;
        let flags = unsafe { libc::fcntl(output.as_raw_fd(), libc::F_GETFL) };
        if flags < 0
            || unsafe { libc::fcntl(output.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) }
                < 0
        {
            return Err(IdentityError);
        }
    }
    let deadline = Instant::now() + timeout;
    let mut bytes = Vec::new();
    let mut buffer = [0_u8; MAX_INFO + 1];
    let mut eof = false;
    loop {
        if Instant::now() >= deadline {
            return Err(IdentityError);
        }
        if !eof {
            match available(&mut output, &mut buffer) {
                Ok(Some(0)) => eof = true,
                Ok(Some(count)) => bytes.extend_from_slice(&buffer[..count]),
                Ok(None) => {}
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(_) => return Err(IdentityError),
            }
        }
        if bytes.len() > MAX_INFO {
            return Err(IdentityError);
        }
        if let Some(status) = child.try_wait().map_err(|_| IdentityError)? {
            if !status.success() {
                return Err(IdentityError);
            }
            if eof {
                return Ok(bytes);
            }
        }
        std::thread::sleep(Duration::from_millis(5));
    }
}

#[cfg(unix)]
fn available(output: &mut ChildStdout, bytes: &mut [u8]) -> io::Result<Option<usize>> {
    match output.read(bytes) {
        Err(error) if error.kind() == io::ErrorKind::WouldBlock => Ok(None),
        value => value.map(Some),
    }
}

#[cfg(windows)]
fn available(output: &mut ChildStdout, bytes: &mut [u8]) -> io::Result<Option<usize>> {
    use std::{ffi::c_void, os::windows::io::AsRawHandle};
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn PeekNamedPipe(
            handle: *mut c_void,
            buffer: *mut c_void,
            size: u32,
            read: *mut u32,
            available: *mut u32,
            left: *mut u32,
        ) -> i32;
    }
    let mut count = 0_u32;
    if unsafe {
        PeekNamedPipe(
            output.as_raw_handle(),
            std::ptr::null_mut(),
            0,
            std::ptr::null_mut(),
            &mut count,
            std::ptr::null_mut(),
        )
    } == 0
    {
        let error = io::Error::last_os_error();
        return if error.raw_os_error() == Some(109) {
            Ok(Some(0))
        } else {
            Err(error)
        };
    }
    if count == 0 {
        return Ok(None);
    }
    let limit = (count as usize).min(bytes.len());
    output.read(&mut bytes[..limit]).map(Some)
}

#[cfg(not(any(unix, windows)))]
fn available(_: &mut ChildStdout, _: &mut [u8]) -> io::Result<Option<usize>> {
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "Unsupported product target",
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn identity() -> BuildIdentity {
        BuildIdentity::parse(include_bytes!(
            "../../fixtures/packaging/build-identity.json"
        ))
        .unwrap()
    }
    #[test]
    fn offline_report_requires_exact_pair_and_strict_original_metadata() {
        let expected = identity();
        let value = BuildInfo {
            component: Component::Helper,
            identity: expected.clone(),
        };
        let valid = serde_json::to_vec(&value).unwrap();
        assert!(validate_report(&valid, &expected).is_ok());
        for output in [
            vec![b' '; MAX_INFO + 1],
            b"{}".to_vec(),
            br#"{"component":"helper","component":"helper","identity":{}}"#.to_vec(),
        ] {
            assert!(validate_report(&output, &expected).is_err());
        }
        let mut changed = value;
        changed.component = Component::Gui;
        assert!(validate_report(&serde_json::to_vec(&changed).unwrap(), &expected).is_err());
        changed.component = Component::Helper;
        changed.identity.source_sha256 = "b".repeat(64);
        assert!(validate_report(&serde_json::to_vec(&changed).unwrap(), &expected).is_err());
    }
    #[test]
    fn unmarked_development_performs_no_metadata_filesystem_or_process_probe() {
        assert!(BuildIdentity::optional_embedded().unwrap().is_none());
        assert!(
            prepare_helper(Path::new("relative-nonexistent-do-not-open"))
                .unwrap()
                .is_none()
        );
    }
}
