#!/usr/bin/env bash
set -Eeo pipefail

EXPECTED_SHA="${AIO_E2E_EXPECTED_SHA:-}"

validate_candidate_identity() {
  local expected="${1:-}" product="${2:-}" actual
  if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
    echo "FAIL: AIO_E2E_EXPECTED_SHA must be injected as 64 lowercase hex characters" >&2
    return 2
  fi
  [[ -f "$product" ]] || { echo "FAIL: candidate missing: $product" >&2; return 2; }
  actual=$(sha256sum "$product" | awk '{print $1}')
  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL: candidate SHA mismatch: actual=$actual expected=$expected" >&2
    return 1
  fi
}

identity_selftest() {
  local root product actual pass=0
  root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
  product="$root/vless-server.sh"
  actual=$(sha256sum "$product" | awk '{print $1}')

  if validate_candidate_identity "" "$product" >/dev/null 2>&1; then
    echo "FAIL: missing candidate SHA was accepted" >&2; return 1
  fi
  pass=$((pass + 1))
  if validate_candidate_identity not-a-sha "$product" >/dev/null 2>&1; then
    echo "FAIL: malformed candidate SHA was accepted" >&2; return 1
  fi
  pass=$((pass + 1))
  if validate_candidate_identity "$(printf '0%.0s' {1..64})" "$product" >/dev/null 2>&1; then
    echo "FAIL: mismatched candidate SHA was accepted" >&2; return 1
  fi
  pass=$((pass + 1))
  validate_candidate_identity "$actual" "$product" >/dev/null
  pass=$((pass + 1))
  echo "PASS: E2E candidate identity is fail-closed ($pass assertions)"
}

