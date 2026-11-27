#!/usr/bin/env bash
# tests/test-h19-self-audit.sh — Class-wide self-audit remediation (SA-01..SA-07) & mutation tests
set -uo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_DIR/vless-server.sh"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  [PASS] $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  [FAIL] $1" >&2; }

check() {
    local label="$1"; shift
    if "$@"; then pass "$label"; else fail "$label"; fi
}

eq() { [[ "$1" == "$2" ]]; }
has_substr() { [[ "$1" == *"$2"* ]]; }
no_substr() { [[ "$1" != *"$2"* ]]; }

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/aio-h19-sa.XXXXXX")"
trap 'rm -rf -- "$TEST_ROOT"' EXIT INT TERM

fresh_env() {
    local name="$1"
    export VLESS_SOURCE_ONLY=1
    export VLESS_TEST_CFG="$TEST_ROOT/$name/cfg"
    export VLESS_TEST_LOG_ROOT="$TEST_ROOT/$name/log"
    mkdir -p "$VLESS_TEST_CFG" "$VLESS_TEST_LOG_ROOT"
    # shellcheck source=/dev/null
    source "$SCRIPT"
}

echo "=== SA-00: Static Structural Invariants Gate ==="
check "SA-00 scripts/check-static-invariants.py passes" python3 "$REPO_DIR/scripts/check-static-invariants.py"

echo "=== SA-01: watchdog.sh paused/F04 guards & aligned Alpine gcompat _pgrep ==="
(
    fresh_env sa01
    cat > "$DB_FILE" <<'JSON'
{
  "version": "4.0.0",
  "xray": {"vless-ws": {"port": 18443, "uuid": "11111111-1111-4111-8111-111111111111", "sni": "a.test", "path": "/ws"}},
  "singbox": {"anytls": {"port": 24443, "password": "pw", "sni": "a.test"}},
  "meta": {}
}
JSON
    create_server_scripts
    check "SA-01a generated watchdog.sh passes bash -n" bash -n "$CFG/watchdog.sh"

    # Build isolated mock bin for watchdog_cycle runtime tests
    mbin="$TEST_ROOT/sa01/bin"
    mkdir -p "$mbin"
    log_calls="$TEST_ROOT/sa01/restarts.log"
    cat > "$mbin/systemctl" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$log_calls"
exit 0
EOF
    cat > "$mbin/pgrep" <<'EOF'
#!/usr/bin/env bash
# Simulate all processes stopped
exit 1
EOF
    chmod +x "$mbin/systemctl" "$mbin/pgrep"

    # Case 1: paused -> must NOT restart anything
    : > "$log_calls"
    touch "$CFG/paused"
    env PATH="$mbin:$PATH" CFG="$CFG" LOG_FILE="$TEST_ROOT/sa01/wd.log" VLESS_WATCHDOG_ONCE=1 WATCHDOG_POST_RESTART_SLEEP=0 \
        bash "$CFG/watchdog.sh"
    check "SA-01b watchdog skips all restarts when paused" eq "$(wc -l < "$log_calls" | tr -d ' ')" "0"

    # Case 2: not paused, .singbox-stopped-empty set -> restarts vless-reality ONLY, skips vless-singbox
    rm -f "$CFG/paused"
    : > "$log_calls"
    touch "$CFG/.singbox-stopped-empty"
    env PATH="$mbin:$PATH" CFG="$CFG" LOG_FILE="$TEST_ROOT/sa01/wd.log" VLESS_WATCHDOG_ONCE=1 WATCHDOG_POST_RESTART_SLEEP=0 \
        bash "$CFG/watchdog.sh"
    calls=$(cat "$log_calls")
    check "SA-01c watchdog restarts crashed vless-reality when not paused" has_substr "$calls" "restart vless-reality"
    check "SA-01d watchdog skips vless-singbox when .singbox-stopped-empty exists (F04)" no_substr "$calls" "vless-singbox"

    # Case 3: Anti-false-green mutation — removing .singbox-stopped-empty causes restart of vless-singbox
    : > "$log_calls"
    rm -f "$CFG/.singbox-stopped-empty"
    env PATH="$mbin:$PATH" CFG="$CFG" LOG_FILE="$TEST_ROOT/sa01/wd.log" VLESS_WATCHDOG_ONCE=1 WATCHDOG_POST_RESTART_SLEEP=0 \
        bash "$CFG/watchdog.sh"
    calls=$(cat "$log_calls")
    check "SA-01e mutation: without .singbox-stopped-empty watchdog restarts vless-singbox" has_substr "$calls" "restart vless-singbox"

    # Case 4: watchdog embedded _pgrep matches Alpine gcompat and rejects timeout wrapper
    wd_pgrep_body=$(awk '/^_pgrep\(\)/,/^}/' "$CFG/watchdog.sh")
    check "SA-01f watchdog _pgrep contains gcompat ld-(linux|musl) pattern" has_substr "$wd_pgrep_body" 'ld-(linux|musl)'
    check "SA-01g watchdog _pgrep anchors pattern with ^" has_substr "$wd_pgrep_body" '^((/usr/local/s?bin/|/usr/s?bin/)?'

    printf '%d %d\n' "$PASS" "$FAIL" > "$TEST_ROOT/sa01.rc"
)
read -r p f < "$TEST_ROOT/sa01.rc"; PASS=$p; FAIL=$f

