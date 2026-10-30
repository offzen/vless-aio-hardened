#!/bin/bash
set -e
CFG="/tmp/vless-anytls-gen"; rm -rf "$CFG"; mkdir -p "$CFG"
echo "dummy" > "$CFG/anytls.join"
register_protocol() { echo "REGISTER proto=$1 core-write-json=$2" >> "$CFG/calls.log"; }
build_config() {
  local args=() keys=()
  while [[ $# -ge 2 ]]; do local k="$1" v="$2"; shift 2; keys+=("$k")
    if [[ "$v" =~ ^[0-9]+$ ]]; then args+=(--argjson "$k" "$v"); else args+=(--arg "$k" "$v"); fi; done
  args+=(--arg ipv4 "192.0.2.1" --arg ipv6 "")   # TEST-NET-1 保留段，仅文档/测试占位
  local expr="{"; local first=true
  for k in "${keys[@]}"; do if [[ "$first" == true ]]; then first=false; else expr+=","; fi; expr+="\"$k\":\$$k"; done
  expr+="}"; jq -n "${args[@]}" "$expr"
}
_save_join_info() { echo "SAVE: $1 | $2 | $3" >> "$CFG/calls.log"; }
_info() { echo "INFO: $*" >> "$CFG/calls.log"; }
_ok() { echo "OK: $*" >> "$CFG/calls.log"; }

awk '/^gen_anytls_server_config\(\)/,/^}/' vless-server.sh > /tmp/genfn.sh
sed '1d;$d' /tmp/genfn.sh > /tmp/genbody.sh
{ echo "gen_anytls_server_config() {"; cat /tmp/genbody.sh; echo "}"; } > /tmp/genwrapped.sh

source /tmp/genwrapped.sh
gen_anytls_server_config "testpw" 28443 "myreal.example.com"

echo "=== calls.log ==="
cat "$CFG/calls.log"
echo "=== role ==="
cat "$CFG/role"
echo "=== assertions ==="
fail=0
grep -q 'REGISTER proto=anytls' "$CFG/calls.log" || { echo "FAIL: register"; fail=1; }
grep -q '"password": *"testpw"' "$CFG/calls.log" || { echo "FAIL: password"; fail=1; }
grep -q '"port": *28443' "$CFG/calls.log" || { echo "FAIL: port"; fail=1; }
grep -q '"sni": *"myreal.example.com"' "$CFG/calls.log" || { echo "FAIL: sni"; fail=1; }
grep -q 'SAVE: anytls' "$CFG/calls.log" || { echo "FAIL: save_join"; fail=1; }
# 断言：AnyTLS 自签证书已生成（修复前该路径从不生成，sing-box 无真证书时会加载失败）
[[ -f "$CFG/certs/anytls/server.crt" && -f "$CFG/certs/anytls/server.key" ]] || { echo "FAIL: anytls self-signed cert missing"; fail=1; }
local_cn=$(openssl x509 -in "$CFG/certs/anytls/server.crt" -noout -subject 2>/dev/null | sed 's/.*CN *= *//')
[[ "$local_cn" == "myreal.example.com" ]] || { echo "FAIL: anytls cert CN ($local_cn) != sni"; fail=1; }
[[ "$(cat "$CFG/role")" == "server" ]] || { echo "FAIL: role"; fail=1; }
if [[ $fail -eq 0 ]]; then echo "PASS: gen_anytls_server_config 正确"; else exit 1; fi
