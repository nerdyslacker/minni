#!/bin/sh
set -eu

DRIVER=${1:-./build/x11-test}
TEST_DIR=$(mktemp -d /tmp/minni-x11-test.XXXXXX)
trap 'jobs -p | xargs -r kill 2>/dev/null || true; rm -rf "$TEST_DIR"' EXIT INT TERM

wait_ready() {
	for _ in $(seq 1 200); do
		[ -f "$1" ] && return
		sleep 0.02
	done
	return 1
}

printf 'hello\nաշխարհ\n' >"$TEST_DIR/small"
"$DRIVER" capture "$TEST_DIR/captured" "$TEST_DIR/capture-ready" &
CAPTURE_PID=$!
wait_ready "$TEST_DIR/capture-ready"
xclip -selection clipboard -in <"$TEST_DIR/small" &
XCLIP_PID=$!
wait "$CAPTURE_PID"
cmp "$TEST_DIR/small" "$TEST_DIR/captured"
kill "$XCLIP_PID" 2>/dev/null || true
wait "$XCLIP_PID" 2>/dev/null || true

"$DRIVER" serve "$TEST_DIR/small" "$TEST_DIR/serve-ready" &
SERVE_PID=$!
wait_ready "$TEST_DIR/serve-ready"
xclip -selection clipboard -out >"$TEST_DIR/restored"
cmp "$TEST_DIR/small" "$TEST_DIR/restored"
kill "$SERVE_PID" 2>/dev/null || true
wait "$SERVE_PID" 2>/dev/null || true

dd if=/dev/zero bs=1024 count=256 2>/dev/null | tr '\0' x >"$TEST_DIR/large"
printf '\n' >>"$TEST_DIR/large"
"$DRIVER" serve "$TEST_DIR/large" "$TEST_DIR/large-serve-ready" &
SERVE_PID=$!
wait_ready "$TEST_DIR/large-serve-ready"
"$DRIVER" capture "$TEST_DIR/large-captured" "$TEST_DIR/large-capture-ready" &
CAPTURE_PID=$!
wait_ready "$TEST_DIR/large-capture-ready"
wait "$CAPTURE_PID"
cmp "$TEST_DIR/large" "$TEST_DIR/large-captured"
kill "$SERVE_PID" 2>/dev/null || true
wait "$SERVE_PID" 2>/dev/null || true

printf '\351' >"$TEST_DIR/latin1"
printf '\303\251' >"$TEST_DIR/utf8"
"$DRIVER" capture "$TEST_DIR/string-captured" "$TEST_DIR/string-capture-ready" &
CAPTURE_PID=$!
wait_ready "$TEST_DIR/string-capture-ready"
xclip -selection clipboard -target STRING -in <"$TEST_DIR/latin1" &
XCLIP_PID=$!
wait "$CAPTURE_PID"
cmp "$TEST_DIR/utf8" "$TEST_DIR/string-captured"
kill "$XCLIP_PID" 2>/dev/null || true
wait "$XCLIP_PID" 2>/dev/null || true

"$DRIVER" self "$TEST_DIR/small" "$TEST_DIR/self-ready"

magick -size 512x384 plasma:fractal PNG24:"$TEST_DIR/image.png"
magick "$TEST_DIR/image.png" -quality 91 "$TEST_DIR/image.jpg"

"$DRIVER" serve-image image/png "$TEST_DIR/image.png" "$TEST_DIR/png-serve-ready" &
SERVE_PID=$!
wait_ready "$TEST_DIR/png-serve-ready"
xclip -selection clipboard -target image/png -out >"$TEST_DIR/png-restored"
cmp "$TEST_DIR/image.png" "$TEST_DIR/png-restored"
kill "$SERVE_PID" 2>/dev/null || true
wait "$SERVE_PID" 2>/dev/null || true

"$DRIVER" serve-image image/jpeg "$TEST_DIR/image.jpg" "$TEST_DIR/jpeg-serve-ready" &
SERVE_PID=$!
wait_ready "$TEST_DIR/jpeg-serve-ready"
xclip -selection clipboard -target image/jpeg -out >"$TEST_DIR/jpeg-restored"
cmp "$TEST_DIR/image.jpg" "$TEST_DIR/jpeg-restored"
kill "$SERVE_PID" 2>/dev/null || true
wait "$SERVE_PID" 2>/dev/null || true

"$DRIVER" capture-image image/png "$TEST_DIR/png-captured" "$TEST_DIR/png-capture-ready" &
CAPTURE_PID=$!
wait_ready "$TEST_DIR/png-capture-ready"
xclip -selection clipboard -target image/png -in <"$TEST_DIR/image.png" &
XCLIP_PID=$!
wait "$CAPTURE_PID"
cmp "$TEST_DIR/image.png" "$TEST_DIR/png-captured"
kill "$XCLIP_PID" 2>/dev/null || true
wait "$XCLIP_PID" 2>/dev/null || true

"$DRIVER" capture-image image/jpeg "$TEST_DIR/jpeg-captured" "$TEST_DIR/jpeg-capture-ready" &
CAPTURE_PID=$!
wait_ready "$TEST_DIR/jpeg-capture-ready"
xclip -selection clipboard -target image/jpeg -in <"$TEST_DIR/image.jpg" &
XCLIP_PID=$!
wait "$CAPTURE_PID"
cmp "$TEST_DIR/image.jpg" "$TEST_DIR/jpeg-captured"
kill "$XCLIP_PID" 2>/dev/null || true
wait "$XCLIP_PID" 2>/dev/null || true

printf 'file:///tmp/picture.png\r\n' >"$TEST_DIR/uris"
"$DRIVER" capture-image text/uri-list "$TEST_DIR/uris-captured" "$TEST_DIR/uris-capture-ready" &
CAPTURE_PID=$!
wait_ready "$TEST_DIR/uris-capture-ready"
xclip -selection clipboard -target text/uri-list -in <"$TEST_DIR/uris" &
XCLIP_PID=$!
wait "$CAPTURE_PID"
cmp "$TEST_DIR/uris" "$TEST_DIR/uris-captured"
kill "$XCLIP_PID" 2>/dev/null || true
wait "$XCLIP_PID" 2>/dev/null || true

echo 'X11 integration: 10 passed'
