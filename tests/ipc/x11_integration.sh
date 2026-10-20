#!/bin/sh
set -eu

DAEMON=${1:-./build/minnid}
CLI=${2:-./build/minni}
TEST_DIR=$(mktemp -d /tmp/minni-ipc-x11.XXXXXX)
trap 'jobs -p | xargs -r kill 2>/dev/null || true; rm -rf "$TEST_DIR"' EXIT INT TERM

mkdir -m 700 "$TEST_DIR/run"
SOCKET="$TEST_DIR/run/minni.sock"
"$DAEMON" --state-dir "$TEST_DIR/state" --socket "$SOCKET" &
DAEMON_PID=$!

for _ in $(seq 1 200); do
	[ -S "$SOCKET" ] && break
	sleep 0.02
done
[ -S "$SOCKET" ]

printf 'daemon clipboard round-trip\n' >"$TEST_DIR/input"
xclip -selection clipboard -in <"$TEST_DIR/input" &
XCLIP_PID=$!

ITEM_ID=
for _ in $(seq 1 200); do
	RESULT=$("$CLI" --socket "$SOCKET" --json search 'daemon clipboard round-trip')
	ITEM_ID=$(printf '%s' "$RESULT" | python3 -c 'import json,sys; x=json.load(sys.stdin)["result"]["items"]; print(x[0]["id"] if x else "")')
	[ -n "$ITEM_ID" ] && break
	sleep 0.02
done
[ -n "$ITEM_ID" ]

"$CLI" --socket "$SOCKET" --json copy "$ITEM_ID" >/dev/null
xclip -selection clipboard -out >"$TEST_DIR/output"
cmp "$TEST_DIR/input" "$TEST_DIR/output"

kill "$XCLIP_PID" 2>/dev/null || true
wait "$XCLIP_PID" 2>/dev/null || true
kill "$DAEMON_PID"
wait "$DAEMON_PID"

echo 'IPC X11 integration: 2 passed'
