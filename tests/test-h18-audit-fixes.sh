#!/usr/bin/env bash
# H18 外部审计整改回归与变异自检测试（覆盖 F01-F08 确定实现缺陷与 R01/R03 改进）：
#   F01: 外部订阅 YAML 全标量序列化与控制字符拒绝（防注入）+ VLESS Reality pbk/sid 修复
#   F02: 菜单/外部 Clash/Surge 统一 TLS 验证策略（真实证书不跳过校验，外部节点不继承本机证书）
#   F03: _is_real_cert / _anytls_secure 严格密码学链/SAN/有效期/公私钥配对校验（删除 issuer 名称回退）
#   F04: sing-box 全禁用自动停服后重新启用自动恢复，同时保持管理员主动停服/paused 不误启
#   F05: _nginx_install_conf 备份失败即中止、禁止无备份删原配置、保留原 symlink 与失败备份
#   F06: Clash YAML 导入（普通 VLESS TLS vs Reality、首末 VLESS-WS 顺序无关、任意键序、flow mapping、TUIC 闭环、VMess jq 序列化、别名炸弹限制）
#   F07: Debian install_deps 分离退出码、校验 dpkg-query 严格安装态（拒绝 rc/iU/半安装）与关键命令
#   F08: fetch_subscription 通过 curl -K - stdin 传 URL（不进 argv）、限制协议/重定向/体积、提示与列表脱敏 URL
#   R01/R03: 流量采集 reset 后落盘失败显式告警采样缺口 + 单遍 pending 索引正确性与多用户配额/重放幂等
#   Mutation: 4 组安全回归变异自检（去掉序列化/恢复 issuer 回退/备份失败继续/停服不自动拉起 → 必须变红）
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")/.." && pwd)
PRODUCT="${1:-$ROOT/vless-server.sh}"
[[ -f "$PRODUCT" ]] || { echo "FAIL: missing product: $PRODUCT" >&2; exit 2; }
for dep in jq awk grep sed openssl sha256sum mktemp base64; do
    command -v "$dep" >/dev/null 2>&1 || { echo "FAIL: missing dependency: $dep" >&2; exit 2; }
done

TMP=$(mktemp -d "${TMPDIR:-/tmp}/aio-h18-audit.XXXXXX")
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

# ═════════════ F01: 外部订阅 YAML 序列化与注入防护 ═════════════
sec_f01_yaml_injection() ( fresh_env f01
    get_ip_suffix() { echo ""; }

    # 1) VMess JSON 含转义换行注入（\n  external-controller: 0.0.0.0:9090）→ 必须拒绝
    evil_vmess_uuid=$(jq -nc '{v:"2",ps:"evil",add:"198.51.100.1",port:"443",id:"11111111-1111-4111-8111-111111111111\n  external-controller: 0.0.0.0:9090",aid:"0",net:"ws",host:"a.example",path:"/ws",tls:"tls",sni:"a.example"}' | base64 -w 0)
    evil_vmess_path=$(jq -nc '{v:"2",ps:"evilp",add:"198.51.100.1",port:"443",id:"11111111-1111-4111-8111-111111111111",aid:"0",net:"ws",host:"a.example",path:"/ws\n      evil-header: 1",tls:"tls",sni:"a.example"}' | base64 -w 0)
    evil_vmess_sni=$(jq -nc '{v:"2",ps:"evils",add:"198.51.100.1",port:"443",id:"11111111-1111-4111-8111-111111111111",aid:"0",net:"tcp",host:"",path:"",tls:"tls",sni:"a.example\r\n  type: direct"}' | base64 -w 0)
    evil_vmess_tab=$(jq -nc '{v:"2",ps:"evilt",add:"198.51.100.1",port:"443",id:"11111111-1111-4111-8111-111111111111",aid:"0",net:"ws",host:"a.example\tbad",path:"/ws",tls:"tls",sni:"a.example"}' | base64 -w 0)

    out1=$(external_link_to_clash "vmess://${evil_vmess_uuid}" 2>/dev/null); rc1=$?
    out2=$(external_link_to_clash "vmess://${evil_vmess_path}" 2>/dev/null); rc2=$?
    out3=$(external_link_to_clash "vmess://${evil_vmess_sni}" 2>/dev/null); rc3=$?
    out4=$(external_link_to_clash "vmess://${evil_vmess_tab}" 2>/dev/null); rc4=$?
    check 'F01 rejects VMess uuid with newline YAML injection' bash -c '[[ $1 -ne 0 && -z "$2" ]]' _ "$rc1" "$out1"
    check 'F01 rejects VMess path with newline YAML injection' bash -c '[[ $1 -ne 0 && -z "$2" ]]' _ "$rc2" "$out2"
    check 'F01 rejects VMess sni with CRLF YAML injection' bash -c '[[ $1 -ne 0 && -z "$2" ]]' _ "$rc3" "$out3"
    check 'F01 rejects VMess host with TAB control char' bash -c '[[ $1 -ne 0 && -z "$2" ]]' _ "$rc4" "$out4"

    # 2) VLESS/Trojan URL 编码 %0a / %0d / %00 注入 → 必须拒绝
    check 'F01 rejects VLESS %0a newline injection in sni' bash -c '! external_link_to_clash "vless://11111111-1111-4111-8111-111111111111@198.51.100.2:443?security=tls&type=ws&sni=ok.example%0a%20%20evil:%201&path=/ws#n1" >/dev/null 2>&1'
    check 'F01 rejects Trojan %00 null-byte injection in password' bash -c '! external_link_to_clash "trojan://pass%00word@198.51.100.2:443?sni=ok.example#t1" >/dev/null 2>&1'

    # 3) 合法特殊 YAML 字符（引号、反斜线、冒号、#、Unicode）必须安全编码为合法 YAML 且结构不变
    special_vmess=$(jq -nc '{v:"2",ps:"香港 \"node\": #1 \\ test",add:"198.51.100.3",port:"443",id:"11111111-1111-4111-8111-111111111111",aid:"0",net:"ws",host:"h.example",path:"/ws?a=1&b=2#frag:x",tls:"tls",sni:"s.example"}' | base64 -w 0)
    yaml_out=$(external_link_to_clash "vmess://${special_vmess}")
    check 'F01 emits Clash YAML for special-char VMess node' test -n "$yaml_out"
    check 'F01 quotes uuid/servername/path/Host as JSON/YAML double-quoted scalars' \
        bash -c 'grep -Fq "uuid: \"11111111-1111-4111-8111-111111111111\"" <<<"$1" && grep -Fq "servername: \"s.example\"" <<<"$1" && grep -Fq "path: \"/ws?a=1&b=2#frag:x\"" <<<"$1" && grep -Fq "Host: \"h.example\"" <<<"$1"' _ "$yaml_out"
    if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
        check 'F01 special-char Clash YAML parses with PyYAML preserving exact fields and node count=1' \
            python3 -c '
import sys, yaml
doc = yaml.safe_load("proxies:\n" + sys.argv[1])
assert isinstance(doc, dict) and len(doc["proxies"]) == 1, doc
p = doc["proxies"][0]
assert p["name"] == "香港 \"node\": #1 \\ test", repr(p["name"])
assert p["ws-opts"]["path"] == "/ws?a=1&b=2#frag:x", repr(p["ws-opts"]["path"])
assert p["skip-cert-verify"] is False, repr(p["skip-cert-verify"])
' "$yaml_out"
    fi

    # 4) VLESS Reality 外链 pbk/sid 必须从 publicKey/shortId 正确导出（不再输出 null）
    vless_real="vless://11111111-1111-4111-8111-111111111111@198.51.100.4:443?encryption=none&security=reality&type=tcp&flow=xtls-rprx-vision&sni=www.example.com&fp=chrome&pbk=PUBKEY123&sid=ab12#RealityNode"
    real_yaml=$(external_link_to_clash "$vless_real")
    check 'F01 VLESS Reality exports real public-key (not null)' grep -Fq 'public-key: "PUBKEY123"' <<<"$real_yaml"
    check 'F01 VLESS Reality exports real short-id (not null)' grep -Fq 'short-id: "ab12"' <<<"$real_yaml"

    # 5) gen_clash_sub proxy-groups 保留带转义引号的外部节点名
    write_db <<<'{"version":"4.0.0","xray":{},"singbox":{},"meta":{}}'
    get_ipv4() { echo "198.51.100.9"; }; get_ipv6() { echo ""; }; get_ip_country() { echo "HK"; }
    get_all_external_links() { printf 'vmess://%s\n' "$special_vmess"; }
    full_clash=$(gen_clash_sub)
    if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
        check 'F01 gen_clash_sub full document parses with matching proxy-group name' \
            python3 -c '
import sys, yaml
doc = yaml.safe_load(sys.argv[1])
assert len(doc["proxies"]) == 1
assert doc["proxy-groups"][0]["proxies"] == [doc["proxies"][0]["name"]], doc["proxy-groups"]
' "$full_clash"
    fi
)

