#!/usr/bin/env bash
# Manifest-driven per-user product policy and dynamic credential contract.
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PRODUCT=${PRODUCT_UNDER_TEST:-$ROOT/vless-server.sh}
MANIFEST=${MANIFEST_UNDER_TEST:-$ROOT/tests/protocol-capabilities.tsv}
[[ -f "$PRODUCT" && -f "$MANIFEST" ]] || { echo "FAIL: product or manifest missing" >&2; exit 2; }
for dep in awk grep jq sha256sum; do
    command -v "$dep" >/dev/null 2>&1 || { echo "FAIL: missing dependency: $dep" >&2; exit 2; }
done

TMP=$(mktemp -d "${TMPDIR:-/tmp}/aio-per-user-contract.XXXXXX")
TMP=$(cd -- "$TMP" && pwd -P) || exit 2
trap '[[ "$TMP" == /tmp/* ]] && rm -rf -- "$TMP"' EXIT INT TERM
SCRIPT_COPY="$TMP/vless-server.sh"
cp "$PRODUCT" "$SCRIPT_COPY"
mkdir -p "$TMP/cfg"
export VLESS_SOURCE_ONLY=1 VLESS_TEST_CFG="$TMP/cfg" VLESS_TEST_LOG_ROOT="$TMP/log"
# shellcheck disable=SC1090
source "$SCRIPT_COPY"
[[ "$CFG" == "$TMP/cfg" ]] || { echo 'FAIL: VLESS_TEST_CFG isolation' >&2; exit 2; }
set +e

pass=0
failures=0
ok() { pass=$((pass + 1)); printf '  OK   %s\n' "$1"; }
fail() { failures=$((failures + 1)); printf '  FAIL %s\n' "$1" >&2; }
check() {
    local label=$1
    shift
    if "$@"; then ok "$label"; else fail "$label"; fi
}

if ! declare -F supports_per_user_management >/dev/null; then
    echo 'FAIL: supports_per_user_management product policy helper is missing' >&2
    exit 1
fi

printf '########## 1. Product policy equals manifest ##########\n'
while IFS=$'\t' read -r proto engine contract uri renderer cluster; do
    [[ -z "$proto" || "$proto" == \#* ]] && continue
    case "$contract" in
        supported)
            check "$proto is admitted by product policy" supports_per_user_management "$proto"
            ;;
        unsupported|rejected)
            if supports_per_user_management "$proto"; then
                fail "$proto is denied by product policy"
            else
                ok "$proto is denied by product policy"
            fi
            ;;
        *)
            fail "$proto has unknown manifest contract: $contract"
            ;;
    esac
done < "$MANIFEST"

printf '\n########## 2. Partial identifiers stay out of user selector ##########\n'
cat > "$DB_FILE" <<'JSON'
{
  "xray": {
    "vless": {"port":14443,"uuid":"11111111-1111-4111-8111-111111111111"},
    "vless-xhttp-cdn": {"port":14444,"uuid":"22222222-2222-4222-8222-222222222222"},
    "vless-ws-notls": {"port":14445,"uuid":"33333333-3333-4333-8333-333333333333"},
    "trojan-ws": {"port":14446,"password":"partial-trojan"},
    "ss2022": {"port":14447,"password":"partial-ss","method":"2022-blake3-aes-128-gcm"}
  },
  "singbox": {}
}
JSON
get_protocol_name() { printf '%s\n' "$1"; }
selector_output=$(printf '1\n' | _select_protocol_for_users 2>&1)
selector_rc=$?
check 'selector succeeds when one supported protocol remains' test "$selector_rc" -eq 0
check 'selector retains the supported protocol' grep -Fq 'vless ' <<< "$selector_output"
for partial in vless-xhttp-cdn vless-ws-notls trojan-ws ss2022; do
    if grep -Fq "$partial" <<< "$selector_output"; then
        fail "selector hides $partial"
    else
        ok "selector hides $partial"
    fi
done
jq 'del(.xray.vless)' "$DB_FILE" > "$TMP/partial-only.json" && mv "$TMP/partial-only.json" "$DB_FILE"
partial_only_output=$(printf '0\n' | _select_protocol_for_users 2>&1)
partial_only_rc=$?
check 'selector fails when only partial identifiers are installed' test "$partial_only_rc" -ne 0
check 'selector explains that no per-user protocol is available' grep -Fq '没有支持逐用户管理的已安装协议' <<< "$partial_only_output"

printf '\n########## 3. db_add_user rejects partial identifiers without mutation ##########\n'
rebuild_and_reload_xray() { :; }
rebuild_and_reload_singbox() { :; }
for partial in vless-xhttp-cdn vless-ws-notls trojan-ws ss2022; do
    before=$(sha256sum "$DB_FILE" | awk '{print $1}')
    db_add_user xray "$partial" rejected-user rejected-credential 0 '' >/dev/null 2>&1
    rc=$?
    after=$(sha256sum "$DB_FILE" | awk '{print $1}')
    check "db_add_user rejects $partial" test "$rc" -ne 0
    check "db_add_user leaves DB unchanged for $partial" test "$after" = "$before"
done

printf '\n'
if [[ "$failures" -eq 0 ]]; then
    printf 'PASS: per-user product policy contract (%d assertions)\n' "$pass"
else
    printf 'FAIL: per-user product policy contract (%d failed, %d passed)\n' "$failures" "$pass" >&2
    exit 1
fi
