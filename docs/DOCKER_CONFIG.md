# Docker config

## Dockerfile

Example is with [ParadeDb](https://github.com/paradedb/paradedb)

```
FROM postgres:18-trixie

ARG PGR_VERSION=0.3.0
ARG WALG_VERSION=v3.0.8

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends curl ca-certificates postgresql-18-cron postgresql-18-postgis-3 postgresql-18-postgis-3-scripts; \
    arch="$(dpkg --print-architecture)"; \
    curl -fsSL "https://hyperiondb.github.io/hyperiondb/pool/main/postgresql-18-pg-replica_${PGR_VERSION}_${arch}.deb" -o /tmp/pg_replica.deb; \
    apt-get install -y /tmp/pg_replica.deb; \
    /tmp/pg_replica.deb; \
    case "$arch" in \
      amd64) wgarch=amd64 ;; \
      arm64) wgarch=aarch64 ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/wal-g/wal-g/releases/download/${WALG_VERSION}/wal-g-pg-20.04-${wgarch}" -o /usr/local/bin/wal-g; \
    chmod 0755 /usr/local/bin/wal-g; \
    wal-g --version; \
    apt-get purge -y curl && apt-get autoremove -y && rm -rf /var/lib/apt/lists/*
````

## postgres.conf

```
shared_preload_libraries = 'pg_cron,pg_replica'

wal_level = replica
max_wal_senders = 10
max_replication_slots = 10
hot_standby = on
wal_log_hints = on
wal_keep_size = '512MB'

pg_replica.raft_port = 7400
pg_replica.peers    = '1@10.98.0.3:7400,2@10.98.0.2:7400,3@10.98.0.4:7400'
pg_replica.pg_addrs = '1@10.98.0.3:5432,2@10.98.0.2:5432,3@10.98.0.4:5432'
pg_replica.psql     = '/usr/lib/postgresql/18/bin/psql'
pg_replica.passfile = '/var/lib/postgresql/.pgpass'
pg_replica.raft_dir = '/var/lib/postgresql/raft'
pg_replica.synchronous = on
```

## Compose

```
paradedb:
    image: # build above Dockerfile or use context
    container_name: paradedb
    restart: always
    environment:
        POSTGRES_PASSWORD: ${PG_PASS}
        POSTGRES_USER: ${PG_USER}
        POSTGRES_DB: ${PG_DB}
        NODE_ID: "1" # 1 node - primary, 2 - stanbdby, 3 - standby for intiial setup
        REPL_PASS: ${REPL_PASS}
        PRIMARY_HOST: 10.0.0.0 # primary node IP
    ports:
        - "5432:5432"
        - "7400:7400"
    entrypoint: ["bash", "/entrypoint.sh"] # see files folder
    command: >
        postgres -c config_file=/etc/postgresql/postgresql.conf -c pg_replica.node_id=1 # should match NODE_ID
    volumes:
        - paradedb:/var/lib/postgresql
        - ./files/postgres.conf:/etc/postgresql/postgresql.conf:ro
        - ./files/entrypoint.sh:/entrypoint.sh:ro
    ```