# ═════════════ F02: 统一 TLS 验证策略（菜单 + 外部 Clash/Surge）═════════════
sec_f02_tls_policy() ( fresh_env f02
    get_ipv4() { echo "198.51.100.10"; }; get_ipv6() { echo ""; }; get_ip_country() { echo "SG"; }
    get_ip_suffix() { echo ""; }
    write_db <<'J'
{"version":"4.0.0",
 "xray":{
   "vless-vision":{"port":8443,"uuid":"u-vis","sni":"real.example.com"},
   "vless-ws":{"port":18443,"uuid":"u-vws","sni":"real.example.com","path":"/vws"},
   "vmess-ws":{"port":18444,"uuid":"u-mws","sni":"real.example.com","path":"/mws"},
   "trojan":{"port":18445,"password":"pw-tr","sni":"real.example.com"},
   "trojan-ws":{"port":18446,"password":"pw-tws","sni":"real.example.com","path":"/tws"},
   "socks":{"port":18447,"username":"suser","password":"spw","tls":"true","sni":"real.example.com"}
 },
 "singbox":{
   "hy2":{"port":28443,"password":"pw-hy2","sni":"real.example.com"},
   "tuic":{"port":28444,"uuid":"u-tuic","password":"pw-tuic","sni":"real.example.com"},
   "anytls":{"port":28445,"password":"pw-any","sni":"real.example.com"}
 },
 "meta":{}}
J
    # 场景 A: 本机为受信任真实证书 → 所有菜单客户端输出均应 skip-cert-verify=false / : false
    _anytls_secure() { [[ "$1" == "real.example.com" ]]; }
    for proto in vless-vision vless-ws vmess-ws trojan trojan-ws socks hy2 tuic anytls; do
        out=$(show_single_protocol_info "$proto" false 2>/dev/null)
        check "F02 menu ($proto) with trusted cert emits no skip-cert-verify=true" \
            bash -c '! grep -qE "skip-cert-verify[:=][[:space:]]*true" <<<"$1"' _ "$out"
        check "F02 menu ($proto) with trusted cert explicitly sets skip-cert-verify false" \
            bash -c 'grep -qE "skip-cert-verify[:=][[:space:]]*false" <<<"$1"' _ "$out"
    done

    # 场景 B: 本机为自签兜底 → 菜单输出应回退 skip-cert-verify=true / : true
    _anytls_secure() { return 1; }
    for proto in vless-vision vless-ws vmess-ws trojan trojan-ws socks hy2 tuic anytls; do
        out=$(show_single_protocol_info "$proto" false 2>/dev/null)
        check "F02 menu ($proto) with self-signed fallback sets skip-cert-verify true" \
            bash -c 'grep -qE "skip-cert-verify[:=][[:space:]]*true" <<<"$1"' _ "$out"
    done

    # 场景 C: 外部节点绝不用本机证书推断信任；默认验证 (false)，仅显式 insecure 才 true
    _anytls_secure() { return 0; } # 即使本机有真证书，也不得影响外部节点
    ext_vmess_sec=$(jq -nc '{v:"2",ps:"vm-sec",add:"198.51.100.20",port:"443",id:"11111111-1111-4111-8111-111111111111",aid:"0",net:"ws",host:"ext.example",path:"/w",tls:"tls",sni:"ext.example"}' | base64 -w 0)
    ext_vmess_ins=$(jq -nc '{v:"2",ps:"vm-ins",add:"198.51.100.20",port:"443",id:"11111111-1111-4111-8111-111111111111",aid:"0",net:"ws",host:"ext.example",path:"/w",tls:"tls",sni:"ext.example",allowInsecure:true}' | base64 -w 0)
    check 'F02 external VLESS-WS default verifies TLS (skip-cert-verify: false)' \
        grep -Fq 'skip-cert-verify: false' <<<"$(external_link_to_clash 'vless://11111111-1111-4111-8111-111111111111@198.51.100.20:443?security=tls&type=ws&sni=ext.example&path=/w#ext-vws')"
    check 'F02 external VLESS-WS explicit allowInsecure=1 keeps skip-cert-verify: true' \
        grep -Fq 'skip-cert-verify: true' <<<"$(external_link_to_clash 'vless://11111111-1111-4111-8111-111111111111@198.51.100.20:443?security=tls&type=ws&sni=ext.example&path=/w&allowInsecure=1#ext-vws')"
    check 'F02 external VMess Clash+Surge default verifies TLS' \
        bash -c 'grep -Fq "skip-cert-verify: false" <<<"$1" && grep -Fq "skip-cert-verify=false" <<<"$2"' _ \
            "$(external_link_to_clash "vmess://${ext_vmess_sec}")" "$(external_link_to_surge "vmess://${ext_vmess_sec}")"
    check 'F02 external VMess explicit allowInsecure=true preserves true in Clash+Surge' \
        bash -c 'grep -Fq "skip-cert-verify: true" <<<"$1" && grep -Fq "skip-cert-verify=true" <<<"$2"' _ \
            "$(external_link_to_clash "vmess://${ext_vmess_ins}")" "$(external_link_to_surge "vmess://${ext_vmess_ins}")"
    check 'F02 external Trojan/HY2/TUIC/AnyTLS default verifies TLS in Clash and Surge' \
        bash -c '
            grep -Fq "skip-cert-verify: false" <<<"$1" && grep -Fq "skip-cert-verify=false" <<<"$2" &&
            grep -Fq "skip-cert-verify: false" <<<"$3" && grep -Fq "skip-cert-verify=false" <<<"$4" &&
            grep -Fq "skip-cert-verify: false" <<<"$5" && grep -Fq "skip-cert-verify=false" <<<"$6" &&
            grep -Fq "skip-cert-verify: false" <<<"$7" && grep -Fq "skip-cert-verify=false" <<<"$8"
        ' _ \
            "$(external_link_to_clash 'trojan://pw@198.51.100.20:443?sni=ext.example#tr')" \
            "$(external_link_to_surge 'trojan://pw@198.51.100.20:443?sni=ext.example#tr')" \
            "$(external_link_to_clash 'hysteria2://pw@198.51.100.20:443?sni=ext.example#hy')" \
            "$(external_link_to_surge 'hysteria2://pw@198.51.100.20:443?sni=ext.example#hy')" \
            "$(external_link_to_clash 'tuic://u1:pw@198.51.100.20:443?sni=ext.example#tu')" \
            "$(external_link_to_surge 'tuic://u1:pw@198.51.100.20:443?sni=ext.example#tu')" \
            "$(external_link_to_clash 'anytls://pw@198.51.100.20:443?sni=ext.example#an')" \
            "$(external_link_to_surge 'anytls://pw@198.51.100.20:443?sni=ext.example#an')"
    # 反向证明：本机 _anytls_secure 返回 0 时，外部 AnyTLS 显式 allowInsecure=1 不得被本机覆盖成 false
    check 'F02 external AnyTLS Surge ignores local _anytls_secure and keeps explicit allowInsecure=1' \
        grep -Fq 'skip-cert-verify=true' <<<"$(external_link_to_surge 'anytls://pw@198.51.100.20:443?sni=real.example.com&allowInsecure=1#an')"
)

