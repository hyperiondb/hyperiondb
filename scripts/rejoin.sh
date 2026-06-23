#!/usr/bin/env bash
set -uo pipefail

PGBIN="$1"
DATADIR="$2"
LEADER_HOST="$3"
LEADER_PORT="$4"
NODE_ID="$5"
PASSFILE="${6:-}"
STANDBY_CONNINFO="${7:-}"

[ -n "$PASSFILE" ] && export PGPASSFILE="$PASSFILE"
PASS_KW=""
[ -n "$PASSFILE" ] && PASS_KW=" passfile=$PASSFILE"

REJOIN_MARK=/tmp/pg_replica_rejoin_active
touch "$REJOIN_MARK"
trap 'rm -f "$REJOIN_MARK"' EXIT

LOG="$(dirname "$DATADIR")/$(basename "$DATADIR").log"

log() { echo "[rejoin $(date -u +%H:%M:%S)] $*" >>"$LOG"; }

log "stopping deposed primary at $DATADIR (immediate: never let a graceful shutdown locally-commit an in-flight sync write that rewind will discard)"
"$PGBIN/pg_ctl" -D "$DATADIR" stop -m immediate >>"$LOG" 2>&1 || true

CONF_SAVE="$(dirname "$DATADIR")/$(basename "$DATADIR").conf.save"
cp "$DATADIR/postgresql.conf" "$CONF_SAVE"

log "waiting for leader $LEADER_HOST:$LEADER_PORT to finish promoting (a rewind against a not-yet-promoted leader is a no-op that strands us on the old timeline)"
for _ in $(seq 1 120); do
  [ "$("$PGBIN/psql" "host=$LEADER_HOST port=$LEADER_PORT user=replicator dbname=postgres${PASS_KW}" -tAc 'SELECT NOT pg_is_in_recovery()' 2>/dev/null | tr -d '[:space:]')" = "t" ] && break
  sleep 1
done

log "pg_rewind against leader $LEADER_HOST:$LEADER_PORT"
if "$PGBIN/pg_rewind" \
  --target-pgdata="$DATADIR" \
  --source-server="host=$LEADER_HOST port=$LEADER_PORT user=replicator dbname=postgres" \
  --progress >>"$LOG" 2>&1; then
  cp "$CONF_SAVE" "$DATADIR/postgresql.conf"
  log "pg_rewind succeeded"
else
  log "pg_rewind FAILED (WAL diverged past retention); falling back to full pg_basebackup re-clone"
  rm -rf "$DATADIR"
  if ! "$PGBIN/pg_basebackup" \
    -h "$LEADER_HOST" -p "$LEADER_PORT" -U replicator \
    -D "$DATADIR" -X stream --progress >>"$LOG" 2>&1; then
    log "pg_basebackup fallback FAILED; leaving node stopped for manual recovery"
    exit 1
  fi
  cp "$CONF_SAVE" "$DATADIR/postgresql.conf"
  log "pg_basebackup re-clone succeeded"
fi

CONNINFO="${STANDBY_CONNINFO:-host=$LEADER_HOST port=$LEADER_PORT user=replicator${PASS_KW} application_name=node$NODE_ID}"
{
  echo "primary_conninfo = '$CONNINFO'"
  echo "default_transaction_read_only = off"
} >> "$DATADIR/postgresql.auto.conf"
touch "$DATADIR/standby.signal"

log "starting as standby of $LEADER_HOST:$LEADER_PORT"
"$PGBIN/pg_ctl" -D "$DATADIR" -l "$LOG" start >>"$LOG" 2>&1
log "rejoin complete"
