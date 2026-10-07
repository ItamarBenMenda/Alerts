#!/usr/bin/env bash
# =============================================================================
# check_service.sh
# Generic service-up checker — Nagios plugin / Control-M job compatible.
#
# Checks that a service is up using one or more methods. Every check given
# must pass; any failure -> CRITICAL.
#
# Exit codes: 0 = OK   1 = WARNING   2 = CRITICAL   3 = UNKNOWN
#
# Usage:
#   check_service.sh [-s UNIT] [-p PROCESS] [-P PORT] [-H HOST] [options]
#
# Options:
#   -s UNIT     systemd unit must be "active"   (e.g. asterisk, nginx.service)
#   -p NAME     process must be running (exact process name, like "asterisk")
#   -f          With -p: match NAME anywhere in the full command line (regex)
#   -n MIN      minimum number of matching processes for -p (default: 1)
#   -P PORT     TCP port must accept connections
#   -H HOST     host for -P (default: 127.0.0.1)
#   -T SEC      TCP connect timeout (default: 5)
#   -h          Help
#
# Examples:
#   check_service.sh -s asterisk
#   check_service.sh -p kamailio -n 4             # at least 4 kamailio procs
#   check_service.sh -f -p 'java.*myapp.jar'       # match full command line
#   check_service.sh -P 5060                       # local port
#   check_service.sh -H 10.0.0.5 -P 443 -T 3       # remote port
#   check_service.sh -s nginx -P 80                # both must pass
# =============================================================================

OK=0; WARNING=1; CRITICAL=2; UNKNOWN=3
UNIT=""; PROC=""; FULLCMD=0; MINPROC=1; PORT=""; HOST="127.0.0.1"; TIMEOUT=5

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit $UNKNOWN; }
die()   { echo "UNKNOWN - $*"; exit $UNKNOWN; }

while getopts ":s:p:fn:P:H:T:h" opt; do
  case $opt in
    s) UNIT="$OPTARG" ;; p) PROC="$OPTARG" ;; f) FULLCMD=1 ;; n) MINPROC="$OPTARG" ;;
    P) PORT="$OPTARG" ;; H) HOST="$OPTARG" ;; T) TIMEOUT="$OPTARG" ;;
    h) usage ;;
    :) die "option -$OPTARG requires an argument" ;;
    *) die "invalid option -$OPTARG (use -h)" ;;
  esac
done

[ -z "$UNIT$PROC$PORT" ] && die "give at least one of -s, -p, -P"
[[ "$MINPROC" =~ ^[1-9][0-9]*$ ]] || die "-n must be a positive integer"
[[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die "-T must be a positive integer"
[ -n "$PORT" ] && { [[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -le 65535 ] || die "invalid port '$PORT'"; }

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

fail=(); ok=()

# --- systemd unit ------------------------------------------------------------
if [ -n "$UNIT" ]; then
  command -v systemctl >/dev/null || die "systemctl not found"
  state=$(systemctl is-active -- "$UNIT" 2>/dev/null)
  if [ "$state" = "active" ]; then ok+=("unit $UNIT active")
  else fail+=("unit $UNIT is ${state:-unknown}"); fi
fi

# --- process -----------------------------------------------------------------
if [ -n "$PROC" ]; then
  count=$(find_pids "$PROC" | wc -l)
  if [ "$count" -ge "$MINPROC" ]; then ok+=("$count process(es) '$PROC'")
  else fail+=("$count process(es) '$PROC' (need $MINPROC)"); fi
fi

# --- TCP port (bash /dev/tcp, no nc needed) ----------------------------------
if [ -n "$PORT" ]; then
  if timeout "$TIMEOUT" bash -c "exec 3<>/dev/tcp/$HOST/$PORT" 2>/dev/null; then
    ok+=("port $HOST:$PORT open")
  else
    fail+=("port $HOST:$PORT closed/unreachable")
  fi
fi

if [ ${#fail[@]} -gt 0 ]; then
  msg=$(printf "%s; " "${fail[@]}"); msg=${msg%; }
  echo "CRITICAL - $msg | up=0"
  exit $CRITICAL
fi
msg=$(printf "%s; " "${ok[@]}"); msg=${msg%; }
echo "OK - $msg | up=1"
exit $OK