# ═════════════ F03: 严格密码学证书校验（删除 issuer 名称回退）═════════════
sec_f03_cert_verify() ( fresh_env f03
    PKI="$SEC/pki"
    mkdir -p "$PKI" "$CFG/certs/hy2"
    # 搭建临时信任根 CA + 中间 CA (CN=Trusted Int) + 合法叶证书 (SAN=good.example.com)
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -keyout "$PKI/root.key" -out "$PKI/root.crt" -subj "/CN=Test Trusted Root" -days 10 \
        -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
    openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -keyout "$PKI/int.key" -out "$PKI/int.csr" -subj "/CN=Test Intermediate" 2>/dev/null
    printf 'basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\n' >"$PKI/int.ext"
    openssl x509 -req -in "$PKI/int.csr" -CA "$PKI/root.crt" -CAkey "$PKI/root.key" \
        -CAcreateserial -out "$PKI/int.crt" -days 10 -extfile "$PKI/int.ext" 2>/dev/null

    openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -keyout "$PKI/leaf.key" -out "$PKI/leaf.csr" -subj "/CN=good.example.com" 2>/dev/null
    printf 'basicConstraints=CA:FALSE\nkeyUsage=digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:good.example.com\n' >"$PKI/leaf.ext"
    openssl x509 -req -in "$PKI/leaf.csr" -CA "$PKI/int.crt" -CAkey "$PKI/int.key" \
        -CAcreateserial -out "$PKI/leaf.crt" -days 10 -extfile "$PKI/leaf.ext" 2>/dev/null
    cat "$PKI/leaf.crt" "$PKI/int.crt" >"$PKI/fullchain.crt"

    # 另一把不匹配的私钥
    openssl ecparam -name prime256v1 -genkey -noout -out "$PKI/other.key" 2>/dev/null

    # 不受信任私有仿名 CA (CN=Let's Encrypt R3) 签发叶证书（issuer != subject）
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -keyout "$PKI/rogue_ca.key" -out "$PKI/rogue_ca.crt" -subj "/O=Let's Encrypt/CN=R3" -days 10 \
        -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
    openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -keyout "$PKI/rogue_leaf.key" -out "$PKI/rogue_leaf.csr" -subj "/CN=good.example.com" 2>/dev/null
    openssl x509 -req -in "$PKI/rogue_leaf.csr" -CA "$PKI/rogue_ca.crt" -CAkey "$PKI/rogue_ca.key" \
        -CAcreateserial -out "$PKI/rogue_leaf.crt" -days 10 -extfile "$PKI/leaf.ext" 2>/dev/null
    cat "$PKI/rogue_leaf.crt" "$PKI/rogue_ca.crt" >"$PKI/rogue_fullchain.crt"

    # 自签证书
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -keyout "$PKI/self.key" -out "$PKI/self.crt" -subj "/CN=good.example.com" -days 10 \
        -addext "subjectAltName=DNS:good.example.com" 2>/dev/null

    # 已过期证书（即使由受信任 CA 签发）
    mkdir -p "$PKI/ca_db"
    : >"$PKI/ca_db/index.txt"
    echo 1000 >"$PKI/ca_db/serial"
    cat >"$PKI/ca.cnf" <<EOF
[ca]
default_ca = CA_default
[CA_default]
database = $PKI/ca_db/index.txt
serial = $PKI/ca_db/serial
new_certs_dir = $PKI/ca_db
certificate = $PKI/int.crt
private_key = $PKI/int.key
default_md = sha256
policy = policy_any
copy_extensions = copy
[policy_any]
commonName = supplied
EOF
    openssl ca -batch -config "$PKI/ca.cnf" -startdate 20200101000000Z -enddate 20200102000000Z \
        -in "$PKI/leaf.csr" -out "$PKI/expired_leaf.crt" -extfile "$PKI/leaf.ext" 2>/dev/null
    cat "$PKI/expired_leaf.crt" "$PKI/int.crt" >"$PKI/expired_fullchain.crt"

    export VLESS_TEST_CA_BUNDLE="$PKI/root.crt"
    echo "good.example.com" >"$CFG/cert_domain"

    # (a) 合法全链 + 匹配 SAN + 匹配私钥 → 通过
    cp "$PKI/fullchain.crt" "$CFG/certs/server.crt"
    cp "$PKI/leaf.key" "$CFG/certs/server.key"
    check 'F03a trusted fullchain + matching SAN + matching key passes _is_real_cert' _is_real_cert "good.example.com" "$CFG/certs/server.key"
    check 'F03a trusted fullchain passes _anytls_secure' _anytls_secure "good.example.com"

    # (b) 缺少中间链（仅叶证书）→ 失败
    cp "$PKI/leaf.crt" "$CFG/certs/server.crt"
    check 'F03b leaf missing intermediate chain fails _is_real_cert' bash -c '! _is_real_cert "good.example.com" "$1"' _ "$CFG/certs/server.key"
    check 'F03b leaf missing intermediate chain fails _anytls_secure' bash -c '! _anytls_secure "good.example.com"'

    # (c) 错误 SAN 主机名 → 失败
    cp "$PKI/fullchain.crt" "$CFG/certs/server.crt"
    echo "wrong.example.com" >"$CFG/cert_domain"
    check 'F03c wrong SAN hostname fails _is_real_cert' bash -c '! _is_real_cert "wrong.example.com" "$1"' _ "$CFG/certs/server.key"
    check 'F03c wrong SAN hostname fails _anytls_secure' bash -c '! _anytls_secure "wrong.example.com"'
    echo "good.example.com" >"$CFG/cert_domain"

    # (d) 过期证书（即便受信任 CA 签发）→ 失败
    cp "$PKI/expired_fullchain.crt" "$CFG/certs/server.crt"
    check 'F03d expired cert fails _is_real_cert' bash -c '! _is_real_cert "good.example.com" "$1"' _ "$CFG/certs/server.key"
    check 'F03d expired cert fails _anytls_secure' bash -c '! _anytls_secure "good.example.com"'

    # (e) 不受信任私有仿名 CA (Let's Encrypt / R3, issuer != subject) → 必须失败
    cp "$PKI/rogue_fullchain.crt" "$CFG/certs/server.crt"
    cp "$PKI/rogue_leaf.key" "$CFG/certs/server.key"
    check 'F03e untrusted private CA spoofed as Let'\''s Encrypt R3 fails _is_real_cert' bash -c '! _is_real_cert "good.example.com" "$1"' _ "$CFG/certs/server.key"
    check 'F03e untrusted private CA spoofed as R3 fails _anytls_secure' bash -c '! _anytls_secure "good.example.com"'

    # (f) 自签证书 → 失败
    cp "$PKI/self.crt" "$CFG/certs/server.crt"
    cp "$PKI/self.key" "$CFG/certs/server.key"
    check 'F03f self-signed cert fails _is_real_cert' bash -c '! _is_real_cert "good.example.com" "$1"' _ "$CFG/certs/server.key"

    # (g) 合法证书但私钥不配对 → 失败
    cp "$PKI/fullchain.crt" "$CFG/certs/server.crt"
    cp "$PKI/other.key" "$CFG/certs/server.key"
    check 'F03g mismatched private key fails _is_real_cert' bash -c '! _is_real_cert "good.example.com" "$1"' _ "$CFG/certs/server.key"
    check 'F03g mismatched private key fails _anytls_secure' bash -c '! _anytls_secure "good.example.com"'

    # (h) HY2 入站与 _anytls_secure 共用判据：私钥不配对时回退独立证书，配对合法全链时使用全局证书
    cp "$PKI/self.crt" "$CFG/certs/hy2/server.crt"
    cp "$PKI/self.key" "$CFG/certs/hy2/server.key"
    write_db <<<'{"version":"4.0.0","xray":{},"singbox":{"hy2":{"port":24443,"password":"pw","sni":"good.example.com"}},"meta":{}}'
    generate_singbox_config >/dev/null 2>&1
    check 'F03h HY2 inbound rejects mismatched global cert/key and falls back to hy2 cert' \
        eq "$(jq -r '.inbounds[] | select(.type=="hysteria2") | .tls.certificate_path' "$CFG/singbox.json")" "$CFG/certs/hy2/server.crt"
    cp "$PKI/leaf.key" "$CFG/certs/server.key"
    generate_singbox_config >/dev/null 2>&1
    check 'F03h HY2 inbound uses trusted matched global fullchain cert' \
        eq "$(jq -r '.inbounds[] | select(.type=="hysteria2") | .tls.certificate_path' "$CFG/singbox.json")" "$CFG/certs/server.crt"
)

