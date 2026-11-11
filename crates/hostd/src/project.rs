//! Projects that the system agent asks for. Each one runs a service that the
//! administrator configured under /etc/agent-os/services.
//!
//! hostd cannot see project data, so every step runs `agentos` in a transient unit
//! of its own. The arguments are a fixed vector of validated names.

use crate::exec::{require, tool};
use crate::protocol::{Action, ActionKind, Impact, Operation, Refusal};
use std::fs;
use std::path::Path;

const REGISTRY: &str = "/var/lib/agent-os/metadata/projects";
const SERVICES: &str = "/etc/agent-os/services";
const AGENTOS: &str = "/usr/sbin/agentos";
/// A credential is a short token. The cap keeps a project from sending a large reply.
const CREDENTIAL_BYTES: usize = 4096;

/// The same pattern that `agentos` enforces.
pub fn valid_project_name(name: &str) -> bool {
    let bytes = name.as_bytes();
    (1..=28).contains(&bytes.len())
        && bytes[0].is_ascii_lowercase()
        && bytes[bytes.len() - 1] != b'-'
        && bytes.iter().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || *b == b'-')
}

pub fn valid_service_name(name: &str) -> bool {
    let bytes = name.as_bytes();
    (1..=32).contains(&bytes.len())
        && bytes[0].is_ascii_lowercase()
        && bytes.iter().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || *b == b'-')
}

fn fields(operation: &Operation) -> (&str, &str) {
    match operation {
        Operation::ProjectCreate { name, service } => (name, service),
        _ => unreachable!("projects receive only project operations"),
    }
}

fn service_configured(service: &str) -> bool {
    Path::new(SERVICES).join(service).join("start").is_file()
}

/// The registry entry of a usable project, or None.
fn registry_entry(name: &str) -> Option<String> {
    fs::read_to_string(Path::new(REGISTRY).join(name)).ok()
}

fn entry_field<'a>(entry: &'a str, key: &str) -> Option<&'a str> {
    entry.lines().find_map(|line| line.strip_prefix(key)?.strip_prefix('='))
}

/// Every name the registry holds, in any state, so a pending delete still counts.
fn registered() -> Vec<String> {
    let mut names: Vec<String> = fs::read_dir(REGISTRY)
        .map(|entries| {
            entries
                .flatten()
                .map(|entry| entry.file_name().to_string_lossy().into_owned())
                .filter(|name| !name.ends_with(".tmp"))
                .map(|name| name.split('.').next().unwrap_or_default().to_string())
                .collect()
        })
        .unwrap_or_default();
    names.sort();
    names.dedup();
    names
}

pub fn project_count() -> usize {
    registered().len()
}

pub fn actions(operation: &Operation) -> Result<Vec<Action>, Refusal> {
    let (name, service) = fields(operation);
    if !service_configured(service) {
        return Err(Refusal::new("unknown_service", format!("service {service} is not configured in {SERVICES}")));
    }
    if registered().iter().any(|existing| existing == name) {
        return Err(Refusal::new("already_exists", format!("project {name} already exists")));
    }
    Ok(vec![Action { kind: ActionKind::Install, target: format!("project {name}"), from: None, to: Some(service.to_string()) }])
}

pub fn plan(operation: &Operation) -> Result<Impact, Refusal> {
    Ok(Impact { actions: actions(operation)?, ..Impact::default() })
}

pub fn still_matches(operation: &Operation, impact: &Impact) -> Result<bool, Refusal> {
    Ok(actions(operation)? == impact.actions)
}

/// Runs `agentos ARGS` outside hostd's mount namespace, which hides project data.
fn agentos(args: &[&str], what: &str) -> Result<String, Refusal> {
    let mut command = tool("systemd-run");
    command.args(["--quiet", "--collect", "--wait", "--pipe", "--service-type=exec", "--", AGENTOS]).args(args);
    require(&mut command, "apply_failed", what).map(|ran| ran.stdout)
}

