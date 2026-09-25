#!/usr/bin/env bash
# run-m1b.sh — M1 follow-ups: SFTPGo short-read handling, full download with
# and without writing to disk (back to back), and 255 KB reads.
#
# Usage:
#   ./run-m1b.sh user@host <openssh-port> <openssh-path> <sftpgo-port> <sftpgo-path> [<sftpgo-fingerprint>]
#
# <sftpgo-fingerprint> (SHA256:…) pins the SFTPGo host key for this run when it
# isn't in ~/.ssh/known_hosts (for example, an Ed25519 key when only ECDSA is known).

set -uo pipefail

if [[ $# -lt 5 ]]; then
  sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
fi
TARGET=$1 PORT=$2 FILE=$3 SFTPGO_PORT=$4 SFTPGO_FILE=$5
TRUST=(); [[ -n "${6:-}" ]] && TRUST=(--trust "$6")
BIN="$(cd "$(dirname "$0")" && pwd)/.build/release/blit-spike"
[[ -x "$BIN" ]] || { echo "build first: swift build -c release"; exit 1; }

"$BIN" hostkey "$TARGET:$SFTPGO_PORT" ${TRUST[@]+"${TRUST[@]}"} | tee /dev/stderr | grep -q "^host key trusted" || {
  echo "Pass the SFTPGo host key's fingerprint (shown above) as the 6th argument after verifying it."
  exit 1
}

read -r -s -p "Password for $TARGET: " BLIT_PASSWORD; echo
export BLIT_PASSWORD

OUT=$(mktemp "${TMPDIR:-/tmp}/blit-m1b.XXXXXX")
trap 'rm -f "$OUT"' EXIT
spike() { "$BIN" "$@" 2>&1 | sed 's/^/  /'; echo; }
FAST=(--packet 256 --rcvbuf 7168 --requests 128 --read 64)

echo "== SFTPGo endpoint: 64 KB requests with short-read handling =="
spike sftp "$TARGET:$SFTPGO_PORT" "$SFTPGO_FILE" "${FAST[@]}" ${TRUST[@]+"${TRUST[@]}"}

echo "== One connection, 32 × 255 KB reads (OpenSSH max-read) =="
spike sftp "$TARGET:$PORT" "$FILE" --packet 256 --rcvbuf 7168 --requests 32 --read 255

echo "== Full download, 3 connections: discard vs. write to disk, back to back =="
for round in 1 2; do
  echo "-- round $round: discard"
  spike sftp "$TARGET:$PORT" "$FILE" "${FAST[@]}" --conns 3 --seconds 0
  echo "-- round $round: write + verify"
  spike sftp "$TARGET:$PORT" "$FILE" "${FAST[@]}" --conns 3 --seconds 0 --out "$OUT"
done
