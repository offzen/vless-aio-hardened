#!/usr/bin/env bash
# ============================================================================
# sync-release.sh —— 让 GitHub Release 恒等于脚本内的 readonly VERSION=
#
# 为什么必须有（2026-10-30 死循环事故的「反面」风险）：
#   vless-server.sh 的 _get_latest_script_version() **优先**取
#   `GET /repos/{repo}/releases/latest` 的 `.tag_name`，且只接受语义化版本。
#   一旦 Release 落后于脚本 VERSION（发了 h6 却忘建 v3.4.10-h6），存量机器会读到
#   旧版本号 ⇒ 判定「已是最新」⇒ **永远收不到更新提示**（静默、无报错，比死循环更难发现）。
#   本作业由 ci.yml 在 GitHub 侧每次 push master 后幂等执行：缺则建、有则不动，
#   因此「Release 落后」不可能发生；也不需要外部 PAT（用仓库自带 GITHUB_TOKEN）。
#
# 环境变量（由 ci.yml 注入）：
#   GITHUB_REPOSITORY  必需，如 offzen/vless-aio-hardened
#   GITHUB_SHA         必需，Release 的 target_commitish
#   GH_TOKEN / GITHUB_TOKEN  必需，需 contents: write
#   GITHUB_API_URL     可选，默认 https://api.github.com
#                      非 GitHub（gitorca/gitpub 的 act_runner）会跑到本作业 ⇒ 跳过并 exit 0
#   SCRIPT_FILE        可选，默认 vless-server.sh
#
# 幂等性：同一 VERSION 重复跑 = no-op；已存在的 Release 不删除、不改写。
# 安全阀：若已存在**高于**脚本 VERSION 的 Release（回滚/误发场景），直接失败 ——
#         否则用户会被提示升级到 master 上并不存在的版本，更新后版本号追不上 ⇒ 死循环。
#
# 退出码：0 成功（含已存在 / 非 GitHub 侧跳过）  1 校验/API 失败  2 环境缺失
# ============================================================================
set -uo pipefail
export LC_ALL=C

SCRIPT_FILE="${SCRIPT_FILE:-vless-server.sh}"
REPO="${GITHUB_REPOSITORY:-}"
SHA="${GITHUB_SHA:-}"
API="${GITHUB_API_URL:-https://api.github.com}"
TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

die() { local m="$1" c="${2:-1}"; printf '✗ %s\n' "$m" >&2; exit "$c"; }
info() { printf '  %s\n' "$*"; }
ok() { printf '  ✓ %s\n' "$*"; }
err_ann() {
    if [ "${GITHUB_ACTIONS:-}" = "true" ]; then printf '::error::%s\n' "$*" >&2; else printf '✗ %s\n' "$*" >&2; fi
}

# 非 GitHub 侧（gitorca / gitpub 的 act_runner）正常会跑到本作业：直接**跳过并成功**。
# 不能失败——三端共用同一份 ci.yml，若在这里 exit 1 就会把私有侧 CI 染红，
# 而「私有侧不建 Release」本身是预期行为，不是错误。
# 2026-10-30 实测：Gitea 1.27.3 的 if: 求值对该作业未生效（作业仍被排队），
# 故此处是真正的闸门，不能只依赖 ci.yml 的 if:。
case "$API" in
    https://api.github.com*) : ;;
    *)
        # 仅离线单测（test-sync-release.sh 起本地 mock API）用这个逃生门，CI 里永远不设它
        if [ "${SYNC_RELEASE_ALLOW_API_OVERRIDE:-0}" = "1" ]; then
            info "警告：已按 SYNC_RELEASE_ALLOW_API_OVERRIDE=1 允许非 GitHub API（仅限离线单测）"
        else
            info "当前不是 GitHub（GITHUB_API_URL=$API）——私有侧（gitorca/gitpub）不建 Release，跳过"
            printf 'RELEASE_SYNC=skipped\n'
            exit 0
        fi
        ;;
esac

