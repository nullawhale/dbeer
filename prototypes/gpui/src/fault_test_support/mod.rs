//! Test-only native peer ownership. The final runner supplies the compiled peer
//! and a verified private root; neither setting is read by the application.
use crate::backend::BackendClient;
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    fs::{self, File, OpenOptions},
    io::{Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
};

#[cfg(windows)]
mod windows;

type Result<T> = std::result::Result<T, &'static str>;
const MARKER: &[u8] = b"owned-dbeer-parity-only-v1";
const MAX_FILE: u64 = 128 * 1024 * 1024;

/// The final runner's REAL Go helper, not the portable fault peer. Holding its
/// original file prevents adoption of a foreign same-byte replacement. The
/// BackendClient retains the original native Child; no PID is attached here.
pub(crate) struct RealHelperSource {
    path: PathBuf,
    file: File,
    identity: String,
    sha256: String,
}
impl RealHelperSource {
    pub fn open() -> Result<Self> {
        let path = absolute_setting("DBEER_GPUI_HELPER_PATH")?;
        let sha256 = std::env::var("DBEER_GPUI_TEST_HELPER_SHA256")
            .map_err(|_| "The final runner must pin the real helper SHA256.")?;
        if sha256.len() != 64
            || !sha256
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        {
            return Err("The real helper source SHA256 is invalid.");
        }
        let root = absolute_setting("DBEER_GPUI_TEST_ROOT")?;
        let run = root.parent().ok_or("The owned runner root is missing.")?;
        if path.parent() != Some(run.join("bin").as_path()) {
            return Err("The real helper must be the original owned runner binary.");
        }
        private(run, true)?;
        private(
            path.parent().ok_or("The owned binary parent is missing.")?,
            true,
        )?;
        real_helper_file(&path)?;
        let mut file = open_regular(&path)?;
        let original = identity(&file)?;
        if digest(&mut file)? != sha256 {
            return Err("The real helper differs from its original runner pin.");
        }
        Ok(Self {
            path,
            file,
            identity: original,
            sha256,
        })
    }
    pub fn verify(&mut self) -> Result<()> {
        let mut current = open_regular(&self.path)?;
        real_helper_file(&self.path)?;
        if identity(&self.file)? != self.identity
            || identity(&current)? != self.identity
            || digest(&mut self.file)? != self.sha256
            || digest(&mut current)? != self.sha256
        {
            return Err("The original real helper source identity changed.");
        }
        Ok(())
    }
    pub fn spawn(&mut self) -> Result<BackendClient> {
        self.verify()?;
        let client = BackendClient::spawn(&self.path)
            .map_err(|_| "Cannot start the original real helper.")?;
        self.verify()?;
        Ok(client)
    }
}

#[cfg(unix)]
fn real_helper_file(path: &Path) -> Result<()> {
    use std::os::unix::fs::MetadataExt;
    no_links(path)?;
    private(
        path.parent().ok_or("The owned binary parent is missing.")?,
        true,
    )?;
    let metadata =
        fs::symlink_metadata(path).map_err(|_| "Cannot inspect the real helper permissions.")?;
    if !metadata.is_file()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.mode() & 0o022 != 0
    {
        return Err(
            "The real helper must be an owned regular binary without group or other write permission.",
        );
    }
    Ok(())
}
#[cfg(windows)]
fn real_helper_file(path: &Path) -> Result<()> {
    private(path, false)
}

pub(crate) struct Fixture {
    pub client: BackendClient,
    pub directory: PathBuf,
    owned: OwnedDirectory,
}

impl Fixture {
    pub fn new(kind: &str, mode: &str) -> Self {
        Self::try_new(kind, mode).unwrap_or_else(|message| panic!("{message}"))
    }

