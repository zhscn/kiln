#!/usr/bin/env bash
# Drives a kiln process that serves the back-end protocol
# from the shell: for people and agents.
#
#   tools/kiln-server.sh start [EXE]     start the server (EXE: build/boot/kiln1)
#   tools/kiln-server.sh eval TEXT       evaluate the forms of TEXT
#   tools/kiln-server.sh restart N [TEXT]  invoke restart N of the innermost
#                                        debug level (TEXT: its arguments)
#   tools/kiln-server.sh frame N         frame N of the innermost debug level
#   tools/kiln-server.sh eval-in-frame N TEXT
#                                        evaluate with frame N's variables bound
#   tools/kiln-server.sh package NAME    set *PACKAGE*
#   tools/kiln-server.sh send REQUEST    send a request as it is
#   tools/kiln-server.sh stop
#
# Each command prints the replies to its request, one per line, up to the
# server's (:waiting LEVEL). The server's directory is $KILN_SERVER_DIR
# (default build/server): in (a FIFO), out (all replies), pid.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
dir=$(realpath -m "${KILN_SERVER_DIR:-$root/build/server}")

quote() {
  # TEXT as a Lisp string.
  local s=${1//\\/\\\\}
  printf '"%s"' "${s//\"/\\\"}"
}

running() {
  [ -f "$dir/pid" ] && kill -0 "$(cat "$dir/pid")" 2>/dev/null
}

# Sends REQUEST and prints the replies after it up to (:waiting ...).
request() {
  running || { echo "kiln-server: not running" >&2; exit 1; }
  local start
  start=$(stat -c %s "$dir/out")
  printf '%s\n' "$1" >"$dir/in"
  while :; do
    if tail -c +$((start + 1)) "$dir/out" | grep -q '^(:waiting '; then
      tail -c +$((start + 1)) "$dir/out" | sed -n '1,/^(:waiting /p'
      return
    fi
    running || { tail -c +$((start + 1)) "$dir/out"; echo "kiln-server: exited" >&2; exit 1; }
    sleep 0.05
  done
}

next_id() {
  local n
  n=$(( $(cat "$dir/id" 2>/dev/null || echo 0) + 1 ))
  echo "$n" >"$dir/id"
  echo "$n"
}

cmd=${1:-}
shift || true
case "$cmd" in
  start)
    exe=$(realpath "${1:-$root/build/boot/kiln1}")
    running && { echo "kiln-server: already running" >&2; exit 1; }
    mkdir -p "$dir"
    rm -f "$dir/in" "$dir/out" "$dir/id"
    mkfifo "$dir/in"
    : >"$dir/out"
    # A writer that never writes keeps the FIFO open between requests.
    (cd "$dir" && KILN_SERVE=1 nohup "$exe" <"$dir/in" >>"$dir/out" 2>&1 & echo $! >"$dir/pid")
    sleep infinity >"$dir/in" &
    echo $! >"$dir/holder"
    # The first (:waiting 0).
    for _ in $(seq 600); do
      grep -q '^(:waiting ' "$dir/out" && { cat "$dir/out"; exit 0; }
      running || { cat "$dir/out"; echo "kiln-server: exited" >&2; exit 1; }
      sleep 0.05
    done
    echo "kiln-server: no reply" >&2; exit 1 ;;
  eval) request "(:eval $(next_id) $(quote "$1"))" ;;
  restart) request "(:restart $(next_id) $1${2:+ $(quote "$2")})" ;;
  frame) request "(:frame $(next_id) $1)" ;;
  eval-in-frame) request "(:eval-in-frame $(next_id) $1 $(quote "$2"))" ;;
  package) request "(:package $(next_id) $(quote "$1"))" ;;
  send) request "$1" ;;
  stop)
    if running; then
      printf '(:quit 0)\n' >"$dir/in" || true
      sleep 0.2
      kill "$(cat "$dir/pid")" 2>/dev/null || true
    fi
    [ -f "$dir/holder" ] && kill "$(cat "$dir/holder")" 2>/dev/null || true
    rm -f "$dir/pid" "$dir/holder" ;;
  *)
    sed -n '2,20p' "$0" >&2
    exit 1 ;;
esac
