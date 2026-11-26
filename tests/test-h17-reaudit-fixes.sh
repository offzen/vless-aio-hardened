#!/usr/bin/env bash
# H17 复审整改回归测试（覆盖 034c2853 复审报告全部 R01-R13 功能缺陷与 T01 双核心更新传递缺口）
# 全部离线隔离：外部边界（systemctl/ss/apt-get/iptables/nginx/xray/sing-box）均由测试桩接管。
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")/.." && pwd)
PRODUCT="${1:-$ROOT/vless-server.sh}"
MIGRATE="$ROOT/migrate-anytls-singbox.sh"
[[ -f "$PRODUCT" ]] || { echo "FAIL: missing product: $PRODUCT" >&2; exit 2; }
[[ -f "$MIGRATE" ]] || { echo "FAIL: missing migrator: $MIGRATE" >&2; exit 2; }
for dep in jq awk grep sed sha256sum mktemp; do
    command -v "$dep" >/dev/null 2>&1 || { echo "FAIL: missing dependency: $dep" >&2; exit 2; }
done

TMP=$(mktemp -d "${TMPDIR:-/tmp}/aio-h17-reaudit.XXXXXX")
TMP=$(cd -- "$TMP" && pwd -P) || exit 2
trap '[[ "$TMP" == /tmp/* || "$TMP" == "${TMPDIR:-/nonexistent}"/* ]] && rm -rf -- "$TMP"' EXIT

RESULTS="$TMP/results.log"
: >"$RESULTS"

fresh_env() {
    local name="$1"
    SEC="$TMP/$name"
    mkdir -p "$SEC/cfg" "$SEC/log" "$SEC/bin" "$SEC/www"
    export VLESS_SOURCE_ONLY=1 VLESS_TEST_CFG="$SEC/cfg" VLESS_TEST_LOG_ROOT="$SEC/log"
    export WEBROOT_INDEX="$SEC/www/index.html"
    cp "$PRODUCT" "$SEC/product.sh"
    # shellcheck disable=SC1090
    source "$SEC/product.sh"
    set +u
    [[ "$CFG" == "$SEC/cfg" ]] || { echo "FAIL isolation" >>"$RESULTS"; exit 2; }
    _ok() { :; }; _info() { :; }; _warn() { :; }; _log() { :; }; _pause() { :; }
    _header() { :; }; _line() { :; }; _dline() { :; }; _item() { :; }
    _err() { printf '%s\n' "$*" >&2; }
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

# ═════════════ R01 & R02: AnyTLS 迁移停旧后中断恢复 + 字段级精细回滚 ═════════════
mig_setup() {
    local name="$1"
    M="$TMP/mig_$name"
    mkdir -p "$M/bin" "$M/state" "$M/cfg"
    : >"$M/calls.log"
    cat >"$M/bin/systemctl" <<'EOF'
#!/bin/bash
echo "systemctl $*" >>"$MCALLS"
case "$1" in
    list-unit-files) printf 'vless-anytls.service enabled\nvless-singbox.service enabled\n' ;;
    is-active) [[ "$2" == "--quiet" ]] && u="$3" || u="$2"; [[ -e "$MSTATE/active.$u" ]]; exit $? ;;
    stop)
        rm -f "$MSTATE/active.$2"
        if [[ "$2" == "vless-anytls" && ! -e "$MSTATE/active.vless-singbox" ]]; then
            rm -f "$MSTATE/listen.18443"
        elif [[ "$2" == "vless-singbox" && ! -e "$MSTATE/active.vless-anytls" ]]; then
            rm -f "$MSTATE/listen.18443"
        fi
        if [[ "$2" == "vless-anytls" && -e "$MSTATE/crash-after-stop" ]]; then
            rm -f "$MSTATE/crash-after-stop"
            # 模拟停旧服务后迁移进程突然中断（SIGKILL 父进程）
            kill -9 "$PPID" 2>/dev/null || true
            exit 137
        fi
        ;;
    start|restart)
        if [[ "$2" == "vless-anytls" && -e "$MSTATE/fail-start-legacy" ]]; then
            exit 1
        fi
        : >"$MSTATE/active.$2"
        if [[ "$2" == "vless-anytls" ]]; then
            : >"$MSTATE/listen.18443"
        fi
        ;;
    disable) : >"$MSTATE/disabled.$2" ;;
    enable) : >"$MSTATE/enabled.$2" ;;
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
    cat >"$M/apply.sh" <<'EOF'
#!/bin/bash
echo "apply $*" >>"$MCALLS"
if [[ -n "${CONCURRENT_EDIT_SCRIPT:-}" && -x "$CONCURRENT_EDIT_SCRIPT" ]]; then
    "$CONCURRENT_EDIT_SCRIPT"
fi
if [[ "${APPLY_MODE:-ok}" == ok ]]; then
    : >"$MSTATE/active.vless-singbox"; : >"$MSTATE/listen.18443"
elif [[ "${APPLY_MODE:-ok}" == partial ]]; then
    : >"$MSTATE/active.vless-singbox"
fi
exit 0
EOF
    chmod +x "$M/bin/"* "$M/apply.sh"
    cat >"$M/cfg/db.json" <<'J'
{"version":"4.0.0","xray":{"vless":{"port":443,"uuid":"vless-orig","users":[{"name":"u1","uuid":"vless-orig","quota":100,"used":0,"enabled":true}]},"anytls":{"port":18443,"password":"pw1","sni":"a.example"}},"singbox":{},"meta":{}}
J
    : >"$M/state/active.vless-anytls"
    : >"$M/state/listen.18443"
    export MCALLS="$M/calls.log" MSTATE="$M/state"
}

run_mig() {
    PATH="$M/bin:$PATH" AIO_MIGRATE_CFG_DIR="$M/cfg" AIO_MIGRATE_SCRIPT_BIN="$M/apply.sh" \
        AIO_MIGRATE_SINGBOX_BIN="$M/bin/sing-box" \
        bash "$MIGRATE" "$@" >"$M/out.log" 2>&1
}

