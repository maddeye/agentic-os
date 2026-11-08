//! Global toolchains. Only pinned catalog entries can be installed.
//!
//! An install stages, verifies its digest, normalizes ownership, and runs its
//! check without privilege before one rename makes it visible.

use crate::exec::{require, run, tool};
use crate::protocol::{Action, ActionKind, Impact, Operation, Refusal};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

const ROOT: &str = "/opt/agent-os/toolchains";
const CATALOG: &str = "/usr/share/agent-os/toolchains.json";
const PROJECT_REGISTRY: &str = "/var/lib/agent-os/metadata/projects";

#[derive(Deserialize, Debug)]
#[serde(deny_unknown_fields)]
struct Catalog {
    toolchains: Vec<Entry>,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
#[serde(deny_unknown_fields)]
struct Entry {
    name: String,
    version: String,
    url: String,
    sha256: String,
    strip_components: u32,
    check_argv: Vec<String>,
    check_stdout: String,
}

fn fields(operation: &Operation) -> (&str, &str) {
    match operation {
        Operation::ToolchainInstallGlobal { name, version } | Operation::ToolchainRemoveGlobal { name, version } => (name, version),
        _ => unreachable!("toolchains receive only toolchain operations"),
    }
}

fn published(name: &str, version: &str) -> PathBuf {
    Path::new(ROOT).join(name).join(version)
}

fn staging(id: u64) -> PathBuf {
    Path::new(ROOT).join(".staging").join(format!("change-{id}"))
}

fn lookup(name: &str, version: &str) -> Result<Entry, Refusal> {
    let text = fs::read_to_string(CATALOG).map_err(|error| Refusal::new("catalog", format!("{CATALOG}: {error}")))?;
    let catalog: Catalog = serde_json::from_str(&text).map_err(|error| Refusal::new("catalog", format!("{CATALOG}: {error}")))?;
    catalog
        .toolchains
        .into_iter()
        .find(|entry| entry.name == name && entry.version == version)
        .ok_or_else(|| Refusal::new("unknown_toolchain", format!("{name} {version} is not in the catalog")))
}

pub fn list() -> Vec<(String, String)> {
    let names = |dir: &Path| -> Vec<String> {
        fs::read_dir(dir)
            .map(|entries| {
                entries
                    .flatten()
                    .filter(|entry| entry.path().is_dir())
                    .map(|entry| entry.file_name().to_string_lossy().into_owned())
                    .filter(|name| !name.starts_with('.'))
                    .collect()
            })
            .unwrap_or_default()
    };
    let mut found = Vec::new();
    for name in names(Path::new(ROOT)) {
        for version in names(&Path::new(ROOT).join(&name)) {
            found.push((name.clone(), version));
        }
    }
    found.sort();
    found
}

/// The projects whose registry entry selects this toolchain.
fn used_by(name: &str, version: &str) -> Vec<String> {
    let wanted = format!("toolchain.{name}={version}");
    let mut projects: Vec<String> = fs::read_dir(PROJECT_REGISTRY)
        .map(|entries| {
            entries
                .flatten()
                .filter(|entry| !entry.file_name().to_string_lossy().contains('.'))
                .filter(|entry| fs::read_to_string(entry.path()).is_ok_and(|text| text.lines().any(|line| line == wanted)))
                .map(|entry| entry.file_name().to_string_lossy().into_owned())
                .collect()
        })
        .unwrap_or_default();
    projects.sort();
    projects
}

pub fn actions(operation: &Operation) -> Result<Vec<Action>, Refusal> {
    let (name, version) = fields(operation);
    let exists = published(name, version).exists();
    let target = name.to_string();
    let version = version.to_string();
    match operation {
        Operation::ToolchainInstallGlobal { .. } => {
            lookup(&target, &version)?;
            if exists {
                return Err(Refusal::new("already_installed", format!("{target} {version} is already installed")));
            }
            Ok(vec![Action { kind: ActionKind::Install, target, from: None, to: Some(version) }])
        }
        _ => {
            if !exists {
                return Err(Refusal::new("not_installed", format!("{target} {version} is not installed")));
            }
            Ok(vec![Action { kind: ActionKind::Remove, target, from: Some(version), to: None }])
        }
    }
}

pub fn plan(operation: &Operation) -> Result<Impact, Refusal> {
    let (name, version) = fields(operation);
    let used = if matches!(operation, Operation::ToolchainRemoveGlobal { .. }) { used_by(name, version) } else { Vec::new() };
    Ok(Impact { actions: actions(operation)?, toolchain_source: source(operation)?, used_by_projects: used, ..Impact::default() })
}

/// The whole catalog entry, so that approval covers its URL, digest, and check.
fn source(operation: &Operation) -> Result<Option<serde_json::Value>, Refusal> {
    let (name, version) = fields(operation);
    match operation {
        Operation::ToolchainInstallGlobal { .. } => Ok(Some(serde_json::to_value(lookup(name, version)?)?)),
        _ => Ok(None),
    }
}

pub fn still_matches(operation: &Operation, impact: &Impact) -> Result<bool, Refusal> {
    Ok(actions(operation)? == impact.actions && source(operation)? == impact.toolchain_source)
}

/// Runs the catalog check as `nobody`, so a bad archive cannot use root here.
fn check(entry: &Entry, dir: &Path) -> Result<(), String> {
    let (program, args) = entry.check_argv.split_first().ok_or("catalog entry has no check")?;
    let mut command = tool("timeout");
    command
        .args(["60", "setpriv", "--reuid=65534", "--regid=65534", "--clear-groups", "--no-new-privs", "--"])
        .arg(dir.join(program))
        .args(args);
    let ran = run(&mut command).map_err(|error| error.to_string())?;
    if ran.success && ran.stdout.trim() == entry.check_stdout {
        Ok(())
    } else {
        Err(format!("check returned [{}]: {}", ran.stdout.trim(), ran.stderr.trim()))
    }
}

fn step(command: &mut Command, what: &str) -> Result<(), String> {
    require(command, "apply_failed", what).map(|_| ()).map_err(|refusal| refusal.message)
}

fn sync_dir(path: &Path) -> Result<(), String> {
    fs::File::open(path).and_then(|dir| dir.sync_all()).map_err(|error| error.to_string())
}

fn install(id: u64, entry: &Entry) -> Result<(), String> {
    let stage = staging(id);
    let tree = stage.join("tree");
    let archive = stage.join("archive");
    fs::create_dir_all(&tree).map_err(|error| error.to_string())?;
    step(
        tool("curl").args(["--proto", "=https", "-fsSL", "--retry", "3", "--max-time", "1800", "-o"]).arg(&archive).arg(&entry.url),
        "download",
    )?;
    let sum = run(tool("sha256sum").arg(&archive)).map_err(|error| error.to_string())?;
    if sum.stdout.split_whitespace().next() != Some(entry.sha256.as_str()) {
        return Err(format!("sha256 mismatch for {}", entry.url));
    }
    step(
        tool("tar")
            .args(["--no-same-owner", "--no-same-permissions", "-xf"])
            .arg(&archive)
            .arg("-C")
            .arg(&tree)
            .arg(format!("--strip-components={}", entry.strip_components)),
        "extract",
    )?;
    fs::remove_file(&archive).map_err(|error| error.to_string())?;
    step(tool("chown").args(["-hR", "root:root"]).arg(&tree), "chown")?;
    step(tool("chmod").args(["-R", "u+rwX,go+rX,go-w,ug-s,-t"]).arg(&tree), "chmod")?;
    check(entry, &tree).map_err(|error| format!("staged check failed: {error}"))?;
    // The contents must reach the disk first. A rename can survive power loss
    // while unsynced files in the tree do not.
    step(tool("sync").arg("--file-system").arg(&tree), "sync")?;

    let target = published(&entry.name, &entry.version);
    let parent = target.parent().expect("published paths have a parent");
    fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    fs::rename(&tree, &target).map_err(|error| error.to_string())?;
    sync_dir(parent)?;
    sync_dir(&stage)?;
    clean_staging(id);
    Ok(())
}

fn remove(id: u64, name: &str, version: &str) -> Result<(), String> {
    let stage = staging(id);
    fs::create_dir_all(&stage).map_err(|error| error.to_string())?;
    let target = published(name, version);
    // The rename is the moment the toolchain stops existing for projects.
    fs::rename(&target, stage.join("tree")).map_err(|error| error.to_string())?;
    sync_dir(target.parent().expect("published paths have a parent"))?;
    clean_staging(id);
    Ok(())
}

pub fn apply(id: u64, operation: &Operation) -> Result<(), String> {
    let (name, version) = fields(operation);
    let result = match operation {
        Operation::ToolchainInstallGlobal { .. } => {
            lookup(name, version).map_err(|refusal| refusal.message).and_then(|entry| install(id, &entry))
        }
        _ => remove(id, name, version),
    };
    if result.is_err() {
        clean_staging(id);
    }
    result
}

pub fn verify(operation: &Operation) -> (bool, String) {
    let (name, version) = fields(operation);
    let target = published(name, version);
    match operation {
        Operation::ToolchainInstallGlobal { .. } => match lookup(name, version) {
            Err(refusal) => (false, refusal.message),
            Ok(_) if !target.exists() => (false, format!("{name} {version} is not published")),
            Ok(entry) => match check(&entry, &target) {
                Ok(()) => (true, "published toolchain passed its check".to_string()),
                Err(error) => (false, error),
            },
        },
        _ if target.exists() => (false, format!("{name} {version} is still published")),
        _ => (true, "toolchain is no longer published".to_string()),
    }
}

pub fn clean_staging(id: u64) {
    let _ = fs::remove_dir_all(staging(id));
}
