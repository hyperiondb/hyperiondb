#!/usr/bin/env bash
set -uo pipefail

PSQL="$1"
HOST="$2"
PORT="$3"
HB="$4"
NODE="$5"
PGUSER="${6:-postgres}"
STALE_MS="${7:-2000}"

LOCK="${HB}.wd.lock"
exec 9>"$LOCK"
flock -n 9 || exit 0

LOG="$(dirname "$HB")/pg_replica_wd_${NODE}.log"
log() { echo "[wd $(date -u +%H:%M:%S)] $*" >>"$LOG"; }
psql_q() { PGCONNECT_TIMEOUT=2 "$PSQL" -h "$HOST" -p "$PORT" -U "$PGUSER" -d postgres -w -tAc "$1" 2>/dev/null; }

log "deadman watchdog start (node $NODE port $PORT stale=${STALE_MS}ms)"
miss=0

while true; do
  sleep 0.5

  in_recovery="$(psql_q 'SELECT pg_is_in_recovery()')"
  if [ -z "$in_recovery" ]; then
    miss=$((miss + 1))
    if [ "$miss" -ge 20 ]; then
      log "postgres unreachable for ~10s; watchdog exiting"
      exit 0
    fi
    continue
  fi
  miss=0

  [ "$in_recovery" = "t" ] && continue

  now="$(date +%s%3N)"
  hb="$(cat "$HB" 2>/dev/null || echo 0)"
  [ -z "$hb" ] && hb=0
  age=$((now - hb))

  if [ "$age" -ge "$STALE_MS" ]; then
    ro="$(psql_q 'SHOW default_transaction_read_only')"
    if [ "$ro" != "on" ]; then
      log "control-plane heartbeat stale (${age}ms >= ${STALE_MS}ms) on ACTING PRIMARY -> FENCE read-only"
      psql_q 'ALTER SYSTEM SET default_transaction_read_only = on' >/dev/null
      psql_q 'SELECT pg_reload_conf()' >/dev/null
    fi
  fi
done
