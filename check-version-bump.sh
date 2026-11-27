#!/usr/bin/env bash
# ============================================================================
# check-version-bump.sh —— 发布闸门：改了 vless-server.sh 就必须抬 readonly VERSION=
#
# 为什么需要（2026-10-30 死循环事故的直接成因之一）：
#   用户装的是 raw master 上的脚本，脚本靠「远端 VERSION > 本地 VERSION」判断要不要
#   提示更新。只改脚本、不抬 VERSION ⇒ 存量机器不会收到提示，`wget master` 重装拿到的
#   仍是同一份旧逻辑（上一代会话只改了 CI/测试层、VERSION 未动，用户重装后 bug 照旧）。
#   本闸门把这条发布约定变成 CI 硬失败，不再依赖人记得。
#
# 用法：
#   ./check-version-bump.sh                     # 基准：HEAD^（gitorca 全历史正本）
#   ./check-version-bump.sh --base REF          # 基准：指定 ref（CI 传 push.before / PR base）
#   ./check-version-bump.sh --script PATH       # 被检脚本（默认 vless-server.sh）
#
# 基准选取（按可用性降级）：
#   1) 显式 --base
#   2) HEAD^  —— gitorca 是带全历史的正本，父提交就是上一次发布
#   3) 仓库内「最高的语义化 tag」 v<X> —— gitpub / GitHub 侧是**无父单 commit 快照**，
#      没有父提交；语义化 tag 由 ci.yml 的 release 作业按脚本 VERSION 幂等维护，
#      正好是「上一次发布」的锚点，因此这条降级路径同样是可靠的
#   4) 都没有 → 无法判定，告警放行（首次发布/浅克隆可接受，不阻断）
#
# 判定规则（基准里存在同一脚本时）：
#   内容未变                        → 通过（不需要抬版本）
#   内容变了 + VERSION 未变         → 失败 ← 本闸门拦的就是这一条
#   内容变了 + VERSION 变大         → 通过
#   内容变了 + VERSION 变小/不可比  → 失败
#   当前 VERSION 非语义化           → 失败（脚本的 _is_semver_version 会拒绝它，
#                                    用户永远收不到更新提示）
#
# 退出码：0 通过（含「无需判定」）  1 闸门触发 / 版本号非法  2 用法或环境错误
# ============================================================================
set -uo pipefail
export LC_ALL=C

SCRIPT_FILE="vless-server.sh"
BASE_REF=""

usage() { sed -n '2,40p' "$0" | sed 's/^#\{1\} \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --base)   BASE_REF="${2:-}"; shift 2 ;;
        --script) SCRIPT_FILE="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "未知参数: $1（-h 看用法）" >&2; exit 2 ;;
    esac
done

# GitHub Actions 注解；本地直跑时退化为普通输出
annotate() {
    local level="$1"; shift
    if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
        printf '::%s::%s\n' "$level" "$*"
    else
        printf '%s\n' "$*"
    fi
}
info() { printf '  %s\n' "$*"; }
pass() { printf '✓ %s\n' "$*"; }

# 与 vless-server.sh 内 _is_semver_version() 保持完全一致
is_semver() {
    [[ -n "${1:-}" ]] && [[ "$1" =~ ^[0-9]+(\.[0-9]+)*(-h[0-9]+)?$ ]]
}

