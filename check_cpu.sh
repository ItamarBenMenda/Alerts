#!/usr/bin/env bash
# =============================================================================
# check_cpu.sh
# Generic CPU checker — Nagios plugin / Control-M job compatible.
#
# Measures CPU usage from /proc/stat over a sample interval (no extra packages).
# Can check total usage, iowait, load average, or a specific process.
#
# Exit codes: 0 = OK   1 = WARNING   2 = CRITICAL   3 = UNKNOWN
#
# Usage:
#   check_cpu.sh [-m MODE] -w WARN -c CRIT [options]
#
# Options:
#   -m MODE     What to check (default: total)
#                 total   - total CPU usage %          (user+system+... )
#                 iowait  - CPU iowait %
#                 load    - 1-min load average per core (e.g. 1.5 = 150%)
#                 process - CPU % of a process (needs -p), summed over all PIDs
#   -w N        WARNING threshold (number, decimals allowed)
#   -c N        CRITICAL threshold
#   -t SEC      Sample interval in seconds (default: 3)
#   -p NAME     Process name for -m process (exact name, like "asterisk")
#   -f          With -p: match NAME anywhere in the full command line (regex)
#   -h          Help
#
# Examples:
#   check_cpu.sh -w 80 -c 95                    # total CPU %
#   check_cpu.sh -m iowait -w 20 -c 40          # disk wait
#   check_cpu.sh -m load -w 1.5 -c 3            # load per core
#   check_cpu.sh -m process -p asterisk -w 50 -c 90
# =============================================================================

OK=0; WARNING=1; CRITICAL=2; UNKNOWN=3
MODE="total"; WARN=""; CRIT=""; INTERVAL=3; PROC=""; FULLCMD=0

usage() { sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; exit $UNKNOWN; }
die()   { echo "UNKNOWN - $*"; exit $UNKNOWN; }

while getopts ":m:w:c:t:p:fh" opt; do
  case $opt in
    m) MODE="$OPTARG" ;; w) WARN="$OPTARG" ;; c) CRIT="$OPTARG" ;;
    t) INTERVAL="$OPTARG" ;; p) PROC="$OPTARG" ;; f) FULLCMD=1 ;; h) usage ;;
    :) die "option -$OPTARG requires an argument" ;;
    *) die "invalid option -$OPTARG (use -h)" ;;
  esac
done

# find PIDs: exact process name (default) or full command line (-f),
# excluding this script and its own subshells
find_pids() {
  local p pp cand skip=" $$ " a=$$ me
  me=$(basename -- "$0")
  # collect this script's ancestors (sh -c wrappers, agents) to skip them
  while [ -n "$a" ] && [ "$a" -gt 1 ]; do
    a=$(awk '{print $4}' "/proc/$a/stat" 2>/dev/null); skip="$skip$a "
  done
  if [ "$FULLCMD" -eq 1 ]; then cand=$(pgrep -f -- "$1"); else cand=$(pgrep -x -- "$1"); fi
  for p in $cand; do
    case "$skip" in *" $p "*) continue ;; esac
    pp=$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null) || continue
    [ "$pp" = "$$" ] && continue
    tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -qF -- "$me" && continue
    echo "$p"
  done
}

isnum() { [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]; }
isnum "$WARN" || die "-w must be a number"
isnum "$CRIT" || die "-c must be a number"
[[ "$INTERVAL" =~ ^[1-9][0-9]*$ ]] || die "-t must be a positive integer"
[ -r /proc/stat ] || die "/proc/stat not readable (Linux only)"

# read aggregate "cpu" line -> total and idle/iowait jiffies
read_cpu() {
  read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
  echo "$((user+nice+system+idle+iowait+irq+softirq+steal)) $((idle+iowait)) $iowait"
}

case "$MODE" in
  total|iowait)
    read -r t1 i1 w1 < <(read_cpu); sleep "$INTERVAL"; read -r t2 i2 w2 < <(read_cpu)
    dt=$((t2 - t1)); [ "$dt" -gt 0 ] || die "no CPU time elapsed"
    if [ "$MODE" = "total" ]; then
      value=$(awk -v d="$dt" -v i="$((i2 - i1))" 'BEGIN{printf "%.1f", (d-i)*100/d}')
      label="CPU usage"; unit="%"; perfname="cpu"
    else
      value=$(awk -v d="$dt" -v w="$((w2 - w1))" 'BEGIN{printf "%.1f", w*100/d}')
      label="CPU iowait"; unit="%"; perfname="iowait"
    fi
    ;;
  load)
    cores=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)
    read -r l1 _ < /proc/loadavg
    value=$(awk -v l="$l1" -v c="$cores" 'BEGIN{printf "%.2f", l/c}')
    label="load per core (load1=$l1, cores=$cores)"; unit=""; perfname="load_per_core"
    ;;
  process)
    [ -z "$PROC" ] && die "-m process requires -p NAME"
    pids=$(find_pids "$PROC" | tr '\n' ' ')
    [ -z "$pids" ] && { echo "CRITICAL - process '$PROC' not running"; exit $CRITICAL; }
    hz=$(getconf CLK_TCK)
    ptime() { local s=0 p; for p in $pids; do
                [ -r /proc/$p/stat ] && s=$((s + $(awk '{print $14+$15}' "/proc/$p/stat")))
              done; echo $s; }
    p1=$(ptime); sleep "$INTERVAL"; p2=$(ptime)
    # % of one core (100% = one full core, like top)
    value=$(awk -v d="$((p2 - p1))" -v hz="$hz" -v t="$INTERVAL" 'BEGIN{v=d*100/(hz*t); if(v<0)v=0; printf "%.1f", v}')
    label="CPU of '$PROC' (PIDs: ${pids% })"; unit="%"; perfname="proc_cpu"
    ;;
  *) die "unknown mode '$MODE' (total|iowait|load|process)" ;;
esac

ge() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a>=b)}'; }
if ge "$value" "$CRIT"; then status="CRITICAL"; rc=$CRITICAL
elif ge "$value" "$WARN"; then status="WARNING"; rc=$WARNING
else status="OK"; rc=$OK; fi

echo "$status - $label: ${value}${unit} (warn ${WARN}, crit ${CRIT}) | ${perfname}=${value}${unit};$WARN;$CRIT"
exit $rc