[ -n "$REPO" ] || die "缺少 GITHUB_REPOSITORY（本脚本只在 CI 中运行）" 2
[ -n "$SHA" ] || die "缺少 GITHUB_SHA" 2
[ -n "$TOKEN" ] || die "缺少 GH_TOKEN / GITHUB_TOKEN —— workflow 需声明 permissions: contents: write" 2
[ -f "$SCRIPT_FILE" ] || die "找不到 $SCRIPT_FILE" 2

# 与 vless-server.sh 内 _is_semver_version() 一致
is_semver() { [[ -n "${1:-}" ]] && [[ "$1" =~ ^[0-9]+(\.[0-9]+)*(-h[0-9]+)?$ ]]; }

# 与 vless-server.sh 内 _version_gt() 一致（v1 > v2 返回 0）
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
    # shellcheck disable=SC2206
    local i v1_arr=($base1) v2_arr=($base2)
    unset IFS
    for ((i=0; i<${#v1_arr[@]} || i<${#v2_arr[@]}; i++)); do
        local n1=${v1_arr[i]:-0} n2=${v2_arr[i]:-0}
        if [[ "$n1" =~ ^[0-9]+$ && "$n2" =~ ^[0-9]+$ ]]; then
            ((n1 > n2)) && return 0
            ((n1 < n2)) && return 1
        else
            [[ "$n1" > "$n2" ]] && return 0
            [[ "$n1" < "$n2" ]] && return 1
        fi
    done
    [[ "$rev1" =~ ^[0-9]+$ ]] || rev1=-1
    [[ "$rev2" =~ ^[0-9]+$ ]] || rev2=-1
    ((rev1 > rev2)) && return 0
    ((rev1 < rev2)) && return 1
    return 1
}

# api METHOD PATH OUTFILE [JSON] -> 打印 HTTP 状态码，响应体写入 OUTFILE
api() {
    local method="$1" path="$2" out="$3" data="${4:-}"
    if [ -n "$data" ]; then
        curl -sS --max-time 30 -X "$method" \
            -H "Authorization: Bearer $TOKEN" \
            -H 'Accept: application/vnd.github+json' \
            -H 'X-GitHub-Api-Version: 2022-11-28' \
            -d "$data" "$API$path" -o "$out" -w '%{http_code}' 2>/dev/null
    else
        curl -sS --max-time 30 -X "$method" \
            -H "Authorization: Bearer $TOKEN" \
            -H 'Accept: application/vnd.github+json' \
            -H 'X-GitHub-Api-Version: 2022-11-28' \
            "$API$path" -o "$out" -w '%{http_code}' 2>/dev/null
    fi
}

TMP="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/sync-release.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# ---------- 0. 读脚本版本 ----------
VER="$(sed -n 's/^readonly VERSION="\([^"]*\)".*/\1/p' "$SCRIPT_FILE" | head -1)"
[ -n "$VER" ] || die "$SCRIPT_FILE 中找不到 readonly VERSION=\"...\""
if ! is_semver "$VER"; then
    err_ann "脚本 VERSION='$VER' 不是语义化版本，拒绝建 Release —— 非语义化 tag 会让客户端丢弃该 Release 并回退到 raw 拉取"
    exit 1
fi
TAG="v$VER"
info "仓库 $REPO · 提交 ${SHA:0:7} · 脚本 VERSION=$VER → Release tag $TAG"

# ---------- 1. 安全阀：不得存在高于 VERSION 的 Release ----------
code="$(api GET "/repos/$REPO/releases?per_page=100" "$TMP/rel.json")"
if [ "$code" != "200" ]; then
    err_ann "读取 releases 失败（HTTP $code）：$(head -c 300 "$TMP/rel.json" 2>/dev/null)"
    exit 1
fi
AHEAD=""
while IFS=$'\t' read -r t draft pre; do
    [ -n "$t" ] || continue
    [ "$draft" = "true" ] && continue
    [ "$pre" = "true" ] && continue
    v="${t#v}"
    is_semver "$v" || continue
    if version_gt "$v" "$VER"; then AHEAD="$v"; fi
done < <(jq -r '.[] | [.tag_name, (.draft|tostring), (.prerelease|tostring)] | @tsv' "$TMP/rel.json" 2>/dev/null)

if [ -n "$AHEAD" ]; then
    err_ann "已存在高于脚本 VERSION=$VER 的 Release（v$AHEAD）。客户端会被提示升级到 master 上并不存在的版本，更新后版本号追不上 ⇒ 死循环。请先删除/修正该 Release，或把脚本 VERSION 抬到 ≥ v$AHEAD"
    exit 1
fi
info "现有 Release 无高于 $VER 的版本（安全阀通过）"

# ---------- 2. 已存在则幂等跳过 ----------
code="$(api GET "/repos/$REPO/releases/tags/$TAG" "$TMP/one.json")"
if [ "$code" = "200" ]; then
    ok "Release $TAG 已存在（幂等，不重建）"
    CREATED=0
elif [ "$code" = "404" ]; then
    BODY="本仓发布快照 \`$TAG\`（脚本 \`readonly VERSION=$VER\`）。

- 安装：\`wget -O vless-server.sh https://raw.githubusercontent.com/$REPO/master/vless-server.sh\`
- 提交：\`$SHA\`
- 改动记录：见 [FIXES.md](https://github.com/$REPO/blob/master/FIXES.md)

> 客户端版本检查优先读本 Release 的 tag 名（\`/releases/latest\`），因此每次发版必须让
> Release 与脚本 \`VERSION\` 一致；本作业在 CI 中幂等自动维护。"
    payload="$(jq -n --arg tag "$TAG" --arg sha "$SHA" --arg body "$BODY" \
        '{tag_name:$tag, target_commitish:$sha, name:$tag, body:$body, draft:false, prerelease:false}')" \
        || die "构造 Release payload 失败（jq）"
    code="$(api POST "/repos/$REPO/releases" "$TMP/create.json" "$payload")"
    case "$code" in
        201) ok "已创建 Release $TAG（指向 ${SHA:0:7}）"; CREATED=1 ;;
        422)
            # 并发/重跑导致已存在：再确认一次
            code2="$(api GET "/repos/$REPO/releases/tags/$TAG" "$TMP/one.json")"
            if [ "$code2" = "200" ]; then
                ok "Release $TAG 已存在（422 后确认，幂等）"; CREATED=0
            else
                err_ann "创建 Release 被拒（HTTP 422，且复查 HTTP $code2）：$(head -c 300 "$TMP/create.json" 2>/dev/null)"
                exit 1
            fi
            ;;
        *)
            err_ann "创建 Release 失败（HTTP $code）：$(head -c 300 "$TMP/create.json" 2>/dev/null)"
            exit 1
            ;;
    esac
else
    err_ann "查询 Release $TAG 失败（HTTP $code）：$(head -c 300 "$TMP/one.json" 2>/dev/null)"
    exit 1
fi

# ---------- 3. 读回核验：/releases/latest 必须就是本 tag ----------
LATEST=""
for i in 1 2 3 4 5; do
    code="$(api GET "/repos/$REPO/releases/latest" "$TMP/latest.json")"
    if [ "$code" = "200" ]; then
        LATEST="$(jq -r '.tag_name // empty' "$TMP/latest.json" 2>/dev/null)"
        [ "$LATEST" = "$TAG" ] && break
    fi
    [ "$i" -lt 5 ] && sleep 2
done

if [ "$LATEST" != "$TAG" ]; then
    err_ann "读回核验失败：/releases/latest 返回 '${LATEST:-<空>}'，期望 '$TAG'。客户端会读到错误版本号"
    exit 1
fi
ok "读回核验通过：/releases/latest → $TAG（created=$CREATED）"
printf 'RELEASE_TAG=%s\nRELEASE_CREATED=%s\n' "$TAG" "$CREATED"
