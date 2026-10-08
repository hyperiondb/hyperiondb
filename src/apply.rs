use std::process::{Command, Output, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const SQL_TIMEOUT: Duration = Duration::from_secs(10);
const PROBE_TIMEOUT: Duration = Duration::from_millis(1200);

fn output_with_timeout(mut command: Command, timeout: Duration) -> Option<Output> {
    command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = command.spawn().ok()?;
    let deadline = Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(_)) => return child.wait_with_output().ok(),
            Ok(None) if Instant::now() >= deadline => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(20)),
            Err(_) => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
        }
    }
}

pub fn split_host_port(addr: &str) -> (String, String) {
    match addr.rsplit_once(':') {
        Some((host, port)) => (host.to_string(), port.to_string()),
        None => (addr.to_string(), String::from("5432")),
    }
}

pub fn parent_dir(path: &str) -> String {
    match path.rsplit_once('/') {
        Some((dir, _)) => dir.to_string(),
        None => String::from("."),
    }
}

pub fn spawn_rejoin(
    script: &str,
    pgbin: &str,
    datadir: &str,
    leader_host: &str,
    leader_port: &str,
    node_id: u64,
    passfile: &str,
    standby_conninfo: &str,
) -> bool {
    Command::new("setsid")
        .arg("bash")
        .arg(script)
        .arg(pgbin)
        .arg(datadir)
        .arg(leader_host)
        .arg(leader_port)
        .arg(node_id.to_string())
        .arg(passfile)
        .arg(standby_conninfo)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .is_ok()
}

pub fn write_heartbeat(path: &str) {
    let millis = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis())
        .unwrap_or(0);
    let tmp = format!("{}.tmp", path);
    if std::fs::write(&tmp, millis.to_string()).is_ok() {
        let _ = std::fs::rename(&tmp, path);
    }
}

pub fn spawn_watchdog(
    script: &str,
    psql: &str,
    host: &str,
    port: &str,
    heartbeat: &str,
    node_id: u64,
    user: &str,
) -> bool {
    Command::new("setsid")
        .arg("bash")
        .arg(script)
        .arg(psql)
        .arg(host)
        .arg(port)
        .arg(heartbeat)
        .arg(node_id.to_string())
        .arg(user)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .is_ok()
}

pub fn peer_wal_lsn(psql: &str, host: &str, port: &str) -> Option<u64> {
    let mut command = Command::new(psql);
    command
        .args([
            "-h", host,
            "-p", port,
            "-U", "replicator",
            "-d", "postgres",
            "-w",
            "-tAc",
            "SELECT pg_wal_lsn_diff(COALESCE(pg_last_wal_receive_lsn(), '0/0'), '0/0')::bigint",
        ])
        .env("PGCONNECT_TIMEOUT", "1");
    let output = output_with_timeout(command, PROBE_TIMEOUT)?;
    if output.status.success() {
        String::from_utf8_lossy(&output.stdout)
            .trim()
            .parse::<i64>()
            .ok()
            .map(|value| value.max(0) as u64)
    } else {
        None
    }
}

pub fn primary_timeline_history(psql: &str, host: &str, port: &str) -> Option<(u32, String)> {
    let mut command = Command::new(psql);
    command
        .args([
            "-h", host,
            "-p", port,
            "-U", "replicator",
            "-d", "postgres",
            "-w",
            "-tAc",
            "SELECT tli || '|' || coalesce(convert_from(pg_read_binary_file('pg_wal/' || hex || '.history', 0, 1048576, true), 'UTF8'), '') \
             FROM (SELECT substr(pg_walfile_name(pg_current_wal_lsn()), 1, 8) AS hex) w, \
             LATERAL (SELECT ('x' || hex)::bit(32)::int AS tli) t",
        ])
        .env("PGCONNECT_TIMEOUT", "2");
    let output = output_with_timeout(command, Duration::from_secs(3))?;
    if !output.status.success() {
        return None;
    }
    let text = String::from_utf8_lossy(&output.stdout).to_string();
    let (tli, history) = text.split_once('|')?;
    Some((tli.trim().parse().ok()?, history.to_string()))
}

pub fn wal_lsn(psql: &str, host: &str, port: &str, in_recovery: bool) -> u64 {
    let sql = if in_recovery {
        "SELECT pg_wal_lsn_diff(COALESCE(pg_last_wal_receive_lsn(), '0/0'), '0/0')::bigint"
    } else {
        "SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), '0/0')::bigint"
    };
    run_sql_with_timeout(psql, host, port, sql, PROBE_TIMEOUT)
        .ok()
        .and_then(|value| value.trim().parse::<i64>().ok())
        .map(|value| value.max(0) as u64)
        .unwrap_or(0)
}

pub fn run_sql(psql: &str, host: &str, port: &str, sql: &str) -> Result<String, String> {
    run_sql_with_timeout(psql, host, port, sql, SQL_TIMEOUT)
}

fn run_sql_with_timeout(
    psql: &str,
    host: &str,
    port: &str,
    sql: &str,
    timeout: Duration,
) -> Result<String, String> {
    let user = crate::config::apply_user();
    let db = crate::config::apply_db();
    let passfile = crate::config::passfile();
    let mut command = Command::new(psql);
    command.args([
        "-h", host,
        "-p", port,
        "-U", user.as_str(),
        "-d", db.as_str(),
        "-w",
        "-v", "ON_ERROR_STOP=1",
        "-tAc", sql,
    ]);
    command.env("PGCONNECT_TIMEOUT", "2");
    command.env("PGOPTIONS", "-c statement_timeout=5000");
    if !passfile.is_empty() {
        command.env("PGPASSFILE", &passfile);
    }
    let output = output_with_timeout(command, timeout)
        .ok_or_else(|| String::from("psql failed to spawn or timed out"))?;

    if output.status.success() {
        Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
    } else {
        Err(String::from_utf8_lossy(&output.stderr).trim().to_string())
    }
}
