#!/bin/bash
# 回归测试：HTTP-01 失败后的菜单选项 2 必须调用现有 DNS-01 实现，
# 且把证书目录一并传入；不能再次出现 get_acme_cert_dns: command not found。
# 同时约束 DNS-01 的真实故障：保留 acme.sh 返回码，不得被 grep 管道误判成功；
# Cloudflare token 必须先验证目标 zone；禁止组合会误命中 production 的 staging 参数。
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/vless-server.sh"
[[ -f "$SCRIPT" ]] || { echo "FAIL: 找不到 $SCRIPT" >&2; exit 1; }

pass=0
fail=0
check() { # description command-result
    if [[ "$2" == "0" ]]; then
        pass=$((pass + 1))
        echo "  OK   $1"
    else
        fail=$((fail + 1))
        echo "  FAIL $1" >&2
    fi
}

# 这个名字从未有实现；保留任何调用都会让用户从 HTTP 失败切 DNS 时直接崩溃。
if grep -Eq '^[[:space:]]*get_acme_cert_dns[[:space:]]' "$SCRIPT"; then
    check "不存在未定义的 get_acme_cert_dns 调用" 1
else
    check "不存在未定义的 get_acme_cert_dns 调用" 0
fi

# _issue_cert_dns 的签名是 domain/cert_dir/protocol；两个入口都必须传齐三参。
call_count=$(grep -Ec '^[[:space:]]*_issue_cert_dns "\$domain" "\$cert_dir" "\$protocol"[[:space:]]*$' "$SCRIPT")
if [[ "$call_count" == "2" ]]; then
    check "首次选择 DNS 与 HTTP 失败后切 DNS 共两个正确入口" 0
else
    echo "  INFO 正确调用数=$call_count（期望 2）" >&2
    check "首次选择 DNS 与 HTTP 失败后切 DNS 共两个正确入口" 1
fi

# 定义必须仍存在且恰好一个，防止测试只靠删除坏调用而误绿。
def_count=$(grep -Ec '^_issue_cert_dns\(\)[[:space:]]*\{' "$SCRIPT")
if [[ "$def_count" == "1" ]]; then
    check "DNS-01 实现定义存在且唯一" 0
else
    echo "  INFO 定义数=$def_count（期望 1）" >&2
    check "DNS-01 实现定义存在且唯一" 1
fi

# grep/sed 仅用于展示日志，不能成为 if 的判据；应先保存 acme.sh 自身退出码。
if grep -Fq 'acme_rc=$?' "$SCRIPT" \
  && grep -Eq 'if \[\[ "?\$acme_rc"? -eq 0 \]\]' "$SCRIPT"; then
    check "DNS-01 以 acme.sh 本身退出码判定成功" 0
else
    check "DNS-01 以 acme.sh 本身退出码判定成功" 1
fi

# Cloudflare token active 不代表能访问目标 zone；签发前必须做 verify + zone lookup。
if grep -Fq '_preflight_cloudflare_token "$domain" "$cf_token"' "$SCRIPT" \
  && grep -Fq '/user/tokens/verify' "$SCRIPT" \
  && grep -Fq 'https://api.cloudflare.com/client/v4/zones' "$SCRIPT"; then
    check "Cloudflare token 在 CA 下单前验证状态与目标 zone 可见性" 0
else
    check "Cloudflare token 在 CA 下单前验证状态与目标 zone 可见性" 1
fi

# example.com 是保留示例域；不能再把它作为真实 ACME 联系邮箱写入账户。
if grep -Eq '^readonly ACME_DEFAULT_EMAIL="admin@example\.com"$' "$SCRIPT"; then
    check "不再把保留示例域邮箱注册到 ACME" 1
else
    check "不再把保留示例域邮箱注册到 ACME" 0
fi

# DNS-01 的正式路径必须明确固定 production LE；若日后新增 staging 验证，不能把
# `--server letsencrypt --staging` 当成 staging（acme.sh v3.1.7 会让显式 server 优先）。
if grep -Eq -- '--server letsencrypt[^\n]*--staging|--staging[^\n]*--server letsencrypt' "$SCRIPT"; then
    check "不组合会误命中 production 的 letsencrypt + staging 参数" 1
else
    check "不组合会误命中 production 的 letsencrypt + staging 参数" 0
fi

if [[ "$fail" -eq 0 ]]; then
    echo "PASS: ACME DNS fallback 回归测试通过（$pass 条断言）"
else
    echo "FAIL: $fail 条断言失败（通过 $pass 条）" >&2
    exit 1
fi
