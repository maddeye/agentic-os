//! Client for `agentos system`. It holds no privilege. hostd decides everything.

use hostd::protocol::{Level, Operation, Request, Response, State, SOCKET};
use serde_json::Value;
use std::io::{Read, Write};
use std::net::Shutdown;
use std::os::unix::net::UnixStream;
use std::process::ExitCode;

const EXIT_REFUSED: u8 = 1;
const EXIT_USAGE: u8 = 2;
const EXIT_AWAITING_APPROVAL: u8 = 3;

const USAGE: &str = "usage: agentos system status
       agentos system recover
       agentos system package install|remove NAME... --reason TEXT
       agentos system toolchain install|remove NAME VERSION --reason TEXT
       agentos system change show|approve|reject|apply ID
       agentos system change history";

fn send(request: &Request) -> Result<Value, String> {
    let mut stream = UnixStream::connect(SOCKET).map_err(|error| format!("{SOCKET}: {error}"))?;
    let mut body = serde_json::to_vec(request).map_err(|error| error.to_string())?;
    body.push(b'\n');
    stream.write_all(&body).map_err(|error| error.to_string())?;
    stream.shutdown(Shutdown::Write).map_err(|error| error.to_string())?;
    let mut reply = String::new();
    stream.read_to_string(&mut reply).map_err(|error| error.to_string())?;
    match serde_json::from_str(&reply).map_err(|error| format!("bad reply: {error}"))? {
        Response::Ok { result } => Ok(result),
        Response::Refused { code, message } => Err(format!("{code}: {message}")),
    }
}

fn print(value: &Value) {
    println!("{}", serde_json::to_string_pretty(value).unwrap_or_default());
}

fn finish(result: Result<Value, String>) -> ExitCode {
    match result {
        Ok(value) => {
            print(&value);
            let state = value.get("state").and_then(|s| serde_json::from_value::<State>(s.clone()).ok());
            match state {
                Some(State::AwaitingApproval) => ExitCode::from(EXIT_AWAITING_APPROVAL),
                Some(State::Failed) => ExitCode::from(EXIT_REFUSED),
                _ => ExitCode::SUCCESS,
            }
        }
        Err(message) => {
            eprintln!("agentos: {message}");
            ExitCode::from(EXIT_REFUSED)
        }
    }
}

/// Plans a change, then applies it at once if policy already approved it.
fn submit(reason: String, operation: Operation) -> ExitCode {
    let planned = match send(&Request::ChangePlan { reason, operation }) {
        Ok(change) => change,
        Err(message) => return finish(Err(message)),
    };
    let automatic = planned.pointer("/decision/level").and_then(|l| serde_json::from_value::<Level>(l.clone()).ok()) == Some(Level::Automatic);
    match planned.get("id").and_then(Value::as_u64) {
        Some(id) if automatic => finish(send(&Request::ChangeApply { id })),
        _ => finish(Ok(planned)),
    }
}

fn take_reason(args: &mut Vec<String>) -> Option<String> {
    let index = args.iter().position(|arg| arg == "--reason")?;
    let reason = args.get(index + 1)?.clone();
    args.drain(index..=index + 1);
    Some(reason)
}

fn change_request(verb: &str, id: u64) -> Option<Request> {
    match verb {
        "show" => Some(Request::ChangeShow { id }),
        "approve" => Some(Request::ChangeApprove { id }),
        "reject" => Some(Request::ChangeReject { id }),
        "apply" => Some(Request::ChangeApply { id }),
        _ => None,
    }
}

fn dispatch(mut args: Vec<String>) -> Option<ExitCode> {
    let words: Vec<&str> = args.iter().map(String::as_str).collect();
    match words.as_slice() {
        ["status"] => return Some(finish(send(&Request::SystemStatus {}))),
        ["recover"] => return Some(finish(send(&Request::Recover {}))),
        ["change", "history"] => return Some(finish(send(&Request::ChangeHistory {}))),
        ["change", verb, id] => {
            let request = change_request(verb, id.parse().ok()?)?;
            return Some(finish(send(&request)));
        }
        _ => {}
    }
    let reason = take_reason(&mut args)?;
    let words: Vec<&str> = args.iter().map(String::as_str).collect();
    let operation = match words.as_slice() {
        ["package", verb @ ("install" | "remove"), names @ ..] if !names.is_empty() => {
            let names = names.iter().map(ToString::to_string).collect();
            if *verb == "install" { Operation::PackageInstall { names } } else { Operation::PackageRemove { names } }
        }
        ["toolchain", "install", name, version] => Operation::ToolchainInstallGlobal { name: name.to_string(), version: version.to_string() },
        ["toolchain", "remove", name, version] => Operation::ToolchainRemoveGlobal { name: name.to_string(), version: version.to_string() },
        _ => return None,
    };
    Some(submit(reason, operation))
}

fn main() -> ExitCode {
    dispatch(std::env::args().skip(1).collect()).unwrap_or_else(|| {
        eprintln!("{USAGE}");
        ExitCode::from(EXIT_USAGE)
    })
}
