//! Runs host tools with an argument vector and a fixed environment.

use crate::protocol::Refusal;
use std::process::{Command, Stdio};

const DETAIL_BYTES: usize = 2000;

pub fn tool(program: &str) -> Command {
    let mut command = Command::new(program);
    command
        .env_clear()
        .env("PATH", "/usr/sbin:/usr/bin:/sbin:/bin")
        .env("LC_ALL", "C")
        .env("HOME", "/root")
        .env("DEBIAN_FRONTEND", "noninteractive")
        .env("APT_LISTCHANGES_FRONTEND", "none")
        .stdin(Stdio::null());
    command
}

pub struct Ran {
    pub success: bool,
    pub stdout: String,
    pub stderr: String,
}

impl Ran {
    /// The end of the output, where apt and dpkg state the failure.
    pub fn tail(&self) -> String {
        let text = format!("{}{}", self.stdout, self.stderr);
        let mut start = text.len().saturating_sub(DETAIL_BYTES);
        while !text.is_char_boundary(start) {
            start += 1;
        }
        text[start..].trim().to_string()
    }
}

pub fn run(command: &mut Command) -> std::io::Result<Ran> {
    let output = command.output()?;
    Ok(Ran {
        success: output.status.success(),
        stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
    })
}

pub fn require(command: &mut Command, code: &'static str, what: &str) -> Result<Ran, Refusal> {
    let ran = run(command).map_err(|error| Refusal::new(code, format!("{what}: {error}")))?;
    if ran.success {
        Ok(ran)
    } else {
        Err(Refusal::new(code, format!("{what} failed: {}", ran.tail())))
    }
}
