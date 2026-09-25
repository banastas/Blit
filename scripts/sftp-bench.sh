#!/usr/bin/env bash
# sftp-bench.sh — measure how SFTP download speed scales with parallel connections.
#
# Folder mode picks a ~2.5 GB set of files and downloads it with N files in
# flight at once. File mode (or a folder containing a file of 1 GB or more)
# also splits one large file into N segments. Every run is SHA-256 checked
# against the first run and against the server.
#
# Usage:
#   ./sftp-bench.sh user@host /remote/folder/ [local_dir]
#   ./sftp-bench.sh user@host /remote/path/to/bigfile [local_dir]
#
# Environment:
#   STREAMS="1 4 8 16"   connection counts to test
#   PORT=22              SFTP port
#   SSH_PORT=$PORT       SSH shell port, for the server-side checksum
#   KEY=1                use SSH key auth (no password prompt)
#   VERIFY=0             skip the server-side SHA-256 check

set -uo pipefail

STREAMS=${STREAMS:-"1 4 8 16"}
PORT=${PORT:-22}
SSH_PORT=${SSH_PORT:-$PORT}
KEY=${KEY:-0}
VERIFY=${VERIFY:-1}

if [[ $# -lt 2 ]]; then
  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
fi

TARGET=$1
REMOTE=$2
USER_PART=${TARGET%@*}
HOST=${TARGET#*@}
[[ "$USER_PART" == "$TARGET" ]] && { echo "error: first argument must be user@host"; exit 1; }

for t in lftp ssh shasum perl bc; do
  command -v "$t" >/dev/null || { echo "error: $t not found"; exit 1; }
done

# lftp can't answer an unknown-host-key prompt; make sure the key is trusted.
if ! ssh-keygen -F "$HOST" >/dev/null 2>&1 && ! ssh-keygen -F "[$HOST]:$PORT" >/dev/null 2>&1; then
  echo "The host key for $HOST isn't in ~/.ssh/known_hosts yet."
  echo "Connect once to verify and accept it, then re-run this script:"
  echo "  ssh -p $PORT $TARGET exit"
  exit 1
fi

WORK=$(mktemp -d "${3:-${TMPDIR:-/tmp}}/sftp-bench.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

SSH_OPTS=(-p "$SSH_PORT" -o ControlMaster=no -o ControlPath=none)
if [[ "$KEY" == 1 ]]; then
  LOGIN="-u \"$USER_PART,\""
else
  read -r -s -p "SFTP password for $TARGET: " LFTP_PASSWORD; echo
  export LFTP_PASSWORD
  LOGIN="--env-password -u \"$USER_PART\""
  # Let the server-side checksum reuse the password (read from the
  # environment; it is never written to disk).
  cat >"$WORK/askpass" <<'EOF'
#!/bin/sh
printf '%s\n' "$LFTP_PASSWORD"
EOF
  chmod 700 "$WORK/askpass"
  export SSH_ASKPASS="$WORK/askpass" SSH_ASKPASS_REQUIRE=force
fi

# Quote a string for an lftp command line.
lq() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; printf '"%s"' "$s"; }

# Separate ssh processes per connection (no multiplexing), no compression,
# and 64 × 32 KB read requests in flight (2 MB, matching the SSH window).
# 64 KB reads crawled at ~0.4 MB/s on an SFTPGo server, so stay at 32 KB.
LFTP_SETUP="set sftp:connect-program 'ssh -a -x -o ControlMaster=no -o ControlPath=none -o Compression=no';
set sftp:max-packets-in-flight 64;
set sftp:size-read 32768;
set net:timeout 30; set net:max-retries 3; set net:reconnect-interval-base 2;
set xfer:clobber on; set pget:save-status never; set cmd:fail-exit yes;
open $LOGIN -p $PORT sftp://$HOST"

now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
gb() { printf "%.2f GB" "$(echo "$1 / 1000000000" | bc -l)"; }

# Digest of "sha256  ./relative/path" lines for every file under a folder,
# in the same format GNU sha256sum produces on the server.
hash_dir() {
  (cd "$1" && LC_ALL=C find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256) |
    shasum -a 256 | awk '{print $1}'
}
remote_hash_dir() {
  local out
  out=$(ssh "${SSH_OPTS[@]}" "$TARGET" \
    "cd -- $(printf '%q' "$1") && LC_ALL=C find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum" 2>/dev/null)
  [[ -n "$out" ]] && printf '%s\n' "$out" | shasum -a 256 | awk '{print $1}'
}
remote_hash_file() {
  ssh "${SSH_OPTS[@]}" "$TARGET" "sha256sum -- $(printf '%q' "$1")" 2>/dev/null | awk '{print $1}'
}

SET_DIR="" BIG_FILE="" BIG_SIZE=0
if [[ "$REMOTE" == */ ]]; then
  echo "Listing ${REMOTE}…"
  lftp -c "$LFTP_SETUP; find -l $(lq "$REMOTE")" 2>"$WORK/find.err" |
    sed -nE 's/^-[^ ]+ +[^ ]+ +([0-9]+) +[0-9-]+ +[0-9:]+ (.*)$/\1|\2/p' >"$WORK/listing"
  if [[ ! -s "$WORK/listing" ]]; then
    echo "error: couldn't list any files in $REMOTE"; sed 's/^/    /' "$WORK/find.err" | tail -3; exit 1
  fi
  # Candidates: the folder itself and each top-level subfolder. Pick the one
  # whose total is closest to 2.5 GB; also note the largest single file.
  PICKS=$(R="$REMOTE" awk -F'|' '
    { s=$1; p=substr($0, index($0, "|") + 1); R=ENVIRON["R"]; rel=substr(p, length(R) + 1)
      tot[R]+=s; cnt[R]++
      i=index(rel, "/"); if (i > 0) { d=R substr(rel, 1, i); tot[d]+=s; cnt[d]++ }
      if (s > ms) { ms=s; mp=p } }
    END { for (pass=1; pass<=2 && best==""; pass++)   # prefer folders with 8+ files
            for (d in tot) { if (pass==1 && cnt[d]<8) continue
              x=tot[d]-2.5e9; if (x<0) x=-x; if (best=="" || x<bx) { best=d; bx=x } }
          print tot[best] "|" cnt[best] "|" best; print ms "|" mp }' "$WORK/listing")
  SET_LINE=${PICKS%%$'\n'*}; BIG_LINE=${PICKS#*$'\n'}
  IFS='|' read -r SET_SIZE SET_COUNT SET_DIR <<<"$SET_LINE"
  BIG_SIZE=${BIG_LINE%%|*}; BIG_FILE=${BIG_LINE#*|}
  echo "Parallel-files test: $SET_DIR"
  echo "    $SET_COUNT files, $(gb "$SET_SIZE")"
  if (( BIG_SIZE >= 1000000000 )); then
    echo "Split-file test:     $BIG_FILE ($(gb "$BIG_SIZE"))"
  else
    echo "Split-file test:     skipped (largest file is $(gb "$BIG_SIZE"); needs 1 GB+)"
    BIG_FILE=""
  fi
  NEED=$(( SET_SIZE > BIG_SIZE ? SET_SIZE : BIG_SIZE ))
else
  BIG_FILE=$REMOTE
  BIG_SIZE=$(lftp -c "$LFTP_SETUP; find -l $(lq "$REMOTE")" 2>/dev/null | awk '{print $3; exit}')
  [[ "$BIG_SIZE" =~ ^[0-9]+$ ]] || { echo "error: couldn't read $REMOTE"; exit 1; }
  echo "Split-file test: $BIG_FILE ($(gb "$BIG_SIZE"))"
  NEED=$BIG_SIZE
fi

FREE=$(df -k "$WORK" | awk 'NR==2 {print $4 * 1024}')
if (( FREE < NEED + 1000000000 )); then
  echo "error: not enough free space in $(dirname "$WORK")"; exit 1
fi
read -r -p "Start? [Y/n] " ok
[[ "$ok" =~ ^[Nn] ]] && exit 0

# run_series <label> <kind: dir|file> <remote> — fills TABLE and REF.
run_series() {
  local label=$1 kind=$2 remote=$3 n out cmd t0 t1 bytes secs mbps hash check
  TABLE=() REF=""
  echo; echo "== $label =="
  for n in $STREAMS; do
    out="$WORK/$kind-$n"
    printf "▶ %2d connection(s)… " "$n"
    if [[ $kind == dir ]]; then
      cmd="mirror --parallel=$n $(lq "$remote") $(lq "$out")"
    else
      cmd="pget -n $n $(lq "$remote") -o $(lq "$out")"
    fi
    t0=$(now)
    if ! lftp -c "$LFTP_SETUP; $cmd" >"$WORK/log" 2>&1; then
      echo "FAILED"; sed 's/^/    /' "$WORK/log" | tail -5
      TABLE+=("$n|failed||"); rm -rf "$out"; continue
    fi
    t1=$(now)
    if [[ $kind == dir ]]; then
      bytes=$(find "$out" -type f -exec stat -f%z {} + | awk '{s+=$1} END {print s+0}')
      hash=$(hash_dir "$out")
    else
      bytes=$(stat -f%z "$out")
      hash=$(shasum -a 256 "$out" | awk '{print $1}')
    fi
    secs=$(echo "$t1 - $t0" | bc -l)
    mbps=$(echo "$bytes / $secs / 1000000" | bc -l)
    if [[ -z "$REF" ]]; then REF=$hash; check="reference"
    elif [[ "$hash" == "$REF" ]]; then check="match"
    else check="MISMATCH"; fi
    printf "%.1f MB/s (%.0f s)  %s\n" "$mbps" "$secs" "$check"
    TABLE+=("$n|$(printf %.1f "$mbps")|$(printf %.0f "$secs")|$check")
    rm -rf "$out"
  done
}

# print_series <server hash> — prints TABLE, sets BEST.
print_series() {
  local r n mbps secs check server="skipped"
  if [[ "$VERIFY" == 1 && -n "$REF" ]]; then
    if [[ -z "$1" ]]; then server="unavailable (no shell access?)"
    elif [[ "$1" == "$REF" ]]; then server="match"
    else server="MISMATCH"; fi
  fi
  echo "────────────────────────────────────────────"
  printf "%-12s %10s %8s  %s\n" "Connections" "MB/s" "Seconds" "Integrity"
  echo "────────────────────────────────────────────"
  BEST=0
  for r in "${TABLE[@]}"; do
    IFS='|' read -r n mbps secs check <<<"$r"
    printf "%-12s %10s %8s  %s\n" "$n" "$mbps" "$secs" "$check"
    [[ "$mbps" =~ ^[0-9.]+$ ]] && (( $(echo "$mbps > $BEST" | bc -l) )) && BEST=$mbps
  done
  echo "────────────────────────────────────────────"
  echo "Server-side SHA-256: $server"
}

SUMMARY=()
if [[ -n "$SET_DIR" ]]; then
  run_series "Parallel files: $SET_COUNT files, $(gb "$SET_SIZE")" dir "$SET_DIR"
  D_TABLE=("${TABLE[@]}") D_REF=$REF D_RHASH=""
  if [[ "$VERIFY" == 1 && -n "$D_REF" ]]; then echo "Checksumming on the server…"; D_RHASH=$(remote_hash_dir "$SET_DIR"); fi
fi
if [[ -n "$BIG_FILE" ]]; then
  run_series "Split file: $(gb "$BIG_SIZE")" file "$BIG_FILE"
  F_TABLE=("${TABLE[@]}") F_REF=$REF F_RHASH=""
  if [[ "$VERIFY" == 1 && -n "$F_REF" ]]; then echo "Checksumming on the server…"; F_RHASH=$(remote_hash_file "$BIG_FILE"); fi
fi

echo
if [[ -n "$SET_DIR" ]]; then
  echo "PARALLEL FILES ($SET_COUNT files, $(gb "$SET_SIZE"))"
  TABLE=("${D_TABLE[@]}") REF=$D_REF; print_series "$D_RHASH"
  SUMMARY+=("parallel files|$BEST")
  echo
fi
if [[ -n "$BIG_FILE" ]]; then
  echo "SPLIT FILE ($(gb "$BIG_SIZE"))"
  TABLE=("${F_TABLE[@]}") REF=$F_REF; print_series "$F_RHASH"
  SUMMARY+=("split file|$BEST")
  echo
fi
for s in "${SUMMARY[@]}"; do
  rate=${s#*|}
  if (( $(echo "$rate > 0" | bc -l) )); then
    printf "Best %-15s %6.1f MB/s → 22.5 TB/month = %.1f days of transfer\n" \
      "${s%%|*}:" "$rate" "$(echo "22500000 / $rate / 86400" | bc -l)"
  fi
done
