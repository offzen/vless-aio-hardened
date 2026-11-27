#!/usr/bin/env bash
# H19 审计复核回归与扩展变异自检测试（覆盖 H18 复核确认缺陷 D2/D3/D4/D5/D7/D8/D9/D10/D11/D12 + M5–M10）：
#   D4/D5/R03: 聚合失败保留 traffic.pending 不丢账、二次重放幂等、单遍整库 jq 配额读取（O(D)）、配额读取失败非静默传播
#   D8/D12/F04: _regenerate_proxy_configs 与按端口卸载全入口遵守 paused/admin-stopped 守卫 + running 重启失败保留 auto-stop 标记
#   D2/D3/F03: _handle_standalone_cert / gen_self_cert 保护缺中间链的非自签证书不被删毁 + 残余 issuer 字符串清理验证
#   D9/D10/D11/F06: Clash YAML <-> share-link <-> Clash YAML gRPC serviceName 往返（VLESS/VMess/Trojan）、server URI 结构字符拒绝、丢节点告警诊断
#   M5–M10: 补齐 F02/F06/F07/F08/R03(D4)/F04(D8) 防假绿变异自检
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")/.." && pwd)
PRODUCT="${1:-$ROOT/vless-server.sh}"
[[ -f "$PRODUCT" ]] || { echo "FAIL: missing product: $PRODUCT" >&2; exit 2; }
for dep in jq awk grep sed openssl sha256sum mktemp base64; do
    command -v "$dep" >/dev/null 2>&1 || { echo "FAIL: missing dependency: $dep" >&2; exit 2; }
done

TMP=$(mktemp -d "${TMPDIR:-/tmp}/aio-h19-reg.XXXXXX")
TMP=$(cd -- "$TMP" && pwd -P) || exit 2
trap '[[ "$TMP" == /tmp/* || "$TMP" == "${TMPDIR:-/nonexistent}"/* ]] && rm -rf -- "$TMP"' EXIT

RESULTS="$TMP/results.log"
: >"$RESULTS"

fresh_env() {
    local name="$1"
    SEC="$TMP/$name"
    mkdir -p "$SEC/cfg" "$SEC/log" "$SEC/bin"
    export VLESS_SOURCE_ONLY=1 VLESS_TEST_CFG="$SEC/cfg" VLESS_TEST_LOG_ROOT="$SEC/log"
    cp "$PRODUCT" "$SEC/product.sh"
    # shellcheck disable=SC1090
    source "$SEC/product.sh"
    set +u
    [[ "$CFG" == "$SEC/cfg" ]] || { echo "FAIL isolation" >>"$RESULTS"; exit 2; }
    _ok() { printf 'OK: %s\n' "$*"; }
    _info() { printf 'INFO: %s\n' "$*"; }
    _warn() { printf 'WARN: %s\n' "$*" >&2; }
    _err() { printf 'ERR: %s\n' "$*" >&2; }
    _log() { :; }; _pause() { :; }; _header() { :; }; _line() { :; }; _dline() { :; }; _item() { :; }
    export PATH="$SEC/bin:$PATH"
    crontab() { echo "crontab $*" >>"$TMP/crontab-guard.log"; return 1; }
    ensure_expire_check_cron() { :; }; ensure_traffic_cron() { :; }
}

check() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "OK   $desc" >>"$RESULTS"; printf '  OK   %s\n' "$desc"
    else
        echo "FAIL $desc" >>"$RESULTS"; printf '  FAIL %s\n' "$desc" >&2
    fi
}
eq() { [[ "$1" == "$2" ]]; }
write_db() { cat >"$DB_FILE"; chmod 600 "$DB_FILE"; }

