#!/bin/bash
# Isolated regression: disabled credentials must stay absent from generated Xray/sing-box configs.
set -uo pipefail
SCRIPT="${1:-$(dirname "$0")/../vless-server.sh}"
TMP=$(mktemp -d)
trap '[[ "$TMP" == /tmp/* ]] && rm -rf -- "$TMP"' EXIT
export VLESS_SOURCE_ONLY=1
export VLESS_TEST_LOG_ROOT="$TMP/var/log"
SCRIPT_COPY="$TMP/vless-server.sh"
sed -e 's@^readonly CFG="/etc/vless-reality"@readonly CFG="'"$TMP"'"@' "$SCRIPT" > "$SCRIPT_COPY"
source "$SCRIPT_COPY"
_listen_addr() { printf '127.0.0.1\n'; }
svc() { return 1; }
_ok() { :; }
_err() { printf '%s\n' "$*" >&2; }
_info() { :; }
_warn() { :; }
db_get_balancer_groups() { echo '[]'; }
db_get_warp_mode() { echo ''; }
db_get_routing_rules() { echo '[]'; }
_db_apply() {
    shift 2
    jq "$@" "$DB_FILE" >"$DB_FILE.next" || return 1
    mv "$DB_FILE.next" "$DB_FILE"
}
db_get() {
    local config
    config=$(jq --arg c "$1" --arg p "$2" '.[$c][$p] // empty' "$DB_FILE" 2>/dev/null)
    [[ -n "$config" && "$config" != "null" ]] || return 1
    printf '%s\n' "$config"
}
db_list_protocols() { jq -r --arg c "$1" '(.[$c] // {}) | keys[]' "$DB_FILE" 2>/dev/null; }
db_del() {
    jq --arg c "$1" --arg p "$2" 'del(.[$c][$p])' "$DB_FILE" >"$DB_FILE.next" || return 1
    mv "$DB_FILE.next" "$DB_FILE"
}
get_xray_protocols() { db_list_protocols xray; }
get_singbox_protocols() { db_list_protocols singbox; }
_db_touch() { :; }
fail=0
check() {
    local name="$1" result="$2"
    if [[ "$result" == true ]]; then printf '  OK   %s\n' "$name"
    else printf '  FAIL %s\n' "$name" >&2; fail=1; fi
}

# The real setter is exercised with production database helpers, isolated at $TMP.
cat > "$DB_FILE" <<'JSON'
{"xray":{"vless":[{"port":14443,"uuid":"fixture-default"},{"port":14444,"uuid":"fixture-other"}]}}
JSON
if db_set_user_enabled xray vless default false; then migrated=1; else migrated=0; fi
check 'legacy Xray multi-port default can be disabled through real setter' "$([[ "$migrated" -eq 1 ]] && echo true || echo false)"
check 'legacy Xray default disabled state persisted' "$(db_get_user_field xray vless default enabled | grep -qx false && echo true || echo false)"
check 'legacy Xray generated config contains no proxy inbounds' "$(jq -e '[.inbounds[]? | select(.tag != "api")] | length == 0' "$CFG/config.json" >/dev/null && echo true || echo false)"
check 'disabled legacy UUID absent from final JSON' "$(jq -e '[.. | objects | select(.id? == "fixture-default" or .id? == "fixture-other")] | length == 0' "$CFG/config.json" >/dev/null && echo true || echo false)"
check 'multi-port generation removed temporary DB entries' "$(jq -e '([.xray | keys[] | select(startswith("vless_port_"))] | length) == 0' "$DB_FILE" >/dev/null && echo true || echo false)"

