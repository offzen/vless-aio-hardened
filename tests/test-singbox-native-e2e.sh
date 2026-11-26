#!/usr/bin/env bash
# Pinned sing-box parser and AnyTLS loopback authentication/data-plane gate.
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PRODUCT=${PRODUCT_UNDER_TEST:-$ROOT/vless-server.sh}
SINGBOX_BIN=${SINGBOX_BIN:-$(command -v sing-box || true)}
readonly PINNED_VERSION="1.14.4"
[[ -f "$PRODUCT" ]] || { echo "FAIL: product script missing" >&2; exit 2; }
[[ -n "$SINGBOX_BIN" && -x "$SINGBOX_BIN" ]] || { echo "FAIL: executable pinned sing-box is required" >&2; exit 2; }
for dep in curl jq openssl python3 sed; do
    command -v "$dep" >/dev/null 2>&1 || { echo "FAIL: missing dependency: $dep" >&2; exit 2; }
done
version_line=$($SINGBOX_BIN version | sed -n '1p')
[[ "$version_line" == "sing-box version $PINNED_VERSION" ]] || {
    echo "FAIL: sing-box $PINNED_VERSION is required; got: $version_line" >&2
    exit 1
}

TMP_BASE=$(cd -- "${TMPDIR:-/tmp}" && pwd -P)
TMP=$(mktemp -d "$TMP_BASE/aio-singbox-native.XXXXXX")
PIDS=()
cleanup() {
    local pid
    for pid in "${PIDS[@]:-}"; do
        [[ -n "$pid" ]] || continue
        kill "$pid" 2>/dev/null || true
    done
    for pid in "${PIDS[@]:-}"; do
        [[ -n "$pid" ]] || continue
        wait "$pid" 2>/dev/null || true
    done
    case "$TMP" in
        "$TMP_BASE"/aio-singbox-native.*) rm -rf -- "$TMP" ;;
        *) echo "WARN: refusing to remove unexpected temp path: $TMP" >&2 ;;
    esac
}
trap cleanup EXIT INT TERM

SCRIPT_COPY="$TMP/vless-server.sh"
cp "$PRODUCT" "$SCRIPT_COPY"
mkdir -p "$TMP/cfg/certs/hy2" "$TMP/cfg/certs/tuic" "$TMP/cfg/certs/anytls"
export VLESS_SOURCE_ONLY=1 VLESS_TEST_CFG="$TMP/cfg" VLESS_TEST_LOG_ROOT="$TMP/log"
# shellcheck disable=SC1090
source "$SCRIPT_COPY"
[[ "$CFG" == "$TMP/cfg" ]] || { echo 'FAIL: VLESS_TEST_CFG isolation' >&2; exit 2; }

_info() { :; }
_ok() { :; }
_warn() { :; }
_err() { printf 'ERR: %s\n' "$*" >&2; }
_listen_addr() { printf '127.0.0.1\n'; }
db_get_balancer_groups() { printf '[]\n'; }
db_get_routing_rules() { printf '[]\n'; }
db_get_warp_mode() { :; }

port() {
    python3 - <<'PY'
import socket
with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
}
wait_tcp() {
    local pid=$1 tcp_port=$2 i
    for ((i=0; i<50; i++)); do
        kill -0 "$pid" 2>/dev/null || return 1
        if python3 - "$tcp_port" <<'PY' >/dev/null 2>&1
import socket, sys
with socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=.1):
    pass
PY
        then
            return 0
        fi
        sleep .1
    done
    return 1
}
line_count() {
    [[ -f "$1" ]] || { printf '0\n'; return; }
    awk 'END {print NR+0}' "$1"
}

HY2_PORT=$(port)
TUIC_PORT=$(port)
ANYTLS_PORT=$(port)
TARGET_PORT=$(port)
GOOD_PROXY_PORT=$(port)
BAD_PROXY_PORT=$(port)
readonly ACTIVE_ONE='11111111-1111-4111-8111-000000000001'
readonly ACTIVE_SECOND='11111111-1111-4111-8111-000000000002'
readonly DISABLED_CRED='11111111-1111-4111-8111-000000000003'
readonly EXPIRED_CRED='11111111-1111-4111-8111-000000000004'

openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -subj '/CN=sb-loopback.internal' \
    -addext 'subjectAltName=DNS:sb-loopback.internal,IP:127.0.0.1' \
    -keyout "$TMP/cfg/certs/anytls/server.key" \
    -out "$TMP/cfg/certs/anytls/server.crt" >/dev/null 2>&1
for proto in hy2 tuic; do
    cp "$TMP/cfg/certs/anytls/server.key" "$TMP/cfg/certs/$proto/server.key"
    cp "$TMP/cfg/certs/anytls/server.crt" "$TMP/cfg/certs/$proto/server.crt"
done