host_main() {
  local root product name tmp image
  root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
  product="$root/vless-server.sh"
  validate_candidate_identity "$EXPECTED_SHA" "$product" || return $?
  command -v docker >/dev/null || { echo "FAIL: docker missing" >&2; return 1; }
  [[ -x /usr/local/bin/xray ]] || { echo "FAIL: /usr/local/bin/xray missing" >&2; return 1; }

  name="aio-h12-e2e-$$-$RANDOM"
  image="aio-h12-e2e-deps:$$-$RANDOM"
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/aio-h12-e2e.XXXXXX")
  cleanup_host() {
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker image rm -f "$image" >/dev/null 2>&1 || true
    rm -rf -- "$tmp"
  }
  trap cleanup_host EXIT INT TERM

  cat >"$tmp/Dockerfile" <<'EOF'
FROM python:3.12-bookworm
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates curl iproute2 jq openssl procps \
 && rm -rf /var/lib/apt/lists/*
EOF
  echo "[host] building disposable dependency image"
  docker build --pull=false -q -t "$image" "$tmp" >/dev/null
  echo "[host] running isolated lifecycle E2E: $name"
  local rc=0
  docker run --rm --name "$name" \
    --network none --cap-drop ALL --security-opt no-new-privileges \
    --pids-limit 256 --memory 768m --cpus 2 \
    --mount "type=bind,src=$root,dst=/repo,readonly" \
    --mount "type=bind,src=/usr/local/bin/xray,dst=/usr/local/bin/xray,readonly" \
    -e AIO_E2E_EXPECTED_SHA="$EXPECTED_SHA" \
    "$image" bash /repo/tests/test-installer-e2e.sh --inside || rc=$?
  cleanup_host
  trap - EXIT INT TERM
  return "$rc"
}

inside_main() {
  set +u
  local sandbox=/sandbox product=/repo/vless-server.sh patched=/sandbox/product.sh
  local server_port=18443 http_port=18080 socks_port=20808
  local uuid0=11111111-1111-4111-8111-111111111111
  local uuid1=22222222-2222-4222-8222-222222222222
  local uuid2=33333333-3333-4333-8333-333333333333
  local uuid_fail=44444444-4444-4444-8444-444444444444
  local pass_count=0

  fail() { echo "not ok $((pass_count + 1)) - $*" >&2; exit 1; }
  ok() { pass_count=$((pass_count + 1)); echo "ok $pass_count - $*"; }
  assert_file() { [[ -f "$1" ]] || fail "missing file: $1"; }
  assert_absent() { [[ ! -e "$1" ]] || fail "unexpected path: $1"; }
  assert_eq() { [[ "$1" == "$2" ]] || fail "$3 (got=$1 want=$2)"; }
  assert_jq() { jq -e "$2" "$1" >/dev/null || fail "$3"; }
  count_svc() { awk -F'|' -v a="$1" -v n="$2" '$1==a && $2==n {c++} END{print c+0}' "$SVC_LOG"; }
  kill_exact() {
    local pid="${1:-}"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 0
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  }

  mkdir -p "$sandbox/etc/vless-reality" "$sandbox/logs" "$sandbox/run" "$sandbox/www"
  validate_candidate_identity "$EXPECTED_SHA" "$product" || fail "container candidate identity rejected"
  cp "$product" "$patched"
  python3 - "$patched" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
old='readonly CFG="/etc/vless-reality"'
assert s.count(old)==1
p.write_text(s.replace(old, 'readonly CFG="/sandbox/etc/vless-reality"'))
PY
  chmod +x "$patched"
  ok "candidate hash locked and only CFG constant patched"

  export VLESS_SOURCE_ONLY=1
  export VLESS_TEST_LOG_ROOT="$sandbox/logs"
  export WEBROOT_INDEX="$sandbox/www/index.html"
  # shellcheck disable=SC1090
  source "$patched"
  BASH_ARGV0="$patched"

  SVC_LOG="$sandbox/svc.log"
  SYS_LOG="$sandbox/systemctl.log"
  FW_LOG="$sandbox/firewall.log"
  FW_STATE="$sandbox/firewall.state"
  GLOBAL_KILL_HIT="$sandbox/global-kill.hit"
  SERVICE_PID="$sandbox/run/vless-reality.pid"
  ACTIVE_SERVICES="$sandbox/run/services"
  : >"$SVC_LOG"; : >"$SYS_LOG"; : >"$FW_LOG"; : >"$FW_STATE"; : >"$ACTIVE_SERVICES"
  FAIL_NEXT_RESTART=0

  _header() { :; }; _line() { :; }; _dline() { :; }; _item() { :; }; _pause() { :; }
  show_single_protocol_info() { :; }
  select_protocol() { SELECTED_PROTOCOL="vless-ws"; return 0; }
  ask_port() { echo "$server_port"; }
  gen_uuid() { echo "$uuid0"; }
  get_ipv4() { echo "198.51.100.10"; }
  get_ipv6() { echo ""; }
  _has_ipv6() { return 1; }
  _can_dual_stack_listen() { return 1; }
  _listen_addr() { echo "0.0.0.0"; }
  check_dependencies() { return 0; }
  ensure_dual_stack_listen() { return 0; }
  install_deps() { return 0; }
  install_xray() { [[ -x /usr/local/bin/xray ]]; }
  warp_status() { echo "not_configured"; }
  check_cmd() {
    case "$1" in xray|jq|curl|openssl|python3) command -v "$1" >/dev/null ;; *) return 1 ;; esac
  }
  crontab() { echo "crontab|$*" >>"$SYS_LOG"; return 0; }
  killall() { echo "killall|$*" >>"$GLOBAL_KILL_HIT"; return 99; }
  pkill() { echo "pkill|$*" >>"$GLOBAL_KILL_HIT"; return 99; }

  _mark_service() {
    local name="$1" state="$2" t
    t=$(mktemp)
    awk -v n="$name" '$0!=n' "$ACTIVE_SERVICES" >"$t"
    [[ "$state" == active ]] && echo "$name" >>"$t"
    mv "$t" "$ACTIVE_SERVICES"
  }
  _service_is_active() { grep -Fxq -- "$1" "$ACTIVE_SERVICES"; }
  _stop_xray() {
    local pid=""
    [[ -f "$SERVICE_PID" ]] && pid=$(cat "$SERVICE_PID")
    kill_exact "$pid"
    rm -f "$SERVICE_PID"
    _mark_service vless-reality inactive
  }
  _start_xray() {
    /usr/local/bin/xray run -c "$CFG/config.json" >"$sandbox/xray-service.log" 2>&1 &
    local pid=$!
    echo "$pid" >"$SERVICE_PID"
    _mark_service vless-reality active
  }
  svc() {
    local action="$1" name="$2"
    echo "$action|$name" >>"$SVC_LOG"
    case "$action" in
      status)
        if [[ "$name" == vless-reality ]]; then
          [[ -f "$SERVICE_PID" ]] && kill -0 "$(cat "$SERVICE_PID")" 2>/dev/null
        else
          _service_is_active "$name"
        fi
        ;;
      enable) return 0 ;;
      disable) _mark_service "$name" inactive ;;
      stop)
        [[ "$name" == vless-reality ]] && _stop_xray || _mark_service "$name" inactive
        ;;
      start|restart)
        if [[ "$name" == vless-reality ]]; then
          if [[ "$action" == restart && "$FAIL_NEXT_RESTART" == 1 ]]; then
            FAIL_NEXT_RESTART=0
            return 1
          fi
          _stop_xray
          _start_xray
        else
          _mark_service "$name" active
        fi
        ;;
      reload) return 0 ;;
      *) return 1 ;;
    esac
  }
  systemctl() {
    echo "systemctl|$*" >>"$SYS_LOG"
    case "$1" in
      is-active) svc status "${*: -1}" ;;
      stop) svc stop "${*: -1}" ;;
      disable) svc disable "${*: -1}" ;;
      reload|restart|start|enable|daemon-reload|status) return 0 ;;
      *) return 0 ;;
    esac
  }

  _fw_spy() {
    local family="$1"; shift
    echo "$family|$*" >>"$FW_LOG"
    local mode="" chain="" range="" port="" prev="" arg
    for arg in "$@"; do
      if [[ "$prev" == --dport ]]; then range="$arg"; prev=""; continue; fi
      if [[ "$prev" == --to-ports ]]; then port="$arg"; prev=""; continue; fi
      case "$arg" in -D|-A|-C) mode="$arg" ;; PREROUTING|OUTPUT) chain="$arg" ;; --dport|--to-ports) prev="$arg" ;; esac
    done
    local key="$family|$chain|$range|$port" t
    case "$mode" in
      -D)
        grep -Fxq -- "$key" "$FW_STATE" || return 1
        t=$(mktemp); awk -v k="$key" '$0!=k' "$FW_STATE" >"$t"; mv "$t" "$FW_STATE"
        ;;
      -C) grep -Fxq -- "$key" "$FW_STATE" ;;
      -A) grep -Fxq -- "$key" "$FW_STATE" || echo "$key" >>"$FW_STATE" ;;
    esac
  }
  iptables() { _fw_spy iptables "$@"; }
  ip6tables() { _fw_spy ip6tables "$@"; }

  data_plane() {
    local uuid="$1" nonce="$2" client="$sandbox/client.json"
    local http_pid client_pid output="" pid
    _stop_xray
    /usr/local/bin/xray run -test -c "$CFG/config.json" >/dev/null 2>&1 || fail "runtime server config invalid"
    /usr/local/bin/xray run -c "$CFG/config.json" >"$sandbox/runtime-server.log" 2>&1 &
    pid=$!; echo "$pid" >"$SERVICE_PID"; _mark_service vless-reality active

    NONCE="$nonce" HTTP_PORT="$http_port" python3 -c 'import http.server,os
class H(http.server.BaseHTTPRequestHandler):
 def do_GET(self):
  b=os.environ["NONCE"].encode(); self.send_response(200); self.send_header("Content-Length",str(len(b))); self.end_headers(); self.wfile.write(b)
 def log_message(self,*a): pass
http.server.ThreadingHTTPServer(("0.0.0.0",int(os.environ["HTTP_PORT"])),H).serve_forever()' >"/sandbox/http.log" 2>&1 &
    http_pid=$!
    jq -n --arg id "$uuid" --argjson sp "$server_port" --argjson lp "$socks_port" --arg path "/e2e" '{
      log:{loglevel:"warning"},
      inbounds:[{listen:"127.0.0.1",port:$lp,protocol:"socks",settings:{auth:"noauth",udp:false}}],
      outbounds:[{protocol:"vless",settings:{vnext:[{address:"127.0.0.1",port:$sp,users:[{id:$id,encryption:"none"}]}]},streamSettings:{network:"ws",security:"none",wsSettings:{path:$path}}}]
    }' >"$client"
    /usr/local/bin/xray run -test -c "$client" >/dev/null 2>&1 || fail "client config invalid"
    /usr/local/bin/xray run -c "$client" >"$sandbox/client.log" 2>&1 &
    client_pid=$!
    for _ in $(seq 1 40); do
      output=$(NO_PROXY= no_proxy= curl -fsS --noproxy '' --socks5-hostname "127.0.0.1:$socks_port" \
        "http://0.0.0.0:$http_port/" 2>/dev/null || true)
      [[ "$output" == "$nonce" ]] && break
      sleep 0.2
    done
    kill_exact "$client_pid"; kill_exact "$http_pid"
    [[ "$output" == "$nonce" ]] || fail "real Xray data plane did not return nonce"
    [[ -f "$SERVICE_PID" ]] && kill -0 "$(cat "$SERVICE_PID")" 2>/dev/null || fail "runtime Xray server died"
  }

  do_install_server <<< $'2\n/e2e\n\nY\n'
  assert_jq "$DB_FILE" '.xray["vless-ws-notls"].port == 18443 and .xray["vless-ws-notls"].uuid == "11111111-1111-4111-8111-111111111111"' "installer DB record wrong"
  assert_file "$CFG/config.json"
  /usr/local/bin/xray run -test -c "$CFG/config.json" >/dev/null 2>&1 || fail "generated production config invalid"
  assert_file /etc/systemd/system/vless-reality.service
  grep -Fq -- "$CFG/config.json" /etc/systemd/system/vless-reality.service || fail "unit does not point to private config"
  [[ -L /usr/local/bin/vless && -f /usr/local/bin/vless-server.sh ]] || fail "shortcut missing"
  cmp -s "$patched" /usr/local/bin/vless-server.sh || fail "shortcut copied wrong source"
  ok "actual do_install_server created DB, valid config, unit, service, and shortcut"

  data_plane "$uuid0" nonce-install
  ok "real Xray client-server-HTTP data plane passed after install"

  local before after
  before=$(count_svc restart vless-reality)
  db_add_user xray vless-ws-notls alice "$uuid1" 0
  after=$(count_svc restart vless-reality)
  assert_eq "$after" "$((before + 1))" "add alice did not trigger exactly one restart"
  assert_jq "$CFG/config.json" '[.inbounds[] | select(.tag=="vless-ws-notls-18443") | .settings.clients[] | select(.id=="22222222-2222-4222-8222-222222222222")] | length == 1' "alice missing from config"
  data_plane "$uuid1" nonce-alice
  ok "db_add_user rebuilt/restarted once and alice data plane passed"

  before=$(count_svc restart vless-reality)
  db_add_user xray vless-ws-notls bob "$uuid2" 0
  after=$(count_svc restart vless-reality)
  assert_eq "$after" "$((before + 1))" "add bob did not trigger exactly one restart"
  before=$after
  db_del_user xray vless-ws-notls alice
  after=$(count_svc restart vless-reality)
  assert_eq "$after" "$((before + 1))" "delete alice did not trigger exactly one restart"
  assert_jq "$DB_FILE" '([.xray["vless-ws-notls"].users[] | select(.name=="bob")] | length == 1) and ([.xray["vless-ws-notls"].users[] | select(.name=="alice")] | length == 0)' "user DB mutation wrong"
  data_plane "$uuid2" nonce-bob
  ok "db_del_user rebuilt/restarted once and remaining bob data plane passed"

  FAIL_NEXT_RESTART=1
  set +e
  db_add_user xray vless-ws-notls failcase "$uuid_fail" 0
  local failure_rc=$?
  set -e
  [[ "$failure_rc" -ne 0 ]] || fail "restart failure was reported as success"
  assert_jq "$DB_FILE" '[.xray["vless-ws-notls"].users[] | select(.name=="failcase" and .uuid=="44444444-4444-4444-8444-444444444444")] | length == 1' "failed restart lost durable DB mutation"
  assert_jq "$CFG/config.json" '[.inbounds[] | select(.tag=="vless-ws-notls-18443") | .settings.clients[] | select(.id=="44444444-4444-4444-8444-444444444444")] | length == 1' "failed restart lost generated config"
  [[ -f "$SERVICE_PID" ]] && kill -0 "$(cat "$SERVICE_PID")" 2>/dev/null || fail "restart failure killed prior service"
  db_del_user xray vless-ws-notls failcase
  ok "restart failure returned nonzero while preserving DB/config and prior process"

  local hy1='{"port":31001,"password":"hy-pass-1","sni":"example.com","hop_enable":1,"hop_start":32001,"hop_end":32010}'
  local hy2='{"port":31002,"password":"hy-pass-2","sni":"example.net","hop_enable":1,"hop_start":32101,"hop_end":32110}'
  db_add singbox hy2 "$hy1"
  db_add_port singbox hy2 "$hy2"
  mkdir -p "$CFG/certs/hy2"
  echo cert-sentinel >"$CFG/certs/hy2/server.crt"
  for family in iptables ip6tables; do
    for chain in PREROUTING OUTPUT; do
      echo "$family|$chain|32001:32010|31001" >>"$FW_STATE"
      echo "$family|$chain|32101:32110|31002" >>"$FW_STATE"
    done
  done
  echo 'iptables|OUTPUT|39990:39999|39999' >>"$FW_STATE"

  local choice
  choice=$(get_installed_protocols | awk '$0=="hy2"{print NR}')
  uninstall_specific_protocol <<< "$choice
1
y"
  assert_jq "$DB_FILE" '.singbox.hy2 | type=="array" and length==1 and .[0].port==31002' "partial HY2 DB cleanup wrong"
  assert_file "$CFG/certs/hy2/server.crt"
  grep -Fq 'iptables|OUTPUT|39990:39999|39999' "$FW_STATE" || fail "third-party NAT sentinel removed"
  grep -q '31001' "$FW_STATE" && fail "selected HY2 NAT rule survived partial uninstall"
  grep -q '31002' "$FW_STATE" || fail "other HY2 NAT rule removed by partial uninstall"
  ok "partial uninstall removed only selected v4/v6 NAT ownership and retained cert/other rules"

  choice=$(get_installed_protocols | awk '$0=="hy2"{print NR}')
  uninstall_specific_protocol <<< "$choice
y"
  jq -e '.singbox.hy2 == null' "$DB_FILE" >/dev/null || fail "last HY2 port remained in DB"
  assert_absent "$CFG/certs/hy2"
  grep -q '31002' "$FW_STATE" && fail "last HY2 NAT rule survived"
  assert_eq "$(grep -c -- '|-t nat -D ' "$FW_LOG")" "8" "unexpected NAT delete spy count"
  grep -Fq 'iptables|OUTPUT|39990:39999|39999' "$FW_STATE" || fail "third-party NAT sentinel lost after last port"
  ok "last-port uninstall removed protocol cert and only its remaining NAT rules"

  mkdir -p /etc/systemd/system
  echo shared-caddy > /etc/systemd/system/shared-caddy.service
  cat >/usr/local/bin/caddy <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x /usr/local/bin/caddy
  do_uninstall <<< $'y\n'
  assert_absent "$DB_FILE"
  assert_absent "$CFG/config.json"
  assert_absent /usr/local/bin/vless
  assert_file /usr/local/bin/caddy
  assert_file /etc/systemd/system/shared-caddy.service
  [[ ! -s "$GLOBAL_KILL_HIT" ]] || fail "global kill command was invoked"
  do_uninstall <<< $'y\n'
  [[ ! -s "$GLOBAL_KILL_HIT" ]] || fail "idempotent uninstall invoked global kill"
  grep -Fq 'iptables|OUTPUT|39990:39999|39999' "$FW_STATE" || fail "full uninstall removed third-party firewall state"
  ok "full uninstall was idempotent, removed project state, and preserved shared Caddy/sentinels"

  _stop_xray
  echo "1..$pass_count"
  echo "PASS: $pass_count lifecycle groups; container isolation + real Xray data plane verified"
}

case "${1:-}" in
  --inside) inside_main ;;
  --identity-selftest) identity_selftest ;;
  "") host_main ;;
  *) echo "Usage: AIO_E2E_EXPECTED_SHA=<sha256> $0 [--identity-selftest]" >&2; exit 2 ;;
esac
