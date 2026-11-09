//! Wire types. One JSON request and one JSON response per connection.
//!
//! No request carries an identity or a command string. The kernel supplies the
//! caller, and each operation is a closed variant with validated fields.

use serde::{Deserialize, Serialize};
use std::io::Read;
use std::os::unix::net::UnixStream;
use std::time::{Duration, Instant};

pub const SOCKET: &str = "/run/agentos/hostd.sock";
/// Root-only, with its own connection limit, so the system agent cannot fill it.
pub const ADMIN_SOCKET: &str = "/run/agentos/hostd-admin.sock";
pub const MAX_REQUEST_BYTES: usize = 64 * 1024;
const MAX_PACKAGES: usize = 32;
const MAX_REASON_CHARS: usize = 512;

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum Operation {
    PackageInstall { names: Vec<String> },
    PackageRemove { names: Vec<String> },
    /// Moves every installed package to its candidate. It never removes a package.
    PackageUpgrade {},
    ToolchainInstallGlobal { name: String, version: String },
    ToolchainRemoveGlobal { name: String, version: String },
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(tag = "request", rename_all = "snake_case", deny_unknown_fields)]
pub enum Request {
    SystemStatus {},
    ChangeHistory {},
    ChangeShow { id: u64 },
    ChangePlan { reason: String, operation: Operation },
    ChangeApprove { id: u64 },
    ChangeReject { id: u64 },
    ChangeApply { id: u64 },
    Recover {},
}

#[derive(Serialize, Deserialize, Debug)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum Response {
    Ok { result: serde_json::Value },
    Refused { code: String, message: String },
}

#[derive(Debug)]
pub struct Refusal {
    pub code: &'static str,
    pub message: String,
}

impl Refusal {
    pub fn new(code: &'static str, message: impl Into<String>) -> Self {
        Refusal { code, message: message.into() }
    }
}

impl From<std::io::Error> for Refusal {
    fn from(error: std::io::Error) -> Self {
        Refusal::new("internal", error.to_string())
    }
}

impl From<serde_json::Error> for Refusal {
    fn from(error: serde_json::Error) -> Self {
        Refusal::new("internal", error.to_string())
    }
}

#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum ActionKind {
    Install,
    Upgrade,
    Remove,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
pub struct Action {
    pub kind: ActionKind,
    pub target: String,
    pub from: Option<String>,
    pub to: Option<String>,
}

/// One package file that a plan downloaded, scanned, and will install.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
pub struct Artifact {
    pub name: String,
    pub version: String,
    pub architecture: String,
    pub file: String,
    pub sha256: String,
}

#[derive(Serialize, Deserialize, Debug, Clone, Default, PartialEq)]
pub struct Impact {
    pub actions: Vec<Action>,
    pub artifacts: Vec<Artifact>,
    pub toolchain_source: Option<serde_json::Value>,
    pub download_bytes: u64,
    pub services: Vec<String>,
    pub setuid_files: Vec<String>,
    pub used_by_projects: Vec<String>,
    /// Upgradable packages that apt would not move, usually because of a conflict.
    /// Changes recorded before this field existed have none.
    #[serde(default)]
    pub kept_back: Vec<String>,
}

#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum Level {
    Automatic,
    ApprovalRequired,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
pub struct Decision {
    pub level: Level,
    pub reasons: Vec<String>,
}

#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum State {
    AwaitingApproval,
    Approved,
    Applying,
    Applied,
    Failed,
    Rejected,
    Stale,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
pub struct Outcome {
    pub verified: bool,
    pub detail: String,
    pub recovered: bool,
    pub recovery: String,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
pub struct Change {
    pub id: u64,
    pub reason: String,
    pub operation: Operation,
    pub requested_by: String,
    pub requested_at: String,
    pub updated_at: String,
    pub state: State,
    pub impact: Impact,
    pub decision: Decision,
    pub approved_by: Option<String>,
    pub outcome: Option<Outcome>,
}

/// Debian names, without the `*` and `/` that select other packages or files.
/// `.` and `+` are legal and also regex syntax for apt, so plans check the result.
pub fn valid_package_name(name: &str) -> bool {
    let bytes = name.as_bytes();
    (2..=128).contains(&bytes.len())
        && (bytes[0].is_ascii_lowercase() || bytes[0].is_ascii_digit())
        && bytes.iter().all(|b| {
            b.is_ascii_lowercase() || b.is_ascii_digit() || matches!(b, b'+' | b'-' | b'.')
        })
}

pub fn valid_toolchain_name(name: &str) -> bool {
    let bytes = name.as_bytes();
    (1..=64).contains(&bytes.len())
        && bytes[0].is_ascii_lowercase()
        && bytes.iter().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || *b == b'-')
}