echo "=== SA-02: configure_direct_outbound & setup_warp_ipv6_chain delegate to _regenerate_proxy_configs ==="
(
    fresh_env sa02
    cdo_body=$(awk '/^configure_direct_outbound\(\)/,/^}/' "$SCRIPT")
    swc_body=$(awk '/^setup_warp_ipv6_chain\(\)/,/^}/' "$SCRIPT")
    check "SA-02a configure_direct_outbound calls _regenerate_proxy_configs" has_substr "$cdo_body" "_regenerate_proxy_configs"
    check "SA-02b configure_direct_outbound has no hand-rolled svc stop vless-singbox" no_substr "$cdo_body" "svc stop vless-singbox"
    check "SA-02c setup_warp_ipv6_chain calls _regenerate_proxy_configs" has_substr "$swc_body" "_regenerate_proxy_configs"
    check "SA-02d setup_warp_ipv6_chain has no hand-rolled svc start vless-singbox" no_substr "$swc_body" "svc start vless-singbox"

    # Runtime check: configure_direct_outbound while paused must not start/restart any core
    cat > "$DB_FILE" <<'JSON'
{
  "version": "4.0.0",
  "xray": {"vless-ws": {"port": 18443, "uuid": "11111111-1111-4111-8111-111111111111", "sni": "a.test", "path": "/ws"}},
  "singbox": {"anytls": {"port": 24443, "password": "pw", "sni": "a.test"}},
  "meta": {}
}
JSON
    touch "$CFG/paused"
    svc_log="$TEST_ROOT/sa02/svc.log"
    : > "$svc_log"
    svc() { echo "$*" >> "$svc_log"; return 1; }
    generate_xray_config() { return 0; }
    generate_singbox_config() { return 0; }
    _header() { :; }; _line() { :; }
    configure_direct_outbound <<< $'1\n' >/dev/null 2>&1
    check "SA-02e configure_direct_outbound saved direct_ip_version=ipv4_only" eq "$(cat "$CFG/direct_ip_version")" "ipv4_only"
    check "SA-02f configure_direct_outbound did not start/restart paused cores" no_substr "$(cat "$svc_log")" "restart"
    check "SA-02g configure_direct_outbound did not start paused cores" no_substr "$(cat "$svc_log")" "start"

    printf '%d %d\n' "$PASS" "$FAIL" > "$TEST_ROOT/sa02.rc"
)
read -r p f < "$TEST_ROOT/sa02.rc"; PASS=$p; FAIL=$f

