// SPDX-License-Identifier: GPL-2.0-or-later

#![allow(dead_code)]

use std::fs;
use std::io::Write;
use std::path::{Component, Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use chrono::Local;
use serde::{Deserialize, Serialize};

use crate::ffi::dirs_home;

pub const AUTOSAVES_DIR_NAME: &str = ".autosaves";
pub const DEFAULT_AUTOSAVE_INTERVAL_SECS: u32 = 120;
pub const DEFAULT_MAX_AUTOSAVES: u32 = 5;

/// Atomic write: writes to a hidden sibling temporary file, syncs, then renames over `target`.
pub fn write_file_atomic(target: &Path, bytes: &[u8]) -> Result<(), String> {
    let parent = target
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    fs::create_dir_all(parent).map_err(|e| format!("Failed to create directory: {e}"))?;

    let stem = target
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("file");
    let pid = std::process::id();
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let tmp_path = parent.join(format!(".{stem}.franca-tmp-{pid}-{nanos}"));

    let write_res = (|| -> std::io::Result<()> {
        let mut f = fs::File::create(&tmp_path)?;
        f.write_all(bytes)?;
        f.sync_all()?;
        Ok(())
    })();

    if let Err(e) = write_res {
        let _ = fs::remove_file(&tmp_path);
        return Err(format!("Failed to write temporary file: {e}"));
    }

    if let Err(e) = fs::rename(&tmp_path, target) {
        let _ = fs::remove_file(&tmp_path);
        return Err(format!("Failed to replace target file: {e}"));
    }
    Ok(())
}

pub fn data_home() -> PathBuf {
    std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| dirs_home().join(".local").join("share"))
}

pub fn franca_autosave_root() -> PathBuf {
    data_home().join("franca").join("autosaves")
}

pub fn session_manifest_path() -> PathBuf {
    franca_autosave_root().join("session.json")
}

/// Returns true if `path` already lives inside a `.autosaves` directory (prevents recursive nesting).
pub fn is_inside_autosave_dir(path: &Path) -> bool {
    path.components().any(|c| match c {
        Component::Normal(s) => s == AUTOSAVES_DIR_NAME,
        _ => false,
    })
}

/// Resolves the autosave directory for a given project file (or untitled session).
/// Saved projects store rotating backups in `<project_dir>/.autosaves/<project_stem>/`.
/// Unsaved sessions (or paths already inside `.autosaves/`) fall back to XDG data dir.
pub fn autosave_dir_for(project_path: Option<&Path>) -> PathBuf {
    if let Some(proj) = project_path {
        if !is_inside_autosave_dir(proj) {
            if let Some(parent) = proj.parent().filter(|p| !p.as_os_str().is_empty()) {
                let stem = proj
                    .file_stem()
                    .and_then(|s| s.to_str())
                    .filter(|s| !s.is_empty())
                    .unwrap_or("project");
                return parent.join(AUTOSAVES_DIR_NAME).join(stem);
            }
        }
    }
    franca_autosave_root().join("untitled")
}

/// Generates a timestamped autosave `.carxp` path inside `dir`.
pub fn next_autosave_path(dir: &Path) -> PathBuf {
    let stamp = Local::now().format("%Y%m%d-%H%M%S");
    dir.join(format!("autosave-{stamp}.carxp"))
}

