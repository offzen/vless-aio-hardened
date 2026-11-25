#!/usr/bin/env bash
# Fast source-derived coverage contract for every registered protocol identifier.
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PRODUCT=${PRODUCT_UNDER_TEST:-$ROOT/vless-server.sh}
MANIFEST=${MANIFEST_UNDER_TEST:-$ROOT/tests/protocol-capabilities.tsv}
SELF_MUTATE=1
ONLY_INVENTORY=0
FILTER_PROTO=""
while (($#)); do
    case "$1" in
        --only-inventory) ONLY_INVENTORY=1; shift ;;
        --no-self-mutate) SELF_MUTATE=0; shift ;;
        --filter-proto) FILTER_PROTO=${2:?}; shift 2 ;;
        *) echo "FAIL: unknown argument: $1" >&2; exit 2 ;;
    esac
done
for dep in awk base64 diff grep jq sed sort; do
    command -v "$dep" >/dev/null 2>&1 || { echo "FAIL: missing dependency: $dep" >&2; exit 2; }
done
[[ -f "$PRODUCT" && -f "$MANIFEST" ]] || { echo "FAIL: product or manifest missing" >&2; exit 2; }

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass=0
ok() { pass=$((pass + 1)); printf '  OK   %s\n' "$1"; }

extract_registry() {
    awk '
      /^XRAY_PROTOCOLS="/ {g="xray"}
      /^SINGBOX_PROTOCOLS="/ {g="singbox"}
      /^STANDALONE_PROTOCOLS="/ {g="standalone"}
      g != "" {
        s=$0; sub(/^[^=]*="/, "", s); sub(/"[[:space:]]*$/, "", s)
        n=split(s,a,/ +/); for(i=1;i<=n;i++) if(a[i] != "") print a[i] "\t" g
        g=""
      }
    ' "$PRODUCT"
}
extract_manifest_inventory() {
    awk -F '\t' '
      /^[[:space:]]*#/ || /^[[:space:]]*$/ {next}
      NF != 6 {printf "manifest line %d has %d columns, expected 6\n", NR, NF > "/dev/stderr"; exit 2}
      $1 !~ /^[a-z0-9][a-z0-9-]*$/ {printf "invalid protocol id at line %d\n", NR > "/dev/stderr"; exit 2}
      $2 !~ /^(xray|singbox|standalone)$/ {printf "invalid engine at line %d\n", NR > "/dev/stderr"; exit 2}
      $3 !~ /^(supported|unsupported|rejected)$/ {printf "invalid user contract at line %d\n", NR > "/dev/stderr"; exit 2}
      {print $1 "\t" $2}
    ' "$MANIFEST"
}
assert_unique_ids() {
    local label=$1 input=$2 duplicate
    duplicate=$(awk -F '\t' 'seen[$1]++ {print $1; exit}' <<<"$input")
    [[ -z "$duplicate" ]] || fail "$label contains duplicate identifier: $duplicate"
}
check_inventory() {
    local source_rows manifest_rows delta
    source_rows=$(extract_registry)
    manifest_rows=$(extract_manifest_inventory)
    [[ -n "$source_rows" ]] || fail "source registry extraction returned no rows"
    [[ -n "$manifest_rows" ]] || fail "capability manifest returned no rows"
    assert_unique_ids source "$source_rows"
    assert_unique_ids manifest "$manifest_rows"
    if ! delta=$(diff -u <(sort <<<"$source_rows") <(sort <<<"$manifest_rows")); then
        fail $'source registry and capability manifest differ:\n'"$delta"
    fi
    ok "source registry equals capability manifest without fixed protocol count"
}