# ═════════════ F04: sing-box 全禁用自动停服后再启用自动恢复 ═════════════
sec_f04_singbox_auto_recovery() ( fresh_env f04
    mkdir -p "$CFG/certs/hy2"
    echo c >"$CFG/certs/hy2/server.crt"; echo k >"$CFG/certs/hy2/server.key"
    write_db <<'J'
{"version":"4.0.0","xray":{},"singbox":{"hy2":{"port":24443,"password":"p","sni":"h.example","users":[
 {"name":"u1","uuid":"pw-u1","enabled":true}]}},"meta":{}}
J
    SB_ACTIVE="$SEC/sb.active"
    START_FAIL="$SEC/sb.start.fail"
    SVC="$SEC/svc.log"; : >"$SVC"
    : >"$SB_ACTIVE"
    svc() {
        echo "svc $*" >>"$SVC"
        case "$1" in
            status) [[ -e "$SB_ACTIVE" ]] ;;
            stop) rm -f "$SB_ACTIVE"; return 0 ;;
            start)
                [[ -e "$START_FAIL" ]] && return 1
                : >"$SB_ACTIVE"; return 0 ;;
            restart) : >"$SB_ACTIVE"; return 0 ;;
            *) return 0 ;;
        esac
    }

    # 1) 禁用最后一位用户 → 停服 + 删除 singbox.json + 写入自动停服标记
    db_set_user_enabled singbox hy2 u1 false >/dev/null 2>&1; rc=$?
    check 'F04a disabling last sing-box user returns 0' eq "$rc" 0
    check 'F04a disabling last user stops vless-singbox and removes singbox.json' \
        bash -c '[[ ! -e "$1" && ! -e "$2/singbox.json" ]]' _ "$SB_ACTIVE" "$CFG"
    check 'F04a auto-stop marker .singbox-stopped-empty is persisted' test -e "$CFG/.singbox-stopped-empty"

    # 2) 重新启用用户但自动启动失败 → 返回非 0、保留 auto-stop 与 pending 标记
    : >"$START_FAIL"
    db_set_user_enabled singbox hy2 u1 true >/dev/null 2>&1; rc=$?
    check 'F04b failed auto-recovery start returns non-zero' test "$rc" -ne 0
    check 'F04b failed start retains .singbox-stopped-empty and .reload-pending.singbox' \
        bash -c '[[ -e "$1/.singbox-stopped-empty" && -e "$1/.reload-pending.singbox" && ! -e "$2" ]]' _ "$CFG" "$SB_ACTIVE"

    # 3) 恢复可启动状态后重试（或重新启用）→ 自动启动服务并清除两个标记
    rm -f "$START_FAIL"
    rebuild_and_reload_singbox "silent" >/dev/null 2>&1; rc=$?
    check 'F04c retry auto-recovery starts vless-singbox and returns 0' \
        bash -c '[[ "$1" -eq 0 && -e "$2" && -s "$3/singbox.json" ]]' _ "$rc" "$SB_ACTIVE" "$CFG"
    check 'F04c successful recovery clears .singbox-stopped-empty and .reload-pending.singbox' \
        bash -c '[[ ! -e "$1/.singbox-stopped-empty" && ! -e "$1/.reload-pending.singbox" ]]' _ "$CFG"

    # 4) 管理员主动停服（非自动停服 / stop_services）→ 禁用后再启用不得擅自启动
    rm -f "$SB_ACTIVE" "$CFG/.singbox-stopped-empty"
    : >"$SVC"
    db_set_user_enabled singbox hy2 u1 false >/dev/null 2>&1
    check 'F04d disabling while already admin-stopped does not create auto-stop marker' test ! -e "$CFG/.singbox-stopped-empty"
    db_set_user_enabled singbox hy2 u1 true >/dev/null 2>&1; rc=$?
    check 'F04d re-enabling after admin-stop updates config but keeps service stopped' \
        bash -c '[[ "$1" -eq 0 && ! -e "$2" && -s "$3/singbox.json" ]]' _ "$rc" "$SB_ACTIVE" "$CFG"
    check 'F04d zero svc start calls when admin-stopped' bash -c '! grep -q "svc start" "$1"' _ "$SVC"

    # 5) 若自动停服后管理员点击 paused（touch $CFG/paused）→ 也不得自动启动
    : >"$SB_ACTIVE"
    db_set_user_enabled singbox hy2 u1 false >/dev/null 2>&1
    : >"$CFG/paused"
    : >"$SVC"
    db_set_user_enabled singbox hy2 u1 true >/dev/null 2>&1; rc=$?
    check 'F04e $CFG/paused prevents auto-start on re-enable' \
        bash -c '[[ "$1" -eq 0 && ! -e "$2" ]]' _ "$rc" "$SB_ACTIVE"
)