echo "=== SA-03: Pure-AWK Gregorian date helpers (Alpine BusyBox date parity) ==="
(
    fresh_env sa03
    # Shim `date` to reject GNU -d and BSD -v/-j (emulating Alpine BusyBox date)
    bb_bin="$TEST_ROOT/sa03/bb_bin"
    mkdir -p "$bb_bin"
    cat > "$bb_bin/date" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
    case "$a" in
        -d|-v*|-j|-f) echo "busybox-shim: unsupported flag $a" >&2; exit 1 ;;
    esac
done
if [[ "$*" == "+%Y-%m-%d" ]]; then
    echo "2026-12-20"
    exit 0
fi
exec /bin/date "$@"
EOF
    chmod +x "$bb_bin/date"
    export PATH="$bb_bin:$PATH"

    check "SA-03a _valid_ymd accepts leap day 2024-02-29 without date -d" _valid_ymd "2024-02-29"
    check "SA-03b _valid_ymd rejects non-leap 2026-02-29 without date -d" bash -c 'export VLESS_SOURCE_ONLY=1; source "$1"; ! _valid_ymd "2026-02-29"' _ "$SCRIPT"
    check "SA-03c _valid_ymd rejects 2026-02-30 without date -d" bash -c 'export VLESS_SOURCE_ONLY=1; source "$1"; ! _valid_ymd "2026-02-30"' _ "$SCRIPT"
    check "SA-03d _date_add_days_ymd crosses year boundary (+30 from 2026-12-20 -> 2027-01-19)" eq "$(_date_add_days_ymd 30)" "2027-01-19"
    check "SA-03e _date_add_days_ymd supports negative offset (-5 from 2026-12-20 -> 2026-12-15)" eq "$(_date_add_days_ymd -5)" "2026-12-15"
    check "SA-03f _date_add_days_ymd handles leap year (+1 from 2024-02-28 -> 2024-02-29)" eq "$(_date_add_days_ymd 1 2024-02-28)" "2024-02-29"
    check "SA-03g _date_add_days_ymd handles zero-padded offset (08 -> 2026-12-28)" eq "$(_date_add_days_ymd 08)" "2026-12-28"

    cat > "$DB_FILE" <<'JSON'
{
  "version": "4.0.0",
  "xray": {"vless-ws": {"port": 18443, "users": [
    {"name": "future", "uuid": "11111111-1111-4111-8111-111111111111", "enabled": true, "expire_date": "2027-01-19"},
    {"name": "past", "uuid": "22222222-2222-4222-8222-222222222222", "enabled": true, "expire_date": "2026-12-15"}
  ]}},
  "singbox": {},
  "meta": {}
}
JSON
    check "SA-03h db_get_user_days_left returns +30 under BusyBox date shim" eq "$(db_get_user_days_left xray vless-ws future)" "30"
    check "SA-03i db_get_user_days_left returns -5 under BusyBox date shim" eq "$(db_get_user_days_left xray vless-ws past)" "-5"

    printf '%d %d\n' "$PASS" "$FAIL" > "$TEST_ROOT/sa03.rc"
)
read -r p f < "$TEST_ROOT/sa03.rc"; PASS=$p; FAIL=$f