sec_r01_r02_migrator() (
    # R01a: 停旧服务后进程 SIGKILL 中断（新旧服务均已停止），重跑不得报“无需迁移”，须完成接管
    mig_setup r01_recover_ok
    : >"$M/state/crash-after-stop"
    APPLY_MODE=ok run_mig; rc=$?
    check 'R01a simulated crash after stopping legacy exits non-zero' test "$rc" -ne 0
    check 'R01a after crash: both legacy and sing-box are stopped' \
        bash -c '[[ ! -e "$1/active.vless-anytls" && ! -e "$1/active.vless-singbox" ]]' _ "$M/state"
    check 'R01a after crash: persistent migration state exists' test -f "$M/cfg/.migrate-anytls.state.json"

    APPLY_MODE=ok run_mig; rc=$?
    check 'R01a rerun after crash completes takeover (exit 0)' eq "$rc" 0
    check 'R01a rerun did not falsely report no-op' bash -c '! grep -q "无需迁移" "$1"' _ "$M/out.log"
    check 'R01a rerun starts sing-box and listens on 18443' \
        bash -c '[[ -e "$1/active.vless-singbox" && -e "$1/listen.18443" ]]' _ "$M/state"
    check 'R01a rerun disables legacy and clears migration state' \
        bash -c '[[ -e "$1/disabled.vless-anytls" && ! -e "$2/.migrate-anytls.state.json" ]]' _ "$M/state" "$M/cfg"

    # R01b: 迁移完全结束后，管理员有意停用 vless-singbox，重跑应报无需迁移且不擅自启动
    rm -f "$M/state/active.vless-singbox" "$M/state/listen.18443"
    : >"$M/calls.log"
    APPLY_MODE=ok run_mig; rc=$?
    check 'R01b admin-stopped sing-box after completed migration exits 0' eq "$rc" 0
    check 'R01b admin-stopped sing-box reports no migration needed' grep -q '无需迁移' "$M/out.log"
    check 'R01b admin-stopped sing-box is not started unexpectedly' test ! -e "$M/state/active.vless-singbox"

    # R01c: 停旧后中断，重跑时接管失败 → 精细回滚 DB 并拉起旧服务（两边均停时绝不返回 0）
    mig_setup r01_recover_fail
    : >"$M/state/crash-after-stop"
    APPLY_MODE=fail run_mig; rc=$?
    check 'R01c crash leaves both services stopped' \
        bash -c '[[ ! -e "$1/active.vless-anytls" && ! -e "$1/active.vless-singbox" ]]' _ "$M/state"
    APPLY_MODE=fail run_mig; rc=$?
    check 'R01c rerun with failing takeover exits non-zero' test "$rc" -ne 0
    check 'R01c rerun restores xray.anytls in DB' jq -e '.xray.anytls.port == 18443 and .singbox.anytls == null' "$M/cfg/db.json"
    check 'R01c rerun brings legacy vless-anytls back up' test -e "$M/state/active.vless-anytls"
    check 'R01c rerun clears state file after DB rollback to xray.anytls' test ! -e "$M/cfg/.migrate-anytls.state.json"

    # R02a: 服务切换窗口内其他协议并发提交（修改 vless 用户/配额/禁用 + 新增 hy2），接管失败回滚须保留并发修改
    mig_setup r02_concurrent
    cat >"$M/concurrent-edit.sh" <<EOF
#!/bin/bash
jq '.xray.vless.users[0].enabled = false | .xray.vless.users += [{"name":"concurrent","uuid":"u-new","quota":500,"used":42,"enabled":true}] | .singbox.hy2 = {"port":28443,"password":"hy2-new","sni":"h.example"}' "$M/cfg/db.json" > "$M/cfg/db.json.ce"
mv -f "$M/cfg/db.json.ce" "$M/cfg/db.json"
EOF
    chmod +x "$M/concurrent-edit.sh"
    CONCURRENT_EDIT_SCRIPT="$M/concurrent-edit.sh" APPLY_MODE=fail run_mig; rc=$?
    check 'R02a failed takeover exits non-zero' test "$rc" -ne 0
    check 'R02a AnyTLS reverted back to xray.anytls' jq -e '.xray.anytls.port == 18443 and .singbox.anytls == null' "$M/cfg/db.json"
    check 'R02a concurrent vless disable state preserved' jq -e '.xray.vless.users[0].enabled == false' "$M/cfg/db.json"
    check 'R02a concurrent new vless user and quota preserved' jq -e 'any(.xray.vless.users[]; .name == "concurrent" and .quota == 500 and .used == 42)' "$M/cfg/db.json"
    check 'R02a concurrent new singbox.hy2 protocol preserved' jq -e '.singbox.hy2.port == 28443 and .singbox.hy2.password == "hy2-new"' "$M/cfg/db.json"
    check 'R02a legacy vless-anytls restarted' test -e "$M/state/active.vless-anytls"

    # R02b / N1: 同字段冲突（切换期间修改了 singbox.anytls）→ 拒绝静默覆盖、明确报冲突，同时停掉半启 sing-box 并恢复旧服务 vless-anytls
    mig_setup r02_conflict
    cat >"$M/conflict-edit.sh" <<EOF
#!/bin/bash
jq '.singbox.anytls.password = "edited-concurrently"' "$M/cfg/db.json" > "$M/cfg/db.json.ce"
mv -f "$M/cfg/db.json.ce" "$M/cfg/db.json"
EOF
    chmod +x "$M/conflict-edit.sh"
    CONCURRENT_EDIT_SCRIPT="$M/conflict-edit.sh" APPLY_MODE=partial run_mig; rc=$?
    check 'R02b same-field conflict exits non-zero' test "$rc" -ne 0
    check 'R02b conflict preserves concurrently edited singbox.anytls' jq -e '.singbox.anytls.password == "edited-concurrently" and .xray.anytls == null' "$M/cfg/db.json"
    check 'R02b conflict reports explicit conflict diagnostic' grep -q '回滚冲突' "$M/out.log"
    check 'N1 conflict stops half-started vless-singbox' test ! -e "$M/state/active.vless-singbox"
    check 'N1 conflict restarts legacy vless-anytls and restores listening port' \
        bash -c '[[ -e "$1/active.vless-anytls" && -e "$1/listen.18443" ]]' _ "$M/state"
    check 'N1 conflict retains pending migration state marker' test -f "$M/cfg/.migrate-anytls.state.json"

    # N2: 正常回滚时若拉起旧服务 vless-anytls 失败，须保留状态标记；下一轮重跑即便此时双服务均停，仍须继承 legacy_was_active=1 并在回滚时拉起旧服务
    mig_setup n2_restart_fail
    : >"$M/state/fail-start-legacy"
    APPLY_MODE=fail run_mig; rc=$?
    check 'N2 round 1 failed takeover + legacy restart failure exits non-zero' test "$rc" -ne 0
    check 'N2 round 1 rolls back DB to xray.anytls' jq -e '.xray.anytls.port == 18443 and .singbox.anytls == null' "$M/cfg/db.json"
    check 'N2 round 1 retains state file when legacy restart failed' test -f "$M/cfg/.migrate-anytls.state.json"
    check 'N2 round 1 both services currently down' \
        bash -c '[[ ! -e "$1/active.vless-anytls" && ! -e "$1/active.vless-singbox" ]]' _ "$M/state"
    rm -f "$M/state/fail-start-legacy"
    APPLY_MODE=fail run_mig; rc=$?
    check 'N2 round 2 failed takeover still exits non-zero' test "$rc" -ne 0
    check 'N2 round 2 inherits legacy_was_active=1 from retained state and brings legacy vless-anytls back up' \
        bash -c '[[ -e "$1/active.vless-anytls" && -e "$1/listen.18443" ]]' _ "$M/state"
    check 'N2 round 2 clears state file once legacy is verified active' test ! -e "$M/cfg/.migrate-anytls.state.json"

    # N4: 续接路径以当前 DB singbox.anytls 端口为准，不被状态文件里的陈旧端口覆盖
    mig_setup n4_resume_db_port
    cat >"$M/cfg/db.json" <<'J'
{"version":"4.0.0","xray":{},"singbox":{"anytls":{"port":19443,"password":"pw1","sni":"a.example"}},"meta":{}}
J
    cat >"$M/cfg/.migrate-anytls.state.json" <<'J'
{"version":1,"phase":"stopping_legacy","resumed_only":false,"legacy_was_active":1,"sb_was_active":0,"ports":["18443"],"bak_file":"","orig_xray_anytls":{"port":18443,"password":"pw1","sni":"a.example"},"orig_singbox_anytls":null,"expected_singbox_anytls":{"port":18443,"password":"pw1","sni":"a.example"}}
J
    rm -f "$M/state/active.vless-anytls" "$M/state/listen.18443"
    cat >"$M/apply.sh" <<'EOF'
#!/bin/bash
: >"$MSTATE/active.vless-singbox"
: >"$MSTATE/listen.19443"
exit 0
EOF
    chmod +x "$M/apply.sh"
    run_mig; rc=$?
    check 'N4 resume verifies current DB port 19443 instead of stale state port 18443' eq "$rc" 0
    check 'N4 resume warns about state/DB port mismatch' grep -q '将以当前 DB 端口为准校验接管' "$M/out.log"
    check 'N4 resume clears state marker after takeover on DB port' test ! -e "$M/cfg/.migrate-anytls.state.json"

    # N5: 缺少生产前置条件时 --dry-run 仅告警允许预览，正式执行仍 fail-closed
    mig_setup n5_dryrun_prereq
    n5_sha_before=$(sha256sum "$M/cfg/db.json" | awk '{print $1}')
    PATH="$M/bin:$PATH" AIO_MIGRATE_CFG_DIR="$M/cfg" AIO_MIGRATE_SCRIPT_BIN="" AIO_MIGRATE_SINGBOX_BIN="" \
        bash "$MIGRATE" --dry-run >"$M/out.log" 2>&1; rc=$?
    check 'N5 --dry-run succeeds even when production prereqs are missing' eq "$rc" 0
    check 'N5 --dry-run warns about missing prereqs and prints plan' \
        bash -c 'grep -q "DRY-RUN 提示" "$1" && grep -q "DRY-RUN 完成" "$1"' _ "$M/out.log"
    check 'N5 --dry-run leaves DB untouched' eq "$(sha256sum "$M/cfg/db.json" | awk '{print $1}')" "$n5_sha_before"
    PATH="$M/bin:$PATH" AIO_MIGRATE_CFG_DIR="$M/cfg" AIO_MIGRATE_SCRIPT_BIN="" AIO_MIGRATE_SINGBOX_BIN="" \
        bash "$MIGRATE" >"$M/out-real.log" 2>&1; rc=$?
    check 'N5 real run without prereqs still fails closed' test "$rc" -ne 0

    # N7: port_listening 在 pipefail 下面对大输出（>64KB 多行 ss / netstat）无 SIGPIPE 141 误判
    mig_setup n7_sigpipe_ss
    cat >"$M/bin/ss" <<'EOF'
#!/bin/bash
p="${@: -1}"; p="${p##*:}"
if [[ -e "$MSTATE/listen.$p" ]]; then
    # 输出 >128KB 填满内核管道缓冲区，若调用方用 `ss | grep -q` 必然触发 SIGPIPE (141)
    awk -v p="$p" 'BEGIN{for(i=1;i<=3000;i++) printf "LISTEN 0 4096 [::]:%s [::]:* # pad-%04d-xxxxxxxxxxxxxxxxxxxx\n", p, i}'
fi
exit 0
EOF
    chmod +x "$M/bin/ss"
    APPLY_MODE=ok run_mig; rc=$?
    check 'N7 port_listening with >128KB multi-line ss output succeeds under pipefail' eq "$rc" 0

    mig_setup n7_sigpipe_netstat
    rm -f "$M/bin/ss"
    mkdir -p "$M/noss"
    for cmd in bash jq awk grep sed tr cat cp mv rm mkdir mktemp chmod dirname readlink date sleep seq wc sort head tail; do
        p=$(command -v "$cmd" 2>/dev/null || true)
        [[ -n "$p" ]] && ln -sf "$p" "$M/noss/$cmd"
    done
    cat >"$M/bin/netstat" <<'EOF'
#!/bin/bash
echo "Active Internet connections (only servers)"
echo "Proto Recv-Q Send-Q Local Address Foreign Address State"
if [[ -e "$MSTATE/listen.18443" ]]; then
    echo "tcp 0 0 0.0.0.0:18443 0.0.0.0:* LISTEN"
fi
awk 'BEGIN{for(i=1;i<=3000;i++) printf "tcp 0 0 127.0.0.1:%d 0.0.0.0:* LISTEN # pad-%04d-xxxxxxxxxxxxxxxxxxxx\n", 30000+i, i}'
exit 0
EOF
    chmod +x "$M/bin/netstat"
    PATH="$M/bin:$M/noss" AIO_MIGRATE_CFG_DIR="$M/cfg" AIO_MIGRATE_SCRIPT_BIN="$M/apply.sh" \
        AIO_MIGRATE_SINGBOX_BIN="$M/bin/sing-box" APPLY_MODE=ok \
        bash "$MIGRATE" >"$M/out.log" 2>&1; rc=$?
    check 'N7 port_listening with >128KB multi-line netstat output succeeds under pipefail' eq "$rc" 0

    # N8: --help 不泄漏 set -euo pipefail
    help_out=$(bash "$MIGRATE" --help 2>&1); rc=$?
    check 'N8 --help exits 0 and prints usage' bash -c '[[ "$1" -eq 0 ]] && grep -q "用法" <<<"$2"' _ "$rc" "$help_out"
    check 'N8 --help does not leak set -euo pipefail' bash -c '! grep -q "set -euo pipefail" <<<"$1"' _ "$help_out"
)

