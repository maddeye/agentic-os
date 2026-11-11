//! Authorizes requests and moves changes through their states.

use crate::protocol::{Action, Change, Level, Operation, Outcome, Refusal, Request, State, validate_reason};
use crate::policy::Policy;
use crate::store::{now, Store};
use crate::{apt, project, toolchain};
use serde_json::{json, Value};
use std::ffi::{CStr, CString};

pub const SYSTEM_AGENT: &str = "agentos-system";

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Role {
    Administrator,
    SystemAgent,
    Unauthorized,
}

pub struct Caller {
    pub uid: u32,
    pub pid: i32,
    pub name: String,
    pub role: Role,
}

fn user_name(uid: u32) -> Option<String> {
    // SAFETY: hostd serves one request on one thread, so the static result cannot
    // be overwritten before it is copied here.
    unsafe {
        let entry = libc::getpwuid(uid);
        (!entry.is_null()).then(|| CStr::from_ptr((*entry).pw_name).to_string_lossy().into_owned())
    }
}

fn user_id(name: &str) -> Option<u32> {
    let name = CString::new(name).ok()?;
    // SAFETY: as in user_name.
    unsafe {
        let entry = libc::getpwnam(name.as_ptr());
        (!entry.is_null()).then(|| (*entry).pw_uid)
    }
}

pub fn role_of(uid: u32, system_agent: Option<u32>) -> Role {
    if uid == 0 {
        Role::Administrator
    } else if Some(uid) == system_agent {
        Role::SystemAgent
    } else {
        Role::Unauthorized
    }
}

impl Caller {
    pub fn resolve(uid: u32, pid: i32) -> Caller {
        Caller { uid, pid, name: user_name(uid).unwrap_or_else(|| uid.to_string()), role: role_of(uid, user_id(SYSTEM_AGENT)) }
    }

    fn identity(&self) -> Value {
        json!({ "uid": self.uid, "pid": self.pid, "name": self.name })
    }
}

/// Only a human administrator decides. The system agent cannot approve its own request.
pub fn authorized(role: Role, request: &Request) -> bool {
    match request {
        Request::ChangeApprove { .. } | Request::ChangeReject { .. } => role == Role::Administrator,
        _ => role != Role::Unauthorized,
    }
}

fn is_package(operation: &Operation) -> bool {
    matches!(operation, Operation::PackageInstall { .. } | Operation::PackageRemove { .. } | Operation::PackageUpgrade {})
}

fn is_project(operation: &Operation) -> bool {
    matches!(operation, Operation::ProjectCreate { .. })
}

fn still_matches(change: &Change) -> bool {
    let current = if is_package(&change.operation) {
        apt::still_matches(change.id, &change.operation, &change.impact)
    } else if is_project(&change.operation) {
        project::still_matches(&change.operation, &change.impact)
    } else {
        toolchain::still_matches(&change.operation, &change.impact)
    };
    current.unwrap_or(false)
}

fn run_change(change: &Change) -> Result<(), String> {
    if is_package(&change.operation) {
        apt::apply(change.id, &change.operation, &change.impact)
    } else if is_project(&change.operation) {
        project::apply(&change.operation)
    } else {
        toolchain::apply(change.id, &change.operation)
    }
}

fn verify(operation: &Operation, actions: &[Action]) -> (bool, String) {
    if is_package(operation) {
        apt::verify(operation, actions)
    } else if is_project(operation) {
        project::verify(operation)
    } else {
        toolchain::verify(operation)
    }
}

/// What an administrator would run to undo this change.
fn recovery_reference(operation: &Operation) -> String {
    match operation {
        Operation::PackageInstall { names } => format!("agentos system package remove {}", names.join(" ")),
        Operation::PackageRemove { names } => format!("agentos system package install {}", names.join(" ")),
        Operation::PackageUpgrade {} => "no single command undoes an upgrade. impact.actions lists each previous version.".to_string(),
        Operation::ToolchainInstallGlobal { name, version } => format!("agentos system toolchain remove {name} {version}"),
        Operation::ToolchainRemoveGlobal { name, version } => format!("agentos system toolchain install {name} {version}"),
        Operation::ProjectCreate { name, .. } => format!("agentos project delete {name} --yes"),
    }
}

#[derive(Default)]
pub struct Broker {
    store: Store,
}

impl Broker {
    fn audit(&self, caller: &Caller, event: &str, fields: Value) -> Result<(), Refusal> {
        self.store.audit(caller.identity(), event, fields)
    }

    pub fn record_malformed(&self, caller: &Caller, refusal: &Refusal) {
        // The body is left out because it can hold anything a caller sent.
        let _ = self.audit(caller, "malformed_request", json!({ "result": refusal.code }));
    }

