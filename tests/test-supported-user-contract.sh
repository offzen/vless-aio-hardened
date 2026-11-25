#!/usr/bin/env bash
# Dynamic DB -> menu/URI -> renderer contract for every manifest-supported identifier.
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PRODUCT=${PRODUCT_UNDER_TEST:-$ROOT/vless-server.sh}
MANIFEST=${MANIFEST_UNDER_TEST:-$ROOT/tests/protocol-capabilities.tsv}
[[ -f "$PRODUCT" && -f "$MANIFEST" ]] || { echo "FAIL: product or manifest missing" >&2; exit 2; }
for dep in awk base64 grep jq sort; do
    command -v "$dep" >/dev/null 2>&1 || { echo "FAIL: missing dependency: $dep" >&2; exit 2; }
done

TMP=$(mktemp -d "${TMPDIR:-/tmp}/aio-supported-contract.XXXXXX")
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
rows=0
ok() { pass=$((pass + 1)); printf '  OK   %s\n' "$1"; }
fail() { failures=$((failures + 1)); printf '  FAIL %s\n' "$1" >&2; }
check() {
    local label=$1
    shift
    if "$@"; then ok "$label"; else fail "$label"; fi
}
check_eq() { [[ "$1" == "$2" ]]; }

_info() { :; }
_ok() { :; }
_warn() { :; }
_err() { :; }
_pause() { :; }
_header() { :; }
_line() { :; }
_dline() { :; }
_item() { :; }
_listen_addr() { printf '127.0.0.1\n'; }
db_get_balancer_groups() { printf '[]\n'; }
db_get_warp_mode() { :; }
db_get_routing_rules() { printf '[]\n'; }
db_ip_routing_enabled() { return 1; }
get_ipv4() { printf '198.51.100.10\n'; }
get_ipv6() { :; }
get_ip_country() { printf 'ZZ\n'; }
qrencode() { return 1; }

readonly CRED_DEFAULT='11111111-1111-4111-8111-000000000001'
readonly CRED_SECOND='11111111-1111-4111-8111-000000000002'
readonly CRED_DISABLED='11111111-1111-4111-8111-000000000003'
readonly CRED_EXPIRED='11111111-1111-4111-8111-000000000004'
readonly CRED_EDGE='11111111-1111-4111-8111-000000000005'
readonly BASE_PORT=21431
readonly EDGE_PORT=21432

mixed_users() {
    jq -cn \
        --arg d "$CRED_DEFAULT" --arg s "$CRED_SECOND" \
        --arg x "$CRED_DISABLED" --arg e "$CRED_EXPIRED" \
        '[
          {name:"default",uuid:$d,enabled:true},
          {name:"second",uuid:$s,enabled:true,expire_date:"2999-12-31"},
          {name:"disabled",uuid:$x,enabled:false},
          {name:"expired",uuid:$e,enabled:true,expire_date:"2000-01-01"}
        ]'
}
inactive_users() {
    jq -cn --arg x "$CRED_DISABLED" --arg e "$CRED_EXPIRED" '[
      {name:"disabled",uuid:$x,enabled:false},
      {name:"expired",uuid:$e,enabled:true,expire_date:"2000-01-01"}
    ]'
}
edge_users() {
    jq -cn --arg c "$CRED_EDGE" '[{name:"edge",uuid:$c,enabled:true}]'
}

protocol_config() {
    local proto=$1 port=$2 users=$3 legacy="00000000-0000-4000-8000-000000000099"
    case "$proto" in
        vless)
            jq -cn --argjson port "$port" --arg u "$legacy" --argjson users "$users" \
                '{port:$port,uuid:$u,sni:"example.com",short_id:"0123456789abcdef",private_key:"test-private",public_key:"test-public",users:$users}' ;;
        vless-xhttp)
            jq -cn --argjson port "$port" --arg u "$legacy" --argjson users "$users" \
                '{port:$port,uuid:$u,sni:"example.com",short_id:"0123456789abcdef",private_key:"test-private",public_key:"test-public",path:"/xhttp",users:$users}' ;;
        vless-ws)
            jq -cn --argjson port "$port" --arg u "$legacy" --argjson users "$users" \
                '{port:$port,uuid:$u,sni:"example.com",path:"/ws",users:$users}' ;;
        vmess-ws)
            jq -cn --argjson port "$port" --arg u "$legacy" --argjson users "$users" \
                '{port:$port,uuid:$u,sni:"example.com",path:"/vmess",users:$users}' ;;
        vless-vision)
            jq -cn --argjson port "$port" --arg u "$legacy" --argjson users "$users" \
                '{port:$port,uuid:$u,sni:"example.com",users:$users}' ;;
        trojan)
            jq -cn --argjson port "$port" --argjson users "$users" \
                '{port:$port,password:"legacy-top-trojan",sni:"example.com",users:$users}' ;;
        socks)
            jq -cn --argjson port "$port" --argjson users "$users" \
                '{port:$port,username:"legacy-user",password:"legacy-top-socks",auth_mode:"password",tls:false,users:$users}' ;;
        ss-legacy)
            jq -cn --argjson port "$port" --argjson users "$users" \
                '{port:$port,method:"aes-256-gcm",password:"legacy-top-ss",users:$users}' ;;
        hy2)
            jq -cn --argjson port "$port" --argjson users "$users" \
                '{port:$port,password:"legacy-top-hy2",sni:"example.com",users:$users}' ;;
        tuic)
            jq -cn --argjson port "$port" --arg u "$legacy" --argjson users "$users" \
                '{port:$port,uuid:$u,password:"legacy-top-tuic",sni:"example.com",users:$users}' ;;
        anytls)
            jq -cn --argjson port "$port" --argjson users "$users" \
                '{port:$port,password:"legacy-top-anytls",sni:"example.com",users:$users}' ;;
        *) return 2 ;;
    esac
}