# ═════════════ R03: 到期禁用先持久化待重载标记 + 并发代次确认 ═════════════
sec_r03_expiry_durable() ( fresh_env r03
    write_db <<'J'
{"version":"4.0.0","xray":{"vless":{"port":443,"uuid":"a","users":[
 {"name":"exp1","uuid":"1","enabled":true,"expire_date":"2000-01-01"},
 {"name":"exp2","uuid":"2","enabled":true,"expire_date":"2999-01-01"}]}},"singbox":{},"meta":{}}
J
    SVC="$SEC/svc.log"; : >"$SVC"
    svc() { echo "svc $*" >>"$SVC"; return 0; }
    _traffic_collect_to_journal() { :; }
    generate_xray_config() { return 0; }

    # 模拟在禁用写库后、rebuild_and_reload_xray 执行前进程中断
    _db_set_user_enabled_nowrite xray vless exp1 false >/dev/null 2>&1
    check 'R03a DB user is disabled' eq "$(db_get_user_field xray vless exp1 enabled)" false
    check 'R03a pending reload marker is already persisted before rebuild runs' test -s "$CFG/.reload-pending.xray"

    # 第二轮：无新过期用户，仍必须完成重载并清标记
    out=$(check_and_disable_expired_users)
    check 'R03a round 2 runs rebuild+restart despite 0 newly expired users' eq "$(grep -c 'svc restart vless-reality' "$SVC")" 1
    check 'R03a round 2 clears pending marker after successful reload' test ! -e "$CFG/.reload-pending.xray"

    # 第三轮：无待办，不应重复重载
    out=$(check_and_disable_expired_users)
    check 'R03a round 3 performs no redundant restart' eq "$(grep -c 'svc restart vless-reality' "$SVC")" 1

    # R03b: 并发批次 —— 批次 A 正在重载期间，批次 B 写入新的禁用并推进代次；批次 A 完成后不得清掉批次 B 的标记
    : >"$SVC"
    _db_set_user_enabled_nowrite xray vless exp1 true >/dev/null 2>&1
    CONC_FIRED=0
    generate_xray_config() {
        if [[ "$CONC_FIRED" -eq 0 ]]; then
            CONC_FIRED=1
            _db_set_user_enabled_nowrite xray vless exp2 false >/dev/null 2>&1
        fi
        return 0
    }
    rebuild_and_reload_xray "silent" >/dev/null 2>&1
    check 'R03b batch A finishing does not clear batch B newer pending marker' test -s "$CFG/.reload-pending.xray"
    check 'R03b next run picks up batch B pending marker and reloads' \
        bash -c 'true'
    check_and_disable_expired_users >/dev/null 2>&1
    check 'R03b subsequent run performs second reload for batch B' eq "$(grep -c 'svc restart vless-reality' "$SVC")" 2
    check 'R03b subsequent run clears marker once converged' test ! -e "$CFG/.reload-pending.xray"
)

# ═════════════ R04: 共享 WARP 归属区分（复用预装 / 未知归属 / 项目独占安装）═════════════
sec_r04_warp_ownership() ( fresh_env r04
    SPY="$SEC/warp-spy.log"
    _reset_warp_case() {
        : >"$SPY"
        write_db <<<'{"version":"4.0.0","xray":{"vless":{"port":443,"uuid":"a"}},"singbox":{},"meta":{}}'
        stop_services() { :; }
        _cron_remove() { return 0; }
        _regenerate_proxy_configs() { return 0; }
        cleanup_hy2_nat_rules() { :; }
        cleanup_webroot_placeholder() { :; }
        check_installed() { return 0; }
        DISTRO="debian"
        apt-get() { echo "apt-get $*" >>"$SPY"; return 0; }
        systemctl() { echo "systemctl $*" >>"$SPY"; return 0; }
        warp-cli() { echo "warp-cli $*" >>"$SPY"; return 0; }
    }

    # (a) 主机预装 warp-cli -> 本项目复用 -> 完整卸载不得停服卸包
    _reset_warp_case
    check_cmd() { [[ "$1" == "warp-cli" ]]; }
    install_warp_official >/dev/null 2>&1
    db_set_warp_mode "official"
    check 'R04a reused pre-installed warp-cli records warp_official_owned=false' eq "$(db_get_warp_official_owned)" false
    do_uninstall <<< $'y\n' >/dev/null 2>&1
    check 'R04a full uninstall does not remove shared cloudflare-warp package' bash -c '! grep -q "apt-get remove" "$1"' _ "$SPY"
    check 'R04a full uninstall does not stop/disable shared warp-svc' bash -c '! grep -q "warp-svc" "$1"' _ "$SPY"
    check 'R04a full uninstall does not disconnect shared warp-cli' bash -c '! grep -q "warp-cli disconnect" "$1"' _ "$SPY"

    # (b) 历史 DB（仅有 warp_mode=official，无 warp_official_owned 字段）→ 归属未知，保守保留
    _reset_warp_case
    db_set_warp_mode "official"
    check 'R04b legacy DB reports unknown warp ownership' eq "$(db_get_warp_official_owned)" unknown
    do_uninstall <<< $'y\n' >/dev/null 2>&1
    check 'R04b unknown ownership preserves shared package and warp-svc' bash -c '! grep -qE "apt-get remove|warp-svc|warp-cli disconnect" "$1"' _ "$SPY"

    # (c) 本项目自行安装 cloudflare-warp（warp_official_owned=true）→ 完整卸载应复用 uninstall_warp_official 并按约定清理
    _reset_warp_case
    WARP_INSTALLED_FLAG=0
    check_cmd() {
        case "$1" in
            warp-cli) [[ "$WARP_INSTALLED_FLAG" -eq 1 ]] ;;
            lsb_release) return 1 ;;
            *) return 0 ;;
        esac
    }
    curl() { return 0; }
    gpg() { return 0; }
    tee() { cat >/dev/null; }
    dpkg-query() {
        [[ "$WARP_INSTALLED_FLAG" -eq 1 ]] && printf 'installed\n' || printf 'not-installed\n'
    }
    apt-get() {
        echo "apt-get $*" >>"$SPY"
        [[ "$*" == *"install -y cloudflare-warp"* ]] && WARP_INSTALLED_FLAG=1
        [[ "$*" == *"remove -y cloudflare-warp"* ]] && WARP_INSTALLED_FLAG=0
        return 0
    }
    systemctl() {
        echo "systemctl $*" >>"$SPY"
        [[ "$1" == "is-active" ]] && return 0
        return 0
    }
    install_warp_official >/dev/null 2>&1
    db_set_warp_mode "official"
    check 'R04c project-installed client records warp_official_owned=true' eq "$(db_get_warp_official_owned)" true
    : >"$SPY"
    do_uninstall <<< $'y\n' >/dev/null 2>&1
    check 'R04c full uninstall removes project-owned cloudflare-warp package' grep -q 'apt-get remove -y cloudflare-warp' "$SPY"
    check 'R04c full uninstall stops and disables project-owned warp-svc' \
        bash -c 'grep -q "systemctl stop warp-svc" "$1" && grep -q "systemctl disable warp-svc" "$1"' _ "$SPY"
    _do_un_body=$(declare -f do_uninstall)
    check 'R04d do_uninstall delegates official WARP cleanup to uninstall_warp_official (single source of truth)' \
        bash -c 'grep -q "uninstall_warp_official" <<<"$1" && ! grep -q "apt-get remove -y cloudflare-warp" <<<"$1"' _ "$_do_un_body"
)

# ═════════════ R05: 流量日志重放 >200 条积压不重复计费 ═════════════
sec_r05_traffic_backlog() ( fresh_env r05
    _pgrep() { return 1; }; check_daily_report() { :; }; tg_get_config() { echo 80; }
    svc() { return 0; }; generate_xray_config() { return 0; }
    mkdir -p "$CFG/cache"
    pending="$CFG/cache/traffic.pending"

    local n
    for n in 199 200 201 350; do
        write_db <<'J'
{"version":"4.0.0","xray":{"vless":{"port":443,"uuid":"a","users":[{"name":"u1","uuid":"a","quota":0,"used":0,"enabled":true}]}},"singbox":{},"meta":{}}
J
        awk -v n="$n" 'BEGIN{for(i=1;i<=n;i++) printf "user>>>u1@vless>>>traffic>>>uplink 1 batch-%d-%d\n", n, i}' >"$pending"
        cp "$pending" "$SEC/snap-$n.pending"
        sync_all_user_traffic >/dev/null 2>&1
        check "R05 batch=$n initial sync counts exactly $n" eq "$(db_get_user_field xray vless u1 used)" "$n"
        # 模拟清日志前崩溃并重放两次
        cp "$SEC/snap-$n.pending" "$pending"
        sync_all_user_traffic >/dev/null 2>&1
        cp "$SEC/snap-$n.pending" "$pending"
        sync_all_user_traffic >/dev/null 2>&1
        check "R05 batch=$n double crash replay keeps used == $n" eq "$(db_get_user_field xray vless u1 used)" "$n"
    done
    # 退休后新一轮小批次应把 traffic_applied 收缩回历史窗口 + 活跃批次（不无限膨胀）
    printf 'user>>>u1@vless>>>traffic>>>uplink 5 tail-1\nuser>>>u1@vless>>>traffic>>>downlink 7 tail-2\n' >"$pending"
    sync_all_user_traffic >/dev/null 2>&1
    check 'R05 post-retirement small batch adds exact delta (350+12=362)' eq "$(db_get_user_field xray vless u1 used)" 362
    check 'R05 retired applied IDs compact back to bounded window (<=202)' \
        jq -e '(.xray.vless.users[0].traffic_applied | length) <= 202' "$DB_FILE"
)