    pub fn handle(&self, caller: &Caller, request: Request) -> Result<Value, Refusal> {
        if !authorized(caller.role, &request) {
            self.audit(caller, "denied", json!({ "request": request, "result": "denied" }))?;
            return Err(Refusal::new("denied", format!("{} may not make this request", caller.name)));
        }
        match request {
            Request::SystemStatus {} => self.status(),
            Request::ChangeHistory {} => Ok(json!(self.store.history()?)),
            Request::ChangeShow { id } => Ok(json!(self.store.load(id)?)),
            mutating => {
                let _lock = self.store.lock()?;
                let recovered = self.recover_interrupted(caller)?;
                match mutating {
                    Request::Recover {} => Ok(json!({ "recovered": recovered })),
                    Request::ChangePlan { reason, operation } => self.plan(caller, reason, operation),
                    Request::ChangeApprove { id } => self.decide(caller, id, true),
                    Request::ChangeReject { id } => self.decide(caller, id, false),
                    Request::ChangeApply { id } => self.apply(caller, id),
                    Request::ServiceStart { project } => self.service(caller, "service_start", &project, project::service_start),
                    Request::ServiceCredential { project } => {
                        self.service(caller, "service_credential", &project, project::service_credential)
                    }
                    _ => unreachable!("read-only requests return above"),
                }
            }
        }
    }

    /// The audit records that a credential was issued, never the credential itself.
    fn service(&self, caller: &Caller, event: &str, name: &str, run: fn(&str) -> Result<Value, Refusal>) -> Result<Value, Refusal> {
        let result = run(name);
        let outcome = match &result {
            Ok(_) => "ok",
            Err(refusal) => refusal.code,
        };
        self.audit(caller, event, json!({ "project": name, "result": outcome }))?;
        result
    }

    fn status(&self) -> Result<Value, Refusal> {
        let changes = self.store.all()?;
        let ids = |state: State| changes.iter().filter(|c| c.state == state).map(|c| c.id).collect::<Vec<_>>();
        Ok(json!({
            "dpkg_consistent": apt::dpkg_consistent(),
            "awaiting_approval": ids(State::AwaitingApproval),
            "approved": ids(State::Approved),
            "applying": ids(State::Applying),
            "toolchains": toolchain::list(),
            "reboot_required": apt::reboot_required(),
        }))
    }

    fn plan(&self, caller: &Caller, reason: String, operation: Operation) -> Result<Value, Refusal> {
        let checked = validate_reason(&reason).and_then(|()| operation.validate()).and_then(|()| Policy::load());
        let policy = match checked {
            Ok(policy) => policy,
            Err(refusal) => return self.refuse_plan(caller, &operation, refusal),
        };
        let id = self.store.next_id()?;
        // Planning runs apt as root, so its record comes first.
        self.audit(caller, "planning", json!({ "change": id, "action": operation, "reason": reason }))?;
        let planned = if is_package(&operation) {
            apt::plan(id, &operation)
        } else if is_project(&operation) {
            project::plan(&operation)
        } else {
            toolchain::plan(&operation)
        };
        let impact = match planned {
            Ok(impact) => impact,
            Err(refusal) => {
                apt::discard_artifacts(id);
                return self.refuse_plan(caller, &operation, refusal);
            }
        };
        // Approved creates that have not run yet count too, so a burst of plans
        // cannot pass the limit before any of them applies.
        let pending = self.store.all()?.iter().filter(|c| is_project(&c.operation) && c.state == State::Approved).count();
        let decision = policy.evaluate_with(&operation, &impact, || project::project_count() + pending);
        let automatic = decision.level == Level::Automatic;
        let change = Change {
            id,
            reason,
            operation,
            requested_by: caller.name.clone(),
            requested_at: now(),
            updated_at: now(),
            state: if automatic { State::Approved } else { State::AwaitingApproval },
            impact,
            decision,
            approved_by: automatic.then(|| "policy".to_string()),
            outcome: None,
        };
        self.audit(caller, "planned", json!({ "change": change.id, "action": change.operation, "decision": change.decision, "impact": change.impact, "reason": change.reason }))?;
        self.store.save(&change)?;
        Ok(json!(change))
    }

    fn refuse_plan(&self, caller: &Caller, operation: &Operation, refusal: Refusal) -> Result<Value, Refusal> {
        self.audit(caller, "plan_refused", json!({ "action": operation, "result": refusal.code, "detail": refusal.message }))?;
        Err(refusal)
    }

    fn decide(&self, caller: &Caller, id: u64, approve: bool) -> Result<Value, Refusal> {
        let mut change = self.store.load(id)?;
        if change.state != State::AwaitingApproval {
            return Err(Refusal::new("wrong_state", format!("change {id} is not awaiting approval")));
        }
        change.state = if approve { State::Approved } else { State::Rejected };
        change.approved_by = approve.then(|| caller.name.clone());
        change.updated_at = now();
        self.audit(caller, if approve { "approved" } else { "rejected" }, json!({ "change": id, "action": change.operation }))?;
        self.store.save(&change)?;
        if !approve {
            apt::discard_artifacts(id);
        }
        Ok(json!(change))
    }

