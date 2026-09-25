#!/usr/bin/env bash
# run-m1.sh — the M1 test matrix. Prompts once for the password (kept in this
# process's environment only) and runs each blit-spike test for 20 seconds.
#
# Usage:
#   ./run-m1.sh user@host <openssh-port> <openssh-path> [<sftpgo-port> <sftpgo-path>]

set -uo pipefail

if [[ $# -lt 3 ]]; then
  sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
fi
TARGET=$1 PORT=$2 FILE=$3 SFTPGO_PORT=${4:-} SFTPGO_FILE=${5:-}
HOST=${TARGET#*@} USER_PART=${TARGET%@*}
BIN="$(cd "$(dirname "$0")" && pwd)/.build/release/blit-spike"
[[ -x "$BIN" ]] || { echo "build first: swift build -c release"; exit 1; }

read -r -s -p "Password for $TARGET: " BLIT_PASSWORD; echo
export BLIT_PASSWORD

OUT=$(mktemp "${TMPDIR:-/tmp}/blit-m1.XXXXXX")
trap 'rm -f "$OUT"' EXIT
spike() { "$BIN" "$@" 2>&1 | sed 's/^/  /'; echo; }

echo "== SSH channel throughput (cat over exec, no SFTP) =="
spike raw  "$USER_PART@$HOST:$PORT" "$FILE" --packet 32
spike raw  "$USER_PART@$HOST:$PORT" "$FILE" --packet 128
spike raw  "$USER_PART@$HOST:$PORT" "$FILE" --packet 128 --rcvbuf 7168
spike raw  "$USER_PART@$HOST:$PORT" "$FILE" --packet 256 --rcvbuf 7168

echo "== SFTP, one connection =="
spike sftp "$USER_PART@$HOST:$PORT" "$FILE" --packet 256 --rcvbuf 7168 --requests 64  --read 32
spike sftp "$USER_PART@$HOST:$PORT" "$FILE" --packet 256 --rcvbuf 7168 --requests 128 --read 64

echo "== SFTP, split across connections =="
spike sftp "$USER_PART@$HOST:$PORT" "$FILE" --packet 256 --rcvbuf 7168 --requests 128 --read 64 --conns 3
spike sftp "$USER_PART@$HOST:$PORT" "$FILE" --packet 256 --rcvbuf 7168 --requests 128 --read 64 --conns 4

if [[ -n "$SFTPGO_PORT" ]]; then
  echo "== SFTPGo endpoint: 64 KB requests with short-read handling =="
  spike sftp "$USER_PART@$HOST:$SFTPGO_PORT" "$SFTPGO_FILE" --packet 256 --rcvbuf 7168 --requests 128 --read 64
fi

echo "== Full download, 3 connections, verified against the server's sha256sum =="
spike sftp "$USER_PART@$HOST:$PORT" "$FILE" --packet 256 --rcvbuf 7168 --requests 128 --read 64 --conns 3 --seconds 0 --out "$OUT"
