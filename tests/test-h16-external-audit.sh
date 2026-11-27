#!/bin/bash
# H17 第二轮外部审计整改回归：
#   A1 旧单用户安装后立即添加用户，不得让原用户凭据失效（含 TUIC 独立 password、SOCKS 账号名）
#   A2 TUIC 升级迁移必须保存原用户独立 password；已被旧版迁移坏的 DB 渲染时回退顶层 password
#   A3 AnyTLS 迁移器：备用 --db 不碰生产服务；接管未验证时回滚并重新拉起旧服务；验证通过才停旧服务
#   A4 按端口卸载预检失败不得停共享核心/删好配置；菜单 14 预检失败返回非 0 且不重启
#   A5 到期撤销：DB 已禁用但重载失败，下一轮必须重试直到成功
#   A6 分享链接生成对自定义口令不得二次 Shell 解释
#   A7 完整卸载不得仅因主机存在 warp-cli 就移除由其它应用使用的 WARP
#   A8 协议注册写库失败须中止且不生成链接   A9 订阅只导出生效用户   A10 流量入账幂等（崩溃重放不重复）
#   A11 自更新备份失败即中止   A12 DB 损坏≠有效空库   A13 订阅重配置事务化   A14 TUIC 入站/导出证书一致
# 全部离线：外部边界（systemctl/ss/sing-box/xray/svc）均用桩替换；每个分区在独立子 shell 重新 source 产品脚本。
set -uo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")/.." && pwd)
PRODUCT="${1:-$ROOT/vless-server.sh}"
MIGRATE="$ROOT/migrate-anytls-singbox.sh"
[[ -f "$PRODUCT" ]] || { echo "FAIL: missing product: $PRODUCT" >&2; exit 2; }
[[ -f "$MIGRATE" ]] || { echo "FAIL: missing migrator: $MIGRATE" >&2; exit 2; }
for dep in jq awk grep sed sha256sum mktemp; do
    command -v "$dep" >/dev/null 2>&1 || { echo "FAIL: missing dependency: $dep" >&2; exit 2; }
done

TMP=$(mktemp -d "${TMPDIR:-/tmp}/aio-h17.XXXXXX")
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
    set +u   # 产品脚本本身不在 nounset 下运行；测试桩外的产品函数不应因此中止
    [[ "$CFG" == "$SEC/cfg" ]] || { echo "FAIL isolation" >>"$RESULTS"; exit 2; }
    _ok() { :; }; _info() { :; }; _warn() { :; }; _log() { :; }
    _err() { printf '%s\n' "$*" >&2; }
    export PATH="$SEC/bin:$PATH"
    crontab() { echo "crontab $*" >>"$TMP/crontab-guard.log"; return 1; }
    ensure_expire_check_cron() { :; }; ensure_traffic_cron() { :; }
}
check() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then echo "OK   $desc" >>"$RESULTS"; printf '  OK   %s\n' "$desc"
    else echo "FAIL $desc" >>"$RESULTS"; printf '  FAIL %s\n' "$desc" >&2; fi
}
eq() { [[ "$1" == "$2" ]]; }
write_db() { cat >"$DB_FILE"; chmod 600 "$DB_FILE"; }

