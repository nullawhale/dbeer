//! Captured SQL file metadata and prepared, same-directory atomic publication.
//! SQL and user paths deliberately have no Debug implementation or diagnostics.
use std::{
    fs::{self, File, Metadata, OpenOptions},
    io::{Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
    time::SystemTime,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FileError {
    Read,
    Utf8,
    Write,
    Changed,
    Locked,
    #[cfg(windows)]
    Uncertain,
}
impl std::fmt::Display for FileError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::Read => "The SQL file could not be opened as UTF-8.",
            Self::Utf8 => "The SQL file could not be opened as UTF-8.",
            Self::Write => "The SQL file could not be saved.",
            Self::Changed => {
                "The SQL file changed outside DBeer. Use Save As to choose a destination again."
            }
            Self::Locked => "The SQL file is locked or unavailable for replacement.",
            #[cfg(windows)] Self::Uncertain => "The SQL file save outcome could not be verified. Keep the document open and inspect the destination before retrying.",
        })
    }
}

#[derive(Clone, PartialEq, Eq)]
struct Stamp {
    len: u64,
    modified: Option<SystemTime>,
    #[cfg(unix)]
    identity: (u64, u64, u32, i64, i64),
    #[cfg(windows)]
    identity: (u32, u64),
    #[cfg(windows)]
    file_id: Option<(u32, u64)>,
}
impl Stamp {
    fn of(m: &Metadata) -> Self {
        Self {
            len: m.len(),
            modified: m.modified().ok(),
            #[cfg(unix)]
            identity: {
                use std::os::unix::fs::MetadataExt;
                (m.dev(), m.ino(), m.mode(), m.ctime(), m.ctime_nsec())
            },
            #[cfg(windows)]
            identity: {
                use std::os::windows::fs::MetadataExt;
                (m.file_attributes(), m.creation_time())
            },
            #[cfg(windows)]
            file_id: None,
        }
    }
    fn file(file: &File) -> Result<Self, FileError> {
        let value = Self::of(&file.metadata().map_err(|_| FileError::Read)?);
        #[cfg(windows)]
        {
            let mut value = value;
            value.file_id = Some(windows_file_identity(file)?);
            Ok(value)
        }
        #[cfg(not(windows))]
        {
            Ok(value)
        }
    }
}
#[derive(Clone, PartialEq, Eq)]
pub struct FileBinding {
    pub path: PathBuf,
    stamp: Stamp,
    /// Original on-disk bytes, including a possible UTF-8 BOM. Not persisted.
    bytes: Arc<[u8]>,
}
impl FileBinding {
    pub fn matches_destination(&self, path: &Path) -> bool {
        destination(path).is_ok_and(|target| target == self.path)
    }
    pub fn title(&self) -> String {
        self.path
            .file_name()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_else(|| "SQL".into())
    }
}
/// File state is independent of database state and editor/source revision.
/// A completed older save records its captured source, never the current editor.
#[derive(Default)]
pub struct DocumentFile {
    pub binding: Option<FileBinding>,
    pub revision: u64,
    pub saved_source: Option<Arc<str>>,
    pub saved_source_revision: Option<u64>,
    /// An unverified publication must never appear clean merely because the
    /// current text equals an older saved snapshot. Never persist this state.
    pub publication_uncertain: bool,
}
impl DocumentFile {
    pub fn dirty(&self, source: &str) -> bool {
        self.publication_uncertain || self.saved_source.as_deref() != Some(source)
    }
    pub fn record_saved(&mut self, binding: FileBinding, source: Arc<str>, revision: u64) {
        self.binding = Some(binding);
        self.revision += 1;
        self.saved_source = Some(source);
        self.saved_source_revision = Some(revision);
        self.publication_uncertain = false;
    }
}
pub struct OpenedSql {
    pub binding: FileBinding,
    pub source: Arc<str>,
}

fn open_regular(path: &Path, write: bool) -> Result<File, FileError> {
    if !fs::symlink_metadata(path).is_ok_and(|m| m.is_file()) {
        return Err(FileError::Read);
    }
    let mut options = OpenOptions::new();
    options.read(true).write(write);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.custom_flags(0x00200000);
    }
    let file = options.open(path).map_err(|_| FileError::Read)?;
    let m = file.metadata().map_err(|_| FileError::Read)?;
    if !m.is_file() {
        return Err(FileError::Read);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        if m.file_attributes() & 0x400 != 0 {
            return Err(FileError::Read);
        }
    }
    Ok(file)
}
/// No arbitrary editor-file cap: checked allocation and a metadata-sized read
/// bound refuse allocation failure, streams, growth and partial/changing reads.
fn read_stable(file: &mut File) -> Result<(Stamp, Arc<[u8]>), FileError> {
    let before = Stamp::file(file)?;
    let len = usize::try_from(before.len).map_err(|_| FileError::Read)?;
    let mut bytes = Vec::new();
    bytes.try_reserve_exact(len).map_err(|_| FileError::Read)?;
    file.seek(SeekFrom::Start(0)).map_err(|_| FileError::Read)?;
    let mut chunk = [0u8; 64 * 1024];
    while bytes.len() < len {
        let count = (len - bytes.len()).min(chunk.len());
        let n = file
            .read(&mut chunk[..count])
            .map_err(|_| FileError::Read)?;
        if n == 0 {
            return Err(FileError::Changed);
        }
        bytes.extend_from_slice(&chunk[..n]);
    }
    if file.read(&mut chunk[..1]).map_err(|_| FileError::Read)? != 0 || Stamp::file(file)? != before
    {
        return Err(FileError::Changed);
    }
    Ok((before, bytes.into()))
}
fn destination(path: &Path) -> Result<PathBuf, FileError> {
    let name = path.file_name().ok_or(FileError::Write)?;
    let parent = path
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    Ok(fs::canonicalize(parent)
        .map_err(|_| FileError::Write)?
        .join(name))
}
pub fn open(path: &Path) -> Result<OpenedSql, FileError> {
    let path = destination(path).map_err(|_| FileError::Read)?;
    let mut file = open_regular(&path, false)?;
    let (stamp, bytes) = read_stable(&mut file)?;
    if !open_regular(&path, false)
        .and_then(|file| Stamp::file(&file))
        .is_ok_and(|now| now == stamp)
    {
        return Err(FileError::Changed);
    }
    let source = std::str::from_utf8(&bytes).map_err(|_| FileError::Utf8)?;
    // Foundation's explicit UTF-8 file reader consumes an initial signature.
    let source = Arc::from(source.strip_prefix('\u{feff}').unwrap_or(source));
    Ok(OpenedSql {
        binding: FileBinding { path, stamp, bytes },
        source,
    })
}

