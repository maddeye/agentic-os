//! Durable change records and the audit log. Readers never see a partial record.

use crate::protocol::{Change, Refusal};
use serde_json::{json, Value};
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::os::fd::AsRawFd;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

const ROOT: &str = "/var/lib/agent-os/metadata/hostd";
const HISTORY_EVENTS: usize = 200;

pub struct Store {
    root: PathBuf,
}

/// Held for one mutating request. The kernel releases it if the holder dies, so
/// a change found in `applying` while this is held was interrupted.
pub struct Lock {
    _file: File,
}

pub fn now() -> String {
    let seconds = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs());
    format_utc(seconds)
}

/// Converts Unix time with the civil-from-days algorithm.
fn format_utc(seconds: u64) -> String {
    let days = (seconds / 86400) as i64;
    let rest = seconds % 86400;
    let z = days + 719468;
    let era = z.div_euclid(146097);
    let doe = z.rem_euclid(146097);
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!("{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z", rest / 3600, rest / 60 % 60, rest % 60)
}

impl Default for Store {
    fn default() -> Self {
        Store { root: PathBuf::from(ROOT) }
    }
}

impl Store {
    fn changes(&self) -> PathBuf {
        self.root.join("changes")
    }

    fn path_of(&self, id: u64) -> PathBuf {
        self.changes().join(format!("{id:06}.json"))
    }

    pub fn lock(&self) -> Result<Lock, Refusal> {
        let file = OpenOptions::new().create(true).write(true).truncate(false).mode(0o600).open(self.root.join("lock"))?;
        // SAFETY: flock only reads the descriptor, which `file` keeps open.
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } != 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        Ok(Lock { _file: file })
    }

    fn write_atomic(&self, path: &Path, bytes: &[u8]) -> Result<(), Refusal> {
        let temporary = path.with_extension("tmp");
        let mut file = OpenOptions::new().create(true).write(true).truncate(true).mode(0o600).open(&temporary)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        fs::rename(&temporary, path)?;
        File::open(path.parent().expect("record paths have a parent"))?.sync_all()?;
        Ok(())
    }

    pub fn next_id(&self) -> Result<u64, Refusal> {
        let path = self.root.join("next-id");
        let id = match fs::read_to_string(&path) {
            Ok(text) => text.trim().parse().map_err(|_| Refusal::new("internal", "corrupt change counter"))?,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => 1,
            Err(error) => return Err(error.into()),
        };
        self.write_atomic(&path, format!("{}\n", id + 1).as_bytes())?;
        Ok(id)
    }

    pub fn save(&self, change: &Change) -> Result<(), Refusal> {
        self.write_atomic(&self.path_of(change.id), &serde_json::to_vec_pretty(change)?)
    }

    pub fn load(&self, id: u64) -> Result<Change, Refusal> {
        let text = fs::read_to_string(self.path_of(id))
            .map_err(|_| Refusal::new("not_found", format!("no such change: {id}")))?;
        Ok(serde_json::from_str(&text)?)
    }

    pub fn all(&self) -> Result<Vec<Change>, Refusal> {
        let mut changes = Vec::new();
        for entry in fs::read_dir(self.changes())? {
            let path = entry?.path();
            if path.extension().is_some_and(|extension| extension == "json") {
                changes.push(serde_json::from_slice::<Change>(&fs::read(&path)?)?);
            }
        }
        changes.sort_by_key(|change| change.id);
        Ok(changes)
    }

    /// Appends and syncs one event. Callers stop if this fails, so no privileged
    /// step runs without its record.
    pub fn audit(&self, identity: Value, event: &str, fields: Value) -> Result<(), Refusal> {
        let mut record = json!({ "time": now(), "event": event, "caller": identity });
        if let (Some(target), Value::Object(extra)) = (record.as_object_mut(), fields) {
            target.extend(extra);
        }
        let mut line = serde_json::to_vec(&record)?;
        line.push(b'\n');
        let mut file = OpenOptions::new().create(true).append(true).mode(0o600).open(self.root.join("audit.jsonl"))?;
        file.write_all(&line)?;
        file.sync_data()?;
        Ok(())
    }

    pub fn history(&self) -> Result<Vec<Value>, Refusal> {
        let text = match fs::read_to_string(self.root.join("audit.jsonl")) {
            Ok(text) => text,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => String::new(),
            Err(error) => return Err(error.into()),
        };
        let lines: Vec<&str> = text.lines().collect();
        let start = lines.len().saturating_sub(HISTORY_EVENTS);
        lines[start..].iter().map(|line| Ok(serde_json::from_str(line)?)).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::format_utc;

    #[test]
    fn formats_utc_across_calendar_edges() {
        assert_eq!(format_utc(0), "1970-01-01T00:00:00Z");
        assert_eq!(format_utc(951782400), "2000-02-29T00:00:00Z");
        assert_eq!(format_utc(1794100921), "2026-11-08T01:22:01Z");
    }
}
