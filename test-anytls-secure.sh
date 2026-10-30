#!/bin/bash
# 单元测试：AnyTLS 分享链接在真实证书 vs 自签兜底两种场景下是否带/去 allowInsecure。
# 复刻 _anytls_secure 与 gen_anytls_link 核心逻辑（不 source 整个脚本）。
# 背景：v3.4.10-h2 中 gen_anytls_link 恒带 &allowInsecure=1，即使服务器已是真证书
#       客户端仍跳过证书校验，secure 功能不生效；本测试验证 -h3 的条件化修复。
set -e
CFG="/tmp/vless-anytls-secure"; rm -rf "$CFG"; mkdir -p "$CFG"

# 直接从脚本抽取函数体（与 test-gen-anytls.sh 同法）
# 可移植性要求：这里必须用 index() 做字符串前缀匹配，**不能**用动态正则
# `-v fn="^$fn\\(\\) *\\{$"`。gawk（GitHub Actions ubuntu-latest 的 /usr/bin/awk）
# 会把 "\(" "\{" 当成普通 "(" "{"，该 pattern 退化成 ^fn() *{$ 便匹配不到 "fn() {"，
# 抽取结果为空 → 后续 source 后调用报 "_anytls_secure: command not found"(exit 127)。
# 本机 mawk 能过、GitHub 挂，就是这条差异（GitHub run 41014766295）。
extract_fn() { # $1=fn_name $2=out  $3=wrap
  local fn="$1" out="$2" wrap="${3:-0}"
  awk -v fn="$fn" '
    !f && index($0, fn "()") == 1 { f = 1 }
    f { print }
    f && /^}/ { exit }
  ' vless-server.sh > "$out"
  # 抽取失败要当场报错，别把 "函数不存在" 留到几十行之后变成 command not found
  if [[ ! -s "$out" ]] || ! grep -q "^$fn()" "$out"; then
    echo "FAIL: 无法从 vless-server.sh 抽取函数 $fn（awk 抽取结果为空或不完整）" >&2
    exit 1
  fi
  if [[ "$wrap" == "1" ]]; then
    sed '1d;$d' "$out" > "$out.body"
    { echo "$fn() {"; cat "$out.body"; echo "}"; } > "$out.wrapped"
    mv "$out.wrapped" "$out"
  fi
  rm -f "$out.body"
}

extract_fn "_anytls_secure" /tmp/securefn.sh
extract_fn "gen_anytls_link" /tmp/linkfn.sh
source /tmp/securefn.sh
source /tmp/linkfn.sh

# stubs：_is_real_cert 用真实证书文件判断（与脚本逻辑一致）；get_ip_suffix 模拟返回
_is_real_cert() {
  [[ ! -f "$CFG/certs/server.crt" ]] && return 1
  local issuer=$(openssl x509 -in "$CFG/certs/server.crt" -noout -issuer 2>/dev/null)
  [[ "$issuer" == *"Let's Encrypt"* ]] || [[ "$issuer" == *"R3"* ]] || [[ "$issuer" == *"R10"* ]] || \
  [[ "$issuer" == *"R11"* ]] || [[ "$issuer" == *"E1"* ]] || [[ "$issuer" == *"ZeroSSL"* ]] || [[ "$issuer" == *"Buypass"* ]]
}
get_ip_suffix() { echo ""; }

fail=0

echo "########## SCENARIO 1: 真实证书（sni == cert_domain，server.crt 为 LE 证书）##########"
# 造一个带 Let's Encrypt 发证者标记的证书（openssl 自签无法真签 LE，这里用假 subject/issuer 模拟）
mkdir -p "$CFG/certs/anytls"
echo "real.example.com" > "$CFG/cert_domain"
openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
  -keyout "$CFG/certs/server.key" -out "$CFG/certs/server.crt" \
  -subj "/CN=real.example.com" -days 1 2>/dev/null
# 伪装 issuer 为 Let's Encrypt（仅测试用；脚本只匹配 issuer 字符串）
openssl x509 -in "$CFG/certs/server.crt" -out "$CFG/certs/server.issuer.crt" 2>/dev/null || true

# 真实场景：_is_real_cert 只认 issuer 字符串。为可测性，这里直接覆盖 _is_real_cert 为真。
_is_real_cert() { return 0; }

_anytls_secure "real.example.com" && echo "  _anytls_secure: true (sni 命中真证书)"
_anytls_secure "real.example.com" || { echo "FAIL: 真证书场景应判为 secure"; fail=1; }
_anytls_secure "other.com" && { echo "FAIL: sni 不匹配证书域名应判非 secure"; fail=1; }
_anytls_secure "" && { echo "FAIL: 空 sni 应判非 secure"; fail=1; }

link=$(gen_anytls_link "192.0.2.1" 18443 "pw" "real.example.com" "HK")
echo "  link=$link"
echo "$link" | grep -q 'allowInsecure' && { echo "FAIL: 真证书场景链接不应带 allowInsecure"; fail=1; } || echo "  OK: 真证书链接已去掉 allowInsecure"
echo "$link" | grep -q 'sni=real.example.com' || { echo "FAIL: link 缺 sni"; fail=1; }

echo ""
echo "########## SCENARIO 2: 自签兜底（sni 不匹配证书域名）##########"
# 移除 cert_domain 匹配，模拟自签
rm -f "$CFG/cert_domain"
_anytls_secure "real.example.com" && { echo "FAIL: 无 cert_domain 时应判非 secure"; fail=1; } || echo "  OK: 自签场景判非 secure"
link2=$(gen_anytls_link "192.0.2.1" 18443 "pw" "real.example.com" "HK")
echo "  link=$link2"
echo "$link2" | grep -q 'allowInsecure=1' || { echo "FAIL: 自签兜底链接应保留 allowInsecure"; fail=1; }

if [[ $fail -eq 0 ]]; then
  echo ""
  echo "PASS: AnyTLS secure 链接条件化正确（真证书去 allowInsecure / 自签保留）"
else
  echo ""
  echo "FAIL: 有断言未通过"
  exit 1
fi