/// The exact native-picker destination before asynchronous save preparation.
/// Existing files need not contain UTF-8. Absence is captured explicitly.
pub struct CapturedDestination {
    path: PathBuf,
    original: Option<FileBinding>,
    #[cfg(any(unix, windows))]
    directory: File,
}
impl CapturedDestination {
    /// A chooser selecting an existing SQL binding retains its older byte and
    /// identity authority as well as the chooser-time parent anchor.
    pub fn capture_for_binding(path: &Path, binding: &FileBinding) -> Result<Self, FileError> {
        let capture = Self::capture(path)?;
        if capture.original.as_ref() != Some(binding) {
            return Err(FileError::Changed);
        }
        Ok(capture)
    }
    pub fn capture(path: &Path) -> Result<Self, FileError> {
        let path = destination(path)?;
        #[cfg(any(unix, windows))]
        let directory = open_directory(path.parent().ok_or(FileError::Write)?)?;
        let original = match fs::symlink_metadata(&path) {
            Ok(m) if m.is_file() => {
                let mut file = open_regular(&path, false)?;
                let (stamp, bytes) = read_stable(&mut file)?;
                Some(FileBinding {
                    path: path.clone(),
                    stamp,
                    bytes,
                })
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
            _ => return Err(FileError::Changed),
        };
        #[cfg(any(unix, windows))]
        if !same_directory(
            &directory,
            &open_directory(path.parent().ok_or(FileError::Changed)?)?,
        )? {
            return Err(FileError::Changed);
        }
        Ok(Self {
            path,
            original,
            #[cfg(any(unix, windows))]
            directory,
        })
    }
}

#[cfg(any(unix, windows))]
fn open_directory(path: &Path) -> Result<File, FileError> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW)
            .open(path)
            .map_err(|_| FileError::Write)
    }
    #[cfg(windows)]
    {
        windows_parent(path)
    }
}
#[cfg(any(unix, windows))]
fn same_directory(a: &File, b: &File) -> Result<bool, FileError> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        let a = a.metadata().map_err(|_| FileError::Changed)?;
        let b = b.metadata().map_err(|_| FileError::Changed)?;
        Ok(a.dev() == b.dev() && a.ino() == b.ino())
    }
    #[cfg(windows)]
    {
        Ok(windows_file_identity(a)? == windows_file_identity(b)?)
    }
}

