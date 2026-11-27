#!/usr/bin/env bash
# Regression suite for H15 P0/P1 security & reliability hardening.
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PRODUCT="${1:-$ROOT/vless-server.sh}"
[[ -f "$PRODUCT" ]] || { echo "FAIL: missing product: $PRODUCT" >&2; exit 2; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/aio-h15-hardening.XXXXXX")
TMP=$(cd -- "$TMP" && pwd -P) || exit 2
trap 'rm -rf -- "$TMP"' EXIT INT TERM

mkdir -p "$TMP/cfg" "$TMP/bin"
export VLESS_SOURCE_ONLY=1 VLESS_TEST_CFG="$TMP/cfg" VLESS_TEST_LOG_ROOT="$TMP/log"
# shellcheck disable=SC1090
source "$PRODUCT"
[[ "$CFG" == "$TMP/cfg" ]] || { echo "FAIL: VLESS_TEST_CFG isolation failed" >&2; exit 2; }
set +e

pass=0
fail=0
check() {
    local label=$1
    shift
    if "$@"; then
        pass=$((pass + 1))
        printf '  OK   %s\n' "$label"
    else
        fail=$((fail + 1))
        printf '  FAIL %s\n' "$label" >&2
    fi
}
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }

_info() { :; }; _ok() { :; }; _warn() { :; }; _err() { :; }
_listen_addr() { printf '127.0.0.1\n'; }

printf '########## 1. C-1 Command Injection Defenses ##########\n'
# 1a. _display_sorted_latencies with malicious node name
declare -A TEST_MARKS
evil_node='evil$(touch '"$TMP"'/pwn_latency)'
TEST_MARKS["$evil_node"]="MARKED"
printf '10|10|%s|socks|1.2.3.4|1080\n' "$evil_node" > "$TMP/lat.txt"
out_lat=$(_display_sorted_latencies "$TMP/lat.txt" "TEST_MARKS" 2>&1)
check 'C-1a _display_sorted_latencies does not execute command in node name' test ! -e "$TMP/pwn_latency"
check 'C-1a _display_sorted_latencies preserves mark via nameref' grep -Fq 'MARKED' <<< "$out_lat"

# 1b. _write_sub_info / _load_sub_info without source
_write_sub_info "11111111-1111-4111-8111-111111111111" "18443" "a.example; touch $TMP/pwn_sub" "true"
sub_uuid=""; sub_port=""; sub_domain=""; sub_https=""
_load_sub_info "$CFG/sub.info"
check 'C-1b _load_sub_info does not execute shell metacharacters' test ! -e "$TMP/pwn_sub"
check 'C-1b _load_sub_info loads literal domain' test "$sub_domain" = "a.example; touch $TMP/pwn_sub"
check 'C-1b sub.info created with 0600 permissions' test "$(mode_of "$CFG/sub.info")" = "600"

# 1c. xray_api_query without eval
cat > "$TMP/bin/xray" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@"
EOF
chmod +x "$TMP/bin/xray"
PATH="$TMP/bin:$PATH" xray_out=$(xray_api_query "user>>>\$(touch $TMP/pwn_xray)>>>uplink" "false")
check 'C-1c xray_api_query does not eval pattern' test ! -e "$TMP/pwn_xray"
check 'C-1c xray_api_query passes pattern verbatim' grep -Fq '$(touch ' <<< "$xray_out"

# 1d. Static ban of dangerous patterns removed in H15
check 'C-1d no eval export dns_env in product' bash -c '! grep -Fq "eval \"export \$dns_env\"" "$1"' _ "$PRODUCT"
check 'C-1d no source sub.info in product' bash -c '! grep -Fq "source \"\$CFG/sub.info\"" "$1"' _ "$PRODUCT"
check 'M-6 no bare pkill -HUP xray in product' bash -c '! grep -Fq "pkill -HUP xray" "$1"' _ "$PRODUCT"
check 'H-3 no /tmp/vless-certs-backup in product' bash -c '! grep -Fq "/tmp/vless-certs-backup" "$1"' _ "$PRODUCT"
check 'M-3 no plaintext baidu HTTP time sync in product' bash -c '! grep -Fq "http://www.baidu.com" "$1"' _ "$PRODUCT"
check 'M-7 no undefined install_warp_go call in product' bash -c '! grep -Fq "install_warp_go" "$1"' _ "$PRODUCT"
check 'L-1 no hardcoded akilecloud credentials in product' bash -c '! grep -Fq "akilecloud" "$1"' _ "$PRODUCT"

printf '\n########## 2. C-2 Routing Order & Private-IP/BT Block Enforcement ##########\n'
init_db
check 'H-3 db.json created with 0600 permissions' test "$(mode_of "$DB_FILE")" = "600"

