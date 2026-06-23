#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
P1=1 P2=2 P3=3

q() { cl_q "$1" "$2"; }
ins() { cl_ins "$1" "$2"; }
new_primary() { for p in $CL_NODES; do [ "$(q $p 'SELECT pg_is_in_recovery()' 2>/dev/null)" = "f" ] && { echo "$p"; return; }; done; }

converged() {
  local prim="" standbys=0 up=0 n r
  for n in $P1 $P2 $P3; do
    r=$(q "$n" "SELECT pg_is_in_recovery()" 2>/dev/null)
    case "$r" in
      f) prim="$prim$n "; up=$((up+1)) ;;
      t) standbys=$((standbys+1)); up=$((up+1)) ;;
    esac
  done
  [ "$up" = 3 ] && [ "$(echo $prim | wc -w)" = 1 ] && [ "$standbys" = 2 ]
}

wait_converged() {
  local label="$1" stable=0 i
  for i in $(seq 1 240); do
    if converged; then stable=$((stable+1)); [ "$stable" -ge 4 ] && return 0; else stable=0; fi
    [ $((i % 20)) -eq 0 ] && echo "    ...${label} ${i}s: not yet (1 primary + 2 streaming standbys)"
    sleep 1
  done
  return 1
}

echo "=== cluster ready ==="
cl_wait_status "$P1" "decided_primary=1 seq=1 quorum=true read_only=false" 80
ins $P1 before-wipe >/dev/null
echo "  node1 primary; wrote marker 'before-wipe'"
for i in $(seq 1 60); do
  [ "$(q 1 "SELECT count(*) FROM pg_stat_replication WHERE state='streaming'")" = "2" ] && break; sleep 1
done

echo
echo "=== WIPE 1: nuke a STANDBY (node2) entire volume — data + raft — like a docker volume wipe ==="
cl_wipe 2
echo "  node2 volumes emptied + container restarted; entrypoint must re-clone from the live primary (no manual action)"
standby_ok=0
for i in $(seq 1 240); do
  rec=$(q 2 "SELECT pg_is_in_recovery()" 2>/dev/null)
  streaming=$(q 1 "SELECT count(*) FROM pg_stat_replication WHERE application_name='node2' AND state='streaming'" 2>/dev/null)
  if [ "$rec" = "t" ] && [ "${streaming:-0}" -ge 1 ]; then standby_ok=1; break; fi
  [ $((i % 20)) -eq 0 ] && echo "    ...${i}s: node2 in_recovery=${rec:-?} streaming_from_node1=${streaming:-0}"
  sleep 1
done
echo "  node2 re-cloned + streaming: $([ "$standby_ok" = 1 ] && echo YES || echo NO)"
wait_converged "post-standby-wipe" && echo "  cluster reconverged after standby wipe" || echo "  WARN: not converged after standby wipe"

echo
echo "=== WIPE 2: nuke the PRIMARY (node1) entire volume — cluster must fail over AND re-clone the ex-primary ==="
ins $P1 after-wipe2 >/dev/null
for i in $(seq 1 30); do [ "$(q 1 "SELECT count(*) FROM pg_stat_replication WHERE state='streaming'")" -ge 1 ] && break; sleep 1; done
cl_wipe 1
NP=""
for i in $(seq 1 120); do NP=$(new_primary); [ -n "$NP" ] && [ "$NP" != "1" ] && break; [ $((i % 20)) -eq 0 ] && echo "    ...${i}s: waiting for failover"; sleep 1; done
echo "  failed over to node ${NP:-none}"
if [ -n "$NP" ] && [ "$NP" != "1" ]; then
  for i in $(seq 1 60); do [ "$(q "$NP" 'SHOW default_transaction_read_only')" = "off" ] && break; sleep 0.5; done
  ins "$NP" after-failover >/dev/null
fi
echo "  waiting for ex-primary node1 to re-clone from the new primary and the cluster to converge..."
final_ok=0
wait_converged "post-primary-wipe" && final_ok=1

echo
echo "=== final status ==="
for p in $P1 $P2 $P3; do echo -n "  node $p: "; q "$p" "SELECT replica.status()" 2>/dev/null; done

CONS=0
declare -A D
for k in $(seq 1 90); do
  for n in $P1 $P2 $P3; do D[$n]="$(q $n "SELECT string_agg(t, chr(44) ORDER BY t) FROM demo" 2>/dev/null)"; done
  if [ -n "${D[$P1]}" ] && [ "${D[$P1]}" = "${D[$P2]}" ] && [ "${D[$P2]}" = "${D[$P3]}" ]; then CONS=1; break; fi
  sleep 1
done
MARKER=0; echo "${D[$P1]}" | grep -q "before-wipe" && MARKER=1
FINAL_PRIMARY="$(new_primary)"

echo
echo "=== M5 volume-wipe result ==="
if [ "$standby_ok" = 1 ] && [ "$final_ok" = 1 ] && [ "$CONS" = 1 ] && [ "$MARKER" = 1 ]; then
  echo "  PASS: full data+raft volume wipe of a standby AND the primary both auto-recovered (re-clone + rejoin) with no manual action; cluster reconverged (primary node${FINAL_PRIMARY}), data consistent on all nodes [${D[$P1]}]"
else
  echo "  CHECK: standby_ok=$standby_ok converged=$final_ok consistent=$CONS marker=$MARKER final_primary=${FINAL_PRIMARY:-none} demos=[${D[$P1]}|${D[$P2]}|${D[$P3]}]"
fi
