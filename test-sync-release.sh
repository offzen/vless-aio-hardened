#!/bin/bash
# 单元测试：.github/scripts/sync-release.sh（GitHub Release 幂等同步）
#
# 用本地 mock GitHub API（test/mock-github-api.py）覆盖：创建 / 幂等 / 安全阀（已存在
# 更高版本 Release）/ 非语义化 tag 忽略 / draft 忽略 / 读回核验失败。
# 全离线，不碰真实 GitHub（不会建出任何真 Release）。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SYNC="$ROOT/.github/scripts/sync-release.sh"
MOCK="$ROOT/test/mock-github-api.py"
[ -f "$SYNC" ] || { echo "FAIL: 找不到 $SYNC" >&2; exit 1; }
[ -f "$MOCK" ] || { echo "FAIL: 找不到 $MOCK" >&2; exit 1; }
for dep in curl jq; do
    command -v "$dep" >/dev/null 2>&1 || { echo "FAIL: 缺少依赖 $dep（真实脚本也依赖它）" >&2; exit 1; }
done
# python3 只用于起 mock API，真实脚本不需要它；缺了不算失败，避免自托管 runner 误红
if ! command -v python3 >/dev/null 2>&1; then
    echo "WARN: 无 python3，跳过 mock API 测试（真实脚本不依赖 python3）"
    echo "PASS: 已跳过（无 python3）"
    exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vless-sync-release.XXXXXX")"
MOCK_PID=""
cleanup() {
    [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

python3 "$MOCK" 0 > "$WORK/port" 2> "$WORK/mock.err" &
MOCK_PID=$!
for _ in $(seq 1 100); do
    [ -s "$WORK/port" ] && break
    kill -0 "$MOCK_PID" 2>/dev/null || { echo "FAIL: mock API 启动失败" >&2; cat "$WORK/mock.err" >&2; exit 1; }
    sleep 0.1
done
PORT="$(head -1 "$WORK/port" 2>/dev/null)"
[ -n "$PORT" ] || { echo "FAIL: mock API 未输出端口" >&2; exit 1; }
BASE="http://127.0.0.1:$PORT"
SHA40="0123456789abcdef0123456789abcdef01234567"

pass=0; fail=0
check() { # desc actual expected
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1)); echo "  OK   $1"
    else
        fail=$((fail + 1)); echo "  FAIL $1（期望 $3，实得 $2）" >&2
    fi
}

reset_mock() { # json body
    curl -sS --max-time 10 -X POST -d "${1:-{\}}" "$BASE/__reset" >/dev/null || {
        echo "FAIL: 无法重置 mock" >&2; exit 1; }
}

mk_script() { # dir version
    mkdir -p "$1"
    printf '#!/bin/bash\nreadonly VERSION="%s"\n' "$2" > "$1/vless-server.sh"
}

# 跑 sync-release.sh；$1=工作目录，其余为额外 env 赋值
run_sync() {
    local d="$1"; shift
    ( cd "$d" && env GITHUB_REPOSITORY=offzen/vless-aio-hardened GITHUB_SHA="$SHA40" \
        GH_TOKEN=dummy-token GITHUB_API_URL="$BASE" \
        SYNC_RELEASE_ALLOW_API_OVERRIDE=1 "$@" \
        bash "$SYNC" >"$WORK/last.log" 2>&1 )
    echo $?
}

post_bodies() { # 取所有 POST /repos/.../releases 的载荷
    curl -sS --max-time 10 "$BASE/__requests" \
        | jq -c '[.[] | select(.method == "POST" and (.path | endswith("/releases")))] | length, (.[0].body // {})' 2>/dev/null
}

echo "########## 1. 环境与版本校验 ##########"

# 注意：本测试必须**显式控制 GITHUB_API_URL**。CI runner 自身就会导出
# GITHUB_API_URL（gitorca/gitpub 上是 Gitea 的 /api/v1），若继承它，
# 脚本会走「非 GitHub → 跳过」分支而不是报配置错误，断言就会失真。
d="$WORK/s_env"; mk_script "$d" 3.4.10-h5
( cd "$d" && env -u GITHUB_REPOSITORY -u GITHUB_SHA -u GH_TOKEN -u GITHUB_TOKEN \
    GITHUB_API_URL=https://api.github.com \
    bash "$SYNC" >/dev/null 2>&1 )
check "缺少 GITHUB_REPOSITORY → 2" "$?" "2"

reset_mock
d="$WORK/s_nonver"; mk_script "$d" dev
check "脚本 VERSION 非语义化(dev) → 1" "$(run_sync "$d")" "1"