# Write WARP config with 0600 check
cat > "$TMP/wgcf.conf" <<'EOF'
[Interface]
PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
Address = 172.16.0.2/32
Address = 2606:4700:110::2/128
[Peer]
PublicKey = BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=
Endpoint = 162.159.192.1:2408
EOF
curl() { printf '198.51.100.1\n'; }
parse_and_save_warp_config "$TMP/wgcf.conf"
unset -f curl
check 'H-3 warp.json created with 0600 permissions' test "$(mode_of "$WARP_CONF_FILE")" = "600"

cat > "$DB_FILE" <<'JSON'
{
  "xray": {
    "vless": [
      {"port": 24443, "uuid": "11111111-1111-4111-8111-000000000001", "sni": "example.com", "short_id": "0123456789abcdef", "private_key": "priv", "public_key": "pub", "users": [{"name": "alice", "uuid": "11111111-1111-4111-8111-000000000001", "enabled": true, "routing": "direct"}]},
      {"port": 24444, "uuid": "11111111-1111-4111-8111-000000000002", "sni": "example.com", "short_id": "0123456789abcdef", "private_key": "priv", "public_key": "pub", "users": [{"name": "bob", "uuid": "11111111-1111-4111-8111-000000000002", "enabled": true}]}
    ]
  },
  "singbox": {
    "anytls": {
      "port": 25443, "password": "top", "sni": "example.com",
      "users": [{"name": "alice", "uuid": "alice-pw", "enabled": true, "routing": "direct"}]
    }
  },
  "routing": {"warp_mode": "wgcf"},
  "routing_rules": [{"id": "r1", "type": "all", "outbound": "warp", "ip_version": "prefer_ipv4"}],
  "ip_routing": {"enabled": true, "rules": [{"inbound_ip": "198.51.100.10", "outbound_ip": "198.51.100.20"}]}
}
JSON