# ═════════════ A1 旧单用户 → 添加首个用户不得丢原用户 ═════════════
sec_add_first_user() ( fresh_env addfirst
    rebuild_and_reload_xray() { return 0; }
    rebuild_and_reload_singbox() { return 0; }
    write_db <<'J'
{"version":"4.0.0","xray":{
  "vless-ws":{"port":8443,"uuid":"aaaaaaaa-0000-4000-8000-000000000001","path":"/ws","sni":"x.example"},
  "socks":{"port":1080,"username":"admin","uuid":"stale-socks-uuid","password":"s3cret"},
  "trojan":{"port":9443,"uuid":"stale-trojan-uuid","password":"trojan-own-pass","sni":"tr.example"},
  "ss-legacy":{"port":10443,"method":"aes-256-gcm","uuid":"stale-ss-uuid","password":"ss-own-pass"}},
 "singbox":{"tuic":{"port":4443,"uuid":"bbbbbbbb-0000-4000-8000-000000000002","password":"tuic-own-pass","sni":"t.example"},
            "hy2":{"port":5443,"uuid":"stale-hy2-uuid","password":"hy2pass","sni":"h.example"},
            "anytls":{"port":6443,"uuid":"stale-anytls-uuid","password":"anytls-own-pass","sni":"a.example"}},"meta":{}}
J
    db_add_user xray vless-ws alice cccccccc-0000-4000-8000-000000000003 0 ''
    check 'A1 vless-ws: add succeeds on a legacy single-user config' eq "$?" 0
    check 'A1 vless-ws: original user is preserved as default with its original uuid' \
        eq "$(db_get_user_field xray vless-ws default uuid)" aaaaaaaa-0000-4000-8000-000000000001
    clients=$(gen_xray_vless_clients vless-ws "")
    check 'A1 vless-ws: rendered clients still contain the original link uuid' \
        jq -e 'any(.[]; .id == "aaaaaaaa-0000-4000-8000-000000000001")' <<<"$clients"
    check 'A1 vless-ws: rendered clients contain the new user too' \
        jq -e 'any(.[]; .id == "cccccccc-0000-4000-8000-000000000003")' <<<"$clients"

    pre_socks_pw=$(_cfg_effective socks "$(db_get xray socks)" | jq -r '.password')
    db_add_user xray socks bob bobpass 0 ''
    post_socks_pw=$(_cfg_effective socks "$(db_get xray socks)" | jq -r '.password')
    check 'A1 socks: original account keeps its username (not renamed to default)' \
        eq "$(jq -r '.xray.socks.users[0].name' "$DB_FILE")" admin
    check 'A1 socks: original effective password is preserved even with stale top-level uuid' \
        bash -c '[[ "$1" == "s3cret" && "$2" == "s3cret" ]]' _ "$pre_socks_pw" "$post_socks_pw"

    pre_trojan_pw=$(_cfg_effective trojan "$(db_get xray trojan)" | jq -r '.password')
    db_add_user xray trojan frank frankpass 0 ''
    post_trojan_pw=$(_cfg_effective trojan "$(db_get xray trojan)" | jq -r '.password')
    check 'A1 trojan: effective password unchanged across migration with stale top-level uuid' \
        bash -c '[[ "$1" == "trojan-own-pass" && "$2" == "trojan-own-pass" ]]' _ "$pre_trojan_pw" "$post_trojan_pw"
    check 'A1 trojan: rendered clients keep original password' \
        jq -e 'any(.[]; .password == "trojan-own-pass")' <<<"$(gen_xray_trojan_clients trojan "")"

    pre_ss_pw=$(_cfg_effective ss-legacy "$(db_get xray ss-legacy)" | jq -r '.password')
    db_add_user xray ss-legacy grace gracepass 0 ''
    post_ss_pw=$(_cfg_effective ss-legacy "$(db_get xray ss-legacy)" | jq -r '.password')
    check 'A1 ss-legacy: effective password unchanged across migration with stale top-level uuid' \
        bash -c '[[ "$1" == "ss-own-pass" && "$2" == "ss-own-pass" ]]' _ "$pre_ss_pw" "$post_ss_pw"
    check 'A1 ss-legacy: rendered clients keep original password' \
        jq -e 'any(.[]; .password == "ss-own-pass")' <<<"$(gen_xray_ss_legacy_clients ss-legacy "")"

    db_add_user singbox tuic carol dddddddd-0000-4000-8000-000000000004 0 ''
    check 'A1 tuic: default keeps the original independent password' \
        eq "$(jq -r '.singbox.tuic.users[] | select(.name=="default") | .password' "$DB_FILE")" tuic-own-pass
    check 'A1 tuic: default keeps the original uuid' \
        eq "$(jq -r '.singbox.tuic.users[] | select(.name=="default") | .uuid' "$DB_FILE")" bbbbbbbb-0000-4000-8000-000000000002

    pre_hy2_pw=$(_cfg_effective hy2 "$(db_get singbox hy2)" | jq -r '.password')
    db_add_user singbox hy2 dave eeeeeeee-0000-4000-8000-000000000005 0 ''
    post_hy2_pw=$(_cfg_effective hy2 "$(db_get singbox hy2)" | jq -r '.password')
    check 'A1 hy2: effective password survives adding a user even with stale top-level uuid' \
        bash -c '[[ "$1" == "hy2pass" && "$2" == "hy2pass" ]]' _ "$pre_hy2_pw" "$post_hy2_pw"

    pre_anytls_pw=$(_cfg_effective anytls "$(db_get singbox anytls)" | jq -r '.password')
    db_add_user singbox anytls heidi heidipass 0 ''
    post_anytls_pw=$(_cfg_effective anytls "$(db_get singbox anytls)" | jq -r '.password')
    check 'A1 anytls: effective password unchanged across migration with stale top-level uuid' \
        bash -c '[[ "$1" == "anytls-own-pass" && "$2" == "anytls-own-pass" ]]' _ "$pre_anytls_pw" "$post_anytls_pw"
    check 'A1 anytls: default record persists explicit password field' \
        eq "$(jq -r '.singbox.anytls.users[] | select(.name=="default") | .password' "$DB_FILE")" anytls-own-pass
    generate_singbox_config >/dev/null 2>&1
    check 'A1 anytls: rendered singbox inbound keeps original effective password' \
        jq -e '.inbounds[] | select(.type=="anytls") | any(.users[]; .password == "anytls-own-pass")' "$CFG/singbox.json"
    check 'A1 hy2: rendered singbox inbound keeps original effective password' \
        jq -e '.inbounds[] | select(.type=="hysteria2") | any(.users[]; .password == "hy2pass")' "$CFG/singbox.json"

    check 'A1 only one write path: second add does not duplicate default' \
        eq "$(db_add_user xray vless-ws erin ffffffff-0000-4000-8000-000000000006 0 ''; jq '[.xray["vless-ws"].users[] | select(.name=="default")] | length' "$DB_FILE")" 1
)

# ═════════════ A2 TUIC 升级迁移保存独立 password / 渲染回退 ═════════════
sec_tuic_password() ( fresh_env tuic
    _render_tuic_users() { jq -c '.inbounds[] | select(.type=="tuic") | .users' "$CFG/singbox.json"; }
    write_db <<'J'
{"version":"4.0.0","xray":{},"singbox":{"tuic":{"port":4443,"uuid":"bbbbbbbb-0000-4000-8000-000000000002","password":"tuic-own-pass","sni":"t.example"}},"meta":{}}
J
    db_migrate_to_multiuser
    check 'A2 migration stores the TUIC independent password on the default user' \
        eq "$(jq -r '.singbox.tuic.users[0].password' "$DB_FILE")" tuic-own-pass
    check 'A2 migration keeps the TUIC uuid' \
        eq "$(jq -r '.singbox.tuic.users[0].uuid' "$DB_FILE")" bbbbbbbb-0000-4000-8000-000000000002
    generate_singbox_config >/dev/null 2>&1
    check 'A2 rebuilt sing-box.json authenticates the original client with its own password' \
        eq "$(_render_tuic_users | jq -r '.[0].password')" tuic-own-pass

    # 已被旧版迁移写坏的 DB（users[0] 无 password）：渲染必须回退到顶层 password
    write_db <<'J'
{"version":"4.0.0","xray":{},"singbox":{"tuic":{"port":4443,"uuid":"bbbbbbbb-0000-4000-8000-000000000002","password":"tuic-own-pass","sni":"t.example",
 "users":[{"name":"default","uuid":"bbbbbbbb-0000-4000-8000-000000000002","enabled":true},
          {"name":"carol","uuid":"dddddddd-0000-4000-8000-000000000004","enabled":true}]}},"meta":{}}
J
    generate_singbox_config >/dev/null 2>&1
    check 'A2 legacy-migrated default user falls back to the top-level password' \
        eq "$(_render_tuic_users | jq -r '.[] | select(.uuid=="bbbbbbbb-0000-4000-8000-000000000002") | .password')" tuic-own-pass
    check 'A2 other users without password still use uuid as password' \
        eq "$(_render_tuic_users | jq -r '.[] | select(.uuid=="dddddddd-0000-4000-8000-000000000004") | .password')" dddddddd-0000-4000-8000-000000000004
)