# ═════════════ D4 & D5 & R03: 聚合失败保账 + 重放幂等 + 单遍整库配额读 ═════════════
sec_d4_d5_traffic_integrity() ( fresh_env d4d5
    _pgrep() { return 1; }; check_daily_report() { :; }; tg_get_config() { echo 80; }
    tg_send_over_quota() { :; }; tg_send_quota_alert() { :; }
    svc() { return 0; }; generate_xray_config() { return 0; }
    mkdir -p "$CFG/cache"

    write_db <<'J'
{"version":"4.0.0","xray":{"vless":{"port":443,"uuid":"u0","users":[
 {"name":"u1","uuid":"u1","quota":1000,"used":0,"enabled":true},
 {"name":"u2","uuid":"u2","quota":500,"used":0,"enabled":true},
 {"name":"u3","uuid":"u3","quota":2000,"used":0,"enabled":true},
 {"name":"u4","uuid":"u4","quota":2000,"used":0,"enabled":true},
 {"name":"u5","uuid":"u5","quota":2000,"used":0,"enabled":true}]}},"singbox":{},"meta":{}}
J
    cat >"$CFG/cache/traffic.pending" <<'P'
user>>>u1@vless>>>traffic>>>uplink 120 b-1
user>>>u1@vless>>>traffic>>>downlink 280 b-2
user>>>u2@vless>>>traffic>>>uplink 300 b-3
user>>>u2@vless>>>traffic>>>downlink 300 b-4
P
    orig_pending_sha=$(sha256sum "$CFG/cache/traffic.pending" | awk '{print $1}')

    # (a) D4: 聚合阶段 jq -Rrn 失败 → 必须返回非 0，且 traffic.pending 逐字节保留不截断
    REAL_JQ=$(command -v jq)
    jq() {
        if [[ "${1:-}" == "-Rrn" ]]; then return 2; fi
        "$REAL_JQ" "$@"
    }
    warn_out=$(sync_all_user_traffic 2>&1); rc=$?
    unset -f jq
    check 'D4a aggregation failure returns non-zero' test "$rc" -ne 0
    check 'D4a aggregation failure emits warning' grep -Fq '已保留原日志' <<<"$warn_out"
    check 'D4a aggregation failure preserves traffic.pending byte-for-byte' \
        eq "$(sha256sum "$CFG/cache/traffic.pending" | awk '{print $1}')" "$orig_pending_sha"
    check 'D4a u1/u2 DB used stays 0 after failed aggregation' \
        bash -c '[[ "$1" == "0" && "$2" == "0" ]]' _ "$(db_get_user_field xray vless u1 used)" "$(db_get_user_field xray vless u2 used)"

    # (b) 写库失败部分保留 + 二次重放幂等验证（修复 H18 测试未重放的缺口）
    FAIL_USER="u2"
    eval "orig_$(declare -f db_update_user_traffic)"
    db_update_user_traffic() {
        if [[ "$3" == "$FAIL_USER" ]]; then return 1; fi
        orig_db_update_user_traffic "$@"
    }
    sync_all_user_traffic >/dev/null 2>&1; rc=$?
    check 'R03b partial write failure returns non-zero' test "$rc" -ne 0
    check 'R03b u1 credited 400 while failed u2 stays 0' \
        bash -c '[[ "$1" == "400" && "$2" == "0" ]]' _ "$(db_get_user_field xray vless u1 used)" "$(db_get_user_field xray vless u2 used)"
    check 'R03b failed u2 lines retained in traffic.pending' grep -Fq 'user>>>u2@vless>>>traffic>>>uplink' "$CFG/cache/traffic.pending"

    # 故意把已入账的 u1 条目（含相同幂等 ID b-1/b-2）重新混入 pending 后重试
    printf 'user>>>u1@vless>>>traffic>>>uplink 120 b-1\nuser>>>u1@vless>>>traffic>>>downlink 280 b-2\n' >>"$CFG/cache/traffic.pending"
    FAIL_USER=""
    sync_all_user_traffic >/dev/null 2>&1; rc=$?
    check 'R03b replay retry succeeds with rc=0' eq "$rc" 0
    check 'R03b replayed u1 IDs are NOT double-counted (still 400)' eq "$(db_get_user_field xray vless u1 used)" "400"
    check 'R03b retried u2 credited 600 and disabled (>= quota 500)' \
        bash -c '[[ "$1" == "600" && "$2" == "false" ]]' _ "$(db_get_user_field xray vless u2 used)" "$(db_get_user_field xray vless u2 enabled)"
    check 'R03b traffic.pending is emptied after full success' test ! -s "$CFG/cache/traffic.pending"

    # (c) D5: 5 个活跃用户同步时，Phase 2 配额/告警状态读取仅对 $DB_FILE 执行 1 次 jq（非 O(U*D)）
    FAIL_USER=""
    cat >"$CFG/cache/traffic.pending" <<'P'
user>>>u1@vless>>>traffic>>>uplink 10 c-1
user>>>u3@vless>>>traffic>>>uplink 10 c-3
user>>>u4@vless>>>traffic>>>uplink 10 c-4
user>>>u5@vless>>>traffic>>>uplink 10 c-5
P
    JQ_STATE_READS="$SEC/jq_state.log"; : >"$JQ_STATE_READS"
    jq() {
        if [[ "$*" == *"quota_exceeded_notified"* ]]; then
            echo "state-read" >>"$JQ_STATE_READS"
        fi
        "$REAL_JQ" "$@"
    }
    sync_all_user_traffic >/dev/null 2>&1; rc=$?
    unset -f jq
    check 'D5c 4-user sync succeeds' eq "$rc" 0
    check 'D5c quota/alert state DB scan runs exactly once (O(D), not O(U*D))' \
        eq "$(wc -l <"$JQ_STATE_READS" | tr -d ' ')" "1"

    # (d) D5: Phase 2 配额状态读取 jq 失败时必须传播非 0 并告警（不再被 || true 静默吞掉）
    printf 'user>>>u3@vless>>>traffic>>>uplink 10 d-3\n' >"$CFG/cache/traffic.pending"
    jq() {
        if [[ "$*" == *"quota_exceeded_notified"* ]]; then return 3; fi
        "$REAL_JQ" "$@"
    }
    qerr=$(sync_all_user_traffic 2>&1); rc=$?
    unset -f jq
    check 'D5d quota state jq failure propagates non-zero rc' test "$rc" -ne 0
    check 'D5d quota state jq failure emits warning' grep -Fq '读取用户配额状态失败' <<<"$qerr"
)