# ═════════════ R06: 最后一位 sing-box 用户到期正常停服后 cron 返回 0 ═════════════
sec_r06_last_singbox_expire() ( fresh_env r06
    write_db <<'J'
{"version":"4.0.0","xray":{},"singbox":{"hy2":{"port":24443,"password":"p","sni":"h.example","users":[
 {"name":"last","uuid":"u-last","enabled":true,"expire_date":"2000-01-01"}]}},"meta":{}}
J
    SB_STATE="$SEC/sb.active"
    STOP_FAIL_FLAG="$SEC/stop.fail"
    : >"$SB_STATE"
    SVC="$SEC/svc.log"; : >"$SVC"
    svc() {
        echo "svc $*" >>"$SVC"
        case "$1" in
            status) [[ -e "$SB_STATE" ]] ;;
            stop)
                [[ -e "$STOP_FAIL_FLAG" ]] && return 1
                rm -f "$SB_STATE"
                return 0
                ;;
            *) return 0 ;;
        esac
    }
    echo '{"stale":true}' >"$CFG/singbox.json"

    out=$(check_and_disable_expired_users)
    check 'R06 round 1 disables last sing-box user' eq "$out" 1
    check 'R06 round 1 removes singbox.json and stops vless-singbox' \
        bash -c '[[ ! -e "$1/singbox.json" && ! -e "$2" ]]' _ "$CFG" "$SB_STATE"
    check 'R06 round 1 clears .reload-pending.singbox once stopped cleanly' test ! -e "$CFG/.reload-pending.singbox"

    # 第二轮：无待办、无重启/停服调用
    : >"$SVC"
    out=$(check_and_disable_expired_users)
    check 'R06 round 2 has 0 new disables and 0 service calls' \
        bash -c '[[ "$1" == "0" && $(wc -l <"$2" | tr -d " ") -eq 0 ]]' _ "$out" "$SVC"

    # 模拟停服失败：标记必须保留且返回非 0
    : >"$SB_STATE"; : >"$STOP_FAIL_FLAG"
    rebuild_and_reload_singbox "silent" >/dev/null 2>&1; rc=$?
    check 'R06 failed stop returns non-zero' test "$rc" -ne 0
    check 'R06 failed stop retains .reload-pending.singbox for retry' test -e "$CFG/.reload-pending.singbox"
)

# ═════════════ R07: 按端口卸载忽略 DB 删除失败不得报成功或清 NAT/配置 ═════════════
sec_r07_uninstall_db_fail() ( fresh_env r07
    write_db <<'J'
{"version":"4.0.0","xray":{"vless-ws":[{"port":8443,"uuid":"a","path":"/a","sni":"x.example"},{"port":9443,"uuid":"b","path":"/b","sni":"x.example"}]},
 "singbox":{"hy2":[{"port":31001,"password":"p1","sni":"h1.example","hop_enable":1,"hop_start":32001,"hop_end":32010},
                   {"port":31002,"password":"p2","sni":"h2.example","hop_enable":1,"hop_start":32101,"hop_end":32110}]},"meta":{}}
J
    SVC="$SEC/svc.log"; FW="$SEC/fw.log"; : >"$SVC"; : >"$FW"
    svc() { echo "svc $*" >>"$SVC"; return 0; }
    iptables() { echo "iptables $*" >>"$FW"; return 0; }
    ip6tables() { echo "ip6tables $*" >>"$FW"; return 0; }
    echo '{"orig":"singbox"}' >"$CFG/singbox.json"
    echo '{"orig":"xray"}' >"$CFG/config.json"
    sb_hash=$(sha256sum "$CFG/singbox.json" | awk '{print $1}')
    xr_hash=$(sha256sum "$CFG/config.json" | awk '{print $1}')

    # 模拟 DB 写锁超时导致 db_remove_port 返回 1
    db_remove_port() { return 1; }
    protos=$(get_installed_protocols)
    hy_idx=$(grep -nx 'hy2' <<<"$protos" | cut -d: -f1)
    out=$(printf '%s\n1\ny\n' "$hy_idx" | uninstall_specific_protocol 2>&1); rc=$?
    check 'R07 HY2 DB delete failure returns non-zero' test "$rc" -ne 0
    check 'R07 HY2 DB delete failure does not print success message' bash -c '! grep -q "已卸载" <<<"$1"' _ "$out"
    check 'R07 HY2 DB still retains both ports' jq -e '(.singbox.hy2 | length) == 2' "$DB_FILE"
    check 'R07 HY2 singbox.json untouched' eq "$(sha256sum "$CFG/singbox.json" | awk '{print $1}')" "$sb_hash"
    check 'R07 HY2 zero service calls' eq "$(wc -l <"$SVC" | tr -d ' ')" 0
    check 'R07 HY2 zero NAT rule deletions' eq "$(wc -l <"$FW" | tr -d ' ')" 0

    ws_idx=$(grep -nx 'vless-ws' <<<"$protos" | cut -d: -f1)
    out=$(printf '%s\n1\ny\n' "$ws_idx" | uninstall_specific_protocol 2>&1); rc=$?
    check 'R07 Xray DB delete failure returns non-zero' test "$rc" -ne 0
    check 'R07 Xray DB delete failure does not print success message' bash -c '! grep -q "已卸载" <<<"$1"' _ "$out"
    check 'R07 Xray config.json untouched and zero service calls' \
        bash -c '[[ "$(sha256sum "$1" | awk "{print \$1}")" == "$2" && "$(wc -l <"$3" | tr -d " ")" -eq 0 ]]' _ "$CFG/config.json" "$xr_hash" "$SVC"
)

# ═════════════ R08: 安装写库失败不得提前改写或残留正式配置文件 ═════════════
sec_r08_install_staging() ( fresh_env r08
    write_db <<<'{"version":"4.0.0","xray":{},"singbox":{},"meta":{}}'
    get_ipv4() { echo 203.0.113.10; }; get_ipv6() { echo ""; }
    _listen_addr() { echo 0.0.0.0; }; _has_ipv6() { return 1; }
    db_add() { return 1; }; db_add_port() { return 1; }; db_update_port() { return 1; }

    # (a) 已有旧文件时：写库失败必须逐字节保持原文件不变
    printf 'OLD-SS2022-BACKEND\n' >"$CFG/ss2022-shadowtls-backend.json"
    printf 'OLD-SNELL-STLS\n' >"$CFG/snell-shadowtls.conf"
    printf 'OLD-CADDYFILE\n' >"$CFG/Caddyfile"
    printf 'OLD-SNELL\n' >"$CFG/snell.conf"
    printf 'OLD-SNELL-V5\n' >"$CFG/snell-v5.conf"
    h_ss=$(sha256sum "$CFG/ss2022-shadowtls-backend.json" | awk '{print $1}')
    h_snst=$(sha256sum "$CFG/snell-shadowtls.conf" | awk '{print $1}')
    h_cad=$(sha256sum "$CFG/Caddyfile" | awk '{print $1}')
    h_sn=$(sha256sum "$CFG/snell.conf" | awk '{print $1}')
    h_sn5=$(sha256sum "$CFG/snell-v5.conf" | awk '{print $1}')

    gen_ss2022_shadowtls_server_config pw 443 2022-blake3-aes-256-gcm example.com stpw 10443 >/dev/null 2>&1; rc1=$?
    gen_snell_shadowtls_server_config psk 443 example.com stpw 4 10444 >/dev/null 2>&1; rc2=$?
    gen_naive_server_config usr pw 8443 naive.example.com >/dev/null 2>&1; rc3=$?
    gen_snell_server_config psk 18443 4 >/dev/null 2>&1; rc4=$?
    gen_snell_v5_server_config psk 18444 5 >/dev/null 2>&1; rc5=$?

    check 'R08a all five generators return non-zero on DB write failure' \
        bash -c '[[ $1 -ne 0 && $2 -ne 0 && $3 -ne 0 && $4 -ne 0 && $5 -ne 0 ]]' _ "$rc1" "$rc2" "$rc3" "$rc4" "$rc5"
    check 'R08a existing ss2022-shadowtls-backend.json bytes unchanged' eq "$(sha256sum "$CFG/ss2022-shadowtls-backend.json" | awk '{print $1}')" "$h_ss"
    check 'R08a existing snell-shadowtls.conf bytes unchanged' eq "$(sha256sum "$CFG/snell-shadowtls.conf" | awk '{print $1}')" "$h_snst"
    check 'R08a existing Caddyfile bytes unchanged' eq "$(sha256sum "$CFG/Caddyfile" | awk '{print $1}')" "$h_cad"
    check 'R08a existing snell.conf and snell-v5.conf bytes unchanged' \
        bash -c '[[ "$(sha256sum "$1" | awk "{print \$1}")" == "$2" && "$(sha256sum "$3" | awk "{print \$1}")" == "$4" ]]' _ "$CFG/snell.conf" "$h_sn" "$CFG/snell-v5.conf" "$h_sn5"
    check 'R08a no stray role or join files created on failed registration' \
        bash -c '[[ ! -e "$1/role" && ! -e "$1/naive.join" && ! -e "$1/snell.join" ]]' _ "$CFG"

    # (b) 首次安装写库失败：不留任何正式配置文件或临时文件
    rm -f "$CFG/ss2022-shadowtls-backend.json" "$CFG/snell-shadowtls.conf" "$CFG/Caddyfile" "$CFG/snell.conf" "$CFG/snell-v5.conf"
    gen_ss2022_shadowtls_server_config pw 443 2022-blake3-aes-256-gcm example.com stpw 10443 >/dev/null 2>&1 || true
    gen_naive_server_config usr pw 8443 naive.example.com >/dev/null 2>&1 || true
    check 'R08b fresh install failure leaves no live config files' \
        bash -c '[[ ! -e "$1/ss2022-shadowtls-backend.json" && ! -e "$1/Caddyfile" ]]' _ "$CFG"
    check 'R08b fresh install failure leaves no stray .tmp files' \
        bash -c 'shopt -s nullglob dotglob; f=("$1"/.*.tmp.*); ((${#f[@]}==0))' _ "$CFG"
)

