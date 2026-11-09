#!/bin/bash
# h8 回归：Reality 多端口 target 不得依赖本机固定 8443/Nginx；watchdog 必须自包含进程检测函数。
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/vless-server.sh"
fail=0
pass=0

check() {
    local name="$1" rc="$2"
    if [[ "$rc" -eq 0 ]]; then
        echo "  OK   $name"
        ((pass++)) || true
    else
        echo "  FAIL $name"
        ((fail++)) || true
    fi
}

body_of() {
    local fn="$1"
    awk -v fn="$fn" '
        index($0, fn "()") == 1 {found=1; depth=0}
        found {
            print
            opens=gsub(/\{/, "{")
            closes=gsub(/\}/, "}")
            depth += opens - closes
            if (depth == 0) exit
        }
    ' "$SCRIPT"
}

inbound_body=$(body_of add_xray_inbound_v2)
server_scripts_body=$(body_of create_server_scripts)

if grep -q 'reality_dest="${sni}:443"' <<<"$inbound_body"; then
    check "Reality target 默认跟随所选 SNI:443" 0
else
    check "Reality target 默认跟随所选 SNI:443" 1
fi

if grep -Eq 'reality_dest="127\.0\.0\.1:8443"|_ensure_nginx_https_for_reality' <<<"$inbound_body"; then
    check "Reality target 不再改写为固定本机 8443/Nginx" 1
else
    check "Reality target 不再改写为固定本机 8443/Nginx" 0
fi

# 抽出 heredoc 生成的 watchdog，做语法与两轮存活进程检查。
watchdog=$(mktemp)
trap 'rm -f "$watchdog"' EXIT
awk '
    /cat > "\$CFG\/watchdog\.sh" << '\''EOFSCRIPT'\''/ {copy=1; next}
    copy && /^EOFSCRIPT$/ {exit}
    copy {print}
' "$SCRIPT" > "$watchdog"

if [[ -s "$watchdog" ]] && bash -n "$watchdog"; then
    check "生成的 watchdog 脚本语法有效" 0
else
    check "生成的 watchdog 脚本语法有效" 1
fi

if grep -q '^_pgrep()' "$watchdog" && grep -q 'if ! _pgrep "$proc_name"' "$watchdog"; then
    check "watchdog 自包含 _pgrep helper" 0
else
    check "watchdog 自包含 _pgrep helper" 1
fi

# 不执行 watchdog 的无限循环；只复用相同 helper 定义，连续检查当前 bash 两次。
helper=$(awk '/^_pgrep\(\)/,/^}/' "$watchdog")
if [[ -n "$helper" ]]; then
    eval "$helper"
    if _pgrep bash && _pgrep bash; then
        check "watchdog 进程检测连续两轮无 command-not-found" 0
    else
        check "watchdog 进程检测连续两轮无 command-not-found" 1
    fi
else
    check "watchdog 进程检测连续两轮无 command-not-found" 1
fi

if [[ "$fail" -eq 0 ]]; then
    echo "PASS: Reality target / watchdog 回归通过（$pass 条断言）"
else
    echo "FAIL: $fail 条断言失败（通过 $pass）"
    exit 1
fi
