# Docker integration cluster (ParadeDB + pg_replica)

A 3-node **ParadeDB** cluster with **pg_replica** automatic Raft failover, plus
**Dozzle** for log viewing — for integration testing.

> **Running the automated test suite?** Use `../scripts/test.ps1` (Windows) or
> `../scripts/test.sh` (Linux/macOS/CI). Those drive a separate
> `docker-compose.test.yml` (no Dozzle, `restart: "no"`, `NET_ADMIN`, plus a
> runner container) and bring a fresh cluster up/down per test. The compose file
> below is the **demo / manual** cluster.

## Quick start

```bash
cd docker
cp .env.example .env
docker compose up --build
```

First boot: `node1` seeds (initdb + roles + `CREATE EXTENSION pg_replica`),
then `node2`/`node3` `pg_basebackup` from it and join the Raft group. Watch it form in
Dozzle (http://localhost:8888) or:

```bash
docker compose exec node1 psql -U postgres -c 'SELECT replica.status();'
```

## Connecting (the app follows the primary, no proxy)

Each node's Postgres is published on the host: node1 `5432`, node2 `5433`, node3 `5434`.
Use a libpq multi-host string with `target_session_attrs=read-write` — it auto-selects
the current primary and, after a failover, reconnects to the new one:

```
postgresql://weido:weido_test_pw@localhost:5432,localhost:5433,localhost:5434/weido?target_session_attrs=read-write
```

(Credentials are the `APP_USER` / `APP_PASSWORD` / `APP_DB` from `.env`

## Watch a failover

```bash
docker compose stop node1                      # kill the primary
docker compose exec node2 psql -U postgres -c 'SELECT replica.status();'   # node2 or node3 promotes
docker compose start node1                     # old primary pg_rewind-rejoins as a standby
```

With `SYNCHRONOUS=on` (default) every acknowledged commit is on a quorum, so failover
is zero committed-transaction loss.

## How the extension is built and installed

`docker/Dockerfile` is multi-stage and **auto-detects ParadeDB's Postgres major version**,
so it always builds against the right PG:

1. **builder** (`FROM paradedb/paradedb:v0.23.1`): installs Rust + `cargo-pgrx 0.18.1` and
   the build deps, then
   ```bash
   PGVER=$(pg_config --version | grep -oE '[0-9]+' | head -1)   # e.g. 17
   cargo pgrx install --release --no-default-features --features pg${PGVER} \
         --pg-config "$(command -v pg_config)"
   ```
   which compiles `pg_replica.so` and installs it into ParadeDB's `pkglibdir` + the
   `.control` / `--<ver>.sql` files into its `sharedir/extension`.
2. **runtime** (`FROM paradedb/paradedb:v0.23.1`): copies just those three artifacts onto a
   clean image, adds the control-plane helpers (`rejoin.sh`, `watchdog.sh`), and uses
   `entrypoint.sh` to seed/replica each node.

`entrypoint.sh` sets `shared_preload_libraries = 'pg_replica'` and the per-node
`pg_replica.*` GUCs (node id, raft port, peers, pg_addrs, passfile, synchronous). Auth is
**SCRAM everywhere, no trust** (a chmod-600 `~/.pgpass` holds the replicator + superuser
passwords; `initdb -A scram-sha-256 --pwfile` bootstraps the superuser).