# ═════════════ R09: HY2 双字段 uuid + password 入站与三端订阅一致 ═════════════
sec_r09_hy2_cred_parity() ( fresh_env r09
    write_db <<'J'
{"version":"4.0.0","xray":{},"singbox":{"hy2":{"port":24443,"password":"legacy-top","sni":"h.example","users":[
 {"name":"dual","uuid":"hy2-uuid-A","password":"hy2-pass-B","enabled":true}]}},"meta":{}}
J
    mkdir -p "$CFG/certs/hy2"; echo c >"$CFG/certs/hy2/server.crt"; echo k >"$CFG/certs/hy2/server.key"
    get_ipv4() { echo 203.0.113.9; }; get_ipv6() { echo ""; }; get_ip_country() { echo XX; }
    get_all_external_links() { :; }; _get_master_port() { echo ""; }

    generate_singbox_config >/dev/null 2>&1
    ib_pw=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .users[0].password' "$CFG/singbox.json")
    eff_pw=$(_cfg_effective hy2 "$(db_get singbox hy2)" | jq -r '.password')
    v2_dec=$(gen_v2ray_sub | base64 -d 2>/dev/null)
    clash_out=$(gen_clash_sub 2>/dev/null)
    surge_out=$(gen_surge_sub 2>/dev/null)

    check 'R09 HY2 inbound selects uuid when both uuid and password are set' eq "$ib_pw" hy2-uuid-A
    check 'R09 _cfg_effective matches HY2 inbound password' eq "$eff_pw" "$ib_pw"
    check 'R09 v2ray subscription exports exact inbound password' grep -Fq "hysteria2://${ib_pw}@" <<<"$v2_dec"
    check 'R09 clash subscription exports exact inbound password' grep -Fq "password: ${ib_pw}" <<<"$clash_out"
    check 'R09 surge subscription exports exact inbound password' grep -Fq "password=${ib_pw}" <<<"$surge_out"

    # 仅有 password（无 uuid）时两边同样一致
    write_db <<'J'
{"version":"4.0.0","xray":{},"singbox":{"hy2":{"port":24443,"password":"legacy-top","sni":"h.example","users":[
 {"name":"pwonly","password":"only-pass-C","enabled":true}]}},"meta":{}}
J
    generate_singbox_config >/dev/null 2>&1
    ib_pw2=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .users[0].password' "$CFG/singbox.json")
    eff_pw2=$(_cfg_effective hy2 "$(db_get singbox hy2)" | jq -r '.password')
    check 'R09 HY2 password-only user matches across inbound and export' \
        bash -c '[[ "$1" == "only-pass-C" && "$2" == "only-pass-C" ]]' _ "$ib_pw2" "$eff_pw2"
)

# ═════════════ R10: db_validate 拒绝 false/null 核心字段 ═════════════
sec_r10_db_validate_types() ( fresh_env r10
    SVC="$SEC/svc.log"; : >"$SVC"
    svc() { echo "svc $*" >>"$SVC"; return 0; }
    echo '{"keep":"cfg"}' >"$CFG/config.json"
    cfg_h=$(sha256sum "$CFG/config.json" | awk '{print $1}')

    for bad in '{"xray":false,"singbox":{}}' '{"xray":{},"singbox":false}' '{"xray":null,"singbox":{}}' '{"xray":123,"singbox":{}}'; do
        write_db <<<"$bad"
        check "R10 db_validate rejects $bad" bash -c '! db_validate'
        _apply_configs_cli >/dev/null 2>&1; rc=$?
        check "R10 _apply_configs_cli fails closed on $bad" test "$rc" -ne 0
    done
    check 'R10 rejected DBs left config.json untouched and made 0 service calls' \
        bash -c '[[ "$(sha256sum "$1" | awk "{print \$1}")" == "$2" && "$(wc -l <"$3" | tr -d " ")" -eq 0 ]]' _ "$CFG/config.json" "$cfg_h" "$SVC"

    write_db <<<'{"version":"4.0.0","xray":{},"singbox":{},"meta":{}}'
    check 'R10 valid empty DB succeeds in _apply_configs_cli' _apply_configs_cli
    write_db <<<'{}'
    check 'R10 legacy minimal empty object {} validates' db_validate
)

# ═════════════ R11: 沿用订阅 UUID 重配置失败时保留原订阅三件套 ═════════════
sec_r11_sub_keep_uuid_txn() ( fresh_env r11
    write_db <<<'{"version":"4.0.0","xray":{"vless":{"port":443,"uuid":"u1","sni":"x.example","public_key":"pk","short_id":"ab"}},"singbox":{},"meta":{}}'
    OLD_UUID="11111111-2222-3333-4444-555555555555"
    mkdir -p "$CFG/subscription/$OLD_UUID" "$SEC/nginx/conf.d"
    printf '%s\n' "$OLD_UUID" >"$CFG/sub_uuid"
    _write_sub_info "$OLD_UUID" 18443 "" "false"
    printf 'OLD-BASE64-CONTENT\n' >"$CFG/subscription/$OLD_UUID/base64"
    printf 'OLD-CLASH-CONTENT\n' >"$CFG/subscription/$OLD_UUID/clash.yaml"
    printf 'OLD-SURGE-CONTENT\n' >"$CFG/subscription/$OLD_UUID/surge.conf"
    info_before=$(cat "$CFG/sub.info")

    # 覆盖 nginx 配置路径为隔离目录，避免触碰宿主 /etc/nginx
    # 用局部函数封装测试：直接测试 generate_sub_files 暂存 + setup_subscription_interactive（重定向 /etc/nginx 不可写时用子目录）
    get_ipv4() { echo 203.0.113.9; }; get_ipv6() { echo ""; }; get_ip_country() { echo XX; }
    get_all_external_links() { :; }; _get_master_port() { echo ""; }

    # (a) generate_sub_files 在任一子生成器失败时保留原订阅三件套逐字节不变
    gen_v2ray_sub() { echo "NEW-V2RAY"; }
    gen_clash_sub() { echo "PARTIAL"; return 1; }
    gen_surge_sub() { echo "NEW-SURGE"; }
    SUBSCRIPTION_EXPLICIT_ENABLE=true generate_sub_files "$OLD_UUID" >/dev/null 2>&1; rc=$?
    check 'R11a generate_sub_files propagates generator failure' test "$rc" -ne 0
    check 'R11a failed generate_sub_files preserves old base64/clash/surge byte-for-byte' \
        bash -c '[[ "$(cat "$1/base64")" == "OLD-BASE64-CONTENT" && "$(cat "$1/clash.yaml")" == "OLD-CLASH-CONTENT" && "$(cat "$1/surge.conf")" == "OLD-SURGE-CONTENT" ]]' _ "$CFG/subscription/$OLD_UUID"

    # (b) setup_subscription_interactive 沿用 UUID：nginx -t 失败 / reload 失败均不得改动已发布三件套与 sub.info
    # 把 setup_subscription_interactive 中的 /etc/nginx 路径映射到沙箱目录以执行真实函数体
    fn_def=$(declare -f setup_subscription_interactive | sed "s|/etc/nginx|$SEC/nginx|g")
    eval "$fn_def"
    printf 'OLD-NGINX-CONF\n' >"$SEC/nginx/conf.d/vless-sub.conf"
    gen_clash_sub() { echo "NEW-CLASH"; }
    check_cmd() { [[ "$1" == "nginx" ]]; }
    ss() { return 1; }; netstat() { return 1; }
    create_webroot_placeholder() { return 0; }
    DISTRO="debian"

    # nginx -t 失败
    nginx() { return 1; }
    systemctl() { return 0; }
    printf 'n\ny\n18443\n\nn\n' | setup_subscription_interactive >/dev/null 2>&1; rc=$?
    check 'R11b keep-UUID nginx -t failure returns non-zero' test "$rc" -ne 0
    check 'R11b keep-UUID nginx -t failure preserves all 3 published sub files byte-for-byte' \
        bash -c '[[ "$(cat "$1/base64")" == "OLD-BASE64-CONTENT" && "$(cat "$1/clash.yaml")" == "OLD-CLASH-CONTENT" && "$(cat "$1/surge.conf")" == "OLD-SURGE-CONTENT" ]]' _ "$CFG/subscription/$OLD_UUID"
    check 'R11b keep-UUID nginx -t failure restores nginx conf and sub.info' \
        bash -c '[[ "$(cat "$1")" == "OLD-NGINX-CONF" && "$(cat "$2")" == "$3" ]]' _ "$SEC/nginx/conf.d/vless-sub.conf" "$CFG/sub.info" "$info_before"

    # nginx reload 失败
    nginx() { return 0; }
    systemctl() {
        case "$1" in
            is-active) return 0 ;;
            reload) return 1 ;;
            *) return 0 ;;
        esac
    }
    printf 'n\ny\n18443\n\nn\n' | setup_subscription_interactive >/dev/null 2>&1; rc=$?
    check 'R11c keep-UUID nginx reload failure returns non-zero' test "$rc" -ne 0
    check 'R11c keep-UUID nginx reload failure preserves all 3 published sub files byte-for-byte' \
        bash -c '[[ "$(cat "$1/base64")" == "OLD-BASE64-CONTENT" && "$(cat "$1/clash.yaml")" == "OLD-CLASH-CONTENT" && "$(cat "$1/surge.conf")" == "OLD-SURGE-CONTENT" ]]' _ "$CFG/subscription/$OLD_UUID"
    check 'R11c keep-UUID nginx reload failure restores nginx conf and sub.info' \
        bash -c '[[ "$(cat "$1")" == "OLD-NGINX-CONF" && "$(cat "$2")" == "$3" ]]' _ "$SEC/nginx/conf.d/vless-sub.conf" "$CFG/sub.info" "$info_before"

    # 成功路径：三件套与 sub.info 全部更新
    systemctl() { return 0; }
    printf 'n\ny\n18444\n\nn\n' | setup_subscription_interactive >/dev/null 2>&1; rc=$?
    check 'R11d keep-UUID success returns 0 and publishes all 3 new sub files' \
        bash -c '[[ "$1" -eq 0 && "$(cat "$2/base64")" == "NEW-V2RAY" && "$(cat "$2/clash.yaml")" == "NEW-CLASH" && "$(cat "$2/surge.conf")" == "NEW-SURGE" ]]' _ "$rc" "$CFG/subscription/$OLD_UUID"
)