pub fn valid_toolchain_version(version: &str) -> bool {
    let bytes = version.as_bytes();
    (1..=64).contains(&bytes.len())
        && bytes[0].is_ascii_digit()
        && bytes.iter().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-' | b'_'))
}

impl Operation {
    pub fn validate(&self) -> Result<(), Refusal> {
        let valid = match self {
            Operation::PackageInstall { names } | Operation::PackageRemove { names } => {
                !names.is_empty()
                    && names.len() <= MAX_PACKAGES
                    && names.iter().all(|name| valid_package_name(name))
            }
            Operation::PackageUpgrade {} => true,
            Operation::ToolchainInstallGlobal { name, version }
            | Operation::ToolchainRemoveGlobal { name, version } => {
                valid_toolchain_name(name) && valid_toolchain_version(version)
            }
        };
        if valid {
            Ok(())
        } else {
            Err(Refusal::new("invalid", "operation has an invalid name or version"))
        }
    }
}

/// Reads one line. The limit covers the whole request, so a client that sends
/// one byte at a time cannot hold a broker instance past it.
pub fn read_line(mut stream: &UnixStream, limit: Duration) -> Result<Vec<u8>, Refusal> {
    let deadline = Instant::now() + limit;
    let (mut line, mut chunk) = (Vec::new(), [0u8; 4096]);
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(Refusal::new("malformed", "request timed out"));
        }
        stream.set_read_timeout(Some(remaining))?;
        let count = stream.read(&mut chunk).map_err(|error| Refusal::new("malformed", error.to_string()))?;
        line.extend_from_slice(&chunk[..count]);
        if line.len() > MAX_REQUEST_BYTES {
            return Err(Refusal::new("malformed", "request is too large"));
        }
        if let Some(end) = line.iter().position(|byte| *byte == b'\n') {
            line.truncate(end);
            return Ok(line);
        }
        if count == 0 {
            return Ok(line);
        }
    }
}

pub fn validate_reason(reason: &str) -> Result<(), Refusal> {
    let count = reason.chars().count();
    if (1..=MAX_REASON_CHARS).contains(&count) && !reason.chars().any(char::is_control) {
        Ok(())
    } else {
        Err(Refusal::new("invalid", "reason must be 1 to 512 characters without control characters"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_shell_shaped_requests_and_forged_identity() {
        for body in [
            r#"{"request":"run_as_root","command":"id"}"#,
            r#"{"request":"system_status","caller":"root"}"#,
            r#"{"request":"change_approve","id":1,"as":"admin"}"#,
            r#"{"request":"change_plan","reason":"x","operation":{"type":"shell","command":"id"}}"#,
            r#"{"request":"change_plan","reason":"x","operation":{"type":"package_install","names":["a1"],"post":"id"}}"#,
        ] {
            assert!(serde_json::from_str::<Request>(body).is_err(), "accepted {body}");
        }
    }

    #[test]
    fn a_slow_client_cannot_outlast_the_request_limit() {
        let (reader, mut writer) = UnixStream::pair().unwrap();
        let drip = std::thread::spawn(move || {
            use std::io::Write;
            while writer.write_all(b"x").is_ok() {
                std::thread::sleep(Duration::from_millis(20));
            }
        });
        let started = Instant::now();
        assert!(read_line(&reader, Duration::from_millis(100)).is_err());
        assert!(started.elapsed() < Duration::from_secs(2));
        drop(reader);
        drip.join().unwrap();
    }

    #[test]
    fn read_line_stops_at_the_newline() {
        let (reader, mut writer) = UnixStream::pair().unwrap();
        std::io::Write::write_all(&mut writer, b"{}\nignored").unwrap();
        assert_eq!(read_line(&reader, Duration::from_secs(1)).unwrap(), b"{}");
    }

    #[test]
    fn package_names_exclude_option_path_and_glob_syntax() {
        for good in ["ripgrep", "g++", "libstdc++6", "fonts-dejavu", "python3.13"] {
            assert!(valid_package_name(good), "{good}");
        }
        for bad in ["-oDebug::x=1", "../evil", "a/b.deb", "foo*", "foo:i386", "foo=1.0", "foo bar", "F", "", "a;b"] {
            assert!(!valid_package_name(bad), "{bad}");
        }
    }

    #[test]
    fn toolchain_fields_cannot_traverse() {
        assert!(valid_toolchain_version("26.13.0"));
        for bad in ["..", "../x", ".hidden", "1/2", ""] {
            assert!(!valid_toolchain_version(bad), "{bad}");
        }
        for bad in ["..", ".staging", "a/b", "Node", ""] {
            assert!(!valid_toolchain_name(bad), "{bad}");
        }
    }
}