# ═════════════ D8 & D12: F04 全入口 paused 守卫与标记生命周期 ═════════════
sec_d8_d12_f04_closure() ( fresh_env d8d12
    mkdir -p "$CFG/certs/hy2"
    echo c >"$CFG/certs/hy2/server.crt"; echo k >"$CFG/certs/hy2/server.key"
    write_db <<'J'
{"version":"4.0.0",
 "xray":{"vless":{"port":443,"uuid":"11111111-1111-4111-8111-111111111111","sni":"x.example","private_key":"pk","public_key":"pub","short_id":"ab"}},
 "singbox":{"hy2":{"port":24443,"password":"p","sni":"h.example","users":[{"name":"u1","uuid":"pw-u1","enabled":true}]},
            "tuic":{"port":24444,"uuid":"22222222-2222-4222-8222-222222222222","password":"tpw","sni":"h.example","users":[{"name":"t1","uuid":"22222222-2222-4222-8222-222222222222","password":"tpw","enabled":true}]}},
 "meta":{}}
J
    XR_ACTIVE="$SEC/xr.active"
    SB_ACTIVE="$SEC/sb.active"
    RESTART_FAIL="$SEC/sb.restart.fail"
    SVC="$SEC/svc.log"; : >"$SVC"
    generate_xray_config() { echo '{"xray":"ok"}' >"$CFG/config.json"; return 0; }
    generate_singbox_config() { echo '{"sb":"ok"}' >"$CFG/singbox.json"; return 0; }
    _traffic_collect_to_journal() { return 0; }
    _collect_hy2_nat_rules() { :; }
    _delete_hy2_nat_rules_list() { :; }
    cleanup_protocol_cert_if_unused() { :; }

    svc() {
        echo "svc $*" >>"$SVC"
        local act="$1" name="$2"
        case "$name:$act" in
            vless-reality:status) [[ -e "$XR_ACTIVE" ]] ;;
            vless-reality:stop) rm -f "$XR_ACTIVE"; return 0 ;;
            vless-reality:start|vless-reality:restart) : >"$XR_ACTIVE"; return 0 ;;
            vless-singbox:status) [[ -e "$SB_ACTIVE" ]] ;;
            vless-singbox:stop) rm -f "$SB_ACTIVE"; return 0 ;;
            vless-singbox:start) : >"$SB_ACTIVE"; return 0 ;;
            vless-singbox:restart) [[ -e "$RESTART_FAIL" ]] && return 1; : >"$SB_ACTIVE"; return 0 ;;
            *) return 0 ;;
        esac
    }

    # (a) D8: 管理员停服并写入 $CFG/paused 后，调用 _regenerate_proxy_configs 绝不得拉起 Xray 或 Sing-box
    rm -f "$XR_ACTIVE" "$SB_ACTIVE"
    : >"$CFG/paused"
    : >"$CFG/.singbox-stopped-empty"
    : >"$SVC"
    _regenerate_proxy_configs >/dev/null 2>&1; rc=$?
    check 'D8a _regenerate_proxy_configs under paused returns 0' eq "$rc" 0
    check 'D8a _regenerate_proxy_configs under paused never starts/restarts xray or singbox' \
        bash -c '[[ ! -e "$1" && ! -e "$2" ]] && ! grep -Eq "svc (start|restart)" "$3"' _ "$XR_ACTIVE" "$SB_ACTIVE" "$SVC"
    check 'D8a _regenerate_proxy_configs still updates configs on disk while paused' \
        bash -c '[[ -s "$1/config.json" && -s "$1/singbox.json" ]]' _ "$CFG"

    # (b) D8: 无 paused 但管理员手动停服（无 .singbox-stopped-empty）→ _regenerate_proxy_configs 保持停止
    rm -f "$CFG/paused" "$CFG/.singbox-stopped-empty" "$XR_ACTIVE" "$SB_ACTIVE"
    : >"$SVC"
    _regenerate_proxy_configs >/dev/null 2>&1; rc=$?
    check 'D8b admin-stopped services stay stopped after _regenerate_proxy_configs' \
        bash -c '[[ "$1" -eq 0 && ! -e "$2" && ! -e "$3" ]] && ! grep -Eq "svc (start|restart)" "$4"' _ "$rc" "$XR_ACTIVE" "$SB_ACTIVE" "$SVC"

    # (c) D8: 自动停服标记存在且未 paused → _regenerate_proxy_configs 自动拉起 vless-singbox 并清标记
    : >"$CFG/.singbox-stopped-empty"
    : >"$SVC"
    _regenerate_proxy_configs >/dev/null 2>&1; rc=$?
    check 'D8c auto-stopped singbox recovers via _regenerate_proxy_configs when not paused' \
        bash -c '[[ "$1" -eq 0 && -e "$2" && ! -e "$3/.singbox-stopped-empty" ]]' _ "$rc" "$SB_ACTIVE" "$CFG"

    # (d) D8: paused 状态下卸载一个 sing-box 协议（还有剩余 sing-box 协议）→ 绝不拉起 sing-box
    rm -f "$SB_ACTIVE" "$XR_ACTIVE"
    : >"$CFG/paused"
    : >"$SVC"
    protos=$(get_installed_protocols)
    tuic_idx=$(grep -nx 'tuic' <<<"$protos" | cut -d: -f1)
    printf '%s\ny\n' "${tuic_idx:-3}" | uninstall_specific_protocol >/dev/null 2>&1; rc=$?
    check 'D8d uninstall remaining singbox protocol under paused never restarts singbox' \
        bash -c '[[ ! -e "$1" ]] && ! grep -Eq "svc (start|restart) vless-singbox" "$2"' _ "$SB_ACTIVE" "$SVC"
    check 'D8d tuic protocol was removed from DB' bash -c '! db_exists singbox tuic'

    # (e) D12: running 状态 svc restart 失败 → 必须保留 .singbox-stopped-empty（仅成功后删除）
    rm -f "$CFG/paused"
    : >"$SB_ACTIVE"
    : >"$CFG/.singbox-stopped-empty"
    : >"$RESTART_FAIL"
    _rebuild_and_reload_singbox_impl "silent" >/dev/null 2>&1; rc=$?
    check 'D12e running restart failure returns non-zero and retains .singbox-stopped-empty' \
        bash -c '[[ "$1" -ne 0 && -e "$2/.singbox-stopped-empty" ]]' _ "$rc" "$CFG"
    rm -f "$RESTART_FAIL"
    _rebuild_and_reload_singbox_impl "silent" >/dev/null 2>&1; rc=$?
    check 'D12e subsequent successful restart clears .singbox-stopped-empty' \
        bash -c '[[ "$1" -eq 0 && ! -e "$2/.singbox-stopped-empty" ]]' _ "$rc" "$CFG"
    # (f) Alpine gcompat _pgrep 匹配 ld-linux ... -- /usr/local/bin/sing-box 且拒绝 timeout 包装器
    DISTRO="alpine"
    MOCK_CMDLINE=""
    pgrep() {
        if [[ "${1:-}" == "-f" ]]; then
            [[ "$MOCK_CMDLINE" =~ $2 ]]
        else
            return 1
        fi
    }
    MOCK_CMDLINE="ld-linux-x86-64.so.2 --argv0 /usr/local/bin/sing-box --preload /lib/libgcompat.so.0 -- /usr/local/bin/sing-box run -c /etc/vless-reality/singbox.json"
    check 'Alpine gcompat _pgrep matches ld-linux wrapped sing-box process' _pgrep sing-box
    MOCK_CMDLINE="timeout 30 sing-box check -c /etc/vless-reality/singbox.json"
    _alp_pgrep_timeout_rc=0
    _pgrep sing-box || _alp_pgrep_timeout_rc=$?
    check 'Alpine gcompat _pgrep still rejects timeout sing-box check wrapper' test "$_alp_pgrep_timeout_rc" -ne 0
    unset -f pgrep
)

