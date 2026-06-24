#!/usr/bin/env bash
# Per-node entrypoint for the pg_replica + ParadeDB integration cluster.
# Node 1 seeds (initdb + roles + extensions); nodes 2/3 pg_basebackup from it.
# All inter-node + client auth is SCRAM (no trust). pg_replica drives failover.
set -euo pipefail

PGDATA="${PGDATA:-/var/lib/postgresql/data}"
PGBIN="$(pg_config --bindir)"
PGCONF="${PGCONF:-/etc/postgresql/postgresql.conf}"
PASSFILE=/var/lib/postgresql/.pgpass
RAFT_DIR="${RAFT_DIR:-/var/lib/postgresql/raft}"

: "${NODE_ID:?NODE_ID required}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD required}"
: "${REPL_PASS:?REPL_PASS required}"

# Running as root (image default): fix ownership, then drop to the postgres user.
if [ "$(id -u)" = '0' ]; then
  mkdir -p "$PGDATA" "$RAFT_DIR"
  chown -R postgres:postgres "$(dirname "$PGDATA")" "$RAFT_DIR" /opt/pg_replica
  exec gosu postgres "$0" "$@"
fi

mkdir -p "$RAFT_DIR"

write_passfile() {
  {
    printf '*:*:*:replicator:%s\n' "$REPL_PASS"
    printf '*:*:*:postgres:%s\n'   "$POSTGRES_PASSWORD"
  } > "$PASSFILE"
  chmod 600 "$PASSFILE"
}

members() {
  if [ -n "${PG_ADDRS:-}" ]; then printf '%s' "$PG_ADDRS"; return 0; fi
  [ -f "$PGCONF" ] || return 0
  sed -n "s/^[[:space:]]*pg_replica\.pg_addrs[[:space:]]*=[[:space:]]*'\([^']*\)'.*/\1/p" "$PGCONF" | head -1
}

node_conf() {
  {
    echo ""
    echo "include '$PGCONF'"
    echo "cluster_name = 'node$NODE_ID'"
    echo "primary_slot_name = 'node$NODE_ID'"
    echo "pg_replica.node_id = $NODE_ID"
    echo "pg_replica.psql = '$PGBIN/psql'"
    [ -n "${SYNCHRONOUS:-}" ]       && echo "pg_replica.synchronous = $SYNCHRONOUS"
    [ -n "${COMPACT_THRESHOLD:-}" ] && echo "pg_replica.compact_threshold = $COMPACT_THRESHOLD"
    [ -n "${WAL_KEEP:-}" ]          && echo "wal_keep_size = '$WAL_KEEP'"
    [ -n "${MAX_WAL:-}" ]           && echo "max_wal_size = '$MAX_WAL'"
    true
  } >> "$PGDATA/postgresql.conf"
}

ensure_hba() {
  local hba="$PGDATA/pg_hba.conf"
  [ -f "$hba" ] || return 0
  grep -qE '^[[:space:]]*host[[:space:]]+replication[[:space:]]+all[[:space:]]+all[[:space:]]+scram-sha-256' "$hba" \
    || echo "host replication all all scram-sha-256" >> "$hba"
  grep -qE '^[[:space:]]*host[[:space:]]+all[[:space:]]+all[[:space:]]+all[[:space:]]+scram-sha-256' "$hba" \
    || echo "host all         all all scram-sha-256" >> "$hba"
}

find_primary() {
  local spec id hostport host port
  for spec in $(members | tr ',' ' '); do
    id="${spec%%@*}"; hostport="${spec#*@}"; host="${hostport%%:*}"; port="${hostport##*:}"
    [ "$id" = "$NODE_ID" ] && continue
    "$PGBIN/pg_isready" -h "$host" -p "$port" -q >/dev/null 2>&1 || continue
    [ "$(PGPASSFILE="$PASSFILE" "$PGBIN/psql" -h "$host" -p "$port" -U replicator -d postgres -tAc 'SELECT NOT pg_is_in_recovery()' 2>/dev/null | tr -d '[:space:]')" = "t" ] || continue
    echo "$host $port"; return 0
  done
  return 1
}

