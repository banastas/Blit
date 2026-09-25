#!/usr/bin/env bash
# sftp-probe.sh — quick 20-second-per-method SFTP speed probe.
#
# Downloads one file for up to 20 seconds with each method, reporting MB/s.
# Given a folder (trailing slash), it picks the largest file of 100 MB–1 GB. Use it to find out whether
# the server limits speed per connection before running sftp-bench.sh.
#
# Usage:
#   PORT=2222 ./sftp-probe.sh user@host /remote/folder/
#   PORT=2222 ./sftp-probe.sh user@host /remote/path/to/file.mkv
#
# Environment:
#   PORT=22         SFTP port
#   SHELL_PORT=     if set, also time a raw disk read on the server over SSH
#   SECONDS_EACH=20

set -uo pipefail

PORT=${PORT:-22}
LIMIT=${SECONDS_EACH:-20}
SHELL_PORT=${SHELL_PORT:-}

if [[ $# -lt 2 ]]; then
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
fi

TARGET=$1
REMOTE=$2
USER_PART=${TARGET%@*}
HOST=${TARGET#*@}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/sftp-probe.XXXXXX") || exit 1
# Stop a process and everything it started (lftp → ssh, sftp → ssh).
killtree() { local c; for c in $(pgrep -P "$1"); do killtree "$c"; done; kill "$1" 2>/dev/null; }
cleanup() { local c; for c in $(pgrep -P $$); do killtree "$c"; done; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'echo; exit 130' INT

read -r -s -p "SFTP password for $TARGET: " LFTP_PASSWORD; echo
export LFTP_PASSWORD
cat >"$WORK/askpass" <<'EOF'
#!/bin/sh
printf '%s\n' "$LFTP_PASSWORD"
EOF
chmod 700 "$WORK/askpass"
export SSH_ASKPASS="$WORK/askpass" SSH_ASKPASS_REQUIRE=force

lq() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; printf '"%s"' "$s"; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }

BASE="set sftp:connect-program 'ssh -a -x -o ControlMaster=no -o ControlPath=none -o Compression=no';
set net:timeout 30; set net:max-retries 2; set xfer:clobber on; set pget:save-status never;
open --env-password -u $(lq "$USER_PART") -p $PORT sftp://$HOST"
# 32 KB reads (what OpenSSH's sftp uses; 64 KB reads crawled at ~0.4 MB/s on
# this server) with 64 requests in flight = 2 MB, matching the SSH window.
TUNED="set sftp:max-packets-in-flight 64; set sftp:size-read 32768"

if [[ "$REMOTE" == */ ]]; then
echo "Listing ${REMOTE}…"
lftp -c "$BASE; find -l $(lq "$REMOTE")" 2>"$WORK/err" |
  sed -nE 's/^-[^ ]+ +[^ ]+ +([0-9]+) +[0-9-]+ +[0-9:]+ (.*)$/\1|\2/p' |
  awk -F'|' '$1 >= 1e8 && $1 <= 1e9' | sort -t'|' -k1,1nr >"$WORK/candidates"
FILE_LINE=$(sed -n 1p "$WORK/candidates")
if [[ -z "$FILE_LINE" ]]; then
  echo "error: no file between 100 MB and 1 GB found"; tail -3 "$WORK/err"; exit 1
fi
else
  size=$(lftp -c "$BASE; find -l $(lq "$REMOTE")" 2>"$WORK/err" | awk '{print $3; exit}')
  [[ "$size" =~ ^[0-9]+$ ]] || { echo "error: couldn't read $REMOTE"; tail -3 "$WORK/err"; exit 1; }
  FILE_LINE="$size|$REMOTE"
  : >"$WORK/candidates"
fi
FILE=${FILE_LINE#*|}
printf "Probe file: %s (%.0f MB)\n\n" "${FILE##*/}" "$(echo "${FILE_LINE%%|*} / 1000000" | bc -l)"

# Disk read speed on the server, on a different file than the probe file so it
# is less likely to be in the server's cache from our downloads.
if [[ -n "$SHELL_PORT" ]]; then
  DD_FILE=$(sed -n 2p "$WORK/candidates"); DD_FILE=${DD_FILE#*|}
  [[ -z "$DD_FILE" ]] && DD_FILE=$FILE
  printf "%-34s " "Server disk read (dd)"
  ssh -p "$SHELL_PORT" -o ControlMaster=no -o ControlPath=none "$TARGET" \
    "dd if=$(printf '%q' "$DD_FILE") of=/dev/null bs=1M 2>&1 | tail -1" 2>&1 |
    sed -E 's/.*copied, //' | tail -1
fi

# probe <label> <command...> — runs the command (which writes $WORK/out) for up to LIMIT seconds.
probe() {
  local label=$1; shift
  rm -f "$WORK/out"
  printf "%-34s " "$label"
  local t0 t1 pid kb secs
  t0=$(now)
  "$@" >"$WORK/log" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    sleep 0.5
    (( $(echo "$(now) - $t0 >= $LIMIT" | bc -l) )) && break
  done
  t1=$(now)
  killtree "$pid"; wait "$pid" 2>/dev/null
  # Allocated size, not apparent size: pget writes segments at offsets.
  kb=$(du -k "$WORK/out" 2>/dev/null | cut -f1)
  secs=$(echo "$t1 - $t0" | bc -l)
  if [[ -z "$kb" || "$kb" -eq 0 ]]; then
    echo "no data"; sed 's/^/    /' "$WORK/log" | tail -3
  else
    printf "%7.2f MB/s\n" "$(echo "$kb * 1024 / $secs / 1000000" | bc -l)"
  fi
  rm -f "$WORK/out"
}

sftp_get() {
  local q=${FILE//\\/\\\\}; q=${q//\"/\\\"}
  printf 'get "%s" "%s"\n' "$q" "$WORK/out" |
    sftp -q -P "$PORT" -o ControlMaster=no -o ControlPath=none "$TARGET"
}
lftp_get() { lftp -c "$BASE; ${1:+$1;} pget -n $2 $(lq "$FILE") -o $(lq "$WORK/out")"; }

probe "OpenSSH sftp (typical client)"   sftp_get
probe "lftp, 1 connection, defaults"     lftp_get ""       1
probe "lftp, 1 connection, 32 KB × 64"   lftp_get "$TUNED" 1
probe "lftp, 1 connection, 64 KB × 64"   lftp_get "set sftp:max-packets-in-flight 64; set sftp:size-read 65536" 1
probe "lftp, 4 connections"              lftp_get "$TUNED" 4
probe "lftp, 8 connections"              lftp_get "$TUNED" 8
probe "lftp, 16 connections"             lftp_get "$TUNED" 16
