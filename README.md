# alerts

Generic Bash check scripts for monitoring and scheduling tools (Nagios-style
plugins, Centerity, Control-M jobs). Linux only, no extra packages needed.

All scripts follow the Nagios plugin convention:

| Exit code | Meaning  |
|-----------|----------|
| 0         | OK       |
| 1         | WARNING  |
| 2         | CRITICAL |
| 3         | UNKNOWN (bad arguments, missing file, etc.) |

Output is one status line plus performance data after `|` (for graphs).
In Control-M, any non-zero exit code fails the job, so alerts / On-Do actions fire.

Run any script with `-h` for full help.

## check_log_pattern.sh — find an error in a log

Scans a log (or the newest file matching a glob in a directory) for a regex.
Remembers its position between runs, so each run checks **only new lines**.
Handles log rotation.

```bash
# CRITICAL on any ORA- error in the newest app*.log
./check_log_pattern.sh -d /opt/app/logs -f 'app*.log' -p 'ORA-[0-9]+'

# WARNING at 5 matches, CRITICAL at 20, ignore lines with "401"
./check_log_pattern.sh -F /var/log/asterisk/messages -p 'SIP/2.0 [45][0-9]{2}' -x 'SIP/2.0 401' -w 5 -c 20

# Also CRITICAL if the log was not written for 30 minutes
./check_log_pattern.sh -d /opt/app/logs -p 'ERROR' -a 30
```

Key options: `-p` pattern, `-x` exclude, `-i` ignore case, `-w`/`-c` match counts,
`-n` scan the whole file every run (no state), `-s` state directory
(default `/var/tmp/check_log_pattern`).

## check_cpu.sh — CPU usage

```bash
./check_cpu.sh -w 80 -c 95                          # total CPU %
./check_cpu.sh -m iowait -w 20 -c 40                # disk wait %
./check_cpu.sh -m load -w 1.5 -c 3                  # 1-min load per core
./check_cpu.sh -m process -p asterisk -w 50 -c 90   # one process (100% = one core)
```

`-t` sets the sample interval (default 3 seconds). With `-m process`, `-p` is an
exact process name; add `-f` to match a regex against the full command line.

## check_service.sh — is a service up

Every check given must pass; any failure is CRITICAL.

```bash
./check_service.sh -s asterisk                 # systemd unit active
./check_service.sh -p kamailio -n 4            # at least 4 processes
./check_service.sh -f -p 'java.*myapp.jar'     # full command-line match
./check_service.sh -P 5060                     # local TCP port open
./check_service.sh -H 10.0.0.5 -P 443 -T 3     # remote TCP port
./check_service.sh -s nginx -P 80              # both must pass
```

## Installing

```bash
chmod +x *.sh
# Nagios / Centreon style: copy to the plugins directory, e.g.
cp *.sh /usr/lib/nagios/plugins/
```

The user that runs the checks needs read access to the logs and write access
to the state directory.

## check_dir.sh — check one or more directories

Several directories in one check: repeat `-d` or comma-separate them. The final
status is the worst of all directories. A missing directory is always CRITICAL.

```bash
./check_dir.sh -d /data/in -d /data/out                        # both exist
./check_dir.sh -d /data/in,/data/out -m count -w 100 -c 500    # file backlog
./check_dir.sh -d /vault/outgoing -m oldest -w 30 -c 60        # files stuck > N min
./check_dir.sh -d /data/in -m newest -f '*.csv' -w 60 -c 120   # no new file for N min
./check_dir.sh -d /var/log -m size -r -w 5000 -c 10000         # total size in MB
./check_dir.sh -d /data/in,/data/out -m empty                  # CRITICAL if no files
```

Modes: `exists` (default), `size` (MB), `count`, `oldest` (minutes), `newest`
(minutes), `empty`. `-f` filters by file name pattern, `-r` includes sub-directories.