# An explicit default must not be resurrected from its top-level UUID fallback.
cat > "$DB_FILE" <<'JSON'
{"xray":{"vless":{"port":14443,"uuid":"fixture-default","users":[{"name":"default","uuid":"fixture-default","enabled":true},{"name":"alice","uuid":"fixture-alice","enabled":true}]}}}
JSON
if db_set_user_enabled xray vless default false; then explicit_result=1; else explicit_result=0; fi
check 'explicit Xray default disable rebuilds successfully' "$([[ "$explicit_result" -eq 1 ]] && echo true || echo false)"
check 'disabled explicit Xray default absent from final inbounds' "$(jq -e '[.inbounds[]? | select(.settings.clients[]?.id=="fixture-default")] | length == 0' "$CFG/config.json" >/dev/null && echo true || echo false)"
check 'enabled Xray peer retained in final inbounds' "$(jq -e '[.inbounds[]? | .settings.clients[]? | select(.email=="alice@vless")] | length == 1' "$CFG/config.json" >/dev/null && echo true || echo false)"
if db_set_user_enabled xray vless default true; then reenabled=1; else reenabled=0; fi
check 'Xray default re-enable rebuilds successfully' "$([[ "$reenabled" -eq 1 ]] && echo true || echo false)"
check 'Xray re-enabled default restored exactly once' "$(jq -e '[.inbounds[]? | .settings.clients[]? | select(.id=="fixture-default")] | length == 1' "$CFG/config.json" >/dev/null && echo true || echo false)"

# Legacy single-port configuration migrates to explicit user state.
cat > "$DB_FILE" <<'JSON'
{"xray":{"vless":{"port":14443,"uuid":"fixture-legacy-single"}}}
JSON
if db_set_user_enabled xray vless default false; then legacy_single=1; else legacy_single=0; fi
check 'legacy single-port default disable succeeds' "$([[ "$legacy_single" -eq 1 ]] && echo true || echo false)"
check 'legacy single-port default remains absent from final config' "$(jq -e '[.inbounds[]? | .settings.clients[]? | select(.id=="fixture-legacy-single")] | length == 0' "$CFG/config.json" >/dev/null && echo true || echo false)"

# Sing-box AnyTLS runs the real setter and generator; reload is stubbed as stopped.
cat > "$DB_FILE" <<'JSON'
{"singbox":{"anytls":[{"port":18443,"password":"fixture-base","users":[{"name":"alice","uuid":"fixture-alice","enabled":true}]},{"port":18444,"password":"fixture-other","users":[{"name":"bob","uuid":"fixture-bob","enabled":true}]}]}}
JSON
if db_set_user_enabled singbox anytls alice false; then sb_disable=1; else sb_disable=0; fi
check 'Sing-box setter/rebuild succeeds with real generator' "$([[ "$sb_disable" -eq 1 ]] && echo true || echo false)"
check 'disabled AnyTLS user and default fallback absent at its port' "$(jq -e '[.inbounds[] | select(.type=="anytls" and .listen_port==18443)] | length == 0' "$CFG/singbox.json" >/dev/null && echo true || echo false)"
check 'unrelated enabled user retained at independent port' "$(jq -e '[.inbounds[] | select(.type=="anytls" and .listen_port==18444) | .users[]? | select(.name=="bob")] | length == 1' "$CFG/singbox.json" >/dev/null && echo true || echo false)"
if db_set_user_enabled singbox anytls alice true; then sb_enable=1; else sb_enable=0; fi
check 'Sing-box re-enable restores the user' "$([[ "$sb_enable" -eq 1 ]] && jq -e '[.inbounds[] | select(.type=="anytls" and .listen_port==18443) | .users[]? | select(.name=="alice")] | length == 1' "$CFG/singbox.json" >/dev/null && echo true || echo false)"

