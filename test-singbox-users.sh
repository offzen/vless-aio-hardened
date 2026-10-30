#!/bin/bash
# 功能测试：运行真实的 generate_singbox_config（从 vless-server.sh 提取），
# 验证 h4 修复：多端口展开 / 禁用用户过滤 / 过期用户过滤 / sniff 路由 / tag 后缀
# 用法: bash test-singbox-users.sh [vless-server.sh 路径]
set -uo pipefail
SCRIPT="${1:-$(dirname "$0")/vless-server.sh}"
[[ -f "$SCRIPT" ]] || { echo "找不到脚本: $SCRIPT"; exit 2; }

CFG="/tmp/h4-test-cfg"
rm -rf "$CFG"; mkdir -p "$CFG"
DB_FILE="$CFG/db.json"
export CFG DB_FILE

# ---- 从真实脚本中抽取 generate_singbox_config ----
awk '/^generate_singbox_config\(\)/{f=1} f{print} f&&/^}$/{exit}' "$SCRIPT" > /tmp/h4-gsb.sh
[[ -s /tmp/h4-gsb.sh ]] || { echo "抽取失败"; exit 2; }

# ---- 桩函数：从 db.json 读取 ----
db_get() { jq -c --arg c "$1" --arg p "$2" '.[$c][$p] // empty' "$DB_FILE" 2>/dev/null; }
db_list_protocols() { jq -r --arg c "$1" '(.[$c] // {}) | keys[]' "$DB_FILE" 2>/dev/null; }
db_get_routing_rules() { jq -c '.routing_rules // []' "$DB_FILE" 2>/dev/null; }
db_get_balancer_groups() { echo "[]"; }
db_get_warp_mode() { echo ""; }
_listen_addr() { echo "0.0.0.0"; }
_ok() { :; }
_err() { echo "ERR: $*" >&2; }

source /tmp/h4-gsb.sh

# ============ 场景1：单端口 + 多用户（enabled true/false + 过期） ============
cat > "$DB_FILE" <<'J'
{
  "singbox": {
    "anytls": {
      "port": 18443, "password": "topsecret", "sni": "example.com",
      "users": [
        {"name":"alice","uuid":"alicepw","enabled":true,"quota":0,"used":0,"expire_date":""},
        {"name":"bob","uuid":"bobpw","enabled":false,"quota":0,"used":0,"expire_date":""},
        {"name":"carol","uuid":"carolpw","enabled":true,"quota":0,"used":0,"expire_date":"2020-01-01"}
      ]
    }
  }
}
J

fail=0
echo "===== 场景1: 单端口 + 多用户 ====="
if generate_singbox_config >/tmp/h4-gen1.log 2>&1; then
  echo "[gen ok]"
else
  echo "[gen FAILED]"; cat /tmp/h4-gen1.log; fail=1
fi

J1="$CFG/singbox.json"
echo "--- singbox.json ---"
jq . "$J1" 2>/dev/null || { echo "INVALID JSON"; fail=1; }

# 断言：anytls inbound 存在且端口正确
[[ "$(jq -r '.inbounds[] | select(.type=="anytls") | .listen_port' "$J1" 2>/dev/null)" == "18443" ]] \
  || { echo "FAIL: anytls inbound 端口不对"; fail=1; }

# 断言：alice 在，bob（禁用）不在，carol（过期）不在
jq -e '.inbounds[] | select(.type=="anytls") | .users[] | select(.name=="alice" and .password=="alicepw")' "$J1" >/dev/null 2>&1 \
  || { echo "FAIL: alice 缺失或密码不对"; fail=1; }
jq -e '.inbounds[] | select(.type=="anytls") | .users[] | select(.name=="bob")' "$J1" >/dev/null 2>&1 \
  && { echo "FAIL: bob(禁用) 不应出现"; fail=1; }
jq -e '.inbounds[] | select(.type=="anytls") | .users[] | select(.name=="carol")' "$J1" >/dev/null 2>&1 \
  && { echo "FAIL: carol(过期) 不应出现"; fail=1; }

# 断言：default 用户存在且无重复
defcount=$(jq -r '[.inbounds[] | select(.type=="anytls") | .users[] | select(.name=="default")] | length' "$J1" 2>/dev/null)
[[ "$defcount" == "1" ]] || { echo "FAIL: default 用户数 $defcount != 1"; fail=1; }