# ═════════════ D2 & D3 & F03: 防误删非自签证书 + 残余 issuer 回退清零 ═════════════
sec_d2_d3_cert_protection() ( fresh_env d2d3
    PKI="$SEC/pki"
    mkdir -p "$PKI" "$CFG/certs"

    # 构造独立 CA + 中间 CA + 叶证书（故意仅放叶证书以模拟缺中间链）
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -keyout "$PKI/root.key" -out "$PKI/root.crt" -subj "/CN=D2 Root CA" -days 10 \
        -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
    openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -keyout "$PKI/int.key" -out "$PKI/int.csr" -subj "/CN=D2 Intermediate CA" 2>/dev/null
    printf 'basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\n' >"$PKI/int.ext"
    openssl x509 -req -in "$PKI/int.csr" -CA "$PKI/root.crt" -CAkey "$PKI/root.key" \
        -CAcreateserial -out "$PKI/int.crt" -days 10 -extfile "$PKI/int.ext" 2>/dev/null
    openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -keyout "$PKI/leaf.key" -out "$PKI/leaf.csr" -subj "/CN=ca.example.com" 2>/dev/null
    printf 'basicConstraints=CA:FALSE\nkeyUsage=digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:ca.example.com\n' >"$PKI/leaf.ext"
    openssl x509 -req -in "$PKI/leaf.csr" -CA "$PKI/int.crt" -CAkey "$PKI/int.key" \
        -CAcreateserial -out "$PKI/leaf.crt" -days 10 -extfile "$PKI/leaf.ext" 2>/dev/null

    export VLESS_TEST_CA_BUNDLE="$PKI/root.crt"
    echo "ca.example.com" >"$CFG/cert_domain"
    cp "$PKI/leaf.crt" "$CFG/certs/server.crt"
    cp "$PKI/leaf.key" "$CFG/certs/server.key"
    orig_cert_sha=$(sha256sum "$CFG/certs/server.crt" | awk '{print $1}')
    orig_key_sha=$(sha256sum "$CFG/certs/server.key" | awk '{print $1}')

    # (a) D2: 缺中间链的 CA 证书虽然 _is_real_cert 不信任，但 _handle_standalone_cert force_new=true 绝不得删毁
    check 'D2a leaf-only cert still fails strict _is_real_cert trust check' \
        bash -c '! _is_real_cert "ca.example.com" "$1"' _ "$CFG/certs/server.key"
    warn_out=$(_handle_standalone_cert "self.example.com" true 2>&1); rc=$?
    check 'D2a _handle_standalone_cert force_new=true refuses to delete non-self-signed cert' test "$rc" -ne 0
    check 'D2a original CA server.crt & server.key preserved byte-for-byte' \
        bash -c '[[ "$(sha256sum "$1" | awk "{print \$1}")" == "$3" && "$(sha256sum "$2" | awk "{print \$1}")" == "$4" ]]' _ \
            "$CFG/certs/server.crt" "$CFG/certs/server.key" "$orig_cert_sha" "$orig_key_sha"
    check 'D2a warning explains non-self-signed protection' grep -Fq '非自签证书' <<<"$warn_out"

    # (b) D2: gen_self_cert 同样不得覆盖非自签 CA 证书
    gen_self_cert "override.example.com" >/dev/null 2>&1
    check 'D2b gen_self_cert preserves non-self-signed CA certificate' \
        eq "$(sha256sum "$CFG/certs/server.crt" | awk '{print $1}')" "$orig_cert_sha"

    # (c) D2: 真正的自签证书（subject == issuer）在 force_new=true 下可正常替换
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -keyout "$CFG/certs/server.key" -out "$CFG/certs/server.crt" -subj "/CN=old-self.example" -days 10 2>/dev/null
    rm -f "$CFG/cert_domain"
    _handle_standalone_cert "new-self.example" true >/dev/null 2>&1; rc=$?
    new_subj=$(openssl x509 -in "$CFG/certs/server.crt" -noout -subject 2>/dev/null)
    check 'D2c _handle_standalone_cert force_new=true replaces genuine self-signed cert' \
        bash -c '[[ "$1" -eq 0 ]] && grep -Fq "new-self.example" <<<"$2"' _ "$rc" "$new_subj"

    # (d) F03 全脚本卫生：不再存在基于 R3/ZeroSSL/Buypass 的 issuer 字符串匹配回退，也不存在死代码 _sanitize_sub_scalar
    check 'F03d zero leftover issuer-name fallback checks in product' \
        bash -c '! grep -qE "issuer.*(R3|ZeroSSL|Buypass)" "$1"' _ "$PRODUCT"
    check 'D7 dead function _sanitize_sub_scalar removed from product' \
        bash -c '! grep -q "^_sanitize_sub_scalar()" "$1"' _ "$PRODUCT"
)

