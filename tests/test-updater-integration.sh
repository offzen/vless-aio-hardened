#!/usr/bin/env bash
# Offline integration test for the real do_update/main_menu updater paths.
# Each case sources the product from mktemp and replaces only external boundaries.
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PRODUCT="${1:-$ROOT/vless-server.sh}"
[[ -f "$PRODUCT" ]] || { echo "FAIL: missing product: $PRODUCT" >&2; exit 2; }
for dep in awk grep sed sha256sum; do
  command -v "$dep" >/dev/null 2>&1 || { echo "FAIL: missing dependency: $dep" >&2; exit 2; }
done

TMP=$(mktemp -d "${TMPDIR:-/tmp}/aio-updater.XXXXXX") || exit 2
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT INT TERM

PRODUCT_SHA=$(sha256sum "$PRODUCT" | awk '{print $1}')
LOCAL_VERSION=$(sed -n 's/^readonly VERSION="\([^"]*\)"/\1/p' "$PRODUCT" | head -n1)
[[ "$LOCAL_VERSION" =~ ^[0-9]+(\.[0-9]+)*(-h[0-9]+)?$ ]] || {
  echo "FAIL: candidate VERSION is not legacy-compatible semantic form: $LOCAL_VERSION" >&2
  exit 1
}

pass=0
fail=0
check() {
  local name="$1"; shift
  if "$@"; then
    pass=$((pass + 1)); printf '  OK   %s\n' "$name"
  else
    fail=$((fail + 1)); printf '  FAIL %s\n' "$name" >&2
  fi
}
check_eq() { [[ "$1" == "$2" ]]; }
not_contains() { ! grep -Fq -- "$2" "$1"; }

make_remote() {
  local path="$1" version="$2" marker="$3"
  cat >"$path" <<EOF
#!/usr/bin/env bash
readonly VERSION="$version"
# updater fixture: $marker
EOF
  chmod +x "$path"
}

make_source_copy() {
  local dir="$1" target="$2"
  sed -e 's@^readonly VERSION_CACHE_DIR=.*@readonly VERSION_CACHE_DIR="'"$dir"'/cache"@' \
      -e 's@^readonly CFG="/etc/vless-reality"@readonly CFG="'"$dir"'/cfg"@' \
      "$PRODUCT" >"$target"
  bash -n "$target"
}

make_runner() {
  local dir="$1" runner="$2" source_copy="$3" remote="$4" apply_mode="$5" chmod_mode="$6"
  cat >"$runner" <<EOF
#!/usr/bin/env bash
set -uo pipefail
export VLESS_SOURCE_ONLY=1
# shellcheck disable=SC1090
source "$source_copy"
FETCH_COUNT_FILE="$dir/fetch.count"
REBUILD_LOG="$dir/rebuild.log"
: >"\$FETCH_COUNT_FILE"
: >"\$REBUILD_LOG"
_header() { :; }
_line() { :; }
_info() { :; }
_ok() { :; }
_warn() { :; }
_err() { printf '%s\n' "\$*" >&2; }
_init_version_cache() { mkdir -p "\$VERSION_CACHE_DIR"; }
_fetch_script_tmp() {
  printf x >>"\$FETCH_COUNT_FILE"
  local f
  f=\$(mktemp "$dir/download.XXXXXX") || return 1
  cp "$remote" "\$f" || return 1
  printf '%s\n' "\$f"
}
init_db() { printf 'init_db\n' >>"\$REBUILD_LOG"; [[ "$apply_mode" != fail && "$apply_mode" != fail-init ]]; }
rebuild_and_reload_xray() { printf 'xray\n' >>"\$REBUILD_LOG"; [[ "$apply_mode" != fail && "$apply_mode" != fail-xray ]]; }
rebuild_and_reload_singbox() { printf 'singbox\n' >>"\$REBUILD_LOG"; [[ "$apply_mode" != fail && "$apply_mode" != fail-singbox ]]; }
EOF
  if [[ "$chmod_mode" == fail ]]; then
    cat >>"$runner" <<'EOF'
chmod() { return 1; }
EOF
  fi
  cat >>"$runner" <<'EOF'
do_update
EOF
}

run_case() {
  local name="$1" kind="$2" remote_version="$3" answer="$4" expected_rc="$5"
  local expected_state="$6" apply_mode="$7" chmod_mode="$8" expected_apply="$9"
  local dir runner source_copy remote before rc
  dir="$TMP/$name"
  runner="$TMP/$name.runner.sh"
  source_copy="$dir/product-source.sh"
  remote="$dir/remote.sh"
  before="$dir/runner.before"
  mkdir -p "$dir/cache" "$dir/cfg"
  make_source_copy "$dir" "$source_copy"

  case "$kind" in
    valid) make_remote "$remote" "$remote_version" "$name" ;;
    missing-version) printf '#!/usr/bin/env bash\n# VERSION intentionally absent\n' >"$remote" ;;
    html) printf '<!doctype html><title>not a script</title>\n' >"$remote" ;;
    truncated) printf '#!/usr/bin/env bash\nreadonly VERSION="%s"\nif then\n' "$remote_version" >"$remote" ;;
    same-bytes) : >"$remote" ;;
    *) echo "FAIL: unknown fixture kind: $kind" >&2; return 2 ;;
  esac
  chmod +x "$remote"
  make_runner "$dir" "$runner" "$source_copy" "$remote" "$apply_mode" "$chmod_mode"
  if [[ "$kind" == same-bytes ]]; then
    cp "$runner" "$remote"
  fi
  cp "$runner" "$before"

  bash "$runner" <<<"$answer" >"$dir/output.log" 2>&1
  rc=$?
  check "$name returns $expected_rc" check_eq "$rc" "$expected_rc"
  case "$expected_state" in
    replaced)
      check "$name installs exact downloaded bytes" cmp -s "$runner" "$remote"
      check "$name backup is exact pre-update caller" cmp -s "$runner.bak" "$before"
      ;;
    preserved)
      check "$name preserves exact caller bytes" cmp -s "$runner" "$before"
      check "$name leaves no stale backup" test ! -e "$runner.bak"
      ;;
    *) echo "FAIL: unknown expected state: $expected_state" >&2; return 2 ;;
  esac
  check "$name fetches exactly once" check_eq "$(wc -c <"$dir/fetch.count" | tr -d ' ')" "1"
  check "$name leaves no download temp" bash -c 'shopt -s nullglob; files=("$1"/download.*); ((${#files[@]} == 0))' _ "$dir"
  check "$name auto-apply trace" check_eq "$(tr '\n' ',' <"$dir/rebuild.log")" "$expected_apply"
  if [[ "$apply_mode" == fail || "$apply_mode" == fail-* ]]; then
    check "$name reports explicit partial failure" grep -Fq '脚本已更新，但自动应用失败' "$dir/output.log"
    check "$name does not print completion success" not_contains "$dir/output.log" '✓ 更新完成'
  fi
}

