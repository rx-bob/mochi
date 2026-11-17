#!/bin/sh
set -eu

if [ "$#" -lt 3 ]; then
  echo "usage: $0 SECONDS LOGFILE COMMAND [ARG...]" >&2
  exit 2
fi

seconds=$1
log=$2
shift 2

case "$seconds" in
  ''|*[!0-9]*)
    echo "error: SECONDS must be a positive integer" >&2
    exit 2
    ;;
esac
if [ "$seconds" -le 0 ]; then
  echo "error: SECONDS must be a positive integer" >&2
  exit 2
fi

log_dir=$(dirname -- "$log")
mkdir -p "$log_dir"
: > "$log"

"$@" > "$log" 2>&1 &
pid=$!
started=$(date +%s)

while kill -0 "$pid" 2>/dev/null; do
  now=$(date +%s)
  elapsed=$((now - started))
  if [ "$elapsed" -ge "$seconds" ]; then
    echo "timeout after ${seconds}s: $*" >&2
    kill -TERM "$pid" 2>/dev/null || true
    sleep 2
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    echo "last log lines ($log):" >&2
    tail -40 "$log" >&2 || true
    exit 124
  fi
  sleep 1
done

status=0
wait "$pid" || status=$?
if [ "$status" -ne 0 ]; then
  echo "command failed with status ${status}: $*" >&2
  echo "last log lines ($log):" >&2
  tail -40 "$log" >&2 || true
fi
exit "$status"
