#!/bin/sh
set -eu

DAEMON=${1:-./build/minnid}
CLI=${2:-./build/minni}
TEST_DIR=$(mktemp -d /tmp/minni-ipc-x11.XXXXXX)
trap 'jobs -p | xargs -r kill 2>/dev/null || true; rm -rf "$TEST_DIR"' EXIT INT TERM

mkdir -m 700 "$TEST_DIR/run"
SOCKET="$TEST_DIR/run/minni.sock"
DAEMON_PID=

start_daemon() {
	"$DAEMON" --state-dir "$TEST_DIR/state" --cache-dir "$TEST_DIR/cache" \
		--socket "$SOCKET" &
	DAEMON_PID=$!
	for _ in $(seq 1 200); do
		[ -S "$SOCKET" ] && return
		sleep 0.02
	done
	return 1
}

stop_daemon() {
	kill "$DAEMON_PID"
	wait "$DAEMON_PID"
	DAEMON_PID=
}

if DISPLAY=:987 "$DAEMON" --state-dir "$TEST_DIR/invalid-state" \
		--cache-dir "$TEST_DIR/cache" --socket "$SOCKET" 2>/dev/null; then
	exit 1
fi
[ ! -S "$SOCKET" ]

start_daemon

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
xsel --clipboard --output >"$TEST_DIR/output"
cmp "$TEST_DIR/input" "$TEST_DIR/output"

kill "$XCLIP_PID" 2>/dev/null || true
wait "$XCLIP_PID" 2>/dev/null || true

magick -size 96x64 gradient: PNG24:"$TEST_DIR/image.png"
if python3 -c 'import PyQt6' 2>/dev/null; then
	python3 "$(dirname "$0")/qt_clipboard.py" put image/png "$TEST_DIR/image.png" &
	XCLIP_PID=$!
else
	xclip -selection clipboard -target image/png -in <"$TEST_DIR/image.png" &
	XCLIP_PID=$!
fi
IMAGE_ID=
for _ in $(seq 1 200); do
	RESULT=$("$CLI" --socket "$SOCKET" --json list --limit 20)
	IMAGE_ID=$(printf '%s' "$RESULT" | python3 -c 'import json,sys; x=json.load(sys.stdin)["result"]["items"]; print(next((i["id"] for i in x if i["kind"] == "image"), ""))')
	[ -n "$IMAGE_ID" ] && break
	sleep 0.02
done
[ -n "$IMAGE_ID" ]
"$CLI" --socket "$SOCKET" --json pin "$IMAGE_ID" >/dev/null
kill "$XCLIP_PID" 2>/dev/null || true
wait "$XCLIP_PID" 2>/dev/null || true

magick -size 80x60 xc:darkorange PNG24:"$TEST_DIR/copied-file.png"
printf 'file://%s\r\n' "$TEST_DIR/copied-file.png" \
	| xclip -selection clipboard -target text/uri-list -in &
XCLIP_PID=$!
for _ in $(seq 1 200); do
	RESULT=$("$CLI" --socket "$SOCKET" --json list --limit 20)
	IMAGE_COUNT=$(printf '%s' "$RESULT" | python3 -c 'import json,sys; print(sum(i["kind"] == "image" for i in json.load(sys.stdin)["result"]["items"]))')
	[ "$IMAGE_COUNT" -ge 2 ] && break
	sleep 0.02
done
[ "$IMAGE_COUNT" -ge 2 ]
kill "$XCLIP_PID" 2>/dev/null || true
wait "$XCLIP_PID" 2>/dev/null || true

magick -size 72x54 xc:steelblue PNG24:"$TEST_DIR/plain-path.png"
printf '%s\n' "$TEST_DIR/plain-path.png" | xclip -selection clipboard -in &
XCLIP_PID=$!
for _ in $(seq 1 200); do
	RESULT=$("$CLI" --socket "$SOCKET" --json list --limit 20)
	IMAGE_COUNT=$(printf '%s' "$RESULT" | python3 -c 'import json,sys; print(sum(i["kind"] == "image" for i in json.load(sys.stdin)["result"]["items"]))')
	[ "$IMAGE_COUNT" -ge 3 ] && break
	sleep 0.02
done
[ "$IMAGE_COUNT" -ge 3 ]
kill "$XCLIP_PID" 2>/dev/null || true
wait "$XCLIP_PID" 2>/dev/null || true

magick -size 64x48 xc:seagreen PNG24:"$TEST_DIR/text-uri.png"
printf 'file://%s\n' "$TEST_DIR/text-uri.png" | xclip -selection clipboard -in &
XCLIP_PID=$!
for _ in $(seq 1 200); do
	RESULT=$("$CLI" --socket "$SOCKET" --json list --limit 20)
	IMAGE_COUNT=$(printf '%s' "$RESULT" | python3 -c 'import json,sys; print(sum(i["kind"] == "image" for i in json.load(sys.stdin)["result"]["items"]))')
	[ "$IMAGE_COUNT" -ge 4 ] && break
	sleep 0.02
done
[ "$IMAGE_COUNT" -ge 4 ]
kill "$XCLIP_PID" 2>/dev/null || true
wait "$XCLIP_PID" 2>/dev/null || true

stop_daemon
start_daemon
PINNED=$("$CLI" --socket "$SOCKET" --json list --pinned)
printf '%s' "$PINNED" | python3 -c 'import json,sys; x=json.load(sys.stdin)["result"]["items"]; assert len(x) == 1 and x[0]["kind"] == "image"'

"$CLI" --socket "$SOCKET" --json copy "$IMAGE_ID" >/dev/null
if python3 -c 'import PyQt6' 2>/dev/null; then
	python3 "$(dirname "$0")/qt_clipboard.py" get image/png "$TEST_DIR/image-output.png"
else
	xclip -selection clipboard -target image/png -out >"$TEST_DIR/image-output.png"
fi
cmp "$TEST_DIR/image.png" "$TEST_DIR/image-output.png"

"$CLI" --socket "$SOCKET" --json remove "$ITEM_ID" >/dev/null
"$CLI" --socket "$SOCKET" --json clear --unpinned >/dev/null
PINNED=$("$CLI" --socket "$SOCKET" --json list --pinned)
printf '%s' "$PINNED" | python3 -c 'import json,sys; assert len(json.load(sys.stdin)["result"]["items"]) == 1'

stop_daemon

echo 'IPC X11 integration: 15 passed'
