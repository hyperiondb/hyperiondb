ARG PARADEDB=paradedb/paradedb:v0.23.1

FROM ${PARADEDB} AS builder
USER root
RUN set -eux; \
    PGVER="$(pg_config --version | grep -oE '[0-9]+' | head -1)"; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      build-essential clang libclang-dev pkg-config libssl-dev curl git ca-certificates; \
    apt-get install -y --no-install-recommends "postgresql-server-dev-${PGVER}" \
      || echo "postgresql-server-dev-${PGVER} unavailable; using image-provided server headers"; \
    rm -rf /var/lib/apt/lists/*
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
ENV PATH="/root/.cargo/bin:${PATH}"
ENV CARGO_NET_RETRY=10 CARGO_HTTP_MULTIPLEXING=false
RUN cargo install --locked cargo-pgrx --version 0.18.1
WORKDIR /build
COPY Cargo.toml pg_replica.control ./extension/
COPY src/ ./extension/src/
RUN set -eux; \
    PGVER="$(pg_config --version | grep -oE '[0-9]+' | head -1)"; \
    cd extension; \
    cargo pgrx init "--pg${PGVER}" "$(command -v pg_config)"; \
    cargo pgrx install --release --no-default-features --features "pg${PGVER}" --pg-config "$(command -v pg_config)"; \
    PKGLIB="$(pg_config --pkglibdir)"; SHARE="$(pg_config --sharedir)"; \
    mkdir -p /staging; \
    cp "${PKGLIB}/pg_replica.so" /staging/; \
    cp "${SHARE}/extension/pg_replica".* /staging/
RUN cp "$(pg_config --sharedir)/extension/pg_replica--"*.sql /staging/

FROM ${PARADEDB}
USER root
COPY --from=builder /staging/ /staging/
RUN set -eux; \
    PKGLIB="$(pg_config --pkglibdir)"; SHARE="$(pg_config --sharedir)"; \
    cp /staging/pg_replica.so "${PKGLIB}/"; \
    cp /staging/pg_replica.control "${SHARE}/extension/"; \
    cp /staging/pg_replica--*.sql "${SHARE}/extension/"; \
    rm -rf /staging
ARG TEST_TOOLS=0
RUN if [ "$TEST_TOOLS" = "1" ]; then \
      apt-get update; \
      apt-get install -y --no-install-recommends iptables libfaketime jq procps; \
      rm -rf /var/lib/apt/lists/*; \
    fi
COPY docker/entrypoint.sh /opt/pg_replica/entrypoint.sh
COPY scripts/rejoin.sh    /opt/pg_replica/rejoin.sh
COPY scripts/watchdog.sh  /opt/pg_replica/watchdog.sh
RUN chmod +x /opt/pg_replica/*.sh
ENTRYPOINT ["/opt/pg_replica/entrypoint.sh"]