db_sha_before=$(sha256sum "$DB_FILE" | awk '{print $1}')
generate_xray_config >/dev/null 2>&1
db_sha_after=$(sha256sum "$DB_FILE" | awk '{print $1}')
check 'H-8 multi-port generate_xray_config does not mutate db.json' test "$db_sha_before" = "$db_sha_after"
check 'H-3 config.json created with 0600 permissions' test "$(mode_of "$CFG/config.json")" = "600"
check 'C-2 Xray blocks ::1/128 and 100.64.0.0/10 before ip_routing and user routing' jq -e '
    .routing.rules as $r |
    ($r | map(.outboundTag == "block" and ((.ip // []) | index("::1/128") != null and index("100.64.0.0/10") != null)) | index(true)) as $priv_idx |
    ($r | map(.outboundTag == "block" and (.protocol // []) == ["bittorrent"]) | index(true)) as $bt_idx |
    ($r | map((.outboundTag // "") | startswith("direct-ip-")) | index(true)) as $ip_idx |
    ($r | map((.user // []) | index("alice@vless") != null) | index(true)) as $u_idx |
    ($priv_idx != null and $bt_idx != null and $ip_idx != null and $u_idx != null and $priv_idx < $ip_idx and $bt_idx < $ip_idx and $bt_idx < $u_idx)
' "$CFG/config.json" >/dev/null

generate_singbox_config >/dev/null 2>&1
check 'H-3 singbox.json created with 0600 permissions' test "$(mode_of "$CFG/singbox.json")" = "600"
check 'C-2 sing-box orders sniff -> private-IP block(::1/128) -> BT block -> auth_user -> global' jq -e '
    .route.rules as $r |
    $r[0].action == "sniff" and
    $r[1].outbound == "block" and (($r[1].ip_cidr // []) | index("::1/128") != null and index("127.0.0.0/8") != null and index("100.64.0.0/10") != null) and
    $r[2].outbound == "block" and ($r[2].protocol // []) == ["bittorrent"] and
    ($r | map((.auth_user // []) | index("alice") != null) | index(true)) > 2 and
    ($r | map((.outbound == "direct") and ((.ip_cidr // []) | index("127.0.0.0/8") != null)) | any | not)
' "$CFG/singbox.json" >/dev/null

printf '\n########## 3. H-1 & H-2 Empty users:[] Fail-Closed & Stale Sing-box Revocation ##########\n'
cat > "$DB_FILE" <<'JSON'
{
  "xray": {
    "vless": {"port": 31001, "uuid": "top-vless", "sni": "example.com", "short_id": "0123456789abcdef", "private_key": "p", "public_key": "k", "users": []},
    "vmess-ws": {"port": 31002, "uuid": "top-vmess", "sni": "example.com", "path": "/vm", "users": []},
    "trojan": {"port": 31003, "password": "top-trojan", "sni": "example.com", "users": []},
    "socks": {"port": 31004, "username": "top-u", "password": "top-p", "auth_mode": "password", "users": []},
    "ss-legacy": {"port": 31005, "method": "aes-256-gcm", "password": "top-ss", "users": []}
  },
  "singbox": {
    "anytls": {"port": 31006, "password": "top-anytls", "sni": "example.com", "users": []}
  }
}
JSON
check 'H-2 vless explicit empty users:[] returns []' test "$(gen_xray_vless_clients vless '' 31001)" = "[]"
check 'H-2 vmess-ws explicit empty users:[] returns []' test "$(gen_xray_vmess_clients vmess-ws 31002)" = "[]"
check 'H-2 trojan explicit empty users:[] returns []' test "$(gen_xray_trojan_clients trojan 31003)" = "[]"
check 'H-2 socks explicit empty users:[] returns []' test "$(gen_xray_socks_accounts socks 31004)" = "[]"
check 'H-2 ss-legacy explicit empty users:[] returns []' test "$(gen_xray_ss_legacy_clients ss-legacy 31005)" = "[]"

printf '{"stale":true}\n' > "$CFG/singbox.json"
svc_stopped=0
svc() {
    case "$1:$2" in
        status:vless-singbox) return 0 ;;
        stop:vless-singbox) svc_stopped=1; return 0 ;;
        *) return 0 ;;
    esac
}
rebuild_and_reload_singbox "silent"
check 'H-1 rebuild_and_reload_singbox removes stale singbox.json on 0 active users' test ! -e "$CFG/singbox.json"
check 'H-1 rebuild_and_reload_singbox stops running vless-singbox on 0 active users' test "$svc_stopped" = "1"

printf '\n########## 4. H-4 / H-9 / H-10 / M-5 Hardening Checks ##########\n'
check 'H-4 VERSION_CACHE_DIR is isolated under $CFG/cache' test "$VERSION_CACHE_DIR" = "$CFG/cache"
_init_version_cache
check 'H-4 cache directory created with 0700 permissions' test "$(mode_of "$VERSION_CACHE_DIR")" = "700"
check 'H-4 _install_binary rejects .. path traversal version' bash -c '
    export VLESS_SOURCE_ONLY=1 VLESS_TEST_CFG="'"$TMP"'/cfg"
    source "'"$PRODUCT"'"
    _err() { :; }
    ! _install_binary "nonexistent-bin-xyz" "org/repo" "https://example.invalid/\$version" "true" "stable" "true" "../1.0.0"
'

# H-9 self-signed cert with CN=R3 must NOT pass _is_real_cert
mkdir -p "$CFG/certs"
openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
    -keyout "$CFG/certs/server.key" -out "$CFG/certs/server.crt" \
    -subj "/CN=R3" -days 1 >/dev/null 2>&1
check 'H-9 _is_real_cert rejects self-signed certificate spoofed with CN=R3' bash -c '
    export VLESS_SOURCE_ONLY=1 VLESS_TEST_CFG="'"$TMP"'/cfg"
    source "'"$PRODUCT"'"
    ! _is_real_cert
'

# H-10 YAML injection sanitizer (superseded by _yaml_quote strict YAML 1.2 JSON encoding)
clean_scalar=$(_yaml_quote $'evil\n  external-controller: 0.0.0.0:9090"')
check 'H-10 _yaml_quote encodes newlines without raw line break' test "${clean_scalar#*$'\n'}" = "$clean_scalar"
check 'H-10 _yaml_quote escapes quotes' grep -Fq '\"' <<< "$clean_scalar"

# M-5 IPv6-only share link generation
cat > "$DB_FILE" <<'JSON'
{"xray":{"vless":{"port":443,"uuid":"11111111-1111-4111-8111-000000000001","sni":"example.com","short_id":"abcd","private_key":"p","public_key":"pub"}},"singbox":{}}
JSON
get_ipv4() { :; }
get_ipv6() { printf '2001:db8::1\n'; }
get_ip_country() { printf 'ZZ\n'; }
v6_link=$(_gen_user_share_link xray vless "11111111-1111-4111-8111-000000000001" default 443)
check 'M-5 _gen_user_share_link supports IPv6-only servers' grep -Fq '@[2001:db8::1]:443' <<< "$v6_link"

printf '\n'
if [[ "$fail" -eq 0 ]]; then
    printf 'PASS: H15 security & reliability hardening suite (%d assertions)\n' "$pass"
else
    printf 'FAIL: H15 security & reliability hardening suite (%d failed, %d passed)\n' "$fail" "$pass" >&2
    exit 1
fi
