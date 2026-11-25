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
#   2) 尝试调用新脚本生成 singbox.json 并验证通过后重启 vless-singbox
#   3) 仅在步骤 2 确认成功后，按精确服务边界停用旧独立服务 vless-anytls（禁用裸 pkill）
#
# 用法：  sudo bash migrate-anytls-singbox.sh [--db /path/to/db.json] [--dry-run] [--stop-legacy]
#   --db           指定 DB 路径（默认 /etc/vless-reality/db.json）
#   --dry-run      只打印将要做什么，不改库、不重启服务
#   --stop-legacy  即使步骤 2 未自动重建，也允许显式停用旧 vless-anytls 服务

set -euo pipefail

CFG_DEFAULT="/etc/vless-reality"
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
            sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "[✗] 未知参数: $1" >&2
            exit 2
            ;;
    esac
done
[[ -n "$DB" ]] || DB="$CFG_DEFAULT/db.json"

log()  { printf '%s\n' "$*"; }
err()  { printf '[✗] %s\n' "$*" >&2; }
ok()   { printf '[✓] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }

# ---------- 前置检查 ----------
command -v jq >/dev/null 2>&1 || { err "缺少依赖 jq"; exit 1; }
[[ -f "$DB" ]] || { err "DB 不存在: $DB"; exit 1; }

has_xray_anytls=$(jq -e '.xray.anytls // empty' "$DB" 2>/dev/null) \
    && xray_anytls="$has_xray_anytls" || xray_anytls=""
if [[ -z "$xray_anytls" ]]; then
    if jq -e '.singbox.anytls // empty' "$DB" >/dev/null 2>&1; then
        ok "anytls 已在 singbox 核心，无需迁移"
        exit 0
    fi
    err "DB 里找不到 xray.anytls（也没有 singbox.anytls），无法迁移"
    exit 1
fi

# 统一展开为数组校验每个实例都有合法数字端口
src_ports=$(jq -r '
    .xray.anytls | (if type == "array" then . else [.] end) |
    if length == 0 then empty else .[].port // empty end
' "$DB" 2>/dev/null || true)
if [[ -z "$src_ports" ]]; then
    err "xray.anytls 缺少有效 port，配置异常，中止"
    exit 1
fi
while IFS= read -r p; do
    if [[ ! "$p" =~ ^[0-9]+$ ]]; then
        err "xray.anytls 包含非法端口: $p"
        exit 1
    fi
done <<< "$src_ports"

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
if [[ $DRY -eq 1 ]]; then
    log "[计划] 备份 $DB → $DB.bak-migrate-<时间戳> (权限 0600)"
    if [[ $has_existing_sb -eq 1 ]]; then
        log "[计划] 安全合并 xray.anytls 到 singbox.anytls 数组并删除 xray.anytls"
    else
        log "[计划] 搬移 xray.anytls → singbox.anytls 并删除 xray.anytls"
    fi
else
    db_dir=$(dirname -- "$DB")
    lock_dir="${DB}.lock"
    locked=0
    for _ in $(seq 1 50); do
        if mkdir "$lock_dir" 2>/dev/null; then
            printf '%s\n' "$$" > "$lock_dir/pid" 2>/dev/null || true
            locked=1
            break
        fi
        sleep 0.1 2>/dev/null || sleep 1
    done
    if [[ $locked -ne 1 ]]; then
        err "获取数据库写锁超时: $lock_dir"
        exit 1
    fi
    cleanup_lock() { rm -rf "$lock_dir" 2>/dev/null || true; }
    trap cleanup_lock EXIT INT TERM

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
    mv -f "$tmp" "$DB" || { rm -f "$tmp"; err "写回失败（原库未动，备份在 $bak）"; exit 1; }
    chmod 600 "$DB" 2>/dev/null || true
    cleanup_lock
    trap - EXIT INT TERM
    ok "xray.anytls → singbox.anytls 已迁移（port=$port_summary）"
fi

# ---------- 步骤 2：尝试通过新脚本自动重建 singbox.json 并重载 ----------
applied_singbox=0
if [[ $DRY -eq 1 ]]; then
    log "[计划] 调用系统脚本 --apply-configs 重建 singbox.json 并重载 vless-singbox"
else
    script_bin=""
    for cand in /usr/local/bin/vless-server.sh /usr/local/sbin/vless-server.sh; do
        [[ -x "$cand" ]] && { script_bin="$cand"; break; }
    done
    if command -v sing-box >/dev/null 2>&1 && [[ -n "$script_bin" ]]; then
        if "$script_bin" --apply-configs >/dev/null 2>&1; then
            applied_singbox=1
            ok "已自动重建 singbox.json 并应用 vless-singbox"
        else
            warn "自动应用 sing-box 配置失败；请手工执行菜单 14 重建配置并校验 singbox.json"
        fi
    else
        warn "未满足自动重建条件（需已安装 sing-box 及 /usr/local/bin/vless-server.sh）；请手工在菜单 14 重建"
    fi
fi

# ---------- 步骤 3：仅在 sing-box 重建成功（或显式 --stop-legacy）后停用旧服务 ----------
if [[ $DRY -eq 1 ]]; then
    log "[计划] 仅在步骤 2 成功后停用旧服务 vless-anytls（不执行裸 pkill）"
elif [[ $applied_singbox -eq 1 || $FORCE_STOP_LEGACY -eq 1 ]]; then
    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q '^vless-anytls'; then
        systemctl stop vless-anytls 2>/dev/null || true
        systemctl disable vless-anytls 2>/dev/null || true
        ok "已停用 systemd 服务 vless-anytls"
    elif command -v rc-service >/dev/null 2>&1 && [[ -f /etc/init.d/vless-anytls ]]; then
        rc-service vless-anytls stop 2>/dev/null || true
        rc-update del vless-anytls default 2>/dev/null || true
        ok "已停用 OpenRC 服务 vless-anytls"
    else
        warn "未检测到本项目 vless-anytls 服务单元，未执行裸进程终止"
    fi
else
    warn "因步骤 2 未完成自动重建，为避免业务中断暂不停止旧 vless-anytls 服务；手工完成菜单 14 重建后再停用 vless-anytls"
fi

log ""
if [[ $DRY -eq 1 ]]; then
    ok "DRY-RUN 完成——以上为将要执行的动作"
else
    ok "迁移流程结束（DB 备份：$bak）"
fi
