use pgrx::bgworkers::{BackgroundWorker, BackgroundWorkerBuilder, BgWorkerStartTime, SignalWakeFlags};
use pgrx::prelude::*;
use std::collections::HashMap;
use std::time::{Duration, Instant};

mod apply;
mod config;
mod failover;
mod raft_node;
mod rpc;
mod rtype;
mod state;
mod store;

pgrx::pg_module_magic!();

#[pg_guard]
pub extern "C-unwind" fn _PG_init() {
    if !unsafe { pg_sys::process_shared_preload_libraries_in_progress } {
        return;
    }

    config::init();

    BackgroundWorkerBuilder::new("pg_replica supervisor")
        .set_function("pg_replica_supervisor_main")
        .set_library("pg_replica")
        .set_restart_time(Some(Duration::from_secs(5)))
        .set_start_time(BgWorkerStartTime::ConsistentState)
        .load();
}

fn local_wal_lsn(in_recovery: bool) -> u64 {
    unsafe {
        if in_recovery {
            pg_sys::GetXLogReplayRecPtr(std::ptr::null_mut())
        } else {
            pg_sys::GetXLogWriteRecPtr()
        }
    }
}

fn standby_conninfo(pg_members: &[rpc::Peer], passfile: &str, node_id: u64) -> String {
    let mut hosts = Vec::new();
    let mut ports = Vec::new();
    for member in pg_members {
        if member.id == node_id {
            continue;
        }
        let (host, port) = apply::split_host_port(&member.addr);
        hosts.push(host);
        ports.push(port);
    }
    let passfile_kw = if passfile.is_empty() {
        String::new()
    } else {
        format!(" passfile={}", passfile)
    };
    format!(
        "host={} port={} user=replicator{} target_session_attrs=read-write application_name=node{}",
        hosts.join(","),
        ports.join(","),
        passfile_kw,
        node_id
    )
}

fn apply_setting(psql: &str, host: &str, port: &str, sql: &str) -> bool {
    apply::run_sql(psql, host, port, sql).is_ok()
        && apply::run_sql(psql, host, port, "SELECT pg_reload_conf()").is_ok()
}

