#!/bin/bash
# migrate-anytls-singbox.sh — 存量 anytls 迁移到 sing-box 核心
#
# 背景：vless-aio-hardened 3.4.10-h1 之后，AnyTLS 从「独立 anytls-go 进程」移入
#       sing-box 统一服务（为的是让 anytls 能吃上真实 ACME 证书，sing-box anytls
#       inbound 原生支持 certificate_path）。老安装里 anytls 配置仍在 DB 的
#       `xray.anytls` 核心，且跑着独立的 `vless-anytls` 服务。
#
# 本脚本把存量 anytls 迁到新模型：
#   1) xray.anytls → singbox.anytls（安全兼容单对象/多端口数组；若目标已存在则合并并检测端口冲突，绝不静默覆盖）
#   2) 先停旧服务释放监听端口，再调用新脚本 --apply-configs 重建 singbox.json 并重启 vless-singbox
#   3) 仅当 vless-singbox 在运行且迁移端口均已监听时，才确认接管并停用旧独立服务 vless-anytls；
#      校验失败则恢复迁移前 DB 并重新拉起旧服务（禁用裸 pkill）
#
# 用法：  sudo bash migrate-anytls-singbox.sh [--db /path/to/db.json] [--dry-run] [--stop-legacy]
#   --db           指定 DB 路径（默认 /etc/vless-reality/db.json）。备用 DB 只迁移该文件，
#                  不重建配置、不触碰任何服务（--apply-configs 与服务操作只作用于生产部署）
#   --dry-run      只打印将要做什么，不改库、不重启服务
#   --stop-legacy  即使接管校验失败，也强制保留迁移结果并停用旧 vless-anytls 服务（仅生产 DB）

set -euo pipefail

CFG_DEFAULT="${AIO_MIGRATE_CFG_DIR:-/etc/vless-reality}"
DB=""
DRY=0
FORCE_STOP_LEGACY=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --db)
            if [[ $# -lt 2 || -z "${2:-}" ]]; then
                echo "[✗] --db 需要提供路径参数" >&2
                exit 2
            fi
            DB="$2"
            shift 2
            ;;
        --dry-run)
            DRY=1
            shift
            ;;
        --stop-legacy)
            FORCE_STOP_LEGACY=1
            shift
            ;;
        -h|--help)
            sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "[✗] 未知参数: $1" >&2
            exit 2
            ;;
    esac
done
[[ -n "$DB" ]] || DB="$CFG_DEFAULT/db.json"
# 服务级动作（--apply-configs / 停用旧服务）只对生产 DB 有意义
PROD_DB=0
if [[ "$(readlink -f -- "$DB" 2> /dev/null || printf '%s' "$DB")" == "$(readlink -f -- "$CFG_DEFAULT/db.json" 2> /dev/null || printf '%s' "$CFG_DEFAULT/db.json")" ]]; then
    PROD_DB=1
fi
if [[ $PROD_DB -ne 1 && $FORCE_STOP_LEGACY -eq 1 ]]; then
    echo "[✗] --stop-legacy 只能与生产 DB ($CFG_DEFAULT/db.json) 一起使用；备用 --db 不会触碰服务" >&2
    exit 2
fi

