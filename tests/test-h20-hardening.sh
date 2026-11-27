#!/usr/bin/env bash
# H20 全面安全加固、深模块收敛、对抗复审闭环回归套件（SEC-1..SEC-4, SA-08..SA-15, STYLE-1..2, REL-2, ADV-1..9）
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PRODUCT="$ROOT/vless-server.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/aio-h20-hardening.XXXXXX")
trap 'rm -rf -- "$TMP"' EXIT

RESULTS="$TMP/results"
: >"$RESULTS"

check() {
    local name="$1"; shift
    if "$@"; then
        echo "OK   $name" | tee -a "$RESULTS"
    else
        echo "FAIL $name" | tee -a "$RESULTS" >&2
    fi
}
eq() { [[ "$1" == "$2" ]]; }
has_substr() { [[ "$1" == *"$2"* ]]; }
no_substr() { [[ "$1" != *"$2"* ]]; }
not_ok() {
    local _rc=0
    "$@" && return 1 || _rc=$?
    [[ "$_rc" -ne 127 && "$_rc" -ne 126 ]]
}

fresh_env() {
    SEC="$TMP/$1"
    mkdir -p "$SEC/cfg"
    export VLESS_SOURCE_ONLY=1
    export VLESS_TEST_CFG="$SEC/cfg"
    # shellcheck disable=SC1090
    source "$PRODUCT"
    set +u
    DISTRO="debian"
    _ok() { :; }; _info() { :; }; _warn() { echo "WARN: $*" >&2; }; _err() { echo "ERR: $*" >&2; }
}

write_db() {
    mkdir -p "$CFG"
    cat >"$DB_FILE"
    chmod 600 "$DB_FILE"
}

# 1. SEC-1, SEC-3, SEC-4: Zero eval, zero untrusted wgcf mirrors, _install_binary whitelist extract, ELF check, _save_join_info argc
sec_sec1_sec3_eval_and_downloads() ( fresh_env sec1_sec3
    rc=0
    _install_binary_extract "touch $SEC/pwned" "$SEC" 2>/dev/null || rc=$?
    check 'SEC-3a _install_binary_extract rejects unknown/arbitrary command strings (fail-closed)' \
        bash -c '[[ "$1" -ne 0 && ! -e "$2/pwned" ]]' _ "$rc" "$SEC"
    check 'SEC-3b _install_binary_extract accepts noop/true for tests' \
        _install_binary_extract "noop" "$SEC"

    wgcf_body=$(declare -f download_wgcf)
    check 'SEC-1a download_wgcf exists and contains zero third-party proxy domains' \
        bash -c '[[ -n "$1" ]] && ! grep -Eq "gh-proxy\.com|ghps\.cc|gh\.ddlc\.top|ghproxy\.net" <<<"$1"' _ "$wgcf_body"
    check 'SEC-1b download_wgcf delegates to _install_binary with official ViRb3/wgcf' \
        bash -c 'grep -Fq "_install_binary \"wgcf\" \"ViRb3/wgcf\"" <<<"$1"' _ "$wgcf_body"

    printf '\177ELF\002\001' >"$SEC/ok.elf"
    printf '#!/bin/sh\necho hi\n' >"$SEC/bad.sh"
    check 'SEC-4a _is_elf_binary accepts ELF magic' _is_elf_binary "$SEC/ok.elf"
    check 'SEC-4a _is_elf_binary rejects plain text/shell script' not_ok _is_elf_binary "$SEC/bad.sh"

    naive_body=$(declare -f install_naive)
    check 'SEC-4b install_naive exists and never executes unverified downloaded binary' \
        bash -c '[[ -n "$1" ]] && ! grep -Fq "\"\$caddy_bin\" version" <<<"$1"' _ "$naive_body"

    # ADV-6: _save_join_info explicit link_argc avoids "--" delimiter collision & "%s" collision on Naive credentials
    get_ipv4() { echo 203.0.113.9; }; get_ipv6() { echo ""; }
    SJI_LOG="$SEC/sji.args"
    gen_naive_link() { printf '%s\n' "$@" >"$SJI_LOG"; echo "https://stub"; }
    _save_join_info "naive" "NAIVE|d.example|443|%s|--" gen_naive_link 4 "d.example" "443" "%s" "--" "# extra-line"
    check 'ADV-6 _save_join_info preserves literal %s and -- in Naive credentials and keeps extra_lines separate' \
        bash -c '[[ "$(sed -n 1p "$1")" == "d.example" && "$(sed -n 3p "$1")" == "%s" && "$(sed -n 4p "$1")" == "--" && "$(wc -l <"$1" | tr -d " ")" -eq 4 ]] && grep -Fq "# extra-line" "$2"' _ "$SJI_LOG" "$CFG/naive.join"
)