    fn apply(&self, caller: &Caller, id: u64) -> Result<Value, Refusal> {
        let mut change = self.store.load(id)?;
        if change.state != State::Approved {
            self.audit(caller, "apply_refused", json!({ "change": id, "result": "not_approved" }))?;
            return Err(Refusal::new("not_approved", format!("change {id} is not approved")));
        }
        // Approval covers the exact transaction that the approver saw.
        if !still_matches(&change) {
            change.state = State::Stale;
            change.updated_at = now();
            self.audit(caller, "stale", json!({ "change": id, "action": change.operation, "result": "stale" }))?;
            self.store.save(&change)?;
            apt::discard_artifacts(id);
            return Err(Refusal::new("stale", format!("the transaction for change {id} has changed. Request a new plan.")));
        }

        change.state = State::Applying;
        change.updated_at = now();
        self.audit(caller, "applying", json!({ "change": id, "action": change.operation, "approved_by": change.approved_by }))?;
        self.store.save(&change)?;

        let ran = run_change(&change);
        let (verified, detail) = verify(&change.operation, &change.impact.actions);
        match ran {
            Ok(()) => self.finish(caller, change, verified, detail, false),
            Err(error) => self.finish(caller, change, false, format!("{error}. {detail}"), false),
        }
    }

    fn finish(&self, caller: &Caller, mut change: Change, verified: bool, detail: String, recovered: bool) -> Result<Value, Refusal> {
        let recovery = recovery_reference(&change.operation);
        change.state = if verified { State::Applied } else { State::Failed };
        change.updated_at = now();
        change.outcome = Some(Outcome { verified, detail: detail.clone(), recovered, recovery: recovery.clone() });
        self.audit(caller, "finished", json!({
            "change": change.id,
            "action": change.operation,
            "result": change.state,
            "verified": verified,
            "detail": detail,
            "recovered": recovered,
            "recovery": recovery,
        }))?;
        self.store.save(&change)?;
        apt::discard_artifacts(change.id);
        Ok(json!(change))
    }

    /// Runs with the lock held, so a change still in `applying` has no live owner.
    fn recover_interrupted(&self, caller: &Caller) -> Result<Vec<u64>, Refusal> {
        let mut recovered = Vec::new();
        for change in self.store.all()?.into_iter().filter(|c| c.state == State::Applying) {
            let id = change.id;
            self.audit(caller, "recovery_started", json!({ "change": id, "action": change.operation }))?;
            let repair = if is_package(&change.operation) {
                apt::repair(&change.impact.actions)
            } else if is_project(&change.operation) {
                // Each step resumes or finds its work done, so recovery runs them again.
                match project::apply(&change.operation) {
                    Ok(()) => "finished the create".to_string(),
                    Err(error) => format!("could not finish the create: {error}"),
                }
            } else {
                toolchain::clean_staging(id);
                "removed staging files".to_string()
            };
            let (verified, detail) = verify(&change.operation, &change.impact.actions);
            self.audit(caller, "recovery", json!({ "change": id, "repair": repair, "verified": verified }))?;
            self.finish(caller, change, verified, format!("interrupted. {repair} {detail}"), true)?;
            recovered.push(id);
        }
        Ok(recovered)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SYSTEM_UID: u32 = 990;

    fn requests() -> Vec<Request> {
        let operation = Operation::PackageInstall { names: vec!["ripgrep".into()] };
        vec![
            Request::SystemStatus {},
            Request::ChangeHistory {},
            Request::ChangeShow { id: 1 },
            Request::ChangePlan { reason: "r".into(), operation },
            Request::ChangeApply { id: 1 },
            Request::Recover {},
            Request::ServiceStart { project: "a".into() },
            Request::ServiceCredential { project: "a".into() },
        ]
    }

    #[test]
    fn roles_come_only_from_the_kernel_uid() {
        assert_eq!(role_of(0, Some(SYSTEM_UID)), Role::Administrator);
        assert_eq!(role_of(SYSTEM_UID, Some(SYSTEM_UID)), Role::SystemAgent);
        assert_eq!(role_of(20000, Some(SYSTEM_UID)), Role::Unauthorized);
        assert_eq!(role_of(20000, None), Role::Unauthorized);
    }

    #[test]
    fn projects_may_make_no_request_at_all() {
        for request in requests().iter().chain(&[Request::ChangeApprove { id: 1 }, Request::ChangeReject { id: 1 }]) {
            assert!(!authorized(Role::Unauthorized, request), "{request:?}");
        }
    }

    #[test]
    fn only_the_administrator_decides() {
        for role in [Role::Administrator, Role::SystemAgent] {
            for request in requests() {
                assert!(authorized(role, &request), "{role:?} {request:?}");
            }
        }
        for request in [Request::ChangeApprove { id: 1 }, Request::ChangeReject { id: 1 }] {
            assert!(authorized(Role::Administrator, &request));
            assert!(!authorized(Role::SystemAgent, &request));
        }
    }
}