# ═════════════ D9 & D10 & D11: gRPC serviceName + server 校验 + 诊断告警 ═════════════
sec_d9_d10_d11_clash_external() ( fresh_env d9d10d11
    get_ip_suffix() { echo ""; }

    # (a) D9: VLESS+TLS+gRPC, VLESS+Reality+gRPC, VMess+TLS+gRPC, Trojan+gRPC 全链路往返
    yaml_grpc=$(cat <<'YAML'
proxies:
  - name: "VLESS-gRPC"
    type: vless
    server: 198.51.100.61
    port: 443
    uuid: 11111111-1111-4111-8111-111111111111
    tls: true
    network: grpc
    servername: vg.example.com
    grpc-opts:
      grpc-service-name: my-vless-svc
  - name: "Reality-gRPC"
    type: vless
    server: 198.51.100.62
    port: 443
    uuid: 22222222-2222-4222-8222-222222222222
    tls: true
    network: grpc
    servername: rg.example.com
    reality-opts:
      public-key: PUBKEYGRPC
      short-id: cc33
    grpc-opts:
      grpc-service-name: real-grpc-svc
  - { name: "VMess-gRPC", type: vmess, server: 198.51.100.63, port: 443, uuid: "33333333-3333-4333-8333-333333333333", tls: true, network: grpc, servername: mg.example.com, grpc-opts: { grpc-service-name: "vmess-grpc-svc" } }
  - name: "Trojan-gRPC"
    type: trojan
    server: 198.51.100.64
    port: 443
    password: tr-grpc-password
    sni: tg.example.com
    network: grpc
    grpc-opts:
      grpc-service-name: trojan-grpc-svc
YAML
)
    links=$(_parse_clash_yaml_proxies "$yaml_grpc" 2>/dev/null)
    vl_link=$(grep '198.51.100.61' <<<"$links" | head -n1)
    rg_link=$(grep '198.51.100.62' <<<"$links" | head -n1)
    vm_link=$(grep '^vmess://' <<<"$links" | head -n1)
    tr_link=$(grep '198.51.100.64' <<<"$links" | head -n1)

    check 'D9a VLESS+TLS+gRPC link carries serviceName=my-vless-svc' grep -Fq 'serviceName=my-vless-svc' <<<"$vl_link"
    check 'D9a VLESS+Reality+gRPC link carries serviceName=real-grpc-svc' grep -Fq 'serviceName=real-grpc-svc' <<<"$rg_link"
    check 'D9a Trojan+gRPC link carries serviceName=trojan-grpc-svc' grep -Fq 'serviceName=trojan-grpc-svc' <<<"$tr_link"

    check 'D9b parse_share_link preserves serviceName for VLESS/Reality/VMess/Trojan' \
        bash -c '
            jq -e ".transport == \"grpc\" and .serviceName == \"my-vless-svc\"" <<<"$1" &&
            jq -e ".security == \"reality\" and .transport == \"grpc\" and .serviceName == \"real-grpc-svc\"" <<<"$2" &&
            jq -e ".network == \"grpc\" and .serviceName == \"vmess-grpc-svc\"" <<<"$3" &&
            jq -e ".transport == \"grpc\" and .serviceName == \"trojan-grpc-svc\"" <<<"$4"
        ' _ "$(parse_share_link "$vl_link")" "$(parse_share_link "$rg_link")" "$(parse_share_link "$vm_link")" "$(parse_share_link "$tr_link")"

    vl_clash=$(external_link_to_clash "$vl_link")
    rg_clash=$(external_link_to_clash "$rg_link")
    vm_clash=$(external_link_to_clash "$vm_link")
    tr_clash=$(external_link_to_clash "$tr_link")
    check 'D9c external_link_to_clash emits grpc-opts.grpc-service-name for all 4 gRPC nodes' \
        bash -c '
            grep -Fq "grpc-service-name: \"my-vless-svc\"" <<<"$1" &&
            grep -Fq "grpc-service-name: \"real-grpc-svc\"" <<<"$2" &&
            grep -Fq "grpc-service-name: \"vmess-grpc-svc\"" <<<"$3" &&
            grep -Fq "grpc-service-name: \"trojan-grpc-svc\"" <<<"$4" &&
            grep -Fq "network: grpc" <<<"$4"
        ' _ "$vl_clash" "$rg_clash" "$vm_clash" "$tr_clash"

    # D6 实证：多节点输出不存在多余空行
    blank_lines=$(grep -c '^$' <<<"$links" || true)
    check 'D6 _parse_clash_yaml_proxies produces zero extra blank lines between nodes' eq "$blank_lines" "0"

    # (b) D10: server 字段拒绝 @ ? / # 空白等 URI 结构字符，放行合法域名/IPv4/IPv6
    for bad_srv in "evil.com@1.2.3.4" "1.2.3.4?x=y" "1.2.3.4/path" "1.2.3.4#frag" "1.2.3.4 bad" ".leading.dot" "-bad.host"; do
        check "D10 _valid_sub_server rejects '$bad_srv'" bash -c '! _valid_sub_server "$1"' _ "$bad_srv"
    done
    for good_srv in "198.51.100.1" "sub.example-01.com" "2001:db8::1" "::1"; do
        check "D10 _valid_sub_server accepts '$good_srv'" _valid_sub_server "$good_srv"
    done
    bad_vmess_srv=$(jq -nc '{v:"2",ps:"bad",add:"evil.com@1.2.3.4",port:"443",id:"11111111-1111-4111-8111-111111111111",aid:"0",net:"tcp",tls:"tls",sni:"a.example"}' | base64 -w 0)
    check 'D10 parse_vmess_link rejects server with @ userinfo spoof' bash -c '! parse_vmess_link "vmess://$1" >/dev/null 2>&1' _ "$bad_vmess_srv"
    v6_emitted=$(_clash_emit_proxy_link "v6" "trojan" "[2001:db8::1]" "443" "" "pw" "" "tcp" "true" "s.example" "" "" "" "" "" "false" "" "" "" "" "" 2>/dev/null)
    check 'D10 _clash_emit_proxy_link accepts bracketed IPv6 server' grep -Fq '@[2001:db8::1]:443' <<<"$v6_emitted"

    # (c) D11: 合法节点与非法节点混排时，合法节点正常输出，非法节点必须在 stderr 输出明确告警
    yaml_mixed=$(cat <<'YAML'
proxies:
  - name: "BadPort"
    type: trojan
    server: 198.51.100.70
    port: 99999
    password: pw
    sni: s.example
  - name: "BadServer"
    type: trojan
    server: "evil.com@198.51.100.71"
    port: 443
    password: pw
    sni: s.example
  - name: "GoodNode"
    type: trojan
    server: 198.51.100.72
    port: 443
    password: pw
    sni: s.example
YAML
)
    mixed_err="$SEC/mixed.err"
    mixed_out=$(_parse_clash_yaml_proxies "$yaml_mixed" 2>"$mixed_err"); rc=$?
    check 'D11 mixed YAML succeeds and emits valid node' \
        bash -c '[[ "$1" -eq 0 ]] && grep -Fq "198.51.100.72:443" <<<"$2"' _ "$rc" "$mixed_out"
    check 'D11 invalid port node emits diagnostic warning on stderr' grep -Fq 'BadPort' "$mixed_err"
    check 'D11 invalid server node emits diagnostic warning on stderr' grep -Fq 'BadServer' "$mixed_err"
)

