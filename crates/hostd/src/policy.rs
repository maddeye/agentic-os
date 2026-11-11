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
    /// Services whose projects the system agent may create without approval.
    /// Policies written before this field existed allow none.
    #[serde(default)]
    pub automatic_project_services: Vec<String>,
    /// Automatic creates stop once the host has this many projects.
    #[serde(default)]
    pub automatic_project_limit: usize,
}

impl Policy {
    /// A missing or malformed policy refuses the request, so it fails closed.
    pub fn load() -> Result<Policy, Refusal> {
        let text = std::fs::read_to_string(PATH)
            .map_err(|error| Refusal::new("policy", format!("{PATH}: {error}")))?;
        serde_json::from_str(&text).map_err(|error| Refusal::new("policy", format!("{PATH}: {error}")))
    }

    /// `projects` counts the host's projects. Tests pass their own.
    pub fn evaluate_with(&self, operation: &Operation, impact: &Impact, projects: impl Fn() -> usize) -> Decision {
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
            Operation::PackageUpgrade {} => {
                reasons.push("package upgrades always need approval".to_string());
                self.review_packages(impact, &mut reasons);
                reasons.extend(impact.kept_back.iter().map(|name| format!("apt kept back {name}")));
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
            Operation::ProjectCreate { service, .. } => {
                if !self.automatic_project_services.contains(service) {
                    reasons.push(format!("service {service} is not on the automatic list"));
                }
                let count = projects();
                if count >= self.automatic_project_limit {
                    reasons.push(format!("the host has {count} projects, and the automatic limit is {}", self.automatic_project_limit));
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
        reasons.extend(impact.services.iter().map(|unit| format!("ships autostart file {unit}")));
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
            automatic_project_services: vec!["t3code".into()],
            automatic_project_limit: 3,
        }
    }

    #[test]
    fn projects_are_automatic_only_for_listed_services_below_the_limit() {
        let create = |service: &str| Operation::ProjectCreate { name: "hub-a".into(), service: service.into() };
        let decide = |service: &str, count: usize| policy().evaluate_with(&create(service), &Impact::default(), || count).level;
        assert_eq!(decide("t3code", 2), Level::Automatic);
        assert_eq!(decide("t3code", 3), Level::ApprovalRequired);
        assert_eq!(decide("other", 0), Level::ApprovalRequired);
    }

    #[test]
    fn an_older_policy_allows_no_automatic_project() {
        let old = r#"{"automatic_packages":[],"automatic_toolchains":[],"protected_package_prefixes":[]}"#;
        let policy: Policy = serde_json::from_str(old).unwrap();
        let create = Operation::ProjectCreate { name: "a".into(), service: "t3code".into() };
        assert_eq!(policy.evaluate_with(&create, &Impact::default(), || 0).level, Level::ApprovalRequired);
    }

    #[test]
    fn an_upgrade_always_needs_approval_and_names_what_apt_kept_back() {
        let impact = Impact { kept_back: vec!["held".into()], ..Impact::default() };
        let decision = policy().evaluate_with(&Operation::PackageUpgrade {}, &impact, || 0);
        assert_eq!(decision.level, Level::ApprovalRequired);
        assert_eq!(decision.reasons, ["package upgrades always need approval", "apt kept back held"]);
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
        assert_eq!(policy().evaluate_with(&install("ripgrep"), &impact, || 0).level, Level::Automatic);
        assert_eq!(policy().evaluate_with(&install("hello"), &impact, || 0).level, Level::ApprovalRequired);
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
            assert_eq!(policy().evaluate_with(&install("ripgrep"), &impact, || 0).level, Level::ApprovalRequired, "{impact:?}");
        }
    }

    #[test]
    fn removals_always_need_a_human() {
        let remove = Operation::PackageRemove { names: vec!["ripgrep".into()] };
        assert_eq!(policy().evaluate_with(&remove, &Impact::default(), || 0).level, Level::ApprovalRequired);
        let remove = Operation::ToolchainRemoveGlobal { name: "node".into(), version: "26.13.0".into() };
        assert_eq!(policy().evaluate_with(&remove, &Impact::default(), || 0).level, Level::ApprovalRequired);
    }

    #[test]
    fn toolchains_follow_the_exact_version_on_the_list() {
        let op = |version: &str| Operation::ToolchainInstallGlobal { name: "node".into(), version: version.into() };
        assert_eq!(policy().evaluate_with(&op("26.13.0"), &Impact::default(), || 0).level, Level::Automatic);
        assert_eq!(policy().evaluate_with(&op("24.22.2"), &Impact::default(), || 0).level, Level::ApprovalRequired);
    }
}
