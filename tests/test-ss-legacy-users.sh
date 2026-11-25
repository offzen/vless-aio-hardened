#!/bin/bash
# Isolated regression for ss-legacy multi-user config and share-link menus.
set -uo pipefail

SCRIPT="${1:-$(dirname "$0")/../vless-server.sh}"
[[ -f "$SCRIPT" ]] || { echo "missing script: $SCRIPT" >&2; exit 2; }
for dep in jq sed grep base64; do
    command -v "$dep" >/dev/null 2>&1 || { echo "missing dependency: $dep" >&2; exit 2; }
done

TMP=$(mktemp -d "${TMPDIR:-/tmp}/aio-ss-legacy.XXXXXX")
TMP=$(cd -- "$TMP" && pwd -P) || exit 2
trap '[[ "$TMP" == /tmp/* ]] && rm -rf -- "$TMP"' EXIT
SCRIPT_COPY="$TMP/vless-server.sh"
cp "$SCRIPT" "$SCRIPT_COPY"
mkdir -p "$TMP/cfg"
export VLESS_SOURCE_ONLY=1 VLESS_TEST_CFG="$TMP/cfg" VLESS_TEST_LOG_ROOT="$TMP/log"
# shellcheck disable=SC1090
source "$SCRIPT_COPY"
[[ "$CFG" == "$TMP/cfg" ]] || { echo 'FAIL: VLESS_TEST_CFG isolation' >&2; exit 2; }
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
check_eq() { [[ "$1" == "$2" ]]; }
_info() { :; }
_ok() { :; }
_warn() { :; }
_err() { printf 'ERR: %s\n' "$*" >&2; }
_pause() { :; }
_listen_addr() { printf '127.0.0.1\n'; }
db_get_balancer_groups() { echo '[]'; }
db_get_warp_mode() { echo ''; }
db_get_routing_rules() { echo '[]'; }
db_ip_routing_enabled() { return 1; }
get_ipv4() { printf '198.51.100.10\n'; }
get_ipv6() { :; }
get_ip_country() { printf 'ZZ\n'; }

DEFAULT_PASSWORD='fixture-default-01'
YTB_PASSWORD='fixture-ytb-02'
REVOKED_PASSWORD='fixture-revoked-03'
EXPIRED_PASSWORD='{{SECRET_expired_k2x9}}'
EDGE_PASSWORD='{{SECRET_edge_n4p8}}'

write_multi_user_fixture() {
    cat > "$DB_FILE" <<JSON
{
  "xray": {
    "ss-legacy": {
      "port": 18388,
      "method": "aes-256-gcm",
      "password": "$DEFAULT_PASSWORD",
      "users": [
        {"name":"default","uuid":"$DEFAULT_PASSWORD","enabled":true},
        {"name":"ytb","uuid":"$YTB_PASSWORD"},
        {"name":"revoked","uuid":"$REVOKED_PASSWORD","enabled":false},
        {"name":"expired","uuid":"$EXPIRED_PASSWORD","enabled":true,"expire_date":"2000-01-01"}
      ]
    }
  },
  "singbox": {}
}
JSON
}

share_password() {
    local uri="$1" userinfo
    userinfo="${uri#ss://}"
    userinfo="${userinfo%%@*}"
    printf '%s' "$userinfo" | base64 -d 2>/dev/null | sed 's/^[^:]*://'
}