    fn try_new(kind: &str, mode: &str) -> Result<Self> {
        if !matches!(kind, "preview" | "run-to-file") {
            return Err("Invalid native fault fixture kind.");
        }
        let source = absolute_setting("DBEER_GPUI_FAULT_HELPER_PATH")?;
        let expected = std::env::var("DBEER_GPUI_FAULT_HELPER_SHA256")
            .map_err(|_| "The final runner must provide the native peer SHA256.")?;
        if expected.len() != 64
            || !expected
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        {
            return Err("The native peer SHA256 is invalid.");
        }
        let mut source_file = open_regular(&source)?;
        let source_identity = identity(&source_file)?;
        if digest(&mut source_file)? != expected {
            return Err("The compiled native peer does not match the runner's SHA256.");
        }
        let mut owned = OwnedDirectory::new()?;
        let executable = if cfg!(windows) {
            "helper.exe"
        } else {
            "helper"
        };
        source_file
            .rewind()
            .map_err(|_| "Cannot read the native peer.")?;
        let mut output = create_file(&owned.path.join(executable), true)?;
        std::io::copy(&mut source_file, &mut output).map_err(|_| "Cannot copy the native peer.")?;
        output
            .sync_all()
            .map_err(|_| "Cannot persist the native peer.")?;
        drop(output);
        owned.capture(executable, false)?;
        if owned.files[executable].sha256 != expected
            || identity(&source_file)? != source_identity
            || identity(&open_regular(&source)?)? != source_identity
        {
            return Err("The native peer changed while it was copied.");
        }
        owned.write("disposable.marker", MARKER)?;
        owned.write("fixture-kind", kind.as_bytes())?;
        owned.write("mode", mode.as_bytes())?;
        // Precreate logs so the peer only appends to files already owned here.
        owned.write(
            if kind == "preview" {
                "commands"
            } else {
                "counts"
            },
            b"",
        )?;
        owned.mutable_log = Some(if kind == "preview" {
            "commands"
        } else {
            "counts"
        });
        let client = BackendClient::spawn(owned.path.join(executable))
            .map_err(|_| "Cannot start the compiled native fault peer.")?;
        // Establish the RAII owner before an await or assertion can fail.
        let mut fixture = Self {
            client,
            directory: owned.path.clone(),
            owned,
        };
        smol::block_on(crate::live_tests::bounded(fixture.client.handshake()))
            .map_err(|_| "The compiled native fault peer handshake failed.")?;
        fixture.owned.capture("fault-peer-started.json", false)?;
        let journal: serde_json::Value = serde_json::from_reader(
            open_regular(&fixture.directory.join("fault-peer-started.json"))?.take(4097),
        )
        .map_err(|_| "The native fault peer ownership journal is invalid.")?;
        if journal["schemaVersion"] != 1
            || journal["disposableMarker"] != String::from_utf8_lossy(MARKER).as_ref()
            || journal["nonce"]
                != fixture
                    .directory
                    .file_name()
                    .unwrap()
                    .to_string_lossy()
                    .as_ref()
            || journal["fixtureKind"] != kind
            || journal["state"] != "started"
            || !journal["ownedPid"].as_u64().is_some_and(|pid| pid > 0)
        {
            return Err("The native fault peer ownership journal does not match this fixture.");
        }
        Ok(fixture)
    }

    pub fn log(&self) -> String {
        let name = self.owned.mutable_log.unwrap();
        let mut file =
            open_regular(&self.directory.join(name)).unwrap_or_else(|message| panic!("{message}"));
        assert!(
            identity(&file).is_ok_and(|id| id == self.owned.files[name].identity),
            "The owned native peer log was replaced."
        );
        let mut text = String::new();
        Read::by_ref(&mut file)
            .take(64 * 1024 + 1)
            .read_to_string(&mut text)
            .expect("Cannot read the command-type-only native peer log.");
        assert!(
            text.len() <= 64 * 1024,
            "The native peer log exceeded its bound."
        );
        text
    }

    pub fn set_mode(&mut self, mode: &str) {
        self.owned
            .write("mode", mode.as_bytes())
            .unwrap_or_else(|message| panic!("{message}"));
    }

    pub fn clear_mode(&mut self) {
        self.set_mode("");
    }

    pub fn refuse_disconnect_once(&mut self) {
        self.owned
            .write("disconnect-once", b"1")
            .unwrap_or_else(|message| panic!("{message}"));
        self.owned
            .files
            .get_mut("disconnect-once")
            .unwrap()
            .may_be_removed = true;
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        // A transport failure is never an exit observation. On an assertion or
        // panic, retire pending test requests before bounded exact-child teardown.
        let exited = smol::block_on(async {
            if self.client.await_owned_exit().await.is_err() {
                self.client.retire_owned_for_test().await?;
            }
            Ok::<_, crate::backend::BackendError>(())
        })
        .is_ok()
            && self.client.owned_process_exited();
        if !exited {
            self.owned.preserve = true;
            report_cleanup_failure(
                "Owned native fault peer exit was not proven; fixture preserved.",
            );
            return;
        }
        if self.owned.cleanup().is_err() {
            self.owned.preserve = true;
            report_cleanup_failure(
                "Owned native fault fixture cleanup was refused; fixture preserved.",
            );
        }
    }
}

