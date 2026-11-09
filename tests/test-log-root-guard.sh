#!/usr/bin/env bash
# Regression for the two h11 guards:
#   1. generate_xray_config must fail fast (non-zero) when the log root is unusable,
#      instead of writing a config.json that points at a directory that does not exist.
#   2. _install_binary must refuse a URL that still contains an unsubstituted placeholder,
#      before it ever calls curl.
#
# Why: h9's defect was a config that looked fine and failed at service start. h11 moves both
# failures to the generation/download step, where the error can name the real cause.
#
# Side effects: temporary dir + source-only generation. No service, no network, no /etc write.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/../vless-server.sh"
[[ -f "$SRC" ]] || { echo 'FAIL: vless-server.sh not found' >&2; exit 2; }

WORK="$(mktemp -d /tmp/vless-logroot.XXXXXXXX)"
WORK_PIN="$WORK"
t_cleanup() {
    [[ "${KEEP:-0}" == 1 ]] && { echo "kept: $WORK_PIN" >&2; return; }
    [[ -n "${WORK_PIN:-}" && -d "$WORK_PIN" && ! -L "$WORK_PIN" ]] && rm -rf -- "$WORK_PIN"
}
trap t_cleanup EXIT

fail=0
t_check() { # name expected actual
    if [[ "$2" == "$3" ]]; then printf '  OK   %s\n' "$1"
    else printf '  FAIL %s (expected=%s actual=%s)\n' "$1" "$2" "$3" >&2; fail=1; fi
}
t_nonzero() { # name actual-rc
    if [[ "$2" != "0" ]]; then printf '  OK   %s (rc=%s)\n' "$1" "$2"
    else printf '  FAIL %s (expected non-zero, got 0)\n' "$1" >&2; fail=1; fi
}