printf '########## 1. real do_update success/no-op paths ##########\n'
run_case same-bytes same-bytes '' '' 0 preserved normal normal ''
run_case higher valid 3.4.10-h99 '' 0 replaced normal normal 'init_db,xray,singbox,'
run_case same-version-different valid 3.4.10-h13 '' 0 replaced normal normal 'init_db,xray,singbox,'

printf '\n########## 2. rejection and failure preservation ##########\n'
run_case lower valid 3.4.10-h12 '' 1 preserved normal normal ''
run_case missing-version missing-version '' '' 1 preserved normal normal ''
run_case html html '' '' 1 preserved normal normal ''
run_case syntax-broken truncated 3.4.10-h13 '' 1 preserved normal normal ''
run_case explicit-no valid 3.4.10-h13 n 0 preserved normal normal ''
run_case replacement-failure valid 3.4.10-h13 '' 1 preserved normal fail ''

printf '\n########## 3. auto-apply failure returns nonzero after replacement ##########\n'
run_case apply-failure valid 3.4.10-h13 '' 1 replaced fail normal 'init_db,xray,singbox,'
run_case apply-init-failure valid 3.4.10-h13 '' 1 replaced fail-init normal 'init_db,xray,singbox,'
run_case apply-xray-failure valid 3.4.10-h13 '' 1 replaced fail-xray normal 'init_db,xray,singbox,'
run_case apply-singbox-failure valid 3.4.10-h13 '' 1 replaced fail-singbox normal 'init_db,xray,singbox,'

printf '\n########## 4. startup prompt default is no ##########\n'
startup_dir="$TMP/startup-default-no"
startup_runner="$TMP/startup-default-no.runner.sh"
startup_source="$startup_dir/product-source.sh"
mkdir -p "$startup_dir/cache" "$startup_dir/cfg"
make_source_copy "$startup_dir" "$startup_source"
cat >"$startup_runner" <<EOF
#!/usr/bin/env bash
set -uo pipefail
export VLESS_SOURCE_ONLY=1
source "$startup_source"
HIT="$startup_dir/do-update.hit"
check_root() { :; }
init_log() { :; }
init_db() { :; }
db_migrate_to_multiuser() { :; }
_auto_update_system_script() { :; }
_init_version_cache() { :; }
_update_all_versions_async() { :; }
_check_script_update_async() { :; }
_get_latest_script_hash() { :; }
_has_script_update() { return 0; }
_get_script_update_info() { printf 'master\n'; }
get_installed_protocols() { printf 'vless-ws-notls\n'; }
_get_core_version_with_status() { printf 'fixture\n'; }
_version_check_started=1
show_status() { _INSTALLED_CACHE=vless-ws-notls; }
_header() { :; }
_line() { :; }
_item() { :; }
do_update() { : >"\$HIT"; return 77; }
main_menu
EOF
bash "$startup_runner" <<< $'\n0\n' >"$startup_dir/output.log" 2>&1
startup_rc=$?
check 'startup blank answer reaches menu and exits normally' check_eq "$startup_rc" 0
check 'startup blank answer does not call do_update' test ! -e "$startup_dir/do-update.hit"
check 'startup prompt remains opt-in [y/N]' grep -Fq '是否立即更新并尝试自动生效? [y/N]' "$PRODUCT"

printf '\n########## 5. H4/H5/H12 discovery handshake compatibility ##########\n'
version_line_count=$(grep -c '^readonly VERSION="[0-9][0-9.]*\(-h[0-9][0-9]*\)\?"$' "$PRODUCT")
check 'candidate exposes exactly one legacy-readable VERSION line' check_eq "$version_line_count" 1
for legacy in 3.4.10-h4 3.4.10-h5 3.4.10-h12; do
  legacy_rev=${legacy##*-h}
  current_rev=${LOCAL_VERSION##*-h}
  check "$legacy parses candidate semantic VERSION" bash -c '[[ "$1" =~ ^[0-9]+(\.[0-9]+)*(-h[0-9]+)?$ ]]' _ "$LOCAL_VERSION"
  check "$legacy sees candidate as newer" test "$current_rev" -gt "$legacy_rev"
done

check 'product bytes remain unchanged during the integration run' check_eq "$(sha256sum "$PRODUCT" | awk '{print $1}')" "$PRODUCT_SHA"

printf '\n'
if [[ "$fail" -eq 0 ]]; then
  printf 'PASS: updater integration (%d assertions)\n' "$pass"
else
  printf 'FAIL: updater integration (%d failed, %d passed)\n' "$fail" "$pass" >&2
  exit 1
fi