fn report_cleanup_failure(message: &str) {
    if std::thread::panicking() {
        eprintln!("{message}");
    } else {
        panic!("{message}");
    }
}

/// Test-only filesystem owner for real-helper export outputs. A destination is
/// reserved as absent before submission, then captured immediately after the
/// successful terminal and fixed export oracle. Cleanup never adopts new names.
pub(crate) struct FileFixture {
    owned: OwnedDirectory,
    directory: Option<File>,
    _parent: File,
    reserved: std::collections::BTreeSet<String>,
    outputs: BTreeMap<String, File>,
    finished: bool,
}
impl FileFixture {
    pub fn new() -> Result<Self> {
        let owned = OwnedDirectory::new()?;
        let directory = Some(open_directory(&owned.path)?);
        let parent = open_directory(&owned.parent)?;
        owned.verify_directories()?;
        Ok(Self {
            owned,
            directory,
            _parent: parent,
            reserved: Default::default(),
            outputs: Default::default(),
            finished: false,
        })
    }
    pub fn destination(&mut self, name: &str) -> Result<PathBuf> {
        self.owned.verify_directories()?;
        if name.is_empty()
            || Path::new(name).components().count() != 1
            || !name
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-' | b'_'))
            || !self.reserved.insert(name.into())
        {
            return Err("An export fixture output name is invalid or already reserved.");
        }
        let path = self.owned.path.join(name);
        match fs::symlink_metadata(&path) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(path),
            _ => Err("An export fixture destination is already occupied."),
        }
    }
    pub fn capture_output(&mut self, name: &str) -> Result<()> {
        self.owned.verify_directories()?;
        if !self.reserved.contains(name) || self.outputs.contains_key(name) {
            return Err("Only an original reserved output can be captured once.");
        }
        let file = open_regular(&self.owned.path.join(name))?;
        let original = identity(&file)?;
        self.owned.capture(name, false)?;
        if self.owned.files[name].identity != original {
            return Err("The export output changed while its ownership was captured.");
        }
        self.outputs.insert(name.into(), file);
        Ok(())
    }
    pub fn cleanup(&mut self) -> Result<()> {
        let result = self.cleanup_owned();
        self.finished = true;
        if result.is_err() {
            self.owned.preserve = true;
        }
        result
    }
    fn cleanup_owned(&mut self) -> Result<()> {
        self.owned.verify_directories()?;
        // Refuse before deleting any file if an output was never captured or
        // its original held handle no longer identifies the captured file.
        if self.reserved.len() != self.outputs.len()
            || self.outputs.iter().any(|(name, file)| {
                identity(file).ok().as_ref() != Some(&self.owned.files[name].identity)
            })
        {
            return Err("Export output ownership is incomplete.");
        }
        // Windows directory/output handles deny delete sharing during the DB
        // work. Release only at the existing identity-checked cleanup boundary.
        self.outputs.clear();
        self.directory.take();
        self.owned.cleanup()
    }
}
impl Drop for FileFixture {
    fn drop(&mut self) {
        if !self.finished && self.cleanup().is_err() {
            self.owned.preserve = true;
            report_cleanup_failure(
                "Owned export fixture cleanup was refused; verification failed and files were preserved.",
            );
        }
    }
}

#[cfg(test)]
mod file_fixture_tests;