function_body() {
    local name=$1
    case "$name" in
        _gen_user_share_link) sed -n '/^_gen_user_share_link()/,/^}/p' "$PRODUCT" ;;
        _show_user_share_links) sed -n '/^_show_user_share_links()/,/^}/p' "$PRODUCT" ;;
        gen_xray_ss_legacy_clients) sed -n '/^gen_xray_ss_legacy_clients()/,/^}/p' "$PRODUCT" ;;
        db_add_user) sed -n '/^db_add_user()/,/^}/p' "$PRODUCT" ;;
        add_xray_inbound_v2) sed -n '/^add_xray_inbound_v2()/,/^    # 验证生成的 inbound JSON/p' "$PRODUCT" ;;
        *) return 2 ;;
    esac
}
case_labels() {
    sed -n 's/^[[:space:]]*\([a-z0-9|-]*\))[[:space:]].*/\1/p' | tr '|' '\n' | sed '/^$/d'
}
renderer_labels() {
    sed -n 's/^[[:space:]]*\([a-z0-9-][a-z0-9|-]*\))[[:space:]]*$/\1/p' | tr '|' '\n' | sed '/^$/d'
}
manifest_supported() { awk -F '\t' '$1 !~ /^#/ && $3=="supported" {print $1}' "$MANIFEST" | sort; }
manifest_unsupported() { awk -F '\t' '$1 !~ /^#/ && $3=="unsupported" {print $1}' "$MANIFEST" | sort; }
manifest_rejected() { awk -F '\t' '$1 !~ /^#/ && $3=="rejected" {print $1}' "$MANIFEST" | sort; }

check_dispatch_completeness() {
    local link_cases renderer_cases expected missing="" proto
    link_cases=$(function_body _gen_user_share_link | case_labels | sort -u)
    renderer_cases=$(function_body add_xray_inbound_v2 | renderer_labels | sort -u)
    expected=$(manifest_supported)
    while IFS= read -r proto; do
        [[ -n "$proto" ]] || continue
        grep -Fqx "$proto" <<<"$link_cases" || missing+=" link:$proto"
        if awk -F '\t' -v p="$proto" '$1==p && $2=="xray" {found=1} END{exit !found}' "$MANIFEST"; then
            grep -Fqx "$proto" <<<"$renderer_cases" || missing+=" renderer:$proto"
        fi
    done <<<"$expected"
    [[ -z "$missing" ]] || fail "supported protocol lacks direct dispatch:$missing"
    ok "every supported identifier has direct share-link and renderer dispatch"

    local unsupported_cases renderer_family
    unsupported_cases=$(manifest_unsupported)
    while IFS= read -r proto; do
        [[ -n "$proto" ]] || continue
        renderer_family=$(awk -F '\t' -v p="$proto" '$1==p {print $5}' "$MANIFEST")
        if [[ "$renderer_family" != xray-top-password ]]; then
            ! grep -Fqx "$proto" <<<"$link_cases" || fail "$proto is classified unsupported but has a direct user-link dispatch"
        fi
    done <<<"$unsupported_cases"
    ok "partial identifiers are explicitly classified unsupported, never silently aliased"

    local user_contract_guard
    user_contract_guard=$(function_body db_add_user)
    grep -Fq 'supports_per_user_management "$proto"' <<<"$user_contract_guard" || fail "db_add_user lost fail-closed per-user policy guard"
    while IFS= read -r proto; do
        grep -Fqx "$proto" <<<"$(extract_registry | awk -F '\t' '$2=="standalone"{print $1}')" || fail "$proto is classified rejected but is not standalone"
    done < <(manifest_rejected)
    ok "all rejected identifiers are source-registered standalone protocols"
}

check_static_contracts() {
    local body
    body=$(function_body _show_user_share_links)
    grep -Fq '_gen_user_share_link "$core" "$proto" "$uuid" "$user" "$port"' <<<"$body" || fail "menu no longer passes selected user credential and port to URI dispatcher"
    ok "menu binds selected DB credential and port to URI generation"

    body=$(function_body gen_xray_ss_legacy_clients)
    grep -Fq 'select((if .enabled == null then true else .enabled end) == true)' <<<"$body" || fail "ss-legacy active-user filter missing"
    grep -Fq '.expire_date >= $today' <<<"$body" || fail "ss-legacy expiry filter missing"
    ok "ss-legacy renderer retains active/expiry filter contract"

    body=$(function_body add_xray_inbound_v2)
    grep -Fq 'if [[ -z "$legacy_clients" || "$legacy_clients" == "[]" ]]' <<<"$body" || fail "ss-legacy explicit-user fail-closed guard missing"
    grep -Fq '{clients: $clients}' <<<"$body" || fail "Xray client-array renderer contract missing"
    ok "renderer retains client-array and ss-legacy fail-closed contracts"
}