# ═════════════ F05: _nginx_install_conf 备份前置闸门与防删原配置 ═════════════
sec_f05_nginx_backup_gate() ( fresh_env f05
    d="$SEC/nginx"; mkdir -p "$d/avail" "$d/enabled"
    printf 'ORIGINAL-NGINX-CONF\n' >"$d/avail/site"
    printf 'BROKEN-NEW-CONF\n' >"$SEC/new.conf"
    orig_sha=$(sha256sum "$d/avail/site" | awk '{print $1}')

    NGINX_CALLS="$SEC/nginx.calls"; : >"$NGINX_CALLS"
    NGINX_RC=1
    nginx() { echo "nginx $*" >>"$NGINX_CALLS"; return "$NGINX_RC"; }

    # (a) mktemp 失败 → 在任何覆盖前中止，原配置字节不变，nginx -t 从未调用
    mktemp() { return 1; }
    _nginx_install_conf "$SEC/new.conf" "$d/avail/site" "$d/enabled/site" 2>/dev/null; rc=$?
    unset -f mktemp
    check 'F05a backup mktemp failure aborts non-zero' test "$rc" -ne 0
    check 'F05a original config preserved byte-for-byte on mktemp failure' \
        eq "$(sha256sum "$d/avail/site" | awk '{print $1}')" "$orig_sha"
    check 'F05a nginx -t was never called when backup failed' eq "$(wc -l <"$NGINX_CALLS" | tr -d ' ')" 0

    # (b) cp 备份失败 → 在任何覆盖前中止，原配置不变
    cp() { return 1; }
    _nginx_install_conf "$SEC/new.conf" "$d/avail/site" "$d/enabled/site" 2>/dev/null; rc=$?
    unset -f cp
    check 'F05b backup cp failure aborts non-zero' test "$rc" -ne 0
    check 'F05b original config preserved byte-for-byte on backup cp failure' \
        eq "$(sha256sum "$d/avail/site" | awk '{print $1}')" "$orig_sha"

    # (c) 原 symlink 指向别的旧文件，nginx -t 失败 → 既恢复原配置又恢复原 symlink 目标
    printf 'OTHER-TARGET\n' >"$d/avail/other"
    ln -sf "$d/avail/other" "$d/enabled/site"
    NGINX_RC=1
    _nginx_install_conf "$SEC/new.conf" "$d/avail/site" "$d/enabled/site" 2>/dev/null; rc=$?
    check 'F05c failed nginx -t restores original dest and original symlink target' \
        bash -c '[[ "$1" -ne 0 && "$(sha256sum "$2" | awk "{print \$1}")" == "$3" && "$(readlink "$4")" == "$5" ]]' _ \
            "$rc" "$d/avail/site" "$orig_sha" "$d/enabled/site" "$d/avail/other"

    # (d) 回滚时恢复 cp 失败 → 绝不删备份文件、绝不删原配置路径
    CP_COUNT=0
    REAL_CP=$(command -v cp)
    cp() {
        CP_COUNT=$((CP_COUNT + 1))
        if [[ $CP_COUNT -eq 3 ]]; then return 1; fi
        "$REAL_CP" "$@"
    }
    NGINX_RC=1
    err_out=$(_nginx_install_conf "$SEC/new.conf" "$d/avail/site" 2>&1); rc=$?
    unset -f cp
    bak_kept=$(find "$d/avail" -maxdepth 1 -name '.site.bak.*' | head -n 1)
    check 'F05d failed rollback restore preserves backup file instead of deleting it' \
        bash -c '[[ "$1" -ne 0 && -n "$2" && -f "$2" && "$(sha256sum "$2" | awk "{print \$1}")" == "$3" ]]' _ \
            "$rc" "$bak_kept" "$orig_sha"
    check 'F05d failed rollback restore reports retained backup path on stderr' grep -Fq "$bak_kept" <<<"$err_out"
    cp -f "$bak_kept" "$d/avail/site" && rm -f "$bak_kept"
)

