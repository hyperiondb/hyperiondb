use pgrx::guc::{GucContext, GucFlags, GucRegistry, GucSetting};
use std::ffi::CString;
use std::sync::OnceLock;

static APPLY_USER_CACHE: OnceLock<String> = OnceLock::new();
static APPLY_DB_CACHE: OnceLock<String> = OnceLock::new();
static PASSFILE_CACHE: OnceLock<String> = OnceLock::new();

pub static SYNCHRONOUS: GucSetting<bool> = GucSetting::<bool>::new(false);
pub static NODE_ID: GucSetting<i32> = GucSetting::<i32>::new(0);
pub static RAFT_PORT: GucSetting<i32> = GucSetting::<i32>::new(7400);
pub static COMPACT_THRESHOLD: GucSetting<i32> = GucSetting::<i32>::new(64);
pub static PEERS: GucSetting<Option<CString>> = GucSetting::<Option<CString>>::new(None);
pub static PG_ADDRS: GucSetting<Option<CString>> = GucSetting::<Option<CString>>::new(None);
pub static PSQL: GucSetting<Option<CString>> = GucSetting::<Option<CString>>::new(None);
pub static REJOIN_SCRIPT: GucSetting<Option<CString>> = GucSetting::<Option<CString>>::new(None);
pub static WATCHDOG_SCRIPT: GucSetting<Option<CString>> = GucSetting::<Option<CString>>::new(None);
pub static PASSFILE: GucSetting<Option<CString>> = GucSetting::<Option<CString>>::new(None);
pub static RAFT_DIR: GucSetting<Option<CString>> = GucSetting::<Option<CString>>::new(None);
pub static APPLY_USER: GucSetting<Option<CString>> = GucSetting::<Option<CString>>::new(None);
pub static APPLY_DB: GucSetting<Option<CString>> = GucSetting::<Option<CString>>::new(None);
pub static APPLY_ADDR: GucSetting<Option<CString>> = GucSetting::<Option<CString>>::new(None);

pub fn init() {
    GucRegistry::define_bool_guc(
        c"pg_replica.synchronous",
        c"Quorum-synchronous replication: withhold COMMIT ack until a quorum of standbys has the WAL.",
        c"When on, the primary maintains synchronous_standby_names = 'ANY <majority-1> (peers)' so every acked transaction is on a majority of nodes (zero loss on failover). Off = async.",
        &SYNCHRONOUS,
        GucContext::Postmaster,
        GucFlags::default(),
    );

    GucRegistry::define_int_guc(
        c"pg_replica.node_id",
        c"This node's Raft id, unique across the cluster.",
        c"A positive integer set in postgresql.conf. 0 means unconfigured.",
        &NODE_ID,
        0,
        i32::MAX,
        GucContext::Postmaster,
        GucFlags::default(),
    );

    GucRegistry::define_int_guc(
        c"pg_replica.compact_threshold",
        c"Compact the Raft log once this many applied entries accumulate past the snapshot.",
        c"Folds the applied log into a snapshot (data = latest decision) to bound log/disk growth.",
        &COMPACT_THRESHOLD,
        1,
        i32::MAX,
        GucContext::Postmaster,
        GucFlags::default(),
    );

    GucRegistry::define_int_guc(
        c"pg_replica.raft_port",
        c"TCP port the Raft peer transport listens on.",
        c"Each node binds this port for peer-to-peer consensus traffic.",
        &RAFT_PORT,
        1,
        65535,
        GucContext::Postmaster,
        GucFlags::default(),
    );

    GucRegistry::define_string_guc(
        c"pg_replica.peers",
        c"Cluster members as a comma-separated id@host:port list.",
        c"Example: 1@10.0.0.1:7400,2@10.0.0.2:7400,3@10.0.0.3:7400",
        &PEERS,
        GucContext::Postmaster,
        GucFlags::default(),
    );

    GucRegistry::define_string_guc(
        c"pg_replica.pg_addrs",
        c"Each node's Postgres host:port as id@host:port (used to build primary_conninfo).",
        c"Example: 1@10.0.0.1:5432,2@10.0.0.2:5432,3@10.0.0.3:5432",
        &PG_ADDRS,
        GucContext::Postmaster,
        GucFlags::default(),
    );

    GucRegistry::define_string_guc(
        c"pg_replica.psql",
        c"Path to the psql client used to apply promote/repoint actions.",
        c"Defaults to 'psql' on PATH.",
        &PSQL,
        GucContext::Postmaster,
        GucFlags::default(),
    );

    GucRegistry::define_string_guc(
        c"pg_replica.rejoin_script",
        c"Path to a detached helper that rewinds+rejoins a deposed primary as a standby.",
        c"Receives: pgbin datadir leader_host leader_port node_id. Empty disables rejoin (fence only).",
        &REJOIN_SCRIPT,
        GucContext::Postmaster,
        GucFlags::default(),
    );

    GucRegistry::define_string_guc(
        c"pg_replica.watchdog_script",
        c"Path to a detached deadman watchdog that fences this node read-only if the control plane stalls.",
        c"Receives: psql host port heartbeat_file node_id apply_user. Empty disables the watchdog.",
        &WATCHDOG_SCRIPT,
        GucContext::Postmaster,
        GucFlags::default(),
    );

    GucRegistry::define_string_guc(
        c"pg_replica.passfile",
        c"Path to a libpq passfile (chmod 600) holding the replicator password for streaming replication.",
        c"Referenced as passfile= in primary_conninfo and PGPASSFILE for pg_basebackup, so the password is never written into postgresql.conf or auto.conf. Empty = no replication auth (trust).",
        &PASSFILE,
        GucContext::Postmaster,
        GucFlags::default(),
    );

    GucRegistry::define_string_guc(
        c"pg_replica.raft_dir",
        c"Directory holding this node's durable Raft state (term/vote/log). Required.",
        c"Must be node-local, on durable storage that survives reboots (never /tmp), and outside the Postgres data directory so base backups and pg_rewind never clone it. The supervisor refuses to start while unset.",
        &RAFT_DIR,
        GucContext::Postmaster,
        GucFlags::default(),
    );

    GucRegistry::define_string_guc(
        c"pg_replica.apply_user",
        c"Superuser role psql connects as to apply promote/fence/repoint/reload actions on the local node.",
        c"Needs a matching entry in pg_replica.passfile. Empty falls back to the POSTGRES_USER environment variable, then 'postgres'.",
        &APPLY_USER,
        GucContext::Postmaster,
        GucFlags::default(),
    );

    GucRegistry::define_string_guc(
        c"pg_replica.apply_addr",
        c"host:port psql connects to for local apply actions (promote/fence/repoint/reload).",
        c"Must reach the LOCAL Postgres from wherever the supervisor runs. Empty defaults to 127.0.0.1 with this node's pg_replica.pg_addrs port — the node's advertised address is often unreachable from inside its own container (Docker published-port hairpin).",
        &APPLY_ADDR,
        GucContext::Postmaster,
        GucFlags::default(),
    );

    GucRegistry::define_string_guc(
        c"pg_replica.apply_db",
        c"Database psql connects to when applying control-plane actions on the local node.",
        c"Any database the apply_user can connect to; the SQL is cluster-global. Empty falls back to the POSTGRES_DB environment variable, then 'postgres'.",
        &APPLY_DB,
        GucContext::Postmaster,
        GucFlags::default(),
    );
}