# 2. SEC-2 & SA-12 & ADV-3/7/9: Unified _http_fetch_sub_raw (chunked cap), _urldecode (+ & %0a), parsers, Clash YAML, IPv6, SS @, date bounds
sec_sec2_sa12_parsers_and_date() ( fresh_env sec2_sa12
    ARGV_F="$SEC/curl.argv"
    curl() { printf '%s\n' "$@" >"$ARGV_F"; printf 'vless://11111111-1111-4111-8111-111111111111@198.51.100.10:443?security=tls&type=tcp#N\n'; }
    check 'SEC-2a _http_fetch_sub_raw rejects URL containing whitespace' \
        not_ok _http_fetch_sub_raw "https://sub.example/a b"
    parse_subscription "https://sub.example/sub?token=TOPSECRET99" >/dev/null 2>&1
    check 'SEC-2b parse_subscription passes --proto-redir =http,https and --max-filesize 2097152 and hides token from argv' \
        bash -c 'grep -Fq -- "--proto-redir" "$1" && grep -Fq -- "=http,https" "$1" && grep -Fq -- "2097152" "$1" && ! grep -Fq "TOPSECRET99" "$1"' _ "$ARGV_F"

    # ADV-9 & C20-6: chunked / no-Content-Length > 2 MiB stream is capped early by head -c (never drains full upstream)
    big_rc=0
    rm -f -- "$SEC/drained_4m"
    (
        curl() {
            local i
            for i in $(seq 1 64); do
                head -c 65536 /dev/zero 2>/dev/null | tr '\0' 'A' || exit 0
            done
            : >"$SEC/drained_4m"
        }
        _http_fetch_sub_raw "https://sub.example/chunked" >/dev/null 2>&1
    ) || big_rc=$?
    check 'ADV-9 _http_fetch_sub_raw caps and rejects >2MiB stream early without draining full upstream' \
        bash -c '[[ "$1" -ne 0 && "$1" -ne 127 && ! -e "$2/drained_4m" ]]' _ "$big_rc" "$SEC"

    # ADV-3 & D20-3: _urldecode preserves literal '+' (RFC 3986), rejects trailing %0a / %00 / bare '%' / '%_%0a', single-pass %25
    check 'ADV-3a _urldecode preserves literal + in passwords/paths' eq "$(_urldecode 'ab+cd/ef%20g')" "ab+cd/ef g"
    check 'ADV-3b _urldecode rejects trailing %0a before command substitution can strip it' not_ok _urldecode 'pw%0a'
    check 'ADV-3c _urldecode rejects %00 NUL byte' not_ok _urldecode 'pw%00x'
    check 'D20-3a _urldecode rejects trailing bare % (fail-closed)' not_ok _urldecode 'pw%'
    check 'D20-3b _urldecode rejects truncated %4 (fail-closed)' not_ok _urldecode 'pw%4'
    check 'D20-3c _urldecode rejects malformed %%41 (fail-closed)' not_ok _urldecode '%%41'
    check 'D20-3d _urldecode rejects %_%0a (no loop short-circuit bypass)' not_ok _urldecode 'pw%_%0a'
    check 'D20-3e _urldecode decodes %25 single-pass without double-decoding %250a' \
        bash -c '[[ "$1" == "100% ok" && "$2" == "%0a" ]]' _ "$(_urldecode '100%25%20ok')" "$(_urldecode '%250a')"
    plus_json=$(parse_proxy_link "trojan://ab+cd@198.51.100.11:443#n+1")
    check 'ADV-3d parse_proxy_link preserves literal + in trojan password and name' \
        bash -c '[[ "$(jq -r .password <<<"$1")" == "ab+cd" && "$(jq -r .name <<<"$1")" == "n+1" ]]' _ "$plus_json"
    check 'ADV-3e parse_proxy_link rejects trailing %0a in trojan password' \
        not_ok parse_proxy_link "trojan://pw%0a@198.51.100.11:443#n"
    check 'D20-3f parse_proxy_link rejects malformed %_%0a in trojan password' \
        not_ok parse_proxy_link "trojan://pw%_%0a@198.51.100.11:443#n"

    # SEC-2c..g & ADV-7: missing @ and @ only in query string
    check 'SEC-2c parse_proxy_link rejects vless without @' not_ok parse_proxy_link "vless://example.com:443?security=tls#bad"
    check 'SEC-2d parse_proxy_link rejects trojan without @' not_ok parse_proxy_link "trojan://example.com:443#bad"
    check 'SEC-2e parse_proxy_link rejects hy2 without @' not_ok parse_proxy_link "hy2://example.com:443#bad"
    check 'ADV-7a parse_proxy_link rejects vless with @ only in query string' \
        not_ok parse_proxy_link "vless://example.com:443?x=@198.51.100.1:443#bad"
    check 'ADV-7b parse_vless_link rejects vless with @ only in query string' \
        not_ok parse_vless_link "vless://example.com:443?x=@198.51.100.1:443#bad"
    check 'SEC-2f parse_proxy_link rejects %00 NUL byte in password' not_ok parse_proxy_link "trojan://pw%00x@198.51.100.11:443#n"
    check 'SEC-2g parse_proxy_link rejects encoded LF (%0a) in password' not_ok parse_proxy_link "trojan://pw%0ax@198.51.100.11:443#n"

    # SA-12a & D20-1: Clash YAML single & multi-element block/flow alpn sequences round-trip losslessly to Clash & Surge
    clash_yaml=$(cat <<'YAML'
proxies:
  - name: TuicBlockAlpn
    type: tuic
    server: tuic.example.com
    port: 443
    uuid: 11111111-1111-4111-8111-111111111111
    password: secret
    alpn:
      - h3
    sni: tuic.example.com
    skip-cert-verify: true
YAML
)
    clash_out=$(_parse_clash_yaml_proxies "$clash_yaml")
    check 'SA-12a Clash YAML block sequence alpn keeps single node with sni & allow_insecure=1 & alpn=h3' \
        bash -c '[[ "$(printf "%s\n" "$1" | grep -c "^tuic://")" -eq 1 ]] && grep -Fq "sni=tuic.example.com" <<<"$1" && grep -Fq "allow_insecure=1" <<<"$1" && grep -Fq "alpn=h3" <<<"$1"' _ "$clash_out"

    clash_multi_block=$(cat <<'YAML'
proxies:
  - name: TuicMultiBlock
    type: tuic
    server: tuic2.example.com
    port: 443
    uuid: 11111111-1111-4111-8111-111111111111
    password: secret
    alpn:
      - h3
      - http/1.1
    sni: tuic2.example.com
    skip-cert-verify: false
YAML
)
    clash_multi_flow=$(cat <<'YAML'
proxies:
  - name: TuicMultiFlow
    type: tuic
    server: tuic3.example.com
    port: 443
    uuid: 11111111-1111-4111-8111-111111111111
    password: secret
    alpn: [h3, "http/1.1"]
    sni: tuic3.example.com
YAML
)
    mb_link=$(_parse_clash_yaml_proxies "$clash_multi_block")
    mf_link=$(_parse_clash_yaml_proxies "$clash_multi_flow")
    mb_json=$(parse_share_link "$mb_link")
    mf_json=$(parse_share_link "$mf_link")
    mb_clash=$(external_link_to_clash "$mb_link")
    mb_surge=$(external_link_to_surge "$mb_link")
    check 'D20-1a Clash YAML multi-element block alpn preserves h3,http/1.1 losslessly' \
        eq "$(jq -r '.alpn' <<<"$mb_json")" "h3,http/1.1"
    check 'D20-1b Clash YAML multi-element flow alpn preserves h3,http/1.1 losslessly' \
        eq "$(jq -r '.alpn' <<<"$mf_json")" "h3,http/1.1"
    check 'D20-1c external_link_to_clash exports multi-alpn as valid 2-element YAML array ["h3", "http/1.1"]' \
        grep -Fq 'alpn: ["h3", "http/1.1"]' <<<"$mb_clash"
    check 'D20-1d external_link_to_surge accepts multi-alpn TUIC node using primary alpn=h3' \
        bash -c '[[ -n "$1" ]] && grep -Fq "alpn=h3" <<<"$1" && ! grep -Fq "alpn=h3," <<<"$1"' _ "$mb_surge"

    # SA-12b & ADV-7: _valid_sub_server, _clash_emit_proxy_link, and all sibling parsers normalize [2001:db8::1]
    check 'SA-12b _valid_sub_server accepts bracketed IPv6 [2001:db8::1]' _valid_sub_server "[2001:db8::1]"
    check 'SA-12b _valid_sub_server rejects bogus bracketed non-IPv6 [evil.com]' not_ok _valid_sub_server "[evil.com]"
    check 'ADV-7c _clash_emit_proxy_link rejects bracketed non-IPv6 [1.2.3.4]' \
        not_ok _clash_emit_proxy_link "bad" "trojan" "[1.2.3.4]" "443" "" "pw" "" "tcp" "true" "" "" "" "" "" "" "false" "" "" "" "" ""
    vm_b64=$(printf '{"ps":"v6","add":"[2001:db8::1]","port":443,"id":"11111111-1111-4111-8111-111111111111","aid":0,"net":"tcp"}' | base64 -w 0)
    vm_json=$(parse_vmess_link "vmess://$vm_b64")
    check 'SA-12b parse_vmess_link normalizes [2001:db8::1] to 2001:db8::1' \
        eq "$(jq -r '.server' <<<"$vm_json")" "2001:db8::1"
    tr_v6=$(parse_trojan_link "trojan://pw@[2001:db8::1]:443#t")
    hy_v6=$(parse_hy2_link "hy2://pw@[2001:db8::1]:443#h")
    an_v6=$(parse_anytls_link "anytls://pw@[2001:db8::1]:443#a")
    check 'ADV-7d parse_{trojan,hy2,anytls}_link normalize bracketed IPv6 to bare 2001:db8::1' \
        bash -c '[[ "$(jq -r .server <<<"$1")" == "2001:db8::1" && "$(jq -r .server <<<"$2")" == "2001:db8::1" && "$(jq -r .server <<<"$3")" == "2001:db8::1" ]]' _ "$tr_v6" "$hy_v6" "$an_v6"

    # SA-12c & D20-6: parse_ss_link / parse_proxy_link legacy & plaintext '@' in password + diagnostic warn on malformed SS userinfo
    ss_b64=$(printf 'aes-256-gcm:p@ss:word@198.51.100.12:8388' | base64 -w 0)
    ss_json=$(parse_ss_link "ss://$ss_b64#SSAt")
    check 'SA-12c parse_ss_link legacy format preserves @ and : in password' \
        bash -c '[[ "$(jq -r .password <<<"$1")" == "p@ss:word" && "$(jq -r .server <<<"$1")" == "198.51.100.12" ]]' _ "$ss_json"
    ss_plain_json=$(parse_proxy_link "ss://aes-256-gcm:p@ss@198.51.100.12:8388#PlainAt")
    ss_plain_json2=$(parse_ss_link "ss://aes-256-gcm:p@ss@198.51.100.12:8388#PlainAt")
    check 'D20-6a parse_proxy_link & parse_ss_link preserve @ in plaintext SS password' \
        bash -c '[[ "$(jq -r .password <<<"$1")" == "p@ss" && "$(jq -r .server <<<"$1")" == "198.51.100.12" && "$(jq -r .password <<<"$2")" == "p@ss" && "$(jq -r .server <<<"$2")" == "198.51.100.12" ]]' _ "$ss_plain_json" "$ss_plain_json2"
    ss_bad_err1="$SEC/ss_bad1.err"; ss_bad_out1=""; ss_bad_rc1=0
    ss_bad_out1=$(parse_proxy_link "ss://notbase64nocolon@198.51.100.12:8388#Bad" 2>"$ss_bad_err1") || ss_bad_rc1=$?
    ss_bad_err2="$SEC/ss_bad2.err"; ss_bad_out2=""; ss_bad_rc2=0
    ss_bad_out2=$(parse_ss_link "ss://notbase64nocolon@198.51.100.12:8388#Bad" 2>"$ss_bad_err2") || ss_bad_rc2=$?
    check 'D20-6b malformed SS userinfo without colon returns 1 with stderr warning and empty stdout in both parsers' \
        bash -c '[[ "$1" -ne 0 && -z "$2" && -s "$3" && "$4" -ne 0 && -z "$5" && -s "$6" ]]' _ \
        "$ss_bad_rc1" "$ss_bad_out1" "$ss_bad_err1" "$ss_bad_rc2" "$ss_bad_out2" "$ss_bad_err2"

    # C20-3: SS base64 password with trailing LF or garbage suffix rejected; Trojan/Hy2 query params URL-decoded symmetrically
    ss_lf_b64=$(printf 'aes-256-gcm:secret\n' | base64 -w 0)
    ss_ok_b64=$(printf 'aes-256-gcm:secret' | base64 -w 0)
    check 'C20-3a parse_proxy_link & parse_ss_link reject base64 userinfo with trailing LF instead of stripping LF' \
        bash -c '! "$1" "ss://${2}@198.51.100.12:8388#LF" >/dev/null 2>&1 && ! "$3" "ss://${2}@198.51.100.12:8388#LF" >/dev/null 2>&1' _ \
        parse_proxy_link "$ss_lf_b64" parse_ss_link
    check 'C20-3b parse_proxy_link & parse_ss_link reject base64 userinfo with garbage suffix' \
        bash -c '! "$1" "ss://${2}!bad@198.51.100.12:8388#Bad" >/dev/null 2>&1 && ! "$3" "ss://${2}!bad@198.51.100.12:8388#Bad" >/dev/null 2>&1' _ \
        parse_proxy_link "$ss_ok_b64" parse_ss_link
    check 'C20-3c parse_proxy_link rejects malformed % in Trojan/Hy2 sni query param' \
        bash -c '! "$1" "trojan://pw@198.51.100.11:443?sni=example%#bad" >/dev/null 2>&1 && ! "$1" "hy2://pw@198.51.100.11:443?sni=example%#bad" >/dev/null 2>&1' _ \
        parse_proxy_link
    tr_dec=$(parse_proxy_link "trojan://pw@198.51.100.11:443?sni=edge%2Eexample.com#ok")
    hy_dec=$(parse_proxy_link "hy2://pw@198.51.100.11:443?sni=edge%2Eexample.com&insecure=1#ok")
    check 'C20-3d parse_proxy_link URL-decodes Trojan & Hy2 sni query param (%2E -> .)' \
        bash -c '[[ "$(jq -r .sni <<<"$1")" == "edge.example.com" && "$(jq -r .sni <<<"$2")" == "edge.example.com" ]]' _ "$tr_dec" "$hy_dec"

    # SA-12d: _date_add_days_ymd rejects overflow / 5-digit year offsets
    check 'SA-12d _date_add_days_ymd rejects 9999999 overflow' not_ok _date_add_days_ymd 9999999 2026-11-28
    check 'SA-12d _date_add_days_ymd rejects 20-digit integer overflow' not_ok _date_add_days_ymd 99999999999999999999 2026-11-28
    check 'SA-12d _date_add_days_ymd computes valid +30 days accurately' eq "$(_date_add_days_ymd 30 2026-11-28)" "2026-12-28"
)