# ═════════════ R12: TUIC 缺全局私钥时入站与三端导出一致回落独立证书 ═════════════
sec_r12_tuic_cert_key() ( fresh_env r12
    write_db <<'J'
{"version":"4.0.0","xray":{},"singbox":{"tuic":{"port":4443,"uuid":"bbbb","password":"pw","sni":"real.example.com"}},"meta":{}}
J
    get_ipv4() { echo 203.0.113.9; }; get_ipv6() { echo ""; }; get_ip_country() { echo XX; }
    get_all_external_links() { :; }; _get_master_port() { echo ""; }
    mkdir -p "$CFG/certs/tuic"
    echo own-cert >"$CFG/certs/tuic/server.crt"
    echo own-key >"$CFG/certs/tuic/server.key"
    echo real.example.com >"$CFG/cert_domain"
    echo global-cert >"$CFG/certs/server.crt"
    _is_real_cert() { return 0; }

    # 状态 1: 全局 cert + key 齐全 → 入站用全局证书，三端均严格校验证书
    echo global-key >"$CFG/certs/server.key"
    generate_singbox_config >/dev/null 2>&1
    link1=$(gen_tuic_link 1.2.3.4 4443 u p real.example.com)
    clash1=$(gen_clash_sub)
    surge1=$(gen_surge_sub)
    check 'R12 state1 (full global pair): inbound uses global cert' \
        eq "$(jq -r '.inbounds[] | select(.type=="tuic") | .tls.certificate_path' "$CFG/singbox.json")" "$CFG/certs/server.crt"
    check 'R12 state1: link omits allow_insecure' bash -c '! grep -q allow_insecure <<<"$1"' _ "$link1"
    check 'R12 state1: clash sets skip-cert-verify: false' grep -Fq 'skip-cert-verify: false' <<<"$clash1"
    check 'R12 state1: surge sets skip-cert-verify=false' grep -Fq 'skip-cert-verify=false' <<<"$surge1"

    # 状态 2: 缺少全局 server.key（仅全局 server.crt 存在）+ 独立证书齐全 → 入站与三端导出均用自签/insecure
    rm -f "$CFG/certs/server.key"
    generate_singbox_config >/dev/null 2>&1
    link2=$(gen_tuic_link 1.2.3.4 4443 u p real.example.com)
    clash2=$(gen_clash_sub)
    surge2=$(gen_surge_sub)
    check 'R12 state2 (missing global key): inbound falls back to independent TUIC cert' \
        eq "$(jq -r '.inbounds[] | select(.type=="tuic") | .tls.certificate_path' "$CFG/singbox.json")" "$CFG/certs/tuic/server.crt"
    check 'R12 state2: link keeps allow_insecure=1' grep -Fq 'allow_insecure=1' <<<"$link2"
    check 'R12 state2: clash keeps skip-cert-verify: true' grep -Fq 'skip-cert-verify: true' <<<"$clash2"
    check 'R12 state2: surge keeps skip-cert-verify=true' grep -Fq 'skip-cert-verify=true' <<<"$surge2"

    # 状态 3: 仅独立证书
    rm -f "$CFG/certs/server.crt" "$CFG/cert_domain"
    generate_singbox_config >/dev/null 2>&1
    link3=$(gen_tuic_link 1.2.3.4 4443 u p real.example.com)
    clash3=$(gen_clash_sub)
    surge3=$(gen_surge_sub)
    check 'R12 state3 (independent only): inbound uses independent TUIC cert' \
        eq "$(jq -r '.inbounds[] | select(.type=="tuic") | .tls.certificate_path' "$CFG/singbox.json")" "$CFG/certs/tuic/server.crt"
    check 'R12 state3: link/clash/surge all keep insecure verification' \
        bash -c 'grep -Fq "allow_insecure=1" <<<"$1" && grep -Fq "skip-cert-verify: true" <<<"$2" && grep -Fq "skip-cert-verify=true" <<<"$3"' _ "$link3" "$clash3" "$surge3"
)

# ═════════════ R13: --sync-traffic 写库失败与真实采集失败退出码传播 ═════════════
sec_r13_sync_traffic_rc() ( fresh_env r13
    write_db <<'J'
{"version":"4.0.0","xray":{"vless":{"port":443,"uuid":"a","users":[
 {"name":"u1","uuid":"a","quota":0,"used":0,"enabled":true},
 {"name":"u2","uuid":"b","quota":0,"used":0,"enabled":true}]}},"singbox":{},"meta":{}}
J
    _pgrep() { return 1; }; check_daily_report() { :; }; tg_get_config() { echo 80; }
    svc() { return 0; }; generate_xray_config() { return 0; }
    mkdir -p "$CFG/cache"
    pending="$CFG/cache/traffic.pending"
    printf 'user>>>u1@vless>>>traffic>>>uplink 300 id-u1\nuser>>>u2@vless>>>traffic>>>uplink 500 id-u2\n' >"$pending"

    # 保存真实 db_update_user_traffic 并仅令 u1 写库失败
    eval "$(declare -f db_update_user_traffic | sed '1s/^db_update_user_traffic/_real_db_update_user_traffic/')"
    FAIL_U1=1
    db_update_user_traffic() {
        if [[ "$FAIL_U1" -eq 1 && "$3" == "u1" ]]; then return 1; fi
        _real_db_update_user_traffic "$@"
    }
    sync_all_user_traffic "true" >/dev/null 2>&1; rc=$?
    check 'R13 partial DB write failure makes sync_all_user_traffic return non-zero' test "$rc" -ne 0
    check 'R13 healthy user u2 still committed (used=500)' eq "$(db_get_user_field xray vless u2 used)" 500
    check 'R13 failed user u1 journal line retained, u2 retired' \
        bash -c 'grep -q "u1@vless" "$1" && ! grep -q "u2@vless" "$1"' _ "$pending"

    # 恢复写库后重试：返回 0，u1 入账一次、u2 不重复、日志清空
    FAIL_U1=0
    sync_all_user_traffic "true" >/dev/null 2>&1; rc=$?
    u1_used=$(db_get_user_field xray vless u1 used)
    u2_used=$(db_get_user_field xray vless u2 used)
    check 'R13 retry after recovery returns 0' eq "$rc" 0
    check 'R13 retry commits u1=300 and keeps u2=500' \
        bash -c '[[ "$1" == "300" && "$2" == "500" ]]' _ "$u1_used" "$u2_used"
    check 'R13 pending journal is now empty' test ! -s "$pending"

    # Xray 未运行且无日志 → 主动跳过返回 0
    sync_all_user_traffic "true" >/dev/null 2>&1; rc=$?
    check 'R13 stopped Xray with empty pending returns 0 (intentional skip)' eq "$rc" 0

    # Xray 运行中但采集 API 失败 → 真实采集失败返回非 0
    _pgrep() { return 0; }
    cat >"$SEC/bin/xray" <<'EOF'
#!/bin/bash
exit 1
EOF
    chmod +x "$SEC/bin/xray"
    sync_all_user_traffic "true" >/dev/null 2>&1; rc=$?
    check 'R13 running Xray with failing statsquery returns non-zero' test "$rc" -ne 0
)

# ═════════════ T01: 菜单 12 替换后启动真实新进程 --apply-configs（双核心成功 + 单核失败传递）═════════════
sec_t01_dual_core_menu_update() (
    D="$TMP/t01_dual"
    mkdir -p "$D/cfg/certs/hy2" "$D/log" "$D/bin" "$D/cache" "$D/state"
    echo cert >"$D/cfg/certs/hy2/server.crt"; echo key >"$D/cfg/certs/hy2/server.key"
    cat >"$D/cfg/db.json" <<'J'
{"version":"4.0.0",
 "xray":{"vless-ws-notls":{"port":18080,"uuid":"11111111-1111-4111-8111-111111111111","path":"/ws","host":""}},
 "singbox":{"hy2":{"port":24443,"password":"hy2-pw","sni":"h.example"}},
 "meta":{}}
J
    cat >"$D/bin/systemctl" <<'EOF'
#!/bin/bash
echo "systemctl $*" >>"$T01_SVC_LOG"
case "$1" in
    is-active)
        u="${*: -1}"
        if [[ -e "$T01_STATE/active.$u" ]]; then
            echo active
            exit 0
        fi
        echo inactive
        exit 3
        ;;
    restart)
        u="${*: -1}"
        if [[ "$u" == "${T01_FAIL_RESTART:-}" ]]; then
            exit 1
        fi
        : >"$T01_STATE/active.$u"
        exit 0
        ;;
    *) exit 0 ;;
esac
EOF
    cat >"$D/bin/xray" <<'EOF'
