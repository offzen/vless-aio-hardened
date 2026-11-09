#!/bin/bash
# 单元测试：复刻 generate_singbox_config 的 anytls 分支核心逻辑（不 source 整个脚本）
set -e
CFG="/tmp/vless-singbox-test"
rm -rf "$CFG"; mkdir -p "$CFG"
DB_FILE="$CFG/db.json"
# 与 hy2 一致：DB 只存顶层 password/port/sni；多用户经 db_add_user 追加（凭证在 .uuid）
cat > "$DB_FILE" << 'J'
{
  "singbox": {
    "anytls": {
      "port": 18443, "password": "pw123", "sni": "example.com",
      "users": [ {"name":"alice","uuid":"alicesecret","enabled":true} ]
    }
  }
}
J
echo "example.com" > "$CFG/cert_domain"
mkdir -p "$CFG/certs"
openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) -keyout "$CFG/certs/server.key" -out "$CFG/certs/server.crt" -subj "/CN=example.com" -days 1 2>/dev/null
listen_addr="0.0.0.0"
proto="anytls"

cfg=$(jq -r --arg p "$proto" '.singbox[$p]' "$DB_FILE")
port=$(echo "$cfg" | jq -r '.port // empty')
password=$(echo "$cfg" | jq -r '.password // empty')
sni=$(echo "$cfg" | jq -r '.sni // "bing.com"')

cert_path="$CFG/certs/anytls/server.crt"
key_path="$CFG/certs/anytls/server.key"
[[ ! -f "$cert_path" ]] && { cert_path="$CFG/certs/server.crt"; key_path="$CFG/certs/server.key"; }
if [[ -f "$CFG/cert_domain" && -f "$CFG/certs/server.crt" ]]; then
  cert_domain=$(cat "$CFG/cert_domain" 2>/dev/null)
  if [[ "$sni" == "$cert_domain" ]]; then
    cert_path="$CFG/certs/server.crt"; key_path="$CFG/certs/server.key"
  fi
fi

