//! Decides whether a planned change may proceed without a human.

use crate::protocol::{ActionKind, Decision, Impact, Level, Operation, Refusal};
use serde::Deserialize;

pub const PATH: &str = "/etc/agent-os/hostd-policy.json";

#[derive(Deserialize, Debug)]
#[serde(deny_unknown_fields)]
pub struct Policy {
    pub automatic_packages: Vec<String>,
    pub automatic_toolchains: Vec<String>,
    pub protected_package_prefixes: Vec<String>,
}

impl Policy {
    /// A missing or malformed policy refuses the request, so it fails closed.
    pub fn load() -> Result<Policy, Refusal> {
        let text = std::fs::read_to_string(PATH)
            .map_err(|error| Refusal::new("policy", format!("{PATH}: {error}")))?;
        serde_json::from_str(&text).map_err(|error| Refusal::new("policy", format!("{PATH}: {error}")))
    }

    pub fn evaluate(&self, operation: &Operation, impact: &Impact) -> Decision {
        let mut reasons = Vec::new();
        match operation {
            Operation::PackageInstall { names } => {
                for name in names.iter().filter(|name| !self.automatic_packages.contains(name)) {
                    reasons.push(format!("{name} is not on the automatic list"));
                }
                self.review_packages(impact, &mut reasons);
            }
            Operation::PackageRemove { .. } => {
                reasons.push("package removal always needs approval".to_string());
                self.review_packages(impact, &mut reasons);
            }
            Operation::ToolchainInstallGlobal { name, version } => {
                let key = format!("{name}/{version}");
                if !self.automatic_toolchains.contains(&key) {
                    reasons.push(format!("toolchain {key} is not on the automatic list"));
                }
            }
            Operation::ToolchainRemoveGlobal { .. } => {
                reasons.push("toolchain removal always needs approval".to_string());
                for project in &impact.used_by_projects {
                    reasons.push(format!("project {project} uses this toolchain"));
                }
            }
        }
        let level = if reasons.is_empty() { Level::Automatic } else { Level::ApprovalRequired };
        Decision { level, reasons }
    }

    /// An allowlisted name can still pull in something the list did not intend.
    fn review_packages(&self, impact: &Impact, reasons: &mut Vec<String>) {
        for action in &impact.actions {
            match action.kind {
                ActionKind::Upgrade => reasons.push(format!("changes installed package {}", action.target)),
                ActionKind::Remove => reasons.push(format!("removes package {}", action.target)),
                ActionKind::Install => {}
            }
            if self.protected_package_prefixes.iter().any(|prefix| action.target.starts_with(prefix)) {
                reasons.push(format!("{} is a protected package", action.target));
            }
        }
        reasons.extend(impact.services.iter().map(|unit| format!("ships systemd unit {unit}")));
        reasons.extend(impact.setuid_files.iter().map(|file| format!("ships setuid file {file}")));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::Action;

    fn policy() -> Policy {
        Policy {
            automatic_packages: vec!["ripgrep".into(), "linux-image-amd64".into()],
            automatic_toolchains: vec!["node/26.13.0".into()],
            protected_package_prefixes: vec!["linux-image".into()],
        }
    }

    fn action(kind: ActionKind, target: &str) -> Action {
        Action { kind, target: target.into(), from: None, to: Some("1".into()) }
    }

    fn install(name: &str) -> Operation {
        Operation::PackageInstall { names: vec![name.into()] }
    }

    fn with_action(a: Action) -> Impact {
        Impact { actions: vec![a], ..Impact::default() }
    }

    #[test]
    fn only_an_allowlisted_clean_install_is_automatic() {
        let impact = with_action(action(ActionKind::Install, "ripgrep"));
        assert_eq!(policy().evaluate(&install("ripgrep"), &impact).level, Level::Automatic);
        assert_eq!(policy().evaluate(&install("hello"), &impact).level, Level::ApprovalRequired);
    }

    #[test]
    fn allowlisted_name_cannot_carry_risk_through() {
        let cases = [
            with_action(action(ActionKind::Upgrade, "libc6")),
            with_action(action(ActionKind::Remove, "openssh-server")),
            with_action(action(ActionKind::Install, "linux-image-amd64")),
            Impact { services: vec!["/usr/lib/systemd/system/x.service".into()], ..Impact::default() },
            Impact { setuid_files: vec!["/usr/bin/x".into()], ..Impact::default() },
        ];
        for impact in cases {
            assert_eq!(policy().evaluate(&install("ripgrep"), &impact).level, Level::ApprovalRequired, "{impact:?}");
        }
    }

    #[test]
    fn removals_always_need_a_human() {
        let remove = Operation::PackageRemove { names: vec!["ripgrep".into()] };
        assert_eq!(policy().evaluate(&remove, &Impact::default()).level, Level::ApprovalRequired);
        let remove = Operation::ToolchainRemoveGlobal { name: "node".into(), version: "26.13.0".into() };
        assert_eq!(policy().evaluate(&remove, &Impact::default()).level, Level::ApprovalRequired);
    }

    #[test]
    fn toolchains_follow_the_exact_version_on_the_list() {
        let op = |version: &str| Operation::ToolchainInstallGlobal { name: "node".into(), version: version.into() };
        assert_eq!(policy().evaluate(&op("26.13.0"), &Impact::default()).level, Level::Automatic);
        assert_eq!(policy().evaluate(&op("24.22.2"), &Impact::default()).level, Level::ApprovalRequired);
    }
}
