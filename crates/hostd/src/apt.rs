//! Plans and applies Debian package changes through apt.

use crate::exec::{require, run, tool};
use crate::protocol::{Action, ActionKind, Impact, Operation, Refusal};
use std::fs;
use std::path::PathBuf;
use std::process::Command;

const ARCHIVES: &str = "/var/cache/apt/archives";

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

fn with_operation<'a>(command: &'a mut Command, operation: &Operation) -> &'a mut Command {
    match operation {
        Operation::PackageInstall { names } => command.args(INSTALL_FLAGS).arg("install").args(names),
        Operation::PackageRemove { names } => command.arg("remove").args(names),
        _ => unreachable!("apt receives only package operations"),
    }
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
        if path.contains("/systemd/system/") && [".service", ".socket", ".timer"].iter().any(|s| path.ends_with(s)) {
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

pub fn simulate(operation: &Operation) -> Result<Vec<Action>, Refusal> {
    let mut command = apt_get();
    command.arg("-s");
    with_operation(&mut command, operation);
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

fn downloaded_file(action: &Action) -> Result<PathBuf, Refusal> {
    let name = action.target.split(':').next().unwrap_or(&action.target);
    let version = action.to.as_deref().unwrap_or_default().replace(':', "%3a");
    let prefix = format!("{name}_{version}_");
    for entry in fs::read_dir(ARCHIVES)? {
        let path = entry?.path();
        let file = path.file_name().map(|f| f.to_string_lossy().into_owned()).unwrap_or_default();
        if file.starts_with(&prefix) && file.ends_with(".deb") {
            return Ok(path);
        }
    }
    Err(Refusal::new("plan_failed", format!("no downloaded archive for {name}")))
}

pub fn plan(operation: &Operation) -> Result<Impact, Refusal> {
    require(apt_get().arg("update"), "plan_failed", "apt-get update")?;
    let actions = simulate(operation)?;
    check_names_resolved(operation, &actions)?;
    if let Some(action) = actions.iter().find(|a| a.kind == ActionKind::Remove && is_essential(&a.target)) {
        return Err(Refusal::new("denied", format!("{} is an essential package", action.target)));
    }

    let mut impact = Impact { actions, ..Impact::default() };
    if matches!(operation, Operation::PackageInstall { .. }) {
        let mut download = apt_get();
        download.args(["-y", "-d"]);
        with_operation(&mut download, operation);
        require(&mut download, "plan_failed", "package download")?;
        // Listing a .deb reads its archive and runs none of its scripts.
        for action in impact.actions.iter().filter(|a| a.kind != ActionKind::Remove) {
            let file = downloaded_file(action)?;
            impact.download_bytes += fs::metadata(&file)?.len();
            let listing = require(tool("dpkg-deb").arg("--contents").arg(&file), "plan_failed", "package listing")?;
            let (units, setuid) = scan_listing(&listing.stdout);
            impact.services.extend(units);
            impact.setuid_files.extend(setuid);
        }
    }
    Ok(impact)
}

pub fn apply(operation: &Operation) -> Result<(), String> {
    let mut command = apt_get();
    command.arg("-y");
    with_operation(&mut command, operation);
    let ran = run(&mut command).map_err(|error| error.to_string())?;
    if ran.success {
        Ok(())
    } else {
        Err(ran.tail())
    }
}

pub fn verify(operation: &Operation) -> (bool, String) {
    let (names, want_installed) = match operation {
        Operation::PackageInstall { names } => (names, true),
        Operation::PackageRemove { names } => (names, false),
        _ => unreachable!("apt receives only package operations"),
    };
    if !dpkg_consistent() {
        return (false, "dpkg --audit reports unfinished packages".to_string());
    }
    match names.iter().find(|name| is_installed(name) != want_installed) {
        Some(name) if want_installed => (false, format!("{name} is not installed")),
        Some(name) => (false, format!("{name} is still installed")),
        None => (true, "dpkg state matches the request".to_string()),
    }
}

/// Finishes what an interrupted dpkg left behind. Removes nothing.
pub fn repair() -> String {
    let mut steps = String::new();
    let mut configure = tool("dpkg");
    configure.args(["--force-confdef", "--force-confold", "--configure", "-a"]);
    let mut fix = apt_get();
    fix.args(["-y", "-f", "--no-remove", "install"]);
    for (label, command) in [("dpkg --configure -a", &mut configure), ("apt-get -f install", &mut fix)] {
        match run(command) {
            Ok(ran) if ran.success => steps.push_str(&format!("{label}: ok. ")),
            Ok(ran) => steps.push_str(&format!("{label}: {}. ", ran.tail())),
            Err(error) => steps.push_str(&format!("{label}: {error}. ")),
        }
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
    fn scan_finds_system_units_and_setuid_files() {
        let listing = "drwxr-xr-x root/root 0 2026-01-01 00:00 ./usr/\n\
            -rwsr-xr-x root/root 10 2026-01-01 00:00 ./usr/bin/helper\n\
            -rwxr-sr-x root/mail 10 2026-01-01 00:00 ./usr/bin/mailer\n\
            -rw-r--r-- root/root 10 2026-01-01 00:00 ./usr/lib/systemd/system/x.service\n\
            lrwxrwxrwx root/root 0 2026-01-01 00:00 ./lib/systemd/system/y.timer -> x\n\
            -rw-r--r-- root/root 10 2026-01-01 00:00 ./usr/lib/systemd/user/z.service\n\
            -rwxr-xr-x root/root 10 2026-01-01 00:00 ./usr/bin/plain\n";
        let (units, setuid) = scan_listing(listing);
        assert_eq!(units, ["/usr/lib/systemd/system/x.service", "/lib/systemd/system/y.timer"]);
        assert_eq!(setuid, ["/usr/bin/helper", "/usr/bin/mailer"]);
    }
}