static NEXT_TEMP: AtomicU64 = AtomicU64::new(1);
enum PreparedSource {
    Text(Arc<str>),
    Bytes(Arc<[u8]>),
}
impl PreparedSource {
    fn as_bytes(&self) -> &[u8] {
        match self {
            Self::Text(source) => source.as_bytes(),
            Self::Bytes(source) => source,
        }
    }
}
pub struct PreparedSave {
    target: PathBuf,
    temporary: PathBuf,
    original: Option<(File, Stamp, Arc<[u8]>)>,
    source: PreparedSource,
    temporary_created: bool,
    temporary_file: Option<File>,
    temporary_stamp: Option<Stamp>,
    #[cfg(any(unix, windows))]
    directory: File,
}
impl PreparedSave {
    /// Writes and syncs only a new temporary. No destination is truncated.
    pub fn prepare(
        source: Arc<str>,
        path: &Path,
        expected: Option<&FileBinding>,
    ) -> Result<Self, FileError> {
        Self::prepare_with_sync(source, path, expected, |file| file.sync_all())
    }
    /// Refuse changed or appeared destinations since native chooser completion.
    pub fn prepare_captured(
        source: Arc<str>,
        path: &Path,
        capture: &CapturedDestination,
    ) -> Result<Self, FileError> {
        Self::prepare_source_captured(PreparedSource::Text(source), path, capture)
    }
    /// Exact new recovery copies use the same private staging and captured
    /// no-replace publication as text. Existing captures are always refused.
    /// No UTF-8 conversion or decoding occurs.
    pub fn prepare_bytes_captured(
        source: Arc<[u8]>,
        path: &Path,
        capture: &CapturedDestination,
    ) -> Result<Self, FileError> {
        if capture.original.is_some() {
            return Err(FileError::Changed);
        }
        Self::prepare_source_captured(PreparedSource::Bytes(source), path, capture)
    }
    fn prepare_source_captured(
        source: PreparedSource,
        path: &Path,
        capture: &CapturedDestination,
    ) -> Result<Self, FileError> {
        if destination(path)? != capture.path {
            return Err(FileError::Changed);
        }
        #[cfg(any(unix, windows))]
        if !same_directory(
            &capture.directory,
            &open_directory(capture.path.parent().ok_or(FileError::Changed)?)?,
        )? {
            return Err(FileError::Changed);
        }
        let prepared =
            Self::prepare_source_with_sync(source, path, capture.original.as_ref(), |file| {
                file.sync_all()
            })?;
        #[cfg(any(unix, windows))]
        if !same_directory(&capture.directory, &prepared.directory)? {
            return Err(FileError::Changed);
        }
        if prepared.original.is_some() != capture.original.is_some() {
            return Err(FileError::Changed);
        }
        Ok(prepared)
    }
    fn prepare_with_sync(
        source: Arc<str>,
        path: &Path,
        expected: Option<&FileBinding>,
        sync: impl FnOnce(&File) -> std::io::Result<()>,
    ) -> Result<Self, FileError> {
        Self::prepare_source_with_sync(PreparedSource::Text(source), path, expected, sync)
    }
    fn prepare_source_with_sync(
        source: PreparedSource,
        path: &Path,
        expected: Option<&FileBinding>,
        sync: impl FnOnce(&File) -> std::io::Result<()>,
    ) -> Result<Self, FileError> {
        Self::prepare_named(source, path, expected, sync, || {
            format!(
                ".dbeer-sql-{}-{}.tmp",
                std::process::id(),
                NEXT_TEMP.fetch_add(1, Ordering::Relaxed)
            )
        })
    }
    fn prepare_named(
        source: PreparedSource,
        path: &Path,
        expected: Option<&FileBinding>,
        sync: impl FnOnce(&File) -> std::io::Result<()>,
        temporary_name: impl FnOnce() -> String,
    ) -> Result<Self, FileError> {
        let target = destination(path)?;
        if expected.is_some_and(|binding| binding.path != target) {
            return Err(FileError::Changed);
        }
        let original = match fs::symlink_metadata(&target) {
            Ok(m) if m.is_file() => {
                #[cfg(windows)]
                if m.permissions().readonly() {
                    return Err(FileError::Write);
                }
                let mut file = open_regular(&target, false).map_err(|_| FileError::Write)?;
                file.try_lock().map_err(|_| FileError::Locked)?;
                let (stamp, bytes) = read_stable(&mut file)?;
                if expected.is_some_and(|b| b.stamp != stamp || b.bytes != bytes) {
                    return Err(FileError::Changed);
                }
                Some((file, stamp, bytes))
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound && expected.is_none() => None,
            _ => return Err(FileError::Changed),
        };
        let parent = target.parent().ok_or(FileError::Write)?;
        #[cfg(any(unix, windows))]
        let directory = open_directory(parent)?;
        let temporary = parent.join(temporary_name());
        let mut prepared = Self {
            target,
            temporary,
            original,
            source,
            temporary_created: false,
            temporary_file: None,
            temporary_stamp: None,
            #[cfg(any(unix, windows))]
            directory,
        };
        let file = prepared.create_temporary()?;
        prepared.temporary_created = true;
        prepared.temporary_file = Some(file);
        #[cfg(test)]
        test_support::preparation(&prepared, test_support::Stage::BeforeWrite)?;
        let mut file = prepared
            .temporary_file
            .as_ref()
            .unwrap()
            .try_clone()
            .map_err(|_| FileError::Write)?;
        file.write_all(prepared.source.as_bytes())
            .map_err(|_| FileError::Write)?;
        #[cfg(test)]
        test_support::preparation(&prepared, test_support::Stage::BeforeSync)?;
        sync(&file).map_err(|_| FileError::Write)?;
        // Check exact bytes after the potentially slow write, off the UI thread.
        prepared.validate_bytes()?;
        let (stamp, bytes) = read_stable(&mut file)?;
        if bytes.as_ref() != prepared.source.as_bytes() {
            return Err(FileError::Changed);
        }
        prepared.temporary_stamp = Some(stamp);
        prepared.temporary_file = Some(file);
        Ok(prepared)
    }
    fn create_temporary(&self) -> Result<File, FileError> {
        #[cfg(unix)]
        {
            use std::os::fd::{AsRawFd, FromRawFd};
            let name = c_name(&self.temporary)?;
            let fd = unsafe {
                libc::openat(
                    self.directory.as_raw_fd(),
                    name.as_ptr(),
                    libc::O_RDWR
                        | libc::O_CREAT
                        | libc::O_EXCL
                        | libc::O_NOFOLLOW
                        | libc::O_CLOEXEC,
                    0o600,
                )
            };
            if fd < 0 {
                return Err(FileError::Write);
            }
            Ok(unsafe { File::from_raw_fd(fd) })
        }
        #[cfg(windows)]
        {
            windows_create_private(&self.temporary)
        }
        #[cfg(not(any(unix, windows)))]
        {
            Err(FileError::Write)
        }
    }

    fn validate_bytes(&self) -> Result<(), FileError> {
        if let Some((file, stamp, bytes)) = &self.original {
            let mut file = file.try_clone().map_err(|_| FileError::Write)?;
            let (now, contents) = read_stable(&mut file)?;
            if &now != stamp || &contents != bytes {
                return Err(FileError::Changed);
            }
        }
        self.validate_target()
    }
    fn validate_target(&self) -> Result<(), FileError> {
        #[cfg(unix)]
        {
            use std::os::fd::{AsRawFd, FromRawFd};
            let actual = fs::metadata(self.target.parent().ok_or(FileError::Changed)?)
                .map_err(|_| FileError::Changed)?;
            let anchored = self.directory.metadata().map_err(|_| FileError::Changed)?;
            {
                use std::os::unix::fs::MetadataExt;
                if actual.dev() != anchored.dev() || actual.ino() != anchored.ino() {
                    return Err(FileError::Changed);
                }
            }
            let name = c_name(&self.target)?;
            let fd = unsafe {
                libc::openat(
                    self.directory.as_raw_fd(),
                    name.as_ptr(),
                    libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC,
                )
            };
            let now = if fd < 0 {
                let error = std::io::Error::last_os_error();
                if error.kind() != std::io::ErrorKind::NotFound {
                    return Err(FileError::Changed);
                }
                None
            } else {
                let file = unsafe { File::from_raw_fd(fd) };
                let meta = file.metadata().map_err(|_| FileError::Changed)?;
                if !meta.is_file() {
                    return Err(FileError::Changed);
                }
                Some(Stamp::of(&meta))
            };
            if now.as_ref() != self.original.as_ref().map(|(_, stamp, _)| stamp) {
                return Err(FileError::Changed);
            }
        }
        #[cfg(not(unix))]
        {
            #[cfg(windows)]
            if windows_file_identity(&self.directory)?
                != windows_file_identity(&windows_parent(
                    self.target.parent().ok_or(FileError::Changed)?,
                )?)?
            {
                return Err(FileError::Changed);
            }
            let now = match fs::symlink_metadata(&self.target) {
                Ok(m) if m.is_file() => Some(Stamp::file(&open_regular(&self.target, false)?)?),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
                _ => return Err(FileError::Changed),
            };
            if now.as_ref() != self.original.as_ref().map(|(_, stamp, _)| stamp) {
                return Err(FileError::Changed);
            }
        }
        Ok(())
    }
    pub fn matches_capture(&self, source: &str, path: &Path) -> bool {
        self.source.as_bytes() == source.as_bytes()
            && destination(path).is_ok_and(|target| target == self.target)
    }
    #[cfg(test)]
    pub(super) fn temporary_path(&self) -> &Path {
        &self.temporary
    }

    // Compare through the retained handle with a fixed buffer. A pathname or
    // restored timestamp alone cannot prove ownership of the prepared content.
    fn validate_prepared_content(&self, file: &File) -> Result<(), FileError> {
        let mut reader = file.try_clone().map_err(|_| FileError::Write)?;
        reader
            .seek(SeekFrom::Start(0))
            .map_err(|_| FileError::Write)?;
        let mut expected = self.source.as_bytes();
        let mut buffer = [0u8; 64 * 1024];
        while !expected.is_empty() {
            let count = expected.len().min(buffer.len());
            reader
                .read_exact(&mut buffer[..count])
                .map_err(|_| FileError::Changed)?;
            if buffer[..count] != expected[..count] {
                return Err(FileError::Changed);
            }
            expected = &expected[count..];
        }
        if reader
            .read(&mut buffer[..1])
            .map_err(|_| FileError::Changed)?
            != 0
            || self.temporary_stamp.as_ref() != Some(&Stamp::file(file)?)
        {
            return Err(FileError::Changed);
        }
        Ok(())
    }
    /// Publication is one synchronous UI ownership boundary after callback checks.
    /// No await may occur between checking the request token and calling publish.
    pub fn publish(self) -> Result<FileBinding, FileError> {
        self.validate_bytes()?;
        let published = self.temporary_file.as_ref().ok_or(FileError::Write)?;
        let before = Stamp::file(published)?;
        if self.temporary_stamp.as_ref() != Some(&before) {
            return Err(FileError::Changed);
        }
        #[cfg(unix)]
        {
            use std::os::fd::{AsRawFd, FromRawFd};
            let name = c_name(&self.temporary)?;
            let fd = unsafe {
                libc::openat(
                    self.directory.as_raw_fd(),
                    name.as_ptr(),
                    libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                )
            };
            if fd < 0 {
                return Err(FileError::Write);
            }
            let named = unsafe { File::from_raw_fd(fd) };
            if Stamp::file(&named)? != before {
                return Err(FileError::Changed);
            }
        }
        #[cfg(not(unix))]
        {
            let named = open_regular(&self.temporary, false)?;
            if Stamp::file(&named)? != before {
                return Err(FileError::Changed);
            }
        }
        self.validate_prepared_content(published)?;
        // Destination permissions are transferred only at the authorized
        // publication boundary; staging remains private through preparation.
        if let Some((original, _, _)) = &self.original {
            published
                .set_permissions(
                    original
                        .metadata()
                        .map_err(|_| FileError::Write)?
                        .permissions(),
                )
                .map_err(|_| FileError::Write)?;
            #[cfg(windows)]
            windows_copy_dacl(original, published)?;
        }
        #[cfg(unix)]
        {
            use std::os::fd::AsRawFd;
            let from = c_name(&self.temporary)?;
            let to = c_name(&self.target)?;
            let fd = self.directory.as_raw_fd();
            let result = if self.original.is_some() {
                unsafe { libc::renameat(fd, from.as_ptr(), fd, to.as_ptr()) }
            } else {
                #[cfg(target_os = "linux")]
                {
                    unsafe {
                        libc::renameat2(fd, from.as_ptr(), fd, to.as_ptr(), libc::RENAME_NOREPLACE)
                    }
                }
                #[cfg(target_os = "macos")]
                {
                    unsafe {
                        libc::renameatx_np(fd, from.as_ptr(), fd, to.as_ptr(), libc::RENAME_EXCL)
                    }
                }
                #[cfg(not(any(target_os = "linux", target_os = "macos")))]
                {
                    return Err(FileError::Write);
                }
            };
            if result != 0 {
                return Err(FileError::Write);
            }
            // Publication already happened: a directory sync failure cannot be
            // reported as an unchanged destination or invite a duplicate retry.
            _ = self.directory.sync_all();
        }
        #[cfg(windows)]
        windows_publish(
            published,
            &self.directory,
            &self.target,
            self.original
                .as_ref()
                .map(|(file, _, _)| windows_file_identity(file))
                .transpose()?,
        )?;
        #[cfg(not(any(unix, windows)))]
        {
            return Err(FileError::Write);
        }
        // Use the published inode's metadata; source bytes are known exactly.
        let stamp = Stamp::file(published).unwrap_or(before);
        Ok(FileBinding {
            path: self.target.clone(),
            stamp,
            bytes: Arc::from(self.source.as_bytes()),
        })
    }
}
#[cfg(unix)]
fn c_name(path: &Path) -> Result<std::ffi::CString, FileError> {
    use std::os::unix::ffi::OsStrExt;
    std::ffi::CString::new(path.file_name().ok_or(FileError::Write)?.as_bytes())
        .map_err(|_| FileError::Write)
}
impl Drop for PreparedSave {
    fn drop(&mut self) {
        if !self.temporary_created {
            return;
        }
        #[cfg(unix)]
        {
            use std::os::fd::AsRawFd;
            use std::os::{fd::FromRawFd, unix::fs::MetadataExt};
            if let (Ok(name), Some(owned)) = (c_name(&self.temporary), self.temporary_file.as_ref())
            {
                let fd = unsafe {
                    libc::openat(
                        self.directory.as_raw_fd(),
                        name.as_ptr(),
                        libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC,
                    )
                };
                if fd >= 0 {
                    let named = unsafe { File::from_raw_fd(fd) };
                    if owned
                        .metadata()
                        .ok()
                        .zip(named.metadata().ok())
                        .is_some_and(|(a, b)| a.dev() == b.dev() && a.ino() == b.ino())
                    {
                        _ = unsafe { libc::unlinkat(self.directory.as_raw_fd(), name.as_ptr(), 0) };
                    }
                }
            }
        }
        #[cfg(windows)]
        {
            if let Some(owned) = self.temporary_file.as_ref()
                && open_regular(&self.temporary, false)
                    .ok()
                    .is_some_and(|named| {
                        windows_file_identity(owned)
                            .ok()
                            .zip(windows_file_identity(&named).ok())
                            .is_some_and(|(a, b)| a == b)
                    })
            {
                _ = fs::remove_file(&self.temporary);
            }
        }
    }
}
#[cfg(windows)]
fn windows_create_private(path: &Path) -> Result<File, FileError> {
    use std::{
        ffi::c_void,
        os::windows::{ffi::OsStrExt, io::FromRawHandle},
    };
    #[repr(C)]
    struct SecurityAttributes {
        length: u32,
        descriptor: *mut c_void,
        inherit: i32,
    }
    #[link(name = "advapi32")]
    unsafe extern "system" {
        fn OpenProcessToken(process: *mut c_void, access: u32, token: *mut *mut c_void) -> i32;
        fn GetTokenInformation(
            token: *mut c_void,
            class: u32,
            buffer: *mut c_void,
            length: u32,
            needed: *mut u32,
        ) -> i32;
        fn ConvertSidToStringSidW(sid: *mut c_void, text: *mut *mut u16) -> i32;
        fn ConvertStringSecurityDescriptorToSecurityDescriptorW(
            text: *const u16,
            revision: u32,
            descriptor: *mut *mut c_void,
            size: *mut u32,
        ) -> i32;
    }
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn CreateFileW(
            name: *const u16,
            access: u32,
            share: u32,
            security: *const SecurityAttributes,
            creation: u32,
            flags: u32,
            template: *mut c_void,
        ) -> *mut c_void;
        fn GetCurrentProcess() -> *mut c_void;
        fn CloseHandle(handle: *mut c_void) -> i32;
        fn LocalFree(memory: *mut c_void) -> *mut c_void;
    }
    struct Token(*mut c_void);
    impl Drop for Token {
        fn drop(&mut self) {
            _ = unsafe { CloseHandle(self.0) };
        }
    }
    struct Local(*mut c_void);
    impl Drop for Local {
        fn drop(&mut self) {
            _ = unsafe { LocalFree(self.0) };
        }
    }
    let mut token = std::ptr::null_mut();
    if unsafe { OpenProcessToken(GetCurrentProcess(), 8, &mut token) } == 0 {
        return Err(FileError::Write);
    }
    let token = Token(token);
    let mut needed = 0;
    _ = unsafe { GetTokenInformation(token.0, 1, std::ptr::null_mut(), 0, &mut needed) };
    if needed == 0 || needed > 65_536 {
        return Err(FileError::Write);
    }
    let mut user = vec![0u64; (needed as usize).div_ceil(8)];
    if unsafe { GetTokenInformation(token.0, 1, user.as_mut_ptr().cast(), needed, &mut needed) }
        == 0
    {
        return Err(FileError::Write);
    }
    // TOKEN_USER begins with SID_AND_ATTRIBUTES, whose first member is PSID.
    let sid = unsafe { *user.as_ptr().cast::<*mut c_void>() };
    let mut sid_text = std::ptr::null_mut();
    if unsafe { ConvertSidToStringSidW(sid, &mut sid_text) } == 0 {
        return Err(FileError::Write);
    }
    let sid_owner = Local(sid_text.cast());
    let mut sid_length = 0;
    while unsafe { *sid_text.add(sid_length) } != 0 {
        sid_length += 1;
    }
    let sid = String::from_utf16(unsafe { std::slice::from_raw_parts(sid_text, sid_length) })
        .map_err(|_| FileError::Write)?;
    drop(sid_owner);
    let descriptor_text: Vec<u16> = format!("D:P(A;;FA;;;{sid})")
        .encode_utf16()
        .chain(Some(0))
        .collect();
    let mut descriptor = std::ptr::null_mut();
    if unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            descriptor_text.as_ptr(),
            1,
            &mut descriptor,
            std::ptr::null_mut(),
        )
    } == 0
    {
        return Err(FileError::Write);
    }
    let descriptor_owner = Local(descriptor);
    let attributes = SecurityAttributes {
        length: std::mem::size_of::<SecurityAttributes>() as u32,
        descriptor,
        inherit: 0,
    };
    let name: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
    // READ/WRITE, DELETE, READ_CONTROL, WRITE_DAC; retained through publication.
    let handle = unsafe {
        CreateFileW(
            name.as_ptr(),
            0xc0070000,
            7,
            &attributes,
            1,
            0x00200080,
            std::ptr::null_mut(),
        )
    };
    drop(descriptor_owner);
    if handle as isize == -1 {
        return Err(FileError::Write);
    }
    Ok(unsafe { File::from_raw_handle(handle) })
}