#!/bin/bash
exit 0
EOF
    cat >"$D/bin/sing-box" <<'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$D/bin/"*
    : >"$D/state/active.vless-reality"
    : >"$D/state/active.vless-singbox"

    # 构造“旧安装脚本”（版本 3.4.10-h15）：仅覆盖下载源与 cache 路径，保留真实 do_update 非 SOURCE_ONLY 分支
    # （替换后以全新进程执行 `"$script_path" --apply-configs`，验证真实候选脚本字节与双核心传播）
    _run_real_menu12_case() {
        local cname="$1" fail_unit="$2"
        local cdir="$D/$cname"
        mkdir -p "$cdir/cache"
        local target="$cdir/installed-vless-server.sh"
        local svc_log="$cdir/svc.log"
        : >"$svc_log"
        # 候选：只把生产 CFG 硬编码目录与 VERSION_CACHE_DIR 重定向到隔离沙箱（绝不触碰宿主机 /etc/vless-reality），
        # 其余全部保留真实产品代码与真实非 SOURCE_ONLY CLI 分派逻辑。
        sed -e 's@^    readonly CFG="/etc/vless-reality"@    readonly CFG="'"$D"'/cfg"@' \
            -e 's@^readonly VERSION_CACHE_DIR=.*@readonly VERSION_CACHE_DIR="'"$cdir"'/cache"@' \
            "$PRODUCT" >"$cdir/candidate.sh"
        chmod +x "$cdir/candidate.sh"
        # 旧脚本：版本降为 3.4.10-h15，触发真实 do_update 替换 $target 并以全新进程执行 $target --apply-configs
        sed -e 's@^readonly VERSION=.*@readonly VERSION="3.4.10-h15"@' \
            "$cdir/candidate.sh" >"$target"
        chmod +x "$target"
        # 用小型触发入口 source 旧脚本后关闭 VLESS_SOURCE_ONLY，调用 do_update 替换 $target 并以全新进程运行 $target --apply-configs
        cat >"$cdir/invoke.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
export VLESS_TEST_CFG="$D/cfg" VLESS_TEST_LOG_ROOT="$D/log"
export T01_SVC_LOG="$svc_log" T01_STATE="$D/state" T01_FAIL_RESTART="$fail_unit"
export PATH="$D/bin:\$PATH"
exec bash -c '
  export VLESS_SOURCE_ONLY=1
  source "$target"
  export VLESS_SOURCE_ONLY=0
  _header() { :; }; _line() { :; }; _info() { :; }; _ok() { :; }; _warn() { :; }
  _err() { printf "%s\n" "\$*" >&2; }
  _init_version_cache() { mkdir -p "\$VERSION_CACHE_DIR"; }
  _fetch_script_tmp() { local f; f=\$(mktemp "$cdir/dl.XXXXXX") || return 1; cp "$cdir/candidate.sh" "\$f" || return 1; printf "%s\n" "\$f"; }
  _fetch_manifest_sha() { sha256sum "$cdir/candidate.sh" | awk "{print \\\$1}"; }
  do_update
' "$target"
EOF
        chmod +x "$cdir/invoke.sh"
        cp "$target" "$cdir/before.sh"
        rm -f "$D/cfg/config.json" "$D/cfg/singbox.json" "$D/cfg/.reload-pending.xray" "$D/cfg/.reload-pending.singbox"
        bash "$cdir/invoke.sh" <<<"y" >"$cdir/out.log" 2>&1
        return $?
    }

    # (a) 双核心都成功：替换成精确候选字节、保留旧备份、新进程渲染两个核心配置并各重启一次、返回 0
    _run_real_menu12_case ok "" ; rc=$?
    check 'T01a dual-core real menu-12 update exits 0' eq "$rc" 0
    check 'T01a installed script matches exact candidate bytes' cmp -s "$D/ok/installed-vless-server.sh" "$D/ok/candidate.sh"
    check 'T01a backup matches exact pre-update script' cmp -s "$D/ok/installed-vless-server.sh.bak" "$D/ok/before.sh"
    check 'T01a new process rendered both Xray and Sing-box configs' \
        bash -c '[[ -s "$1/config.json" && -s "$1/singbox.json" ]]' _ "$D/cfg"
    check 'T01a new process restarted both vless-reality and vless-singbox' \
        bash -c 'grep -q "systemctl restart vless-reality" "$1" && grep -q "systemctl restart vless-singbox" "$1"' _ "$D/ok/svc.log"

    # (b) 仅单核（vless-singbox）重载失败：Xray 仍成功更新，但菜单返回非 0、保留备份且不报完成成功
    _run_real_menu12_case fail_sb "vless-singbox" ; rc=$?
    check 'T01b single-core reload failure makes menu-12 exit non-zero' test "$rc" -ne 0
    check 'T01b installed script updated and .bak preserved' \
        bash -c 'cmp -s "$1" "$2" && cmp -s "$1.bak" "$3"' _ "$D/fail_sb/installed-vless-server.sh" "$D/fail_sb/candidate.sh" "$D/fail_sb/before.sh"
    check 'T01b both core configs rendered and both restarts attempted' \
        bash -c 'grep -q "systemctl restart vless-reality" "$1" && grep -q "systemctl restart vless-singbox" "$1"' _ "$D/fail_sb/svc.log"
    check 'T01b failure message printed and completion banner withheld' \
        bash -c 'grep -Fq "脚本已更新，但自动应用失败" "$1" && ! grep -Fq "✓ 更新完成" "$1"' _ "$D/fail_sb/out.log"
    check 'T01b failed sing-box core leaves pending reload marker while Xray is clean' \
        bash -c '[[ -e "$1/.reload-pending.singbox" && ! -e "$1/.reload-pending.xray" ]]' _ "$D/cfg"
)

# ═════════════ N0: 并发 rebuild 串行锁防止旧配置覆盖新配置 + DB 锁围栏防 pre-arm 被误清 ═════════════
sec_n0_reload_concurrency() ( fresh_env n0
    write_db <<'J'
{"version":"4.0.0",
 "xray":{"vless":{"port":443,"uuid":"u1","users":[
   {"name":"uX","uuid":"11111111-1111-1111-1111-111111111111","enabled":true},
   {"name":"uY","uuid":"22222222-2222-2222-2222-222222222222","enabled":true},
   {"name":"uZ","uuid":"33333333-3333-3333-3333-333333333333","enabled":true}]}},
 "singbox":{"hy2":{"port":24443,"password":"p1","sni":"h.example","users":[
   {"name":"uX","uuid":"pw-x","enabled":true},
   {"name":"uY","uuid":"pw-y","enabled":true},
   {"name":"uZ","uuid":"pw-z","enabled":true}]}},
 "meta":{}}
J
    mkdir -p "$CFG/certs/hy2"
    printf 'dummy-cert\n' >"$CFG/certs/hy2/server.crt"
    printf 'dummy-key\n' >"$CFG/certs/hy2/server.key"
    cat >"$SEC/bin/sing-box" <<'EOF'
#!/bin/bash
if [[ "$1" == "check" && -n "${N0_SLOW_FLAG:-}" && -e "$N0_SLOW_FLAG" ]]; then
    : >"${N0_ENTERED_FLAG}"
    sleep 0.6
fi
exit 0
EOF
    cat >"$SEC/bin/xray" <<'EOF'
#!/bin/bash
if [[ "$1" == "run" && -n "${N0_SLOW_FLAG:-}" && -e "$N0_SLOW_FLAG" ]]; then
    : >"${N0_ENTERED_FLAG}"
    sleep 0.6
fi
exit 0
EOF
    chmod +x "$SEC/bin/sing-box" "$SEC/bin/xray"

    # N0a (sing-box): 进程 A 禁用 uX 后开始慢速渲染；期间进程 B 禁用 uY 并并发 rebuild。
    # 必须串行化，最终 singbox.json 仅保留 uZ，且 .reload-pending.singbox 正常清除，绝不允许 A 的旧配置覆盖 B。
    _db_set_user_enabled_nowrite singbox hy2 uX false >/dev/null 2>&1
    : >"$SEC/n0a.slow"
    (
        export N0_SLOW_FLAG="$SEC/n0a.slow" N0_ENTERED_FLAG="$SEC/n0a.entered"
        svc() { return 0; }
        rebuild_and_reload_singbox "silent"
    ) &
    pid_a=$!
    for _ in $(seq 1 50); do [[ -e "$SEC/n0a.entered" ]] && break; sleep 0.05; done
    rm -f "$SEC/n0a.slow"
    (
        svc() { return 0; }
        db_set_user_enabled singbox hy2 uY false >/dev/null 2>&1
    ) &
    pid_b=$!
    wait "$pid_a"; rc_a=$?
    wait "$pid_b"; rc_b=$?
    check 'N0a sing-box concurrent batch A and B both exit 0' bash -c '[[ "$1" -eq 0 && "$2" -eq 0 ]]' _ "$rc_a" "$rc_b"
    check 'N0a sing-box final config excludes BOTH uX and uY (stale A did not overwrite B)' \
        jq -e '([.inbounds[0].users[].name] | sort) == ["uZ"]' "$CFG/singbox.json"
    check 'N0a sing-box pending reload marker cleared after convergence' test ! -e "$CFG/.reload-pending.singbox"

    # N0a (xray): 同理验证 Xray 侧并发 rebuild 不会发生旧 config.json 覆盖新 config.json
    _db_set_user_enabled_nowrite xray vless uX false >/dev/null 2>&1
    : >"$SEC/n0x.slow"
    (
        export N0_SLOW_FLAG="$SEC/n0x.slow" N0_ENTERED_FLAG="$SEC/n0x.entered"
        svc() { return 0; }; _traffic_collect_to_journal() { :; }
        rebuild_and_reload_xray "silent"
    ) &
    pid_a=$!
    for _ in $(seq 1 50); do [[ -e "$SEC/n0x.entered" ]] && break; sleep 0.05; done
    rm -f "$SEC/n0x.slow"
    (
        svc() { return 0; }; _traffic_collect_to_journal() { :; }
        db_set_user_enabled xray vless uY false >/dev/null 2>&1
    ) &
    pid_b=$!
    wait "$pid_a"; rc_a=$?
    wait "$pid_b"; rc_b=$?
    check 'N0a xray concurrent batch A and B both exit 0' bash -c '[[ "$1" -eq 0 && "$2" -eq 0 ]]' _ "$rc_a" "$rc_b"
    check 'N0a xray final config excludes BOTH uX and uY (stale A did not overwrite B)' \
        jq -e '([.inbounds[] | select(.protocol == "vless") | .settings.clients[]?.email] | sort) == ["uZ@vless"]' "$CFG/config.json"
    check 'N0a xray pending reload marker cleared after convergence' test ! -e "$CFG/.reload-pending.xray"

    # N0b: 写库前 pre-arm 窗口受 DB 锁围栏保护 —— 两个独立进程（写库进程与重建进程）：
    # 即使重建进程恰好在写库进程 pre-arm 后启动，且写库进程在写库后、post-arm 前崩溃，
    # 重建进程仍会等待 DB 锁释放并读取新 DB，绝不提前误清 pre-arm。
    bash -c '
        export VLESS_SOURCE_ONLY=1 VLESS_TEST_CFG="$1" VLESS_TEST_LOG_ROOT="$2"
        export PATH="$3:$PATH"
        source "$4"
        set +u
        _db_lock_acquire
        _reload_pending_arm singbox >/dev/null
        : >"$5/n0b.armed"
        while [[ ! -e "$5/n0b.release" ]]; do sleep 0.05; done
        # 模拟写库进程在锁内禁用最后一位用户 uZ 后直接崩溃（不执行 post-arm）
        jq ".singbox.hy2.users |= map(if .name == \"uZ\" then .enabled = false else . end)" "$DB_FILE" >"$DB_FILE.n0b"
        mv -f "$DB_FILE.n0b" "$DB_FILE"
        _db_lock_release
    ' _ "$CFG" "$SEC/log" "$SEC/bin" "$SEC/product.sh" "$SEC" &
    pid_w=$!
    for _ in $(seq 1 50); do [[ -e "$SEC/n0b.armed" ]] && break; sleep 0.05; done
    bash -c '
        export VLESS_SOURCE_ONLY=1 VLESS_TEST_CFG="$1" VLESS_TEST_LOG_ROOT="$2"
        export PATH="$3:$PATH"
        source "$4"
        set +u
        _ok() { :; }; _info() { :; }; _warn() { :; }; _log() { :; }
        svc() { return 0; }
        rebuild_and_reload_singbox "silent"
    ' _ "$CFG" "$SEC/log" "$SEC/bin" "$SEC/product.sh" &
    pid_r=$!
    sleep 0.35
    check 'N0b rebuild waits behind DB lock fence while writer holds lock' kill -0 "$pid_r"
    : >"$SEC/n0b.release"
    wait "$pid_w"
    wait "$pid_r"; rc_r=$?
    check 'N0b rebuild completes after DB lock release (exit 0)' eq "$rc_r" 0
    check 'N0b rebuild observed post-write DB (0 active users -> singbox.json removed)' test ! -e "$CFG/singbox.json"
    check 'N0b marker cleared only after observing disabled uZ' test ! -e "$CFG/.reload-pending.singbox"
)