pub fn node_id() -> i32 {
    NODE_ID.get()
}

pub fn synchronous() -> bool {
    SYNCHRONOUS.get()
}

pub fn raft_port() -> i32 {
    RAFT_PORT.get()
}

pub fn compact_threshold() -> i32 {
    COMPACT_THRESHOLD.get()
}

pub fn peers() -> String {
    PEERS
        .get()
        .map(|value| value.to_string_lossy().into_owned())
        .unwrap_or_default()
}

pub fn pg_addrs() -> String {
    PG_ADDRS
        .get()
        .map(|value| value.to_string_lossy().into_owned())
        .unwrap_or_default()
}

pub fn psql() -> String {
    PSQL
        .get()
        .map(|value| value.to_string_lossy().into_owned())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| String::from("psql"))
}

pub fn rejoin_script() -> String {
    REJOIN_SCRIPT
        .get()
        .map(|value| value.to_string_lossy().into_owned())
        .unwrap_or_default()
}

pub fn watchdog_script() -> String {
    WATCHDOG_SCRIPT
        .get()
        .map(|value| value.to_string_lossy().into_owned())
        .unwrap_or_default()
}

pub fn passfile() -> String {
    PASSFILE_CACHE
        .get_or_init(|| {
            PASSFILE
                .get()
                .map(|value| value.to_string_lossy().into_owned())
                .unwrap_or_default()
        })
        .clone()
}

pub fn raft_dir() -> String {
    RAFT_DIR
        .get()
        .map(|value| value.to_string_lossy().into_owned())
        .unwrap_or_default()
}

pub fn apply_user() -> String {
    APPLY_USER_CACHE
        .get_or_init(|| {
            APPLY_USER
                .get()
                .map(|value| value.to_string_lossy().into_owned())
                .filter(|value| !value.is_empty())
                .or_else(|| std::env::var("POSTGRES_USER").ok())
                .filter(|value| !value.is_empty())
                .unwrap_or_else(|| String::from("postgres"))
        })
        .clone()
}

pub fn apply_addr() -> String {
    APPLY_ADDR
        .get()
        .map(|value| value.to_string_lossy().into_owned())
        .unwrap_or_default()
}

pub fn apply_db() -> String {
    APPLY_DB_CACHE
        .get_or_init(|| {
            APPLY_DB
                .get()
                .map(|value| value.to_string_lossy().into_owned())
                .filter(|value| !value.is_empty())
                .or_else(|| std::env::var("POSTGRES_DB").ok())
                .filter(|value| !value.is_empty())
                .unwrap_or_else(|| String::from("postgres"))
        })
        .clone()
}