echo "=== SA-04: parse_subscription curl -K - & parse_proxy_link host/port/SS hardening ==="
(
    fresh_env sa04
    cbin="$TEST_ROOT/sa04/cbin"
    mkdir -p "$cbin"
    argv_log="$TEST_ROOT/sa04/curl_argv.log"
    stdin_log="$TEST_ROOT/sa04/curl_stdin.log"
    cat > "$cbin/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$argv_log"
cat > "$stdin_log"
printf 'vless://11111111-1111-4111-8111-111111111111@node.example.com:443?security=tls&sni=node.example.com#oknode\n'
EOF
    chmod +x "$cbin/curl"

    secret_url="https://sub.example.com/api?token=SUPER_SECRET_SA04"
    out=$(PATH="$cbin:$PATH" parse_subscription "$secret_url" 2>/dev/null)
    check "SA-04a parse_subscription parsed valid node" has_substr "$out" '"server":"node.example.com"'
    check "SA-04b parse_subscription did NOT pass secret URL on curl argv" no_substr "$(cat "$argv_log")" "SUPER_SECRET_SA04"
    check "SA-04c parse_subscription passed -K - on curl argv" has_substr "$(cat "$argv_log")" "-K -"
    check "SA-04d parse_subscription passed URL via stdin config" has_substr "$(cat "$stdin_log")" "SUPER_SECRET_SA04"

    rc_bad_proto=0
    parse_subscription "file:///etc/passwd" >/dev/null 2>&1 || rc_bad_proto=$?
    check "SA-04e parse_subscription rejects non-http(s) scheme" eq "$rc_bad_proto" "1"

    rc_p0=0; parse_proxy_link "vless://11111111-1111-4111-8111-111111111111@ok.example.com:0#bad" >/dev/null 2>&1 || rc_p0=$?
    rc_p70k=0; parse_proxy_link "vless://11111111-1111-4111-8111-111111111111@ok.example.com:70000#bad" >/dev/null 2>&1 || rc_p70k=$?
    rc_bad_host=0; parse_proxy_link "trojan://pw@evil.com/path:443#bad" >/dev/null 2>&1 || rc_bad_host=$?
    check "SA-04f parse_proxy_link rejects port 0" eq "$rc_p0" "1"
    check "SA-04g parse_proxy_link rejects port 70000" eq "$rc_p70k" "1"
    check "SA-04h parse_proxy_link rejects invalid server with '/'" eq "$rc_bad_host" "1"

    # Legacy ss:// with colon inside password
    ss_b64=$(printf 'aes-256-gcm:pa:ss:word@ss.example.com:8388' | base64 | tr -d '\n')
    ss_out=$(parse_proxy_link "ss://${ss_b64}#ss-colon")
    check "SA-04i parse_proxy_link legacy ss:// preserves password containing colons" eq "$(jq -r '.password' <<< "$ss_out")" "pa:ss:word"

    hy2_out=$(parse_proxy_link "hy2://pw@hy2.example.com:443?allowInsecure=1&sni=hy2.example.com#h")
    check "SA-04j parse_proxy_link hy2:// honors allowInsecure=1" eq "$(jq -r '.insecure' <<< "$hy2_out")" "1"

    printf '%d %d\n' "$PASS" "$FAIL" > "$TEST_ROOT/sa04.rc"
)
read -r p f < "$TEST_ROOT/sa04.rc"; PASS=$p; FAIL=$f

echo "=== SA-05: OpenRC shadow-tls env_file ordering & zero shell-eval injection ==="
(
    fresh_env sa05
    # Extract _write_openrc from create_service and evaluate its generated script in /bin/sh
    openrc_fn=$(awk '/_write_openrc\(\) \{/,/^    \}/' "$SCRIPT")
    env_f="$TEST_ROOT/sa05/stls.env"
    pwn_marker="$TEST_ROOT/sa05/pwned"
    # Deliberately include shell substitution payload in password to prove sed avoids `.` code execution
    pw_payload='pw$(touch '"$pwn_marker"')_ok'
    printf 'STLS_PASSWORD=%s\n' "$pw_payload" > "$env_f"
    init_dir="$TEST_ROOT/sa05/init.d"
    mkdir -p "$init_dir"
    # Load the exact template helper redirected to a temp dir (avoid eval)
    tmpl_file="$TEST_ROOT/sa05/write_openrc.sh"
    printf '%s\n' "$openrc_fn" | sed "s|/etc/init.d/|${init_dir}/|g" > "$tmpl_file"
    # shellcheck source=/dev/null
    source "$tmpl_file"
    _write_openrc "vless-stls-test" "Proxy Server (ss2022-shadowtls)" "/usr/local/bin/shadow-tls" \
        '--v3 server --listen 0.0.0.0:443 --server 127.0.0.1:10443 --tls example.com:443 --password ${STLS_PASSWORD}' \
        "MONOIO_FORCE_LEGACY_DRIVER=1" "$env_f"
    gen_file="$init_dir/vless-stls-test"
    check "SA-05a generated OpenRC shadow-tls script passes POSIX sh -n" sh -n "$gen_file"
    expanded=$(sh -c '. "$1"; printf "%s" "$command_args"' _ "$gen_file")
    check "SA-05b OpenRC command_args received non-empty STLS_PASSWORD before evaluation" has_substr "$expanded" "--password $pw_payload"
    check "SA-05c OpenRC env_file loading did NOT execute embedded command substitution" test ! -e "$pwn_marker"

    printf '%d %d\n' "$PASS" "$FAIL" > "$TEST_ROOT/sa05.rc"
)
read -r p f < "$TEST_ROOT/sa05.rc"; PASS=$p; FAIL=$f

