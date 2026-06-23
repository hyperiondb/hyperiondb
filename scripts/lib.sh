#!/usr/bin/env bash
set -uo pipefail

CL_NODES="${CL_NODES:-1 2 3}"
CL_PASSFILE="${CL_PASSFILE:-/var/lib/postgresql/.pgpass}"
CL_RAFT_PORT="${CL_RAFT_PORT:-7400}"
CL_RAFT_DIR="${CL_RAFT_DIR:-/var/lib/postgresql/raft}"
CL_FAKETIME_LIB="${CL_FAKETIME_LIB:-}"
SU_PASSWORD="${SU_PASSWORD:-pgr_super_pw}"

cname() { echo "pgr-node$1"; }

_pgexec() {
  local node="$1"; shift
  docker exec -i -u postgres \
    -e PGPASSFILE="$CL_PASSFILE" \
    ${PGCONNECT_TIMEOUT:+-e PGCONNECT_TIMEOUT="$PGCONNECT_TIMEOUT"} \
    "$(cname "$node")" "$@"
}

_rootexec() {
  local node="$1"; shift
  docker exec -i -u root "$(cname "$node")" "$@"
}

cl_q() { _pgexec "$1" psql -h 127.0.0.1 -U postgres -tAc "$2" 2>&1; }

cl_q_quiet() { _pgexec "$1" psql -h 127.0.0.1 -U postgres -tAc "$2" 2>/dev/null; }

cl_ins() { _pgexec "$1" psql -h 127.0.0.1 -U postgres -tAc "INSERT INTO demo VALUES (\$cltag\$$2\$cltag\$)" 2>&1; }

cl_psql() { local node="$1"; shift; _pgexec "$node" psql -h 127.0.0.1 -U postgres "$@"; }

cl_psql_t() { local secs="$1" node="$2"; shift 2; timeout "$secs" docker exec -i -u postgres -e PGPASSFILE="$CL_PASSFILE" "$(cname "$node")" psql -h 127.0.0.1 -U postgres "$@"; }

cl_pgbench() { local node="$1"; shift; _pgexec "$node" pgbench -h 127.0.0.1 -U postgres "$@"; }

cl_put() { _pgexec "$1" sh -c "cat > $2"; }

CL_PGDATA="${CL_PGDATA:-/var/lib/postgresql/data}"
CL_LOGFILE="${CL_LOGFILE:-/var/lib/postgresql/data.log}"

_pgctl() { docker exec -u postgres "$(cname "$1")" sh -c "B=\$(pg_config --bindir); $2" >/dev/null 2>&1 || true; }

cl_kill()    { _pgctl "$1" "\"\$B/pg_ctl\" -D $CL_PGDATA stop -m immediate"; }
cl_stop()    { _pgctl "$1" "\"\$B/pg_ctl\" -D $CL_PGDATA stop -m fast"; }
cl_start()   { _pgctl "$1" "rm -f $CL_PGDATA/postmaster.pid; \"\$B/pg_ctl\" -D $CL_PGDATA -l $CL_LOGFILE -w -t 120 start"; }
cl_restart() { _pgctl "$1" "\"\$B/pg_ctl\" -D $CL_PGDATA -l $CL_LOGFILE -w -t 120 restart -m fast"; }
cl_wipe() {
  local node="$1" c v; c="$(cname "$node")"
  docker stop -t 3 "$c" >/dev/null 2>&1 || true
  for v in $(docker inspect -f '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}} {{end}}{{end}}' "$c" 2>/dev/null); do
    docker run --rm --entrypoint sh -v "$v:/w" pg-replica-paradedb:test -c 'rm -rf /w/* /w/.[!.]* 2>/dev/null; true' >/dev/null 2>&1 || true
  done
  docker start "$c" >/dev/null 2>&1 || true
}
cl_pause()   { docker pause "$(cname "$1")" >/dev/null 2>&1 || true; }
cl_unpause() { docker unpause "$(cname "$1")" >/dev/null 2>&1 || true; }

cl_logs() { docker logs "$(cname "$1")" 2>&1; }

cl_node_logfile() { _rootexec "$1" sh -c 'cat /var/lib/postgresql/data.log 2>/dev/null'; }
cl_watchdog_log() { _rootexec "$1" sh -c "cat $CL_RAFT_DIR/pg_replica_wd_$1.log 2>/dev/null"; }