printf '########## 1. Xray ss-legacy multi-user generation ##########\n'
write_multi_user_fixture
generate_xray_config
check 'multi-user config generates' test "$?" -eq 0
check 'two enabled legacy clients rendered' bash -c '[[ "$(jq "[.inbounds[] | select(.tag==\"ss-legacy-18388\") | .settings.clients[]] | length" "$1")" == 2 ]]' _ "$CFG/config.json"
check 'legacy config never emits ignored settings.users' jq -e '[.inbounds[] | select(.tag=="ss-legacy-18388") | .settings | has("users")] == [false]' "$CFG/config.json"
check 'multi-user config omits legacy top-level password' jq -e '[.inbounds[] | select(.tag=="ss-legacy-18388") | .settings | has("password")] == [false]' "$CFG/config.json"
check 'default client rendered with inherited method' bash -c '[[ "$(jq --arg pw "$2" "[.inbounds[] | select(.tag==\"ss-legacy-18388\") | .settings.clients[] | select(.password==\$pw and .method==\"aes-256-gcm\" and .email==\"default@ss-legacy\")] | length" "$1")" == 1 ]]' _ "$CFG/config.json" "$DEFAULT_PASSWORD"
check 'missing enabled defaults to active' bash -c '[[ "$(jq --arg pw "$2" "[.inbounds[] | select(.tag==\"ss-legacy-18388\") | .settings.clients[] | select(.password==\$pw and .method==\"aes-256-gcm\" and .email==\"ytb@ss-legacy\")] | length" "$1")" == 1 ]]' _ "$CFG/config.json" "$YTB_PASSWORD"
check 'disabled user excluded' bash -c '[[ "$(jq --arg pw "$2" "[.. | objects | select(.password?==\$pw)] | length" "$1")" == 0 ]]' _ "$CFG/config.json" "$REVOKED_PASSWORD"
check 'expired user excluded' bash -c '[[ "$(jq --arg pw "$2" "[.. | objects | select(.password?==\$pw)] | length" "$1")" == 0 ]]' _ "$CFG/config.json" "$EXPIRED_PASSWORD"

cat > "$DB_FILE" <<JSON
{
  "xray": {
    "ss-legacy": [{
      "port": 18388,
      "method": "aes-256-gcm",
      "password": "$DEFAULT_PASSWORD",
      "users": [
        {"name":"default","uuid":"$DEFAULT_PASSWORD","enabled":true},
        {"name":"ytb","uuid":"$YTB_PASSWORD","enabled":true}
      ]
    }]
  },
  "singbox": {}
}
JSON
generate_xray_config
check 'multi-port wrapper preserves legacy clients' bash -c '[[ "$(jq "[.inbounds[] | select(.tag==\"ss-legacy-18388\") | .settings.clients[]] | length" "$1")" == 2 ]]' _ "$CFG/config.json"

cat > "$DB_FILE" <<JSON
{"xray":{"ss-legacy":{"port":18388,"method":"aes-256-gcm","password":"$DEFAULT_PASSWORD","users":[]}},"singbox":{}}
JSON
generate_xray_config
check 'explicit empty users fails closed without inbound' jq -e '[.inbounds[] | select(.tag=="ss-legacy-18388")] | length == 0' "$CFG/config.json"

cat > "$DB_FILE" <<JSON
{"xray":{"ss-legacy":{"port":18388,"method":"aes-256-gcm","password":"$DEFAULT_PASSWORD","users":[{"name":"revoked","uuid":"$REVOKED_PASSWORD","enabled":false},{"name":"expired","uuid":"$EXPIRED_PASSWORD","expire_date":"2000-01-01"}]}},"singbox":{}}
JSON
generate_xray_config
check 'all inactive users fail closed without inbound' jq -e '[.inbounds[] | select(.tag=="ss-legacy-18388")] | length == 0' "$CFG/config.json"

cat > "$DB_FILE" <<JSON
{"xray":{"ss-legacy":[{"port":18388,"method":"aes-256-gcm","password":"$DEFAULT_PASSWORD","users":[{"name":"default","uuid":"$DEFAULT_PASSWORD"}]},{"port":"18389","method":"aes-128-gcm","password":"$EDGE_PASSWORD","users":[{"name":"edge","uuid":"$EDGE_PASSWORD"}]}]},"singbox":{}}
JSON
generate_xray_config
check 'two-port config keeps each credential isolated' jq -e --arg p1 "$DEFAULT_PASSWORD" --arg p2 "$EDGE_PASSWORD" '([.inbounds[] | select(.tag=="ss-legacy-18388") | .settings.clients[] | select(.password==$p1 and .method=="aes-256-gcm")] | length == 1) and ([.inbounds[] | select(.tag=="ss-legacy-18389") | .settings.clients[] | select(.password==$p2 and .method=="aes-128-gcm")] | length == 1) and ([.inbounds[] | .settings.clients[]?] | length == 2)' "$CFG/config.json"
edge_link=$(_gen_user_share_link xray ss-legacy "$EDGE_PASSWORD" edge 18389)
check 'second-port link uses matching port and method' bash -c '[[ "$1" == ss://*@198.51.100.10:18389* && "$(printf %s "${1#ss://}" | cut -d@ -f1 | base64 -d 2>/dev/null)" == "aes-128-gcm:$2" ]]' _ "$edge_link" "$EDGE_PASSWORD"

