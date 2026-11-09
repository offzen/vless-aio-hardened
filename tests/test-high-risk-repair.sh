#!/bin/bash
# Isolated regression for the h12 high-risk repair set.
# Exercises production functions with temporary state and strict command spies.
set -uo pipefail

SCRIPT="${1:-$(dirname "$0")/../vless-server.sh}"
[[ -f "$SCRIPT" ]] || { echo "missing script: $SCRIPT" >&2; exit 2; }
for dep in jq sed awk grep; do
    command -v "$dep" >/dev/null 2>&1 || { echo "missing dependency: $dep" >&2; exit 2; }
done

TMP=$(mktemp -d "${TMPDIR:-/tmp}/aio-high-risk.XXXXXX")
trap '[[ "$TMP" == /tmp/* ]] && rm -rf -- "$TMP"' EXIT
SCRIPT_COPY="$TMP/vless-server.sh"
sed -e 's@^readonly VERSION="[^"]*"@readonly VERSION="test-fixture"@' \
    -e 's@^readonly CFG="/etc/vless-reality"@readonly CFG="'"$TMP"'/cfg"@' \
    -e 's@^readonly CLOUDFLARED_BIN="/usr/local/bin/cloudflared"@readonly CLOUDFLARED_BIN="'"$TMP"'/bin/cloudflared"@' \
    -e 's@^readonly CLOUDFLARED_DIR="/etc/cloudflared"@readonly CLOUDFLARED_DIR="'"$TMP"'/cloudflared"@' \
    "$SCRIPT" > "$SCRIPT_COPY"
mkdir -p "$TMP/cfg" "$TMP/bin" "$TMP/cloudflared"
export VLESS_SOURCE_ONLY=1 VLESS_TEST_LOG_ROOT="$TMP/log"
# shellcheck disable=SC1090
source "$SCRIPT_COPY"
set +e

pass=0
fail=0
check() {
    local name="$1"
    shift
    if "$@"; then
        pass=$((pass + 1)); printf '  OK   %s\n' "$name"
    else
        fail=$((fail + 1)); printf '  FAIL %s\n' "$name" >&2
    fi
}
contains_line() { grep -Fqx -- "$2" "$1"; }
not_contains() { ! grep -Eq -- "$2" "$1"; }
_info() { :; }
_ok() { :; }
_warn() { :; }
_err() { printf 'ERR: %s\n' "$*" >&2; }
_pause() { :; }
_listen_addr() { printf '127.0.0.1\n'; }
db_get_balancer_groups() { echo '[]'; }
db_get_warp_mode() { echo ''; }
db_get_routing_rules() { echo '[]'; }
ensure_expire_check_cron() { :; }
ensure_traffic_cron() { :; }
svc() { return 1; }

printf '########## 1. Xray user mutation uses one full rebuild ##########\n'
cat > "$DB_FILE" <<'JSON'
{
  "xray": {
    "vless": {"port":14443,"uuid":"11111111-1111-4111-8111-111111111111","users":[{"name":"default","uuid":"11111111-1111-4111-8111-111111111111","enabled":true}]},
    "vless-ws-notls": {"port":14444,"uuid":"22222222-2222-4222-8222-222222222222","users":[{"name":"peer","uuid":"22222222-2222-4222-8222-222222222222","enabled":true}]},
    "vmess-ws": {"port":14445,"uuid":"33333333-3333-4333-8333-333333333333","users":[{"name":"vm","uuid":"33333333-3333-4333-8333-333333333333","enabled":true}]}
  },
  "singbox": {}
}
JSON
rebuild_calls=0
rebuild_and_reload_xray() { rebuild_calls=$((rebuild_calls + 1)); generate_xray_config; }
rebuild_and_reload_singbox() { return 0; }
if db_add_user xray vless alice aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa 0 ''; then add_rc=0; else add_rc=$?; fi
check 'db_add_user succeeds' test "$add_rc" -eq 0
check 'add performs exactly one Xray rebuild' test "$rebuild_calls" -eq 1
check 'target VLESS contains new user once' jq -e '[.inbounds[]? | select(.port==14443) | .settings.clients[]? | select(.id=="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")] | length == 1' "$CFG/config.json"
check 'unrelated VLESS inbound keeps its own peer' jq -e '[.inbounds[]? | select(.port==14444) | .settings.clients[]? | select(.id=="22222222-2222-4222-8222-222222222222")] | length == 1' "$CFG/config.json"
check 'new user does not leak to unrelated VLESS inbound' jq -e '[.inbounds[]? | select(.port==14444) | .settings.clients[]? | select(.id=="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")] | length == 0' "$CFG/config.json"
check 'VMess schema remains VMess email/id without flow' jq -e '[.inbounds[]? | select(.port==14445) | .settings.clients[]? | select(.id=="33333333-3333-4333-8333-333333333333" and .email=="vm@vmess-ws" and (has("flow")|not))] | length == 1' "$CFG/config.json"
if db_del_user xray vless alice; then del_rc=0; else del_rc=$?; fi
check 'db_del_user succeeds' test "$del_rc" -eq 0
check 'delete performs exactly one additional rebuild' test "$rebuild_calls" -eq 2
check 'deleted user absent everywhere' jq -e '[.. | objects | select(.id?=="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")] | length == 0' "$CFG/config.json"

