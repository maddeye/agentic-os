//! Plans and applies Debian package changes through apt.

use crate::exec::{require, run, tool, Ran};
use crate::protocol::{Action, ActionKind, Artifact, Impact, Operation, Refusal};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

const ARCHIVES: &str = "/var/cache/apt/archives";
const ARTIFACTS: &str = "/var/lib/agent-os/metadata/hostd/artifacts";
/// Files that run with privilege or start on their own once installed.
const AUTOSTART_DIRS: [&str; 7] = [
    "/systemd/system/",
    "/systemd/user/",
    "/systemd/system-generators/",
    "/systemd/user-generators/",
    "/systemd/system-shutdown/",
    "/systemd/system-sleep/",
    "/etc/init.d/",
];

fn apt_get() -> Command {
    let mut command = tool("apt-get");
    command.args([
        "-q",
        "-o", "DPkg::Lock::Timeout=120",
        "-o", "Dpkg::Options::=--force-confdef",
        "-o", "Dpkg::Options::=--force-confold",
    ]);
    command
}

/// Installing never removes a package. A removal must be requested as one.
const INSTALL_FLAGS: [&str; 2] = ["--no-install-recommends", "--no-remove"];

/// With `files`, apt installs those exact archives instead of resolving names.
fn with_operation<'a>(command: &'a mut Command, operation: &Operation, files: &[PathBuf]) -> &'a mut Command {
    match operation {
        Operation::PackageInstall { .. } if !files.is_empty() => command.args(INSTALL_FLAGS).arg("install").args(files),
        Operation::PackageInstall { names } => command.args(INSTALL_FLAGS).arg("install").args(names),
        Operation::PackageRemove { names } => command.arg("remove").args(names),
        _ => unreachable!("apt receives only package operations"),
    }
}

fn artifact_dir(id: u64) -> PathBuf {
    Path::new(ARTIFACTS).join(id.to_string())
}

fn artifact_paths(id: u64, impact: &Impact) -> Vec<PathBuf> {
    impact.artifacts.iter().map(|artifact| artifact_dir(id).join(&artifact.file)).collect()
}

pub fn discard_artifacts(id: u64) {
    let _ = fs::remove_dir_all(artifact_dir(id));
}

fn sha256(path: &Path) -> Result<String, Refusal> {
    let ran = require(tool("sha256sum").arg(path), "plan_failed", "package hash")?;
    Ok(ran.stdout.split_whitespace().next().unwrap_or_default().to_string())
}

/// The cache file names for an action. A bare target is native or `all`, and
/// any other architecture appears in the target, so a foreign file cannot match.
pub fn archive_candidates(action: &Action, native: &str) -> Vec<String> {
    let (name, architecture) = match action.target.split_once(':') {
        Some((name, architecture)) => (name, Some(architecture)),
        None => (action.target.as_str(), None),
    };
    let version = action.to.as_deref().unwrap_or_default().replace(':', "%3a");
    match architecture {
        Some(architecture) => vec![format!("{name}_{version}_{architecture}.deb")],
        None => vec![format!("{name}_{version}_{native}.deb"), format!("{name}_{version}_all.deb")],
    }
}

fn control_field(control: &str, field: &str) -> String {
    let prefix = format!("{field}: ");
    control.lines().find_map(|line| line.strip_prefix(&prefix)).unwrap_or_default().to_string()
}

/// Copies an action's archive out of the shared cache, so that what the plan
/// scans and hashes is the file that apply installs.
fn keep_artifact(id: u64, action: &Action, native: &str) -> Result<Artifact, Refusal> {
    let file = archive_candidates(action, native)
        .into_iter()
        .find(|file| Path::new(ARCHIVES).join(file).is_file())
        .ok_or_else(|| Refusal::new("plan_failed", format!("no downloaded archive for {}", action.target)))?;
    let kept = artifact_dir(id).join(&file);
    fs::copy(Path::new(ARCHIVES).join(&file), &kept)?;
    let control = require(tool("dpkg-deb").arg("-f").arg(&kept), "plan_failed", "package control data")?.stdout;
    let (name, version) = (control_field(&control, "Package"), control_field(&control, "Version"));
    if action.target.split(':').next() != Some(name.as_str()) || action.to.as_deref() != Some(version.as_str()) {
        return Err(Refusal::new("plan_failed", format!("{file} does not contain {}", action.target)));
    }
    Ok(Artifact { name, version, architecture: control_field(&control, "Architecture"), file, sha256: sha256(&kept)? })
}