# ═════════════ A3 AnyTLS 迁移器 ═════════════
# 桩：systemctl 用状态文件，ss 读 listen.<port>，sing-box 仅需存在；--apply-configs 由桩脚本模拟
mig_env() { # mig_env <name>
    M="$TMP/$1"; mkdir -p "$M/bin" "$M/state" "$M/cfg"
    : >"$M/calls.log"
    cat >"$M/bin/systemctl" <<'EOF'
#!/bin/bash
echo "systemctl $*" >>"$MCALLS"
case "$1" in
    list-unit-files) printf 'vless-anytls.service enabled\nvless-singbox.service enabled\n' ;;
    is-active) [[ "$2" == "--quiet" ]] && u="$3" || u="$2"; [[ -e "$MSTATE/active.$u" ]]; exit $? ;;
    stop)
        rm -f "$MSTATE/active.$2"
        [[ "$2" == "vless-anytls" ]] && rm -f "$MSTATE/listen.18443"
        ;;
    start) : >"$MSTATE/active.$2" ;;
    disable) : >"$MSTATE/disabled.$2" ;;
esac
exit 0
EOF
    cat >"$M/bin/ss" <<'EOF'
#!/bin/bash
p="${@: -1}"; p="${p##*:}"
[[ -e "$MSTATE/listen.$p" ]] && echo "LISTEN 0 4096 *:$p *:*"
exit 0
EOF
    printf '#!/bin/bash\nexit 0\n' >"$M/bin/sing-box"
    chmod +x "$M/bin/"*
    # 桩 vless-server.sh：APPLY_MODE=ok 模拟已接管；partial 模拟 sing-box 半启动未监听；fail 模拟 rc=0 不启服
    cat >"$M/apply.sh" <<'EOF'
#!/bin/bash
echo "apply $*" >>"$MCALLS"
if [[ "${APPLY_MODE:-ok}" == ok ]]; then
    : >"$MSTATE/active.vless-singbox"; : >"$MSTATE/listen.18443"
elif [[ "${APPLY_MODE:-ok}" == partial ]]; then
    : >"$MSTATE/active.vless-singbox"
fi
exit 0
EOF
    chmod +x "$M/apply.sh"
    cat >"$M/cfg/db.json" <<'J'
{"xray":{"anytls":{"port":18443,"password":"pw1","sni":"a.example"}},"singbox":{}}
J
    : >"$M/state/active.vless-anytls"; : >"$M/state/listen.18443"   # 旧服务运行并占着端口
    export MCALLS="$M/calls.log" MSTATE="$M/state"
}
run_mig() { # run_mig <args...>
    PATH="$M/bin:$PATH" AIO_MIGRATE_CFG_DIR="$M/cfg" AIO_MIGRATE_SCRIPT_BIN="$M/apply.sh" \
        bash "$MIGRATE" "$@" >"$M/out.log" 2>&1
}
sec_migrator() (
    # (a) 备用 --db：只迁移文件，绝不触碰服务/生产脚本
    mig_env alt
    cp "$M/cfg/db.json" "$M/alt.json"
    run_mig --db "$M/alt.json"; rc=$?
    check 'A3 alt --db: migration succeeds' eq "$rc" 0
    check 'A3 alt --db: DB file is migrated' jq -e '.xray.anytls == null and .singbox.anytls.port == 18443' "$M/alt.json"
    check 'A3 alt --db: no service command was run' eq "$(wc -l <"$M/calls.log" | tr -d ' ')" 0
    check 'A3 alt --db: legacy service untouched' test -e "$M/state/active.vless-anytls"
    run_mig --db "$M/alt.json" --stop-legacy; rc=$?
    check 'A3 alt --db + --stop-legacy is refused (exit 2)' eq "$rc" 2

    # (b) 生产 DB，但 sing-box 实际没起来（--apply-configs 返回 0）→ 回滚并重新拉起旧服务
    mig_env fail
    APPLY_MODE=fail run_mig; rc=$?
    check 'A3 unverified takeover exits non-zero' test "$rc" -ne 0
    check 'A3 unverified takeover restores the pre-migration DB' jq -e '.xray.anytls.port == 18443 and .singbox.anytls == null' "$M/cfg/db.json"
    check 'A3 unverified takeover does not disable the legacy service' test ! -e "$M/state/disabled.vless-anytls"
    check 'A3 unverified takeover brings the legacy service back' test -e "$M/state/active.vless-anytls"

    # (c) 生产 DB，接管成功 → 停用旧服务
    mig_env ok
    APPLY_MODE=ok run_mig; rc=$?
    check 'A3 verified takeover succeeds' eq "$rc" 0
    check 'A3 verified takeover keeps migrated DB' jq -e '.xray.anytls == null and .singbox.anytls.port == 18443' "$M/cfg/db.json"
    check 'A3 verified takeover disables the legacy service' test -e "$M/state/disabled.vless-anytls"
    check 'A3 legacy service was stopped before sing-box took the port' \
        bash -c '[[ $(grep -n "systemctl stop vless-anytls" "$1" | head -1 | cut -d: -f1) -lt $(grep -n "^apply" "$1" | head -1 | cut -d: -f1) ]]' _ "$M/calls.log"
    # 接管完成后重跑应幂等返回 0 且提示无需迁移
    APPLY_MODE=ok run_mig; rc=$?
    check 'A3 idempotent re-run after completed takeover exits 0' eq "$rc" 0
    check 'A3 idempotent re-run reports no migration needed' grep -q '无需迁移' "$M/out.log"

    # (d) 生产 DB 缺少前置条件（无 sing-box 或无 vless-server.sh）→ 改库前中止，DB 与旧服务均不动
    mig_env missing_sb
    before_sha=$(sha256sum "$M/cfg/db.json" | awk '{print $1}')
    PATH="$M/bin:$PATH" AIO_MIGRATE_CFG_DIR="$M/cfg" AIO_MIGRATE_SCRIPT_BIN="$M/apply.sh" AIO_MIGRATE_SINGBOX_BIN="" \
        bash "$MIGRATE" >"$M/out.log" 2>&1; rc=$?
    check 'A3 missing sing-box on prod DB aborts non-zero' test "$rc" -ne 0
    check 'A3 missing sing-box leaves prod DB untouched' eq "$(sha256sum "$M/cfg/db.json" | awk '{print $1}')" "$before_sha"
    check 'A3 missing sing-box leaves legacy service active' test -e "$M/state/active.vless-anytls"

    mig_env missing_script
    before_sha=$(sha256sum "$M/cfg/db.json" | awk '{print $1}')
    PATH="$M/bin:$PATH" AIO_MIGRATE_CFG_DIR="$M/cfg" AIO_MIGRATE_SCRIPT_BIN="" AIO_MIGRATE_SINGBOX_BIN="$M/bin/sing-box" \
        bash "$MIGRATE" >"$M/out.log" 2>&1; rc=$?
    check 'A3 missing vless-server.sh on prod DB aborts non-zero' test "$rc" -ne 0
    check 'A3 missing vless-server.sh leaves prod DB untouched' eq "$(sha256sum "$M/cfg/db.json" | awk '{print $1}')" "$before_sha"
    check 'A3 missing vless-server.sh leaves legacy service active' test -e "$M/state/active.vless-anytls"

    # (e) 半迁移状态（DB 已迁到 singbox.anytls，但旧 vless-anytls 仍在运行）→ 不得误报“无需迁移”
    mig_env half
    cat >"$M/cfg/db.json" <<'J'
{"xray":{},"singbox":{"anytls":{"port":18443,"password":"pw1","sni":"a.example"}}}
J
    # 缺前置条件时必须返回非 0 并保持旧服务运行
    PATH="$M/bin:$PATH" AIO_MIGRATE_CFG_DIR="$M/cfg" AIO_MIGRATE_SCRIPT_BIN="" AIO_MIGRATE_SINGBOX_BIN="$M/bin/sing-box" \
        bash "$MIGRATE" >"$M/out.log" 2>&1; rc=$?
    check 'A3 half-migrated without prereqs exits non-zero' test "$rc" -ne 0
    check 'A3 half-migrated without prereqs keeps legacy active' test -e "$M/state/active.vless-anytls"
    # 前置条件齐备但接管失败（即使 vless-singbox 被拉起占着状态）→ 必须先停 vless-singbox 再拉起旧服务
    APPLY_MODE=partial run_mig; rc=$?
    check 'A3 half-migrated failed takeover exits non-zero' test "$rc" -ne 0
    check 'A3 half-migrated failed takeover stops unverified vless-singbox' test ! -e "$M/state/active.vless-singbox"
    check 'A3 half-migrated failed takeover restarts legacy service' test -e "$M/state/active.vless-anytls"
    check 'A3 half-migrated failed takeover does not disable legacy' test ! -e "$M/state/disabled.vless-anytls"
    # 前置条件齐备且接管成功 → 自动停用旧服务并返回 0
    APPLY_MODE=ok run_mig; rc=$?
    check 'A3 half-migrated resume takeover succeeds' eq "$rc" 0
    check 'A3 half-migrated resume disables legacy service' test -e "$M/state/disabled.vless-anytls"
    check 'A3 half-migrated resume leaves vless-singbox active' test -e "$M/state/active.vless-singbox"

    # (f) 真实主脚本联动：调用真实 vless-server.sh 的 _apply_configs_cli（与 --apply-configs --ensure-singbox 同一实现）
    # 覆盖最常见的纯旧 AnyTLS 主机（vless-singbox 此前未运行），验证成功接管与失败回滚清场
    mig_env real_ok
    mkdir -p "$M/cfg/certs/anytls" "$M/logs"
    printf 'dummy-cert\n' >"$M/cfg/certs/anytls/server.crt"
    printf 'dummy-key\n' >"$M/cfg/certs/anytls/server.key"
    cat >"$M/bin/systemctl" <<'EOF'
#!/bin/bash
echo "systemctl $*" >>"$MCALLS"
case "$1" in
    list-unit-files) printf 'vless-anytls.service enabled\nvless-singbox.service enabled\n' ;;
    is-active) [[ "$2" == "--quiet" ]] && u="$3" || u="$2"; [[ -e "$MSTATE/active.$u" ]]; exit $? ;;
    stop)
        rm -f "$MSTATE/active.$2"
        [[ "$2" == "vless-anytls" || "$2" == "vless-singbox" ]] && rm -f "$MSTATE/listen.18443"
        ;;
    start|restart)
        : >"$MSTATE/active.$2"
        if [[ "$2" == "vless-singbox" && "${REAL_SB_LISTEN:-1}" == "1" ]]; then
            : >"$MSTATE/listen.18443"
        fi
        ;;
    enable) : >"$MSTATE/enabled.$2" ;;
    disable) : >"$MSTATE/disabled.$2" ;;