# 3. SA-08, SA-09, SA-10, SA-11, SA-13, SA-14, STYLE-1..2, ADV-4, ADV-5
sec_lifecycle_certs_traffic_style() ( fresh_env lifecycle
    # SA-08 + SA-09: _apply_configs_cli refreshes watchdog.sh & respects paused/.singbox-stopped-empty on --ensure-singbox
    write_db <<<'{"version":"4.0.0","xray":{},"singbox":{"anytls":{"port":24443,"password":"p","sni":"a.example","users":[{"name":"u1","password":"p","enabled":false}]}},"meta":{}}'
    printf '#!/bin/bash\n# STALE_H17_WATCHDOG\n' >"$CFG/watchdog.sh"
    SVC_LOG="$SEC/svc.log"; : >"$SVC_LOG"
    generate_singbox_config() { rm -f "$CFG/singbox.json"; return 2; }
    create_singbox_service() { :; }
    svc() {
        echo "$*" >>"$SVC_LOG"
        case "$1" in
            status) [[ "$2" == "vless-singbox" && ! -e "$CFG/.singbox-stopped-empty" ]] && return 0; return 1 ;;
            stop|start|restart|enable) return 0 ;;
        esac
    }
    _apply_configs_cli --ensure-singbox >/dev/null 2>&1; rc=$?
    check 'SA-08/SA-09a _apply_configs_cli --ensure-singbox returns 0 on F04 0-active-users without starting singbox' \
        bash -c '[[ "$1" -eq 0 ]] && ! grep -Fq "start vless-singbox" "$2"' _ "$rc" "$SVC_LOG"
    check 'SA-08b _apply_configs_cli refreshes stale watchdog.sh with F04/paused guards' \
        bash -c '! grep -Fq "STALE_H17_WATCHDOG" "$1" && grep -Fq ".singbox-stopped-empty" "$1" && grep -Fq "paused" "$1"' _ "$CFG/watchdog.sh"

    # D20-5: _apply_configs_cli propagates watchdog restart failure (non-zero rc + warning, never || true)
    wd_err="$SEC/wd_restart.err"; wd_rc=0
    (
        generate_singbox_config() { rm -f "$CFG/singbox.json"; return 2; }
        svc() {
            case "$1" in
                status) [[ "$2" == "vless-watchdog" ]] && return 0; return 1 ;;
                restart) [[ "$2" == "vless-watchdog" ]] && return 1; return 0 ;;
                *) return 0 ;;
            esac
        }
        _apply_configs_cli >/dev/null 2>"$wd_err"
    ) || wd_rc=$?
    check 'D20-5 _apply_configs_cli returns non-zero and warns when active vless-watchdog fails to restart' \
        bash -c '[[ "$1" -ne 0 ]] && grep -Fq "vless-watchdog" "$2"' _ "$wd_rc" "$wd_err"

    # SA-09b + ADV-4 + D20-4: _acme_cert_reload_cmd respects paused & .singbox-stopped-empty, NEVER calls exit, safely escapes single quotes
    acme_cmd=$(_acme_cert_reload_cmd "$CFG/certs")
    check 'SA-09b _acme_cert_reload_cmd passes POSIX sh -n' bash -c 'sh -n <<<"$1"' _ "$acme_cmd"
    check 'SA-09b/ADV-4 _acme_cert_reload_cmd checks paused/.singbox-stopped-empty/active services with zero exit call' \
        bash -c 'grep -Fq "paused" <<<"$1" && grep -Fq ".singbox-stopped-empty" <<<"$1" && grep -Fq "is-active --quiet" <<<"$1" && grep -Fq "rc-service vless-reality status" <<<"$1" && ! grep -Eq "(^|[[:space:];])exit([[:space:];]|$)" <<<"$1"' _ "$acme_cmd"
    acme_sq_cmd=$(_acme_cert_reload_cmd "/tmp/acme's/certs")
    check 'D20-4a _acme_cert_reload_cmd safely escapes single quotes in cert_dir (passes POSIX sh -n without quote break)' \
        bash -c 'sh -n <<<"$1" && grep -Fq "/tmp/acme'\''\\'\'''\''s/certs/server.key" <<<"$1"' _ "$acme_sq_cmd"
    check 'D20-4b _acme_cert_reload_cmd rejects control characters in cert_dir' \
        not_ok _acme_cert_reload_cmd $'/tmp/bad\ncerts'

    # C20-2 & C20-4: create_server_scripts atomic write failure preserves existing watchdog.sh & returns non-zero; _acme_cert_reload_cmd propagates chmod failure without exit
    acme_fail_rc=0
    bash -c "$acme_cmd" >/dev/null 2>&1 || acme_fail_rc=$?
    check 'C20-4 _acme_cert_reload_cmd returns non-zero when cert files are missing (chmod failure propagated)' \
        test "$acme_fail_rc" -ne 0
    css_ro="$SEC/ro_cfg"
    mkdir -p "$css_ro"
    printf '#!/bin/bash\n# KEEP_OLD_WATCHDOG\n' >"$css_ro/watchdog.sh"
    css_err="$SEC/css_ro.err"; css_rc=0
    VLESS_SOURCE_ONLY=1 VLESS_TEST_CFG="$css_ro" bash -c '
        # shellcheck disable=SC1090
        source "$1"
        cat() { return 1; }
        create_server_scripts
    ' _ "$PRODUCT" >/dev/null 2>"$css_err" || css_rc=$?
    check 'C20-2 create_server_scripts returns non-zero on write failure without truncating existing watchdog.sh' \
        bash -c '[[ "$1" -ne 0 ]] && ! grep -Fq "readonly variable" "$3" && grep -Fq "KEEP_OLD_WATCHDOG" "$2/watchdog.sh"' _ "$css_rc" "$css_ro" "$css_err"
    mig_aux="$SEC/mig_aux"
    mkdir -p "$mig_aux/bin" "$mig_aux/state" "$mig_aux/cfg"
    cat >"$mig_aux/bin/systemctl" <<'EOF'