fn parse_line(line: &str) -> Option<Action> {
    let mut words = line.split_whitespace();
    let verb = words.next()?;
    let target = words.next()?.to_string();
    let rest: Vec<&str> = words.collect();
    let from = rest.first().and_then(|word| word.strip_prefix('[')).map(|word| word.trim_end_matches(']').to_string());
    match verb {
        "Inst" => {
            let to = rest.iter().find_map(|word| word.strip_prefix('('))?.to_string();
            let kind = if from.is_some() { ActionKind::Upgrade } else { ActionKind::Install };
            Some(Action { kind, target, from, to: Some(to) })
        }
        "Remv" => Some(Action { kind: ActionKind::Remove, target, from, to: None }),
        _ => None,
    }
}

pub fn parse_simulation(text: &str) -> Vec<Action> {
    let mut actions: Vec<Action> = text.lines().filter_map(parse_line).collect();
    actions.sort_by(|a, b| a.target.cmp(&b.target));
    actions
}

/// Returns (systemd units, setuid files) from a `dpkg-deb --contents` listing.
pub fn scan_listing(listing: &str) -> (Vec<String>, Vec<String>) {
    let (mut units, mut setuid) = (Vec::new(), Vec::new());
    for line in listing.lines() {
        let fields: Vec<&str> = line.split_whitespace().collect();
        let (Some(mode), Some(path)) = (fields.first(), fields.get(5)) else { continue };
        let path = path.trim_start_matches('.');
        if matches!(mode.as_bytes().get(3), Some(b's' | b'S')) || matches!(mode.as_bytes().get(6), Some(b's' | b'S')) {
            setuid.push(path.to_string());
        }
        if !mode.starts_with('d') && AUTOSTART_DIRS.iter().any(|dir| path.contains(dir)) {
            units.push(path.to_string());
        }
    }
    (units, setuid)
}

fn package_status(name: &str) -> String {
    let mut command = tool("dpkg-query");
    command.args(["-W", "-f=${db:Status-Abbrev}", name]);
    run(&mut command).map(|ran| ran.stdout).unwrap_or_default()
}

fn is_installed(name: &str) -> bool {
    package_status(name) == "ii "
}

fn installed_version(name: &str) -> String {
    let mut command = tool("dpkg-query");
    command.args(["-W", "-f=${Version}", name]);
    run(&mut command).map(|ran| ran.stdout).unwrap_or_default()
}

fn is_essential(name: &str) -> bool {
    let mut command = tool("dpkg-query");
    command.args(["-W", "-f=${Essential}", name]);
    run(&mut command).is_ok_and(|ran| ran.stdout == "yes")
}

pub fn dpkg_consistent() -> bool {
    let mut command = tool("dpkg");
    command.arg("--audit");
    run(&mut command).is_ok_and(|ran| ran.success && ran.stdout.trim().is_empty())
}

fn simulate(operation: &Operation, files: &[PathBuf]) -> Result<Vec<Action>, Refusal> {
    let mut command = apt_get();
    command.arg("-s");
    with_operation(&mut command, operation, files);
    Ok(parse_simulation(&require(&mut command, "plan_failed", "apt simulation")?.stdout))
}

/// apt treats an unknown name as a regex and honors `name-` and `name+` suffixes.
/// A request stands only if apt acted on exactly the names that were asked for.
fn check_names_resolved(operation: &Operation, actions: &[Action]) -> Result<(), Refusal> {
    let acted = |name: &String| {
        actions.iter().any(|action| action.target.split(':').next() == Some(name.as_str()))
    };
    let (names, satisfied): (&Vec<String>, fn(&str) -> bool) = match operation {
        Operation::PackageInstall { names } => (names, is_installed),
        Operation::PackageRemove { names } => (names, |_| false),
        _ => unreachable!("apt receives only package operations"),
    };
    match names.iter().find(|name| !acted(name) && !satisfied(name)) {
        Some(name) => Err(Refusal::new("unknown_package", format!("apt did not resolve {name} to that exact package"))),
        None => Ok(()),
    }
}

