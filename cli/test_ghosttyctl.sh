#!/bin/bash
#
# test_ghosttyctl.sh - tests for the ghosttyctl CLI.
#
# Runs ghosttyctl against a fake IPC socket server and asserts on the JSON
# requests it sends, plus the error paths that never reach the socket.
#
# Usage: ./cli/test_ghosttyctl.sh

set -uo pipefail

CLI_DIR="$(cd "$(dirname "$0")" && pwd)"
GHOSTTYCTL="$CLI_DIR/ghosttyctl"
WORKDIR="$(mktemp -d)"
SOCKET="$WORKDIR/ghostty-test.sock"
CAPTURE="$WORKDIR/request.json"
SERVER_PID=""

PASS=0
FAIL=0

cleanup() {
    if [[ -n "$SERVER_PID" ]]; then
        kill "$SERVER_PID" 2>/dev/null
        wait "$SERVER_PID" 2>/dev/null
    fi
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

start_server() {
    python3 - "$SOCKET" "$CAPTURE" <<'PY' &
import socket, sys, os

sock_path, capture_path = sys.argv[1], sys.argv[2]
if os.path.exists(sock_path):
    os.unlink(sock_path)
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(sock_path)
server.listen(8)
while True:
    conn, _ = server.accept()
    data = b""
    while not data.endswith(b"\n"):
        chunk = conn.recv(4096)
        if not chunk:
            break
        data += chunk
    with open(capture_path, "wb") as f:
        f.write(data)
    conn.sendall(b'{"ok": true}\n')
    conn.close()
PY
    SERVER_PID=$!
    for _ in $(seq 1 50); do
        [[ -S "$SOCKET" ]] && return 0
        sleep 0.1
    done
    echo "FATAL: fake server socket never appeared" >&2
    exit 1
}

# assert_request <name> <expected-json> -- <ghosttyctl args...>
# Compared as parsed JSON, so key order/whitespace don't matter.
# GHOSTTY_TAB_ID is cleared: a real Ghostty session would leak its own
# tab id into the request under test.
assert_request() {
    local name="$1" expected="$2"
    shift 3

    : > "$CAPTURE"
    if ! GHOSTTY_SOCKET="$SOCKET" GHOSTTY_TAB_ID="" "$GHOSTTYCTL" "$@" >/dev/null 2>&1; then
        echo "FAIL: $name (ghosttyctl exited non-zero)"
        FAIL=$((FAIL + 1))
        return
    fi

    if python3 - "$CAPTURE" "$expected" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    got = json.load(f)
want = json.loads(sys.argv[2])
sys.exit(0 if got == want else 1)
PY
    then
        PASS=$((PASS + 1))
    else
        echo "FAIL: $name"
        echo "  expected: $expected"
        echo "  got:      $(cat "$CAPTURE")"
        FAIL=$((FAIL + 1))
    fi
}

# assert_fails <name> -- <ghosttyctl args...>
assert_fails() {
    local name="$1"
    shift 2
    if GHOSTTY_SOCKET="$SOCKET" GHOSTTY_TAB_ID="" "$GHOSTTYCTL" "$@" >/dev/null 2>&1; then
        echo "FAIL: $name (expected non-zero exit)"
        FAIL=$((FAIL + 1))
    else
        PASS=$((PASS + 1))
    fi
}

start_server

# ── Request shape ────────────────────────────────────────────────────────

assert_request "rename sends tab.rename" \
    '{"method": "tab.rename", "params": {"title": "build"}}' \
    -- rename "build"

assert_request "rename empty string clears the title" \
    '{"method": "tab.rename", "params": {"title": ""}}' \
    -- rename ""

assert_request "notify short form defaults title to Ghostty" \
    '{"method": "tab.notify", "params": {"title": "Ghostty", "body": "done"}}' \
    -- notify "done"

assert_request "notify long form" \
    '{"method": "tab.notify", "params": {"title": "CI", "body": "tests passed"}}' \
    -- notify --title "CI" --body "tests passed"

assert_request "set-status without icon" \
    '{"method": "tab.set-status", "params": {"key": "git", "value": "main"}}' \
    -- set-status git main

assert_request "set-status with icon" \
    '{"method": "tab.set-status", "params": {"key": "git", "value": "main", "icon": "arrow.branch"}}' \
    -- set-status git main --icon arrow.branch

assert_request "clear-status" \
    '{"method": "tab.clear-status", "params": {"key": "git"}}' \
    -- clear-status git

assert_request "set-color" \
    '{"method": "tab.set-color", "params": {"color": "teal"}}' \
    -- set-color teal

assert_request "list" \
    '{"method": "tab.list", "params": {}}' \
    -- list

assert_request "current" \
    '{"method": "tab.current", "params": {}}' \
    -- current

# ── JSON escaping ────────────────────────────────────────────────────────

assert_request "rename escapes double quotes" \
    '{"method": "tab.rename", "params": {"title": "say \"hi\""}}' \
    -- rename 'say "hi"'

assert_request "rename escapes backslashes" \
    '{"method": "tab.rename", "params": {"title": "C:\\path"}}' \
    -- rename 'C:\path'

assert_request "notify escapes newlines and tabs" \
    '{"method": "tab.notify", "params": {"title": "Ghostty", "body": "line1\nline2\tend"}}' \
    -- notify "$(printf 'line1\nline2\tend')"

# ── GHOSTTY_TAB_ID targeting ─────────────────────────────────────────────

: > "$CAPTURE"
if GHOSTTY_SOCKET="$SOCKET" GHOSTTY_TAB_ID="tab-42" "$GHOSTTYCTL" rename "x" >/dev/null 2>&1 \
    && python3 - "$CAPTURE" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    got = json.load(f)
want = {"method": "tab.rename", "params": {"tab_id": "tab-42", "title": "x"}}
sys.exit(0 if got == want else 1)
PY
then
    PASS=$((PASS + 1))
else
    echo "FAIL: GHOSTTY_TAB_ID adds tab_id param"
    echo "  got: $(cat "$CAPTURE")"
    FAIL=$((FAIL + 1))
fi

# ── Error paths ──────────────────────────────────────────────────────────

assert_fails "no arguments shows usage and fails" --
assert_fails "unknown command fails" -- frobnicate
assert_fails "rename without title fails" -- rename
assert_fails "set-status with one arg fails" -- set-status git
assert_fails "set-status with unknown option fails" -- set-status git main --bogus x
assert_fails "clear-status without key fails" -- clear-status
assert_fails "set-color without color fails" -- set-color
assert_fails "notify without message fails" -- notify

if GHOSTTY_SOCKET="$WORKDIR/absent.sock" "$GHOSTTYCTL" list >/dev/null 2>&1; then
    echo "FAIL: missing socket should exit non-zero"
    FAIL=$((FAIL + 1))
else
    PASS=$((PASS + 1))
fi

if "$GHOSTTYCTL" --help >/dev/null 2>&1; then
    PASS=$((PASS + 1))
else
    echo "FAIL: --help should exit 0"
    FAIL=$((FAIL + 1))
fi

echo
echo "ghosttyctl tests: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
