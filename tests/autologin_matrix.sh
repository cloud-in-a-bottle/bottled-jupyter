#!/usr/bin/env bash
# Owner auto-login regression matrix for nginx.conf.tmpl.
#
# Runs the real front-proxy config (only the ports, temp paths and the
# include path are rewritten) in front of tests/stub_jupyter.py, then
# drives it with curl and asserts what a browser would end up seeing.
#
# The cases that matter most are the ones this app has been bitten by:
#   * an _xsrf cookie must NOT count as "signed in" (Jupyter hands one to
#     anonymous visitors on its login page);
#   * a stale/invalid session cookie must still recover, because every
#     restart mints a new cookie_secret and invalidates the old cookies;
#   * a deep link must survive the round trip;
#   * a non-owner must never be handed the token.
#
# Usage: tests/autologin_matrix.sh [path-to-nginx]
# Requires: nginx, python3, curl.  Exits non-zero on the first failure.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NGINX_BIN="${1:-$(command -v nginx || echo /usr/sbin/nginx)}"
TOKEN="test-token-$RANDOM$RANDOM"
WORK_DIR="$(mktemp -d)"
FAILURES=0

if [[ ! -x "$NGINX_BIN" ]]; then
    echo "nginx binary not found (tried: $NGINX_BIN)" >&2
    exit 2
fi

cleanup() {
    [[ -n "${NGINX_PID:-}" ]] && kill "$NGINX_PID" 2>/dev/null || true
    [[ -n "${STUB_PID:-}" ]] && kill "$STUB_PID" 2>/dev/null || true
    wait 2>/dev/null || true
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# Two free ports, handed over by the kernel.
read -r PROXY_PORT STUB_PORT < <(python3 - <<'PY'
import socket
ports = []
socks = []
for _ in range(2):
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    socks.append(s)
    ports.append(s.getsockname()[1])
for s in socks:
    s.close()
print(*ports)
PY
)

export STUB_TOKEN="$TOKEN"
export STUB_LOG="$WORK_DIR/upstream.log"
: >"$STUB_LOG"

python3 "$REPO_DIR/tests/stub_jupyter.py" "$STUB_PORT" &
STUB_PID=$!

# Rewrite the production template for a sandboxed run: our token, our
# ports, temp/pid/log paths inside $WORK_DIR, and the real include path.
CONF="$WORK_DIR/nginx.conf"
REPO_DIR="$REPO_DIR" WORK_DIR="$WORK_DIR" TOKEN="$TOKEN" \
PROXY_PORT="$PROXY_PORT" STUB_PORT="$STUB_PORT" python3 - "$CONF" <<'PY'
import os
import sys

work = os.environ["WORK_DIR"]
repo = os.environ["REPO_DIR"]
conf = open(os.path.join(repo, "nginx.conf.tmpl"), encoding="utf-8").read()
conf = conf.replace("__JUPYTER_TOKEN__", os.environ["TOKEN"])
conf = conf.replace("listen 8080;", f"listen 127.0.0.1:{os.environ['PROXY_PORT']};")
conf = conf.replace("server 127.0.0.1:8888;", f"server 127.0.0.1:{os.environ['STUB_PORT']};")
conf = conf.replace("/opt/openhost-jupyter/proxy_common.conf", os.path.join(repo, "proxy_common.conf"))
conf = conf.replace("pid /tmp/nginx.pid;", f"pid {work}/nginx.pid;")
conf = conf.replace("error_log /dev/stderr warn;", f"error_log {work}/error.log warn;")
conf = conf.replace("access_log /dev/stdout;", f"access_log {work}/access.log;")
conf = conf.replace("/tmp/nginx-", f"{work}/nginx-")
open(sys.argv[1], "w", encoding="utf-8").write(conf)
PY

mkdir -p "$WORK_DIR/nginx-client-body" "$WORK_DIR/nginx-proxy" \
         "$WORK_DIR/nginx-fastcgi" "$WORK_DIR/nginx-uwsgi" "$WORK_DIR/nginx-scgi" \
         "$WORK_DIR/logs"

"$NGINX_BIN" -t -c "$CONF" -p "$WORK_DIR" >/dev/null
"$NGINX_BIN" -c "$CONF" -p "$WORK_DIR" -g 'daemon off;' &
NGINX_PID=$!

BASE="http://127.0.0.1:$PROXY_PORT"
for _ in $(seq 1 100); do
    if curl -fsS -o /dev/null "$BASE/_healthz" 2>/dev/null; then break; fi
    sleep 0.1
done
curl -fsS -o /dev/null "$BASE/_healthz"

# The stub listens a moment after fork; wait for it too, or the first
# proxied request races it and 502s.
for _ in $(seq 1 100); do
    if curl -sS -o /dev/null "http://127.0.0.1:$STUB_PORT/_ready" 2>/dev/null; then break; fi
    sleep 0.1
done
curl -sS -o /dev/null "http://127.0.0.1:$STUB_PORT/_ready"

OWNER=(-H "X-OpenHost-Is-Owner: true")
HTML=(-H "Accept: text/html,application/xhtml+xml")

# Follow the whole redirect chain like a browser and print the final body.
follow() {
    curl -sS -L --max-redirs 8 -c "$WORK_DIR/jar-$RANDOM" -o - "$@"
}

# One request, no redirect following: print "<status> <location>".
once() {
    curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' "$@"
}

check() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" == *"$expected"* ]]; then
        printf 'ok   %s\n' "$name"
    else
        printf 'FAIL %s\n       expected to contain: %s\n       got: %s\n' "$name" "$expected" "$actual"
        FAILURES=$((FAILURES + 1))
    fi
}