#[cfg(windows)]
pub(super) fn windows_file_identity(file: &File) -> Result<(u32, u64), FileError> {
    use std::os::windows::io::AsRawHandle;
    #[repr(C)]
    struct Info {
        attributes: u32,
        creation: [u32; 2],
        access: [u32; 2],
        write: [u32; 2],
        volume: u32,
        size_high: u32,
        size_low: u32,
        links: u32,
        index_high: u32,
        index_low: u32,
    }
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn GetFileInformationByHandle(file: *mut std::ffi::c_void, info: *mut Info) -> i32;
    }
    let mut info: Info = unsafe { std::mem::zeroed() };
    if unsafe { GetFileInformationByHandle(file.as_raw_handle(), &mut info) } == 0 {
        return Err(FileError::Read);
    }
    Ok((
        info.volume,
        (u64::from(info.index_high) << 32) | u64::from(info.index_low),
    ))
}
#[cfg(windows)]
pub(super) fn windows_parent(path: &Path) -> Result<File, FileError> {
    use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
    let file = OpenOptions::new()
        .read(true)
        .share_mode(3)
        .custom_flags(0x02200000)
        .open(path)
        .map_err(|_| FileError::Write)?; // backup semantics, open reparse point, deny delete sharing
    if file
        .metadata()
        .map_err(|_| FileError::Write)?
        .file_attributes()
        & 0x400
        != 0
    {
        return Err(FileError::Changed);
    }
    Ok(file)
}
#[cfg(windows)]
fn windows_copy_dacl(original: &File, temporary: &File) -> Result<(), FileError> {
    use std::{ffi::c_void, os::windows::io::AsRawHandle};
    #[link(name = "advapi32")]
    unsafe extern "system" {
        fn GetSecurityInfo(
            handle: *mut c_void,
            kind: u32,
            info: u32,
            owner: *mut *mut c_void,
            group: *mut *mut c_void,
            dacl: *mut *mut c_void,
            sacl: *mut *mut c_void,
            descriptor: *mut *mut c_void,
        ) -> u32;
        fn SetSecurityInfo(
            handle: *mut c_void,
            kind: u32,
            info: u32,
            owner: *mut c_void,
            group: *mut c_void,
            dacl: *mut c_void,
            sacl: *mut c_void,
        ) -> u32;
        fn GetSecurityDescriptorControl(
            descriptor: *mut c_void,
            control: *mut u16,
            revision: *mut u32,
        ) -> i32;
    }
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn LocalFree(memory: *mut c_void) -> *mut c_void;
    }
    struct Descriptor(*mut c_void);
    impl Drop for Descriptor {
        fn drop(&mut self) {
            _ = unsafe { LocalFree(self.0) };
        }
    }
    let null = std::ptr::null_mut::<c_void>();
    let mut dacl = null;
    let mut descriptor = null;
    if unsafe {
        GetSecurityInfo(
            original.as_raw_handle(),
            1,
            4,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            &mut dacl,
            std::ptr::null_mut(),
            &mut descriptor,
        )
    } != 0
    {
        return Err(FileError::Write);
    }
    let descriptor = Descriptor(descriptor);
    let mut control = 0;
    let mut revision = 0;
    if unsafe { GetSecurityDescriptorControl(descriptor.0, &mut control, &mut revision) } == 0 {
        return Err(FileError::Write);
    }
    let protection = if control & 0x1000 != 0 {
        0x80000000
    } else {
        0x20000000
    };
    if unsafe {
        SetSecurityInfo(
            temporary.as_raw_handle(),
            1,
            4 | protection,
            null,
            null,
            dacl,
            null,
        )
    } != 0
    {
        return Err(FileError::Write);
    }
    Ok(())
}
#[cfg(windows)]
fn windows_publish(
    temporary: &File,
    directory: &File,
    target: &Path,
    original: Option<(u32, u64)>,
) -> Result<(), FileError> {
    use std::{
        ffi::c_void,
        os::windows::{ffi::OsStrExt, io::AsRawHandle},
    };
    #[repr(C)]
    struct RenameInfo {
        replace: u8,
        root: *mut c_void,
        length: u32,
        name: [u16; 1],
    }
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn SetFileInformationByHandle(
            file: *mut c_void,
            class: i32,
            info: *const c_void,
            length: u32,
        ) -> i32;
    }
    // FILE_RENAME_INFO uses a byte length and WCHAR filename. The directory
    // handle anchors the relative Unicode name, including extended-length paths.
    let name = target
        .file_name()
        .ok_or(FileError::Write)?
        .encode_wide()
        .collect::<Vec<_>>();
    let byte_length = name.len().checked_mul(2).ok_or(FileError::Write)?;
    let offset = std::mem::offset_of!(RenameInfo, name);
    let length = offset
        .checked_add(byte_length)
        .ok_or(FileError::Write)?
        .max(std::mem::size_of::<RenameInfo>());
    let native_length = u32::try_from(length).map_err(|_| FileError::Write)?;
    let mut buffer = Vec::<u64>::new();
    buffer
        .try_reserve_exact(length.div_ceil(8))
        .map_err(|_| FileError::Write)?;
    buffer.resize(length.div_ceil(8), 0);
    let info = buffer.as_mut_ptr().cast::<RenameInfo>();
    unsafe {
        (*info).replace = u8::from(original.is_some());
        (*info).root = directory.as_raw_handle();
        (*info).length = u32::try_from(byte_length).map_err(|_| FileError::Write)?;
        std::ptr::copy_nonoverlapping(
            name.as_ptr(),
            buffer.as_mut_ptr().cast::<u8>().add(offset).cast::<u16>(),
            name.len(),
        );
    }
    let result = unsafe {
        SetFileInformationByHandle(
            temporary.as_raw_handle(),
            3,
            buffer.as_ptr().cast(),
            native_length,
        )
    };
    if result != 0 {
        return Ok(());
    }
    // Do not infer "unchanged" from an OS/filesystem error. Reconcile identity
    // without a second publication; ambiguity keeps the original binding dirty.
    let current = open_regular(target, false).and_then(|file| windows_file_identity(&file));
    if current
        .as_ref()
        .is_ok_and(|id| windows_file_identity(temporary).is_ok_and(|source| *id == source))
    {
        return Ok(());
    }
    windows_reconcile_publication(
        original,
        current.ok(),
        windows_file_identity(temporary).ok(),
        fs::symlink_metadata(target)
            .is_err_and(|error| error.kind() == std::io::ErrorKind::NotFound),
    )
}
#[cfg(windows)]
fn windows_reconcile_publication(
    original: Option<(u32, u64)>,
    current: Option<(u32, u64)>,
    published: Option<(u32, u64)>,
    absent: bool,
) -> Result<(), FileError> {
    if current.is_some() && current == published {
        return Ok(());
    }
    if (current.is_some() && current == original) || (original.is_none() && absent) {
        return Err(FileError::Write);
    }
    Err(FileError::Uncertain)
}