#!/bin/bash
case "$1" in
    list-unit-files) printf 'vless-anytls.service enabled\nvless-singbox.service enabled\n' ;;
    is-active) [[ "$2" == "--quiet" ]] && u="$3" || u="$2"; [[ -e "$MSTATE/active.$u" ]]; exit $? ;;
    stop) rm -f "$MSTATE/active.$2"; [[ "$2" == "vless-anytls" ]] && rm -f "$MSTATE/listen.18443" ;;
    start) : >"$MSTATE/active.$2" ;;
    disable) : >"$MSTATE/disabled.$2" ;;
esac
exit 0
EOF
    cat >"$mig_aux/bin/ss" <<'EOF'
#!/bin/bash
p="${*: -1}"; p="${p##*:}"
[[ -e "$MSTATE/listen.$p" ]] && echo "LISTEN 0 4096 *:$p *:*"
exit 0
EOF
    printf '#!/bin/bash\nexit 0\n' >"$mig_aux/bin/sing-box"
    cat >"$mig_aux/apply_aux_warn.sh" <<'EOF'
#!/bin/bash
printf '{"inbounds":[{"type":"anytls","listen_port":18443}]}\n' >"$MCFG/singbox.json"
: >"$MSTATE/active.vless-singbox"
: >"$MSTATE/listen.18443"
exit 1
EOF
    cat >"$mig_aux/apply_no_sb.sh" <<'EOF'