struct OwnedFile {
    identity: String,
    sha256: String,
    may_be_removed: bool,
}
struct OwnedDirectory {
    path: PathBuf,
    parent: PathBuf,
    parent_identity: String,
    identity: String,
    files: BTreeMap<String, OwnedFile>,
    mutable_log: Option<&'static str>,
    preserve: bool,
}
impl OwnedDirectory {
    fn new() -> Result<Self> {
        let parent = absolute_setting("DBEER_GPUI_TEST_ROOT")?;
        let build = fs::canonicalize(Path::new(env!("CARGO_MANIFEST_DIR")).join("../../build"))
            .map_err(|_| "The ignored build directory is unavailable.")?;
        if !parent.starts_with(build) {
            return Err("The final runner's private test root must be under ignored build/.");
        }
        private(&parent, true)?;
        let parent_identity = identity(&open_directory(&parent)?)?;
        let path = parent.join(uuid::Uuid::new_v4().to_string());
        create_directory(&path)?;
        private(&path, true)?;
        let identity = identity(&open_directory(&path)?)?;
        Ok(Self {
            path,
            parent,
            parent_identity,
            identity,
            files: BTreeMap::new(),
            mutable_log: None,
            preserve: false,
        })
    }
    fn capture(&mut self, name: &str, may_be_removed: bool) -> Result<()> {
        private(&self.path.join(name), false)?;
        let mut file = open_regular(&self.path.join(name))?;
        let identity = identity(&file)?;
        let sha256 = digest(&mut file)?;
        self.files.insert(
            name.into(),
            OwnedFile {
                identity,
                sha256,
                may_be_removed,
            },
        );
        Ok(())
    }
    fn write(&mut self, name: &str, bytes: &[u8]) -> Result<()> {
        self.verify_directories()?;
        let path = self.path.join(name);
        if let Some(captured) = self.files.get(name) {
            let mut file = open_regular_options(&path, true)?;
            if identity(&file)? != captured.identity || digest(&mut file)? != captured.sha256 {
                return Err("An owned fixture file changed outside its fixture owner.");
            }
            file.set_len(0)
                .map_err(|_| "Cannot update an owned fixture file.")?;
            file.rewind()
                .map_err(|_| "Cannot update an owned fixture file.")?;
            file.write_all(bytes)
                .map_err(|_| "Cannot update an owned fixture file.")?;
            file.sync_all()
                .map_err(|_| "Cannot persist an owned fixture file.")?;
            if identity(&open_regular(&path)?)? != captured.identity {
                return Err("An owned fixture file was replaced during its update.");
            }
            drop(file);
        } else {
            create_file(&path, false)?
                .write_all(bytes)
                .map_err(|_| "Cannot write an owned fixture file.")?;
        }
        self.capture(name, false)
    }
    fn cleanup(&mut self) -> Result<()> {
        // No recursive deletion: unexpected entries and replaced files survive.
        self.verify_directories()?;
        let mut snapshots = Vec::new();
        for entry in fs::read_dir(&self.path).map_err(|_| "Cannot inventory the owned fixture.")? {
            let entry = entry.map_err(|_| "Cannot inventory the owned fixture.")?;
            let name = entry
                .file_name()
                .into_string()
                .map_err(|_| "An unrelated entry is present.")?;
            let expected = self
                .files
                .get(&name)
                .ok_or("An unrelated entry is present.")?;
            private(&entry.path(), false)?;
            let mut file = open_regular(&entry.path())?;
            let id = identity(&file)?;
            let hash = digest(&mut file)?;
            if id != expected.identity
                || (self.mutable_log != Some(name.as_str()) && hash != expected.sha256)
            {
                return Err("An owned fixture file was replaced or changed.");
            }
            snapshots.push((name, id, hash));
        }
        for (name, file) in &self.files {
            if !file.may_be_removed && !snapshots.iter().any(|(seen, _, _)| seen == name) {
                return Err("An owned fixture file is missing.");
            }
        }
        for (name, id, hash) in snapshots {
            self.verify_directories()?;
            let path = self.path.join(&name);
            let mut file = open_regular(&path)?;
            if identity(&file)? != id || digest(&mut file)? != hash {
                return Err("An owned fixture changed during cleanup.");
            }
            drop(file);
            fs::remove_file(path).map_err(|_| "Cannot remove an owned fixture file.")?;
            self.files.remove(&name);
        }
        self.verify_directories()?;
        fs::remove_dir(&self.path).map_err(|_| "Cannot remove the empty owned fixture.")?;
        self.preserve = true; // Already removed; Drop must not retry it.
        Ok(())
    }
    fn verify_directories(&self) -> Result<()> {
        private(&self.parent, true)?;
        private(&self.path, true)?;
        if identity(&open_directory(&self.parent)?)? != self.parent_identity
            || identity(&open_directory(&self.path)?)? != self.identity
        {
            return Err("The owned fixture directory or its parent was replaced.");
        }
        Ok(())
    }
}
impl Drop for OwnedDirectory {
    fn drop(&mut self) {
        // Constructor failures before spawn also clean only captured files.
        if !self.preserve && self.cleanup().is_err() {
            eprintln!("Incomplete native fault fixture preserved after cleanup refusal.");
        }
    }
}