#[pg_guard]
#[unsafe(no_mangle)]
pub extern "C-unwind" fn pg_replica_supervisor_main(_arg: pg_sys::Datum) {
    BackgroundWorker::attach_signal_handlers(SignalWakeFlags::SIGHUP | SignalWakeFlags::SIGTERM);

    // Set PGPASSFILE before spawning any threads/child psql so every libpq client we shell out
    // to (local control, peer LSN probe, rejoin) authenticates with SCRAM from the passfile.
    let auth_passfile = config::passfile();
    if !auth_passfile.is_empty() {
        std::env::set_var("PGPASSFILE", &auth_passfile);
    }

    let node_id = config::node_id() as u64;
    let port = config::raft_port() as u16;
    let peers = rpc::parse_peers(&config::peers());
    let voters: Vec<u64> = peers.iter().map(|peer| peer.id).collect();

    pgrx::log!(
        "pg_replica: supervisor started (node_id={}, raft_port={}, voters={:?})",
        node_id,
        port,
        voters
    );

    if node_id == 0 || voters.is_empty() {
        pgrx::log!("pg_replica: not configured (node_id/peers unset); idling");
        while BackgroundWorker::wait_latch(Some(Duration::from_secs(10))) {}
        return;
    }

    let pg_members = rpc::parse_peers(&config::pg_addrs());
    let raft_dir = config::raft_dir();
    config::apply_user();
    config::apply_db();

    let mut config_errors: Vec<String> = Vec::new();
    let mut seen_voters = std::collections::HashSet::new();
    for voter in &voters {
        if !seen_voters.insert(*voter) {
            config_errors.push(format!("duplicate node id {} in pg_replica.peers", voter));
        }
    }
    let mut seen_members = std::collections::HashSet::new();
    for member in &pg_members {
        if !seen_members.insert(member.id) {
            config_errors.push(format!("duplicate node id {} in pg_replica.pg_addrs", member.id));
        }
    }
    if !voters.contains(&node_id) {
        config_errors.push(format!("pg_replica.peers has no entry for this node (node_id={})", node_id));
    }
    if !pg_members.iter().any(|member| member.id == node_id) {
        config_errors.push(format!("pg_replica.pg_addrs has no entry for this node (node_id={})", node_id));
    }
    if raft_dir.is_empty() {
        config_errors.push(String::from(
            "pg_replica.raft_dir is unset; it must point at durable node-local storage outside the data directory (never /tmp)",
        ));
    }
    if !config_errors.is_empty() {
        for error in &config_errors {
            pgrx::log!("pg_replica: config error: {}", error);
        }
        pgrx::log!("pg_replica: invalid configuration; idling");
        while BackgroundWorker::wait_latch(Some(Duration::from_secs(10))) {}
        return;
    }
    for voter in &voters {
        if !pg_members.iter().any(|member| member.id == *voter) {
            pgrx::log!(
                "pg_replica: warning: pg_replica.pg_addrs has no entry for peer {}; cannot repoint standbys at it",
                voter
            );
        }
    }

    let psql = config::psql();
    let pgbin = apply::parent_dir(&psql);
    let rejoin_script = config::rejoin_script();
    let passfile = config::passfile();
    let (my_host, my_port) = apply::split_host_port(
        &pg_members
            .iter()
            .find(|member| member.id == node_id)
            .map(|member| member.addr.clone())
            .unwrap_or_default(),
    );

    let majority = voters.len() / 2 + 1;
    let sync_quorum = majority.saturating_sub(1);
    let sync_target = if sync_quorum >= 1 {
        let names: Vec<String> = voters
            .iter()
            .filter(|&&voter| voter != node_id)
            .map(|voter| format!("node{}", voter))
            .collect();
        format!("ANY {} ({})", sync_quorum, names.join(", "))
    } else {
        String::new()
    };
    let synchronous = config::synchronous();
    let heartbeat_file = format!("{}/pg_replica_hb_{}", raft_dir, node_id);
    let watchdog_script = config::watchdog_script();
    let apply_user = config::apply_user();
    if !watchdog_script.is_empty() {
        if apply::spawn_watchdog(
            &watchdog_script,
            &psql,
            &my_host,
            &my_port,
            &heartbeat_file,
            node_id,
            &apply_user,
        ) {
            pgrx::log!("pg_replica: node {} deadman watchdog spawned", node_id);
        }
    }

    let compact_threshold = config::compact_threshold().max(1) as u64;
    let raft_peers: Vec<(u64, String)> =
        peers.iter().map(|peer| (peer.id, peer.addr.clone())).collect();
    let handle =
        match raft_node::RaftHandle::start(node_id, port, &raft_peers, &raft_dir, compact_threshold)
        {
            Ok(handle) => handle,
            Err(error) => {
                pgrx::log!("pg_replica: raft start failed on {}: {}", port, error);
                return;
            }
        };
    handle.bootstrap();
    pgrx::log!(
        "pg_replica: node {} openraft started (raft_port={}, members={:?})",
        node_id,
        port,
        voters
    );
    let mut last = String::new();
    let mut peers_lsn: HashMap<u64, (u64, bool, Instant)> = HashMap::new();
    let mut last_heard: HashMap<u64, Instant> = HashMap::new();
    let mut peers_reconfirm: HashMap<u64, bool> = HashMap::new();
    let mut peers_seq: HashMap<u64, u64> = HashMap::new();
    let mut reconfirm_pending = false;
    let mut decided: Option<failover::Decision> = handle.current_decision();
    let mut last_proposed: (u64, u64) = (0, 0);
    let mut last_proposed_tick: u64 = 0;
    let mut promoted = false;
    let mut promote_tick: u64 = 0;
    let mut rejoining = false;
    let mut applied_primary: u64 = 0;
    let mut slots_ensured = false;
    let mut applied_read_only: Option<bool> = None;
    let mut applied_sync: Option<String> = None;
    let mut authorized_since: Option<Instant> = None;
    let mut datadir: Option<String> = None;
    let mut cluster_marker = false;
    let mut ticks: u64 = 0;
    let gossip_every: u64 = 5;
    let dead_timeout = Duration::from_millis(2500);
    let confirm_window = Duration::from_millis(1500);
    let quorum_lease = Duration::from_millis(1200);
    let stall_threshold = Duration::from_millis(1500);
    let mut last_loop = Instant::now();

    while BackgroundWorker::wait_latch(Some(Duration::from_millis(100))) {
        let loop_now = Instant::now();
        if loop_now.duration_since(last_loop) > stall_threshold {
            applied_read_only = None;
            authorized_since = None;
            reconfirm_pending = true;
        }
        last_loop = loop_now;
        apply::write_heartbeat(&heartbeat_file);
        if !watchdog_script.is_empty() && ticks % 50 == 49 {
            apply::spawn_watchdog(
                &watchdog_script,
                &psql,
                &my_host,
                &my_port,
                &heartbeat_file,
                node_id,
                &apply_user,
            );
        }

        while let Some((from, payload)) = handle.try_recv_gossip() {
            last_heard.insert(from, Instant::now());
            if let Some(gossip) = failover::decode_gossip(&payload) {
                peers_lsn.insert(from, (gossip.lsn, gossip.in_recovery, Instant::now()));
                peers_reconfirm.insert(from, gossip.reconfirm);
                let known_seq = peers_seq.entry(from).or_insert(0);
                *known_seq = (*known_seq).max(gossip.seq);
            }
        }

        if let Some(decision) = handle.current_decision() {
            if decided.map_or(true, |current| decision != current) {
                decided = Some(decision);
                promoted = false;
                rejoining = false;
                applied_primary = 0;
                slots_ensured = false;
                reconfirm_pending = false;
                last_proposed = (0, 0);
                pgrx::log!(
                    "pg_replica: node {} DECISION seq={} primary={}",
                    node_id,
                    decision.seq,
                    decision.primary
                );
            }
        }

        let in_recovery = unsafe { pg_sys::RecoveryInProgress() };
        let decided_seq = decided.map(|decision| decision.seq).unwrap_or(0);

        ticks += 1;
        let my_lsn = local_wal_lsn(in_recovery);
        peers_lsn.insert(node_id, (my_lsn, in_recovery, Instant::now()));
        if ticks % gossip_every == 0 {
            let payload =
                failover::encode_gossip(my_lsn, in_recovery, reconfirm_pending, decided_seq);
            handle.gossip_broadcast(node_id, &payload);
        }

        if datadir.is_none() && ticks % 20 == 1 {
            if let Ok(dir) = apply::run_sql(&psql, &my_host, &my_port, "SHOW data_directory") {
                if !dir.is_empty() {
                    cluster_marker =
                        std::path::Path::new(&dir).join("pg_replica_cluster").exists();
                    datadir = Some(dir);
                }
            }
        }
        if !cluster_marker && decided.is_some() {
            if let Some(dir) = &datadir {
                let marker = std::path::Path::new(dir).join("pg_replica_cluster");
                if std::fs::write(&marker, b"1").is_ok() {
                    cluster_marker = true;
                }
            }
        }

        let live_now = Instant::now();
        let live: Vec<(u64, u64, bool)> = peers_lsn
            .iter()
            .filter(|(id, (_, _, seen))| {
                **id == node_id || live_now.duration_since(*seen) < dead_timeout
            })
            .map(|(id, (lsn, recovery, _))| (*id, *lsn, *recovery))
            .collect();
        let genesis_winner = failover::choose_primary(&live);
        let cluster_seq = peers_seq.values().copied().max().unwrap_or(0);

        if handle.is_leader() {
            let current_primary = decided.map(|decision| decision.primary).unwrap_or(0);
            let primary_alive = current_primary != 0
                && match live.iter().find(|c| c.0 == current_primary) {
                    Some(p) => !(p.2 && live.iter().any(|o| o.1 > p.1)),
                    None => false,
                };
            let needs_reconfirm = reconfirm_pending
                || live
                    .iter()
                    .any(|member| peers_reconfirm.get(&member.0).copied().unwrap_or(false));

            let candidate = if decided.is_none() {
                genesis_winner
            } else if !primary_alive {
                let psql_ref = &psql;
                let my_host_ref = &my_host;
                let my_port_ref = &my_port;
                let pg_members_ref = &pg_members;
                let fresh: Vec<(u64, u64, bool)> = std::thread::scope(|scope| {
                    let probes: Vec<_> = live
                        .iter()
                        .map(|&(id, gossiped, in_rec)| {
                            scope.spawn(move || {
                                let lsn = if id == node_id {
                                    apply::wal_lsn(psql_ref, my_host_ref, my_port_ref, in_recovery)
                                } else if let Some(member) =
                                    pg_members_ref.iter().find(|member| member.id == id)
                                {
                                    let (host, port) = apply::split_host_port(&member.addr);
                                    apply::peer_wal_lsn(psql_ref, &host, &port).unwrap_or(gossiped)
                                } else {
                                    gossiped
                                };
                                (id, lsn, in_rec)
                            })
                        })
                        .collect();
                    probes
                        .into_iter()
                        .filter_map(|probe| probe.join().ok())
                        .collect()
                });
                failover::choose_primary(&fresh)
            } else if needs_reconfirm {
                Some(current_primary)
            } else {
                None
            };

            if live.len() >= majority {
                if let Some(candidate) = candidate {
                    let seq = decided_seq + 1;
                    let in_flight = last_proposed.0 == seq
                        && ticks.saturating_sub(last_proposed_tick) < 20;
                    if !in_flight {
                        let decision = failover::Decision {
                            seq,
                            primary: candidate,
                        };
                        handle.propose(decision);
                        last_proposed = (seq, candidate);
                        last_proposed_tick = ticks;
                        pgrx::log!(
                            "pg_replica: node {} PROPOSE seq={} primary={} live={:?}",
                            node_id,
                            seq,
                            candidate,
                            live
                        );
                    }
                }
            }
        }

        let decided_primary = decided.map(|decision| decision.primary).unwrap_or(0);
        let contact_now = Instant::now();
        let reachable = last_heard
            .iter()
            .filter(|(id, seen)| {
                **id != node_id && contact_now.duration_since(**seen) < quorum_lease
            })
            .count();
        let quorum_ok = 1 + reachable >= majority;

        if in_recovery {
            applied_read_only = None;
            authorized_since = None;
            if applied_sync.as_deref() != Some("") {
                if apply_setting(
                    &psql,
                    &my_host,
                    &my_port,
                    "ALTER SYSTEM SET synchronous_standby_names = ''",
                ) {
                    applied_sync = Some(String::new());
                }
            }
            if decided_primary == node_id {
                if promoted && ticks.saturating_sub(promote_tick) >= 100 {
                    pgrx::log!(
                        "pg_replica: node {} still in recovery after pg_promote; retrying",
                        node_id
                    );
                    promoted = false;
                }
                if !promoted {
                    pgrx::log!(
                        "pg_replica: node {} APPLY promote (standby -> primary, fenced until authorized)",
                        node_id
                    );
                    let _ = apply::run_sql(
                        &psql,
                        &my_host,
                        &my_port,
                        "ALTER SYSTEM SET default_transaction_read_only = on",
                    );
                    let _ = apply::run_sql(&psql, &my_host, &my_port, "SELECT pg_reload_conf()");
                    match apply::run_sql(&psql, &my_host, &my_port, "SELECT pg_promote(false)") {
                        Ok(_) => {
                            promoted = true;
                            promote_tick = ticks;
                        }
                        Err(error) => {
                            pgrx::log!("pg_replica: node {} promote failed: {}", node_id, error)
                        }
                    }
                }
            } else if decided_primary != 0 && applied_primary != decided_primary {
                if let Some(member) = pg_members.iter().find(|member| member.id == decided_primary) {
                    let conninfo = standby_conninfo(&pg_members, &passfile, node_id);
                    pgrx::log!(
                        "pg_replica: node {} APPLY repoint standby -> primary {} ({})",
                        node_id,
                        decided_primary,
                        member.addr
                    );
                    if apply_setting(
                        &psql,
                        &my_host,
                        &my_port,
                        &format!("ALTER SYSTEM SET primary_conninfo = '{}'", conninfo),
                    ) {
                        applied_primary = decided_primary;
                    }
                }
            }
        } else {
            if decided_primary == node_id && !slots_ensured {
                for member in &pg_members {
                    if member.id != node_id {
                        let _ = apply::run_sql(
                            &psql,
                            &my_host,
                            &my_port,
                            &format!(
                                "SELECT pg_create_physical_replication_slot('node{}', true) WHERE NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = 'node{}')",
                                member.id, member.id
                            ),
                        );
                    }
                }
                slots_ensured = true;
            }
            let raw_auth = match decided {
                None => {
                    quorum_ok
                        && cluster_seq == 0
                        && !cluster_marker
                        && genesis_winner == Some(node_id)
                }
                Some(decision) => {
                    decision.primary == node_id && quorum_ok && !reconfirm_pending
                }
            };
            let authorized = if !raw_auth {
                authorized_since = None;
                false
            } else if decided.is_none() || applied_read_only == Some(false) {
                authorized_since = Some(Instant::now());
                true
            } else {
                let since = *authorized_since.get_or_insert_with(Instant::now);
                Instant::now().duration_since(since) >= confirm_window
            };
            // want_sync = None means LEAVE synchronous_standby_names unchanged: critical for a
            // primary that is losing authority while a sync commit is in flight — clearing it
            // would let Postgres complete that commit LOCALLY (false ack) and then rewind it away.
            // Set it only when authorized; clear it only when sync is globally off (no in-flight
            // sync commits to mis-ack). Standbys clear it in the in_recovery branch.
            let want_sync: Option<&str> = if !synchronous {
                Some("")
            } else if authorized && decided.is_some() {
                Some(sync_target.as_str())
            } else {
                None
            };
            let want_read_only = !authorized;

            // Invariant: a writable primary always has sync configured. So fence first
            // (always safe), then (re)configure sync, then unfence last — never a window
            // where read_only=off but synchronous_standby_names is stale/empty.
            if want_read_only && applied_read_only != Some(true) {
                if apply_setting(
                    &psql,
                    &my_host,
                    &my_port,
                    "ALTER SYSTEM SET default_transaction_read_only = on",
                ) {
                    applied_read_only = Some(true);
                    pgrx::log!(
                        "pg_replica: node {} FENCE -> read-only (decided_primary={} quorum_ok={})",
                        node_id,
                        decided_primary,
                        quorum_ok
                    );
                }
            }
            if let Some(want_sync) = want_sync {
                if applied_sync.as_deref() != Some(want_sync) {
                    if apply_setting(
                        &psql,
                        &my_host,
                        &my_port,
                        &format!("ALTER SYSTEM SET synchronous_standby_names = '{}'", want_sync),
                    ) {
                        applied_sync = Some(want_sync.to_string());
                        pgrx::log!(
                            "pg_replica: node {} synchronous_standby_names = '{}'",
                            node_id,
                            want_sync
                        );
                    }
                }
            }
            if !want_read_only && applied_read_only != Some(false) {
                if apply_setting(
                    &psql,
                    &my_host,
                    &my_port,
                    "ALTER SYSTEM SET default_transaction_read_only = off",
                ) {
                    applied_read_only = Some(false);
                    pgrx::log!(
                        "pg_replica: node {} UNFENCE -> read-write (decided_primary={} quorum_ok={})",
                        node_id,
                        decided_primary,
                        quorum_ok
                    );
                }
            }

            if !authorized
                && decided_primary != 0
                && decided_primary != node_id
                && !rejoining
                && !rejoin_script.is_empty()
            {
                if let Some(member) = pg_members.iter().find(|member| member.id == decided_primary) {
                    let (primary_host, primary_port) = apply::split_host_port(&member.addr);
                    let datadir = datadir.clone().unwrap_or_else(|| {
                        apply::run_sql(&psql, &my_host, &my_port, "SHOW data_directory")
                            .unwrap_or_default()
                    });
                    if !datadir.is_empty() {
                        pgrx::log!(
                            "pg_replica: node {} REJOIN spawn (rewind against primary {} {})",
                            node_id,
                            decided_primary,
                            member.addr
                        );
                        apply::spawn_rejoin(
                            &rejoin_script,
                            &pgbin,
                            &datadir,
                            &primary_host,
                            &primary_port,
                            node_id,
                            &passfile,
                            &standby_conninfo(&pg_members, &passfile, node_id),
                        );
                        rejoining = true;
                    }
                }
            }
        }

        let repl = if decided_primary == node_id {
            String::from("primary")
        } else if decided_primary != 0 {
            match pg_members.iter().find(|member| member.id == decided_primary) {
                Some(member) => format!("standby<-{}", member.addr),
                None => String::from("standby<-?"),
            }
        } else {
            String::from("bootstrap")
        };

        let snapshot = format!(
            "{} term={} leader={} decided_primary={} seq={} quorum={} read_only={} reconfirm={} | repl={} in_recovery={}",
            handle.role_name(),
            handle.term(),
            handle.leader_id(),
            decided_primary,
            decided_seq,
            quorum_ok,
            applied_read_only == Some(true),
            reconfirm_pending,
            repl,
            in_recovery
        );
        if snapshot != last {
            pgrx::log!("pg_replica: node {} -> {}", node_id, snapshot);
            state::write(node_id, &snapshot);
            last = snapshot;
        }
    }

    handle.shutdown();
    state::write(node_id, "stopped");
    pgrx::log!("pg_replica: supervisor shutting down");
}

#[pg_schema]
mod replica {
    use pgrx::prelude::*;

    #[pg_extern]
    fn status() -> String {
        let node_id = crate::config::node_id();
        let live = crate::state::read(node_id as u64)
            .unwrap_or_else(|| String::from("consensus not started"));
        format!(
            "pg_replica node_id={} raft_port={} peers=[{}] | {}",
            node_id,
            crate::config::raft_port(),
            crate::config::peers(),
            live
        )
    }
}

#[cfg(any(test, feature = "pg_test"))]
#[pg_schema]
mod tests {
    use pgrx::prelude::*;

    #[pg_test]
    fn status_is_reported() {
        let reported = Spi::get_one::<String>("SELECT replica.status()")
            .expect("SPI failed")
            .expect("status() returned NULL");
        assert!(reported.contains("node_id="));
    }
}

#[cfg(test)]
pub mod pg_test {
    pub fn setup(_options: Vec<&str>) {}

    pub fn postgresql_conf_options() -> Vec<&'static str> {
        vec!["shared_preload_libraries = 'pg_replica'"]
    }
}