#!/bin/bash
: >"$MSTATE/active.vless-singbox"
: >"$MSTATE/listen.18443"
exit 1
EOF
    chmod +x "$mig_aux/bin/"* "$mig_aux/apply_aux_warn.sh" "$mig_aux/apply_no_sb.sh"
    printf '{"xray":{"anytls":{"port":18443,"password":"pw1","sni":"a.example"}},"singbox":{}}\n' >"$mig_aux/cfg/db.json"
    : >"$mig_aux/state/active.vless-anytls"; : >"$mig_aux/state/listen.18443"
    mig_aux_rc=0
    PATH="$mig_aux/bin:$PATH" MSTATE="$mig_aux/state" MCFG="$mig_aux/cfg" \
        AIO_MIGRATE_CFG_DIR="$mig_aux/cfg" AIO_MIGRATE_SCRIPT_BIN="$mig_aux/apply_aux_warn.sh" \
        bash "$ROOT/migrate-anytls-singbox.sh" >/dev/null 2>&1 || mig_aux_rc=$?
    check 'C20-2b migrator keeps verified AnyTLS takeover when --apply-configs exits non-zero from auxiliary refresh' \
        bash -c '[[ "$1" -eq 0 && -e "$2/state/disabled.vless-anytls" ]] && jq -e ".xray.anytls == null and .singbox.anytls.port == 18443" "$2/cfg/db.json" >/dev/null' _ "$mig_aux_rc" "$mig_aux"
    rm -f "$mig_aux/cfg/singbox.json" "$mig_aux/state/disabled.vless-anytls" "$mig_aux/state/active.vless-singbox"
    printf '{"xray":{"anytls":{"port":18443,"password":"pw1","sni":"a.example"}},"singbox":{}}\n' >"$mig_aux/cfg/db.json"
    : >"$mig_aux/state/active.vless-anytls"; : >"$mig_aux/state/listen.18443"
    mig_nosb_rc=0
    PATH="$mig_aux/bin:$PATH" MSTATE="$mig_aux/state" MCFG="$mig_aux/cfg" \
        AIO_MIGRATE_CFG_DIR="$mig_aux/cfg" AIO_MIGRATE_SCRIPT_BIN="$mig_aux/apply_no_sb.sh" \
        bash "$ROOT/migrate-anytls-singbox.sh" >/dev/null 2>&1 || mig_nosb_rc=$?
    check 'C20-2c migrator rolls back when --apply-configs exits non-zero without rendered singbox.json anytls inbound' \
        bash -c '[[ "$1" -ne 0 && ! -e "$2/state/disabled.vless-anytls" ]] && jq -e ".xray.anytls.port == 18443 and .singbox.anytls == null" "$2/cfg/db.json" >/dev/null' _ "$mig_nosb_rc" "$mig_aux"

    # ADV-5: create_fake_website has no dead/unbound nginx_bak reference
    cfw_body=$(declare -f create_fake_website)
    check 'ADV-5 create_fake_website removes dead nginx_bak reference and uses sub_stash around _nginx_install_conf' \
        bash -c '[[ -n "$1" ]] && ! grep -Fq "nginx_bak" <<<"$1" && grep -Fq "sub_stash" <<<"$1"' _ "$cfw_body"

    # SA-10: generate_singbox_config anytls falls back to anytls self-signed cert when global cert fails _anytls_secure
    mkdir -p "$CFG/certs/anytls"
    printf 'dummy-global\n' >"$CFG/certs/server.crt"
    printf 'dummy-global-key\n' >"$CFG/certs/server.key"
    printf 'a.example\n' >"$CFG/cert_domain"
    printf 'dummy-anytls\n' >"$CFG/certs/anytls/server.crt"
    printf 'dummy-anytls-key\n' >"$CFG/certs/anytls/server.key"
    write_db <<<'{"version":"4.0.0","xray":{},"singbox":{"anytls":{"port":24443,"password":"p","sni":"a.example","users":[{"name":"u1","password":"p","enabled":true}]}},"meta":{}}'
    mkdir -p "$SEC/bin"
    printf '#!/bin/sh\nexit 0\n' >"$SEC/bin/sing-box"
    chmod +x "$SEC/bin/sing-box"
    anytls_cert_used=$(PATH="$SEC/bin:$PATH" VLESS_SOURCE_ONLY=1 VLESS_TEST_CFG="$CFG" bash -c '
        # shellcheck disable=SC1090
        source "$1"
        set +u
        DISTRO="debian"
        generate_singbox_config >/dev/null 2>&1 || true
        jq -r ".inbounds[] | select(.type==\"anytls\") | .tls.certificate_path" "$CFG/singbox.json" 2>/dev/null
    ' _ "$PRODUCT")
    check 'SA-10 anytls falls back to $CFG/certs/anytls/server.crt when global cert fails _anytls_secure' \
        eq "$anytls_cert_used" "$CFG/certs/anytls/server.crt"

    # SA-11: Stage-2 quota-check failure persists .quota-check-pending so next run disables over-quota user even with empty traffic.pending
    mkdir -p "$CFG/cache"
    write_db <<<'{"version":"4.0.0","xray":{"vless":{"port":443,"uuid":"u","users":[{"name":"u1","uuid":"u","enabled":true,"quota":100,"used":0}]}},"singbox":{},"meta":{}}'
    printf 'user>>>u1@vless>>>traffic>>>uplink 250 sa11-1\n' >"$CFG/cache/traffic.pending"
    (
        _traffic_collect_to_journal() { return 0; }
        tg_get_config() { echo 80; }
        _db_set_user_enabled_nowrite() { return 1; }
        _sync_all_user_traffic_locked >/dev/null 2>&1
    ); rc1=$?
    check 'SA-11a Stage-2 disable failure returns non-zero and drops .quota-check-pending marker' \
        bash -c '[[ "$1" -ne 0 && -e "$2/cache/.quota-check-pending" ]]' _ "$rc1" "$CFG"
    (
        _traffic_collect_to_journal() { return 0; }
        tg_get_config() { echo 80; }
        tg_send_over_quota() { :; }
        _sync_all_user_traffic_locked >/dev/null 2>&1
    ); rc2=$?
    u1_enabled=$(jq -r '.xray.vless.users[0].enabled' "$DB_FILE")
    check 'SA-11b Next sync with empty traffic.pending disables over-quota user and clears .quota-check-pending' \
        bash -c '[[ "$1" -eq 0 && "$2" == "false" && ! -e "$3/cache/.quota-check-pending" ]]' _ "$rc2" "$u1_enabled" "$CFG"

    # D20-2: Consecutive Stage-2 failures trigger bounded exponential backoff (skipping redundant full-DB jq scans)
    write_db <<<'{"version":"4.0.0","xray":{"vless":{"port":443,"uuid":"u","users":[{"name":"u2","uuid":"u","enabled":true,"quota":100,"used":250}]}},"singbox":{},"meta":{}}'
    : >"$CFG/cache/traffic.pending"
    printf '1\t0\n' >"$CFG/cache/.quota-check-pending"
    (
        _traffic_collect_to_journal() { return 0; }
        tg_get_config() { echo 80; }
        _db_set_user_enabled_nowrite() { return 1; }
        _sync_all_user_traffic_locked >/dev/null 2>&1
    ); rc_bo1=$?
    IFS=$'\t' read -r bo_fails bo_next <"$CFG/cache/.quota-check-pending"
    now_check=$(date +%s)
    check 'D20-2a 2nd consecutive Stage-2 failure records fail_count=2 and future backoff next_retry' \
        bash -c '[[ "$1" -ne 0 && "$2" -eq 2 && "$3" -gt "$4" ]]' _ "$rc_bo1" "$bo_fails" "$bo_next" "$now_check"
    JQ_SPY="$SEC/jq_backoff.count"; printf '0\n' >"$JQ_SPY"
    (
        _traffic_collect_to_journal() { return 0; }
        jq() { echo $(( $(cat "$JQ_SPY") + 1 )) >"$JQ_SPY"; command jq "$@"; }
        _sync_all_user_traffic_locked >/dev/null 2>&1
    ); rc_bo2=$?
    jq_calls=$(cat "$JQ_SPY")
    check 'D20-2b sync inside backoff window with empty pending skips full-DB jq scan and returns non-zero' \
        bash -c '[[ "$1" -ne 0 && "$2" -eq 0 && -e "$3/cache/.quota-check-pending" ]]' _ "$rc_bo2" "$jq_calls" "$CFG"
    printf '2\t1\n' >"$CFG/cache/.quota-check-pending"
    (
        _traffic_collect_to_journal() { return 0; }
        tg_get_config() { echo 80; }
        tg_send_over_quota() { :; }
        _sync_all_user_traffic_locked >/dev/null 2>&1
    ); rc_bo3=$?
    u2_enabled=$(jq -r '.xray.vless.users[0].enabled' "$DB_FILE")
    check 'D20-2c after backoff window expires, sync disables over-quota user and clears .quota-check-pending' \
        bash -c '[[ "$1" -eq 0 && "$2" == "false" && ! -e "$3/cache/.quota-check-pending" ]]' _ "$rc_bo3" "$u2_enabled" "$CFG"

    # C20-1: Zero-valued statsquery entries are not journaled (preserving idle backoff); >3600s clock skew & 08 octal handled; failed marker write keeps pending
    write_db <<<'{"version":"4.0.0","xray":{"vless":{"port":443,"uuid":"u","users":[{"name":"u3","uuid":"u","enabled":true,"quota":100,"used":250}]}},"singbox":{},"meta":{}}'
    : >"$CFG/cache/traffic.pending"
    (
        _pgrep() { return 0; }
        xray() { printf '{"stat":[{"name":"user>>>u3@vless>>>traffic>>>uplink","value":0},{"name":"user>>>u3@vless>>>traffic>>>downlink"}]}\n'; }
        _traffic_collect_to_journal >/dev/null 2>&1
    )
    check 'C20-1a _traffic_collect_to_journal ignores 0-byte idle counters so traffic.pending stays empty' \
        test ! -s "$CFG/cache/traffic.pending"
    printf '08\t4102444800\n' >"$CFG/cache/.quota-check-pending"
    (
        _traffic_collect_to_journal() { return 0; }
        tg_get_config() { echo 80; }
        tg_send_over_quota() { :; }
        _sync_all_user_traffic_locked >/dev/null 2>&1
    ); rc_skew=$?
    u3_enabled=$(jq -r '.xray.vless.users[0].enabled' "$DB_FILE")
    check 'C20-1b 08 octal count & >3600s future clock-skew deadline do not freeze scan (disables over-quota user)' \
        bash -c '[[ "$1" -eq 0 && "$2" == "false" && ! -e "$3/cache/.quota-check-pending" ]]' _ "$rc_skew" "$u3_enabled" "$CFG"
    write_db <<<'{"version":"4.0.0","xray":{"vless":{"port":443,"uuid":"u","users":[{"name":"u4","uuid":"u","enabled":true,"quota":100,"used":0}]}},"singbox":{},"meta":{}}'
    printf 'user>>>u4@vless>>>traffic>>>uplink 250 c20-1c\n' >"$CFG/cache/traffic.pending"
    mkdir -p "$CFG/cache/.quota-check-pending"
    (
        _traffic_collect_to_journal() { return 0; }
        tg_get_config() { echo 80; }
        _db_set_user_enabled_nowrite() { return 1; }
        _sync_all_user_traffic_locked >/dev/null 2>&1
    ); rc_qpf=$?
    rmdir "$CFG/cache/.quota-check-pending" 2>/dev/null || true
    check 'C20-1c when .quota-check-pending atomic persist fails, traffic.pending is preserved (never lost)' \
        bash -c '[[ "$1" -ne 0 && -s "$2/cache/traffic.pending" ]]' _ "$rc_qpf" "$CFG"
    : >"$CFG/cache/traffic.pending"

    # SA-14: _regenerate_proxy_configs acks stale .reload-pending.xray on success
    write_db <<<'{"version":"4.0.0","xray":{"vless":{"port":443,"uuid":"u","users":[{"name":"u1","uuid":"u","enabled":true}]}},"singbox":{},"meta":{}}'
    _reload_pending_arm xray >/dev/null
    generate_xray_config() { return 0; }
    svc() { return 1; }
    _regenerate_proxy_configs >/dev/null 2>&1
    check 'SA-14 _regenerate_proxy_configs delegates to rebuild_and_reload_xray and acks .reload-pending.xray' \
        test ! -e "$CFG/.reload-pending.xray"

    # STYLE-1: gen_*_routing_* returns 0 even when empty
    write_db <<<'{"version":"4.0.0","xray":{},"singbox":{},"meta":{}}'
    gen_xray_routing_rules >/dev/null; r1=$?
    gen_singbox_routing_rules >/dev/null; r2=$?
    gen_xray_ip_routing_outbounds >/dev/null; r3=$?
    gen_xray_ip_routing_rules >/dev/null; r4=$?
    check 'STYLE-1 all 4 gen_*_routing_* functions return 0 on empty rules' \
        bash -c '[[ "$1" -eq 0 && "$2" -eq 0 && "$3" -eq 0 && "$4" -eq 0 ]]' _ "$r1" "$r2" "$r3" "$r4"
)