run_existing_protocol_receipts() {
    [[ -z "$FILTER_PROTO" || "$FILTER_PROTO" == ss-legacy ]] || return 0
    bash "$ROOT/tests/test-ss-legacy-users.sh" "$PRODUCT" >/dev/null
    ok "dynamic ss-legacy DB to URI to renderer contract"
    [[ -z "$FILTER_PROTO" ]] || return 0
    bash "$ROOT/tests/test-high-risk-repair.sh" "$PRODUCT" >/dev/null
    ok "dynamic Xray UUID renderer isolation contract"
    bash "$ROOT/tests/test-singbox-users.sh" "$PRODUCT" >/dev/null
    ok "dynamic sing-box active/disabled/expired and multi-port contract"
}

assert_mutant_fails() {
    local label=$1; shift
    if "$@" >/dev/null 2>&1; then fail "mutation escaped: $label"; fi
    ok "mutation rejected: $label"
}
run_mutations() {
    local tmp=$1
    sed 's/XRAY_PROTOCOLS="/XRAY_PROTOCOLS="phantom-contract /' "$PRODUCT" >"$tmp/extra-proto.sh"
    assert_mutant_fails source-inventory env PRODUCT_UNDER_TEST="$tmp/extra-proto.sh" MANIFEST_UNDER_TEST="$MANIFEST" bash "$0" --only-inventory --no-self-mutate

    sed '/^vless\txray\t/a stale-protocol\txray\tsupported\tvless-reality\txray-vless-clients\txray-uuid' "$MANIFEST" >"$tmp/stale.tsv"
    assert_mutant_fails stale-manifest env PRODUCT_UNDER_TEST="$PRODUCT" MANIFEST_UNDER_TEST="$tmp/stale.tsv" bash "$0" --only-inventory --no-self-mutate

    sed '/^[[:space:]]*vless-ws) link=\$(gen_vless_ws_link/d' "$PRODUCT" >"$tmp/missing-link.sh"
    assert_mutant_fails missing-link-dispatch env PRODUCT_UNDER_TEST="$tmp/missing-link.sh" MANIFEST_UNDER_TEST="$MANIFEST" bash "$0" --no-self-mutate

    sed 's/select((if \.enabled == null then true else \.enabled end) == true) |/./' "$PRODUCT" >"$tmp/disabled-leak.sh"
    assert_mutant_fails disabled-filter env PRODUCT_UNDER_TEST="$tmp/disabled-leak.sh" MANIFEST_UNDER_TEST="$MANIFEST" bash "$0" --no-self-mutate --filter-proto ss-legacy

    sed '/if \[\[ -z "$legacy_clients" || "$legacy_clients" == "\[\]" \]\]; then/,/^[[:space:]]*fi$/d' "$PRODUCT" >"$tmp/fail-open.sh"
    assert_mutant_fails fail-open env PRODUCT_UNDER_TEST="$tmp/fail-open.sh" MANIFEST_UNDER_TEST="$MANIFEST" bash "$0" --no-self-mutate --filter-proto ss-legacy
}

check_inventory
((ONLY_INVENTORY == 0)) || { printf 'PASS: protocol capability inventory (%d assertion)\n' "$pass"; exit 0; }
check_dispatch_completeness
check_static_contracts
run_existing_protocol_receipts
if ((SELF_MUTATE)); then
    TMP=$(mktemp -d "${TMPDIR:-/tmp}/aio-protocol-contract.XXXXXX")
    trap 'rm -rf -- "$TMP"' EXIT INT TERM
    run_mutations "$TMP"
fi
printf 'PASS: source-derived protocol capability contract (%d assertions)\n' "$pass"