# 与 vless-server.sh 内 _version_gt() 保持完全一致（v1 > v2 返回 0）
version_gt() {
    local v1="$1" v2="$2"
    [[ "$v1" == "$v2" ]] && return 1
    is_semver "$v1" || return 1
    is_semver "$v2" || return 1

    local base1="${v1%%-h*}" rev1="${v1#*-h}"
    local base2="${v2%%-h*}" rev2="${v2#*-h}"
    [[ "$base1" == "$v1" ]] && rev1=-1
    [[ "$base2" == "$v2" ]] && rev2=-1

    local IFS=.
    # shellcheck disable=SC2206  # 有意按 . 分词
    local i v1_arr=($base1) v2_arr=($base2)
    unset IFS
    for ((i=0; i<${#v1_arr[@]} || i<${#v2_arr[@]}; i++)); do
        local n1=${v1_arr[i]:-0} n2=${v2_arr[i]:-0}
        if [[ "$n1" =~ ^[0-9]+$ && "$n2" =~ ^[0-9]+$ ]]; then
            ((10#$n1 > 10#$n2)) && return 0
            ((10#$n1 < 10#$n2)) && return 1
        else
            [[ "$n1" > "$n2" ]] && return 0
            [[ "$n1" < "$n2" ]] && return 1
        fi
    done

    if [[ "$rev1" =~ ^[0-9]+$ ]]; then rev1=$((10#$rev1)); else rev1=-1; fi
    if [[ "$rev2" =~ ^[0-9]+$ ]]; then rev2=$((10#$rev2)); else rev2=-1; fi
    ((rev1 > rev2)) && return 0
    ((rev1 < rev2)) && return 1
    return 1
}

# 从 stdin 提取 readonly VERSION="..."
extract_version() {
    sed -n 's/^readonly VERSION="\([^"]*\)".*/\1/p' | head -1
}

# 仓库内最高的语义化发布 tag（仅匹配可解析为 commit 的 refs/tags/v*）；若传入 max_exclusive 则只选严格低于该版本的最高 tag
highest_semver_tag() {
    local max_exclusive="${1:-}"
    local t v best_ver="" best_tag=""
    while IFS= read -r t; do
        [[ "$t" == v* ]] || continue
        v="${t#v}"
        is_semver "$v" || continue
        git rev-parse --verify -q "refs/tags/${t}^{commit}" >/dev/null 2>&1 || continue
        if [ -n "$max_exclusive" ] && ! version_gt "$max_exclusive" "$v"; then
            continue
        fi
        if [ -z "$best_ver" ] || version_gt "$v" "$best_ver"; then
            best_ver="$v"
            best_tag="$t"
        fi
    done < <(git for-each-ref --format='%(refname:short)' 'refs/tags/v*' 2>/dev/null)
    [ -n "$best_tag" ] || return 1
    printf '%s\n' "$best_tag"
}

# ---------- 0. 环境与被检脚本 ----------
git rev-parse --show-toplevel >/dev/null 2>&1 || {
    echo "✗ 当前目录不在 git 工作树内（闸门依赖 git 历史判定基准）" >&2
    exit 2
}
[ -f "$SCRIPT_FILE" ] || {
    echo "✗ 找不到被检脚本 $SCRIPT_FILE" >&2
    exit 2
}

CUR_VER="$(extract_version < "$SCRIPT_FILE")"
if [ -z "$CUR_VER" ]; then
    annotate error "$SCRIPT_FILE 中找不到 'readonly VERSION=\"...\"'（脚本升级判定依赖它）"
    exit 1
fi
if ! is_semver "$CUR_VER"; then
    annotate error "VERSION=$CUR_VER 不是语义化版本（应形如 3.4.10-h5）。脚本的 _is_semver_version() 会拒绝非语义化版本，用户将永远收不到更新提示"
    exit 1
fi

# ---------- 1. 选基准 ----------
BASE_SHA=""
BASE_SRC=""
ALL_ZERO_BASE=0
if [ -n "$BASE_REF" ]; then
    # 全 0 是 GitHub 首次推送 / tag push / 部分 force push 的哨兵值：
    # 优先对比「严格低于当前 VERSION 的最高历史发布 tag」（避免多提交分支打 tag 时退回同版本 HEAD^ 误失败）。
    if [[ "$BASE_REF" =~ ^0+$ ]]; then
        ALL_ZERO_BASE=1
    elif git rev-parse --verify -q "$BASE_REF^{commit}" >/dev/null 2>&1; then
        BASE_SHA="$(git rev-parse "$BASE_REF^{commit}")"
        BASE_SRC="--base $BASE_REF"
    else
        info "提示：--base $BASE_REF 在本地对象库中不存在（force push 后旧提交不可达），降级选基准"
    fi
fi
if [ -z "$BASE_SHA" ] && [ "$ALL_ZERO_BASE" -eq 1 ]; then
    # 全 0 哨兵需区分两类合法与非法场景：
    # 1) 已有 >= CUR_VER 的发布 tag 且不指向 HEAD（例如已发 v3.4.10-h20 后又在未抬版本号的新分支改脚本或降级）：
    #    必须与该最高 tag 比较（fail-closed 拦下未抬升/降级）。
    # 2) 最高 tag 恰好 == v$CUR_VER 且指向 HEAD（多提交分支打 tag push）或最高 tag < v$CUR_VER（新未发布版本分支）：
    #    对比严格低于 CUR_VER 的最高历史发布 tag。
    if TOP_TAG="$(highest_semver_tag)"; then
        TOP_VER="${TOP_TAG#v}"
        HEAD_SHA="$(git rev-parse HEAD 2>/dev/null || true)"
        TOP_SHA="$(git rev-parse "$TOP_TAG^{commit}" 2>/dev/null || true)"
        if [ "$TOP_VER" = "$CUR_VER" ] && [ "$TOP_SHA" = "$HEAD_SHA" ]; then
            if PREV_TAG="$(highest_semver_tag "$CUR_VER")"; then
                BASE_SHA="$(git rev-parse "$PREV_TAG^{commit}" 2>/dev/null)"
                BASE_SRC="prev-tag $PREV_TAG"
            else
                BASE_SHA="$TOP_SHA"
                BASE_SRC="tag $TOP_TAG"
            fi
        elif ! version_gt "$CUR_VER" "$TOP_VER"; then
            BASE_SHA="$TOP_SHA"
            BASE_SRC="tag $TOP_TAG"
        else
            BASE_SHA="$TOP_SHA"
            BASE_SRC="prev-tag $TOP_TAG"
        fi
    fi
fi
if [ -z "$BASE_SHA" ] && git rev-parse --verify -q 'HEAD^' >/dev/null 2>&1; then
    BASE_SHA="$(git rev-parse 'HEAD^')"
    BASE_SRC="HEAD^"
fi
if [ -z "$BASE_SHA" ]; then
    if TAG="$(highest_semver_tag)"; then
        BASE_SHA="$(git rev-parse "$TAG^{commit}" 2>/dev/null)"
        BASE_SRC="tag $TAG"
    fi
fi

if [ -z "$BASE_SHA" ]; then
    annotate warning "无法确定发布基准（无父提交且仓库内没有 v<语义化> tag）——跳过 VERSION 抬升校验；首次发布可接受"
    pass "跳过：无基准可比（当前 VERSION=$CUR_VER）"
    exit 0
fi
info "基准：$BASE_SRC（${BASE_SHA:0:7}）"

# ---------- 2. 基准里没有这个脚本 → 新增文件，无需抬版本 ----------
if ! git cat-file -e "$BASE_SHA:$SCRIPT_FILE" 2>/dev/null; then
    pass "$SCRIPT_FILE 在基准中不存在（新增文件）——无需抬版本（当前 VERSION=$CUR_VER）"
    exit 0
fi

BASE_VER="$(git show "$BASE_SHA:$SCRIPT_FILE" | extract_version)"
CUR_SUM="$(sha256sum "$SCRIPT_FILE" | cut -d' ' -f1)"
BASE_SUM="$(git show "$BASE_SHA:$SCRIPT_FILE" | sha256sum | cut -d' ' -f1)"

# ---------- 3. 判定 ----------
if [ "$CUR_SUM" = "$BASE_SUM" ]; then
    pass "$SCRIPT_FILE 内容未变，VERSION=$CUR_VER 无需抬升"
    exit 0
fi

info "$SCRIPT_FILE 内容已变更（${BASE_SUM:0:12}… → ${CUR_SUM:0:12}…）"
info "基准 VERSION=${BASE_VER:-<无>}  当前 VERSION=$CUR_VER"

if [ -z "$BASE_VER" ]; then
    annotate warning "基准版本里读不到 VERSION（旧版脚本可能没有该常量）——无法比较，放行"
    pass "放行：基准无 VERSION 可比（当前 $CUR_VER）"
    exit 0
fi
if ! is_semver "$BASE_VER"; then
    annotate warning "基准 VERSION=$BASE_VER 非语义化——无法比较新旧，放行"
    pass "放行：基准版本号非语义化（当前 $CUR_VER）"
    exit 0
fi

if [ "$CUR_VER" = "$BASE_VER" ]; then
    annotate error "改了 $SCRIPT_FILE 但 VERSION 未抬（仍是 $CUR_VER）——存量机器收不到更新提示，用户重装也拿不到新逻辑。请把 'readonly VERSION=\"$CUR_VER\"' 抬到下一个版本（如 3.4.10-h6）后重试"
    exit 1
fi
if version_gt "$CUR_VER" "$BASE_VER"; then
    pass "VERSION 已抬升：$BASE_VER → $CUR_VER"
    exit 0
fi

annotate error "VERSION 回退或不可比：基准 $BASE_VER → 当前 $CUR_VER。脚本升级判定只认「远端 > 本地」，版本号必须单调递增"
exit 1
