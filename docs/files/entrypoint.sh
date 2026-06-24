#!/usr/bin/env bash
set -euo pipefail

: "${NODE_ID:?NODE_ID is required}"
: "${REPL_PASS:?REPL_PASS is required}"
: "${PGDATA:?PGDATA is required (set by the postgres image)}"
: "${POSTGRES_USER:?}" "${POSTGRES_PASSWORD:?}" "${POSTGRES_DB:?}"
SUBNET="${CLUSTER_SUBNET:-10.98.0.0/16}"
PRIMARY_PORT="${PRIMARY_PORT:-5432}"

umask 077
pgpass_escape() { printf '%s' "$1" | sed 's/[\\:]/\\&/g'; }
printf '*:*:*:replicator:%s\n*:*:*:%s:%s\n' \
  "$(pgpass_escape "$REPL_PASS")" "$POSTGRES_USER" "$(pgpass_escape "$POSTGRES_PASSWORD")" \
  > /var/lib/postgresql/.pgpass
chown postgres:postgres /var/lib/postgresql/.pgpass

mkdir -p /var/lib/postgresql/raft
chown postgres:postgres /var/lib/postgresql/raft

if [ "$NODE_ID" = "1" ]; then
  if [ -f "$PGDATA/pg_hba.conf" ] && ! grep -qE 'replication[[:space:]]+replicator' "$PGDATA/pg_hba.conf"; then
    echo "host replication replicator ${SUBNET} scram-sha-256" >> "$PGDATA/pg_hba.conf"
    chown postgres:postgres "$PGDATA/pg_hba.conf"
  fi
  (
    set +e
    export PGPASSWORD="$POSTGRES_PASSWORD"
    until pg_isready -q -U "$POSTGRES_USER" -d "$POSTGRES_DB"; do sleep 1; done
    psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -v rp="$REPL_PASS" <<'SQL'
SELECT format('CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD %L', :'rp')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'replicator')
\gexec
SELECT format('ALTER ROLE replicator WITH REPLICATION LOGIN PASSWORD %L', :'rp')
\gexec
GRANT pg_monitor TO replicator;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_ls_dir(text, boolean, boolean)                  TO replicator;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_stat_file(text, boolean)                        TO replicator;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_binary_file(text)                          TO replicator;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_binary_file(text, bigint, bigint, boolean) TO replicator;
CREATE EXTENSION IF NOT EXISTS pg_replica;
CREATE EXTENSION IF NOT EXISTS amcheck;
SQL
    psql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 -v appdb="$POSTGRES_DB" <<'SQL'
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule_in_database(
  'amcheck-btree',
  '17 3 * * 0',
  $cmd$DO $$DECLARE r record; BEGIN FOR r IN SELECT c.oid::regclass AS idx FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid JOIN pg_am a ON a.oid = c.relam JOIN pg_namespace n ON n.oid = c.relnamespace WHERE a.amname = 'btree' AND c.relpersistence = 'p' AND i.indisready AND i.indisvalid AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast') LOOP PERFORM bt_index_check(r.idx, true); END LOOP; END$$;$cmd$,
  :'appdb'
);
SQL
    exit 0
  ) &
elif [ ! -f /var/lib/postgresql/.bootstrapped ]; then
  : "${PRIMARY_HOST:?PRIMARY_HOST is required on standbys}"
  until pg_isready -q -h "$PRIMARY_HOST" -p "$PRIMARY_PORT"; do
    echo "waiting for primary ${PRIMARY_HOST}:${PRIMARY_PORT}..."
    sleep 2
  done
  while true; do
    rm -rf "${PGDATA:?}"/* "${PGDATA}"/.[!.]* 2>/dev/null || true
    if PGPASSFILE=/var/lib/postgresql/.pgpass \
        pg_basebackup -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U replicator -D "$PGDATA" -X stream -R -P; then
      break
    fi
    echo "basebackup failed (primary not ready for replication yet); retrying in 5s..."
    sleep 5
  done
  touch "$PGDATA/standby.signal"
  chown -R postgres:postgres "$PGDATA"
  touch /var/lib/postgresql/.bootstrapped
  chown postgres:postgres /var/lib/postgresql/.bootstrapped
fi

exec docker-entrypoint.sh "$@"
