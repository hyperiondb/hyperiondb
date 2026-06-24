#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
P1=1 P2=2 P3=3
CYCLES="${COLDSTART_CYCLES:-3}"

q() { cl_q "$1" "$2"; }

dump_node() {
  local n="$1" c; c="$(cname "$n")"
  echo "  --- DIAG $c (node$n) ---"
  echo "  state: $(docker inspect -f 'status={{.State.Status}} running={{.State.Running}} restarts={{.RestartCount}} exit={{.State.ExitCode}}' "$c" 2>&1)"
  cl_node_logfile "$n" 2>/dev/null | tail -120 | sed 's/^/  | /'
  echo "  --- end DIAG $c ---"
}

decided_primary_of() { q "$1" "SELECT replica.status()" 2>/dev/null | grep -oE 'decided_primary=[0-9]+' | head -1 | cut -d= -f2; }

wait_caught_up() {
  local sb=0 i
  for i in $(seq 1 90); do
    sb=$(q 1 "SELECT count(*) FROM pg_stat_replication WHERE state='streaming' AND replay_lsn = pg_current_wal_lsn()" 2>/dev/null)
    [ "${sb:-0}" = "2" ] && break
    sleep 1
  done
  echo "${sb:-0}"
}

wait_leader() {
  local i n d
  for i in $(seq 1 40); do
    for n in $P1 $P2 $P3; do
      d="$(decided_primary_of "$n")"
      if [ -n "$d" ] && [ "$d" != "0" ]; then echo "$d"; return 0; fi
    done
    sleep 1
  done
  return 1
}

echo "=== clean bring-up must elect a leader first (sanity) ==="
if ! cl_wait_status "$P1" "decided_primary=[1-9]" 240; then
  echo "  FAIL: clean bring-up never elected a leader (decided_primary stayed 0)"
  dump_node 1; dump_node 2; dump_node 3
  exit 0
fi
echo "  initial leader: $(q 1 "SELECT replica.status()")"

echo
echo "=== $CYCLES cold-start cycles: each stops all 3, wipes raft + cluster marker, starts all together at equal LSN ==="
echo "    (a single tie can race intermittently; looping makes the split-genesis wedge reliably reproduce)"
fail_cycle=0; dp=0
for cyc in $(seq 1 "$CYCLES"); do
  echo
  echo "--- cycle $cyc/$CYCLES ---"
  echo "  standbys streaming and caught up: $(wait_caught_up)/2"
  for n in $P1 $P2 $P3; do cl_stop "$n"; done
  for n in $P1 $P2 $P3; do
    _rootexec "$n" sh -c "rm -rf ${CL_RAFT_DIR:?}/* ${CL_PGDATA:?}/pg_replica_cluster" >/dev/null 2>&1
  done
  echo "  raft state + pg_replica_cluster marker wiped on all 3; cold-starting node1/node2/node3 together"
  for n in $P1 $P2 $P3; do cl_start "$n"; done
  if dp="$(wait_leader)"; then
    echo "  cycle $cyc: leader elected (decided_primary=$dp)"
  else
    echo "  cycle $cyc: NO leader elected (decided_primary=0 on all 3)"
    fail_cycle=$cyc
    break
  fi
done

echo
echo "=== final status ==="
for n in $P1 $P2 $P3; do echo -n "  node $n: "; q "$n" "SELECT replica.status()" 2>/dev/null; done

echo
echo "=== genesis cold-start result ==="
if [ "$fail_cycle" = 0 ]; then
  echo "  PASS: $CYCLES/$CYCLES equal-LSN cold-start cycles each converged on a single leader (last decided_primary=$dp); no split-genesis wedge"
else
  echo "  FAIL: cold-start cycle $fail_cycle elected NO leader (decided_primary stayed 0 on all 3) — split-genesis race"
  dump_node 1; dump_node 2; dump_node 3
fi