# ═════════════ F06: Clash YAML 导入语义完整与首末节点一致 ═════════════
sec_f06_clash_yaml_import() ( fresh_env f06
    get_ip_suffix() { echo ""; }

    yaml_fwd=$(cat <<'YAML'
proxies:
  - name: "WS-Node"
    type: vless
    server: 198.51.100.31
    port: 443
    uuid: 11111111-1111-4111-8111-111111111111
    tls: true
    skip-cert-verify: false
    network: ws
    servername: ws.example.com
    ws-opts:
      path: /ws-path
      headers:
        Host: cdn.example.com
  - type: vless
    server: 198.51.100.32
    port: 443
    uuid: 22222222-2222-4222-8222-222222222222
    tls: true
    network: tcp
    flow: xtls-rprx-vision
    servername: real.example.com
    reality-opts:
      public-key: REALITYPUB
      short-id: 1a2b
    name: "KeyOrder-Reality"
  - { name: "Flow-VMess \"Q\"", type: vmess, server: 198.51.100.33, port: 8443, uuid: "33333333-3333-4333-8333-333333333333", tls: true, skip-cert-verify: true, network: ws, servername: vm.example.com, ws-opts: { path: "/f\\p", headers: { Host: "vm.example.com" } } }
  - name: "TUIC-Node"
    type: tuic
    server: 198.51.100.34
    port: 4443
    uuid: 44444444-4444-4444-8444-444444444444
    password: tuic-secret-pw
    sni: tuic.example.com
    alpn: [h3]
    skip-cert-verify: false
proxy-groups:
  - name: Proxy
YAML
)
    # 倒序版本：把 VLESS-WS 放在最后一个节点（验证首末节点语义完全一致）
    yaml_ws_last=$(cat <<'YAML'
proxies:
  - name: "TUIC-Node"
    type: tuic
    server: 198.51.100.34
    port: 4443
    uuid: 44444444-4444-4444-8444-444444444444
    password: tuic-secret-pw
    sni: tuic.example.com
    alpn: [h3]
    skip-cert-verify: false
  - name: "WS-Node"
    type: vless
    server: 198.51.100.31
    port: 443
    uuid: 11111111-1111-4111-8111-111111111111
    tls: true
    skip-cert-verify: false
    network: ws
    servername: ws.example.com
    ws-opts:
      path: /ws-path
      headers:
        Host: cdn.example.com
YAML
)
    links1=$(_parse_clash_yaml_proxies "$yaml_fwd")
    links2=$(_parse_clash_yaml_proxies "$yaml_ws_last")

    ws1=$(grep '198.51.100.31' <<<"$links1" | head -n1)
    ws2=$(grep '198.51.100.31' <<<"$links2" | head -n1)
    real1=$(grep '198.51.100.32' <<<"$links1" | head -n1)
    vm1=$(grep '^vmess://' <<<"$links1" | head -n1)
    tuic1=$(grep '^tuic://' <<<"$links1" | head -n1)

    check 'F06 plain VLESS+TLS imports as security=tls (NOT reality)' \
        bash -c 'grep -Fq "security=tls" <<<"$1" && ! grep -Fq "security=reality" <<<"$1"' _ "$ws1"
    check 'F06 VLESS-WS first vs last node emits byte-identical URI with path & host' eq "$ws1" "$ws2"
    check 'F06 VLESS-WS URI does not duplicate type=ws' \
        eq "$(grep -o 'type=ws' <<<"$ws1" | wc -l | tr -d ' ')" 1
    ws_json=$(parse_share_link "$ws1")
    check 'F06 VLESS-WS round-trip preserves path=/ws-path, host=cdn.example.com, insecure=false' \
        jq -e '.security == "tls" and .transport == "ws" and .path == "/ws-path" and .host == "cdn.example.com" and .insecure == false' <<<"$ws_json"

    check 'F06 block mapping with arbitrary key order parses Reality node' \
        jq -e '.name == "KeyOrder-Reality" and .security == "reality" and .publicKey == "REALITYPUB" and .shortId == "1a2b"' <<<"$(parse_share_link "$real1")"

    vm_json=$(parse_share_link "$vm1")
    check 'F06 flow mapping VMess with quotes/backslash round-trips cleanly via jq JSON' \
        jq -e '.name == "Flow-VMess \"Q\"" and .path == "/f\\p" and .host == "vm.example.com" and .insecure == true' <<<"$vm_json"

    tuic_json=$(parse_share_link "$tuic1")
    tuic_clash=$(external_link_to_clash "$tuic1")
    tuic_surge=$(external_link_to_surge "$tuic1")
    check 'F06 TUIC YAML -> link -> parse_share_link closed loop succeeds' \
        jq -e '.type == "tuic" and .uuid == "44444444-4444-4444-8444-444444444444" and .password == "tuic-secret-pw" and .sni == "tuic.example.com" and .insecure == false' <<<"$tuic_json"
    check 'F06 TUIC exports cleanly to Clash and Surge with skip-cert-verify false' \
        bash -c 'grep -Fq "type: tuic" <<<"$1" && grep -Fq "skip-cert-verify: false" <<<"$1" && grep -Fq "tuic, 198.51.100.34, 4443" <<<"$2" && grep -Fq "skip-cert-verify=false" <<<"$2"' _ "$tuic_clash" "$tuic_surge"

    # YAML 别名炸弹保护
    alias_bomb=$(printf 'proxies:\n  - name: bomb\n    type: ss\n    x: %s\n' "$(awk 'BEGIN{for(i=1;i<=60;i++) printf "*a "}')" )
    check 'F06 rejects YAML alias bomb (>50 aliases)' bash -c '! _parse_clash_yaml_proxies "$1" >/dev/null 2>&1' _ "$alias_bomb"
)

# ═════════════ F07: Debian install_deps 严格状态检验 ═════════════
sec_f07_debian_install_deps() ( fresh_env f07
    DISTRO="debian"
    APT_UPD_RC=0
    APT_INS_RC=0
    BROKEN_PKG=""
    BROKEN_STATUS="install ok installed"
    # 在隔离 bin 目录提供必需命令桩，确保测试不依赖宿主环境是否装了 socat
    for c in curl jq unzip openssl socat ip; do
        if ! command -v "$c" >/dev/null 2>&1; then
            printf '#!/bin/sh\nexit 0\n' >"$SEC/bin/$c"
            chmod +x "$SEC/bin/$c"
        fi
    done
    apt-get() {
        if [[ "$1" == "update" ]]; then
            echo "Hit:1 http://deb.debian.org/debian bookworm InRelease"
            return "$APT_UPD_RC"
        fi
        echo "Reading package lists..."
        return "$APT_INS_RC"
    }
    # 模拟 dpkg -l 对残留配置/未配置仍返回 0，但 dpkg-query 暴露真实状态
    dpkg() { return 0; }
    dpkg-query() {
        local pkg="${*: -1}"
        if [[ -n "$BROKEN_PKG" && "$pkg" == "$BROKEN_PKG" ]]; then
            printf '%s\n' "$BROKEN_STATUS"
            return 0
        fi
        printf 'install ok installed\n'
        return 0
    }

    # (a) 全部完整已安装 → 返回 0
    install_deps >/dev/null 2>&1; rc=$?
    check 'F07a all packages install ok installed succeeds' eq "$rc" 0

    # (b) apt 失败且存在残留配置 (rc: deinstall ok config-files) → 必须失败（旧版 dpkg -l 会误判成功）
    APT_INS_RC=100; BROKEN_PKG="socat"; BROKEN_STATUS="deinstall ok config-files"
    out=$(install_deps 2>&1); rc=$?
    check 'F07b residual-config package (deinstall ok config-files) fails install_deps' test "$rc" -ne 0
    check 'F07b failure does not print success message' bash -c '! grep -q "依赖安装完成" <<<"$1"' _ "$out"

    # (c) 未配置半安装态 (iU: install ok unpacked) → 必须失败
    BROKEN_PKG="jq"; BROKEN_STATUS="install ok unpacked"
    install_deps >/dev/null 2>&1; rc=$?
    check 'F07c half-installed unpacked package fails install_deps' test "$rc" -ne 0

    # (d) apt-get update 失败必须显式告警（不再静默吞掉）
    APT_UPD_RC=100; APT_INS_RC=0; BROKEN_PKG=""
    out=$(install_deps 2>&1); rc=$?
    check 'F07d apt-get update failure emits explicit warning' grep -Fq 'apt-get update 退出码 100' <<<"$out"

    # (e) 缺少关键可执行命令时，即使 dpkg 全部声称已安装也必须失败
    mkdir -p "$SEC/emptybin"
    for c in awk grep sed; do
        p=$(command -v "$c" 2>/dev/null || true)
        [[ -n "$p" ]] && ln -sf "$p" "$SEC/emptybin/$c"
    done
    PATH="$SEC/emptybin" install_deps >/dev/null 2>&1; rc=$?
    check 'F07e missing required executable commands fails install_deps' test "$rc" -ne 0
)

