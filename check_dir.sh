#!/usr/bin/env bash
# =============================================================================
# check_dir.sh
# Generic directory checker — Nagios plugin / Control-M job compatible.
#
# Checks one or more directories. The final status is the WORST of all
# directories (e.g. one CRITICAL dir -> CRITICAL). Missing dir -> CRITICAL.
#
# Exit codes: 0 = OK   1 = WARNING   2 = CRITICAL   3 = UNKNOWN
#
# Usage:
#   check_dir.sh -d DIR [-d DIR2 ...] [-m MODE -w WARN -c CRIT] [options]
#   check_dir.sh -d "DIR1,DIR2,DIR3" ...
#
# Options:
#   -d DIR      Directory to check. Repeat -d, or comma-separate, for several.
#   -m MODE     What to check (default: exists)
#                 exists  - directory exists and is readable (no thresholds)
#                 size    - total size in MB              (alert if >= threshold)
#                 count   - number of files               (alert if >= threshold)
#                 oldest  - age of OLDEST file, minutes   (alert if >= threshold)
#                           -> files stuck / not picked up
#                 newest  - age of NEWEST file, minutes   (alert if >= threshold)
#                           -> no new files arriving
#                 empty   - alert if the directory has NO files (CRITICAL)
#   -w N        WARNING threshold
#   -c N        CRITICAL threshold
#   -f GLOB     Only files matching this name pattern (e.g. '*.csv')
#   -r          Recursive (include sub-directories). Default: top level only
#   -h          Help
#
# Examples:
#   check_dir.sh -d /data/in -d /data/out                       # both exist
#   check_dir.sh -d /data/in,/data/out -m count -w 100 -c 500   # backlog
#   check_dir.sh -d /vault/outgoing -m oldest -w 30 -c 60       # stuck files
#   check_dir.sh -d /data/in -m newest -f '*.csv' -w 60 -c 120  # nothing arrived
#   check_dir.sh -d /var/log -m size -r -w 5000 -c 10000        # size in MB
# =============================================================================

OK=0; WARNING=1; CRITICAL=2; UNKNOWN=3
DIRS=(); MODE="exists"; WARN=""; CRIT=""; GLOB=""; RECURSIVE=0

usage() { sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; exit $UNKNOWN; }
die()   { echo "UNKNOWN - $*"; exit $UNKNOWN; }

while getopts ":d:m:w:c:f:rh" opt; do
  case $opt in
    d) IFS=',' read -r -a parts <<< "$OPTARG"; DIRS+=("${parts[@]}") ;;
    m) MODE="$OPTARG" ;; w) WARN="$OPTARG" ;; c) CRIT="$OPTARG" ;;
    f) GLOB="$OPTARG" ;; r) RECURSIVE=1 ;; h) usage ;;
    :) die "option -$OPTARG requires an argument" ;;
    *) die "invalid option -$OPTARG (use -h)" ;;
  esac
done

[ ${#DIRS[@]} -eq 0 ] && die "at least one -d DIR is required"
case "$MODE" in
  exists|empty) ;;
  size|count|oldest|newest)
    [[ "$WARN" =~ ^[0-9]+$ ]] || die "-w must be a non-negative integer for mode $MODE"
    [[ "$CRIT" =~ ^[0-9]+$ ]] || die "-c must be a non-negative integer for mode $MODE" ;;
  *) die "unknown mode '$MODE' (exists|size|count|oldest|newest|empty)" ;;
esac

# list regular files of a dir as "mtime size" lines
list_files() {
  local depth=(-maxdepth 1); [ "$RECURSIVE" -eq 1 ] && depth=()
  local name=(); [ -n "$GLOB" ] && name=(-name "$GLOB")
  find "$1" "${depth[@]}" -type f "${name[@]}" -printf '%T@ %s\n' 2>/dev/null
}

worst=$OK; details=(); perf=""; now=$(date +%s)
raise() { [ "$1" -gt "$worst" ] && worst=$1; }

for d in "${DIRS[@]}"; do
  d="${d#"${d%%[![:space:]]*}"}"; d="${d%"${d##*[![:space:]]}"}"   # trim spaces
  [ -z "$d" ] && continue
  if [ ! -d "$d" ]; then details+=("$d: MISSING"); raise $CRITICAL; continue; fi
  if [ ! -r "$d" ] || [ ! -x "$d" ]; then details+=("$d: NOT READABLE"); raise $CRITICAL; continue; fi

  [ "$MODE" = "exists" ] && { details+=("$d: ok"); continue; }

  files=$(list_files "$d")
  n=$(printf '%s' "$files" | grep -c .)

  case "$MODE" in
    empty)
      if [ "$n" -eq 0 ]; then details+=("$d: EMPTY"); raise $CRITICAL
      else details+=("$d: $n file(s)"); fi
      perf+="'$d'=$n "; continue ;;
    count)  value=$n; unit="file(s)"; pu="" ;;
    size)   value=$(printf '%s\n' "$files" | awk '{s+=$2} END{printf "%d", s/1048576}')
            unit="MB"; pu="MB" ;;
    oldest|newest)
      if [ "$n" -eq 0 ]; then
        # no files: nothing is stuck (oldest=OK); nothing arrived (newest=CRITICAL)
        if [ "$MODE" = "oldest" ]; then details+=("$d: no files"); perf+="'$d'=0min;$WARN;$CRIT "
        else details+=("$d: NO FILES"); raise $CRITICAL; fi
        continue
      fi
      if [ "$MODE" = "oldest" ]; then t=$(printf '%s\n' "$files" | sort -n | head -n1 | cut -d' ' -f1)
      else t=$(printf '%s\n' "$files" | sort -n | tail -n1 | cut -d' ' -f1); fi
      value=$(( (now - ${t%.*}) / 60 )); [ "$value" -lt 0 ] && value=0
      unit="min ($MODE file)"; pu="min" ;;
  esac

  st=""
  if [ "$value" -ge "$CRIT" ]; then st="CRITICAL"; raise $CRITICAL
  elif [ "$value" -ge "$WARN" ]; then st="WARNING"; raise $WARNING; fi
  details+=("$d: $value $unit${st:+ $st}")
  perf+="'$d'=${value}${pu};$WARN;$CRIT "
done

case $worst in 0) status="OK" ;; 1) status="WARNING" ;; *) status="CRITICAL" ;; esac
msg=$(printf '%s; ' "${details[@]}"); msg=${msg%; }
echo "$status - [$MODE] $msg${perf:+ | ${perf% }}"
exit $worst
