//! Full helper export capture and target fingerprint. No loaded-result encoding.
use crate::{backend, sql};
use sha2::{Digest, Sha256};
use std::{fs, io::Read, path::Path};

pub(super) fn validate(fragment: &sql::PreparedFragment) -> Result<(), &'static str> {
    crate::scripts::validate(fragment)?;
    fragment.single_statement()?;
    Ok(())
}
pub(super) fn capture_destination(path: &Path) -> Result<backend::ExportDestination, &'static str> {
    let parent = path
        .parent()
        .ok_or("The export destination is unavailable.")?;
    if !path.is_absolute()
        || !fs::canonicalize(parent).is_ok_and(|canonical| same_path(&canonical, parent))
    {
        return Err("Choose a regular destination in an existing local directory.");
    }
    #[cfg(windows)]
    let parent_handle =
        crate::files::windows_parent(parent).map_err(|_| "The export directory is unavailable.")?;
    #[cfg(not(windows))]
    let parent_handle =
        fs::File::open(parent).map_err(|_| "The export directory is unavailable.")?;
    let parent_identity = Some(identity(&parent_handle)?);
    let info = match fs::symlink_metadata(path) {
        Ok(info) if info.is_file() && !info.file_type().is_symlink() => info,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return Ok(backend::ExportDestination {
                exists: false,
                identity: None,
                parent_identity,
                size: 0,
                sha256: String::new(),
                modified_nanoseconds: None,
            });
        }
        _ => return Err("The export destination is unavailable."),
    };
    let mut file = fs::File::open(path).map_err(|_| "The export destination is unavailable.")?;
    let mut hash = Sha256::new();
    let mut buffer = [0u8; 64 * 1024];
    loop {
        let n = file
            .read(&mut buffer)
            .map_err(|_| "The export destination could not be captured.")?;
        if n == 0 {
            break;
        }
        hash.update(&buffer[..n]);
    }
    let after = file
        .metadata()
        .map_err(|_| "The export destination changed.")?;
    let named = fs::symlink_metadata(path).map_err(|_| "The export destination changed.")?;
    if !named.is_file()
        || named.file_type().is_symlink()
        || info.len() != after.len()
        || info.modified().ok() != after.modified().ok()
        || after.len() != named.len()
        || after.modified().ok() != named.modified().ok()
    {
        return Err("The export destination changed.");
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if info.ino() != after.ino()
            || info.dev() != after.dev()
            || after.ino() != named.ino()
            || after.dev() != named.dev()
        {
            return Err("The export destination changed.");
        }
    }
    let modified = info
        .modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|v| v.as_nanos().to_string());
    Ok(backend::ExportDestination {
        exists: true,
        identity: Some(identity(&file)?),
        parent_identity,
        size: info.len(),
        sha256: format!("{:x}", hash.finalize()),
        modified_nanoseconds: modified,
    })
}
#[cfg(test)]
mod tests;

/// Transient terminal recovery remains attached to its original tab, outside safe DTOs.
#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum Publication {
    Published,
    NotPublished,
    Unknown,
}
#[allow(dead_code)] // Task 22 composes these exact recovery identities in the close graph.
pub(super) struct Recovery {
    pub(super) client: Option<backend::BackendClient>,
    pub(super) operation: u64,
    pub(super) query: Option<String>,
    pub(super) session: Option<String>,
    pub(super) session_generation: u64,
    pub(super) sql_completed: bool,
    pub(super) outcome_unknown: bool,
    pub(super) publication: Publication,
    pub(super) export: backend::ExportRequest,
}

#[cfg(not(windows))]
fn same_path(a: &Path, b: &Path) -> bool {
    a == b
}
#[cfg(windows)]
fn same_path(a: &Path, b: &Path) -> bool {
    fn clean(p: &Path) -> String {
        let value = p.to_string_lossy().replace('/', "\\");
        if value
            .get(..8)
            .is_some_and(|prefix| prefix.eq_ignore_ascii_case("\\\\?\\UNC\\"))
        {
            format!("\\\\{}", &value[8..])
        } else {
            value.strip_prefix("\\\\?\\").unwrap_or(&value).to_owned()
        }
    }
    clean(a).eq_ignore_ascii_case(&clean(b))
}
#[cfg(test)]
mod database_tests;

#[cfg(unix)]
fn identity(file: &fs::File) -> Result<String, &'static str> {
    use std::os::unix::fs::MetadataExt;
    let m = file
        .metadata()
        .map_err(|_| "The export destination changed.")?;
    Ok(format!("{}:{}", m.dev(), m.ino()))
}
#[cfg(windows)]
fn identity(file: &fs::File) -> Result<String, &'static str> {
    let (v, i) =
        crate::files::windows_file_identity(file).map_err(|_| "The export destination changed.")?;
    Ok(format!("{v}:{i}"))
}