log()  { printf '%s\n' "$*"; }
err()  { printf '[✗] %s\n' "$*" >&2; }
ok()   { printf '[✓] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }

# ---------- 服务辅助函数 ----------
# 注意：不能写成 `systemctl list-unit-files | grep -q`——在 pipefail 下 grep -q 提前退出会让
# systemctl 收到 SIGPIPE，整条管道返回非 0，误判“单元不存在”。先落变量再匹配。
unit_listed() { # unit_listed <name>：systemd 单元文件列表里是否有该单元
    local u="$1" units
    command -v systemctl > /dev/null 2>&1 || return 1
    units=$(systemctl list-unit-files 2> /dev/null || true)
    grep -Eq "^${u}(\.service)?[[:space:]]" <<< "$units"
}
unit_known() { # unit_known <name>：本项目是否安装了该服务单元
    local u="$1"
    unit_listed "$u" && return 0
    command -v rc-service > /dev/null 2>&1 && [[ -f "/etc/init.d/$u" ]]
}
unit_active() { # unit_active <name>
    local u="$1"
    if unit_listed "$u"; then
        systemctl is-active --quiet "$u" 2> /dev/null
    elif command -v rc-service > /dev/null 2>&1 && [[ -f "/etc/init.d/$u" ]]; then
        rc-service "$u" status > /dev/null 2>&1
    else
        return 1
    fi
}
unit_start() {
    local u="$1"
    if unit_listed "$u"; then
        systemctl start "$u" 2> /dev/null
    elif command -v rc-service > /dev/null 2>&1 && [[ -f "/etc/init.d/$u" ]]; then
        rc-service "$u" start > /dev/null 2>&1
    else
        return 1
    fi
}
unit_stop() {
    local u="$1"
    if unit_listed "$u"; then
        systemctl stop "$u" 2> /dev/null
    elif command -v rc-service > /dev/null 2>&1 && [[ -f "/etc/init.d/$u" ]]; then
        rc-service "$u" stop > /dev/null 2>&1
    else
        return 1
    fi
}
disable_legacy_anytls() {
    if unit_listed vless-anytls; then
        systemctl stop vless-anytls 2> /dev/null || true
        systemctl disable vless-anytls 2> /dev/null || true
        ok "已停用 systemd 服务 vless-anytls"
    elif command -v rc-service > /dev/null 2>&1 && [[ -f /etc/init.d/vless-anytls ]]; then
        rc-service vless-anytls stop 2> /dev/null || true
        rc-update del vless-anytls default 2> /dev/null || true
        ok "已停用 OpenRC 服务 vless-anytls"
    else
        warn "未检测到本项目 vless-anytls 服务单元，未执行裸进程终止"
    fi
}
port_listening() { # port_listening <tcp-port>
    local p="$1" out
    # 先落变量再匹配，避免 pipefail 下 grep -q 提前退出导致 ss/netstat 收到 SIGPIPE (141) 误判未监听
    if command -v ss > /dev/null 2>&1; then
        out=$(ss -H -ltn "sport = :$p" 2> /dev/null || true)
        grep -q '[^[:space:]]' <<< "$out"
    elif command -v netstat > /dev/null 2>&1; then
        out=$(netstat -ltn 2> /dev/null || true)
        awk -v p="$p" '$4 ~ ("[:.]" p "$") { found=1 } END { exit (found ? 0 : 1) }' <<< "$out"
    else
        return 1
    fi
}
# 接管校验：vless-singbox 必须在运行，且每个迁移端口都已在监听（最多等待约 10 秒）。
takeover_verified() { # takeover_verified <newline-separated-ports>
    local ports="$1" p ok_all
    for _ in $(seq 1 10); do
        ok_all=1
        unit_active vless-singbox || ok_all=0
        if [[ $ok_all -eq 1 ]]; then
            while IFS= read -r p; do
                [[ -n "$p" ]] || continue
                port_listening "$p" || { ok_all=0; break; }
            done <<< "$ports"
        fi
        [[ $ok_all -eq 1 ]] && return 0
        sleep 1
    done
    return 1
}
resolve_script_bin() {
    local cand
    if [[ -n "${AIO_MIGRATE_SCRIPT_BIN+x}" ]]; then
        [[ -n "$AIO_MIGRATE_SCRIPT_BIN" && -x "$AIO_MIGRATE_SCRIPT_BIN" ]] && printf '%s\n' "$AIO_MIGRATE_SCRIPT_BIN"
        return 0
    fi
    for cand in /usr/local/bin/vless-server.sh /usr/local/sbin/vless-server.sh; do
        [[ -x "$cand" ]] && { printf '%s\n' "$cand"; return 0; }
    done
    return 0
}
resolve_singbox_bin() {
    local cand
    if [[ -n "${AIO_MIGRATE_SINGBOX_BIN+x}" ]]; then
        [[ -n "$AIO_MIGRATE_SINGBOX_BIN" && -x "$AIO_MIGRATE_SINGBOX_BIN" ]] && printf '%s\n' "$AIO_MIGRATE_SINGBOX_BIN"
        return 0
    fi
    cand=$(command -v sing-box 2>/dev/null || true)
    if [[ -n "$cand" ]]; then
        printf '%s\n' "$cand"
        return 0
    fi
    for cand in /usr/local/bin/sing-box /usr/local/sbin/sing-box; do
        [[ -x "$cand" ]] && { printf '%s\n' "$cand"; return 0; }
    done
    return 0
}
extract_anytls_ports() { # extract_anytls_ports <xray|singbox>
    local core="$1" ports p
    ports=$(jq -r --arg c "$core" '
        .[$c].anytls | (if type == "array" then . else [.] end) |
        if length == 0 then empty else .[].port // empty end
    ' "$DB" 2>/dev/null || true)
    if [[ -z "$ports" ]]; then
        err "${core}.anytls 缺少有效 port，配置异常，中止"
        return 1
    fi
    while IFS= read -r p; do
        if [[ ! "$p" =~ ^[0-9]+$ ]]; then
            err "${core}.anytls 包含非法端口: $p"
            return 1
        fi
    done <<< "$ports"
    printf '%s\n' "$ports"
}

# ---------- 数据库互斥锁与原子恢复（与 vless-server.sh 分层锁协议互通） ----------
MIG_LOCK_DIR=""
MIG_FLOCK_FD=""
acquire_db_lock() {
    local lock_dir="${DB}.lock" flock_file="${DB}.lock.flock"
    local i pid old_umask fd=""
    MIG_LOCK_DIR=""
    MIG_FLOCK_FD=""
    if command -v flock > /dev/null 2>&1; then
        old_umask=$(umask)
        umask 077
        if { exec {fd}>"$flock_file"; } 2>/dev/null; then
            umask "$old_umask"
            local flocked=0
            if flock -x -n "$fd" 2>/dev/null; then
                flocked=1
            elif flock --version > /dev/null 2>&1; then
                flock -x -w 10 "$fd" 2>/dev/null && flocked=1
            else
                for _ in $(seq 1 100); do
                    if flock -x -n "$fd" 2>/dev/null; then
                        flocked=1
                        break
                    fi
                    sleep 0.1 2>/dev/null || sleep 1
                done
            fi
            if [[ $flocked -ne 1 ]]; then
                { exec {fd}>&-; } 2>/dev/null || true
                err "获取数据库 flock 锁超时: $flock_file"
                return 1
            fi
            MIG_FLOCK_FD="$fd"
        else
            umask "$old_umask"
        fi
    fi
    for i in $(seq 1 100); do
        if mkdir "$lock_dir" 2>/dev/null; then
            printf '%s\n' "$$" > "$lock_dir/pid" 2>/dev/null || true
            MIG_LOCK_DIR="$lock_dir"
            return 0
        fi
        pid=$(cat "$lock_dir/pid" 2>/dev/null || true)
        if [[ "$pid" =~ ^[0-9]+$ ]] && ! kill -0 "$pid" 2>/dev/null; then
            rm -rf "$lock_dir" 2>/dev/null || true
            continue
        fi
        sleep 0.1 2>/dev/null || sleep 1
    done
    if [[ -n "$MIG_FLOCK_FD" ]]; then
        command -v flock > /dev/null 2>&1 && flock -u "$MIG_FLOCK_FD" 2>/dev/null || true
        { exec {MIG_FLOCK_FD}>&-; } 2>/dev/null || true
        MIG_FLOCK_FD=""
    fi
    err "获取数据库写锁超时: $lock_dir"
    return 1
}
release_db_lock() {
    if [[ -n "$MIG_LOCK_DIR" ]]; then
        rm -rf "$MIG_LOCK_DIR" 2>/dev/null || true
        MIG_LOCK_DIR=""
    fi
    if [[ -n "$MIG_FLOCK_FD" ]]; then
        command -v flock > /dev/null 2>&1 && flock -u "$MIG_FLOCK_FD" 2>/dev/null || true
        { exec {MIG_FLOCK_FD}>&-; } 2>/dev/null || true
        MIG_FLOCK_FD=""
    fi
}
atomic_write_json() { # atomic_write_json <target_file> <json_content>
    local dst="$1" content="$2" dst_dir tmp
    dst_dir=$(dirname -- "$dst")
    tmp=$(mktemp "$dst_dir/.migrate-anytls.tmp.XXXXXX") || return 1
    chmod 600 "$tmp" 2>/dev/null || true
    if printf '%s\n' "$content" > "$tmp" && chmod 600 "$tmp" 2>/dev/null && mv -f "$tmp" "$dst" 2>/dev/null; then
        return 0
    fi
    rm -f "$tmp" 2>/dev/null || true
    return 1
}
STATE_FILE="$CFG_DEFAULT/.migrate-anytls.state.json"
write_migration_state() { # write_migration_state <json_content>
    atomic_write_json "$STATE_FILE" "$1"
}
clear_migration_state() {
    rm -f -- "$STATE_FILE" 2>/dev/null || true
}
# 精细字段级回滚：锁内校验 .xray.anytls 仍为空且 .singbox.anytls 仍等于本次迁移写入值，
# 只逆转这两个字段，保留服务切换窗口内其他协议/用户/配额的并发修改。
# 返回: 0=回滚成功, 1=锁/IO失败, 2=同字段已被并发修改（保留现场不覆盖）
surgical_rollback_db() { # surgical_rollback_db <orig_xray_json> <orig_sb_json> <expected_sb_json>
    local orig_xray="$1" orig_sb="$2" expected_sb="$3"
    local dst_dir tmp
    dst_dir=$(dirname -- "$DB")
    acquire_db_lock || return 1
    if ! jq -e --argjson exp_sb "$expected_sb" '
        ((.xray.anytls // null) == null) and ((.singbox.anytls // null) == $exp_sb)
    ' "$DB" > /dev/null 2>&1; then
        release_db_lock
        return 2
    fi
    tmp=$(mktemp "$dst_dir/db.json.rollback.XXXXXX") || { release_db_lock; return 1; }
    chmod 600 "$tmp" 2>/dev/null || true
    if jq --argjson orig_xray "$orig_xray" --argjson orig_sb "$orig_sb" '
        .xray = ((.xray // {}) + {anytls: $orig_xray}) |
        if $orig_sb == null then
            if (.singbox | type) == "object" then del(.singbox.anytls) else . end
        else
            .singbox = ((.singbox // {}) + {anytls: $orig_sb})
        end
    ' "$DB" > "$tmp" 2>/dev/null && [[ -s "$tmp" ]] && chmod 600 "$tmp" 2>/dev/null && mv -f "$tmp" "$DB" 2>/dev/null; then
        release_db_lock
        return 0
    fi
    rm -f "$tmp" 2>/dev/null || true
    release_db_lock
    return 1
}
any_port_listening() { # any_port_listening <newline-separated-ports>
    local ports="$1" p
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        port_listening "$p" && return 0
    done <<< "$ports"
    return 1
}
# 执行生产服务接管；失败时按状态记录精细回滚（仅撤销本次 AnyTLS 字段并恢复旧服务）。
# 参数: $1=ports(换行分隔) $2=legacy_was_active $3=sb_was_active $4=resumed_only(0|1)
#       $5=orig_xray_json $6=orig_sb_json $7=expected_sb_json $8=bak_file
perform_prod_takeover() {
    local ports="$1" legacy_was_active="$2" sb_was_active="$3" resumed_only="$4"
    local orig_xray="$5" orig_sb="$6" expected_sb="$7" bak_file="$8"
    local port_summary state_json
    port_summary=$(tr '\n' ',' <<< "$ports" | sed 's/,$//')

    # 在停旧服务前持久化阶段标记，确保停旧后进程中断仍可由下次运行识别并恢复，绝不误报“无需迁移”。
    state_json=$(jq -cn \
        --arg phase "stopping_legacy" \
        --argjson resumed_only "$([[ "$resumed_only" -eq 1 ]] && echo true || echo false)" \
        --argjson legacy_was_active "$legacy_was_active" \
        --argjson sb_was_active "$sb_was_active" \
        --arg ports_nl "$ports" \
        --arg bak_file "$bak_file" \
        --argjson orig_xray "$orig_xray" \
        --argjson orig_sb "$orig_sb" \
        --argjson expected_sb "$expected_sb" '
        {
            version: 1,
            phase: $phase,
            resumed_only: $resumed_only,
            legacy_was_active: $legacy_was_active,
            sb_was_active: $sb_was_active,
            ports: ($ports_nl | split("\n") | map(select(length > 0))),
            bak_file: $bak_file,
            orig_xray_anytls: $orig_xray,
            orig_singbox_anytls: $orig_sb,
            expected_singbox_anytls: $expected_sb
        }
    ')
    if ! write_migration_state "$state_json"; then
        err "无法写入迁移状态文件 $STATE_FILE，已中止服务切换"
        return 1
    fi

    # 旧服务占着同一监听端口，必须先释放才能让 sing-box 接管；失败时回滚。
    if unit_known vless-anytls && unit_active vless-anytls; then
        unit_stop vless-anytls || warn "停止旧服务 vless-anytls 失败，继续尝试接管"
    fi
    if "$script_bin" --apply-configs --ensure-singbox > /dev/null 2>&1 && takeover_verified "$ports"; then
        ok "sing-box 已接管：vless-singbox 运行中，端口 $port_summary 均在监听"
        disable_legacy_anytls
        clear_migration_state
        return 0
    fi

    warn "sing-box 未能接管 anytls 端口（服务未运行或端口未监听）"
    if [[ $FORCE_STOP_LEGACY -eq 1 ]]; then
        warn "--stop-legacy 已显式指定：保留迁移后的 DB，继续停用旧服务"
        disable_legacy_anytls
        clear_migration_state
        return 0
    fi

    if [[ $resumed_only -eq 0 ]]; then
        local rb_rc=0
        surgical_rollback_db "$orig_xray" "$orig_sb" "$expected_sb" || rb_rc=$?
        if [[ $rb_rc -eq 2 || $rb_rc -ne 0 ]]; then
            # 无论冲突还是 IO 失败，DB 现场与未完成状态标记都保留，但必须先释放半启/占端口的
            # vless-singbox 并恢复先前在跑的旧服务 vless-anytls，避免造成端口无服务的业务中断。
            if unit_active vless-singbox && { [[ $sb_was_active -eq 0 ]] || any_port_listening "$ports"; }; then
                unit_stop vless-singbox || warn "停止半启动或占用迁移端口的 vless-singbox 失败"
            fi
            if [[ $legacy_was_active -eq 1 ]]; then
                if unit_start vless-anytls && unit_active vless-anytls; then
                    warn "已重新拉起旧服务 vless-anytls 以恢复 AnyTLS 业务（DB 现场与未完成状态标记已保留）"
                else
                    err "重新拉起 vless-anytls 失败，AnyTLS 可能中断，请立即手工启动"
                fi
            fi
            if [[ $rb_rc -eq 2 ]]; then
                err "回滚冲突：迁移期间 xray.anytls 或 singbox.anytls 已被其他操作修改；已保留当前 DB 现场，未静默覆盖（原始备份: ${bak_file:-无}）"
            else
                err "精细回滚 DB 失败，保留现场与未完成标记；请排查后重试或手工核对 ${bak_file:-$DB}"
            fi
            return 1
        fi
        warn "已仅撤销本次 AnyTLS 迁移字段（保留迁移期间其他协议的所有 DB 修改）"

        local live_sb_has_protos=0
        if jq -e '(.singbox // {} | length) > 0' "$DB" > /dev/null 2>&1; then
            live_sb_has_protos=1
        fi
        if [[ $live_sb_has_protos -eq 0 ]]; then
            if unit_known vless-singbox || unit_active vless-singbox; then
                unit_stop vless-singbox || warn "停止未接管的 vless-singbox 失败"
            fi
            rm -f -- "$CFG_DEFAULT/singbox.json" 2>/dev/null || true
        else
            "$script_bin" --apply-configs > /dev/null 2>&1 || warn "按回滚后 DB 重建 sing-box 配置失败，请手工执行菜单 14"
            if unit_active vless-singbox && { [[ $sb_was_active -eq 0 ]] || any_port_listening "$ports"; }; then
                unit_stop vless-singbox || warn "停止占用迁移端口的 vless-singbox 失败"
            fi
        fi

        if [[ $legacy_was_active -eq 1 ]]; then
            if unit_start vless-anytls && unit_active vless-anytls; then
                warn "已重新拉起旧服务 vless-anytls，AnyTLS 业务保持原状"
                clear_migration_state
            else
                err "重新拉起 vless-anytls 失败，AnyTLS 可能中断，请立即手工启动（保留未完成状态标记以记忆旧服务原为运行态）"
            fi
        else
            # 迁移前旧服务本未运行，DB 已回退到 xray.anytls，可安全清除状态文件
            clear_migration_state
        fi
    else
        # 半迁移续接（无迁移前快照）：不改动 DB，只释放未接管的 sing-box 并恢复旧服务
        if unit_active vless-singbox && { [[ $sb_was_active -eq 0 ]] || any_port_listening "$ports"; }; then
            unit_stop vless-singbox || warn "停止半启动的 vless-singbox 失败，旧服务可能端口冲突"
        fi
        if [[ $legacy_was_active -eq 1 ]]; then
            if unit_start vless-anytls && unit_active vless-anytls; then
                warn "已重新拉起旧服务 vless-anytls，AnyTLS 业务保持原状"
                clear_migration_state
            else
                err "重新拉起 vless-anytls 失败，AnyTLS 可能中断，请立即手工启动（保留未完成状态标记）"
            fi
        fi
    fi
    err "迁移未完成，已回滚；排查 sing-box 后可重试（或用 --stop-legacy 强制接管）"
    return 1
}

# ---------- 前置检查 ----------
command -v jq >/dev/null 2>&1 || { err "缺少依赖 jq"; exit 1; }
[[ -f "$DB" ]] || { err "DB 不存在: $DB"; exit 1; }

script_bin="$(resolve_script_bin)"
singbox_bin="$(resolve_singbox_bin)"
missing_prereqs=()
[[ -n "$singbox_bin" ]] || missing_prereqs+=("sing-box")
[[ -n "$script_bin" ]] || missing_prereqs+=("/usr/local/bin/vless-server.sh")

has_xray_anytls=$(jq -e '.xray.anytls // empty' "$DB" 2>/dev/null) \
    && xray_anytls="$has_xray_anytls" || xray_anytls=""
if [[ -z "$xray_anytls" ]]; then
    if jq -e '.singbox.anytls // empty' "$DB" >/dev/null 2>&1; then
        # 生产 DB 已在 singbox.anytls 时，若存在未完成的迁移状态文件（例如停旧后进程中断）
        # 或旧独立服务 vless-anytls 仍在运行，都必须进入续接/恢复流程，绝不误报“无需迁移”。
        has_pending_state=0
        [[ $PROD_DB -eq 1 && -f "$STATE_FILE" ]] && has_pending_state=1
        legacy_still_active=0
        [[ $PROD_DB -eq 1 ]] && unit_known vless-anytls && unit_active vless-anytls && legacy_still_active=1

        if [[ $has_pending_state -eq 1 || $legacy_still_active -eq 1 ]]; then
            dst_ports=$(extract_anytls_ports singbox) || exit 1
            port_summary=$(tr '\n' ',' <<< "$dst_ports" | sed 's/,$//')
            resumed_only=1
            st_legacy_was_active=1
            st_sb_was_active=0
            st_orig_xray="null"
            st_orig_sb="null"
            st_expected_sb="null"
            st_bak=""
            if [[ $has_pending_state -eq 1 ]]; then
                if ! jq -e 'type == "object"' "$STATE_FILE" >/dev/null 2>&1; then
                    err "检测到损坏的未完成迁移状态文件: $STATE_FILE；拒绝误报无需迁移，请核对服务与 DB 后清理"
                    exit 1
                fi
                # 以当前 DB 的 singbox.anytls 端口为准（仅在状态文件端口与 DB 不同时提示），避免中断期改端口后用陈旧端口校验
                st_ports=$(jq -r '(.ports // [])[]' "$STATE_FILE" 2>/dev/null || true)
                if [[ -n "$st_ports" && "$(printf '%s\n' "$st_ports" | sort -u)" != "$(printf '%s\n' "$dst_ports" | sort -u)" ]]; then
                    warn "当前 DB singbox.anytls 端口 ($port_summary) 与状态文件记录 ($(tr '\n' ',' <<< "$st_ports" | sed 's/,$//')) 不一致，将以当前 DB 端口为准校验接管"
                fi
                [[ "$(jq -r 'if .resumed_only == false then "false" else "true" end' "$STATE_FILE")" == "false" ]] && resumed_only=0
                st_legacy_was_active=$(jq -r 'if .legacy_was_active == 0 then 0 else 1 end' "$STATE_FILE")
                st_sb_was_active=$(jq -r 'if .sb_was_active == 1 then 1 else 0 end' "$STATE_FILE")
                st_orig_xray=$(jq -c '.orig_xray_anytls // null' "$STATE_FILE")
                st_orig_sb=$(jq -c '.orig_singbox_anytls // null' "$STATE_FILE")
                st_expected_sb=$(jq -c '.expected_singbox_anytls // null' "$STATE_FILE")
                st_bak=$(jq -r '.bak_file // ""' "$STATE_FILE")
            else
                unit_active vless-singbox && st_sb_was_active=1
            fi

            if ((${#missing_prereqs[@]} > 0)); then
                if [[ $DRY -eq 1 ]]; then
                    warn "DRY-RUN 提示：检测到未完成的迁移状态，且当前缺少前置条件（${missing_prereqs[*]}），正式执行前须先安装"
                else
                    err "检测到未完成的迁移状态（DB 已在 singbox.anytls，需完成服务接管或恢复），但缺少前置条件（${missing_prereqs[*]}）"
                    err "请先安装缺失组件后重跑本脚本完成接管"
                    exit 1
                fi
            fi
            if [[ $DRY -eq 1 ]]; then
                log "=== 检测到未完成的 AnyTLS 迁移状态（DB 已在 singbox.anytls） ==="
                log "  DB   : $DB"
                log "  端口 : $port_summary"
                log "[计划] 确认停旧服务并调用 ${script_bin:-/usr/local/bin/vless-server.sh} --apply-configs --ensure-singbox 校验 vless-singbox 接管"
                log "[计划] 接管验证通过后停用旧服务并清除未完成标记；否则精细回滚或恢复旧服务"
                ok "DRY-RUN 完成——以上为将要执行的动作"
                exit 0
            fi
            warn "检测到未完成的 AnyTLS 迁移状态，继续完成服务接管或恢复（port=$port_summary）"
            if perform_prod_takeover "$dst_ports" "$st_legacy_was_active" "$st_sb_was_active" \
                "$resumed_only" "$st_orig_xray" "$st_orig_sb" "$st_expected_sb" "$st_bak"; then
                ok "迁移恢复与接管完成"
                exit 0
            fi
            exit 1
        fi
        ok "anytls 已在 singbox 核心，无需迁移"
        exit 0
    fi
    err "DB 里找不到 xray.anytls（也没有 singbox.anytls），无法迁移"
    exit 1
fi

# 生产 DB 改库前先校验自动接管前置条件：缺组件时拒绝半迁移，保持 DB 与旧服务原样；--dry-run 仅告警允许预览
if [[ $PROD_DB -eq 1 && ${#missing_prereqs[@]} -gt 0 ]]; then
    if [[ $DRY -eq 1 ]]; then
        warn "DRY-RUN 提示：当前主机缺少生产接管前置条件（${missing_prereqs[*]}），正式执行前须先安装"
    else
        err "未满足生产接管前置条件（缺少: ${missing_prereqs[*]}）；为避免产生半迁移状态，已中止且未改动 $DB"
        err "请先安装 sing-box 及 /usr/local/bin/vless-server.sh 后重跑；若仅需离线迁移文件，请用 --db 指定备用 DB 路径"
        exit 1
    fi
fi

# 统一展开为数组校验每个实例都有合法数字端口
src_ports=$(extract_anytls_ports xray) || exit 1

# 检查目标 singbox.anytls 是否已有端口冲突（合并时绝不覆盖）
has_existing_sb=0
if jq -e '.singbox.anytls // empty' "$DB" >/dev/null 2>&1; then
    has_existing_sb=1
    conflict=$(jq -r '
        (.xray.anytls | if type == "array" then . else [.] end | map(.port | tostring)) as $src |
        (.singbox.anytls | if type == "array" then . else [.] end | map(.port | tostring)) as $dst |
        [$src[] | select(. as $p | $dst | index($p) != null)] | join(",")
    ' "$DB" 2>/dev/null || true)
    if [[ -n "$conflict" ]]; then
        err "singbox.anytls 已存在冲突端口 ($conflict)，拒绝覆盖，已中止"
        exit 1
    fi
    warn "singbox.anytls 已存在，将以数组形式安全合并新端口实例（不覆盖现有实例）"
fi

port_summary=$(tr '\n' ',' <<< "$src_ports" | sed 's/,$//')

log ""
log "=== 存量 anytls 迁移到 sing-box 核心 ==="
log "  DB   : $DB"
log "  端口 : $port_summary"
log "  模式 : $([[ $DRY -eq 1 ]] && echo 'DRY-RUN（只读）' || echo '执行')"
log ""

# ---------- 步骤 1：加锁 + 备份 + 同目录原子搬移/合并 ----------
orig_xray_json="null"
orig_sb_json="null"
expected_sb_json="null"
legacy_was_active=0
sb_was_active=0
if [[ $DRY -eq 1 ]]; then
    log "[计划] 备份 $DB → $DB.bak-migrate-<时间戳> (权限 0600)"
    if [[ $has_existing_sb -eq 1 ]]; then
        log "[计划] 安全合并 xray.anytls 到 singbox.anytls 数组并删除 xray.anytls"
    else
        log "[计划] 搬移 xray.anytls → singbox.anytls 并删除 xray.anytls"
    fi
else
    if [[ $PROD_DB -eq 1 ]]; then
        unit_known vless-anytls && unit_active vless-anytls && legacy_was_active=1
        # 若上一轮回滚时拉起旧服务失败导致保留了状态文件，继承其 legacy_was_active=1，避免陷入“双服务 down”循环
        if [[ $legacy_was_active -eq 0 && -f "$STATE_FILE" ]]; then
            if [[ "$(jq -r '.legacy_was_active // 0' "$STATE_FILE" 2>/dev/null || echo 0)" == "1" ]]; then
                legacy_was_active=1
            fi
        fi
        unit_active vless-singbox && sb_was_active=1
    fi
    db_dir=$(dirname -- "$DB")
    acquire_db_lock || exit 1
    trap release_db_lock EXIT INT TERM

    orig_xray_json=$(jq -c '.xray.anytls // null' "$DB" 2>/dev/null) || { err "读取 xray.anytls 失败，中止"; exit 1; }
    orig_sb_json=$(jq -c '.singbox.anytls // null' "$DB" 2>/dev/null) || { err "读取 singbox.anytls 失败，中止"; exit 1; }

    bak="$DB.bak-migrate-$(date +%Y%m%d-%H%M%S)"
    cp -a "$DB" "$bak" || { err "备份失败，中止"; exit 1; }
    chmod 600 "$bak" 2>/dev/null || true
    ok "已备份 → $bak"

    tmp=$(mktemp "$db_dir/db.json.migrate.XXXXXX") || { err "mktemp 失败，中止"; exit 1; }
    chmod 600 "$tmp" 2>/dev/null || true
    if ! jq '
        (.xray.anytls | if type == "array" then . else [.] end) as $src |
        if .singbox.anytls == null then
            .singbox.anytls = .xray.anytls
        else
            (.singbox.anytls | if type == "array" then . else [.] end) as $dst |
            .singbox.anytls = ($dst + $src)
        end |
        del(.xray.anytls)
    ' "$DB" > "$tmp" 2>/dev/null || [[ ! -s "$tmp" ]]; then
        rm -f "$tmp"
        err "迁移 jq 失败，原库未改动"
        exit 1
    fi
    expected_sb_json=$(jq -c '.singbox.anytls // null' "$tmp" 2>/dev/null) || { rm -f "$tmp"; err "解析迁移目标字段失败，原库未改动"; exit 1; }
    if [[ $PROD_DB -eq 1 ]]; then
        # 在 DB 替换前即落盘未完成迁移状态，消除「DB 已改但状态尚未写入」的中断窗口
        pre_state_json=$(jq -cn \
            --arg phase "db_migrated" \
            --argjson legacy_was_active "$legacy_was_active" \
            --argjson sb_was_active "$sb_was_active" \
            --arg ports_nl "$src_ports" \
            --arg bak_file "$bak" \
            --argjson orig_xray "$orig_xray_json" \
            --argjson orig_sb "$orig_sb_json" \
            --argjson expected_sb "$expected_sb_json" '
            {
                version: 1,
                phase: $phase,
                resumed_only: false,
                legacy_was_active: $legacy_was_active,
                sb_was_active: $sb_was_active,
                ports: ($ports_nl | split("\n") | map(select(length > 0))),
                bak_file: $bak_file,
                orig_xray_anytls: $orig_xray,
                orig_singbox_anytls: $orig_sb,
                expected_singbox_anytls: $expected_sb
            }
        ')
        if ! write_migration_state "$pre_state_json"; then
            rm -f "$tmp"
            err "写入迁移状态文件失败，原库未改动"
            exit 1
        fi
    fi
    if ! mv -f "$tmp" "$DB"; then
        rm -f "$tmp"
        [[ $PROD_DB -eq 1 ]] && clear_migration_state
        err "写回失败（原库未动，备份在 $bak）"
        exit 1
    fi
    chmod 600 "$DB" 2>/dev/null || true
    release_db_lock
    trap - EXIT INT TERM
    ok "xray.anytls → singbox.anytls 已迁移（port=$port_summary）"
fi

# ---------- 步骤 2/3：服务切换（仅限生产部署） ----------
# --apply-configs 与服务停启始终作用于 /etc/vless-reality 的生产部署；
# 指定备用 --db 时只迁移该 DB 文件，绝不重建配置或停用生产服务。
if [[ $DRY -eq 1 ]]; then
    if [[ $PROD_DB -eq 1 ]]; then
        log "[计划] 先持久化迁移状态并停止旧服务 vless-anytls 释放端口，再调用系统脚本 --apply-configs --ensure-singbox 重建并启动/重载 vless-singbox"
        log "[计划] 仅当 vless-singbox 运行且迁移端口均在监听时才确认接管并清除状态；否则仅撤销本次 AnyTLS 字段并重新拉起 vless-anytls"
    else
        log "[计划] 备用 DB（非 $CFG_DEFAULT/db.json）：只迁移 DB 文件，不重建配置、不触碰任何服务"
    fi
elif [[ $PROD_DB -ne 1 ]]; then
    warn "指定了备用 DB（$DB）：仅迁移了该文件；未重建 sing-box 配置，也未停用任何服务（服务操作只作用于 $CFG_DEFAULT 生产部署）"
else
    perform_prod_takeover "$src_ports" "$legacy_was_active" "$sb_was_active" \
        0 "$orig_xray_json" "$orig_sb_json" "$expected_sb_json" "$bak" || exit 1
fi

log ""
if [[ $DRY -eq 1 ]]; then
    ok "DRY-RUN 完成——以上为将要执行的动作"
else
    ok "迁移流程结束（DB 备份：${bak:-无}）"
fi
