# TODO — close the test/production gap (2026-07-30 incident)

Every production failure of the 0.7.2 rollout was a pg_replica bug that CI could not
see because the test rig runs a different runtime model than production:
psql-to-self hairpin (refused in prod, direct in rig), `POSTGRES_*` env (scrubbed by
the official image entrypoint, kept by the rig entrypoint), container lifecycle
(postgres is PID 1 in prod so `pg_ctl stop` kills the container; rig survives it),
config path (prod pins `config_file=`, so `$PGDATA/postgresql.conf` writes are dead).

## 1. Ship the production entrypoint from this repo
- [ ] Generic production entrypoint in `scripts/` shipped by the deb to
      `/opt/pg_replica/entrypoint.sh` (alongside rejoin.sh/watchdog.sh): pgpass,
      hba, node_conf generation, marker-rejoin-on-boot (single-user crash recovery
      → pg_rewind → pg_basebackup fallback), clone/genesis gating, then exec the
      official `docker-entrypoint.sh`.
- [ ] App-specific seeding via optional mounted hook (e.g. `/etc/pg_replica/seed.sh`)
      — nothing app-specific (hsearch, postgis, cron jobs) in this repo.
- [ ] server-backend then deletes `services/parade/entrypoint.sh` + `conf-init.sh`
      and points compose `entrypoint:` at the shipped file. One source, zero copies.

## 2. Production-faithful CI profile
- [ ] Second compose profile where nodes run exactly as in production: official
      docker-entrypoint chain (postgres PID 1, `init: true`, restart policy),
      base image scrubbing `POSTGRES_*`, published-port topology, mounted
      read-only conf + generated node.conf, `PGR_REJOIN_MODE=marker`.
- [ ] Run lifecycle tests on this profile: failover, rejoin-through-container-restart,
      fence/unfence, apply-user resolution, walreceivers actually consuming their
      `nodeN` slots. Keep the pg_ctl rig only for process-chaos tests (freeze, faketime).

## 3. Apply identity must never depend on env
- [ ] Drop (or hard-deprecate) the `POSTGRES_USER`/`POSTGRES_DB` env fallbacks for
      `apply_user`/`apply_db` — the official image unsets them before postmaster start.
- [ ] Log the resolved apply identity and target once at supervisor startup
      (`apply via <host>:<port> as <user> db <db>`) so misresolution is visible in
      the first screen of logs, not after connecting.

## 4. Backoff every apply path
- [ ] 0.7.2 added retry backoff only to repoint; sync-clear/fence/unfence still retry
      every tick → ~7 log lines/s when psql is broken. Same backoff everywhere.

## 5. Upgrade paths tested in CI (the "mess after each upgrade" class)
- [ ] CI invariant: every `Cargo.toml` version bump ships
      `sql/pg_replica--<prev>--<new>.sql` and a chain exists from every previously
      released version to `default_version` (the hsearch 0.2.1→0.4.0 failure).
- [ ] CI step: install the previous released deb, create the extension, install the
      new deb, run `ALTER EXTENSION pg_replica UPDATE` — fail the build if no path.
- [ ] Document the release chain in README: deb pool → image build → compose bump,
      in that order, and what each step invalidates.

## 6. Leftovers noticed during the incident
- [ ] `REJOIN_MARK` (`/tmp/pg_replica_rejoin_active`) is meaningless in marker mode —
      scope it to inplace mode or drop it.
- [ ] Test-suite runners share one compose project — two concurrent runs corrupt each
      other silently. Add a project-name guard or flock in `scripts/test.sh`.
- [ ] `test-perf.sh` now aborts early when the perf table is missing / no primary —
      keep that pattern for new tests (fail fast with the diagnosis, never probe-spam).
