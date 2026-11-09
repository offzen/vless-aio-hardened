#!/bin/bash
# h8/h9 回归：协议安装/证书路径不得隐式配置 Nginx；订阅只能经菜单 6 显式 opt-in。
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

setup_body=$(body_of setup_cert_and_nginx)
acme_body=$(body_of get_acme_cert)
dns_body=$(body_of _issue_cert_dns)
manual_body=$(body_of _issue_cert_dns_manual)
sub_body=$(body_of setup_subscription_interactive)
manage_body=$(body_of manage_subscription)
uninstall_body=$(body_of do_uninstall)
create_body=$(body_of create_fake_website)
nginx_body=$(body_of setup_nginx_sub)
generate_body=$(body_of generate_sub_files)

[[ -n "$setup_body" && -n "$sub_body" ]] || { echo "FAIL: 函数抽取失败"; exit 1; }

if grep -Eq 'create_fake_website|generate_sub_files|install_nginx|systemctl (start|stop|restart|enable) nginx|rc-service nginx (start|stop|restart)' <<<"$setup_body"; then
    check "证书配置函数不隐式配置/启停订阅 Nginx" 1
else
    check "证书配置函数不隐式配置/启停订阅 Nginx" 0
fi

if grep -Eq 'create_fake_website|svc (stop|restart) nginx|systemctl (stop|restart) nginx|rc-service nginx (stop|restart)' <<<"$acme_body$dns_body$manual_body"; then
    check "证书签发路径不隐式创建订阅或停止/重启 Nginx" 1
else
    check "证书签发路径不隐式创建订阅或停止/重启 Nginx" 0
fi

if grep -Eq 'SUBSCRIPTION_EXPLICIT_ENABLE:-false.*!=.*true' <<<"$create_body" &&
   grep -Eq 'SUBSCRIPTION_EXPLICIT_ENABLE:-false.*!=.*true' <<<"$nginx_body" &&
   grep -Eq '! -f.*sub.info.*SUBSCRIPTION_EXPLICIT_ENABLE:-false.*!=.*true' <<<"$generate_body"; then
    check "首次生成订阅和 Nginx 配置均具备显式 opt-in 守卫" 0
else
    check "首次生成订阅和 Nginx 配置均具备显式 opt-in 守卫" 1
fi

if grep -q 'local SUBSCRIPTION_EXPLICIT_ENABLE=true' <<<"$sub_body" &&
   grep -q '确认显式启用订阅服务' <<<"$sub_body" &&
   grep -q 'install_nginx' <<<"$sub_body"; then
    check "菜单 6 是显式启用入口且确认后才安装 Nginx" 0
else
    check "菜单 6 是显式启用入口且确认后才安装 Nginx" 1
fi

if grep -Eq 'systemctl stop nginx|rc-service nginx stop|svc stop nginx|systemctl disable nginx|rc-update del nginx' <<<"$sub_body$manage_body$uninstall_body"; then
    check "停用/重配/卸载不停止或禁用共享 Nginx" 1
else
    check "停用/重配/卸载不停止或禁用共享 Nginx" 0
fi

if grep -q 'rm -f /etc/nginx/sites-enabled/default' <<<"$SCRIPT"; then
    check "源码不删除发行版默认 Nginx 站点" 1
else
    check "源码不删除发行版默认 Nginx 站点" 0
fi

if grep -Eq '(rm -rf|rm -f).*\/var\/www\/html\/index\.html' <<<"$uninstall_body"; then
    check "卸载不再无条件删除共享 Web 首页" 1
elif grep -q 'cleanup_webroot_placeholder' <<<"$uninstall_body"; then
    check "卸载不再无条件删除共享 Web 首页" 0
else
    check "卸载不再无条件删除共享 Web 首页" 1
fi

if grep -Eq 'reality_cert_choice.*==.*2' <<<"$setup_body" &&
   ! awk '/reality_cert_choice.*==.*2/,/return 0/' <<<"$setup_body" | grep -Eq 'rm -f.*server\.(crt|key)|rm -f.*cert_domain'; then
    check "Reality 随机 SNI 不删除共享证书" 0
else
    check "Reality 随机 SNI 不删除共享证书" 1
fi

if [[ "$fail" -eq 0 ]]; then
    echo "PASS: 订阅/Nginx 默认关闭回归通过（$pass 条断言）"
else
    echo "FAIL: $fail 条断言失败（通过 $pass）"
    exit 1
fi