pub fn plan(id: u64, operation: &Operation) -> Result<Impact, Refusal> {
    require(apt_get().arg("update"), "plan_failed", "apt-get update")?;
    let actions = simulate(operation, &[])?;
    check_names_resolved(operation, &actions)?;
    if let Some(action) = actions.iter().find(|a| a.kind == ActionKind::Remove && is_essential(&a.target)) {
        return Err(Refusal::new("denied", format!("{} is an essential package", action.target)));
    }

    let mut impact = Impact { actions, ..Impact::default() };
    if matches!(operation, Operation::PackageInstall { .. }) {
        let mut download = apt_get();
        download.args(["-y", "-d"]);
        with_operation(&mut download, operation, &[]);
        require(&mut download, "plan_failed", "package download")?;
        fs::create_dir_all(artifact_dir(id))?;
        let native = require(tool("dpkg").arg("--print-architecture"), "plan_failed", "architecture")?.stdout;
        let packages: Vec<Action> = impact.actions.iter().filter(|a| a.kind != ActionKind::Remove).cloned().collect();
        for action in &packages {
            let artifact = keep_artifact(id, action, native.trim())?;
            let file = artifact_dir(id).join(&artifact.file);
            impact.download_bytes += fs::metadata(&file)?.len();
            // Listing a .deb reads its archive and runs none of its scripts.
            let listing = require(tool("dpkg-deb").arg("--contents").arg(&file), "plan_failed", "package listing")?;
            let (units, setuid) = scan_listing(&listing.stdout);
            impact.services.extend(units);
            impact.setuid_files.extend(setuid);
            impact.artifacts.push(artifact);
        }
    }
    Ok(impact)
}

/// True while the kept files are unchanged and apt still resolves them to the
/// approved transaction.
pub fn still_matches(id: u64, operation: &Operation, impact: &Impact) -> Result<bool, Refusal> {
    let files = artifact_paths(id, impact);
    for (artifact, file) in impact.artifacts.iter().zip(&files) {
        if sha256(file)? != artifact.sha256 {
            return Ok(false);
        }
    }
    Ok(simulate(operation, &files)? == impact.actions)
}

pub fn apply(id: u64, operation: &Operation, impact: &Impact) -> Result<(), String> {
    if impact.actions.is_empty() {
        return Ok(());
    }
    let files = artifact_paths(id, impact);
    let mut command = apt_get();
    command.arg("-y");
    // Anything apt wants beyond the kept files was not approved.
    if !files.is_empty() {
        command.arg("--no-download");
    }
    with_operation(&mut command, operation, &files);
    let ran = run(&mut command).map_err(|error| error.to_string())?;
    if !ran.success {
        return Err(ran.tail());
    }
    // apt marks every file argument as manually installed.
    if let Operation::PackageInstall { names } = operation {
        let dependencies = impact.actions.iter().filter(|a| a.kind == ActionKind::Install && !names.contains(&a.target));
        let mut mark = tool("apt-mark");
        mark.arg("auto").args(dependencies.map(|a| a.target.as_str()));
        let _ = run(&mut mark);
    }
    Ok(())
}

pub fn verify(operation: &Operation, actions: &[Action]) -> (bool, String) {
    let (names, want_installed) = match operation {
        Operation::PackageInstall { names } => (names, true),
        Operation::PackageRemove { names } => (names, false),
        _ => unreachable!("apt receives only package operations"),
    };
    if !dpkg_consistent() {
        return (false, "dpkg --audit reports unfinished packages".to_string());
    }
    if let Some(name) = names.iter().find(|name| is_installed(name) != want_installed) {
        let state = if want_installed { "is not installed" } else { "is still installed" };
        return (false, format!("{name} {state}"));
    }
    for action in actions {
        let current = if is_installed(&action.target) { Some(installed_version(&action.target)) } else { None };
        if current != action.to {
            return (false, format!("{} is at {current:?}, expected {:?}", action.target, action.to));
        }
    }
    (true, "dpkg state matches the approved transaction".to_string())
}

fn describe(label: &str, result: std::io::Result<Ran>) -> String {
    match result {
        Ok(ran) if ran.success => format!("{label}: ok. "),
        Ok(ran) => format!("{label}: {}. ", ran.tail()),
        Err(error) => format!("{label}: {error}. "),
    }
}

