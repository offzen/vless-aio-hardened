#!/usr/bin/env bash
# Real, isolated Xray data-plane regression for two legacy Shadowsocks users.
set -Euo pipefail

SCRIPT="${1:-$(dirname "$0")/../vless-server.sh}"
XRAY_BIN="${XRAY_BIN:-$(command -v xray || true)}"
[[ -f "$SCRIPT" ]] || { echo "missing script: $SCRIPT" >&2; exit 2; }
[[ -n "$XRAY_BIN" && -x "$XRAY_BIN" ]] || { echo "missing executable xray" >&2; exit 2; }
for dep in jq python3 curl; do
    command -v "$dep" >/dev/null 2>&1 || { echo "missing dependency: $dep" >&2; exit 2; }
done

TMP=$(mktemp -d "${TMPDIR:-/tmp}/aio-ss-legacy-e2e.XXXXXX")
TMP=$(cd -- "$TMP" && pwd -P) || exit 2
SERVER_PID=""
HTTP_PID=""
CLIENT_PID=""
kill_exact() {
    local pid="${1:-}"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 0
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}
cleanup() {
    local rc=$?
    kill_exact "$CLIENT_PID"
    kill_exact "$SERVER_PID"
    kill_exact "$HTTP_PID"
    if [[ "${AIO_TEST_KEEP_TMP:-0}" == 1 && "$rc" -ne 0 ]]; then
        printf 'diagnostic directory retained: %s\n' "$TMP" >&2
    elif [[ "$TMP" == /tmp/aio-ss-legacy-e2e.* ]]; then
        rm -rf -- "$TMP"
    fi
    return "$rc"
}
trap cleanup EXIT INT TERM

read -r SERVER_PORT HTTP_PORT SOCKS_DEFAULT SOCKS_SECOND < <(python3 - <<'PY'
import socket
sockets = [socket.socket() for _ in range(4)]
try:
    for sock in sockets:
        sock.bind(("127.0.0.1", 0))
    print(*(sock.getsockname()[1] for sock in sockets))
finally:
    for sock in sockets:
        sock.close()
PY
)

SCRIPT_COPY="$TMP/vless-server.sh"
cp "$SCRIPT" "$SCRIPT_COPY"
mkdir -p "$TMP/cfg" "$TMP/log"
export VLESS_SOURCE_ONLY=1 VLESS_TEST_CFG="$TMP/cfg" VLESS_TEST_LOG_ROOT="$TMP/log"
# shellcheck disable=SC1090
source "$SCRIPT_COPY"
[[ "$CFG" == "$TMP/cfg" ]] || { echo 'FAIL: VLESS_TEST_CFG isolation' >&2; exit 2; }

_info() { :; }
_ok() { :; }
_warn() { :; }
_err() { printf 'ERR: %s\n' "$*" >&2; }
_listen_addr() { printf '127.0.0.1\n'; }
db_get_balancer_groups() { echo '[]'; }
db_get_warp_mode() { echo ''; }
db_get_routing_rules() { echo '[]'; }
db_ip_routing_enabled() { return 1; }

DEFAULT_PASSWORD='{{SECRET_ss_legacy_e2e_default}}'
SECOND_PASSWORD='{{SECRET_ss_legacy_e2e_second}}'
REJECTED_PASSWORD='{{SECRET_ss_legacy_e2e_rejected}}'
cat > "$DB_FILE" <<JSON
{
  "xray": {
    "ss-legacy": {
      "port": $SERVER_PORT,
      "method": "aes-256-gcm",
      "password": "$DEFAULT_PASSWORD",
      "users": [
        {"name":"default","uuid":"$DEFAULT_PASSWORD","enabled":true},
        {"name":"second","uuid":"$SECOND_PASSWORD","enabled":true},
        {"name":"rejected","uuid":"$REJECTED_PASSWORD","enabled":false}
      ]
    }
  },
  "singbox": {}
}
JSON