esac
exit 0
EOF
    cat >"$M/real-vless-wrapper.sh" <<EOF
#!/bin/bash
export VLESS_SOURCE_ONLY=1
export VLESS_TEST_CFG="$M/cfg"
export VLESS_TEST_LOG_ROOT="$M/logs"
# shellcheck source=/dev/null
source "$PRODUCT"
create_singbox_service() { : >"$M/state/unit.vless-singbox"; }
[[ "\$1" == "--apply-configs" ]] || exit 2
_apply_configs_cli "\${2:-}"
EOF
    chmod +x "$M/bin/systemctl" "$M/real-vless-wrapper.sh"
    # 注意：vless-singbox 启动前不活跃，旧 vless-anytls 活跃；真实主脚本须自动生成 singbox.json 并启动 vless-singbox
    PATH="$M/bin:$PATH" AIO_MIGRATE_CFG_DIR="$M/cfg" AIO_MIGRATE_SCRIPT_BIN="$M/real-vless-wrapper.sh" \
        AIO_MIGRATE_SINGBOX_BIN="$M/bin/sing-box" REAL_SB_LISTEN=1 \
        bash "$MIGRATE" >"$M/out.log" 2>&1; rc=$?
    check 'A3 real-linkage (cold sing-box): migration succeeds' eq "$rc" 0
    check 'A3 real-linkage: generated real singbox.json with anytls inbound' \
        jq -e '.inbounds[] | select(.type=="anytls" and .listen_port==18443)' "$M/cfg/singbox.json"
    check 'A3 real-linkage: vless-singbox started and enabled' test -e "$M/state/active.vless-singbox"
    check 'A3 real-linkage: legacy vless-anytls disabled' test -e "$M/state/disabled.vless-anytls"

    # (g) 真实主脚本联动回滚：纯旧 AnyTLS 主机接管未监听 → 必须停掉半启 vless-singbox、删掉新 singbox.json、恢复原 DB 并拉起旧服务
    mig_env real_rollback
    mkdir -p "$M/cfg/certs/anytls" "$M/logs"
    printf 'dummy-cert\n' >"$M/cfg/certs/anytls/server.crt"
    printf 'dummy-key\n' >"$M/cfg/certs/anytls/server.key"
    cp "$TMP/real_ok/bin/systemctl" "$M/bin/systemctl"
    cat >"$M/real-vless-wrapper.sh" <<EOF
