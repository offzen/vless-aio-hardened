#!/bin/bash
# 单元测试：脚本自升级的版本判定（_is_semver_version / _version_gt / _get_latest_script_version）。
#
# 背景（v3.4.10-h4 真实故障，2026-10-30）：本仓 GitHub tag 是滚动名 `dev`，且没有
# Release 对象，于是 `_get_latest_script_version` 回退到 `_get_latest_tag_version`
# 拿到 "dev"，再交给 `_version_gt` 做「逐段数字比较」。遇到非数字段时它退化为字符串
# 比较，"dev" > "3" 成立 ⇒ 恒判为「有新版本」，表现为：
#     最新版本: vdev → 发现新版本? [Y/n] → ✓ 更新成功! v3.4.10-h4 -> v3.4.10-h4
#     → 下次运行 vless 依旧提示更新（死循环）。
# 本测试锁定修复后的行为：非语义化版本号一律不参与比较、不被缓存，
# 版本号改为回退读 master 脚本内的 VERSION 常量。
#
# 全离线（网络函数用 stub 顶替），可在无外网的 runner 上跑。
set -e
CFG="/tmp/vless-version-check"; rm -rf "$CFG"; mkdir -p "$CFG"

# 从 vless-server.sh 抽取真实函数体（与 test-anytls-secure.sh 同法）。
# 抽取用 index() 前缀匹配而非动态正则，避免 gawk/mawk 对 \( 的转义差异。
extract_fn() { # $1=fn_name
  local fn="$1"
  awk -v fn="$fn" '
    !f && index($0, fn "()") == 1 { f = 1 }
    f { print }
    f && /^}/ { exit }
  ' vless-server.sh > "$CFG/$fn.sh"
  if [[ ! -s "$CFG/$fn.sh" ]] || ! grep -q "^$fn()" "$CFG/$fn.sh"; then
    echo "FAIL: 无法从 vless-server.sh 抽取函数 $fn（awk 抽取结果为空或不完整）" >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  source "$CFG/$fn.sh"
}

for fn in _is_semver_version _get_remote_script_version_from_raw \
          _get_latest_script_version _version_gt \
          _has_script_update _get_script_update_info; do
  extract_fn "$fn"
done

# ---- 测试夹具：脚本内被引用到的常量与依赖函数（全部 stub，离线） ----
VERSION="3.4.10-h4"
SCRIPT_REPO="offzen/vless-aio-hardened"
SCRIPT_RAW_URL="https://raw.githubusercontent.com/offzen/vless-aio-hardened/master/vless-server.sh"
SCRIPT_VERSION_CACHE_FILE="$CFG/.script_version"
VERSION_CACHE_DIR="$CFG"

_init_version_cache() { mkdir -p "$VERSION_CACHE_DIR" 2>/dev/null || true; }
_is_cache_fresh() { [[ "${STUB_CACHE_FRESH:-1}" == "1" ]] && [[ -f "$1" ]]; }

# 远端来源 stub（默认：无 release、tag 名为滚动名 dev、master 脚本 VERSION=3.4.10-h5）
_get_latest_version() { return 1; }
_get_latest_tag_version() { echo "dev"; }
_get_remote_script_version_from_raw() { echo "${STUB_RAW_VER:-3.4.10-h5}"; }

fail=0
check() { # $1=描述 $2=实际 $3=期望
  if [[ "$2" == "$3" ]]; then
    echo "  OK   $1"
  else
    echo "  FAIL $1: 实际='$2' 期望='$3'"
    fail=1
  fi
}

echo "########## 1. _is_semver_version：只认语义化版本 ##########"
for v in "3.4.10-h4" "3.4.10" "3.4.10-h5" "10.0.0-h12" "3.4.10-h0"; do
  check "接受 '$v'" "$(_is_semver_version "$v" && echo yes || echo no)" "yes"
done
for v in "dev" "dev3" "latest" "nightly" "v3.4.10" "3.4.10-h" "3.4.10-h4-extra" "" " " "3.4.x"; do
  check "拒绝 '$v'" "$(_is_semver_version "$v" && echo yes || echo no)" "no"
done

echo ""
echo "########## 2. _version_gt：数字段与 -h 修订号 ##########"
check "3.4.10-h5 > 3.4.10-h4"      "$(_version_gt "3.4.10-h5" "3.4.10-h4" && echo gt || echo le)" "gt"
check "3.4.10-h4 < 3.4.10-h5"      "$(_version_gt "3.4.10-h4" "3.4.10-h5" && echo gt || echo le)" "le"
check "3.4.10-h10 > 3.4.10-h9（数字比较而非字符串）" \
      "$(_version_gt "3.4.10-h10" "3.4.10-h9" && echo gt || echo le)" "gt"
check "3.4.11 > 3.4.10-h9（基础版本优先）" \
      "$(_version_gt "3.4.11" "3.4.10-h9" && echo gt || echo le)" "gt"
check "3.4.10-h1 > 3.4.10（无后缀最低）" \
      "$(_version_gt "3.4.10-h1" "3.4.10" && echo gt || echo le)" "gt"
