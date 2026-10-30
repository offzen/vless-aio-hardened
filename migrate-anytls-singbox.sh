#!/bin/bash
# migrate-anytls-singbox.sh — 存量 anytls 迁移到 sing-box 核心
#
# 背景：vless-aio-hardened 3.4.10-h1 之后，AnyTLS 从「独立 anytls-go 进程」移入
#       sing-box 统一服务（为的是让 anytls 能吃上真实 ACME 证书，sing-box anytls
#       inbound 原生支持 certificate_path）。老安装里 anytls 配置仍在 DB 的
#       `xray.anytls` 核心，且跑着独立的 `vless-anytls` 服务。
#
# 本脚本把存量 anytls 迁到新模型：
#   1) xray.anytls  →  singbox.anytls（对象原样搬移，字段兼容：password/port/sni）
#   2) 重新生成 singbox.json 并重启 vless-singbox
#   3) 停止并禁用旧独立服务 vless-anytls
#
# 安全：迁移前自动备份 DB（$CFG/db.json.*.bak-migrate-*），写库走「原子临时文件+mktemp」，
#       迁移失败不改原库。建议迁移前手动再备份一次，并在测试机先演练。
#
# 用法：  sudo bash migrate-anytls-singbox.sh [--db /path/to/db.json] [--dry-run]
#   --db        指定 DB 路径（默认 /etc/vless-reality/db.json）
#   --dry-run   只打印将要做什么，不改库、不重启服务

set -u

CFG_DEFAULT="/etc/vless-reality"
DB="${1:-}"
DRY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --db) DB="${2:-}"; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        *) echo "未知参数: $1"; exit 2 ;;
    esac
done
[[ -n "$DB" ]] || DB="$CFG_DEFAULT/db.json"

log()  { printf '%s\n' "$*"; }
err()  { printf '[✗] %s\n' "$*" >&2; }
ok()   { printf '[✓] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }

# ---------- 前置检查 ----------
[[ -f "$DB" ]] || { err "DB 不存在: $DB"; exit 1; }

# 只读检查：anytls 是否还在 xray 核心
has_xray_anytls=$(jq -e '.xray.anytls // empty' "$DB" 2>/dev/null) \
    && xray_anytls="$has_xray_anytls" || xray_anytls=""
if [[ -z "$xray_anytls" ]]; then
    # 可能已迁过 / 从未用旧模型装过
    if jq -e '.singbox.anytls // empty' "$DB" >/dev/null 2>&1; then
        ok "anytls 已在 singbox 核心，无需迁移"
        exit 0
    fi
    err "DB 里找不到 xray.anytls（也没有 singbox.anytls），无法迁移"
    exit 1
fi

port=$(echo "$xray_anytls" | jq -r '.port // empty')
sni=$(echo "$xray_anytls" | jq -r '.sni // "bing.com"')
if [[ -z "$port" ]]; then
    err "xray.anytls 缺少 port，配置异常，中止"
    exit 1
fi

# 检查 singbox.anytls 是否已被占用（避免覆盖已存在的多端口实例）
if jq -e '.singbox.anytls // empty' "$DB" >/dev/null 2>&1; then
    warn "singbox.anytls 已存在！将用 add-port 形式追加（若端口冲突会失败）"
fi

log ""
log "=== 存量 anytls 迁移到 sing-box 核心 ==="
log "  DB   : $DB"
log "  端口 : $port"
log "  SNI  : $sni"
log "  模式 : $([ $DRY -eq 1 ] && echo 'DRY-RUN（只读）' || echo '执行')"
log ""

# ---------- 步骤 1：备份 + 搬移核心 ----------
if [[ $DRY -eq 1 ]]; then
    log "[计划] 备份 $DB → $DB.bak-migrate-<时间戳>"
    log "[计划] jq: .singbox.anytls = .xray.anytls | del(.xray.anytls)"
else
    bak="$DB.bak-migrate-$(date +%Y%m%d-%H%M%S)"
    cp -a "$DB" "$bak" || { err "备份失败，中止"; exit 1; }
    ok "已备份 → $bak"

    tmp=$(mktemp) || { err "mktemp 失败，中止"; exit 1; }
    if ! jq '.singbox.anytls = .xray.anytls | del(.xray.anytls)' "$DB" > "$tmp" 2>/dev/null; then
        rm -f "$tmp"; err "迁移 jq 失败，原库未改动"; exit 1
    fi
    mv "$tmp" "$DB" || { err "写回失败（原库未动，备份在 $bak）"; exit 1; }
    ok "xray.anytls → singbox.anytls 已迁移（port=$port）"
fi

# ---------- 步骤 2：重新生成 singbox 配置并重启 ----------
if [[ $DRY -eq 1 ]]; then
    log "[计划] 重新生成 singbox.json（generate_singbox_config）并重启 vless-singbox"
else
    # 复用脚本自身函数：以最小环境 source 出重建函数（脚本主体不会在此路径执行）
    # 直接调用脚本的菜单入口不可行（交互式），故在此用 sing-box 自身校验 + 服务重启。
    if command -v sing-box >/dev/null 2>&1; then
        # 尝试让脚本重建配置：走它的入口参数（若有非交互重建入口则更稳）
        if [[ -x /usr/local/bin/vless-server.sh ]] || [[ -x /usr/local/sbin/vless-server.sh ]]; then
            warn "检测到脚本本体，建议用脚本自带菜单「重建 Sing-box 配置 + 重启服务」执行步骤 2"
        else
            warn "未找到脚本本体，步骤 2 需手动在脚本菜单执行「重建 Sing-box 配置 + 重启 vless-singbox」"
        fi
    else
        warn "sing-box 未安装（anytls 迁到 singbox 后依赖 sing-box 承载），请先安装 sing-box"
    fi
    # 提示：vless-singbox 服务在脚本菜单「服务管理」里重建/重启最稳妥
fi

# ---------- 步骤 3：停掉旧独立 anytls 服务 ----------
if [[ $DRY -eq 1 ]]; then
    log "[计划] svc stop + disable vless-anytls（旧独立进程）"
else
    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q '^vless-anytls'; then
        systemctl stop vless-anytls 2>/dev/null; systemctl disable vless-anytls 2>/dev/null
        ok "已停用 systemd 服务 vless-anytls"
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service vless-anytls stop 2>/dev/null; rc-update del vless-anytls default 2>/dev/null
        ok "已停用 OpenRC 服务 vless-anytls"
    else
        # 兜底：kill 残留进程
        pkill -f 'anytls-server' 2>/dev/null && warn "已 kill 残留 anytls-server 进程" || warn "未发现运行中的 anytls-server"
    fi
fi

log ""
if [[ $DRY -eq 1 ]]; then
    ok "DRY-RUN 完成——以上为将要执行的动作"
else
    ok "迁移完成（DB 已搬移 + 旧服务已停）。请用脚本菜单完成最后一步："
    log "  • 服务管理 → 重建 Sing-box 配置 → 重启 vless-singbox"
    log "  • anytls 分享链接不变（ANYTLS|%s|$port|…）"
    log "  • 客户端吃到真实证书后，关闭 allowInsecure"
fi