#!/bin/bash
export VLESS_SOURCE_ONLY=1
export VLESS_TEST_CFG="$M/cfg"
export VLESS_TEST_LOG_ROOT="$M/logs"
# shellcheck source=/dev/null
source "$PRODUCT"
create_singbox_service() { : >"$M/state/unit.vless-singbox"; }
[[ "\$1" == "--apply-configs" ]] || exit 2
_apply_configs_cli "\${2:-}"
EOF
    chmod +x "$M/bin/systemctl" "$M/real-vless-wrapper.sh"
    PATH="$M/bin:$PATH" AIO_MIGRATE_CFG_DIR="$M/cfg" AIO_MIGRATE_SCRIPT_BIN="$M/real-vless-wrapper.sh" \
        AIO_MIGRATE_SINGBOX_BIN="$M/bin/sing-box" REAL_SB_LISTEN=0 \
        bash "$MIGRATE" >"$M/out.log" 2>&1; rc=$?
    check 'A3 real-linkage rollback: exits non-zero when port is not listening' test "$rc" -ne 0
    check 'A3 real-linkage rollback: stops half-started vless-singbox' test ! -e "$M/state/active.vless-singbox"
    check 'A3 real-linkage rollback: removes newly generated singbox.json' test ! -e "$M/cfg/singbox.json"
    check 'A3 real-linkage rollback: restores xray.anytls in DB' \
        jq -e '.xray.anytls.port == 18443 and .singbox.anytls == null' "$M/cfg/db.json"
    check 'A3 real-linkage rollback: restarts legacy vless-anytls' test -e "$M/state/active.vless-anytls"
)

# ═════════════ A4 按端口卸载 / 菜单 14 ═════════════
sec_uninstall_regen() ( fresh_env regen
    write_db <<'J'
{"version":"4.0.0","xray":{"vless":{"port":443,"uuid":"aaaa","sni":"x.example"},"vless-ws":[{"port":8443,"uuid":"bbbb","path":"/a"},{"port":9443,"uuid":"cccc","path":"/b"}]},"singbox":{},"meta":{}}
J
    SVC="$SEC/svc.log"; : >"$SVC"
    svc() { echo "svc $*" >>"$SVC"; return 0; }
    _traffic_collect_to_journal() { :; }
    _pause() { :; }
    echo '{"good":"config"}' >"$CFG/config.json"

    # 菜单 14：预检失败 → 非 0、不重启、保留原配置
    generate_xray_config() { return 1; }
    _regenerate_proxy_configs >/dev/null 2>&1; rc=$?
    check 'A4 menu14: failed preflight returns non-zero' test "$rc" -ne 0
    check 'A4 menu14: failed preflight restarts nothing' eq "$(grep -c 'svc restart' "$SVC")" 0
    generate_xray_config() { echo '{"new":"config"}' >"$CFG/config.json"; return 0; }
    _regenerate_proxy_configs >/dev/null 2>&1; rc=$?
    check 'A4 menu14: success returns 0' eq "$rc" 0
    check 'A4 menu14: success restarts Xray exactly once' eq "$(grep -c 'svc restart vless-reality' "$SVC")" 1

    # 按端口卸载（vless-ws 的 9443）：剩余配置预检失败 → 不得停服务、不得删 config.json
    echo '{"good":"config"}' >"$CFG/config.json"; : >"$SVC"
    generate_xray_config() { return 1; }
    # 菜单输入：协议序号（vless-ws）→ 端口序号（9443）→ 确认
    protos=$(get_installed_protocols); idx=$(grep -nx 'vless-ws' <<<"$protos" | cut -d: -f1)
    printf '%s\n2\ny\n' "${idx:-2}" | uninstall_specific_protocol >/dev/null 2>&1
    check 'A4 uninstall: failed preflight does not stop any service' eq "$(grep -c 'svc stop' "$SVC")" 0
    check 'A4 uninstall: failed preflight keeps the previous config.json' eq "$(cat "$CFG/config.json")" '{"good":"config"}'
    check 'A4 uninstall: failed preflight does not restart anything' eq "$(grep -c 'svc restart' "$SVC")" 0
    check 'A4 uninstall: the requested port is still removed from the DB' \
        eq "$(jq -r '[.xray["vless-ws"][]?.port] | join(",")' "$DB_FILE")" 8443
    # 成功路径：只重启一次
    : >"$SVC"; generate_xray_config() { echo '{"new":"config"}' >"$CFG/config.json"; return 0; }
    printf '1\ny\n' | uninstall_specific_protocol >/dev/null 2>&1
    check 'A4 uninstall: successful rebuild restarts once and never hard-stops first' \
        bash -c '[[ $(grep -c "svc restart vless-reality" "$1") -eq 1 && $(grep -c "svc stop" "$1") -eq 0 ]]' _ "$SVC"
)