check "同版本不比（3.4.10-h4 vs 3.4.10-h4）" \
      "$(_version_gt "3.4.10-h4" "3.4.10-h4" && echo gt || echo le)" "le"

echo ""
echo "########## 3. 回归：滚动 tag 名 dev 绝不能被判为更新版本 ##########"
check "'dev' vs '3.4.10-h4' 不更新" "$(_version_gt "dev" "3.4.10-h4" && echo gt || echo le)" "le"
check "'3.4.10-h4' vs 'dev' 不更新" "$(_version_gt "3.4.10-h4" "dev" && echo gt || echo le)" "le"
check "'dev3' vs 'dev' 不更新"      "$(_version_gt "dev3" "dev" && echo gt || echo le)" "le"
check "'latest' vs '3.4.10-h4' 不更新" "$(_version_gt "latest" "3.4.10-h4" && echo gt || echo le)" "le"

echo ""
echo "########## 4. _get_latest_script_version：脏缓存与 tag 回退 ##########"
# 4a. 旧版写进缓存的脏值 "dev" 必须被丢弃，改用远端真实版本
echo "dev" > "$SCRIPT_VERSION_CACHE_FILE"
STUB_CACHE_FRESH=1 check "缓存里的 'dev' 被丢弃，改用 master VERSION" \
  "$(_get_latest_script_version "true" "false")" "3.4.10-h5"
check "缓存已被纠正为 3.4.10-h5" "$(cat "$SCRIPT_VERSION_CACHE_FILE")" "3.4.10-h5"

# 4b. tag 名非语义化 → 必须回退读 master 脚本 VERSION（这正是 h4 故障点）
rm -f "$SCRIPT_VERSION_CACHE_FILE"
check "tag='dev' 时回退到 master VERSION" \
  "$(_get_latest_script_version "false" "true")" "3.4.10-h5"

# 4c. release 给出语义化版本时优先用 release（不必回退）
rm -f "$SCRIPT_VERSION_CACHE_FILE"
_get_latest_version() { echo "3.4.10-h6"; }
check "release 语义化版本优先" \
  "$(_get_latest_script_version "false" "true")" "3.4.10-h6"
_get_latest_version() { return 1; }

# 4d. 所有来源都拿不到语义化版本 → 返回非 0，且不得写入脏缓存
rm -f "$SCRIPT_VERSION_CACHE_FILE"
_get_latest_tag_version() { echo "dev"; }
_get_remote_script_version_from_raw() { return 1; }
check "全来源失败返回非 0" "$(_get_latest_script_version "false" "true" >/dev/null 2>&1 && echo ok || echo err)" "err"
check "失败时不写缓存" "$([[ -f "$SCRIPT_VERSION_CACHE_FILE" ]] && echo exists || echo absent)" "absent"

# 4e. 缓存有效时不再走网络
_get_latest_tag_version() { echo "dev"; }
_get_remote_script_version_from_raw() { echo "9.9.9-h9"; }
echo "3.4.10-h5" > "$SCRIPT_VERSION_CACHE_FILE"
STUB_CACHE_FRESH=1 check "新鲜缓存命中" \
  "$(_get_latest_script_version "true" "false")" "3.4.10-h5"

echo ""
echo "########## 5. 菜单/启动提示读缓存路径 ##########"
echo "dev" > "$SCRIPT_VERSION_CACHE_FILE"
check "缓存为 'dev' 时 _has_script_update 为假" \
  "$(_has_script_update && echo yes || echo no)" "no"
check "缓存为 'dev' 时 _get_script_update_info 为空" \
  "$(_get_script_update_info)" ""
echo "3.4.10-h9" > "$SCRIPT_VERSION_CACHE_FILE"
check "缓存为 3.4.10-h9 时 _has_script_update 为真" \
  "$(_has_script_update && echo yes || echo no)" "yes"
check "缓存为 3.4.10-h9 时 _get_script_update_info 输出该版本" \
  "$(_get_script_update_info)" "3.4.10-h9"
echo "3.4.10-h4" > "$SCRIPT_VERSION_CACHE_FILE"
check "缓存与本地同版本时无更新提示" \
  "$(_has_script_update && echo yes || echo no)" "no"

echo ""
echo "########## 6. 真实网络冒烟（离线/失败仅告警，不阻断 CI） ##########"
real_ver=""
if command -v curl >/dev/null 2>&1; then
  real_ver=$(curl -sL --connect-timeout 5 --max-time 15 -r 0-4095 "$SCRIPT_RAW_URL" 2>/dev/null \
    | grep -m1 '^readonly VERSION=' | cut -d'"' -f2 || true)
fi
if _is_semver_version "$real_ver"; then
  echo "  OK   master 上的 VERSION 是语义化版本: $real_ver"
else
  echo "  WARN 无法从远端读取语义化 VERSION（离线或无网络），已跳过（不影响结论）"
fi

echo ""
if [[ $fail -eq 0 ]]; then
  echo "PASS: 版本判定正确（滚动 tag 名不参与比较，版本号回退读 master 脚本 VERSION）"
else
  echo "FAIL: 有断言未通过"
  exit 1
fi