echo "=== SA-06: Tunnel config sync & add_protocol_to_tunnel respect paused/stopped state ==="
(
    export VLESS_TEST_CLOUDFLARED_DIR="$TEST_ROOT/sa06/cf"
    fresh_env sa06
    mkdir -p "$CLOUDFLARED_DIR"
    printf 'protocol=vless-ws\n' > "$CLOUDFLARED_DIR/tunnel.info"
    printf 'ingress:\n  - service: http://localhost:18443\n' > "$CLOUDFLARED_CONFIG"
    printf '{"inbounds":[{"streamSettings":{"wsSettings":{"headers":{"Host":"old.test"}}}}]}\n' > "$CFG/config.json"
    touch "$CFG/paused"
    svc_log="$TEST_ROOT/sa06/svc.log"
    : > "$svc_log"
    svc() { echo "$*" >> "$svc_log"; return 1; }
    _sync_tunnel_config
    check "SA-06a _sync_tunnel_config updated Host header" has_substr "$(cat "$CFG/config.json")" '"Host": ""'
    check "SA-06b _sync_tunnel_config did NOT restart paused vless-reality" no_substr "$(cat "$svc_log")" "restart vless-reality"

    printf '%d %d\n' "$PASS" "$FAIL" > "$TEST_ROOT/sa06.rc"
)
read -r p f < "$TEST_ROOT/sa06.rc"; PASS=$p; FAIL=$f

echo "=== SA-07: State-mutating functions return 0 on valid no-op/clear branches ==="
(
    fresh_env sa07
    cat > "$DB_FILE" <<'JSON'
{
  "version": "4.0.0",
  "xray": {"vless-ws": {"port": 18443, "users": [{"name": "alice", "uuid": "11111111-1111-4111-8111-111111111111", "enabled": true, "expire_date": "2027-01-01"}]}},
  "singbox": {},
  "chain_proxy": {"active": "keep", "nodes": [{"name": "keep"}, {"name": "drop"}]},
  "meta": {}
}
JSON
    ensure_expire_check_cron() { return 0; }
    check "SA-07a db_set_user_expire_date clearing expiry ('') returns 0" db_set_user_expire_date xray vless-ws alice ""
    check "SA-07b db_set_user_expire_date clearing expiry ('never') returns 0" db_set_user_expire_date xray vless-ws alice "never"
    check "SA-07c db_migrate_to_multiuser no-op returns 0" db_migrate_to_multiuser
    check "SA-07d db_del_chain_node deleting non-active node returns 0" db_del_chain_node "drop"
    check "SA-07e db_del_chain_node preserved active node" eq "$(jq -r '.chain_proxy.active' "$DB_FILE")" "keep"
    EXTERNAL_SUBS_FILE="$CFG/external_subs.txt"
    : > "$EXTERNAL_SUBS_FILE"
    rm -f "$CFG/sub.info"
    check "SA-07f refresh_external_subs without sub.info returns 0" refresh_external_subs

    printf '%d %d\n' "$PASS" "$FAIL" > "$TEST_ROOT/sa07.rc"
)
read -r p f < "$TEST_ROOT/sa07.rc"; PASS=$p; FAIL=$f

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
((FAIL == 0))