# ═════════════ A5 到期撤销重载失败 → 下轮重试 ═════════════
sec_expiry_retry() ( fresh_env expretry
    write_db <<'J'
{"version":"4.0.0","xray":{"vless":{"port":443,"uuid":"a","users":[
 {"name":"gone","uuid":"1","enabled":true,"expire_date":"2000-01-01"},
 {"name":"live","uuid":"2","enabled":true,"expire_date":"2999-01-01"}]}},"singbox":{},"meta":{}}
J
    SVC="$SEC/svc.log"; : >"$SVC"
    svc() { echo "svc $*" >>"$SVC"; [[ "$1" != status ]] && return 0; return 0; }   # 服务在运行，重启成功
    _traffic_collect_to_journal() { :; }
    tg_send_message() { :; }
    GEN=fail
    generate_xray_config() { [[ "$GEN" == ok ]]; }
    out=$(check_and_disable_expired_users)
    check 'A5 first run disables the expired user in the DB' eq "$(db_get_user_field xray vless gone enabled)" false
    check 'A5 first run reports the count' eq "$out" 1
    check 'A5 failed reload leaves a pending marker' test -e "$CFG/.reload-pending.xray"
    check 'A5 failed rebuild did not restart the running service' eq "$(grep -c 'svc restart' "$SVC")" 0
    # 下一轮：用户已是 disabled，不再出现在「过期且启用」列表，必须靠标记重试
    GEN=ok
    out=$(check_and_disable_expired_users)
    check 'A5 next run retries the rebuild+restart (no new expired users)' eq "$(grep -c 'svc restart vless-reality' "$SVC")" 1
    check 'A5 successful retry clears the pending marker' test ! -e "$CFG/.reload-pending.xray"
    out=$(check_and_disable_expired_users)
    check 'A5 nothing pending: no further restart' eq "$(grep -c 'svc restart vless-reality' "$SVC")" 1
    # 配额禁用路径（--sync-traffic）同样必须重试挂起的重载
    : >"$CFG/.reload-pending.xray"; : >"$SVC"
    check_daily_report() { :; }; _sync_all_user_traffic_locked() { return 0; }
    sync_all_user_traffic >/dev/null 2>&1
    check 'A5 sync-traffic retries a pending reload (quota-disable path)' eq "$(grep -c 'svc restart vless-reality' "$SVC")" 1
    check 'A5 sync-traffic clears the marker after a successful retry' test ! -e "$CFG/.reload-pending.xray"
    check 'A5 --check-expire exits non-zero while a reload is pending' \
        bash -c 'awk "/--check-expire\\)/,/;;/" "$1" | grep -q "_reload_pending xray || _reload_pending singbox"' _ "$PRODUCT"
    check 'A5 --sync-traffic exits non-zero while a reload is pending or sync fails' \
        bash -c 'awk "/--sync-traffic\\)/,/;;/" "$1" | grep -q "_reload_pending xray"' _ "$PRODUCT"
)

# ═════════════ A6 分享链接生成：口令按字面处理（H20 零 eval 数组分发） ═════════════
sec_join_quoting() ( fresh_env join
    get_ipv4() { echo 203.0.113.9; }; get_ipv6() { echo ""; }
    PWNED="$SEC/pwned"
    LINKARGS="$SEC/linkargs"
    gen_trojan_link() { : >"$LINKARGS"; local a; for a in "$@"; do printf '%s\n' "$a" >>"$LINKARGS"; done; echo "trojan://stub"; }
    i=0
    for pw in "a b" 'x$(touch '"$PWNED"')y' 'q`touch '"$PWNED"'`q' "it's" 'semi;touch '"$PWNED" '%s-literal' '[bracket]*' '--' '%s' ; do
        i=$((i + 1))
        _save_join_info "trojan" "TROJAN|%s|443|$pw|sni.example" \
            gen_trojan_link 4 "%s" "443" "$pw" "sni.example"
        check "A6 password #$i is passed verbatim to the link generator" \
            bash -c '[[ "$(sed -n 3p "$1")" == "$2" ]]' _ "$LINKARGS" "$pw"
        check "A6 password #$i: first arg is the server IP" eq "$(sed -n 1p "$LINKARGS")" 203.0.113.9
        check "A6 password #$i: exactly four args" eq "$(wc -l <"$LINKARGS" | tr -d ' ')" 4
    done
    check 'A6 no command embedded in a password was executed' test ! -e "$PWNED"
    sji_body=$(declare -f _save_join_info)
    check 'A6 _save_join_info uses direct argv dispatch with zero eval' \
        bash -c '[[ -n "$1" ]] && ! grep -Eq "(^|[^A-Za-z0-9_])eval([[:space:]]|$)" <<<"$1"' _ "$sji_body"
)

# ═════════════ A7 完整卸载：仅清理本项目配置的 WARP ═════════════
sec_warp_scope() ( fresh_env warp
    body=$(declare -f do_uninstall)
    check 'A7 do_uninstall no longer treats a bare warp-cli as project-owned' \
        bash -c '! grep -q "check_cmd warp-cli" <<<"$1"' _ "$body"
    check 'A7 package removal is gated on warp_mode=official from this project DB' \
        bash -c 'grep -q "warp_mode\" == \"official\"" <<<"$1"' _ "$body"
)

# ═════════════ A8 协议注册写库失败 → 中止、不生成链接 ═════════════
sec_register_failure() ( fresh_env regfail
    write_db <<'J'
{"version":"4.0.0","xray":{"vless-ws":{"port":8443,"uuid":"aaaa","path":"/ws","sni":"x.example"}},"singbox":{},"meta":{}}
J
    get_ipv4() { echo 203.0.113.9; }; get_ipv6() { echo ""; }
    db_add() { return 1; }
    register_protocol trojan '{"port":9443,"password":"p","sni":"t.example"}' >/dev/null 2>&1; rc=$?
    check 'A8 failed DB write makes register_protocol return non-zero' test "$rc" -ne 0
    check 'A8 failed DB write sets the failure flag' eq "${_REGISTER_FAILED:-0}" 1
    _save_join_info trojan 'TROJAN|%s|9443|p|t.example' gen_trojan_link 4 '%s' 9443 p t.example >/dev/null 2>&1; rc=$?
    check 'A8 join info is not generated after a failed registration' test "$rc" -ne 0
    check 'A8 no join file was written for the unregistered protocol' test ! -e "$CFG/trojan.join"
    check 'A8 existing healthy protocol is untouched' eq "$(jq -r '.xray["vless-ws"].uuid' "$DB_FILE")" aaaa
    db_add() { return 0; }
    register_protocol trojan '{"port":9443,"password":"p","sni":"t.example"}' >/dev/null 2>&1; rc=$?
    check 'A8 successful registration returns 0 and clears the flag' bash -c '[[ "$1" == 0 && "$2" == 0 ]]' _ "$rc" "${_REGISTER_FAILED:-0}"
)

