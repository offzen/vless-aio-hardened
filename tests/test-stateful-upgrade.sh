#!/usr/bin/env bash
# Real prior-release bytes (H13 or H14) -> working-tree candidate updater transaction with persistent DB state.
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
CANDIDATE=${CANDIDATE_UNDER_TEST:-$ROOT/vless-server.sh}
readonly H13_COMMIT=${H13_COMMIT:-0dd40ea036331f14ece92c6197bb8125fabf1be9}
readonly H13_SHA256=33c953bde77f587cb6601751ea404f92b134be0cc663c2e765685393225dfa88
readonly H14_SHA256=6ea18a9e5af7ca2802ee6982d478d042ffcbcd4108b3a978c26e50aaf77eaa34
for dep in git grep jq sed sha256sum; do
    command -v "$dep" >/dev/null 2>&1 || { echo "FAIL: missing dependency: $dep" >&2; exit 2; }
done
[[ -f "$CANDIDATE" ]] || { echo "FAIL: missing candidate: $CANDIDATE" >&2; exit 2; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/aio-stateful-upgrade.XXXXXX")
TMP=$(cd -- "$TMP" && pwd -P) || exit 2
trap 'rm -rf -- "$TMP"' EXIT INT TERM
BASE_SCRIPT="$TMP/base.sh"
BASE_LABEL="H13"
BASE_EXPECTED_SHA="$H13_SHA256"
if git -C "$ROOT" cat-file -e "$H13_COMMIT^{commit}" 2>/dev/null; then
    git -C "$ROOT" show "$H13_COMMIT:vless-server.sh" >"$BASE_SCRIPT"
elif git -C "$ROOT" rev-parse --verify --quiet "v3.4.10-h13^{commit}" >/dev/null 2>&1 \
  && git -C "$ROOT" merge-base --is-ancestor "v3.4.10-h13^{commit}" HEAD 2>/dev/null; then
    git -C "$ROOT" show "v3.4.10-h13:vless-server.sh" >"$BASE_SCRIPT"
else
    # The clean-history H15 repository has an exact H14 baseline, never infer it from a shallow root.
    H14_BASE_COMMIT=${H14_COMMIT:-1623626204905de4498f104ccced0022670085c8}
    if ! git -C "$ROOT" merge-base --is-ancestor "$H14_BASE_COMMIT" HEAD 2>/dev/null; then
        echo "FAIL: H13/H14 baseline is not available as an ancestor; checkout full history (fetch-depth: 0)" >&2
        exit 1
    fi
    git -C "$ROOT" show "$H14_BASE_COMMIT:vless-server.sh" >"$BASE_SCRIPT"
    BASE_LABEL="H14"
    BASE_EXPECTED_SHA="$H14_SHA256"
fi
[[ "$(sha256sum "$BASE_SCRIPT" | awk '{print $1}')" == "$BASE_EXPECTED_SHA" ]] || { echo "FAIL: extracted $BASE_LABEL artifact hash mismatch" >&2; exit 1; }
H13="$BASE_SCRIPT"
CANDIDATE_SHA=$(sha256sum "$CANDIDATE" | awk '{print $1}')
[[ "$CANDIDATE_SHA" != "$BASE_EXPECTED_SHA" ]] || { echo "FAIL: candidate unexpectedly equals $BASE_LABEL" >&2; exit 1; }
CANDIDATE_VERSION=$(sed -n 's/^readonly VERSION="\([^"]*\)"/\1/p' "$CANDIDATE" | head -n1)
[[ "$CANDIDATE_VERSION" =~ -h1[4567]$ ]] || { echo "FAIL: expected H14/H15/H16/H17 candidate, got $CANDIDATE_VERSION" >&2; exit 1; }

pass=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { pass=$((pass + 1)); printf '  OK   %s\n' "$1"; }
make_source_copy() {
    local input=$1 output=$2 dir=$3
    if [[ "$BASE_LABEL" == "H13" ]]; then
        sed -e 's@^readonly CFG="/etc/vless-reality"@readonly CFG="'"$dir"'/cfg"@' \
            -e 's@^readonly VERSION_CACHE_DIR=.*@readonly VERSION_CACHE_DIR="'"$dir"'/cache"@' \
            "$input" >"$output"
        [[ "$(grep -cF "readonly CFG=\"$dir/cfg\"" "$output")" == 1 ]] || fail "H13 CFG fixture rewrite missed: $output"
    else
        sed -e 's@^readonly VERSION_CACHE_DIR=.*@readonly VERSION_CACHE_DIR="'"$dir"'/cache"@' \
            "$input" >"$output"
    fi
    [[ "$(grep -cF "readonly VERSION_CACHE_DIR=\"$dir/cache\"" "$output")" == 1 ]] || fail "$BASE_LABEL cache fixture rewrite missed: $output"
    bash -n "$output"
}
sha() { sha256sum "$1" | awk '{print $1}'; }
function_sha() {
    local script=$1 cfg=$2 output
    mkdir -p "$cfg"
    output=$(mktemp "$TMP/function-sha.XXXXXX") || fail "cannot allocate function hash fixture"
    if ! VLESS_SOURCE_ONLY=1 VLESS_TEST_CFG="$cfg" bash -c '
        source "$1"
        [[ "$CFG" == "$2" ]] || exit 97
        declare -f supports_per_user_management generate_xray_config generate_singbox_config || true
    ' _ "$script" "$cfg" >"$output"; then
        fail "function extraction did not preserve CFG isolation: $script"
    fi
    sha "$output"
}
H13_FUNCTION_COPY="$TMP/h13-function-source.sh"
H13_FUNCTION_DIR="$TMP/h13-function"
mkdir -p "$H13_FUNCTION_DIR/cache" "$H13_FUNCTION_DIR/cfg"
make_source_copy "$H13" "$H13_FUNCTION_COPY" "$H13_FUNCTION_DIR"
H13_FUNCTION_SHA=$(function_sha "$H13_FUNCTION_COPY" "$H13_FUNCTION_DIR/cfg")
CANDIDATE_FUNCTION_SHA=$(function_sha "$CANDIDATE" "$TMP/candidate-function/cfg")
[[ "$H13_FUNCTION_SHA" != "$CANDIDATE_FUNCTION_SHA" ]] || fail "H13 and candidate renderer function hashes unexpectedly match"
seed_db() {
    local db=$1
    mkdir -p "$(dirname -- "$db")"
    cat >"$db" <<'JSON'
{
  "xray": {
    "ss-legacy": {
      "port": 18388, "method": "aes-256-gcm", "password": "legacy-top-secret",
      "users": [
        {"name":"default","uuid":"legacy-default","enabled":true},
        {"name":"second","uuid":"legacy-second","enabled":true},
        {"name":"disabled","uuid":"legacy-disabled","enabled":false},
        {"name":"expired","uuid":"legacy-expired","enabled":true,"expire_date":"2000-01-01"}
      ]
    },
    "vless-ws-notls": {
      "port": 18443, "uuid": "11111111-1111-4111-8111-111111111111", "path":"/fixture", "host":"fixture.invalid",
      "users": [
        {"name":"active","uuid":"22222222-2222-4222-8222-222222222222","enabled":true},
        {"name":"disabled","uuid":"33333333-3333-4333-8333-333333333333","enabled":false}
      ]
    }
  },
  "singbox": {
    "anytls": {
      "port": 19443, "password":"old-top", "sni":"fixture.invalid",
      "users": [
        {"name":"active","uuid":"anytls-active","enabled":true},
        {"name":"disabled","uuid":"anytls-disabled","enabled":false},
        {"name":"expired","uuid":"anytls-expired","enabled":true,"expire_date":"2000-01-01"}
      ]
    }
  }
}
JSON
}
make_runner() {
    local dir=$1 mode=$2
    local source_copy="$dir/h13-source.sh" runner="$dir/runner.sh"
    mkdir -p "$dir/cache" "$dir/cfg"
    make_source_copy "$H13" "$source_copy" "$dir"
    seed_db "$dir/cfg/db.json"
    cat >"$runner" <<EOF
#!/usr/bin/env bash
set -uo pipefail
export VLESS_SOURCE_ONLY=1 VLESS_TEST_CFG="$dir/cfg" VLESS_TEST_LOG_ROOT="$dir/log"
source "$source_copy"
[[ "\$CFG" == "\$VLESS_TEST_CFG" ]] || { echo 'FAIL: VLESS_TEST_CFG isolation' >&2; exit 2; }
_header() { :; }; _line() { :; }; _info() { :; }; _ok() { :; }; _warn() { :; }; _err() { printf '%s\n' "\$*" >&2; }
_init_version_cache() { mkdir -p "\$VERSION_CACHE_DIR"; }
_fetch_script_tmp() { local f; f=\$(mktemp "$dir/download.XXXXXX") || return 1; cp "$CANDIDATE" "\$f" || return 1; printf '%s\n' "\$f"; }
init_db() { printf 'init_db\n' >>"$dir/apply.log"; [[ "$mode" != fail-init ]]; }
rebuild_and_reload_xray() { printf 'xray\n' >>"$dir/apply.log"; [[ "$mode" != fail-xray ]]; }
rebuild_and_reload_singbox() { printf 'singbox\n' >>"$dir/apply.log"; [[ "$mode" != fail-singbox ]]; }
do_update
EOF
    bash -n "$runner"
}
run_fresh_render() {
    local dir=$1 fresh="$dir/fresh-render.sh" marker="$dir/fresh-render.marker"
    cat >"$fresh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
export VLESS_SOURCE_ONLY=1 VLESS_TEST_CFG="$dir/cfg" VLESS_TEST_LOG_ROOT="$dir/log"
set --
source "$dir/runner.sh"
[[ "\$CFG" == "\$VLESS_TEST_CFG" ]] || { echo 'FAIL: VLESS_TEST_CFG isolation' >&2; exit 2; }
set -uo pipefail
_info() { :; }; _ok() { :; }; _warn() { :; }; _err() { printf '%s\n' "\$*" >&2; }
_listen_addr() { printf '127.0.0.1\n'; }
db_get_balancer_groups() { printf '[]\n'; }
db_get_routing_rules() { printf '[]\n'; }
db_get_warp_mode() { :; }
db_ip_routing_enabled() { return 1; }
printf 'pid=%s\nversion=%s\ncfg=%s\nfunction_sha=%s\n' \
    "\$\$" "\$VERSION" "\$CFG" \
    "\$(declare -f supports_per_user_management generate_xray_config generate_singbox_config | sha256sum | awk '{print \$1}')" >"$marker"
(set +e; generate_xray_config >/dev/null) || exit 11
(set +e; generate_singbox_config >/dev/null) || exit 12
EOF
    bash -n "$fresh"
    (cd "$dir" && bash "$fresh" >"$dir/fresh-render.log" 2>&1) || {
        sed -n '1,60p' "$dir/fresh-render.log" >&2
        fail "fresh process failed to render historical DB"
    }
}
assert_fresh_render() {
    local dir=$1 db_sha_before=$2 marker="$dir/fresh-render.marker"
    [[ -s "$marker" ]] || fail "fresh process marker missing"
    grep -Fxq "version=$CANDIDATE_VERSION" "$marker" || fail "fresh process did not load candidate version"
    grep -Fxq "cfg=$dir/cfg" "$marker" || fail "fresh process did not use isolated historical CFG"
    grep -Fxq "function_sha=$CANDIDATE_FUNCTION_SHA" "$marker" || fail "fresh process did not load candidate renderer functions"
    ! grep -Fq "$H13_FUNCTION_SHA" "$marker" || fail "fresh process loaded H13 renderer functions"
    [[ "$(sha "$dir/runner.sh")" == "$CANDIDATE_SHA" ]] || fail "fresh render modified installed candidate bytes"
    [[ "$(sha "$dir/cfg/db.json")" == "$db_sha_before" ]] || fail "fresh render mutated historical DB"
    jq -e '
      [.inbounds[] | select(.tag=="ss-legacy-18388")] as $ss |
      [.inbounds[] | select(.tag=="vless-ws-notls-18443")] as $vw |
      ($ss|length)==1 and ($ss[0].settings.clients|length)==2 and
      ([$ss[0].settings.clients[].password]|sort)==(["legacy-default","legacy-second"]|sort) and
      ($ss[0].settings|has("password")|not) and
      ($vw|length)==1 and ($vw[0].settings.clients|length)==1 and
      $vw[0].settings.clients[0].id=="22222222-2222-4222-8222-222222222222" and
      ([..|scalars|tostring] | any(.=="legacy-top-secret" or .=="legacy-disabled" or .=="legacy-expired" or .=="33333333-3333-4333-8333-333333333333") | not)
    ' "$dir/cfg/config.json" >/dev/null || fail "fresh Xray render does not match preserved active historical users"
    jq -e '
      [.inbounds[] | select(.type=="anytls")] as $a |
      ($a|length)==1 and ($a[0].users|length)==1 and
      $a[0].users[0].name=="active" and $a[0].users[0].password=="anytls-active" and
      ([..|scalars|tostring] | any(.=="old-top" or .=="anytls-disabled" or .=="anytls-expired") | not)
    ' "$dir/cfg/singbox.json" >/dev/null || fail "fresh sing-box render does not match preserved active historical users"
    ok "success fresh process reloads exact installed H14 renderer functions"
    ok "success fresh process re-renders Xray and sing-box credentials without mutating DB"
}
run_scenario() {
    local name=$1 mode=$2 expected_rc=$3 dir rc=0 db_sha_before
    dir="$TMP/$name"
    make_runner "$dir" "$mode"
    db_sha_before=$(sha "$dir/cfg/db.json")
    : >"$dir/apply.log"
    (cd "$dir" && bash "$dir/runner.sh" <<<'' >"$dir/output.log" 2>&1) || rc=$?
    [[ "$rc" == "$expected_rc" ]] || fail "$name returned $rc, expected $expected_rc"
    ok "$name returns $expected_rc"
    [[ "$(sha256sum "$dir/runner.sh" | awk '{print $1}')" == "$CANDIDATE_SHA" ]] || fail "$name did not install exact candidate bytes"
    ok "$name installs exact working-tree candidate bytes"
    [[ -f "$dir/runner.sh.bak" ]] || fail "$name omitted backup"
    grep -Fq 'source ' "$dir/runner.sh.bak" || fail "$name backup is not exact pre-update transaction caller"
    grep -Fq 'do_update' "$dir/runner.sh.bak" || fail "$name backup lost updater invocation"
    ok "$name preserves exact pre-update caller backup"
    [[ "$(tr '\n' ',' <"$dir/apply.log")" == 'init_db,xray,singbox,' ]] || fail "$name did not attempt all apply helpers"
    ok "$name attempts all apply helpers in order"
    jq -e '.xray["ss-legacy"].users | length == 4' "$dir/cfg/db.json" >/dev/null || fail "$name lost historical DB users"
    ok "$name preserves historical multi-user DB state"
    if [[ "$mode" == normal ]]; then
        grep -Fq '✓ 更新完成' "$dir/output.log" || fail "$name lacks completion receipt"
        [[ ! -e "$dir/cfg/config.json" && ! -e "$dir/cfg/singbox.json" ]] || fail "$name spy unexpectedly created derived configs"
        run_fresh_render "$dir"
        assert_fresh_render "$dir" "$db_sha_before"
    else
        grep -Fq '脚本已更新，但自动应用失败' "$dir/output.log" || fail "$name lacks partial-failure receipt"
        [[ ! -e "$dir/fresh-render.marker" ]] || fail "$name partial failure falsely claimed fresh render"
        ok "$name reports partial failure without rolling back candidate"
    fi
}

printf '########## real %s -> %s stateful updater transaction ##########\n' "$BASE_LABEL" "$CANDIDATE_VERSION"
run_scenario success normal 0
run_scenario partial-failure fail-xray 1
printf 'PASS: real-artifact stateful upgrade (%d assertions; %s=%s candidate=%s)\n' "$pass" "$BASE_LABEL" "$BASE_EXPECTED_SHA" "$CANDIDATE_SHA"