sed -e "s@^readonly CFG=\"/etc/vless-reality\"@readonly CFG=\"$WORK/cfg\"@" "$SRC" > "$WORK/script.sh"
[[ "$(grep -cF "readonly CFG=\"$WORK/cfg\"" "$WORK/script.sh")" == 1 ]] || { echo 'FAIL: CFG rewrite' >&2; exit 2; }
command mkdir -p "$WORK/cfg" "$WORK/log" "$WORK/home"
export VLESS_SOURCE_ONLY=1 HOME="$WORK/home" TMPDIR="$WORK"
export XDG_STATE_HOME="$WORK" XDG_CACHE_HOME="$WORK" XDG_CONFIG_HOME="$WORK"
# shellcheck disable=SC1090
source "$WORK/script.sh" || { echo 'FAIL: source' >&2; exit 2; }
set +e            # the product script re-enables errexit
trap t_cleanup EXIT
WORK="$WORK_PIN"

# stubs: keep generation offline and side-effect free
_listen_addr() { printf '127.0.0.1\n'; }
svc() { printf 'blocked\n' >&2; return 99; }
_ok() { :; }; _info() { :; }; _warn() { :; }
_err() { printf 'err: %s\n' "$*" >> "$WORK/err.log"; }
db_get() { jq -c --arg c "$1" --arg p "$2" '.[$c][$p] // empty' "$DB_FILE"; }
db_list_protocols() { jq -r --arg c "$1" '(.[$c] // {}) | keys[]' "$DB_FILE"; }
db_get_balancer_groups() { printf '[]\n'; }
db_get_warp_mode() { printf '\n'; }
db_get_routing_rules() { printf '[]\n'; }
gen_xray_routing_rules() { printf '[]\n'; }
gen_xray_user_routing_rules() { printf '[]\n'; }
gen_xray_ip_routing_outbounds() { printf '[]\n'; }
get_xray_protocols() { db_list_protocols xray; }
PEER='{"name":"on","uuid":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","enabled":true}'
printf '%s\n' "{\"xray\":{\"vless-ws-notls\":{\"port\":18447,\"uuid\":\"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee\",\"users\":[$PEER]}}}" > "$DB_FILE"

gen_rc() { # <VLESS_TEST_LOG_ROOT value or __UNSET__> [stub-default-mkdir]
    local v="$1" stub_default_mkdir="${2:-0}" rc
    rm -f "$CFG/config.json"
    (
        set +e    # product code may re-enable errexit; a probe must never abort the harness
        if [[ "$v" == "__UNSET__" ]]; then unset VLESS_TEST_LOG_ROOT; else export VLESS_TEST_LOG_ROOT="$v"; fi
        if [[ "$stub_default_mkdir" == 1 ]]; then
            # The product is root-only, while hosted CI runs this test as an unprivileged user.
            # Stub only the successful /var/log boundary; all rejection probes keep real mkdir.
            mkdir() {
                if [[ "$#" -eq 2 && "$1" == "-p" && "$2" == "/var/log/xray" ]]; then
                    printf '%s\n' "$*" >> "$WORK/default-mkdir.calls"
                    return 0
                fi
                command mkdir "$@"
            }
        fi
        generate_xray_config
    ) >/dev/null 2>&1
    rc=$?
    printf '%s' "$rc"
}

echo '--- guard 1: unusable log root must fail fast ---'
t_nonzero 'relative log root rejected'        "$(gen_rc 'relative/logs')"
t_check   'relative log root wrote no config' no "$([[ -s "$CFG/config.json" ]] && echo yes || echo no)"
t_nonzero 'unwritable log root rejected'      "$(gen_rc '/proc/vless-cannot-create')"
t_check   'unwritable log root wrote no config' no "$([[ -s "$CFG/config.json" ]] && echo yes || echo no)"
: > "$WORK/default-mkdir.calls"
t_check   'unset log root still generates'    0  "$(gen_rc '__UNSET__' 1)"
t_check   'unset log root -> /var/log'        /var/log/xray/access.log "$(jq -r '.log.access // "<none>"' "$CFG/config.json" 2>/dev/null)"
t_check   'empty log root still generates'    0  "$(gen_rc '' 1)"
t_check   'empty log root -> /var/log'        /var/log/xray/access.log "$(jq -r '.log.access // "<none>"' "$CFG/config.json" 2>/dev/null)"
t_check   'default cases request exact log directory' 2 "$(grep -cxF -- '-p /var/log/xray' "$WORK/default-mkdir.calls")"

echo '--- guard 2: URL with an unsubstituted placeholder must be refused before curl ---'
: > "$WORK/curl.calls"
curl() { printf '%s\n' "$*" >> "$WORK/curl.calls"; return 0; }
# _install_binary short-circuits when the binary is "installed" and otherwise resolves a
# version from the network; stub both so only the URL-building path is exercised.
check_cmd() { return 1; }
IB_RC=0
ib_run() { # <url-pattern>; sets IB_RC (version_override = 7th arg, so no version lookup)
    # the real callers define these locals before calling _install_binary; the substitution table
    # dereferences them, so they must exist here too (script runs under `set -u`).
    ( set +e; xarch=amd64; sarch=amd64; aarch=amd64
      _install_binary "probe" "owner/repo" "$1" 'true' stable false "1.2.3" ) >/dev/null 2>&1
    IB_RC=$?
}
ib_run 'https://example.invalid/v$version/x-${goarch}.zip'
t_nonzero 'unknown placeholder ${goarch} refused' "$IB_RC"
t_check   'refused before curl (no curl call)'   0 "$(grep -c . "$WORK/curl.calls" 2>/dev/null || true)"
ib_run 'https://example.invalid/v$version/x-${xarch}.zip'
t_check   'known placeholders still accepted'    0 "$IB_RC"
t_check   'known placeholders -> curl called'    1 "$(grep -c . "$WORK/curl.calls" 2>/dev/null || true)"

if [[ $fail -ne 0 ]]; then
    [[ -s "$WORK/err.log" ]] && { echo '--- captured _err output ---'; cat "$WORK/err.log" | head -10; }
    printf 'log-root-guard: FAIL\n' >&2; exit 1
fi
printf 'log-root-guard: PASS\n'