# ═════════════ A9 订阅只导出生效用户的凭据 ═════════════
sec_sub_active() ( fresh_env subactive
    today=$(date '+%Y-%m-%d'); yest=$(date -d 'yesterday' '+%Y-%m-%d' 2>/dev/null || date -v-1d '+%Y-%m-%d')
    C() { printf '{"port":443,"uuid":"top-uuid","password":"top-pw","users":%s}' "$1"; }
    none_effective() { ! _cfg_effective "$1" "$2" >/dev/null; }
    some_effective() { _cfg_effective "$1" "$2" >/dev/null; }
    check 'A9 all users disabled -> no subscription entry' none_effective vless "$(C '[{"name":"a","uuid":"u1","enabled":false}]')"
    check 'A9 yesterday-expired user -> no entry'          none_effective vless "$(C "[{\"name\":\"a\",\"uuid\":\"u1\",\"enabled\":true,\"expire_date\":\"$yest\"}]")"
    check 'A9 expires today -> still active'               some_effective vless "$(C "[{\"name\":\"a\",\"uuid\":\"u1\",\"enabled\":true,\"expire_date\":\"$today\"}]")"
    out=$(_cfg_effective vless "$(C '[{"name":"a","uuid":"u1","enabled":false},{"name":"b","uuid":"u2","enabled":true}]')")
    check 'A9 only the second user active -> its uuid replaces the top-level one' eq "$(jq -r .uuid <<<"$out")" u2
    out=$(_cfg_effective trojan "$(C '[{"name":"a","uuid":"u1","enabled":false},{"name":"b","uuid":"pw-b","enabled":true}]')")
    check 'A9 trojan uses the active user credential as password' eq "$(jq -r .password <<<"$out")" pw-b
    out=$(_cfg_effective tuic '{"port":1,"uuid":"tu","password":"tpw","users":[{"name":"default","uuid":"tu","enabled":true}]}')
    check 'A9 tuic default user keeps the independent top-level password' eq "$(jq -r .password <<<"$out")" tpw
    out=$(_cfg_effective vless '{"port":1,"uuid":"legacy"}')
    check 'A9 legacy config without users is exported unchanged' eq "$(jq -r .uuid <<<"$out")" legacy
    write_db <<'J'
{"version":"4.0.0","xray":{"vless-ws":{"port":8443,"uuid":"revoked-uuid","path":"/ws","sni":"x.example","users":[
 {"name":"old","uuid":"revoked-uuid","enabled":false},{"name":"new","uuid":"live-uuid","enabled":true}]}},"singbox":{},"meta":{}}
J
    get_ipv4() { echo 203.0.113.9; }; get_ipv6() { echo ""; }; get_ip_country() { echo XX; }
    get_all_external_links() { :; }; _get_master_port() { echo ""; }
    decoded=$(gen_v2ray_sub | base64 -d 2>/dev/null)
    check 'A9 v2ray subscription contains the active user uuid' grep -q 'live-uuid' <<<"$decoded"
    check 'A9 v2ray subscription does not leak the revoked top-level uuid' bash -c '! grep -q revoked-uuid <<<"$1"' _ "$decoded"
    clash=$(gen_clash_sub 2>/dev/null)
    check 'A9 clash subscription uses only the active user' bash -c 'grep -q live-uuid <<<"$1" && ! grep -q revoked-uuid <<<"$1"' _ "$clash"
)

# ═════════════ A10 流量入账幂等 ═════════════
sec_traffic_idem() ( fresh_env trafidem
    write_db <<'J'
{"version":"4.0.0","xray":{"vless":{"port":443,"uuid":"aaaa","users":[
 {"name":"u1","uuid":"aaaa","quota":0,"used":0,"enabled":true},
 {"name":"u2","uuid":"bbbb","quota":0,"used":0,"enabled":true}]}},"singbox":{},"meta":{}}
J
    ents='[{"id":"b1-1","v":700},{"id":"b1-2","v":300}]'
    db_update_user_traffic xray vless u1 1000 "$ents"; db_update_user_traffic xray vless u1 1000 "$ents"
    check 'A10 replaying the same journal entries counts them once' eq "$(db_get_user_field xray vless u1 used)" 1000
    db_update_user_traffic xray vless u1 50 '[{"id":"b1-2","v":300},{"id":"b2-1","v":50}]'
    check 'A10 only unseen entry ids are added later' eq "$(db_get_user_field xray vless u1 used)" 1050
    # 模拟「入账后、清日志前」崩溃：恢复日志再同步一遍
    _pgrep() { return 1; }; check_daily_report() { :; }; tg_get_config() { echo 80; }
    svc() { return 0; }; generate_xray_config() { return 0; }
    pending="$CFG/cache/traffic.pending"; mkdir -p "$CFG/cache"
    printf 'user>>>u2@vless>>>traffic>>>uplink 400 j1\nuser>>>u2@vless>>>traffic>>>downlink 100 j2\nuser>>>u1@vless>>>traffic>>>uplink 10 j3\n' >"$pending"
    cp "$pending" "$SEC/pending.snapshot"
    sync_all_user_traffic >/dev/null 2>&1
    check 'A10 first sync applies the journal' eq "$(db_get_user_field xray vless u2 used)" 500
    cp "$SEC/pending.snapshot" "$pending"
    sync_all_user_traffic >/dev/null 2>&1
    check 'A10 crash replay does not double count u2' eq "$(db_get_user_field xray vless u2 used)" 500
    check 'A10 crash replay does not double count u1' eq "$(db_get_user_field xray vless u1 used)" 1060
)

# ═════════════ A11 自更新：备份失败即中止 ═════════════
sec_update_backup() ( fresh_env updbak
    d="$SEC/upd"; mkdir -p "$d/cache" "$d/cfg"
    sed -e 's@^readonly VERSION_CACHE_DIR=.*@readonly VERSION_CACHE_DIR="'"$d"'/cache"@' "$PRODUCT" >"$d/src.sh"
    printf '#!/usr/bin/env bash\nreadonly VERSION="3.4.10-h99"\n# remote fixture\n' >"$d/remote.sh"; chmod +x "$d/remote.sh"
    cat >"$d/runner.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
export VLESS_SOURCE_ONLY=1 VLESS_TEST_CFG="$d/cfg" VLESS_TEST_LOG_ROOT="$d/log"
source "$d/src.sh"
_header() { :; }; _line() { :; }; _info() { :; }; _ok() { :; }; _warn() { :; }; _err() { printf '%s\n' "\$*" >&2; }
_init_version_cache() { mkdir -p "\$VERSION_CACHE_DIR"; }
_fetch_script_tmp() { local f; f=\$(mktemp "$d/download.XXXXXX") || return 1; cp "$d/remote.sh" "\$f" || return 1; printf '%s\n' "\$f"; }
_fetch_manifest_sha() { sha256sum "$d/remote.sh" | awk '{print \$1}'; }
init_db() { return 0; }; rebuild_and_reload_xray() { return 0; }; rebuild_and_reload_singbox() { return 0; }
cp() { if [[ "\${*: -1}" == *.bak.* ]]; then return 1; fi; command cp "\$@"; }
do_update
EOF
    printf 'OLD-GOOD-BACKUP\n' >"$d/runner.sh.bak"
    cp "$d/runner.sh" "$d/runner.before"
    bash "$d/runner.sh" >"$d/out.log" 2>&1 <<<""; rc=$?
    check 'A11 failed backup makes the update fail' test "$rc" -ne 0
    check 'A11 failed backup leaves the running script byte-identical' cmp -s "$d/runner.sh" "$d/runner.before"
    check 'A11 failed backup preserves the previous .bak' eq "$(cat "$d/runner.sh.bak")" OLD-GOOD-BACKUP
    check 'A11 failed backup leaves no stray download temp' bash -c 'shopt -s nullglob; f=("$1"/download.*); ((${#f[@]}==0))' _ "$d"
)

# ═════════════ A12 DB 损坏 vs 有效空库 ═════════════
sec_db_validate() ( fresh_env dbval
    write_db <<<'{"version":"4.0.0","xray":{},"singbox":{},"meta":{}}'
    check 'A12 valid empty DB validates' db_validate
    write_db <<<'{"version":"4.0.0","xray":{"vless":{"port":1,"uuid":"a"}},"singbox":{},"meta":{}}'
    check 'A12 DB with protocols validates' db_validate
    invalid() { ! db_validate; }
    head -c 30 "$DB_FILE" >"$DB_FILE.t"; mv "$DB_FILE.t" "$DB_FILE"
    check 'A12 truncated DB is rejected' invalid
    write_db <<<'{"xray":[],"singbox":{}}'
    check 'A12 structurally wrong DB is rejected' invalid
    check 'A12 production --apply-configs handler validates before acting' \
        bash -c 'awk "/^_apply_configs_cli\\(\\)/,/^}/" "$1" | grep -q db_validate && awk "/--apply-configs\\)/,/;;/" "$1" | grep -q _apply_configs_cli' _ "$PRODUCT"
    check 'A12 minimal cron/Alpine PATH still appends /usr/local/bin without overriding caller PATH' \
        bash -c 'p=$(PATH=/sbin:/bin:/usr/bin VLESS_SOURCE_ONLY=1 bash -c "source \"\$1\"; printf \"%s\" \"\$PATH\"" _ "$1"); [[ "$p" == /sbin:/bin:/usr/bin:* && ":$p:" == *:/usr/local/bin:* ]]' _ "$PRODUCT"
    check 'A12 flock acquire/release preserves shell stderr (no bare exec 2>/dev/null)' \
        bash -c 'err=$(VLESS_SOURCE_ONLY=1 VLESS_TEST_CFG="$2" bash -c "source \"\$1\"; _lockdir_acquire \"\$CFG/db.json.lock\" 10; _lockdir_release \"\$CFG/db.json.lock\"; echo STDERR_OK >&2" _ "$1" 2>&1 >/dev/null); [[ "$err" == *STDERR_OK* ]]' _ "$PRODUCT" "$SEC/cfg"
)

# ═════════════ A13 订阅重新配置：失败保留旧状态（顺序约束） ═════════════
sec_sub_txn() ( fresh_env subtxn
    body=$(declare -f setup_subscription_interactive)
    lineno() { grep -n -- "$1" <<<"$body" | head -1 | cut -d: -f1; }
    check 'A13 UUID regeneration no longer rotates before confirmation' bash -c '! grep -q reset_sub_uuid <<<"$1"' _ "$body"
    check 'A13 old subscription dir is removed only after the nginx check' \
        bash -c '[[ -n "$1" && -n "$2" && "$1" -lt "$2" ]]' _ "$(lineno 'Nginx 配置错误，已恢复原配置')" "$(lineno 'rm -rf -- "$CFG/subscription/$old_uuid"')"
    check 'A13 sub.info is written only after the nginx reload' \
        bash -c '[[ -n "$1" && -n "$2" && "$1" -lt "$2" ]]' _ "$(lineno 'reload_ok -ne 1')" "$(lineno '_write_sub_info')"
    check 'A13 rollback cleans newly created webroot placeholder only when absent before' \
        bash -c 'grep -q "cleanup_webroot_placeholder" <<<"$1"' _ "$body"
)

# ═════════════ A14 TUIC 入站与导出共用同一证书判据 ═════════════
sec_tuic_cert() ( fresh_env tuiccert
    write_db <<'J'
{"version":"4.0.0","xray":{},"singbox":{"tuic":{"port":4443,"uuid":"bbbb","password":"pw","sni":"real.example.com"}},"meta":{}}
J
    mkdir -p "$CFG/certs/tuic"; echo own-cert >"$CFG/certs/tuic/server.crt"; echo own-key >"$CFG/certs/tuic/server.key"
    echo cert >"$CFG/certs/server.crt"; echo key >"$CFG/certs/server.key"; echo real.example.com >"$CFG/cert_domain"
    link_secure() { ! gen_tuic_link 1.2.3.4 4443 u p real.example.com | grep -q allow_insecure; }
    link_insecure() { gen_tuic_link 1.2.3.4 4443 u p real.example.com | grep -q allow_insecure; }
    _is_real_cert() { return 0; }
    generate_singbox_config >/dev/null 2>&1
    check 'A14 trusted global cert + matching SNI: inbound presents the global cert' \
        eq "$(jq -r '.inbounds[] | select(.type=="tuic") | .tls.certificate_path' "$CFG/singbox.json")" "$CFG/certs/server.crt"
    check 'A14 ...and the exported link drops allow_insecure' link_secure
    _is_real_cert() { return 1; }
    generate_singbox_config >/dev/null 2>&1
    check 'A14 no trusted cert: inbound keeps the independent self-signed cert' \
        eq "$(jq -r '.inbounds[] | select(.type=="tuic") | .tls.certificate_path' "$CFG/singbox.json")" "$CFG/certs/tuic/server.crt"
    check 'A14 ...and the exported link keeps allow_insecure' link_insecure
)

for sec in sec_add_first_user sec_tuic_password sec_migrator sec_uninstall_regen sec_expiry_retry sec_join_quoting sec_warp_scope sec_register_failure sec_sub_active sec_traffic_idem sec_update_backup sec_db_validate sec_sub_txn sec_tuic_cert; do
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
    printf 'PASS: H16 external-audit remediation regression (%d assertions)\n' "$pass"
else
    grep '^FAIL' "$RESULTS" >&2
    printf 'FAIL: H16 external-audit remediation regression (%d failed, %d passed)\n' "$fail" "$pass" >&2
    exit 1
fi