# ═════════════ F08: 外部订阅 URL 去敏与 curl stdin 传参 ═════════════
sec_f08_sub_url_redaction() ( fresh_env f08
    SECRET_TOKEN="BEARER_TOP_SECRET_TOKEN_XYZ987"
    SECRET_URL="https://sub.example.com/api/v1/subscribe?token=${SECRET_TOKEN}&flag=clash"
    CURL_ARGV_LOG="$SEC/curl.argv"
    CURL_STDIN_LOG="$SEC/curl.stdin"

    curl() {
        printf '%s\n' "$@" >"$CURL_ARGV_LOG"
        cat >"$CURL_STDIN_LOG"
        printf 'vless://11111111-1111-4111-8111-111111111111@198.51.100.50:443?security=tls&type=tcp&sni=s.example#N1\n'
    }

    got=$(fetch_subscription "$SECRET_URL" 2>/dev/null); rc=$?
    check 'F08 fetch_subscription succeeds via curl -K -' eq "$rc" 0
    check 'F08 secret token URL NEVER appears in curl argv' bash -c '! grep -Fq "$1" "$2"' _ "$SECRET_TOKEN" "$CURL_ARGV_LOG"
    check 'F08 curl enforces -K -, http/https proto restrictions, max-redirs, max-filesize' \
        bash -c 'grep -Fxq -- "-K" "$1" && grep -Fxq -- "--proto" "$1" && grep -Fxq -- "=http,https" "$1" && grep -Fxq -- "--proto-redir" "$1" && grep -Fxq -- "--max-redirs" "$1" && grep -Fxq -- "--max-filesize" "$1"' _ "$CURL_ARGV_LOG"
    check 'F08 URL is passed via stdin config' grep -Fq "$SECRET_URL" "$CURL_STDIN_LOG"

    # 非法协议与控制字符在调用 curl 之前拒绝
    rm -f "$CURL_ARGV_LOG"
    check 'F08 rejects file:// URL before calling curl' bash -c '! fetch_subscription "file:///etc/passwd" >/dev/null 2>&1 && [[ ! -e "$1" ]]' _ "$CURL_ARGV_LOG"
    check 'F08 rejects gopher:// URL before calling curl' bash -c '! fetch_subscription "gopher://127.0.0.1:6379/" >/dev/null 2>&1 && [[ ! -e "$1" ]]' _ "$CURL_ARGV_LOG"
    check 'F08 rejects URL with embedded newline before calling curl' bash -c '! fetch_subscription $"https://sub.example.com/a\nb" >/dev/null 2>&1 && [[ ! -e "$1" ]]' _ "$CURL_ARGV_LOG"

    # refresh_external_subs & show_external_nodes 输出不得回显 token
    printf '%s\n' "$SECRET_URL" >"$EXTERNAL_SUBS_FILE"
    ref_out=$(refresh_external_subs 2>&1)
    show_out=$(show_external_nodes 2>&1)
    check 'F08 refresh_external_subs output redacts token and shows host' \
        bash -c '! grep -Fq "$1" <<<"$2" && grep -Fq "https://sub.example.com/***" <<<"$2"' _ "$SECRET_TOKEN" "$ref_out"
    check 'F08 show_external_nodes output redacts token and shows host' \
        bash -c '! grep -Fq "$1" <<<"$2" && grep -Fq "https://sub.example.com/***" <<<"$2"' _ "$SECRET_TOKEN" "$show_out"
)

# ═════════════ R01 & R03: 流量采样缺口告警 + 单遍索引正确性 ═════════════
sec_r01_r03_traffic() ( fresh_env r01r03
    # R01: statsquery -reset 成功但返回损坏 JSON（模拟 reset 后解析/落盘失败）→ 必须返回非 0 并显式告警采样缺口
    _pgrep() { return 0; }
    cat >"$SEC/bin/xray" <<'EOF'
#!/bin/bash
printf '{BROKEN-JSON'
exit 0
EOF
    chmod +x "$SEC/bin/xray"
    warn_out=$(_traffic_collect_to_journal 2>&1); rc=$?
    check 'R01 post-reset parse failure returns non-zero' test "$rc" -ne 0
    check 'R01 post-reset parse failure logs explicit sampling-gap warning' grep -Fq '采样缺口' <<<"$warn_out"

    # R03: 多用户批量待处理日志单遍索引正确性 + 超配额禁用 + 幂等重放
    _pgrep() { return 1; }; check_daily_report() { :; }; tg_get_config() { echo 80; }
    tg_send_over_quota() { :; }; tg_send_quota_alert() { :; }
    svc() { return 0; }; generate_xray_config() { return 0; }
    mkdir -p "$CFG/cache"
    write_db <<'J'
{"version":"4.0.0","xray":{"vless":{"port":443,"uuid":"u0","users":[
 {"name":"u1","uuid":"u1","quota":1000,"used":0,"enabled":true},
 {"name":"u2","uuid":"u2","quota":500,"used":0,"enabled":true},
 {"name":"idle","uuid":"u3","quota":1000,"used":0,"enabled":true}]}},"singbox":{},"meta":{}}
J
    cat >"$CFG/cache/traffic.pending" <<'P'
user>>>u1@vless>>>traffic>>>uplink 120 b-1
user>>>u1@vless>>>traffic>>>downlink 280 b-2
user>>>u2@vless>>>traffic>>>uplink 300 b-3
user>>>u2@vless>>>traffic>>>downlink 300 b-4
P
    sync_all_user_traffic >/dev/null 2>&1; rc=$?
    u1_used=$(db_get_user_field xray vless u1 used)
    u1_en=$(db_get_user_field xray vless u1 enabled)
    u2_used=$(db_get_user_field xray vless u2 used)
    u2_en=$(db_get_user_field xray vless u2 enabled)
    idle_used=$(db_get_user_field xray vless idle used)
    idle_en=$(db_get_user_field xray vless idle enabled)
    check 'R03 single-pass indexed sync succeeds' eq "$rc" 0
    check 'R03 u1 used=400 and stays enabled' \
        bash -c '[[ "$1" == "400" && "$2" == "true" ]]' _ "$u1_used" "$u1_en"
    check 'R03 u2 used=600 >= quota 500 and is disabled' \
        bash -c '[[ "$1" == "600" && "$2" == "false" ]]' _ "$u2_used" "$u2_en"
    check 'R03 idle user untouched (used=0, enabled=true)' \
        bash -c '[[ "$1" == "0" && "$2" == "true" ]]' _ "$idle_used" "$idle_en"
)