# ═════════════ N9: WARP 官方客户端卸载失败保留 warp_official_owned=true 供重试 ═════════════
sec_n9_warp_uninstall_fail() ( fresh_env n9
    write_db <<'J'
{"version":"4.0.0","xray":{"vless":{"port":443,"uuid":"a"}},"singbox":{},"routing":{"warp_mode":"official","warp_official_owned":true},"meta":{}}
J
    DISTRO="debian"
    WARP_PRESENT=1
    WARP_PKG_STATUS="installed"
    APT_REMOVE_RC=1
    _regenerate_proxy_configs() { return 0; }
    systemctl() { return 0; }
    warp-cli() { return 0; }
    dpkg() { return 1; }
    dpkg-query() { printf '%s\n' "$WARP_PKG_STATUS"; }
    check_cmd() {
        case "$1" in
            warp-cli) [[ "$WARP_PRESENT" -eq 1 ]] ;;
            *) return 0 ;;
        esac
    }
    apt-get() {
        if [[ "$*" == *"remove -y cloudflare-warp"* ]]; then
            if [[ "$APT_REMOVE_RC" -eq 0 && "${APT_ACTUALLY_REMOVES:-0}" -eq 1 ]]; then
                WARP_PRESENT=0
                WARP_PKG_STATUS="${APT_POST_STATUS:-not-installed}"
            fi
            return "$APT_REMOVE_RC"
        fi
        return 0
    }
    _ok() { printf 'OK:%s\n' "$*"; }

    # (a) apt-get remove 失败：返回非 0，不报成功，保留 owned=true 与 warp_mode=official
    out=$(uninstall_warp 2>&1); rc=$?
    check 'N9a failed apt-get remove makes uninstall_warp return non-zero' test "$rc" -ne 0
    check 'N9a failed remove does not print success message' bash -c '! grep -q "OK:WARP" <<<"$1"' _ "$out"
    check 'N9a failed remove preserves warp_official_owned=true' eq "$(db_get_warp_official_owned)" true
    check 'N9a failed remove preserves warp_mode=official for retry' eq "$(db_get_warp_mode)" official

    # (b) apt-get 返回 0 但 warp-cli / installed 包仍存在：同样返回非 0 且保留 owned=true
    APT_REMOVE_RC=0
    APT_ACTUALLY_REMOVES=0
    out=$(uninstall_warp_official 2>&1); rc=$?
    check 'N9b lingering warp-cli after apt-get 0 still fails closed' test "$rc" -ne 0
    check 'N9b lingering warp-cli preserves warp_official_owned=true' eq "$(db_get_warp_official_owned)" true

    # (b2) warp-cli 已不存在，但 dpkg-query 仍报 installed：同样 fail-closed 保留 owned=true
    WARP_PRESENT=0
    WARP_PKG_STATUS="installed"
    out=$(uninstall_warp_official 2>&1); rc=$?
    check 'N9b2 dpkg-query installed status still fails closed even without warp-cli' test "$rc" -ne 0
    check 'N9b2 dpkg-query installed preserves warp_official_owned=true' eq "$(db_get_warp_official_owned)" true

    # (c) D2: 包进入 rc (config-files) 态（dpkg -s 会返回 0），但已非 installed 且 warp-cli 已删 → 正常判定卸载成功
    WARP_PRESENT=1
    WARP_PKG_STATUS="installed"
    dpkg() { return 0; } # 模拟 dpkg -s 对 rc 态返回 0
    APT_REMOVE_RC=0
    APT_ACTUALLY_REMOVES=1
    APT_POST_STATUS="config-files"
    out=$(uninstall_warp 2>&1); rc=$?
    check 'N9c(D2) dpkg config-files (rc) state is treated as removed, not stuck failure' eq "$rc" 0
    check 'N9c(D2) config-files state clears warp_official_owned=false' eq "$(db_get_warp_official_owned)" false
    check 'N9c(D2) config-files state resets warp_mode=wgcf' eq "$(db_get_warp_mode)" wgcf

    # (d) 常规彻底移除（not-installed）：返回 0、写 owned=false、切回 wgcf 模式
    db_set_warp_mode "official"
    db_set_warp_official_owned true
    WARP_PRESENT=1
    WARP_PKG_STATUS="installed"
    APT_POST_STATUS="not-installed"
    out=$(uninstall_warp 2>&1); rc=$?
    check 'N9d retry after real removal exits 0' eq "$rc" 0
    check 'N9d retry clears warp_official_owned=false after confirmed removal' eq "$(db_get_warp_official_owned)" false
    check 'N9d retry resets warp_mode=wgcf' eq "$(db_get_warp_mode)" wgcf
)

# ═════════════ D1/D4: 双字段单用户迁移保密 + 清理 _reload_pending_mark 死代码 ═════════════
sec_d1_d4_audit_fixes() ( fresh_env d1d4
    rebuild_and_reload_xray() { return 0; }
    rebuild_and_reload_singbox() { return 0; }

    # D1: db_migrate_to_multiuser 在顶层同时含 uuid+password 时，密码型协议保持原 password，UUID 型保持原 uuid
    write_db <<'J'
{"version":"4.0.0",
 "xray":{
   "vless-ws":{"port":8443,"uuid":"AAA-VLESS","password":"STALE-PW","path":"/ws","sni":"v.example"},
   "trojan":{"port":9443,"uuid":"AAA-TRJ","password":"PPP-TRJ","sni":"t.example"},
   "ss-legacy":{"port":10443,"method":"aes-256-gcm","uuid":"AAA-SS","password":"PPP-SS"},
   "socks":{"port":1080,"username":"ops","uuid":"AAA-SOCKS","password":"PPP-SOCKS"}},
 "singbox":{
   "anytls":{"port":6443,"uuid":"AAA-ANY","password":"PPP-ANY","sni":"a.example"},
   "hy2":{"port":5443,"uuid":"AAA-HY2","password":"PPP-HY2","sni":"h.example"},
   "tuic":{"port":4443,"uuid":"AAA-TUIC","password":"PPP-TUIC","sni":"u.example"}},
 "meta":{}}
J
    db_migrate_to_multiuser >/dev/null 2>&1
    check 'D1 vless-ws keeps uuid after db_migrate_to_multiuser' \
        eq "$(_cfg_effective vless-ws "$(db_get xray vless-ws)" | jq -r '.uuid')" AAA-VLESS
    check 'D1 trojan keeps effective password after db_migrate_to_multiuser' \
        eq "$(_cfg_effective trojan "$(db_get xray trojan)" | jq -r '.password')" PPP-TRJ
    check 'D1 ss-legacy keeps effective password after db_migrate_to_multiuser' \
        eq "$(_cfg_effective ss-legacy "$(db_get xray ss-legacy)" | jq -r '.password')" PPP-SS
    _socks_eff=$(_cfg_effective socks "$(db_get xray socks)")
    check 'D1 socks keeps effective username and password after db_migrate_to_multiuser' \
        jq -e '.username == "ops" and .password == "PPP-SOCKS"' <<<"$_socks_eff"
    check 'D1 anytls keeps effective password after db_migrate_to_multiuser' \
        eq "$(_cfg_effective anytls "$(db_get singbox anytls)" | jq -r '.password')" PPP-ANY
    check 'D1 anytls persists explicit password on migrated default user' \
        eq "$(jq -r '.singbox.anytls.users[0].password' "$DB_FILE")" PPP-ANY
    check 'D1 hy2 keeps effective password after db_migrate_to_multiuser' \
        eq "$(_cfg_effective hy2 "$(db_get singbox hy2)" | jq -r '.password')" PPP-HY2
    _tuic_eff=$(_cfg_effective tuic "$(db_get singbox tuic)")
    check 'D1 tuic keeps both uuid and independent password after db_migrate_to_multiuser' \
        jq -e '.uuid == "AAA-TUIC" and .password == "PPP-TUIC"' <<<"$_tuic_eff"

    # D4: 死代码 _reload_pending_mark 已移除
    check 'D4 dead helper _reload_pending_mark removed from product' \
        bash -c '! grep -Fq "_reload_pending_mark" "$1"' _ "$PRODUCT"
)

for sec in \
    sec_r01_r02_migrator \
    sec_r03_expiry_durable \
    sec_r04_warp_ownership \
    sec_r05_traffic_backlog \
    sec_r06_last_singbox_expire \
    sec_r07_uninstall_db_fail \
    sec_r08_install_staging \
    sec_r09_hy2_cred_parity \
    sec_r10_db_validate_types \
    sec_r11_sub_keep_uuid_txn \
    sec_r12_tuic_cert_key \
    sec_r13_sync_traffic_rc \
    sec_t01_dual_core_menu_update \
    sec_n0_reload_concurrency \
    sec_n9_warp_uninstall_fail \
    sec_d1_d4_audit_fixes; do
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
    printf 'PASS: H17 re-audit remediation regression (%d assertions)\n' "$pass"
else
    grep '^FAIL' "$RESULTS" >&2
    printf 'FAIL: H17 re-audit remediation regression (%d failed, %d passed)\n' "$fail" "$pass" >&2
    exit 1
fi