# ═════════════ M5–M10: 补齐 F02/F06/F07/F08/R03(D4)/F04(D8) 防假绿变异自检 ═════════════
sec_h19_mutations() ( fresh_env h19mut
    get_ip_suffix() { echo ""; }

    # M5 (F02): 回退外部 hy2 默认 insecure=true → 导出 skip-cert-verify: true（与真实产物相反）
    m5_mut=$( (
        _parse_insecure_flag() { printf 'true'; }
        external_link_to_clash 'hysteria2://pw@198.51.100.80:443?sni=h.example#hy'
    ) )
    m5_real=$(external_link_to_clash 'hysteria2://pw@198.51.100.80:443?sni=h.example#hy')
    check 'Mutation M5 (F02): insecure-default mutant flips hy2 to skip-cert-verify: true while real product outputs false' \
        bash -c 'grep -Fq "skip-cert-verify: true" <<<"$1" && grep -Fq "skip-cert-verify: false" <<<"$2"' _ "$m5_mut" "$m5_real"

    # M6 (F06/D9): 真实函数变异——将 parse_vless_link 中 serviceName 提取置空，证明真实导出链路对回归敏感
    m6_mut=$( (
        eval_body=$(declare -f parse_vless_link | sed 's/service_name="\$value"/service_name=""/g')
        source <(printf '%s\n' "$eval_body")
        external_link_to_clash 'vless://11111111-1111-4111-8111-111111111111@198.51.100.81:443?security=tls&type=grpc&sni=g.example&serviceName=svc1#G'
    ) )
    m6_real=$(external_link_to_clash 'vless://11111111-1111-4111-8111-111111111111@198.51.100.81:443?security=tls&type=grpc&sni=g.example&serviceName=svc1#G')
    check 'Mutation M6 (F06/D9): mutating parse_vless_link serviceName drops grpc-opts while real product emits grpc-service-name' \
        bash -c '! grep -Fq "grpc-service-name" <<<"$1" && grep -Fq "grpc-service-name: \"svc1\"" <<<"$2"' _ "$m6_mut" "$m6_real"

    # M7 (F07): 回退 dpkg -l 判定 → 残留配置态 rc 误判已安装，而真实 _dpkg_pkg_installed 拒绝
    m7_mut_rc=0
    dpkg() { return 0; }
    dpkg-query() { printf 'deinstall ok config-files\n'; return 0; }
    ( _dpkg_pkg_installed() { dpkg -l "$1" >/dev/null 2>&1; }; _dpkg_pkg_installed socat ) || m7_mut_rc=$?
    check 'Mutation M7 (F07): dpkg -l mutant falsely accepts residual rc pkg while real _dpkg_pkg_installed rejects' \
        bash -c '[[ "$1" -eq 0 ]] && ! _dpkg_pkg_installed socat' _ "$m7_mut_rc"

    # M8 (F08): 真实函数变异——将 _http_fetch_sub_raw 改为直接传 "$url" 给 curl argv，证明真实 fetch_subscription 零泄漏
    TOK="MUT_SECRET_TOKEN_8899"
    ARGV_F="$SEC/m8.argv"
    curl() { printf '%s\n' "$@" >"$ARGV_F"; printf 'vless://11111111-1111-4111-8111-111111111111@198.51.100.82:443?security=tls&type=tcp&sni=s.example#N\n'; }
    (
        _http_fetch_sub_raw() { curl -fsSL "$1"; }
        fetch_subscription "https://sub.example/x?token=$TOK" >/dev/null 2>&1
    )
    m8_leaked=$(grep -cF "$TOK" "$ARGV_F" || true)
    : >"$ARGV_F"
    fetch_subscription "https://sub.example/x?token=$TOK" >/dev/null 2>&1
    m8_real_leaked=$(grep -cF "$TOK" "$ARGV_F" || true)
    check 'Mutation M8 (F08): mutated _http_fetch_sub_raw leaks token to curl argv while real fetch_subscription keeps argv clean' \
        bash -c '[[ "$1" -ge 1 && "$2" -eq 0 ]]' _ "$m8_leaked" "$m8_real_leaked"

    # M9 (R03/D4): 真实函数变异——移除 _sync_all_user_traffic_locked 聚合失败的 return 1 早退，证明变异体丢账而真实产品保账
    mkdir -p "$CFG/cache"
    write_db <<<'{"version":"4.0.0","xray":{"vless":{"port":443,"uuid":"u","users":[{"name":"u1","uuid":"u","enabled":true,"quota":0,"used":0}]}},"singbox":{},"meta":{}}'
    printf 'user>>>u1@vless>>>traffic>>>uplink 500 m9-1\n' >"$CFG/cache/traffic.pending"
    m9_real_kept=$( (
        _traffic_collect_to_journal() { return 0; }
        awk() { return 1; }
        _sync_all_user_traffic_locked >/dev/null 2>&1 || true
        [[ -s "$CFG/cache/traffic.pending" ]] && echo "KEPT" || echo "WIPED"
    ) )
    m9_mut_kept=$( (
        _traffic_collect_to_journal() { return 0; }
        awk() { return 1; }
        mut_fn=$(declare -f _sync_all_user_traffic_locked | sed '/流量暂存日志聚合失败/{n;s/return 1/:/;}')
        source <(printf '%s\n' "$mut_fn")
        _sync_all_user_traffic_locked >/dev/null 2>&1 || true
        [[ -s "$CFG/cache/traffic.pending" ]] && echo "KEPT" || echo "WIPED"
    ) )
    check 'Mutation M9 (R03/D4): removing early-return in _sync_all_user_traffic_locked wipes pending while real product preserves it' \
        bash -c '[[ "$1" == "KEPT" && "$2" == "WIPED" ]]' _ "$m9_real_kept" "$m9_mut_kept"

    # M10 (F04/D8): 真实函数变异——移除 _rebuild_and_reload_singbox_impl 的 is_paused 守卫，证明变异体在 paused 下误启而真实产品保持停服
    write_db <<<'{"version":"4.0.0","xray":{},"singbox":{"hy2":{"port":24443,"password":"p","sni":"h.example","users":[{"name":"u1","uuid":"pw","enabled":true}]}},"meta":{}}'
    SB_M10="$SEC/m10.sb"; rm -f "$SB_M10"
    : >"$CFG/paused"
    : >"$CFG/.singbox-stopped-empty"
    generate_singbox_config() { echo '{"ok":1}' >"$CFG/singbox.json"; return 0; }
    svc() { case "$1" in status) [[ -e "$SB_M10" ]];; start|restart) : >"$SB_M10"; return 0;; stop) rm -f "$SB_M10"; return 0;; esac; }
    _regenerate_proxy_configs >/dev/null 2>&1
    m10_real_active=0; [[ -e "$SB_M10" ]] && m10_real_active=1
    m10_mut_active=$( (
        mut_fn=$(declare -f _rebuild_and_reload_singbox_impl | sed 's/if is_paused; then/if false; then/')
        source <(printf '%s\n' "$mut_fn")
        _regenerate_proxy_configs >/dev/null 2>&1 || true
        [[ -e "$SB_M10" ]] && echo 1 || echo 0
    ) )
    check 'Mutation M10 (F04/D8): removing is_paused guard in _rebuild_and_reload_singbox_impl starts paused singbox while real product keeps it stopped' \
        bash -c '[[ "$1" -eq 0 && "$2" -eq 1 ]]' _ "$m10_real_active" "$m10_mut_active"
)