# ═════════════ Mutation 自检（防假绿：回退安全修复时测试必须变红）═════════════
sec_mutations() ( fresh_env mut
    # M1: 回退 F01 _reject_ctrl_fields → VMess 换行注入会穿出外泄，断言必红
    mut_f01_hit=$( (
        _reject_ctrl_fields() { return 0; }
        _yaml_quote() { printf '%s' "$1"; }
        evil=$(jq -nc '{v:"2",ps:"e",add:"198.51.100.1",port:"443",id:"u1\n  external-controller: 0.0.0.0:9090",aid:"0",net:"tcp",tls:"tls",sni:"a.example"}' | base64 -w 0)
        external_link_to_clash "vmess://${evil}" 2>/dev/null
    ) )
    check 'Mutation M1 (F01): removing serializer+ctrl guard leaks injected YAML key (proves test sensitivity)' \
        grep -Fq 'external-controller: 0.0.0.0:9090' <<<"$mut_f01_hit"

    # M2: 回退 F03 恢复 issuer 名称回退 → 私有仿名 R3 CA 证书会误判通过，断言必红
    PKI="$SEC/mpki"; mkdir -p "$PKI" "$CFG/certs"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -keyout "$PKI/ca.key" -out "$PKI/ca.crt" -subj "/O=Let's Encrypt/CN=R3" -days 5 \
        -addext "basicConstraints=critical,CA:TRUE" 2>/dev/null
    openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -keyout "$CFG/certs/server.key" -out "$PKI/l.csr" -subj "/CN=evil.example" 2>/dev/null
    openssl x509 -req -in "$PKI/l.csr" -CA "$PKI/ca.crt" -CAkey "$PKI/ca.key" \
        -CAcreateserial -out "$CFG/certs/server.crt" -days 5 2>/dev/null
    mut_f03_rc=0
    (
        _is_real_cert() {
            local issuer; issuer=$(openssl x509 -in "$CFG/certs/server.crt" -noout -issuer 2>/dev/null)
            [[ "$issuer" == *"R3"* ]]
        }
        _is_real_cert
    ) || mut_f03_rc=$?
    check 'Mutation M2 (F03): issuer-fallback mutant falsely accepts spoofed R3 CA (while real _is_real_cert rejects)' \
        bash -c '[[ "$1" -eq 0 ]] && ! _is_real_cert "evil.example" "$2"' _ "$mut_f03_rc" "$CFG/certs/server.key"

    # M3: 回退 F04 去掉 auto-stop 恢复逻辑 → 全禁用再启用后服务仍停，断言必红
    mut_f04_ok=$( (
        mkdir -p "$CFG/certs/hy2"; echo c >"$CFG/certs/hy2/server.crt"; echo k >"$CFG/certs/hy2/server.key"
        write_db <<<'{"version":"4.0.0","xray":{},"singbox":{"hy2":{"port":24443,"password":"p","sni":"h.example","users":[{"name":"u1","uuid":"pw","enabled":true}]}},"meta":{}}'
        SB="$SEC/m_sb"; : >"$SB"
        svc() { case "$1" in status) [[ -e "$SB" ]];; stop) rm -f "$SB";; start|restart) : >"$SB";; esac; }
        # 变异：不写 auto-stop 标记
        db_set_user_enabled singbox hy2 u1 false >/dev/null 2>&1
        rm -f "$CFG/.singbox-stopped-empty"
        db_set_user_enabled singbox hy2 u1 true >/dev/null 2>&1
        [[ ! -e "$SB" ]] && echo "STAYED_STOPPED"
    ) )
    check 'Mutation M3 (F04): without auto-stop marker, service stays stopped on re-enable (proves F04 fix is required)' \
        eq "$mut_f04_ok" "STAYED_STOPPED"

    # M4: 回退 F05 备份失败继续覆盖 → nginx -t 失败后原配置被删除，断言必红
    mut_f05_deleted=$( (
        mkdir -p "$SEC/m_ng"
        printf 'ORIG\n' >"$SEC/m_ng/site"
        printf 'BAD\n' >"$SEC/m_ng/new"
        nginx() { return 1; }
        _nginx_install_conf_mutant() {
            local src="$1" dest="$2" bak=""
            [[ -e "$dest" ]] && { bak=""; }
            cp -f "$src" "$dest"
            if ! nginx -t &>/dev/null; then
                if [[ -n "$bak" ]]; then cp -pf "$bak" "$dest"; else rm -f "$dest"; fi
                return 1
            fi
        }
        _nginx_install_conf_mutant "$SEC/m_ng/new" "$SEC/m_ng/site" 2>/dev/null || true
        [[ ! -e "$SEC/m_ng/site" ]] && echo "DELETED_ORIG"
    ) )
    check 'Mutation M4 (F05): backup-failure-continues mutant deletes original config (proves F05 gate is required)' \
        eq "$mut_f05_deleted" "DELETED_ORIG"
)

for sec in sec_f01_yaml_injection sec_f02_tls_policy sec_f03_cert_verify sec_f04_singbox_auto_recovery sec_f05_nginx_backup_gate sec_f06_clash_yaml_import sec_f07_debian_install_deps sec_f08_sub_url_redaction sec_r01_r03_traffic sec_mutations; do
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
    printf 'PASS: H18 audit remediation & mutation regression (%d assertions)\n' "$pass"
else
    grep '^FAIL' "$RESULTS" >&2
    printf 'FAIL: H18 audit remediation & mutation regression (%d failed, %d passed)\n' "$fail" "$pass" >&2
    exit 1
fi