/// Keeps only the `keep` newest `autosave-*.carxp` files in `dir`, deleting older ones.
pub fn prune_old_autosaves(dir: &Path, keep: usize) {
    let keep = keep.max(1);
    let Ok(read) = fs::read_dir(dir) else {
        return;
    };
    let mut entries: Vec<(SystemTime, PathBuf)> = read
        .flatten()
        .filter_map(|e| {
            let p = e.path();
            let name = p.file_name()?.to_str()?;
            if !name.starts_with("autosave-") || !name.ends_with(".carxp") {
                return None;
            }
            let mtime = e
                .metadata()
                .ok()
                .and_then(|m| m.modified().ok())
                .unwrap_or(UNIX_EPOCH);
            Some((mtime, p))
        })
        .collect();

    if entries.len() <= keep {
        return;
    }
    // Sort newest first, tie-breaking by filename descending (timestamp order)
    entries.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| b.1.cmp(&a.1)));
    for (_, old_path) in entries.into_iter().skip(keep) {
        let _ = fs::remove_file(old_path);
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SessionManifest {
    pub project_path: Option<String>,
    pub autosave_path: String,
    pub saved_at_unix: u64,
    pub saved_at_display: String,
    pub clean_exit: bool,
}

#[derive(Clone, Debug, Serialize)]
pub struct RecoveryInfo {
    pub project_path: String,
    pub project_display: String,
    pub autosave_path: String,
    pub saved_at_display: String,
}

impl SessionManifest {
    pub fn load_from(path: &Path) -> Option<Self> {
        let raw = fs::read_to_string(path).ok()?;
        serde_json::from_str(&raw).ok()
    }

    pub fn save_to(&self, path: &Path) -> Result<(), String> {
        let json = serde_json::to_string_pretty(self).map_err(|e| e.to_string())?;
        write_file_atomic(path, json.as_bytes())
    }
}

pub fn record_autosave_manifest(project_path: Option<&Path>, autosave_path: &Path) {
    record_autosave_manifest_at(&session_manifest_path(), project_path, autosave_path);
}

pub fn record_autosave_manifest_at(
    manifest_path: &Path,
    project_path: Option<&Path>,
    autosave_path: &Path,
) {
    let now_unix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let manifest = SessionManifest {
        project_path: project_path.map(|p| p.to_string_lossy().into_owned()),
        autosave_path: autosave_path.to_string_lossy().into_owned(),
        saved_at_unix: now_unix,
        saved_at_display: Local::now().format("%Y-%m-%d %H:%M:%S").to_string(),
        clean_exit: false,
    };
    let _ = manifest.save_to(manifest_path);
}

pub fn mark_session_clean() {
    mark_session_clean_at(&session_manifest_path());
}

pub fn mark_session_clean_at(manifest_path: &Path) {
    if let Some(mut m) = SessionManifest::load_from(manifest_path) {
        if !m.clean_exit {
            m.clean_exit = true;
            let _ = m.save_to(manifest_path);
        }
    }
}

/// Checks whether an unclean previous session left a recoverable autosave.
pub fn check_pending_recovery() -> Option<RecoveryInfo> {
    check_pending_recovery_at(&session_manifest_path())
}

pub fn check_pending_recovery_at(manifest_path: &Path) -> Option<RecoveryInfo> {
    let manifest = SessionManifest::load_from(manifest_path)?;
    if manifest.clean_exit {
        return None;
    }
    let autosave = PathBuf::from(&manifest.autosave_path);
    if !autosave.is_file() {
        return None;
    }
    let project_path = manifest.project_path.unwrap_or_default();
    let project_display = if project_path.is_empty() {
        "Untitled session".to_string()
    } else {
        Path::new(&project_path)
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or(&project_path)
            .to_string()
    };
    Some(RecoveryInfo {
        project_path,
        project_display,
        autosave_path: manifest.autosave_path,
        saved_at_display: manifest.saved_at_display,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn atomic_write_creates_and_replaces_file() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("nested/sub/project.carxp");
        write_file_atomic(&target, b"<CARLA-PROJECT>v1</CARLA-PROJECT>").unwrap();
        assert_eq!(
            fs::read_to_string(&target).unwrap(),
            "<CARLA-PROJECT>v1</CARLA-PROJECT>"
        );
        write_file_atomic(&target, b"<CARLA-PROJECT>v2</CARLA-PROJECT>").unwrap();
        assert_eq!(
            fs::read_to_string(&target).unwrap(),
            "<CARLA-PROJECT>v2</CARLA-PROJECT>"
        );
        // No leftover temporary files
        let entries: Vec<_> = fs::read_dir(target.parent().unwrap())
            .unwrap()
            .flatten()
            .collect();
        assert_eq!(entries.len(), 1);
    }

    #[test]
    fn autosave_dir_avoids_recursive_nesting() {
        let proj = Path::new("/tmp/studio/mix.carxp");
        assert_eq!(
            autosave_dir_for(Some(proj)),
            PathBuf::from("/tmp/studio/.autosaves/mix")
        );

        let nested = Path::new("/tmp/studio/.autosaves/mix/autosave-20260101-120000.carxp");
        assert!(is_inside_autosave_dir(nested));
        assert!(!is_inside_autosave_dir(&autosave_dir_for(Some(nested))));
    }

    #[test]
    fn prune_keeps_newest_autosaves() {
        let dir = tempfile::tempdir().unwrap();
        for i in 1..=6 {
            let p = dir.path().join(format!("autosave-20260101-12000{i}.carxp"));
            fs::write(&p, format!("snap {i}")).unwrap();
        }
        // Unrelated file must not be touched
        let keep_me = dir.path().join("notes.txt");
        fs::write(&keep_me, "hi").unwrap();

        prune_old_autosaves(dir.path(), 3);

        let mut remaining: Vec<String> = fs::read_dir(dir.path())
            .unwrap()
            .flatten()
            .filter_map(|e| e.file_name().into_string().ok())
            .collect();
        remaining.sort();
        assert_eq!(
            remaining,
            vec![
                "autosave-20260101-120004.carxp",
                "autosave-20260101-120005.carxp",
                "autosave-20260101-120006.carxp",
                "notes.txt",
            ]
        );
    }

    #[test]
    fn recovery_manifest_roundtrip_and_clean_exit() {
        let dir = tempfile::tempdir().unwrap();
        let manifest = dir.path().join("session.json");
        let auto = dir.path().join("autosave-20260101-120000.carxp");
        fs::write(&auto, "<CARLA-PROJECT/>").unwrap();

        record_autosave_manifest_at(&manifest, Some(Path::new("/work/live.carxp")), &auto);
        let rec = check_pending_recovery_at(&manifest).expect("expected recovery");
        assert_eq!(rec.project_path, "/work/live.carxp");
        assert_eq!(rec.project_display, "live.carxp");
        assert_eq!(rec.autosave_path, auto.to_string_lossy());

        mark_session_clean_at(&manifest);
        assert!(check_pending_recovery_at(&manifest).is_none());
    }
}
