//! Serves one connection. systemd starts one instance per connection, with the
//! socket on standard input, and stops the instance's whole cgroup with it.

use hostd::broker::{Broker, Caller};
use hostd::protocol::{Refusal, Request, Response, MAX_REQUEST_BYTES};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::net::UnixStream;
use std::process::ExitCode;
use std::time::Duration;

/// The kernel recorded these when the client connected. The client cannot alter them.
fn peer_credentials(stream: &UnixStream) -> std::io::Result<libc::ucred> {
    let mut credentials = libc::ucred { pid: 0, uid: 0, gid: 0 };
    let mut length = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    // SAFETY: the pointers refer to live locals of the size given in `length`.
    let status = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            std::ptr::addr_of_mut!(credentials).cast(),
            &mut length,
        )
    };
    if status == 0 {
        Ok(credentials)
    } else {
        Err(std::io::Error::last_os_error())
    }
}

fn read_request(stream: &UnixStream) -> Result<Request, Refusal> {
    let mut line = Vec::new();
    BufReader::new(stream.take(MAX_REQUEST_BYTES + 1))
        .read_until(b'\n', &mut line)
        .map_err(|error| Refusal::new("malformed", error.to_string()))?;
    if line.len() as u64 > MAX_REQUEST_BYTES {
        return Err(Refusal::new("malformed", "request is too large"));
    }
    serde_json::from_slice(&line).map_err(|error| Refusal::new("malformed", error.to_string()))
}

fn main() -> ExitCode {
    // SAFETY: systemd passes the connection as descriptor 0, and only this owns it.
    let stream = unsafe { UnixStream::from_raw_fd(0) };
    let Ok(peer) = peer_credentials(&stream) else {
        eprintln!("agentos-hostd: standard input is not a Unix socket");
        return ExitCode::FAILURE;
    };
    let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));

    let caller = Caller::resolve(peer.uid, peer.pid);
    let broker = Broker::default();
    let outcome = match read_request(&stream) {
        Ok(request) => broker.handle(&caller, request),
        Err(refusal) => {
            broker.record_malformed(&caller, &refusal);
            Err(refusal)
        }
    };
    let response = match outcome {
        Ok(result) => Response::Ok { result },
        Err(refusal) => Response::Refused { code: refusal.code.to_string(), message: refusal.message },
    };
    // The change is already recorded, so a client that has gone away loses nothing.
    let mut stream = &stream;
    if let Ok(mut body) = serde_json::to_vec(&response) {
        body.push(b'\n');
        let _ = stream.write_all(&body);
    }
    ExitCode::SUCCESS
}