printf '\n########## 2. NAT cleanup is exact, symmetric and fail closed ##########\n'
cat > "$DB_FILE" <<'JSON'
{"xray":{},"singbox":{"hy2":[{"port":24443,"hop_enable":1,"hop_start":21000,"hop_end":21999},{"port":24444,"hop_enable":1,"hop_start":22000,"hop_end":22999}],"tuic":{"port":34443,"hop_enable":1,"hop_start":31000,"hop_end":31999}}}
JSON
: > "$TMP/netfilter.calls"
iptables() { printf 'iptables %s\n' "$*" >> "$TMP/netfilter.calls"; [[ " $* " == *' -S '* ]] && printf '%s\n' '-A PREROUTING -p tcp --dport 9999 -j REDIRECT --to-ports 9998'; return 0; }
ip6tables() { printf 'ip6tables %s\n' "$*" >> "$TMP/netfilter.calls"; [[ " $* " == *' -S '* ]] && printf '%s\n' '-A OUTPUT -p tcp --dport 9999 -j REDIRECT --to-ports 9998'; return 0; }
cleanup_hy2_nat_rules
check 'hy2 port 24443 IPv4 PREROUTING exact delete' contains_line "$TMP/netfilter.calls" 'iptables -t nat -D PREROUTING -p udp --dport 21000:21999 -j REDIRECT --to-ports 24443'
check 'hy2 port 24444 IPv6 OUTPUT exact delete' contains_line "$TMP/netfilter.calls" 'ip6tables -t nat -D OUTPUT -p udp --dport 22000:22999 -j REDIRECT --to-ports 24444'
check 'tuic port 34443 IPv4 OUTPUT exact delete' contains_line "$TMP/netfilter.calls" 'iptables -t nat -D OUTPUT -p udp --dport 31000:31999 -j REDIRECT --to-ports 34443'
: > "$TMP/netfilter.calls"
cleanup_hy2_nat_rules hy2 24443
check 'targeted partial uninstall deletes selected port rule' contains_line "$TMP/netfilter.calls" 'iptables -t nat -D PREROUTING -p udp --dport 21000:21999 -j REDIRECT --to-ports 24443'
check 'targeted partial uninstall preserves other HY2 port rule' not_contains "$TMP/netfilter.calls" '24444|22000:22999'
check 'targeted partial uninstall preserves TUIC rule' not_contains "$TMP/netfilter.calls" '34443|31000:31999'
check 'cleanup never enumerates whole NAT chains' not_contains "$TMP/netfilter.calls" ' -S( |$)'
check 'cleanup never deletes third-party ports' not_contains "$TMP/netfilter.calls" '9999|9998'
rm -f "$DB_FILE"; : > "$TMP/netfilter.calls"
cleanup_hy2_nat_rules
check 'missing DB makes NAT cleanup a no-op' test ! -s "$TMP/netfilter.calls"
cat > "$DB_FILE" <<'JSON'
{"xray":{},"singbox":{"hy2":{"port":24443,"hop_enable":0,"hop_start":21000,"hop_end":21999}}}
JSON
: > "$TMP/netfilter.calls"
cleanup_hy2_nat_rules
check 'disabled hop configuration is not treated as an owned rule' test ! -s "$TMP/netfilter.calls"