# 4. REL-2 & ADV-2: check-version-bump.sh all-zero --base passes multi-commit tag push AND blocks unbumped post-tag branch
sec_rel2_version_bump_tag_push() (
    TR="$TMP/vb_repo"
    mkdir -p "$TR"
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
    export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@e.invalid
    export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@e.invalid
    git -C "$TR" init -q
    printf '#!/bin/bash\nreadonly VERSION="3.4.10-h17"\necho a\n' >"$TR/vless-server.sh"
    git -C "$TR" add vless-server.sh && git -C "$TR" commit -qm "h17"
    git -C "$TR" tag v3.4.10-h17
    printf '#!/bin/bash\nreadonly VERSION="3.4.10-h20"\necho b1\n' >"$TR/vless-server.sh"
    git -C "$TR" add vless-server.sh && git -C "$TR" commit -qm "h20 part 1"
    printf '#!/bin/bash\nreadonly VERSION="3.4.10-h20"\necho b2\n' >"$TR/vless-server.sh"
    git -C "$TR" add vless-server.sh && git -C "$TR" commit -qm "h20 part 2"
    git -C "$TR" tag v3.4.10-h20
    ( cd "$TR" && bash "$ROOT/check-version-bump.sh" --base 0000000000000000000000000000000000000000 >/dev/null 2>&1 )
    check 'REL-2 check-version-bump.sh passes on multi-commit tag push (all-zero --base compares against prev tag v3.4.10-h17)' eq $? 0

    # ADV-2 & version_gt fix: after v3.4.10-h20 is already tagged, unbumped edit on a new branch (all-zero --base) MUST fail closed with zero shell error
    printf '#!/bin/bash\nreadonly VERSION="3.4.10-h20"\necho b3-unbumped\n' >"$TR/vless-server.sh"
    git -C "$TR" add vless-server.sh && git -C "$TR" commit -qm "unbumped post-tag"
    vb_err1="$TMP/vb_adv2.err"; vb_rc1=0
    ( cd "$TR" && bash "$ROOT/check-version-bump.sh" --base 0000000000000000000000000000000000000000 >/dev/null 2>"$vb_err1" ) || vb_rc1=$?
    check 'ADV-2 check-version-bump.sh blocks unbumped post-tag branch cleanly (no command-not-found on stderr)' \
        bash -c '[[ "$1" -eq 1 ]] && ! grep -Fq "command not found" "$2"' _ "$vb_rc1" "$vb_err1"

    # New bumped branch above highest tag (all-zero --base) passes cleanly via version_gt
    printf '#!/bin/bash\nreadonly VERSION="3.4.10-h21"\necho b4-bumped\n' >"$TR/vless-server.sh"
    git -C "$TR" add vless-server.sh && git -C "$TR" commit -qm "bumped post-tag"
    vb_err2="$TMP/vb_h21.err"; vb_rc2=0
    ( cd "$TR" && bash "$ROOT/check-version-bump.sh" --base 0000000000000000000000000000000000000000 >/dev/null 2>"$vb_err2" ) || vb_rc2=$?
    check 'REL-2b check-version-bump.sh passes bumped branch above latest tag (all-zero --base, clean stderr)' \
        bash -c '[[ "$1" -eq 0 ]] && ! grep -Fq "command not found" "$2"' _ "$vb_rc2" "$vb_err2"

    # C20-5: bare numeric tag without 'v' prefix cannot derail multi-commit v* tag push, and 08/09 revisions compare as decimal
    git -C "$TR" tag 3.4.10-h20-bare 2>/dev/null || true
    git -C "$TR" tag 3.4.10-h19 HEAD~2
    printf '#!/bin/bash\nreadonly VERSION="3.4.10-h21"\necho b5-part2\n' >"$TR/vless-server.sh"
    git -C "$TR" add vless-server.sh && git -C "$TR" commit -qm "h21 part 2"
    git -C "$TR" tag v3.4.10-h21
    vb_err3="$TMP/vb_c20_5.err"; vb_rc3=0
    ( cd "$TR" && bash "$ROOT/check-version-bump.sh" --base 0000000000000000000000000000000000000000 >/dev/null 2>"$vb_err3" ) || vb_rc3=$?
    check 'C20-5 check-version-bump.sh ignores bare non-v numeric tags on multi-commit v* tag push' \
        bash -c '[[ "$1" -eq 0 ]] && ! grep -Fq "command not found" "$2"' _ "$vb_rc3" "$vb_err3"
)

for sec in sec_sec1_sec3_eval_and_downloads sec_sec2_sa12_parsers_and_date sec_lifecycle_certs_traffic_style sec_rel2_version_bump_tag_push; do
    printf '\n########## %s ##########\n' "$sec"
    "$sec"
    rc=$?
    if [[ "$rc" -ne 0 ]]; then
        echo "FAIL $sec subshell exited with $rc" | tee -a "$RESULTS" >&2
    fi
done

pass=$(grep -c '^OK ' "$RESULTS" || true)
fail=$(grep -c '^FAIL ' "$RESULTS" || true)
echo ""
if [[ "$fail" -eq 0 && "$pass" -gt 0 ]]; then
    echo "PASS: H20 hardening & adversarial remediation regression passed ($pass assertions, 0 failed)"
    exit 0
else
    echo "FAIL: H20 hardening regression failed ($fail failed, $pass passed)" >&2
    exit 1
fi