printf '\n########## 2. Legacy single-user compatibility ##########\n'
cat > "$DB_FILE" <<JSON
{"xray":{"ss-legacy":{"port":18388,"method":"aes-256-gcm","password":"$DEFAULT_PASSWORD"}},"singbox":{}}
JSON
generate_xray_config
check 'single-user config generates' test "$?" -eq 0
check 'single-user config has no users key' jq -e '[.inbounds[] | select(.tag=="ss-legacy-18388") | .settings | has("users")] == [false]' "$CFG/config.json"
check 'single-user top-level password preserved' jq -e --arg pw "$DEFAULT_PASSWORD" '[.inbounds[] | select(.tag=="ss-legacy-18388") | .settings.password] == [$pw]' "$CFG/config.json"

printf '\n########## 3. Per-user ss:// links ##########\n'
write_multi_user_fixture
default_link=$(_gen_user_share_link xray ss-legacy "$DEFAULT_PASSWORD" default 18388)
ytb_link=$(_gen_user_share_link xray ss-legacy "$YTB_PASSWORD" ytb 18388)
check 'default link emitted' bash -c '[[ "$1" == ss://*"@198.51.100.10:18388#"* ]]' _ "$default_link"
check 'default link carries default credential' check_eq "$(share_password "$default_link")" "$DEFAULT_PASSWORD"
check 'ytb link emitted' bash -c '[[ "$1" == ss://*"@198.51.100.10:18388#"* ]]' _ "$ytb_link"
check 'ytb link carries ytb credential' check_eq "$(share_password "$ytb_link")" "$YTB_PASSWORD"
check 'per-user links differ' bash -c '[[ "$1" != "$2" ]]' _ "$default_link" "$ytb_link"

printf '\n########## 4. Single-user and all-user menu paths ##########\n'
_header() { :; }
_dline() { :; }
_line() { :; }
_item() { :; }
qrencode() { return 1; }

single_output=$(printf '2\n0\n' | _show_user_share_links xray ss-legacy)
check 'single-user menu no longer reports generation failure' bash -c '! grep -Fq "无法生成链接" <<< "$1"' _ "$single_output"
check 'single-user menu emits ytb link' bash -c 'grep -Fq "$2" <<< "$1"' _ "$single_output" "$ytb_link"

all_output=$(printf 'a\n0\n' | _show_user_share_links xray ss-legacy)
check 'all-user menu emits two ss links' check_eq "$(grep -o 'ss://[^[:space:]]*' <<< "$all_output" | wc -l | tr -d ' ')" '2'
check 'all-user menu omits disabled user' bash -c '! grep -Fq "revoked" <<< "$1"' _ "$all_output"
check 'all-user menu omits expired user' bash -c '! grep -Fq "expired" <<< "$1"' _ "$all_output"
# Verify both enabled users are present and distinct.
check 'all-user menu includes default link' bash -c 'grep -Fq "$2" <<< "$1"' _ "$all_output" "$default_link"
check 'all-user menu includes ytb link' bash -c 'grep -Fq "$2" <<< "$1"' _ "$all_output" "$ytb_link"

printf '\n'
if [[ "$fail" -eq 0 ]]; then
    printf 'PASS: ss-legacy multi-user/share-link regression (%d assertions)\n' "$pass"
else
    printf 'FAIL: %d assertions failed (%d passed)\n' "$fail" "$pass" >&2
    exit 1
fi