#[cfg(test)]
pub(crate) mod test_support {
    use super::*;
    use std::cell::RefCell;

    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub(crate) enum Stage {
        BeforeWrite,
        BeforeSync,
    }
    type Hook = Box<dyn FnMut(Stage, &Path, &Path, &File) -> std::io::Result<()>>;
    thread_local! {
        static HOOK: RefCell<Option<Hook>> = const { RefCell::new(None) };
    }
    pub(crate) fn with_preparation_hook<R>(
        hook: impl FnMut(Stage, &Path, &Path, &File) -> std::io::Result<()> + 'static,
        action: impl FnOnce() -> R,
    ) -> R {
        struct Restore(Option<Hook>);
        impl Drop for Restore {
            fn drop(&mut self) {
                HOOK.with(|slot| *slot.borrow_mut() = self.0.take());
            }
        }
        let previous = HOOK.with(|slot| slot.borrow_mut().replace(Box::new(hook)));
        let _restore = Restore(previous);
        action()
    }
    pub(super) fn preparation(prepared: &PreparedSave, stage: Stage) -> Result<(), FileError> {
        HOOK.with(|slot| {
            let Some(mut hook) = slot.borrow_mut().take() else {
                return Ok(());
            };
            // Do not retain a RefCell borrow across arbitrary test callbacks.
            // Nested preparation has no outer hook; a nested scoped hook restores normally.
            let result = hook(
                stage,
                &prepared.target,
                &prepared.temporary,
                prepared.temporary_file.as_ref().ok_or(FileError::Write)?,
            );
            *slot.borrow_mut() = Some(hook);
            result.map_err(|_| FileError::Write)
        })
    }
    #[cfg(windows)]
    pub(crate) mod windows {
        use super::super::*;
        use std::{
            ffi::c_void,
            os::windows::{fs::OpenOptionsExt, io::AsRawHandle},
        };
        #[link(name = "advapi32")]
        unsafe extern "system" {
            fn GetKernelObjectSecurity(
                handle: *mut c_void,
                info: u32,
                buffer: *mut c_void,
                length: u32,
                needed: *mut u32,
            ) -> i32;
            fn SetKernelObjectSecurity(
                handle: *mut c_void,
                info: u32,
                descriptor: *mut c_void,
            ) -> i32;
            fn ConvertSecurityDescriptorToStringSecurityDescriptorW(
                descriptor: *const c_void,
                revision: u32,
                info: u32,
                text: *mut *mut u16,
                length: *mut u32,
            ) -> i32;
            fn ConvertStringSecurityDescriptorToSecurityDescriptorW(
                text: *const u16,
                revision: u32,
                descriptor: *mut *mut c_void,
                size: *mut u32,
            ) -> i32;
        }
        #[link(name = "kernel32")]
        unsafe extern "system" {
            fn LocalFree(memory: *mut c_void) -> *mut c_void;
        }
        pub(crate) fn descriptor(file: &File) -> String {
            let mut needed = 0;
            _ = unsafe {
                GetKernelObjectSecurity(
                    file.as_raw_handle(),
                    4,
                    std::ptr::null_mut(),
                    0,
                    &mut needed,
                )
            };
            assert!(needed > 0);
            let mut bytes = vec![0u8; needed as usize];
            assert_ne!(
                unsafe {
                    GetKernelObjectSecurity(
                        file.as_raw_handle(),
                        4,
                        bytes.as_mut_ptr().cast(),
                        needed,
                        &mut needed,
                    )
                },
                0
            );
            let mut text = std::ptr::null_mut();
            let mut length = 0;
            assert_ne!(
                unsafe {
                    ConvertSecurityDescriptorToStringSecurityDescriptorW(
                        bytes.as_ptr().cast(),
                        1,
                        4,
                        &mut text,
                        &mut length,
                    )
                },
                0
            );
            let value = String::from_utf16(unsafe {
                std::slice::from_raw_parts(text, length as usize - 1)
            })
            .unwrap();
            _ = unsafe { LocalFree(text.cast()) };
            value
        }
        pub(crate) fn set_broad(file: &File, inheritable: bool) {
            let value = if inheritable {
                "D:P(A;OICI;FA;;;WD)"
            } else {
                "D:P(A;;FA;;;WD)"
            };
            let text: Vec<u16> = value.encode_utf16().chain(Some(0)).collect();
            let mut descriptor = std::ptr::null_mut();
            assert_ne!(
                unsafe {
                    ConvertStringSecurityDescriptorToSecurityDescriptorW(
                        text.as_ptr(),
                        1,
                        &mut descriptor,
                        std::ptr::null_mut(),
                    )
                },
                0
            );
            assert_ne!(
                unsafe { SetKernelObjectSecurity(file.as_raw_handle(), 0x80000004, descriptor) },
                0
            );
            _ = unsafe { LocalFree(descriptor) };
        }
        pub(crate) fn set_broad_inheritance(path: &Path) {
            let directory = OpenOptions::new()
                .access_mode(0x60000)
                .custom_flags(0x02000000)
                .open(path)
                .unwrap();
            set_broad(&directory, true);
        }
        pub(crate) fn create_private(path: &Path) -> Result<File, FileError> {
            windows_create_private(path)
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("../../build/gpui/file-tests")
                .join(crate::connections::ConnectionProfile::new().id);
            fs::create_dir_all(&root).unwrap();
            Self(fs::canonicalize(root).unwrap())
        }
        fn no_temporary(&self) {
            assert!(fs::read_dir(&self.0).unwrap().all(|e| {
                !e.unwrap()
                    .file_name()
                    .to_string_lossy()
                    .starts_with(".dbeer-sql-")
            }));
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            _ = fs::remove_dir_all(&self.0);
        }
    }
    #[test]
    fn chooser_capture_for_binding_preserves_older_identity_bytes_and_absence_authority() {
        let fixture = Fixture::new();
        let path = fixture.0.join("bound.sql");
        fs::write(&path, "original bound bytes\r\n").unwrap();
        let binding = open(&path).unwrap().binding;
        let capture = CapturedDestination::capture_for_binding(&path, &binding).unwrap();
        PreparedSave::prepare_captured(Arc::from("captured local text\r\n"), &path, &capture)
            .unwrap()
            .publish()
            .unwrap();
        assert_eq!(fs::read(&path).unwrap(), b"captured local text\r\n");
        assert!(matches!(
            CapturedDestination::capture_for_binding(&path, &binding),
            Err(FileError::Changed)
        ));
        let current = open(&path).unwrap().binding;
        let other = fixture.0.join("different.sql");
        fs::write(&other, "captured local text\r\n").unwrap();
        assert!(matches!(
            CapturedDestination::capture_for_binding(&other, &current),
            Err(FileError::Changed)
        ));
        fs::remove_file(&path).unwrap();
        assert!(matches!(
            CapturedDestination::capture_for_binding(&path, &current),
            Err(FileError::Changed)
        ));
        assert!(!path.exists());
        assert_eq!(fs::read(&other).unwrap(), b"captured local text\r\n");
        fixture.no_temporary();
    }
    #[cfg(unix)]
    #[test]
    fn dropped_preparation_never_removes_an_unowned_replacement_temporary() {
        let fixture = Fixture::new();
        let target = fixture.0.join("loaded.json");
        fs::write(&target, "original").unwrap();
        let prepared = PreparedSave::prepare(Arc::from("captured export"), &target, None).unwrap();
        let temporary = prepared.temporary.clone();
        let detached = fixture.0.join("detached-owned-temp");
        fs::rename(&temporary, &detached).unwrap();
        fs::write(&temporary, "unrelated owner").unwrap();
        drop(prepared);
        assert_eq!(fs::read_to_string(&temporary).unwrap(), "unrelated owner");
        assert_eq!(fs::read_to_string(&target).unwrap(), "original");
    }
    #[test]
    fn utf8_signature_unicode_crlf_empty_extension_and_long_paths_roundtrip_exactly() {
        let fixture = Fixture::new();
        let source = "SELECT 'caf\u{e9}\u{1f642}';\r\n-- unchanged\r\n";
        for name in [
            "space caf\u{e9} \u{1f642}.sql",
            "extension.unspecified",
            "without-extension",
        ] {
            let path = fixture.0.join(name);
            fs::write(&path, format!("\u{feff}{source}")).unwrap();
            let opened = open(&path).unwrap();
            assert_eq!(opened.source.as_ref(), source);
            assert_eq!(opened.binding.title(), name);
            let binding = PreparedSave::prepare(opened.source, &path, Some(&opened.binding))
                .unwrap()
                .publish()
                .unwrap();
            assert_eq!(fs::read(&path).unwrap(), source.as_bytes());
            assert_eq!(open(&binding.path).unwrap().source.as_ref(), source);
        }
        let long = fixture
            .0
            .join("long-folder-".repeat(7))
            .join("nested-folder-".repeat(6))
            .join("more-folders-".repeat(6));
        fs::create_dir_all(&long).unwrap();
        let path = long.join("SQL \u{1f642}.sql");
        assert!(path.as_os_str().len() > 260);
        PreparedSave::prepare(Arc::from(source), &path, None)
            .unwrap()
            .publish()
            .unwrap();
        assert_eq!(open(&path).unwrap().source.as_ref(), source);
        let empty = fixture.0.join("empty.sql");
        fs::write(&empty, []).unwrap();
        assert_eq!(open(&empty).unwrap().source.as_ref(), "");
        fixture.no_temporary();
    }
    #[test]
    fn invalid_utf8_binary_nonregular_and_external_changes_are_refused_without_mutation() {
        let fixture = Fixture::new();
        let path = fixture.0.join("invalid.sql");
        fs::write(&path, [0xef, 0xbb, 0xbf, 0xf0, 0x28, 0x8c, 0xbc]).unwrap();
        assert!(matches!(open(&path), Err(FileError::Utf8)));
        assert!(open(&fixture.0).is_err());
        fs::write(&path, "original").unwrap();
        let binding = open(&path).unwrap().binding;
        fs::write(&path, "external edit").unwrap();
        assert!(matches!(
            PreparedSave::prepare(Arc::from("replacement"), &path, Some(&binding)),
            Err(FileError::Changed)
        ));
        assert_eq!(fs::read_to_string(&path).unwrap(), "external edit");
        fixture.no_temporary();
    }
    #[test]
    fn cancelled_preparation_sync_failure_and_changed_target_leave_original_and_clean_temps() {
        let fixture = Fixture::new();
        let path = fixture.0.join("original.sql");
        fs::write(&path, "original").unwrap();
        drop(PreparedSave::prepare(Arc::from("cancelled"), &path, None).unwrap());
        assert_eq!(fs::read_to_string(&path).unwrap(), "original");
        assert!(
            PreparedSave::prepare_with_sync(Arc::from("not synced"), &path, None, |_| Err(
                std::io::Error::other("synthetic sync failure")
            ))
            .is_err()
        );
        assert_eq!(fs::read_to_string(&path).unwrap(), "original");
        let prepared = PreparedSave::prepare(Arc::from("stale"), &path, None).unwrap();
        fs::write(&path, "external after preparation").unwrap();
        assert!(matches!(prepared.publish(), Err(FileError::Changed)));
        assert_eq!(
            fs::read_to_string(&path).unwrap(),
            "external after preparation"
        );
        let prepared = PreparedSave::prepare(Arc::from("prepared"), &path, None).unwrap();
        fs::write(&prepared.temporary, "tampered temporary").unwrap();
        assert!(matches!(prepared.publish(), Err(FileError::Changed)));
        assert_eq!(
            fs::read_to_string(&path).unwrap(),
            "external after preparation"
        );
        let absent = fixture.0.join("appeared.sql");
        let prepared = PreparedSave::prepare(Arc::from("stale"), &absent, None).unwrap();
        fs::write(&absent, "appeared").unwrap();
        assert!(prepared.publish().is_err());
        assert_eq!(fs::read_to_string(&absent).unwrap(), "appeared");
        fixture.no_temporary();
    }
    #[test]
    fn locked_target_is_refused_and_saved_snapshot_does_not_mark_newer_text_clean() {
        let fixture = Fixture::new();
        let path = fixture.0.join("locked.sql");
        fs::write(&path, "original").unwrap();
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .open(&path)
            .unwrap();
        lock.try_lock().unwrap();
        assert!(matches!(
            PreparedSave::prepare(Arc::from("refused"), &path, None),
            Err(FileError::Locked)
        ));
        assert_eq!(fs::read_to_string(&path).unwrap(), "original");
        drop(lock);
        let opened = open(&path).unwrap();
        let mut state = DocumentFile::default();
        state.record_saved(opened.binding, Arc::from("original"), 7);
        assert!(!state.dirty("original"));
        assert!(state.dirty("newer"));
        assert_eq!(state.saved_source_revision, Some(7));
        fixture.no_temporary();
    }
    #[cfg(unix)]
    #[test]
    fn unix_atomic_replacement_preserves_readonly_permissions_and_refuses_symlinks_and_retargeted_parent()
     {
        use std::os::unix::fs::{PermissionsExt, symlink};
        let fixture = Fixture::new();
        let path = fixture.0.join("readonly.sql");
        fs::write(&path, "original").unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o440)).unwrap();
        let opened = open(&path).unwrap();
        PreparedSave::prepare(Arc::from("replacement"), &path, Some(&opened.binding))
            .unwrap()
            .publish()
            .unwrap();
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o440
        );
        assert_eq!(fs::read_to_string(&path).unwrap(), "replacement");
        let link = fixture.0.join("link.sql");
        symlink(&path, &link).unwrap();
        assert!(open(&link).is_err());
        assert!(PreparedSave::prepare(Arc::from("unsafe"), &link, None).is_err());
        let parent = fixture.0.join("parent");
        fs::create_dir(&parent).unwrap();
        let prepared =
            PreparedSave::prepare(Arc::from("unsafe"), &parent.join("target.sql"), None).unwrap();
        fs::rename(&parent, fixture.0.join("moved")).unwrap();
        fs::create_dir(&parent).unwrap();
        assert!(prepared.publish().is_err());
        assert!(!parent.join("target.sql").exists());
        assert_eq!(fs::read_dir(fixture.0.join("moved")).unwrap().count(), 0);
        fixture.no_temporary();
    }
    #[cfg(windows)]
    #[test]
    fn windows_readonly_and_deny_share_handle_refuse_replacement_without_chmod() {
        use std::os::windows::fs::OpenOptionsExt;
        let fixture = Fixture::new();
        let path = fixture.0.join("readonly.sql");
        fs::write(&path, "original").unwrap();
        let original = fs::metadata(&path).unwrap().permissions();
        let mut readonly = original.clone();
        readonly.set_readonly(true);
        fs::set_permissions(&path, readonly).unwrap();
        assert!(PreparedSave::prepare(Arc::from("refused"), &path, None).is_err());
        assert!(fs::metadata(&path).unwrap().permissions().readonly());
        fs::set_permissions(&path, original).unwrap();
        let deny = OpenOptions::new()
            .read(true)
            .share_mode(0)
            .open(&path)
            .unwrap();
        assert!(PreparedSave::prepare(Arc::from("refused"), &path, None).is_err());
        drop(deny);
        assert_eq!(fs::read_to_string(&path).unwrap(), "original");
        fixture.no_temporary();
    }
    #[cfg(windows)]
    #[test]
    fn windows_rename_preserves_dacl_and_ambiguous_publication_never_becomes_unchanged_failure() {
        use std::{ffi::c_void, os::windows::io::AsRawHandle};
        fn snapshot(file: &File) -> Vec<u8> {
            #[link(name = "advapi32")]
            unsafe extern "system" {
                fn GetKernelObjectSecurity(
                    handle: *mut c_void,
                    info: u32,
                    buffer: *mut c_void,
                    length: u32,
                    needed: *mut u32,
                ) -> i32;
            }
            let mut needed = 0;
            _ = unsafe {
                GetKernelObjectSecurity(
                    file.as_raw_handle(),
                    4,
                    std::ptr::null_mut(),
                    0,
                    &mut needed,
                )
            };
            assert!(needed > 0);
            let mut bytes = vec![0u8; needed as usize];
            assert_ne!(
                unsafe {
                    GetKernelObjectSecurity(
                        file.as_raw_handle(),
                        4,
                        bytes.as_mut_ptr().cast(),
                        needed,
                        &mut needed,
                    )
                },
                0
            );
            bytes
        }
        let fixture = Fixture::new();
        let path = fixture.0.join("DACL.sql");
        fs::write(&path, "original").unwrap();
        let before = snapshot(&open_regular(&path, false).unwrap());
        let binding = PreparedSave::prepare(Arc::from("SELECT '\u{1f642}';\r\n"), &path, None)
            .unwrap()
            .publish()
            .unwrap();
        assert_eq!(
            snapshot(&open_regular(&binding.path, false).unwrap()),
            before
        );
        assert_eq!(
            fs::read_to_string(&path).unwrap(),
            "SELECT '\u{1f642}';\r\n"
        );
        let old = Some((1, 1));
        let published = Some((1, 2));
        assert_eq!(
            windows_reconcile_publication(old, published, published, false),
            Ok(())
        );
        assert_eq!(
            windows_reconcile_publication(old, old, published, false),
            Err(FileError::Write)
        );
        assert_eq!(
            windows_reconcile_publication(old, Some((1, 3)), published, false),
            Err(FileError::Uncertain)
        );
        assert_eq!(
            windows_reconcile_publication(old, None, published, true),
            Err(FileError::Uncertain)
        );
        assert_eq!(
            windows_reconcile_publication(None, None, published, true),
            Err(FileError::Write)
        );
        fixture.no_temporary();
    }
    #[cfg(windows)]
    #[test]
    fn protected_staging_precedes_first_byte_and_destination_dacl_transfer() {
        use super::test_support::windows::{descriptor, set_broad};
        use std::os::windows::fs::OpenOptionsExt;
        let fixture = Fixture::new();
        let directory = OpenOptions::new()
            .access_mode(0x60000)
            .custom_flags(0x02000000)
            .open(&fixture.0)
            .unwrap();
        set_broad(&directory, true);
        let target = fixture.0.join("existing.sql");
        let mut original = windows_create_private(&target).unwrap();
        let private = descriptor(&original);
        assert!(private.starts_with("D:P(A;;FA;;;"));
        assert_eq!(private.matches("(A;").count(), 1);
        assert_eq!(original.metadata().unwrap().len(), 0);
        // The same CREATE_NEW primitive refuses a foreign colliding name without cleanup.
        assert!(windows_create_private(&target).is_err());
        original.write_all(b"original synthetic bytes").unwrap();
        set_broad(&original, false);
        let broad = descriptor(&original);
        drop(original);
        let prepared = PreparedSave::prepare_with_sync(
            Arc::from("synthetic SQL or loaded export"),
            &target,
            None,
            |file| {
                assert_eq!(
                    descriptor(file),
                    private,
                    "Destination DACL transferred during preparation."
                );
                file.sync_all()
            },
        )
        .unwrap();
        assert_eq!(
            descriptor(prepared.temporary_file.as_ref().unwrap()),
            private
        );
        prepared.publish().unwrap();
        assert_eq!(descriptor(&open_regular(&target, false).unwrap()), broad);
        let absent = fixture.0.join("new-export.json");
        let capture = CapturedDestination::capture(&absent).unwrap();
        let prepared =
            PreparedSave::prepare_captured(Arc::from("synthetic loaded export"), &absent, &capture)
                .unwrap();
        assert_eq!(
            descriptor(prepared.temporary_file.as_ref().unwrap()),
            private
        );
        drop(prepared); // stale/cancelled owner keeps the staging bytes private until cleanup.
        assert!(!absent.exists());
        let failed = PreparedSave::prepare_with_sync(
            Arc::from("synthetic failed preparation"),
            &target,
            None,
            |file| {
                assert_eq!(descriptor(file), private);
                Err(std::io::Error::other("synthetic sync fault"))
            },
        );
        assert!(failed.is_err());
        fixture.no_temporary();
    }
    #[test]
    fn create_new_collision_does_not_register_cleanup_for_the_foreign_file() {
        let fixture = Fixture::new();
        let target = fixture.0.join("target.sql");
        let collision = fixture.0.join("owned-synthetic-collision.tmp");
        fs::write(&target, b"original synthetic destination").unwrap();
        fs::write(&collision, b"foreign synthetic collision").unwrap();
        assert!(
            PreparedSave::prepare_named(
                PreparedSource::Text(Arc::from("source")),
                &target,
                None,
                |file| file.sync_all(),
                || "owned-synthetic-collision.tmp".into()
            )
            .is_err()
        );
        assert_eq!(fs::read(collision).unwrap(), b"foreign synthetic collision");
        assert_eq!(fs::read(target).unwrap(), b"original synthetic destination");
    }
    #[test]
    fn exact_raw_recovery_copy_refuses_existing_appeared_and_foreign_staging() {
        let fixture = Fixture::new();
        let target = fixture.0.join("raw-recovery.bin");
        let bytes: Arc<[u8]> = Arc::from([0xff, 0, b'{', b'\r', b'\n']);
        let capture = CapturedDestination::capture(&target).unwrap();
        test_support::with_preparation_hook(
            |stage, _, _, file| {
                if stage == test_support::Stage::BeforeWrite {
                    assert_eq!(file.metadata().unwrap().len(), 0);
                    #[cfg(unix)]
                    {
                        use std::os::unix::fs::PermissionsExt;
                        assert_eq!(file.metadata().unwrap().permissions().mode() & 0o777, 0o600);
                    }
                }
                Ok(())
            },
            || {
                PreparedSave::prepare_bytes_captured(bytes.clone(), &target, &capture)
                    .unwrap()
                    .publish()
                    .unwrap()
            },
        );
        assert_eq!(fs::read(&target).unwrap(), bytes.as_ref());
        let capture = CapturedDestination::capture(&target).unwrap();
        assert!(PreparedSave::prepare_bytes_captured(bytes.clone(), &target, &capture).is_err());
        assert_eq!(fs::read(&target).unwrap(), bytes.as_ref());

        let appeared = fixture.0.join("appeared-recovery.bin");
        let capture = CapturedDestination::capture(&appeared).unwrap();
        let prepared =
            PreparedSave::prepare_bytes_captured(bytes.clone(), &appeared, &capture).unwrap();
        fs::write(&appeared, b"foreign appeared backup").unwrap();
        assert!(prepared.publish().is_err());
        assert_eq!(fs::read(&appeared).unwrap(), b"foreign appeared backup");

        let foreign = fixture.0.join("foreign-stage-recovery.bin");
        let moved = fixture.0.join("moved-owned-recovery.bin");
        let capture = CapturedDestination::capture(&foreign).unwrap();
        let temporary = Arc::new(std::sync::Mutex::new(PathBuf::new()));
        let output = temporary.clone();
        let result = test_support::with_preparation_hook(
            move |stage, _, path, _| {
                if stage == test_support::Stage::BeforeSync {
                    *output.lock().unwrap() = path.to_owned();
                    fs::rename(path, &moved).unwrap();
                    fs::write(path, b"foreign recovery staging").unwrap();
                    return Err(std::io::Error::other("synthetic backup sync failure"));
                }
                Ok(())
            },
            || PreparedSave::prepare_bytes_captured(bytes, &foreign, &capture),
        );
        assert!(matches!(result, Err(FileError::Write)));
        assert!(!foreign.exists());
        assert_eq!(
            fs::read(&*temporary.lock().unwrap()).unwrap(),
            b"foreign recovery staging"
        );
    }
}