# 断言：sniff 动作在 route.rules 首位
[[ "$(jq -r '.route.rules[0].action' "$J1" 2>/dev/null)" == "sniff" ]] \
  || { echo "FAIL: route.rules[0].action != sniff (实际: $(jq -r '.route.rules[0].action' "$J1" 2>/dev/null))"; fail=1; }

# 断言：bittorrent 拦截规则存在
jq -e '.route.rules[] | select(.protocol==["bittorrent"] and .outbound=="block")' "$J1" >/dev/null 2>&1 \
  || { echo "FAIL: bittorrent 拦截规则缺失"; fail=1; }

# 断言：私网 ip_cidr 拦截仍在
jq -e '.route.rules[] | select(.ip_cidr != null and .outbound=="block")' "$J1" >/dev/null 2>&1 \
  || { echo "FAIL: 私网 ip_cidr 拦截缺失"; fail=1; }

# ============ 场景2：多端口数组 ============
echo ""
echo "===== 场景2: 多端口数组 ====="
cat > "$DB_FILE" <<'J'
{
  "singbox": {
    "anytls": [
      {"port": 18443, "password": "pw1", "sni": "example.com", "users": [{"name":"u1","uuid":"p1","enabled":true}]},
      {"port": 18444, "password": "pw2", "sni": "example.com", "users": [{"name":"u2","uuid":"p2","enabled":true}]}
    ]
  }
}
J
rm -f "$CFG/singbox.json"
generate_singbox_config >/tmp/h4-gen2.log 2>&1 || { echo "[gen2 FAILED]"; cat /tmp/h4-gen2.log; fail=1; }
J2="$CFG/singbox.json"
echo "--- inbounds (type/port/tag) ---"
jq -r '.inbounds[] | "\(.type) port=\(.listen_port) tag=\(.tag)"' "$J2" 2>/dev/null

n=$(jq -r '[.inbounds[] | select(.type=="anytls")] | length' "$J2" 2>/dev/null)
[[ "$n" == "2" ]] || { echo "FAIL: 多端口应生成 2 个 anytls inbound，实际 $n"; fail=1; }
[[ "$(jq -r '.inbounds[] | select(.type=="anytls" and .listen_port==18443) | .tag' "$J2" 2>/dev/null)" == "anytls-in-18443" ]] \
  || { echo "FAIL: 18443 tag 后缀不对"; fail=1; }
[[ "$(jq -r '.inbounds[] | select(.type=="anytls" and .listen_port==18444) | .tag' "$J2" 2>/dev/null)" == "anytls-in-18444" ]] \
  || { echo "FAIL: 18444 tag 后缀不对"; fail=1; }
# 每个端口各自的用户
jq -e '.inbounds[] | select(.listen_port==18443) | .users[] | select(.name=="u1")' "$J2" >/dev/null 2>&1 \
  || { echo "FAIL: 18443 缺 u1"; fail=1; }
jq -e '.inbounds[] | select(.listen_port==18444) | .users[] | select(.name=="u2")' "$J2" >/dev/null 2>&1 \
  || { echo "FAIL: 18444 缺 u2"; fail=1; }

# ============ 场景3：hy2 + tuic 多端口也展开 ============
echo ""
echo "===== 场景3: hy2/tuic 多端口 ====="
cat > "$DB_FILE" <<'J'
{
  "singbox": {
    "hy2": [{"port": 20001, "password": "h1", "sni": "a.com"}, {"port": 20002, "password": "h2", "sni": "a.com"}],
    "tuic": [{"port": 30001, "uuid": "t1u", "password": "t1p", "sni": "a.com"}]
  }
}
J
rm -f "$CFG/singbox.json"
generate_singbox_config >/tmp/h4-gen3.log 2>&1 || { echo "[gen3 FAILED]"; cat /tmp/h4-gen3.log; fail=1; }
J3="$CFG/singbox.json"
jq -r '.inbounds[] | "\(.type) port=\(.listen_port) tag=\(.tag)"' "$J3" 2>/dev/null
[[ "$(jq -r '[.inbounds[] | select(.type=="hysteria2")] | length' "$J3" 2>/dev/null)" == "2" ]] \
  || { echo "FAIL: hy2 多端口应为 2"; fail=1; }
[[ "$(jq -r '.inbounds[] | select(.type=="hysteria2" and .listen_port==20001) | .tag' "$J3" 2>/dev/null)" == "hy2-in-20001" ]] \
  || { echo "FAIL: hy2 tag 后缀"; fail=1; }

echo ""
if [[ $fail -eq 0 ]]; then
  echo "===== ALL PASS ====="
else
  echo "===== FAILURES PRESENT ====="
  exit 1
fi