# A disabled explicit user must suppress legacy top-level fallbacks in single- and multi-port Xray records.
cat > "$DB_FILE" <<'JSON'
{"xray":{"vmess":{"port":24443,"uuid":"fixture-vmess","users":[{"name":"alice","uuid":"fixture-vmess-disabled","enabled":false}]},"trojan":{"port":25443,"password":"fixture-trojan","users":[{"name":"alice","uuid":"fixture-trojan-disabled","enabled":false}]},"socks":{"port":26443,"username":"fixture-socks-user","password":"fixture-socks","users":[{"name":"alice","uuid":"fixture-socks-disabled","enabled":false}]},"vmess_multi":[{"port":27443,"uuid":"fixture-vmess-multi","users":[{"name":"alice","uuid":"fixture-vmess-multi-disabled","enabled":false}]}],"trojan_multi":[{"port":28443,"password":"fixture-trojan-multi","users":[{"name":"alice","uuid":"fixture-trojan-multi-disabled","enabled":false}]}],"socks_multi":[{"port":29443,"username":"fixture-socks-multi-user","password":"fixture-socks-multi","users":[{"name":"alice","uuid":"fixture-socks-multi-disabled","enabled":false}]}]},"singbox":{"hy2":{"port":20443,"password":"fixture-hy2","users":[{"name":"alice","uuid":"fixture-hy2-disabled","enabled":false}]},"tuic":{"port":30443,"uuid":"fixture-tuic-disabled","password":"fixture-tuic-password","users":[{"name":"alice","uuid":"fixture-tuic-disabled","password":"fixture-tuic-password","enabled":false}]}}}
JSON
check 'disabled VMess clients do not fall back to top-level UUID' "$(gen_xray_vmess_clients vmess | jq -e 'length == 0' >/dev/null && echo true || echo false)"
check 'disabled Trojan clients do not fall back to top-level password' "$(gen_xray_trojan_clients trojan | jq -e 'length == 0' >/dev/null && echo true || echo false)"
check 'disabled SOCKS accounts do not fall back to top-level credentials' "$(gen_xray_socks_accounts socks | jq -e 'length == 0' >/dev/null && echo true || echo false)"
check 'disabled multi-port VMess clients do not fall back' "$(gen_xray_vmess_clients vmess-multi | jq -e 'length == 0' >/dev/null && echo true || echo false)"
check 'disabled multi-port Trojan clients do not fall back' "$(gen_xray_trojan_clients trojan-multi | jq -e 'length == 0' >/dev/null && echo true || echo false)"
check 'disabled multi-port SOCKS accounts do not fall back' "$(gen_xray_socks_accounts socks-multi | jq -e 'length == 0' >/dev/null && echo true || echo false)"
cat > "$DB_FILE" <<'JSON'
{"singbox":{"hy2":{"port":20443,"password":"fixture-hy2","users":[{"name":"alice","uuid":"fixture-hy2-disabled","enabled":false}]},"tuic":{"port":30443,"uuid":"fixture-tuic-disabled","password":"fixture-tuic-password","users":[{"name":"alice","uuid":"fixture-tuic-disabled","password":"fixture-tuic-password","enabled":false}]}}}
JSON
rm -f "$CFG/singbox.json"
if generate_singbox_config; then sb_empty_rc=0; else sb_empty_rc=1; fi
check 'all-disabled Sing-box configuration is safely rejected' "$([[ "$sb_empty_rc" -ne 0 ]] && echo true || echo false)"
check 'all-disabled Sing-box leaves no stale configuration file' "$([[ ! -e "$CFG/singbox.json" ]] && echo true || echo false)"

# The full Xray generator must skip an all-disabled VMess-WS inbound, not just
# return [] from its client helper. Keep an enabled peer so this is not vacuous.
cat > "$DB_FILE" <<'JSON'
{"xray":{"vmess-ws":{"port":18446,"uuid":"11111111-2222-4333-8444-555555555555","users":[{"name":"off","uuid":"11111111-2222-4333-8444-555555555555","enabled":false}]},"vless-ws-notls":{"port":18447,"uuid":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","users":[{"name":"on","uuid":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","enabled":true}]}}}
JSON
if generate_xray_config; then xray_mixed=1; else xray_mixed=0; fi
check 'mixed enabled/disabled Xray config rebuilds' "$([[ "$xray_mixed" -eq 1 ]] && echo true || echo false)"
check 'disabled VMess-WS has no listener in generated config' "$(jq -e '[.inbounds[]? | select(.port==18446)] | length == 0' "$CFG/config.json" >/dev/null && echo true || echo false)"
check 'enabled VLESS-WS peer remains in generated config' "$(jq -e '[.inbounds[]? | select(.port==18447) | .settings.clients[]? | select(.id=="aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")] | length == 1' "$CFG/config.json" >/dev/null && echo true || echo false)"
# Regression (h10): log paths must be expanded values, never shell syntax. A literal
# "${VLESS_TEST_LOG_ROOT:-/var/log}/..." makes Xray abort at startup with
# "app/log: failed to initialize access logger > open ...: no such file or directory" (rc=23).
check 'generated log paths contain no unexpanded shell syntax' \
    "$(jq -r '.log.access, .log.error' "$CFG/config.json" | grep -q '\${' && echo false || echo true)"
check 'generated log paths are absolute' \
    "$(jq -r '.log.access' "$CFG/config.json" | grep -q '^/' && echo true || echo false)"

if [[ "$fail" -ne 0 ]]; then exit 1; fi
printf 'manual-user-disable: PASS\n'