/// A create that was interrupted resumes, and one that finished is not repeated.
pub fn apply(operation: &Operation) -> Result<(), String> {
    let (name, service) = fields(operation);
    let created = registry_entry(name).is_some_and(|entry| entry_field(&entry, "service") == Some(service));
    if !created {
        agentos(&["project", "create", name, "--service", service], "create").map_err(|refusal| refusal.message)?;
    }
    agentos(&["project", "service", name, "start"], "service start").map(|_| ()).map_err(|refusal| refusal.message)
}

fn service_active(name: &str) -> bool {
    let Some(uid) = registry_entry(name).and_then(|entry| entry_field(&entry, "uid").map(str::to_string)) else {
        return false;
    };
    tool("systemctl").args(["is-active", "--quiet", &format!("aos-svc-{uid}.service")]).status().is_ok_and(|status| status.success())
}

pub fn verify(operation: &Operation) -> (bool, String) {
    let (name, service) = fields(operation);
    match registry_entry(name) {
        None => (false, format!("project {name} does not exist")),
        Some(entry) if entry_field(&entry, "service") != Some(service) => (false, format!("project {name} does not run {service}")),
        Some(_) if !service_active(name) => (false, format!("service {service} is not running in {name}")),
        Some(_) => (true, format!("project {name} runs {service}")),
    }
}

/// Only projects that hostd created with a service accept these requests.
fn service_project(name: &str) -> Result<(String, String), Refusal> {
    if !valid_project_name(name) {
        return Err(Refusal::new("invalid", "invalid project name"));
    }
    let entry = registry_entry(name).ok_or_else(|| Refusal::new("unknown_project", format!("no such project: {name}")))?;
    let service = entry_field(&entry, "service").ok_or_else(|| Refusal::new("no_service", format!("project {name} has no service")))?;
    let uid = entry_field(&entry, "uid").unwrap_or_default();
    Ok((service.to_string(), uid.to_string()))
}

fn address(uid: &str) -> Result<String, Refusal> {
    let ran = require(tool("/usr/sbin/agentos-netns").args(["address", uid]), "internal", "address")?;
    Ok(ran.stdout.trim().to_string())
}

pub fn service_start(name: &str) -> Result<serde_json::Value, Refusal> {
    let (service, uid) = service_project(name)?;
    let state = agentos(&["project", "service", name, "start"], "service start")?;
    Ok(serde_json::json!({ "project": name, "service": service, "address": address(&uid)?, "state": state.trim() }))
}

/// The credential comes from the project, so it is passed on as text and never parsed here.
pub fn service_credential(name: &str) -> Result<serde_json::Value, Refusal> {
    let (service, uid) = service_project(name)?;
    let output = agentos(&["project", "service", name, "credential"], "credential")?;
    if output.len() > CREDENTIAL_BYTES || output.chars().any(|c| c.is_control() && c != '\n') {
        return Err(Refusal::new("bad_credential", "the service printed more than a credential"));
    }
    Ok(serde_json::json!({ "project": name, "service": service, "address": address(&uid)?, "credential": output.trim() }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_match_the_cli_patterns() {
        for good in ["a", "hub", "my-app", "a1", "abcdefghijklmnopqrstuvwxyz12"] {
            assert!(valid_project_name(good), "{good}");
        }
        for bad in ["", "-a", "a-", "A", "1a", "a_b", "a.b", "../x", "abcdefghijklmnopqrstuvwxyz123", "a b"] {
            assert!(!valid_project_name(bad), "{bad}");
        }
        for bad in ["", "T3", "../x", "a/b", ".hidden", "1a"] {
            assert!(!valid_service_name(bad), "{bad}");
        }
        assert!(valid_service_name("t3code"));
    }

    #[test]
    fn registry_fields_need_the_exact_key() {
        let entry = "name=x\nuid=20001\nservice=t3code\nservice_extra=y\n";
        assert_eq!(entry_field(entry, "service"), Some("t3code"));
        assert_eq!(entry_field(entry, "uid"), Some("20001"));
        assert_eq!(entry_field(entry, "servic"), None);
    }
}
