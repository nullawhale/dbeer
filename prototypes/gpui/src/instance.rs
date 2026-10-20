//! Kernel-released data-directory ownership. Repeated launches refuse safely;
//! no PID, stale-file deletion, second workspace window or process killing.
use std::{
    fs::{self, File, OpenOptions},
    io,
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex, MutexGuard,
        atomic::{AtomicU64, Ordering},
    },
};

pub struct DataDirectory {
    root: PathBuf,
    _lock: File,
    mutations: Mutex<()>,
    selection_sequence: AtomicU64,
}
impl DataDirectory {
    pub fn acquire(root: &Path) -> io::Result<Arc<Self>> {
        if !root.is_absolute() {
            return Err(io::Error::other("The data directory must be absolute."));
        }
        let mut builder = fs::DirBuilder::new();
        builder.recursive(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            builder.mode(0o700);
        }
        builder.create(root)?;
        let root = fs::canonicalize(root)?;
        let lock_path = root.join(".workspace.lock");
        if fs::symlink_metadata(&lock_path).is_ok_and(|m| !m.file_type().is_file()) {
            return Err(io::Error::other(
                "The workspace ownership file is not a regular file.",
            ));
        }
        let mut options = OpenOptions::new();
        options.read(true).write(true).create(true).truncate(false);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
            // Do not follow an ownership-file symlink introduced during open.
            #[cfg(target_os = "macos")]
            options.custom_flags(0x100); // O_NOFOLLOW
            #[cfg(target_os = "linux")]
            options.custom_flags(0x20000); // O_NOFOLLOW
        }
        let lock = options.open(&lock_path)?;
        if !lock.metadata()?.is_file() {
            return Err(io::Error::other("Invalid workspace ownership file."));
        }
        lock.try_lock().map_err(|_| io::Error::other("DBeer GPUI already owns this data directory, or workspace ownership is unavailable. Close the other instance before launching again."))?;
        // Only the owned application directory is tightened, never shared parents.
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&root, fs::Permissions::from_mode(0o700))?;
        }
        Ok(Arc::new(Self {
            root,
            _lock: lock,
            mutations: Mutex::new(()),
            selection_sequence: AtomicU64::new(0),
        }))
    }
    pub fn mutation(&self) -> io::Result<MutexGuard<'_, ()>> {
        self.mutations
            .lock()
            .map_err(|_| io::Error::other("Workspace mutation ownership is unavailable."))
    }
    pub fn next_selection(&self) -> u64 {
        self.selection_sequence.fetch_add(1, Ordering::SeqCst) + 1
    }
    pub fn selection_is_current(&self, sequence: u64) -> bool {
        self.selection_sequence.load(Ordering::SeqCst) == sequence
    }
    pub fn file(&self, name: &str) -> PathBuf {
        self.root.join(name)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        io::{BufRead, BufReader, Write},
        process::{Command, Stdio},
        time::{Duration, SystemTime, UNIX_EPOCH},
    };
    // The test executable is a real second process using the same lock and store.
    #[test]
    fn ownership_child() {
        let Some(root) = std::env::var_os("DBEER_OWNERSHIP_TEST_ROOT") else {
            return;
        };
        let root = PathBuf::from(root);
        let guard = DataDirectory::acquire(&root);
        if std::env::var_os("DBEER_OWNERSHIP_TEST_REFUSE").is_some() {
            assert!(
                guard.is_err(),
                "A second process acquired a live workspace."
            );
            return;
        }
        let guard = guard.expect("Child must acquire isolated workspace.");
        let store = crate::connections::ProfileStore::owned(guard);
        store.save(&[]).expect("Owner can persist profiles.");
        println!("DBEER_OWNERSHIP_READY");
        io::stdout().flush().unwrap();
        // Parent kills only this owned child to prove automatic crash release.
        std::thread::sleep(Duration::from_secs(20));
    }
    #[test]
    fn cross_process_exclusion_and_crash_reacquisition_preserve_library() {
        let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../build/gpui/ownership-tests")
            .join(format!(
                "{}-{}",
                std::process::id(),
                SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap()
                    .as_nanos()
            ));
        fs::create_dir_all(&root).unwrap();
        let spawn = || {
            let mut c = Command::new(std::env::current_exe().unwrap());
            c.args(["--exact", "instance::tests::ownership_child", "--nocapture"])
                .env("DBEER_OWNERSHIP_TEST_ROOT", &root)
                .stdout(Stdio::piped())
                .stderr(Stdio::piped());
            c
        };
        let mut child = spawn().spawn().unwrap();
        let output = child.stdout.take().unwrap();
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let ready = BufReader::new(output)
                .lines()
                .any(|line| line.is_ok_and(|line| line == "DBEER_OWNERSHIP_READY"));
            _ = tx.send(ready);
        });
        let ready = rx.recv_timeout(Duration::from_secs(10)).unwrap_or(false);
        if !ready {
            _ = child.kill();
            _ = child.wait();
            panic!("Ownership child did not become ready.");
        }
        let before = fs::read(root.join("connections.json")).unwrap();
        let refused = spawn()
            .env("DBEER_OWNERSHIP_TEST_REFUSE", "1")
            .output()
            .unwrap();
        let local_refused = DataDirectory::acquire(&root).is_err();
        _ = child.kill();
        let killed = child.wait().unwrap();
        assert!(
            refused.status.success(),
            "Second-process refusal check failed."
        );
        assert!(
            local_refused,
            "Same-process distinct owner bypassed the lock."
        );
        assert!(
            !killed.success(),
            "The owned child must be terminated for crash recovery."
        );
        let owner =
            DataDirectory::acquire(&root).expect("A crashed process must release its OS lock.");
        assert!(
            fs::read(root.join("connections.json")).unwrap() == before,
            "Refused launch changed profiles."
        );
        let store = crate::connections::ProfileStore::owned(owner.clone());
        drop(owner);
        assert!(
            DataDirectory::acquire(&root).is_err(),
            "Store must retain ownership."
        );
        drop(store);
        drop(DataDirectory::acquire(&root).unwrap());
        fs::remove_dir_all(root).unwrap();
    }
}
