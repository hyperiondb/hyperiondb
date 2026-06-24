#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
P1=1 P2=2 P3=3

q() { cl_q "$1" "$2"; }
ins() { cl_ins "$1" "$2"; }
seq_of() {
  local node="$1" s i
  for i in $(seq 1 20); do
    s="$(q "$node" "SELECT replica.status()" 2>/dev/null | grep -oE 'seq=[0-9]+' | head -1 | cut -d= -f2)"
    [ -n "$s" ] && { echo "$s"; return 0; }
    sleep 0.5
  done
  return 1
}
wait_primary() {
  local p i
  for i in $(seq 1 40); do
    p="$(cl_primary_node 2>/dev/null || true)"
    [ -n "$p" ] && { echo "$p"; return 0; }
    sleep 0.5
  done
  return 1
}
# decided_seq is cluster-wide; read it off the current primary (robust to failover during the pump).
cluster_seq() { local p; p="$(wait_primary)" || return 1; seq_of "$p"; }

echo "=== cluster ready (compact_threshold=${COMPACT_THRESHOLD:-8}) ==="
cl_wait_status "$P1" "decided_primary=1 seq=1 quorum=true read_only=false" 80
ins $P1 marker >/dev/null
SEQ0=$(cluster_seq); SZ0=$(cl_raft_file_size 1)
echo "  start: seq=$SEQ0  raft_file_bytes(node1)=$SZ0"

echo
echo "=== pump decisions: repeatedly stall a follower (node2) so the leader re-ratifies (seq climbs) ==="
echo "  node2 control plane freeze/thaw cycles"
for r in $(seq 1 18); do
  cl_freeze_supervisor 2
  sleep 2
  cl_thaw_supervisor 2
  sleep 1.3
done
sleep 2

SEQ1=$(cluster_seq); SZ1=$(cl_raft_file_size 1); SZ2=$(cl_raft_file_size 2); SZ3=$(cl_raft_file_size 3)
NLOG1=$(cl_raft_log_len 1)
echo "  after pumping: seq=$SEQ1"
echo "  raft log file bytes: node1=$SZ1 node2=$SZ2 node3=$SZ3"
echo "  retained log entries (node1): $NLOG1 (openraft purges applied entries after each snapshot)"

echo
echo "=== restart node3 AFTER compaction -> must recover from snapshot (not full log) ==="
cl_restart 3
for i in $(seq 1 40); do q "$P3" "SELECT 1" 2>/dev/null | grep -q 1 && break; sleep 0.5; done
sleep 2
N3SEQ=$(seq_of $P3)
echo "  node3 restarted; seq after recovery = $N3SEQ (retained entries = $(cl_raft_log_len 3))"

echo
echo "=== cluster still healthy: write on primary replicates ==="
PRIM=$(wait_primary || echo $P1)
ins "$PRIM" after-compaction >/dev/null
sleep 1
D1=$(q $P1 "SELECT count(*) FROM demo"); D3=$(q $P3 "SELECT count(*) FROM demo")
echo "  demo rows: node1=$D1 node3=$D3"

echo
echo "=== compaction result ==="
DECS=$(( SEQ1 - SEQ0 ))
if [ "$DECS" -ge 12 ] && [ "$NLOG1" -ge 0 ] && [ "$NLOG1" -lt "$DECS" ] && [ "$SZ1" -lt 8192 ] && [ "$N3SEQ" -ge "$SEQ1" ] 2>/dev/null && [ "$D1" = "$D3" ]; then
  echo "  PASS: $DECS decisions made, raft log purged to $NLOG1 retained entries (< $DECS made), file stayed bounded (${SZ1}B), node3 recovered (seq=$N3SEQ), data consistent"
else
  echo "  CHECK: decisions=$DECS retained_entries=$NLOG1 file_bytes=$SZ1 (start $SZ0) n3_seq=$N3SEQ seq=$SEQ1 demo n1=$D1 n3=$D3"
fi