generate_xray_config >/dev/null
jq -e --argjson port "$SERVER_PORT" '
    . as $root |
    ([$root.inbounds[] | select(.tag == ("ss-legacy-" + ($port | tostring)))] | length == 1) and
    ([$root.inbounds[] | select(.tag == ("ss-legacy-" + ($port | tostring))) | .settings.clients[]?] | length == 2) and
    ([$root.inbounds[] | select(.tag == ("ss-legacy-" + ($port | tostring))) | .settings | has("users")] == [false]) and
    ([$root.inbounds[] | select(.tag == ("ss-legacy-" + ($port | tostring))) | .settings | has("password")] == [false])
' "$CFG/config.json" >/dev/null || {
    echo "FAIL: generated legacy Shadowsocks inbound must use settings.clients with two users" >&2
    exit 1
}
"$XRAY_BIN" run -test -c "$CFG/config.json" >/dev/null 2>&1 || {
    echo "FAIL: generated server config rejected by Xray" >&2
    exit 1
}
# The production generator intentionally blocks loopback/private destinations. This test derives an
# isolated config that removes only that routing rule so the local HTTP origin can measure auth/data
# plane behavior without changing product routing policy or using the external network.
jq '.routing.rules |= map(select(.outboundTag != "block"))' "$CFG/config.json" > "$TMP/server-e2e.json"
"$XRAY_BIN" run -test -c "$TMP/server-e2e.json" >/dev/null 2>&1 || {
    echo "FAIL: isolated server config rejected by Xray" >&2
    exit 1
}

NONCE='ss-legacy-two-user-e2e-ok'
NONCE="$NONCE" HTTP_PORT="$HTTP_PORT" python3 -c 'import http.server, os
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = os.environ["NONCE"].encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *_):
        pass
http.server.ThreadingHTTPServer(("127.0.0.1", int(os.environ["HTTP_PORT"])), Handler).serve_forever()' \
    >"$TMP/http.log" 2>&1 &
HTTP_PID=$!
"$XRAY_BIN" run -c "$TMP/server-e2e.json" >"$TMP/server.log" 2>&1 &
SERVER_PID=$!

run_user() {
    local label="$1" password="$2" socks_port="$3" expect="${4:-accept}"
    local client="$TMP/client-$label.json" output=""
    jq -n \
        --arg password "$password" \
        --argjson server_port "$SERVER_PORT" \
        --argjson socks_port "$socks_port" \
        '{
          log:{loglevel:"warning"},
          inbounds:[{listen:"127.0.0.1",port:$socks_port,protocol:"socks",settings:{auth:"noauth",udp:false}}],
          outbounds:[{protocol:"shadowsocks",settings:{servers:[{address:"127.0.0.1",port:$server_port,method:"aes-256-gcm",password:$password}]}}]
        }' > "$client"
    "$XRAY_BIN" run -test -c "$client" >/dev/null 2>&1 || return 1
    "$XRAY_BIN" run -c "$client" >"$TMP/client-$label.log" 2>&1 &
    CLIENT_PID=$!
    for _ in {1..30}; do
        output=$(NO_PROXY= no_proxy= curl -fsS --max-time 0.5 --noproxy '' \
            --socks5-hostname "127.0.0.1:$socks_port" "http://127.0.0.1:$HTTP_PORT/" 2>/dev/null || true)
        [[ "$output" == "$NONCE" ]] && break
        sleep 0.1
    done
    kill_exact "$CLIENT_PID"
    CLIENT_PID=""
    if [[ "$expect" == "reject" ]]; then
        [[ "$output" != "$NONCE" ]]
    else
        [[ "$output" == "$NONCE" ]]
    fi
}

run_user default "$DEFAULT_PASSWORD" "$SOCKS_DEFAULT" || {
    echo "FAIL: default legacy Shadowsocks credential failed real Xray data plane" >&2
    exit 1
}
run_user second "$SECOND_PASSWORD" "$SOCKS_SECOND" || {
    echo "FAIL: second legacy Shadowsocks credential failed real Xray data plane" >&2
    exit 1
}
run_user rejected "$REJECTED_PASSWORD" "$SOCKS_SECOND" reject || {
    echo "FAIL: disabled legacy Shadowsocks credential reached the data plane" >&2
    exit 1
}
kill -0 "$SERVER_PID" 2>/dev/null || {
    echo "FAIL: Xray server exited during two-user test" >&2
    exit 1
}

printf 'PASS: real Xray legacy Shadowsocks data plane accepts two active credentials and rejects one disabled credential (3/3)\n'