cl_hb_age() {
  _rootexec "$1" sh -c 'now=$(date +%s%3N); hb=$(cat '"$CL_RAFT_DIR"'/pg_replica_hb_'"$1"' 2>/dev/null || echo 0); echo $(( now - hb ))'
}

cl_postmaster_pid() { _rootexec "$1" sh -c 'head -1 "$PGDATA/postmaster.pid" 2>/dev/null'; }

cl_supervisor_pid() {
  _rootexec "$1" sh -c '
    pm=$(head -1 "$PGDATA/postmaster.pid" 2>/dev/null)
    [ -z "$pm" ] && exit 1
    for p in $(pgrep -P "$pm" 2>/dev/null); do
      if tr "\0" " " < "/proc/$p/cmdline" 2>/dev/null | grep -q "pg_replica supervisor"; then
        echo "$p"; exit 0
      fi
    done
    exit 1'
}

cl_freeze_supervisor() { local pid; pid=$(cl_supervisor_pid "$1") || return 1; _rootexec "$1" kill -STOP "$pid"; }
cl_thaw_supervisor()   { local pid; pid=$(cl_supervisor_pid "$1") || return 1; _rootexec "$1" kill -CONT "$pid"; }

cl_partition_on()  { _rootexec "$1" iptables -I INPUT 1 -p tcp --dport "$CL_RAFT_PORT" -j DROP >/dev/null 2>&1; }
cl_partition_off() { _rootexec "$1" iptables -D INPUT -p tcp --dport "$CL_RAFT_PORT" -j DROP >/dev/null 2>&1 || true; }

cl_clock_skew_on()  { _rootexec "$1" sh -c "echo '$2' > /tmp/faketime"; docker restart -t 30 "$(cname "$1")" >/dev/null 2>&1 || true; }
cl_clock_skew_off() { _rootexec "$1" sh -c 'rm -f /tmp/faketime'; docker restart -t 30 "$(cname "$1")" >/dev/null 2>&1 || true; }

cl_slow_disk_on()  { docker update --device-write-bps /dev/sda:1mb --device-read-bps /dev/sda:1mb "$(cname "$1")" >/dev/null 2>&1; }
cl_slow_disk_off() { docker update --device-write-bps /dev/sda:0 --device-read-bps /dev/sda:0 "$(cname "$1")" >/dev/null 2>&1 || true; }

cl_raft_file_size() { _rootexec "$1" sh -c "stat -c %s $CL_RAFT_DIR/raft_log_$1.json 2>/dev/null || echo 0"; }
cl_raft_log_len()   { _rootexec "$1" sh -c "jq '.log | length' $CL_RAFT_DIR/raft_log_$1.json 2>/dev/null || echo -1"; }

cl_clk_tck()   { _rootexec "$1" getconf CLK_TCK 2>/dev/null; }
cl_rss_kb()    { _rootexec "$1" sh -c "ps -o rss= -p $2 2>/dev/null | tr -d ' '"; }
cl_pss_kb()    { _rootexec "$1" sh -c "awk '/^Pss:/{print \$2; exit}' /proc/$2/smaps_rollup 2>/dev/null"; }
cl_priv_kb()   { _rootexec "$1" sh -c "awk '/^Private_Clean|^Private_Dirty/{s+=\$2} END{print s+0}' /proc/$2/smaps_rollup 2>/dev/null"; }
cl_cpu_ticks() { _rootexec "$1" sh -c "st=\$(cat /proc/$2/stat 2>/dev/null) || exit 1; st=\${st#*) }; set -- \$st; echo \$(( \${12} + \${13} ))"; }

cl_is_primary() { [ "$(cl_q "$1" 'SELECT pg_is_in_recovery()' 2>/dev/null)" = "f" ]; }

cl_primary_node() {
  local n
  for n in $CL_NODES; do
    [ "$(cl_q "$n" 'SELECT pg_is_in_recovery()' 2>/dev/null)" = "f" ] && { echo "$n"; return 0; }
  done
  return 1
}

cl_pg_conninfo() {
  local hosts="" ports="" n
  for n in $CL_NODES; do hosts+="node$n,"; ports+="5432,"; done
  echo "host=${hosts%,} port=${ports%,} user=postgres password=$SU_PASSWORD dbname=postgres target_session_attrs=read-write connect_timeout=2"
}

cl_wait_status() {
  local node="$1" pattern="$2" tries="${3:-80}" i
  for ((i = 0; i < tries; i++)); do
    cl_q "$node" "SELECT replica.status()" 2>/dev/null | grep -qE "$pattern" && return 0
    sleep 0.5
  done
  return 1
}
