#!/usr/bin/env bash
# =============================================================================
# check_log_pattern.sh
# Generic log-pattern checker — Nagios plugin / Control-M job compatible.
#
# Scans a log file (or the newest file matching a glob in a directory) for a
# regex pattern. Remembers the last read position (offset + inode) so each run
# checks only NEW lines. Handles log rotation / truncation.
#
# Exit codes (Nagios standard; any non-zero fails a Control-M job):
#   0 = OK   1 = WARNING   2 = CRITICAL   3 = UNKNOWN
#
# Usage:
#   check_log_pattern.sh -d DIR [-f GLOB] -p PATTERN [options]
#   check_log_pattern.sh -F /path/to/file.log -p PATTERN [options]
#
# Options:
#   -d DIR      Directory containing the log
#   -f GLOB     File name glob inside DIR (default: *.log) — newest match is used
#   -F FILE     Explicit log file (instead of -d/-f)
#   -p REGEX    Pattern to search (extended regex, grep -E)
#   -x REGEX    Exclude lines matching this regex (optional)
#   -i          Case-insensitive match
#   -w N        WARNING if matches >= N   (default: disabled)
#   -c N        CRITICAL if matches >= N  (default: 1)
#   -a MIN      CRITICAL if log not modified for MIN minutes (stale log check)
#   -l N        Number of matching lines to show in output (default: 3)
#   -s DIR      State directory (default: /var/tmp/check_log_pattern)
#   -n          No state — scan the whole file every run
#   -h          Help
#
# Examples:
#   # Alert CRITICAL on any "ORA-" error in newest app*.log
#   check_log_pattern.sh -d /opt/app/logs -f 'app*.log' -p 'ORA-[0-9]+'
#
#   # SIP errors: WARNING at 5, CRITICAL at 20, ignore 401 auth challenges
#   check_log_pattern.sh -F /var/log/asterisk/messages -p 'SIP/2.0 [45][0-9]{2}' \
#       -x 'SIP/2.0 401' -w 5 -c 20
# =============================================================================

OK=0; WARNING=1; CRITICAL=2; UNKNOWN=3

DIR=""; GLOB="*.log"; FILE=""; PATTERN=""; EXCLUDE=""
ICASE=""; WARN=0; CRIT=1; MAXAGE=0; SHOWLINES=3
STATEDIR="/var/tmp/check_log_pattern"; NOSTATE=0

usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit $UNKNOWN; }
die()   { echo "UNKNOWN - $*"; exit $UNKNOWN; }

while getopts ":d:f:F:p:x:iw:c:a:l:s:nh" opt; do
  case $opt in
    d) DIR="$OPTARG" ;;   f) GLOB="$OPTARG" ;;   F) FILE="$OPTARG" ;;
    p) PATTERN="$OPTARG" ;; x) EXCLUDE="$OPTARG" ;; i) ICASE="-i" ;;
    w) WARN="$OPTARG" ;;  c) CRIT="$OPTARG" ;;   a) MAXAGE="$OPTARG" ;;
    l) SHOWLINES="$OPTARG" ;; s) STATEDIR="$OPTARG" ;; n) NOSTATE=1 ;;
    h) usage ;;
    :) die "option -$OPTARG requires an argument" ;;
    *) die "invalid option -$OPTARG (use -h)" ;;
  esac
done

[ -z "$PATTERN" ] && die "pattern (-p) is required"
for v in WARN CRIT MAXAGE SHOWLINES; do
  [[ "${!v}" =~ ^[0-9]+$ ]] || die "$v must be a non-negative integer"
done

# --- Resolve the log file ----------------------------------------------------
if [ -z "$FILE" ]; then
  [ -z "$DIR" ] && die "either -F FILE or -d DIR is required"
  [ -d "$DIR" ] || die "directory not found: $DIR"
  # newest file matching the glob
  FILE=$(ls -1t -- "$DIR"/$GLOB 2>/dev/null | head -n 1)
  [ -z "$FILE" ] && die "no file matching '$GLOB' in $DIR"
fi
[ -f "$FILE" ] || die "log file not found: $FILE"
[ -r "$FILE" ] || die "log file not readable: $FILE"

# --- Stale log check ---------------------------------------------------------
if [ "$MAXAGE" -gt 0 ]; then
  now=$(date +%s); mtime=$(stat -c %Y -- "$FILE")
  age=$(( (now - mtime) / 60 ))
  if [ "$age" -ge "$MAXAGE" ]; then
    echo "CRITICAL - log $FILE not updated for ${age} min (limit ${MAXAGE}) | matches=0;$WARN;$CRIT;0"
    exit $CRITICAL
  fi
fi

# --- Determine read range (state) -------------------------------------------
size=$(stat -c %s -- "$FILE")
inode=$(stat -c %i -- "$FILE")
offset=0

if [ "$NOSTATE" -eq 0 ]; then
  mkdir -p "$STATEDIR" 2>/dev/null || die "cannot create state dir $STATEDIR"
  key=$(printf '%s|%s|%s|%s|%s' "$DIR" "$GLOB" "$FILE" "$PATTERN" "$EXCLUDE" | md5sum | cut -c1-16)
  STATEFILE="$STATEDIR/$key.state"
  if [ -f "$STATEFILE" ]; then
    read -r s_inode s_offset < "$STATEFILE"
    # same file and not truncated -> continue from last offset; else rotation
    if [ "$s_inode" = "$inode" ] && [ "${s_offset:-0}" -le "$size" ]; then
      offset=$s_offset
    fi
  fi
fi

# --- Scan new content --------------------------------------------------------
count=0; sample=""
if [ "$size" -gt "$offset" ]; then
  matches=$(tail -c +$((offset + 1)) -- "$FILE" | head -c $((size - offset)) \
            | grep -E $ICASE -- "$PATTERN")
  if [ -n "$matches" ] && [ -n "$EXCLUDE" ]; then
    matches=$(printf '%s\n' "$matches" | grep -vE $ICASE -- "$EXCLUDE")
  fi
  if [ -n "$matches" ]; then
    count=$(printf '%s\n' "$matches" | wc -l)
    sample=$(printf '%s\n' "$matches" | tail -n "$SHOWLINES")
  fi
fi

# save new position only after a successful read
if [ "$NOSTATE" -eq 0 ]; then
  echo "$inode $size" > "$STATEFILE" || die "cannot write state file $STATEFILE"
fi

# --- Evaluate ----------------------------------------------------------------
perf="matches=$count;$WARN;$CRIT;0"
name=$(basename -- "$FILE")

if [ "$CRIT" -gt 0 ] && [ "$count" -ge "$CRIT" ]; then
  status="CRITICAL"; rc=$CRITICAL
elif [ "$WARN" -gt 0 ] && [ "$count" -ge "$WARN" ]; then
  status="WARNING"; rc=$WARNING
else
  status="OK"; rc=$OK
fi

echo "$status - $count match(es) of '$PATTERN' in $name | $perf"
[ -n "$sample" ] && [ "$rc" -ne $OK ] && printf '%s\n' "$sample"
exit $rc