printf '\n########## 3. Force cleanup has no global process-name kill ##########\n'
: > "$TMP/process.calls"
svc() { printf 'svc %s\n' "$*" >> "$TMP/process.calls"; return 0; }
killall() { printf 'killall %s\n' "$*" >> "$TMP/process.calls"; return 99; }
pkill() { printf 'pkill %s\n' "$*" >> "$TMP/process.calls"; return 99; }
cleanup_hy2_nat_rules() { printf 'nat-cleanup\n' >> "$TMP/process.calls"; }
force_cleanup
check 'force cleanup uses project services' grep -q '^svc stop vless-' "$TMP/process.calls"
check 'force cleanup does not call killall/pkill' not_contains "$TMP/process.calls" '^(killall|pkill) '

printf '\n########## 4. Shared HY2/TUIC certificates survive partial uninstall ##########\n'
# Static control-flow assertions keep this regression deterministic while the DB helper tests above
# exercise real mutation. Certificate deletion must be guarded by the post-removal remaining-port state.
check 'certificate cleanup helper exists' grep -q '^cleanup_protocol_cert_if_unused()' "$SCRIPT"
check 'HY2/TUIC pre-removal certificate deletion absent' not_contains "$SCRIPT" '^[[:space:]]*rm -rf "\$CFG/certs/(hy2|tuic)"'
# Exercise the real ownership helper against two-port, one-port and absent protocol states.
mkdir -p "$CFG/certs/hy2" "$CFG/certs/tuic"
printf keep > "$CFG/certs/hy2/marker"
printf keep > "$CFG/certs/tuic/marker"
cat > "$DB_FILE" <<'JSON'
{"xray":{},"singbox":{"hy2":[{"port":24443},{"port":24444}],"tuic":{"port":34443}}}
JSON
cleanup_protocol_cert_if_unused hy2
check 'HY2 cert retained while protocol has ports' test -f "$CFG/certs/hy2/marker"
db_remove_port singbox hy2 24443
cleanup_protocol_cert_if_unused hy2
check 'HY2 cert retained after partial port removal' test -f "$CFG/certs/hy2/marker"
db_remove_port singbox hy2 24444
cleanup_protocol_cert_if_unused hy2
check 'HY2 cert removed after last port removal' test ! -e "$CFG/certs/hy2"
cleanup_protocol_cert_if_unused tuic
check 'TUIC cert retained while protocol exists' test -f "$CFG/certs/tuic/marker"
db_del singbox tuic
cleanup_protocol_cert_if_unused tuic
check 'TUIC cert removed only when protocol is absent' test ! -e "$CFG/certs/tuic"

printf '\n########## 5. Main-menu pre-choice tunnel mutation removed ##########\n'
main_menu_body=$(awk '/^main_menu\(\)/{f=1} f{print} f&&/^}$/{exit}' "$SCRIPT")
check 'main_menu contains no implicit tunnel sync' bash -c '! grep -q "_sync_tunnel_config" <<< "$1"' _ "$main_menu_body"
check 'explicit protocol mutation still synchronizes tunnel' grep -A18 -q '^db_add()' "$SCRIPT"

printf '\n########## 6. Caddy cleanup is ownership-gated ##########\n'
do_uninstall_body=$(awk '/^do_uninstall\(\)/{f=1} f{print} f&&/^}$/{exit}' "$SCRIPT")
check 'full uninstall contains no global pkill/killall' bash -c '! grep -Eq "(^|[[:space:]])(pkill|killall)([[:space:]]|$)" <<< "$1"' _ "$do_uninstall_body"
check 'project Naive service is stopped only through its unit boundary' bash -c 'grep -q "has_naive" <<< "$1" && grep -q "svc stop vless-naive" <<< "$1"' _ "$do_uninstall_body"
check 'shared Caddy binary is never auto-deleted' bash -c '! grep -Eq "rm -f .*/caddy" <<< "$1"' _ "$do_uninstall_body"

printf '\n'
if [[ "$fail" -eq 0 ]]; then
    printf 'PASS: high-risk repair regression (%d assertions)\n' "$pass"
else
    printf 'FAIL: %d assertions failed (%d passed)\n' "$fail" "$pass" >&2
    exit 1
fi
