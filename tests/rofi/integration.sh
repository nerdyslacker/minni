#!/bin/sh

set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/minni-rofi.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM

mkdir -p "$tmp/bin"
cat > "$tmp/bin/minni" <<'EOF'
#!/bin/sh
if [ "$1 $2" = "--json list" ]; then
    printf '%s\n' '{"ok":true,"result":{"items":[{"id":"first","kind":"text","preview_text":"line one\nline two","pinned":true},{"id":"second","kind":"image","mime_type":"image/png","pinned":false}]}}'
else
    printf '%s\n' "$*" > "$MINNI_TEST_ACTION"
fi
EOF
cat > "$tmp/bin/rofi" <<'EOF'
#!/bin/sh
cat > "$MINNI_TEST_ROWS"
printf '1\n'
EOF
chmod +x "$tmp/bin/minni" "$tmp/bin/rofi"

MINNI_BIN="$tmp/bin/minni" \
ROFI_BIN="$tmp/bin/rofi" \
MINNI_TEST_ACTION="$tmp/action" \
MINNI_TEST_ROWS="$tmp/rows" \
    "$root/contrib/rofi/minni-rofi" >/dev/null

grep -Fq '★  line one line two' "$tmp/rows"
grep -Fq 'Image · image/png' "$tmp/rows"
[ "$(cat "$tmp/action")" = "copy second" ]

echo "rofi integration test passed"