check_not() {
    local name="$1" forbidden="$2" actual="$3"
    if [[ "$actual" != *"$forbidden"* ]]; then
        printf 'ok   %s\n' "$name"
    else
        printf 'FAIL %s\n       must not contain: %s\n       got: %s\n' "$name" "$forbidden" "$actual"
        FAILURES=$((FAILURES + 1))
    fi
}

echo "== owner navigations end up in the app, never on the login form =="

check "cold start on /" "LAB:/" \
    "$(follow "${OWNER[@]}" "${HTML[@]}" "$BASE/")"

check "deep link is preserved" "LAB:/lab/tree/demo.ipynb" \
    "$(follow "${OWNER[@]}" "${HTML[@]}" "$BASE/lab/tree/demo.ipynb")"

check "query string is preserved" "LAB:/lab" \
    "$(follow "${OWNER[@]}" "${HTML[@]}" "$BASE/lab?mode=single")"

# The regression: Jupyter's login page hands anonymous visitors an _xsrf
# cookie.  If that counts as a session, the owner is locked out for good.
check "_xsrf cookie alone does not block auto-login" "LAB:/" \
    "$(follow "${OWNER[@]}" "${HTML[@]}" -H 'Cookie: _xsrf=stub-xsrf' "$BASE/")"

# The other regression: after a restart the browser holds a session
# cookie signed with the previous cookie_secret.
check "stale session cookie recovers via /login" "LAB:/" \
    "$(follow "${OWNER[@]}" "${HTML[@]}" -H 'Cookie: username-stub=stale' "$BASE/")"

check "stale session cookie recovers on a deep link" "LAB:/lab/tree/demo.ipynb" \
    "$(follow "${OWNER[@]}" "${HTML[@]}" -H 'Cookie: username-stub=stale; _xsrf=stub-xsrf' "$BASE/lab/tree/demo.ipynb")"

check "stale token in a bookmarked URL still recovers" "LAB:" \
    "$(follow "${OWNER[@]}" "${HTML[@]}" "$BASE/lab?token=long-expired")"

check "landing straight on /login recovers" "LAB:/lab" \
    "$(follow "${OWNER[@]}" "${HTML[@]}" "$BASE/login?next=%2Flab")"

echo
echo "== a valid session is left alone =="

VALID="$(once "${OWNER[@]}" "${HTML[@]}" -H 'Cookie: username-stub=valid' "$BASE/lab")"
check "no redirect when already signed in" "200" "$VALID"
check_not "no token handed out when already signed in" "token=$TOKEN" "$VALID"

echo
echo "== the token is only ever given to the owner =="

ANON="$(follow "${HTML[@]}" "$BASE/")"
check "non-owner lands on the login page" "LOGIN_PAGE" "$ANON"
check_not "non-owner never sees the token" "$TOKEN" "$ANON"

ANON_HEADERS="$(curl -sS -D - -o /dev/null -L --max-redirs 8 "${HTML[@]}" "$BASE/login?next=%2Flab")"
check_not "non-owner never gets a token redirect" "$TOKEN" "$ANON_HEADERS"

echo
echo "== only top-level HTML GETs are redirected =="

XHR="$(once "${OWNER[@]}" -H 'Accept: application/json' "$BASE/api/contents")"
check_not "XHR is not redirected with a token" "token=$TOKEN" "$XHR"

POSTED="$(once "${OWNER[@]}" "${HTML[@]}" -X POST "$BASE/api/kernels")"
check_not "POST is not redirected with a token" "token=$TOKEN" "$POSTED"

WS="$(once "${OWNER[@]}" -H 'Upgrade: websocket' -H 'Connection: Upgrade' "$BASE/api/kernels/x/channels")"
check_not "WebSocket upgrade is not redirected with a token" "token=$TOKEN" "$WS"

echo
echo "== loop breaker =="

MARKED="$(once "${OWNER[@]}" "${HTML[@]}" -H 'Cookie: openhost_jupyter_autologin=1' "$BASE/")"
check_not "no token redirect while the marker cookie is set" "token=$TOKEN" "$MARKED"

MARKER="$(curl -sS -D - -o /dev/null "${OWNER[@]}" "${HTML[@]}" "$BASE/")"
check "token redirect sets the marker cookie" "openhost_jupyter_autologin=1" "$MARKER"
check "token redirect is a 302" "302" "$MARKER"

echo
echo "== upstream never saw a doubled token =="
if grep -qE 'token=[^&"]*&(amp;)?token=' "$STUB_LOG"; then
    printf 'FAIL upstream received a doubled token:\n%s\n' "$(grep -E 'token=.*token=' "$STUB_LOG")"
    FAILURES=$((FAILURES + 1))
else
    echo "ok   no doubled token in $(wc -l <"$STUB_LOG") proxied requests"
fi

echo
if [[ "$FAILURES" -eq 0 ]]; then
    echo "all checks passed"
else
    echo "$FAILURES check(s) failed"
    exit 1
fi
