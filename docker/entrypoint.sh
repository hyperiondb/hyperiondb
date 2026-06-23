#!/usr/bin/env bash
# Per-node entrypoint for the pg_replica + ParadeDB integration cluster.
# Node 1 seeds (initdb + roles + extensions); nodes 2/3 pg_basebackup from it.
# All inter-node + client auth is SCRAM (no trust). pg_replica drives failover.
set -euo pipefail

PGDATA="${PGDATA:-/var/lib/postgresql/data}"
PGBIN="$(pg_config --bindir)"
PASSFILE=/var/lib/postgresql/.pgpass

: "${NODE_ID:?NODE_ID required}"
: "${RAFT_PORT:=7400}"
: "${PEERS:?PEERS required}"
: "${PG_ADDRS:?PG_ADDRS required}"
: "${SEED_HOST:=node1}"
: "${SU_PASSWORD:?SU_PASSWORD required}"
: "${REPL_PASSWORD:?REPL_PASSWORD required}"
: "${APP_USER:=weido}"
: "${APP_PASSWORD:=weido_pw}"
: "${APP_DB:=weido}"
: "${SYNCHRONOUS:=off}"
: "${WAL_KEEP:=512MB}"
: "${MAX_WAL:=1GB}"
: "${COMPACT_THRESHOLD:=64}"
: "${RAFT_DIR:=/var/lib/postgresql/raft}"
: "${MAX_SLOT_WAL_KEEP:=1GB}"

# Running as root (image default): fix ownership, then drop to the postgres user.
if [ "$(id -u)" = '0' ]; then
  mkdir -p "$PGDATA" "$RAFT_DIR"
  chown -R postgres:postgres "$(dirname "$PGDATA")" "$RAFT_DIR" /opt/pg_replica
  exec gosu postgres "$0" "$@"
fi

mkdir -p "$RAFT_DIR"

write_passfile() {
  {
    printf '*:*:*:replicator:%s\n' "$REPL_PASSWORD"
    printf '*:*:*:postgres:%s\n'   "$SU_PASSWORD"
  } > "$PASSFILE"
  chmod 600 "$PASSFILE"
}

node_conf() {
  cat >> "$PGDATA/postgresql.conf" <<EOF

listen_addresses = '*'
cluster_name = 'node$NODE_ID'
wal_level = replica
max_wal_senders = 10
max_replication_slots = 10
hot_standby = on
wal_log_hints = on
wal_keep_size = '$WAL_KEEP'
max_wal_size = '$MAX_WAL'
max_slot_wal_keep_size = '$MAX_SLOT_WAL_KEEP'
primary_slot_name = 'node$NODE_ID'
shared_preload_libraries = 'pg_search,pg_replica'
pg_replica.node_id = $NODE_ID
pg_replica.raft_port = $RAFT_PORT
pg_replica.peers = '$PEERS'
pg_replica.pg_addrs = '$PG_ADDRS'
pg_replica.psql = '$PGBIN/psql'
pg_replica.passfile = '$PASSFILE'
pg_replica.synchronous = $SYNCHRONOUS
pg_replica.compact_threshold = $COMPACT_THRESHOLD
pg_replica.raft_dir = '$RAFT_DIR'
pg_replica.rejoin_script = '/opt/pg_replica/rejoin.sh'
pg_replica.watchdog_script = '/opt/pg_replica/watchdog.sh'
EOF
}

# Cluster auth lives in pg_hba.conf, which sits INSIDE PGDATA. A data-volume wipe,
# pg_basebackup re-clone, or pg_rewind can therefore leave a node — including one that
# later gets promoted to primary — without the replication rule, and its replicas then
# loop forever on: no pg_hba.conf entry for replication connection ... user "replicator".
# pg_replica only manages primary_conninfo, never pg_hba, so nothing else repairs this.
# Re-assert the rules idempotently on every boot, before Postgres starts, for ALL nodes.
ensure_hba() {
  local hba="$PGDATA/pg_hba.conf"
  [ -f "$hba" ] || return 0
  grep -qE '^[[:space:]]*host[[:space:]]+replication[[:space:]]+all[[:space:]]+all[[:space:]]+scram-sha-256' "$hba" \
    || echo "host replication all all scram-sha-256" >> "$hba"
  grep -qE '^[[:space:]]*host[[:space:]]+all[[:space:]]+all[[:space:]]+all[[:space:]]+scram-sha-256' "$hba" \
    || echo "host all         all all scram-sha-256" >> "$hba"
}

write_passfile
export PGPASSFILE="$PASSFILE"