users_json="[]"
db_users=$(jq -r --arg p "$proto" '
  .singbox[$p] as $cfg |
  if $cfg == null then empty
  elif ($cfg | type) == "array" then
    [$cfg[].users // [] | .[]] | unique_by(.name)
  else
    $cfg.users // []
  end
' "$DB_FILE" 2>/dev/null)
if [[ -n "$db_users" && "$db_users" != "[]" && "$db_users" != "null" ]]; then
  default_user_json=$(jq -n --arg pw "$password" '{name: "default", password: $pw}')
  users_json=$(jq -n --argjson db_users "$db_users" --argjson chk_def "$default_user_json" '[$chk_def] + ($db_users | map({name: .name, password: (.password // .uuid)}))')
else
  users_json=$(jq -n --arg pw "$password" '[{name: "default", password: $pw}]')
fi

inbound=$(jq -n \
  --argjson port "$port" --argjson users "$users_json" \
  --arg cert "$cert_path" --arg key "$key_path" --arg listen_addr "$listen_addr" \
'{
  type: "anytls", tag: "anytls-in", listen: $listen_addr, listen_port: $port,
  users: $users,
  tls: { enabled: true, certificate_path: $cert, key_path: $key, alpn: ["http/1.1"] }
}')

echo "=== RESULT inbound ==="
echo "$inbound" | jq .
echo ""
echo "=== ASSERTIONS ==="
fail=0
[[ "$(echo "$inbound" | jq -r '.type')" == "anytls" ]] || { echo "FAIL: type"; fail=1; }
[[ "$(echo "$inbound" | jq -r '.listen_port')" == "18443" ]] || { echo "FAIL: port"; fail=1; }
[[ "$(echo "$inbound" | jq -r '.tls.certificate_path')" == "$CFG/certs/server.crt" ]] || { echo "FAIL: cert_path not ACME (got $(echo "$inbound" | jq -r '.tls.certificate_path'))"; fail=1; }
nusers=$(echo "$inbound" | jq '.users | length')
[[ "$nusers" == "2" ]] || { echo "FAIL: user count $nusers != 2"; fail=1; }
echo "$inbound" | jq -e '.users[] | select(.name=="alice" and .password=="alicesecret")' >/dev/null || { echo "FAIL: alice user missing/wrong"; fail=1; }
echo "$inbound" | jq -e '.users[] | select(.name=="default" and .password=="pw123")' >/dev/null || { echo "FAIL: default user missing/wrong"; fail=1; }
echo "$inbound" | jq -e '.tls.alpn == ["http/1.1"]' >/dev/null || { echo "FAIL: alpn"; fail=1; }
echo "$inbound" | jq -e '.tls.enabled == true' >/dev/null || { echo "FAIL: tls.enabled"; fail=1; }

# 反向：sni 不匹配 cert_domain 时应回落自签证书（此时首选路径 $CFG/certs/anytls/server.crt 不存在 → 用全局自签）
if [[ $fail -eq 0 ]]; then echo "PASS: 全部断言通过 (真实证书路径 + 合成default + 合并alice + tls 开启)"; else echo "FAIL: 有断言未通过"; exit 1; fi

echo ""
echo "########## SCENARIO 2: sni != cert_domain (自签兜底) ##########"
CFG2="/tmp/vless-singbox-test2"; rm -rf "$CFG2"; mkdir -p "$CFG2"
cat > "$CFG2/db.json" << 'J'
{ "singbox": { "anytls": { "port": 34443, "password": "pwX", "sni": "other.bing.com" } } }
J
echo "example.com" > "$CFG2/cert_domain"
mkdir -p "$CFG2/certs"
openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) -keyout "$CFG2/certs/server.key" -out "$CFG2/certs/server.crt" -subj "/CN=example.com" -days 1 2>/dev/null
DB_FILE="$CFG2/db.json"; CFG="$CFG2"
cfg=$(jq -r --arg p "$proto" '.singbox[$p]' "$DB_FILE")
port=$(echo "$cfg" | jq -r '.port // empty'); password=$(echo "$cfg" | jq -r '.password // empty'); sni=$(echo "$cfg" | jq -r '.sni // "bing.com"')
cert_path="$CFG/certs/anytls/server.crt"; key_path="$CFG/certs/anytls/server.key"
[[ ! -f "$cert_path" ]] && { cert_path="$CFG/certs/server.crt"; key_path="$CFG/certs/server.key"; }
if [[ -f "$CFG/cert_domain" && -f "$CFG/certs/server.crt" ]]; then
  cert_domain=$(cat "$CFG/cert_domain" 2>/dev/null)
  if [[ "$sni" == "$cert_domain" ]]; then
    cert_path="$CFG/certs/server.crt"; key_path="$CFG/certs/server.key"
  fi
fi
users_json=$(jq -n --arg pw "$password" '[{name: "default", password: $pw}]')
inbound2=$(jq -n --argjson port "$port" --argjson users "$users_json" --arg cert "$cert_path" --arg key "$key_path" --arg listen_addr "$listen_addr" \
'{type:"anytls", listen_port:$port, users:$users, tls:{enabled:true, certificate_path:$cert, key_path:$key}}')
echo "cert_path chosen = $(echo "$inbound2" | jq -r '.tls.certificate_path')"
echo "port = $(echo "$inbound2" | jq -r '.listen_port')"
# sni=other.bing.com != cert_domain=example.com → 应用全局自签 $CFG2/certs/server.crt（anytls/ 自签目录不存在时回落全局）
# 注意：anytls/ 目录不存在 → 首选路径回落全局自签，这是预期的「自签兜底」。
fail2=0
[[ "$(echo "$inbound2" | jq -r '.listen_port')" == "34443" ]] || { echo "FAIL2: port"; fail2=1; }
[[ "$(echo "$inbound2" | jq -r '.tls.certificate_path')" == "$CFG2/certs/server.crt" ]] || { echo "FAIL2: fallback cert"; fail2=1; }
[[ "$(echo "$inbound2" | jq '.users|length')" == "1" ]] || { echo "FAIL2: users"; fail2=1; }
if [[ $fail2 -eq 0 ]]; then echo "PASS: 自签兜底正确 (sni 不匹配 → 全局自签证书, 单默认用户)"; else echo "FAIL2"; exit 1; fi
