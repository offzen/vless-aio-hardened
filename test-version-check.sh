#!/bin/bash
# 单元测试：h12 滚动 master 的 SHA-256 更新判定与版本防降级。
#
# h12 不再从 Release/tag 取版本；菜单提示比较远端/本地脚本哈希，同时用脚本内
# readonly VERSION 做方向闸门：远端更高或同版本不同字节可更新，远端更旧拒绝。
# 全离线（下载与本地脚本哈希均用 stub），可在无外网 runner 上运行。
set -uo pipefail

CFG="/tmp/vless-version-check"
rm -rf "$CFG"
mkdir -p "$CFG"

# 从 vless-server.sh 抽取真实函数体。使用字符串前缀匹配，兼容 gawk/mawk。
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

for fn in _script_sha256 _is_sha256 _is_semver_version _extract_script_version \
          _version_gt _get_latest_script_hash _has_script_update \
          _get_script_update_info; do
  extract_fn "$fn"
done

VERSION="3.4.10-h12"
RELEASE_CHANNEL="master"
VERSION_CACHE_DIR="$CFG/cache"
SCRIPT_HASH_CACHE_FILE="$VERSION_CACHE_DIR/.script_hash"
SCRIPT_VERSION_CACHE_FILE="$VERSION_CACHE_DIR/.script_version"
mkdir -p "$VERSION_CACHE_DIR"

STUB_CACHE_FRESH=1
STUB_CURRENT_HASH="$(printf '1%.0s' {1..64})"
STUB_REMOTE_VER="3.4.10-h13"
STUB_REMOTE_BODY="remote-build-a"
FETCH_SHOULD_FAIL=0

_init_version_cache() { mkdir -p "$VERSION_CACHE_DIR"; }
_is_cache_fresh() { [[ "$STUB_CACHE_FRESH" == "1" && -f "$1" ]]; }
_current_script_sha256() { printf '%s\n' "$STUB_CURRENT_HASH"; }
_fetch_script_tmp() {
  [[ "$FETCH_SHOULD_FAIL" == "0" ]] || return 1
  local f
  f=$(mktemp "$CFG/remote.XXXXXX") || return 1
  printf '#!/bin/bash\nreadonly VERSION="%s"\n# %s\n' "$STUB_REMOTE_VER" "$STUB_REMOTE_BODY" > "$f"
  printf '%s\n' "$f"
}

fail=0
check() { # $1=描述 $2=实际 $3=期望
  if [[ "$2" == "$3" ]]; then
    echo "  OK   $1"
  else
    echo "  FAIL $1: 实际='$2' 期望='$3'"
    fail=1
  fi
}

is_update() { _has_script_update && echo yes || echo no; }
update_info() { _get_script_update_info 2>/dev/null || true; }

echo "########## 1. 语义化版本与方向比较 ##########"
for v in "3.4.10-h12" "3.4.10" "10.0.0-h1"; do
  check "接受 '$v'" "$(_is_semver_version "$v" && echo yes || echo no)" "yes"
done
for v in "dev" "latest" "v3.4.10-h12" "3.4.10-h" ""; do
  check "拒绝 '$v'" "$(_is_semver_version "$v" && echo yes || echo no)" "no"
done
check "h13 > h12" "$(_version_gt "3.4.10-h13" "3.4.10-h12" && echo gt || echo le)" "gt"
check "h11 不大于 h12" "$(_version_gt "3.4.10-h11" "3.4.10-h12" && echo gt || echo le)" "le"
check "同版本不大于自身" "$(_version_gt "3.4.10-h12" "3.4.10-h12" && echo gt || echo le)" "le"

echo ""
echo "########## 2. 远端制品哈希与缓存 ##########"
rm -f "$SCRIPT_HASH_CACHE_FILE" "$SCRIPT_VERSION_CACHE_FILE"
STUB_REMOTE_VER="3.4.10-h13"
STUB_REMOTE_BODY="remote-build-a"
FETCH_SHOULD_FAIL=0
STUB_CACHE_FRESH=1
remote_hash=$(_get_latest_script_hash "false" "true")
check "下载结果为 SHA-256" "$(_is_sha256 "$remote_hash" && echo yes || echo no)" "yes"
check "哈希写入缓存" "$(cat "$SCRIPT_HASH_CACHE_FILE")" "$remote_hash"
check "语义化 VERSION 写入缓存" "$(cat "$SCRIPT_VERSION_CACHE_FILE")" "3.4.10-h13"

cached_hash="$(printf 'a%.0s' {1..64})"
printf '%s\n' "$cached_hash" > "$SCRIPT_HASH_CACHE_FILE"
FETCH_SHOULD_FAIL=1
check "新鲜合法缓存不访问下载路径" "$(_get_latest_script_hash "true" "false")" "$cached_hash"

printf 'not-a-hash\n' > "$SCRIPT_HASH_CACHE_FILE"
FETCH_SHOULD_FAIL=0
STUB_REMOTE_VER="dev"
STUB_REMOTE_BODY="remote-build-b"
rm -f "$SCRIPT_VERSION_CACHE_FILE"
remote_hash=$(_get_latest_script_hash "true" "false")
check "脏哈希缓存被替换" "$(_is_sha256 "$remote_hash" && echo yes || echo no)" "yes"
check "非语义化远端 VERSION 不写缓存" "$([[ -f "$SCRIPT_VERSION_CACHE_FILE" ]] && echo exists || echo absent)" "absent"

echo ""
echo "########## 3. 哈希差异 + VERSION 防降级 ##########"
STUB_CURRENT_HASH="$(printf '1%.0s' {1..64})"
remote_hash="$(printf '2%.0s' {1..64})"
printf '%s\n' "$STUB_CURRENT_HASH" > "$SCRIPT_HASH_CACHE_FILE"
printf '3.4.10-h13\n' > "$SCRIPT_VERSION_CACHE_FILE"
check "相同字节不提示更新" "$(is_update)" "no"

printf '%s\n' "$remote_hash" > "$SCRIPT_HASH_CACHE_FILE"
printf '3.4.10-h13\n' > "$SCRIPT_VERSION_CACHE_FILE"
check "远端高版本且字节不同可更新" "$(is_update)" "yes"
check "更新提示返回滚动通道" "$(update_info)" "master"

printf '3.4.10-h12\n' > "$SCRIPT_VERSION_CACHE_FILE"
check "同版本滚动制品字节变化可更新" "$(is_update)" "yes"

printf '3.4.10-h11\n' > "$SCRIPT_VERSION_CACHE_FILE"
check "远端较旧即使字节不同也拒绝" "$(is_update)" "no"
check "拒绝降级时不显示更新信息" "$(update_info)" ""

printf 'dev\n' > "$SCRIPT_VERSION_CACHE_FILE"
check "非法远端 VERSION 不参与更新" "$(is_update)" "no"

rm -f "$SCRIPT_HASH_CACHE_FILE"
check "缺少远端哈希缓存时不提示" "$(is_update)" "no"

echo ""
if [[ $fail -eq 0 ]]; then
  echo "PASS: h12 SHA 更新判定正确（高版本/同版本可更新，低版本拒绝）"
else
  echo "FAIL: 有断言未通过"
  exit 1
fi