if [ ! -s "$PGDATA/PG_VERSION" ]; then
  if [ "$NODE_ID" = "1" ]; then
    echo "[node1] seeding: initdb (scram) + roles + extensions"
    (umask 077; printf '%s\n' "$SU_PASSWORD" > /tmp/su.pw)
    "$PGBIN/initdb" -D "$PGDATA" -U postgres -A scram-sha-256 --pwfile=/tmp/su.pw --locale=C.UTF-8 >/dev/null
    rm -f /tmp/su.pw
    ensure_hba
    node_conf

    "$PGBIN/pg_ctl" -D "$PGDATA" -o "-c listen_addresses=127.0.0.1" -w start >/dev/null
    "$PGBIN/psql" -h 127.0.0.1 -U postgres -d postgres -v ON_ERROR_STOP=1 \
      -v repl_pw="$REPL_PASSWORD" -v app_user="$APP_USER" -v app_pw="$APP_PASSWORD" \
      -v app_db="$APP_DB" >/dev/null <<'SQL'
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD :'repl_pw';
GRANT pg_monitor TO replicator;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_ls_dir(text, boolean, boolean) TO replicator;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_stat_file(text, boolean) TO replicator;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_binary_file(text) TO replicator;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_binary_file(text, bigint, bigint, boolean) TO replicator;
CREATE ROLE :"app_user" WITH LOGIN PASSWORD :'app_pw';
CREATE DATABASE :"app_db" OWNER :"app_user";
CREATE EXTENSION IF NOT EXISTS pg_replica;
CREATE TABLE IF NOT EXISTS demo (t text);
SQL
    for spec in $(echo "$PEERS" | tr ',' ' '); do
      pid="${spec%%@*}"
      [ "$pid" != "$NODE_ID" ] && "$PGBIN/psql" -h 127.0.0.1 -U postgres -d postgres -tAc \
        "SELECT pg_create_physical_replication_slot('node$pid', true)" >/dev/null 2>&1 || true
    done
    "$PGBIN/psql" -h 127.0.0.1 -U postgres -d "$APP_DB" -v ON_ERROR_STOP=1 \
      -c 'CREATE EXTENSION IF NOT EXISTS pg_search;' >/dev/null
    "$PGBIN/pg_ctl" -D "$PGDATA" -w stop >/dev/null
    echo "[node1] seed complete"
  else
    echo "[node$NODE_ID] waiting for seed $SEED_HOST, then pg_basebackup"
    until "$PGBIN/pg_isready" -h "$SEED_HOST" -p 5432 -U postgres -d postgres >/dev/null 2>&1; do sleep 2; done
    until "$PGBIN/pg_basebackup" -h "$SEED_HOST" -p 5432 -U replicator -D "$PGDATA" -X stream >/dev/null 2>&1; do
      echo "[node$NODE_ID] basebackup not ready (seed still seeding); retrying"; sleep 3
    done
    # basebackup cloned node1's config; override only the per-node identity.
    cat >> "$PGDATA/postgresql.conf" <<EOF

cluster_name = 'node$NODE_ID'
pg_replica.node_id = $NODE_ID
primary_slot_name = 'node$NODE_ID'
EOF
    echo "primary_conninfo = 'host=$SEED_HOST port=5432 user=replicator passfile=$PASSFILE application_name=node$NODE_ID'" \
      >> "$PGDATA/postgresql.auto.conf"
    touch "$PGDATA/standby.signal"
    echo "[node$NODE_ID] standby ready"
  fi
fi

# Every boot (not just first-time seed): repair pg_hba if a clone/rewind/wipe dropped the
# replication rule. No-op when already present. Must run before Postgres starts below.
ensure_hba

chmod 0700 "$PGDATA"

if [ -f /tmp/faketime ]; then
  FT_LIB="$(ls /usr/lib/*/faketime/libfaketime.so.1 2>/dev/null | head -1)"
  if [ -n "$FT_LIB" ]; then
    export LD_PRELOAD="$FT_LIB"
    export FAKETIME="$(cat /tmp/faketime)"
    echo "[node$NODE_ID] libfaketime active: FAKETIME=$FAKETIME"
  fi
fi

LOGFILE=/var/lib/postgresql/data.log
REJOIN_MARK=/tmp/pg_replica_rejoin_active
rm -f "$PGDATA/postmaster.pid"
touch "$LOGFILE"

graceful_stop() {
  "$PGBIN/pg_ctl" -D "$PGDATA" -m fast stop >/dev/null 2>&1 || true
  exit 0
}
trap graceful_stop TERM INT

"$PGBIN/pg_ctl" -D "$PGDATA" -l "$LOGFILE" -w -t 120 start || true

tail -F "$LOGFILE" &
TAIL_PID=$!

if [ "${PGR_SUPERVISE:-monitor}" = "hold" ]; then
  wait "$TAIL_PID"
else
  while :; do
    if ! "$PGBIN/pg_ctl" -D "$PGDATA" status >/dev/null 2>&1; then
      [ -f "$REJOIN_MARK" ] && { sleep 2; continue; }
      sleep 5
      "$PGBIN/pg_ctl" -D "$PGDATA" status >/dev/null 2>&1 && continue
      [ -f "$REJOIN_MARK" ] && continue
      echo "[node$NODE_ID] postgres down and no rejoin in progress; exiting so the container restart policy can recover it"
      kill "$TAIL_PID" 2>/dev/null || true
      exit 1
    fi
    sleep 3
  done
fi