fn absolute_setting(name: &str) -> Result<PathBuf> {
    let path = PathBuf::from(
        std::env::var_os(name)
            .ok_or("The supported final runner must provide native fault fixture settings.")?,
    );
    if !path.is_absolute() {
        return Err("Native fault fixture paths must be absolute.");
    }
    no_links(&path)?;
    fs::canonicalize(path).map_err(|_| "A native fault fixture prerequisite is missing.")
}
fn no_links(path: &Path) -> Result<()> {
    for ancestor in path.ancestors() {
        let m = fs::symlink_metadata(ancestor).map_err(|_| "A fixture path is unavailable.")?;
        if m.file_type().is_symlink() {
            return Err("Symlinked fixture paths are refused.");
        }
        #[cfg(windows)]
        {
            use std::os::windows::fs::MetadataExt;
            if m.file_attributes() & 0x400 != 0 {
                return Err("Reparse fixture paths are refused.");
            }
        }
    }
    Ok(())
}
fn open_regular(path: &Path) -> Result<File> {
    open_regular_options(path, false)
}
fn open_regular_options(path: &Path, write: bool) -> Result<File> {
    no_links(path)?;
    let mut options = OpenOptions::new();
    options.read(true).write(write);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.share_mode(3).custom_flags(0x00200000);
    }
    let file = options
        .open(path)
        .map_err(|_| "Cannot open a regular owned fixture file.")?;
    if !file.metadata().is_ok_and(|m| m.is_file()) {
        return Err("The fixture file is not regular.");
    }
    Ok(file)
}
fn digest(file: &mut File) -> Result<String> {
    if file
        .metadata()
        .map_err(|_| "Cannot inspect a fixture file.")?
        .len()
        > MAX_FILE
    {
        return Err("A native fixture file exceeded its bound.");
    }
    file.seek(SeekFrom::Start(0))
        .map_err(|_| "Cannot read a fixture file.")?;
    let mut hash = Sha256::new();
    let count = std::io::copy(&mut file.take(MAX_FILE + 1), &mut hash)
        .map_err(|_| "Cannot hash a fixture file.")?;
    if count > MAX_FILE {
        return Err("A native fixture file exceeded its bound.");
    }
    Ok(format!("{:x}", hash.finalize()))
}
#[cfg(unix)]
fn identity(file: &File) -> Result<String> {
    use std::os::unix::fs::MetadataExt;
    let m = file
        .metadata()
        .map_err(|_| "Cannot inspect an owned fixture identity.")?;
    Ok(format!("{}:{}", m.dev(), m.ino()))
}
#[cfg(windows)]
fn identity(file: &File) -> Result<String> {
    let (volume, index) = crate::files::windows_file_identity(file)
        .map_err(|_| "Cannot inspect an owned fixture identity.")?;
    Ok(format!("{volume}:{index}"))
}
#[cfg(unix)]
fn open_directory(path: &Path) -> Result<File> {
    use std::os::unix::fs::OpenOptionsExt;
    no_links(path)?;
    OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW)
        .open(path)
        .map_err(|_| "Cannot open the owned fixture directory.")
}
#[cfg(windows)]
fn open_directory(path: &Path) -> Result<File> {
    no_links(path)?;
    crate::files::windows_parent(path).map_err(|_| "Cannot open the owned fixture directory.")
}
#[cfg(unix)]
fn create_directory(path: &Path) -> Result<()> {
    use std::os::unix::fs::DirBuilderExt;
    fs::DirBuilder::new()
        .mode(0o700)
        .create(path)
        .map_err(|_| "Cannot reserve a private native fixture directory.")
}
#[cfg(windows)]
fn create_directory(path: &Path) -> Result<()> {
    windows::create_directory(path)
}
#[cfg(unix)]
fn private(path: &Path, directory: bool) -> Result<()> {
    use std::os::unix::fs::MetadataExt;
    no_links(path)?;
    let m = fs::symlink_metadata(path).map_err(|_| "Cannot inspect fixture permissions.")?;
    if m.uid() != unsafe { libc::geteuid() }
        || m.mode() & 0o077 != 0
        || if directory { !m.is_dir() } else { !m.is_file() }
    {
        return Err("Native fixture files and directories must be private and owned.");
    }
    Ok(())
}
#[cfg(windows)]
fn private(path: &Path, directory: bool) -> Result<()> {
    no_links(path)?;
    let m = fs::symlink_metadata(path).map_err(|_| "Cannot inspect fixture permissions.")?;
    if if directory { !m.is_dir() } else { !m.is_file() } {
        return Err("The native fixture path has an invalid type.");
    }
    windows::private(path)
}
fn create_file(path: &Path, executable: bool) -> Result<File> {
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(if executable { 0o700 } else { 0o600 });
    }
    #[cfg(windows)]
    {
        let _ = executable;
    }
    options
        .open(path)
        .map_err(|_| "Cannot reserve an owned native fixture file.")
}