/// Finishes what an interrupted dpkg left behind. It removes nothing, downloads
/// nothing, and refuses to touch a package outside the approved transaction.
pub fn repair(approved: &[Action]) -> String {
    let mut configure = tool("dpkg");
    configure.args(["--force-confdef", "--force-confold", "--configure", "-a"]);
    let mut steps = describe("dpkg --configure -a", run(&mut configure));

    let mut probe = apt_get();
    probe.args(["-s", "-f", "--no-remove", "install"]);
    let wanted = run(&mut probe).map(|ran| parse_simulation(&ran.stdout)).unwrap_or_default();
    let outside = wanted.iter().find(|w| !approved.iter().any(|a| a.target == w.target && a.to == w.to));
    if let Some(action) = outside {
        steps.push_str(&format!("apt-get -f install: skipped, it would also change {}.", action.target));
    } else if !wanted.is_empty() {
        let mut fix = apt_get();
        fix.args(["-y", "-f", "--no-remove", "--no-download", "install"]);
        steps.push_str(&describe("apt-get -f install", run(&mut fix)));
    }
    steps.trim().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_simulated_transactions() {
        let text = "NOTE: This is only a simulation!\n\
            Inst ripgrep (14.1.1-1+b4 Debian:13.7/stable [amd64])\n\
            Inst libc6 [2.41-11] (2.41-12 Debian:13.7/stable [amd64]) []\n\
            Conf ripgrep (14.1.1-1+b4 Debian:13.7/stable [amd64])\n\
            Remv hello [2.10-3]\n";
        let actions = parse_simulation(text);
        assert_eq!(actions.len(), 3);
        assert_eq!(actions[0], Action { kind: ActionKind::Remove, target: "hello".into(), from: Some("2.10-3".into()), to: None });
        assert_eq!(actions[1].kind, ActionKind::Upgrade);
        assert_eq!(actions[1].from.as_deref(), Some("2.41-11"));
        assert_eq!(actions[1].to.as_deref(), Some("2.41-12"));
        assert_eq!(actions[2].kind, ActionKind::Install);
        assert_eq!(actions[2].to.as_deref(), Some("14.1.1-1+b4"));
    }

    #[test]
    fn archive_lookup_never_matches_a_foreign_architecture() {
        let action = |target: &str, to: &str| Action { kind: ActionKind::Install, target: target.into(), from: None, to: Some(to.into()) };
        assert_eq!(archive_candidates(&action("foo", "1.0"), "amd64"), ["foo_1.0_amd64.deb", "foo_1.0_all.deb"]);
        assert_eq!(archive_candidates(&action("foo:i386", "1.0"), "amd64"), ["foo_1.0_i386.deb"]);
        assert_eq!(archive_candidates(&action("foo", "2:1.0"), "amd64")[0], "foo_2%3a1.0_amd64.deb");
    }

    #[test]
    fn scan_finds_system_units_and_setuid_files() {
        let listing = "drwxr-xr-x root/root 0 2026-01-01 00:00 ./usr/\n\
            -rwsr-xr-x root/root 10 2026-01-01 00:00 ./usr/bin/helper\n\
            -rwxr-sr-x root/mail 10 2026-01-01 00:00 ./usr/bin/mailer\n\
            -rw-r--r-- root/root 10 2026-01-01 00:00 ./usr/lib/systemd/system/x.service\n\
            lrwxrwxrwx root/root 0 2026-01-01 00:00 ./lib/systemd/system/y.timer -> x\n\
            -rw-r--r-- root/root 10 2026-01-01 00:00 ./usr/lib/systemd/user/z.service\n\
            -rw-r--r-- root/root 10 2026-01-01 00:00 ./usr/lib/systemd/system/p.path\n\
            -rw-r--r-- root/root 10 2026-01-01 00:00 ./usr/lib/systemd/system/m.mount\n\
            -rwxr-xr-x root/root 10 2026-01-01 00:00 ./usr/lib/systemd/system-generators/g\n\
            -rwxr-xr-x root/root 10 2026-01-01 00:00 ./etc/init.d/legacy\n\
            drwxr-xr-x root/root 0 2026-01-01 00:00 ./usr/lib/systemd/system/\n\
            -rwxr-xr-x root/root 10 2026-01-01 00:00 ./usr/bin/plain\n";
        let (units, setuid) = scan_listing(listing);
        assert_eq!(
            units,
            [
                "/usr/lib/systemd/system/x.service",
                "/lib/systemd/system/y.timer",
                "/usr/lib/systemd/user/z.service",
                "/usr/lib/systemd/system/p.path",
                "/usr/lib/systemd/system/m.mount",
                "/usr/lib/systemd/system-generators/g",
                "/etc/init.d/legacy",
            ]
        );
        assert_eq!(setuid, ["/usr/bin/helper", "/usr/bin/mailer"]);
    }
}