write_single_fixture() {
    local proto=$1 engine=$2 users=$3 cfg
    cfg=$(protocol_config "$proto" "$BASE_PORT" "$users") || return
    jq -n --arg e "$engine" --arg p "$proto" --argjson cfg "$cfg" \
        '{xray:{},singbox:{}} | .[$e][$p]=$cfg' > "$DB_FILE"
}
write_multi_fixture() {
    local proto=$1 engine=$2 first_users=$3 second_users=$4 first second
    first=$(protocol_config "$proto" "$BASE_PORT" "$first_users") || return
    second=$(protocol_config "$proto" "$EDGE_PORT" "$second_users") || return
    jq -n --arg e "$engine" --arg p "$proto" --argjson first "$first" --argjson second "$second" \
        '{xray:{},singbox:{}} | .[$e][$p]=[$first,$second]' > "$DB_FILE"
}

render() {
    local engine=$1
    rm -f "$CFG/config.json" "$CFG/singbox.json"
    if [[ "$engine" == xray ]]; then generate_xray_config >/dev/null 2>&1
    else generate_singbox_config >/dev/null 2>&1
    fi
}

canonical_credential() {
    local proto=$1 name=$2 credential=$3
    case "$proto" in
        socks) printf '%s:%s\n' "$name" "$credential" ;;
        ss-legacy) printf 'aes-256-gcm:%s\n' "$credential" ;;
        tuic) printf '%s:%s\n' "$credential" "$credential" ;;
        *) printf '%s\n' "$credential" ;;
    esac
}

rendered_credentials() {
    local proto=$1 engine=$2 port=$3 file
    if [[ "$engine" == xray ]]; then
        file="$CFG/config.json"
        [[ -f "$file" ]] || return
        case "$proto" in
            vless|vless-xhttp|vless-ws|vless-vision|vmess-ws)
                jq -r --argjson port "$port" '.inbounds[]? | select(.port==$port) | .settings.clients[]? | .id' "$file" ;;
            trojan)
                jq -r --argjson port "$port" '.inbounds[]? | select(.port==$port) | .settings.clients[]? | .password' "$file" ;;
            socks)
                jq -r --argjson port "$port" '.inbounds[]? | select(.port==$port) | .settings.accounts[]? | "\(.user):\(.pass)"' "$file" ;;
            ss-legacy)
                jq -r --argjson port "$port" '.inbounds[]? | select(.port==$port) | .settings.clients[]? | "\(.method):\(.password)"' "$file" ;;
        esac
    else
        file="$CFG/singbox.json"
        [[ -f "$file" ]] || return
        case "$proto" in
            hy2|anytls)
                jq -r --argjson port "$port" '.inbounds[]? | select(.listen_port==$port) | .users[]? | .password' "$file" ;;
            tuic)
                jq -r --argjson port "$port" '.inbounds[]? | select(.listen_port==$port) | .users[]? | "\(.uuid):\(.password)"' "$file" ;;
        esac
    fi
}