for sec in sec_d4_d5_traffic_integrity sec_d8_d12_f04_closure sec_d2_d3_cert_protection sec_d9_d10_d11_clash_external sec_h19_mutations; do
    printf '\n########## %s ##########\n' "$sec"
    before_fail=$(grep -c '^FAIL' "$RESULTS" || true)
    "$sec" 2>"$TMP/$sec.err"
    rc=$?
    after_fail=$(grep -c '^FAIL' "$RESULTS" || true)
    if [[ $rc -ne 0 ]]; then
        echo "FAIL $sec exited with $rc" >>"$RESULTS"
        printf '  FAIL %s exited with %s\n' "$sec" "$rc" >&2
        tail -n 30 "$TMP/$sec.err" >&2
    elif [[ "$after_fail" -gt "$before_fail" && -s "$TMP/$sec.err" ]]; then
        tail -n 30 "$TMP/$sec.err" >&2
    fi
done

[[ ! -e "$TMP/crontab-guard.log" ]] || { echo "FAIL a section touched the real crontab: $(head -n1 "$TMP/crontab-guard.log")" >>"$RESULTS"; }
pass=$(grep -c '^OK' "$RESULTS" || true)
fail=$(grep -c '^FAIL' "$RESULTS" || true)
printf '\n'
if [[ "$fail" -eq 0 && "$pass" -gt 0 ]]; then
    printf 'PASS: H19 audit regression & extended mutation suite (%d assertions)\n' "$pass"
else
    grep '^FAIL' "$RESULTS" >&2
    printf 'FAIL: H19 audit regression & extended mutation suite (%d failed, %d passed)\n' "$fail" "$pass" >&2
    exit 1
fi