any_peer_up() {
  local spec id hostport host port
  for spec in $(members | tr ',' ' '); do
    id="${spec%%@*}"; hostport="${spec#*@}"; host="${hostport%%:*}"; port="${hostport##*:}"
    [ "$id" = "$NODE_ID" ] && continue
    "$PGBIN/pg_isready" -h "$host" -p "$port" -q >/dev/null 2>&1 && return 0
  done
  return 1
}

clone_standby() {
  local src_host="$1" src_port="$2"
  echo "[node$NODE_ID] cloning from primary $src_host:$src_port via pg_basebackup"
  until "$PGBIN/pg_basebackup" -h "$src_host" -p "$src_port" -U replicator -D "$PGDATA" -X stream >/dev/null 2>&1; do
    echo "[node$NODE_ID] basebackup not ready; retrying"; sleep 3
  done
  cat >> "$PGDATA/postgresql.conf" <<EOF

cluster_name = 'node$NODE_ID'
pg_replica.node_id = $NODE_ID
primary_slot_name = 'node$NODE_ID'
EOF
  echo "primary_conninfo = 'host=$src_host port=$src_port user=replicator passfile=$PASSFILE application_name=node$NODE_ID'" >> "$PGDATA/postgresql.auto.conf"
  touch "$PGDATA/standby.signal"
  echo "[node$NODE_ID] standby ready (cloned from $src_host:$src_port)"
}

seed_primary() {
  echo "[node1] seeding: initdb (scram) + roles + extensions"
  (umask 077; printf '%s\n' "$POSTGRES_PASSWORD" > /tmp/su.pw)
  "$PGBIN/initdb" -D "$PGDATA" -U postgres -A scram-sha-256 --pwfile=/tmp/su.pw --locale=C.UTF-8 >/dev/null
  rm -f /tmp/su.pw
  ensure_hba
  node_conf

  "$PGBIN/pg_ctl" -D "$PGDATA" -o "-c listen_addresses=127.0.0.1" -w start >/dev/null
  "$PGBIN/psql" -h 127.0.0.1 -U postgres -d postgres -v ON_ERROR_STOP=1 \
    -v repl_pw="$REPL_PASS" >/dev/null <<'SQL'
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD :'repl_pw';
GRANT pg_monitor TO replicator;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_ls_dir(text, boolean, boolean) TO replicator;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_stat_file(text, boolean) TO replicator;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_binary_file(text) TO replicator;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_binary_file(text, bigint, bigint, boolean) TO replicator;
CREATE EXTENSION IF NOT EXISTS pg_replica;
CREATE TABLE IF NOT EXISTS demo (t text);
SQL
  for spec in $(members | tr ',' ' '); do
    pid="${spec%%@*}"
    [ "$pid" != "$NODE_ID" ] && "$PGBIN/psql" -h 127.0.0.1 -U postgres -d postgres -tAc \
      "SELECT pg_create_physical_replication_slot('node$pid', true)" >/dev/null 2>&1 || true
  done
  "$PGBIN/pg_ctl" -D "$PGDATA" -w stop >/dev/null
  echo "[node1] seed complete"
}

write_passfile
export PGPASSFILE="$PASSFILE"

if [ ! -s "$PGDATA/PG_VERSION" ]; then
  src_host=""; src_port=""; saw_peer=0; i=0
  while :; do
    i=$((i + 1))
    found="$(find_primary || true)"
    if [ -n "$found" ]; then set -- $found; src_host="$1"; src_port="$2"; break; fi
    any_peer_up && saw_peer=1
    [ "$NODE_ID" = "1" ] && [ "$saw_peer" = 0 ] && [ "$i" -ge 5 ] && break
    [ $((i % 15)) -eq 0 ] && echo "[node$NODE_ID] empty data dir; waiting for a live primary to clone from (saw_peer=$saw_peer)"
    sleep 2
  done
  if [ -n "$src_host" ]; then
    clone_standby "$src_host" "$src_port"
  else
    seed_primary
  fi
fi

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