jq -n \
    --argjson hp "$HY2_PORT" --argjson tp "$TUIC_PORT" --argjson ap "$ANYTLS_PORT" \
    --arg a1 "$ACTIVE_ONE" --arg a2 "$ACTIVE_SECOND" \
    --arg off "$DISABLED_CRED" --arg old "$EXPIRED_CRED" '
    def users: [
      {name:"active-one",uuid:$a1,password:"tuic-active-one",enabled:true},
      {name:"disabled",uuid:$off,password:"tuic-disabled",enabled:false},
      {name:"active-second",uuid:$a2,password:"tuic-active-second",enabled:true,expire_date:"2999-12-31"},
      {name:"expired",uuid:$old,password:"tuic-expired",enabled:true,expire_date:"2000-01-01"}
    ];
    {xray:{},singbox:{
      hy2:{port:$hp,password:"legacy-hy2",sni:"sb-loopback.internal",users:users},
      tuic:{port:$tp,uuid:$a1,password:"legacy-tuic",sni:"sb-loopback.internal",users:users},
      anytls:{port:$ap,password:"legacy-anytls",sni:"sb-loopback.internal",users:users}
    }}' > "$DB_FILE"

if ! (set +e; generate_singbox_config >/dev/null); then
    echo "FAIL: product generate_singbox_config returned nonzero" >&2
    exit 1
