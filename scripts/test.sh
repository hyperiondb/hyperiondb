#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
COMPOSE=(docker compose -f docker/docker-compose.test.yml)

TESTS=(test-model test-m3-lsn test-m4-fence test-m4-watchdog test-m4-partition
       test-m5-rejoin test-m5-walgone test-m5-wipe test-genesis-coldstart test-compaction test-m6-routing test-m7-sync
       test-quorum-consistency test-perf test-chaos)

test_env() {
  case "$1" in
    test-compaction)          echo "COMPACT_THRESHOLD=8" ;;
    test-m5-walgone)          echo "WAL_KEEP=8MB MAX_WAL=64MB" ;;
    test-m7-sync)             echo "SYNCHRONOUS=on" ;;
    test-quorum-consistency)  echo "SYNCHRONOUS=on" ;;
    test-chaos)               echo "SYNCHRONOUS=on" ;;
    *)                        echo "" ;;
  esac
}

wait_ready() {
  for _ in $(seq 1 120); do
    docker exec -u postgres -e PGPASSFILE=/var/lib/postgresql/.pgpass pgr-node1 \
      psql -h 127.0.0.1 -U postgres -tAc 'SELECT 1' >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

if [ "${1:-}" != "--no-build" ]; then
  echo "== building node + runner images =="
  "${COMPOSE[@]}" build || { echo "build FAILED"; exit 1; }
fi

pass=0; other=0
declare -a SUMMARY
for t in "${TESTS[@]}"; do
  "${COMPOSE[@]}" down -v >/dev/null 2>&1
  echo "================ $t ================"
  if [ "$t" = "test-model" ]; then
    out=$("${COMPOSE[@]}" run --rm runner bash "scripts/$t.sh" 2>&1)
  else
    env $(test_env "$t") "${COMPOSE[@]}" up -d node1 node2 node3 >/dev/null 2>&1
    wait_ready || echo "  (warning: node1 not ready in time; running test anyway)"
    out=$("${COMPOSE[@]}" run --rm runner bash "scripts/$t.sh" 2>&1)
  fi
  echo "$out" | grep -vE "screen size|FTS index" | grep -E "^  (PASS|FAIL|CHECK)"
  res=$(echo "$out" | grep -E "^  (PASS|FAIL|CHECK)" | head -1)
  if echo "$res" | grep -q "PASS"; then
    pass=$((pass+1)); mark="PASS"
  else
    other=$((other+1)); mark="CHECK"
    echo "  ---- full output for $t (did not PASS) ----"
    echo "$out" | grep -vE "screen size|FTS index" | sed 's/^/  | /'
    echo "  ---- end output for $t ----"
  fi
  SUMMARY+=("$(printf '%-24s %s' "$t" "$mark")")
done
"${COMPOSE[@]}" down -v >/dev/null 2>&1

echo
echo "==================== SUMMARY ===================="
printf '%s\n' "${SUMMARY[@]}"
echo "------------------------------------------------"
echo "$pass passed, $other need-attention, of ${#TESTS[@]} tests"
[ "$other" -eq 0 ]