d="$WORK/s_nover"; mkdir -p "$d"; printf '#!/bin/bash\necho x\n' > "$d/vless-server.sh"
check "脚本无 readonly VERSION → 1" "$(run_sync "$d")" "1"

# 私有侧（gitorca/gitpub 的 act_runner）会跑到本作业：必须**跳过并成功**，不能染红 CI
d="$WORK/s_skip"; mk_script "$d" 3.4.10-h5
( cd "$d" && env GITHUB_REPOSITORY=zaoz/vless-aio-hardened GITHUB_SHA="$SHA40" \
    GH_TOKEN=dummy-token GITHUB_API_URL="https://gitpub.example.invalid/api/v1" \
    bash "$SYNC" >"$WORK/skip.log" 2>&1 )
check "非 GitHub 侧（Gitea API）→ 跳过并成功(0)" "$?" "0"
check "跳过时输出 RELEASE_SYNC=skipped" "$(grep -c 'RELEASE_SYNC=skipped' "$WORK/skip.log")" "1"

echo ""
echo "########## 2. 创建路径 ##########"

reset_mock
d="$WORK/s_create"; mk_script "$d" 3.4.10-h5
check "无任何 Release → 创建成功(0)" "$(run_sync "$d")" "0"
check "创建了 1 个 Release" "$(post_bodies | head -1)" "1"
payload="$(post_bodies | tail -1)"
check "payload tag_name" "$(printf '%s' "$payload" | jq -r '.tag_name')" "v3.4.10-h5"
check "payload name" "$(printf '%s' "$payload" | jq -r '.name')" "v3.4.10-h5"
check "payload target_commitish" "$(printf '%s' "$payload" | jq -r '.target_commitish')" "$SHA40"
check "payload draft=false" "$(printf '%s' "$payload" | jq -r '.draft')" "false"
check "payload prerelease=false" "$(printf '%s' "$payload" | jq -r '.prerelease')" "false"
check "读回 /releases/latest 命中" \
    "$(grep -c "读回核验通过" "$WORK/last.log")" "1"

echo ""
echo "########## 3. 幂等（已存在不重建） ##########"

reset_mock '{"releases":[{"tag_name":"v3.4.10-h5","draft":false,"prerelease":false}]}'
check "Release 已存在 → 0（no-op）" "$(run_sync "$d")" "0"
check "已存在时不发 POST" "$(post_bodies | head -1)" "0"
check "输出「已存在」" "$(grep -c "已存在" "$WORK/last.log")" "1"

echo ""
echo "########## 4. 安全阀：已存在更高版本 Release ##########"

reset_mock '{"releases":[{"tag_name":"v3.4.10-h6","draft":false,"prerelease":false}]}'
check "存在 v3.4.10-h6 而脚本是 h5 → 拦下(1)" "$(run_sync "$d")" "1"
check "不建 Release（未发 POST）" "$(post_bodies | head -1)" "0"
check "报错文案点明死循环风险" "$(grep -c "死循环" "$WORK/last.log")" "1"

reset_mock '{"releases":[{"tag_name":"v3.4.10-h6","draft":true,"prerelease":false}]}'
check "更高版本只是 draft → 不算超前，创建(0)" "$(run_sync "$d")" "0"

reset_mock '{"releases":[{"tag_name":"v3.4.10-h6","draft":false,"prerelease":true}]}'
check "更高版本只是 prerelease → 不算超前，创建(0)" "$(run_sync "$d")" "0"

echo ""
echo "########## 5. 非语义化 tag 不得干扰 ##########"

reset_mock '{"releases":[{"tag_name":"dev","draft":false,"prerelease":false}]}'
check "已有滚动 tag dev 的 Release → 忽略并创建(0)" "$(run_sync "$d")" "0"
check "确实创建了 v3.4.10-h5" \
    "$(post_bodies | tail -1 | jq -r '.tag_name')" "v3.4.10-h5"

echo ""
echo "########## 6. 读回核验失败必须报错 ##########"

reset_mock '{"releases":[],"latest_override":"v9.9.9"}'
check "/releases/latest 与 tag 不一致 → 拦下(1)" "$(run_sync "$d")" "1"
check "报错文案点明读回核验" "$(grep -c "读回核验失败" "$WORK/last.log")" "1"

echo ""
if [ "$fail" -eq 0 ]; then
    echo "PASS: Release 同步作业行为正确（共 $pass 条断言）"
else
    echo "FAIL: $fail 条断言未通过（通过 $pass 条）" >&2
    exit 1
fi