fi
RAW_CONFIG="$TMP/cfg/singbox.json"
[[ -s "$RAW_CONFIG" ]] || { echo "FAIL: product did not render singbox.json" >&2; exit 1; }
jq -e '
  ([.inbounds[].type] | sort) == (["anytls","hysteria2","tuic"] | sort) and
  all(.inbounds[]; (.users | length) == 2) and
  ([.inbounds[].users[] | .uuid? // .password?] | any(. == "11111111-1111-4111-8111-000000000002")) and
  ([.inbounds[].users[] | .uuid? // .password?] | all(. != "11111111-1111-4111-8111-000000000003" and . != "11111111-1111-4111-8111-000000000004"))
' "$RAW_CONFIG" >/dev/null || { echo "FAIL: product renderer did not preserve exactly the active sing-box users" >&2; exit 1; }
# 复审回归 R09：当 HY2 用户同时拥有不同的 uuid 和 password 时，入站与订阅导出必须选出完全相同的凭据
HY2_INBOUND_PW=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .users[0].password' "$RAW_CONFIG")
HY2_EXPORT_PW=$(_cfg_effective hy2 "$(db_get singbox hy2)" | jq -r '.password')
[[ -n "$HY2_INBOUND_PW" && "$HY2_INBOUND_PW" == "$HY2_EXPORT_PW" ]] || {
    echo "FAIL: HY2 inbound password ($HY2_INBOUND_PW) differs from subscription export ($HY2_EXPORT_PW)" >&2
    exit 1
}
mkdir -p "$TMP/check-work"
if ! "$SINGBOX_BIN" check -D "$TMP/check-work" -c "$RAW_CONFIG" >"$TMP/raw-check.log" 2>&1; then
    sed -n '1,40p' "$TMP/raw-check.log" >&2
    echo "FAIL: pinned sing-box rejected the product-generated HY2/TUIC/AnyTLS configuration" >&2
    exit 1
fi
printf '  OK   pinned sing-box parser accepts product-generated HY2/TUIC/AnyTLS configuration\n'

# Keep the product-generated AnyTLS inbound unchanged except for the isolated route/outbound set.
jq '{
  log:{level:"warn",timestamp:true},
  inbounds:[.inbounds[] | select(.type=="anytls")],
  outbounds:[{type:"direct",tag:"direct"}],
  route:{rules:[{action:"sniff"}],final:"direct"}
}' "$RAW_CONFIG" > "$TMP/server.json"

cat > "$TMP/target.py" <<'PY'
from http.server import BaseHTTPRequestHandler, HTTPServer
import pathlib, sys
port, hit_file, nonce = int(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        hit_file.open("a").write(self.path + "\n")
        body = nonce.encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *_):
        pass
HTTPServer(("127.0.0.1", port), Handler).serve_forever()
PY
NONCE="singbox-loopback-${RANDOM}-${RANDOM}"
HITS="$TMP/target-hits.log"
: > "$HITS"
python3 "$TMP/target.py" "$TARGET_PORT" "$HITS" "$NONCE" >"$TMP/target.log" 2>&1 &
TARGET_PID=$!
PIDS+=("$TARGET_PID")
wait_tcp "$TARGET_PID" "$TARGET_PORT" || { echo "FAIL: loopback target did not become ready" >&2; exit 1; }

mkdir -p "$TMP/server-work"
"$SINGBOX_BIN" run -D "$TMP/server-work" -c "$TMP/server.json" >"$TMP/server.log" 2>&1 &
SERVER_PID=$!
PIDS+=("$SERVER_PID")
wait_tcp "$SERVER_PID" "$ANYTLS_PORT" || { sed -n '1,40p' "$TMP/server.log" >&2; echo "FAIL: AnyTLS server did not become ready" >&2; exit 1; }

write_client() {
    local output=$1 listen_port=$2 credential=$3
    jq -n \
        --argjson listen_port "$listen_port" --argjson server_port "$ANYTLS_PORT" \
        --arg password "$credential" '{
          log:{level:"warn",timestamp:true},
          inbounds:[{type:"mixed",tag:"local",listen:"127.0.0.1",listen_port:$listen_port}],
          outbounds:[{type:"anytls",tag:"proxy",server:"127.0.0.1",server_port:$server_port,password:$password,
            tls:{enabled:true,server_name:"sb-loopback.internal",insecure:true}}],
          route:{rules:[{action:"sniff"}],final:"proxy"}
        }' > "$output"
}
start_client() {
    local config=$1 work=$2 log=$3 listen_port=$4
    mkdir -p "$work"
    "$SINGBOX_BIN" check -D "$work" -c "$config" >"$log.check" 2>&1 || {
        sed -n '1,40p' "$log.check" >&2
        return 1
    }
    "$SINGBOX_BIN" run -D "$work" -c "$config" >"$log" 2>&1 &
    CLIENT_PID=$!
    PIDS+=("$CLIENT_PID")
    wait_tcp "$CLIENT_PID" "$listen_port"
}

ANYTLS_ACTIVE_PASSWORD=$(jq -r '.inbounds[] | select(.type=="anytls") | .users[] | select(.name=="active-second") | .password' "$RAW_CONFIG")
[[ "$ANYTLS_ACTIVE_PASSWORD" == "tuic-active-second" ]] || {
    echo "FAIL: product-generated AnyTLS second-user password is missing or mismatched" >&2
    exit 1
}
if jq -e '.inbounds[] | select(.type=="anytls") | .users[] | select(.name=="disabled")' "$RAW_CONFIG" >/dev/null; then
    echo "FAIL: disabled AnyTLS user reached the product-generated inbound" >&2
    exit 1
fi
write_client "$TMP/client-good.json" "$GOOD_PROXY_PORT" "$ANYTLS_ACTIVE_PASSWORD"
start_client "$TMP/client-good.json" "$TMP/client-good-work" "$TMP/client-good.log" "$GOOD_PROXY_PORT" || {
    echo "FAIL: active AnyTLS client did not become ready" >&2
    exit 1
}
GOOD_PID=$CLIENT_PID
hits_before=$(line_count "$HITS")
good_body=$(curl --silent --show-error --fail --noproxy '' \
    --proxy "socks5h://127.0.0.1:$GOOD_PROXY_PORT" \
    --connect-timeout 2 --max-time 5 "http://127.0.0.1:$TARGET_PORT/probe")
hits_after=$(line_count "$HITS")
[[ "$good_body" == "$NONCE" && $((hits_after - hits_before)) -eq 1 ]] || {
    echo "FAIL: second active AnyTLS credential did not reach the loopback target exactly once" >&2
    exit 1
}
kill -0 "$SERVER_PID" "$GOOD_PID" "$TARGET_PID" 2>/dev/null || { echo "FAIL: active path process exited unexpectedly" >&2; exit 1; }
printf '  OK   second active AnyTLS credential reaches the loopback target\n'

write_client "$TMP/client-bad.json" "$BAD_PROXY_PORT" "tuic-disabled"
start_client "$TMP/client-bad.json" "$TMP/client-bad-work" "$TMP/client-bad.log" "$BAD_PROXY_PORT" || {
    echo "FAIL: disabled-credential client did not become ready for the negative test" >&2
    exit 1
}
BAD_PID=$CLIENT_PID
kill -0 "$SERVER_PID" "$BAD_PID" "$TARGET_PID" 2>/dev/null || { echo "FAIL: negative-path precondition process is not alive" >&2; exit 1; }
hits_before=$(line_count "$HITS")
set +e
bad_body=$(curl --silent --show-error --fail --noproxy '' \
    --proxy "socks5h://127.0.0.1:$BAD_PROXY_PORT" \
    --connect-timeout 2 --max-time 5 "http://127.0.0.1:$TARGET_PORT/probe" 2>"$TMP/bad-curl.log")
bad_rc=$?
set -e
hits_after=$(line_count "$HITS")
kill -0 "$SERVER_PID" "$BAD_PID" "$TARGET_PID" 2>/dev/null || { echo "FAIL: negative-path process exited, making rejection ambiguous" >&2; exit 1; }
[[ "$bad_rc" -ne 0 && "$bad_body" != "$NONCE" && $((hits_after - hits_before)) -eq 0 ]] || {
    echo "FAIL: disabled AnyTLS credential was not rejected before target access" >&2
    exit 1
}
printf '  OK   disabled AnyTLS credential is rejected while all test processes stay alive\n'

printf 'PASS: pinned sing-box native parser/data-plane gate (3/3; %s)\n' "$version_line"
