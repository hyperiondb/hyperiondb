#!/usr/bin/env bash
set -euo pipefail

PG_MAJOR="${1:?usage: packaging/build-deb.sh <pg-major>}"
EXT="pg_replica"
PKG="postgresql-${PG_MAJOR}-pg-replica"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CRATE_DIR="${ROOT}"
PG_CONFIG="${PG_CONFIG:-/usr/lib/postgresql/${PG_MAJOR}/bin/pg_config}"
ARCH="$(dpkg --print-architecture)"
VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' "${CRATE_DIR}/Cargo.toml" | head -1)"
OUT_DIR="${ROOT}/dist"

if [ ! -x "$PG_CONFIG" ]; then
  echo "missing $PG_CONFIG — install postgresql-server-dev-${PG_MAJOR}" >&2
  exit 1
fi

cd "$CRATE_DIR"
export PGRX_PG_CONFIG_PATH="$PG_CONFIG"
cargo pgrx package --no-default-features --features "pg${PG_MAJOR}" --pg-config "$PG_CONFIG"

TARGET_DIR="$(cargo metadata --no-deps --format-version 1 \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["target_directory"])')"
STAGE="$(find "${TARGET_DIR}/release" -maxdepth 1 -type d -name "${EXT}-pg${PG_MAJOR}*" | head -1)"
if [ -z "${STAGE}" ] || [ ! -d "${STAGE}" ]; then
  echo "package stage not found under ${TARGET_DIR}/release" >&2
  exit 1
fi

PKGROOT="$(mktemp -d)"
cp -a "${STAGE}/." "${PKGROOT}/"
mkdir -p "${PKGROOT}/DEBIAN" "${PKGROOT}/opt/pg_replica"
install -m 0755 "${ROOT}/scripts/rejoin.sh" "${ROOT}/scripts/watchdog.sh" "${PKGROOT}/opt/pg_replica/"

cat > "${PKGROOT}/DEBIAN/control" <<EOF
Package: ${PKG}
Version: ${VERSION}
Architecture: ${ARCH}
Maintainer: Weido <info@nordlet.com>
Section: database
Priority: optional
Depends: postgresql-${PG_MAJOR}
Homepage: https://github.com/hyperiondb/hyperiondb
Description: Consensus-driven failover for PostgreSQL (Raft control plane)
 pg_replica adds an in-process Raft control plane to PostgreSQL for automatic,
 split-brain-safe primary failover, built with pgrx.
EOF

cat > "${PKGROOT}/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
cat <<'MSG'
pg_replica installed. To enable it:
  1) add it to shared_preload_libraries in postgresql.conf:
       shared_preload_libraries = 'pg_replica'
  2) restart PostgreSQL
  3) in your database:  CREATE EXTENSION pg_replica;
See https://github.com/hyperiondb/hyperiondb for cluster configuration.
MSG
EOF
chmod 0755 "${PKGROOT}/DEBIAN/postinst"

mkdir -p "${OUT_DIR}"
DEB="${OUT_DIR}/${PKG}_${VERSION}_${ARCH}.deb"
dpkg-deb --root-owner-group --build "${PKGROOT}" "${DEB}"
rm -rf "${PKGROOT}"
echo "built ${DEB}"