uri_contract() {
    local proto=$1 link=$2 payload rest host port user pass
    case "$proto" in
        vmess-ws)
            payload=${link#vmess://}
            printf '%s' "$payload" | base64 -d 2>/dev/null | jq -r '"\(.id)\t\(.port)"'
            ;;
        socks)
            port=${link#*'&port='}; port=${port%%&*}
            user=${link#*'&user='}; user=${user%%&*}
            pass=${link#*'&pass='}; pass=${pass%%&*}
            printf '%s:%s\t%s\n' "$user" "$pass" "$port"
            ;;
        ss-legacy)
            payload=${link#ss://}; payload=${payload%%@*}
            rest=${link#*@}; host=${rest%%\?*}; host=${host%%#*}; port=${host##*:}
            printf '%s\t%s\n' "$(printf '%s' "$payload" | base64 -d 2>/dev/null)" "$port"
            ;;
        *)
            payload=${link#*://}; payload=${payload%%@*}
            rest=${link#*@}; host=${rest%%\?*}; host=${host%%#*}; port=${host##*:}
            printf '%s\t%s\n' "$payload" "$port"
            ;;
    esac
}

printf '########## Manifest-supported dynamic contracts ##########\n'
while IFS=$'\t' read -r manifest_proto manifest_engine contract uri_family renderer_family auth_cluster; do
    [[ -z "$manifest_proto" || "$manifest_proto" == \#* || "$contract" != supported ]] && continue
    row_proto=$manifest_proto
    row_engine=$manifest_engine
    rows=$((rows + 1))
    printf '\n==> %s (%s / %s / %s)\n' "$row_proto" "$row_engine" "$renderer_family" "$auth_cluster"

    write_single_fixture "$row_proto" "$row_engine" "$(mixed_users)" || { fail "$row_proto fixture builds"; continue; }
    render "$row_engine"
    actual=$(rendered_credentials "$row_proto" "$row_engine" "$BASE_PORT" | sort)
    expected=$(printf '%s\n%s\n' \
        "$(canonical_credential "$row_proto" default "$CRED_DEFAULT")" \
        "$(canonical_credential "$row_proto" second "$CRED_SECOND")" | sort)
    check "$row_proto renderer keeps exactly two active credentials" check_eq "$actual" "$expected"
    rendered_file="$CFG/config.json"; [[ "$row_engine" == singbox ]] && rendered_file="$CFG/singbox.json"
    if [[ -f "$rendered_file" ]] && ! grep -Fq "$CRED_DISABLED" "$rendered_file" && ! grep -Fq "$CRED_EXPIRED" "$rendered_file"; then
        ok "$row_proto renderer excludes disabled and expired credentials"
    else
        fail "$row_proto renderer excludes disabled and expired credentials"
    fi

    for pair in "default:$CRED_DEFAULT" "second:$CRED_SECOND"; do
        name=${pair%%:*}; credential=${pair#*:}
        link=$(_gen_user_share_link "$row_engine" "$row_proto" "$credential" "$name" "$BASE_PORT")
        actual_uri=$(uri_contract "$row_proto" "$link")
        expected_uri="$(canonical_credential "$row_proto" "$name" "$credential")"$'\t'"$BASE_PORT"
        check "$row_proto URI binds $name credential and port" check_eq "$actual_uri" "$expected_uri"
    done

    menu_output=$(printf 'a\n0\n' | _show_user_share_links "$row_engine" "$row_proto" 2>&1)
    check "$row_proto menu includes default" grep -Fq 'default:' <<< "$menu_output"
    check "$row_proto menu includes second" grep -Fq 'second:' <<< "$menu_output"
    if grep -Eq '(disabled|expired):' <<< "$menu_output"; then
        fail "$row_proto menu excludes disabled and expired users"
    else
        ok "$row_proto menu excludes disabled and expired users"
    fi

    write_multi_fixture "$row_proto" "$row_engine" "$(inactive_users)" "$(edge_users)" || { fail "$row_proto multi-port fixture builds"; continue; }
    render "$row_engine"
    base_actual=$(rendered_credentials "$row_proto" "$row_engine" "$BASE_PORT" | sort)
    edge_actual=$(rendered_credentials "$row_proto" "$row_engine" "$EDGE_PORT" | sort)
    edge_expected=$(canonical_credential "$row_proto" edge "$CRED_EDGE")
    check "$row_proto inactive first port fails closed" check_eq "$base_actual" ''
    check "$row_proto second port keeps only its active credential" check_eq "$edge_actual" "$edge_expected"
    edge_link=$(_gen_user_share_link "$row_engine" "$row_proto" "$CRED_EDGE" edge "$EDGE_PORT")
    edge_uri=$(uri_contract "$row_proto" "$edge_link")
    edge_uri_expected="$edge_expected"$'\t'"$EDGE_PORT"
    check "$row_proto multi-port URI selects matching instance" check_eq "$edge_uri" "$edge_uri_expected"
done < "$MANIFEST"

[[ "$rows" -gt 0 ]] || { echo 'FAIL: manifest yielded no supported rows' >&2; exit 1; }
printf '\n'
if [[ "$failures" -eq 0 ]]; then
    printf 'PASS: manifest-supported dynamic user contract (%d rows; %d assertions)\n' "$rows" "$pass"
else
    printf 'FAIL: manifest-supported dynamic user contract (%d rows; %d failed, %d passed)\n' "$rows" "$failures" "$pass" >&2
    exit 1
fi
