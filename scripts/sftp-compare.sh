#!/usr/bin/env bash
# sftp-compare.sh — Blit's engine against rclone and lftp on the same file.
#
# Downloads one whole file with each method and reports MB/s, login
# included for all. A warm-up read goes first (not reported) so every method
# finds the file in the server's cache, rather than the first one paying for
# the disk. Use a file of about 1–3 GB; given a folder (trailing slash), it
# picks the largest file there of 0.5–3 GB.
#
# Usage:
#   PORT=2222 scripts/sftp-compare.sh user@host "path/to/file.mkv"
#   PORT=2222 scripts/sftp-compare.sh user@host "path/to/folder/"
#
# Environment:
#   PORT=22      SFTP port
#   ROUNDS=1     runs per method (the best is reported)
#
# Needs lftp and rclone (brew install lftp rclone) and Xcode (it builds the
# blit tool). The password is asked for once and passed only through
# environment variables (rclone's in its obscured form, read from stdin),
# never written to disk. Downloads go to a temporary folder deleted afterward.

set -uo pipefail

PORT=${PORT:-22}
ROUNDS=${ROUNDS:-1}

if [[ $# -lt 2 ]]; then
  sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
fi
for tool in lftp rclone; do
  command -v "$tool" >/dev/null || { echo "error: $tool isn't installed (brew install $tool)"; exit 1; }
done

TARGET=$1
FILE=$2
USER_PART=${TARGET%@*}
HOST=${TARGET#*@}
ROOT=$(cd "$(dirname "$0")/.." && pwd)

WORK=$(mktemp -d "${TMPDIR:-/tmp}/sftp-compare.XXXXXX") || exit 1
killtree() { local c; for c in $(pgrep -P "$1"); do killtree "$c"; done; kill "$1" 2>/dev/null; }
cleanup() { local c; for c in $(pgrep -P $$); do killtree "$c"; done; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'echo; exit 130' INT

echo "Building the blit tool (release)…"
DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer} \
  swift build -c release --package-path "$ROOT/BlitKit" --product blit >"$WORK/build.log" 2>&1 ||
  { echo "error: the build failed"; tail -20 "$WORK/build.log"; exit 1; }
BLIT="$ROOT/BlitKit/.build/release/blit"

read -r -s -p "SFTP password for $TARGET: " PASSWORD; echo
export LFTP_PASSWORD=$PASSWORD BLIT_PASSWORD=$PASSWORD
RCLONE_SFTP_PASS=$(printf '%s' "$PASSWORD" | rclone obscure -) || { echo "error: rclone obscure failed"; exit 1; }
export RCLONE_SFTP_PASS
unset PASSWORD

lq() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; printf '"%s"' "$s"; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }

BASE="set sftp:connect-program 'ssh -a -x -o ControlMaster=no -o ControlPath=none -o Compression=no';
set net:timeout 30; set net:max-retries 2; set xfer:clobber on; set pget:save-status never;
open --env-password -u $(lq "$USER_PART") -p $PORT sftp://$HOST"
TUNED="set sftp:max-packets-in-flight 64; set sftp:size-read 32768"

if [[ "$FILE" == */ ]]; then
  echo "Listing ${FILE}…"
  LINE=$(lftp -c "$BASE; find -l $(lq "$FILE")" 2>"$WORK/err" |
    sed -nE 's/^-[^ ]+ +[^ ]+ +([0-9]+) +[0-9-]+ +[0-9:]+ (.*)$/\1|\2/p' |
    awk -F'|' '$1 >= 5e8 && $1 <= 3e9' | sort -t'|' -k1,1nr | head -1)
  [[ -n "$LINE" ]] || { echo "error: no file of 0.5–3 GB found there"; tail -3 "$WORK/err"; exit 1; }
  FILE=${LINE#*|}
fi
SIZE=$(lftp -c "$BASE; find -l $(lq "$FILE")" 2>"$WORK/err" | awk '{print $3; exit}')
[[ "$SIZE" =~ ^[0-9]+$ ]] || { echo "error: couldn't read $FILE"; tail -3 "$WORK/err"; exit 1; }
printf "File: %s (%.0f MB)\n\n" "${FILE##*/}" "$(echo "$SIZE / 1000000" | bc -l)"

lftp_get()  { lftp -c "$BASE; $TUNED; pget -n $1 $(lq "$FILE") -o $(lq "$WORK/dl/out")"; }
# rclone on the fly (no saved config): multi-thread download, no shell
# commands on the server (an SFTP-only endpoint has none), no hash check.
rclone_get() {
  rclone copyto ":sftp:$FILE" "$WORK/dl/out" -q --stats 0 \
    --sftp-host "$HOST" --sftp-user "$USER_PART" --sftp-port "$PORT" \
    --sftp-shell-type none --sftp-disable-hashcheck \
    --multi-thread-cutoff 1M --multi-thread-streams "$1" "${@:2}"
}
blit_get() { "$BLIT" get "$USER_PART@$HOST:$PORT" "$FILE" "$WORK/dl" --conns "$1" "${@:2}"; }

# run <label> <command...> — downloads the whole file, prints MB/s.
run() {
  local label=$1; shift
  local best=0 round t0 t1 bytes rate
  printf "%-44s " "$label"
  for ((round = 1; round <= ROUNDS; round++)); do
    rm -rf "$WORK/dl"; mkdir -p "$WORK/dl"
    t0=$(now)
    "$@" >"$WORK/log" 2>&1 </dev/null
    t1=$(now)
    bytes=$(find "$WORK/dl" -type f -exec stat -f %z {} + 2>/dev/null | awk '{s += $1} END {print s + 0}')
    if [[ "$bytes" -ne "$SIZE" ]]; then
      echo "failed (got $bytes of $SIZE bytes)"; sed 's/^/    /' "$WORK/log" | tail -3; return
    fi
    rate=$(echo "$SIZE / ($t1 - $t0) / 1000000" | bc -l)
    (( $(echo "$rate > $best" | bc -l) )) && best=$rate
  done
  printf "%7.1f MB/s\n" "$best"
  rm -rf "$WORK/dl"
}

# Blit checks host keys against its own store and ~/.ssh/known_hosts; a first
# listing here (not timed) asks about an unknown key where you can answer.
"$BLIT" ls "$USER_PART@$HOST:$PORT" "$(dirname "$FILE")" >/dev/null || { echo "error: blit couldn't list the folder"; exit 1; }

printf "%-44s " "Warm-up read (not counted)"; mkdir -p "$WORK/dl"; lftp_get 8 >/dev/null 2>&1 </dev/null; echo done; rm -rf "$WORK/dl"

run "lftp, 8 connections (32 KB × 64)"             lftp_get 8
run "rclone, defaults (4 streams)"                  rclone_get 4
run "rclone, 3 streams, 255 KB chunks × 64"         rclone_get 3 --sftp-chunk-size 255k --sftp-concurrency 64
run "rclone, 8 streams, 255 KB chunks × 64"         rclone_get 8 --sftp-chunk-size 255k --sftp-concurrency 64
run "blit, 3 connections, no SHA-256"               blit_get 3 --no-verify
run "blit, 3 connections, SHA-256 checked"          blit_get 3
run "blit, 4 connections, no SHA-256"               blit_get 4 --no-verify
