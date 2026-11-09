#!/bin/bash
# h9 回归：在 user+mount+network+PID namespace 中执行真实
# setup_subscription_interactive -> manage_subscription(disable) -> do_uninstall 函数链。
# HTTP 读回使用隔离 loopback listener；nginx/systemctl 以严格 spy 验证脚本服务命令契约。
# 本测试证明脚本控制流与共享资产保持，不冒充真实 Nginx/systemd E2E。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/vless-server.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/vless-webroot-ownership.XXXXXX")"
HTTP_PID=""
cleanup() {
    if [[ -n "$HTTP_PID" ]]; then
        kill "$HTTP_PID" 2>/dev/null || true
        wait "$HTTP_PID" 2>/dev/null || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
for dep in unshare mount python3 curl sha256sum awk; do
    command -v "$dep" >/dev/null 2>&1 || fail "缺少隔离测试依赖: $dep"
done

# 依赖存在 ≠ 有权使用：容器化 runner（Gitea self-hosted runner 的 docker 容器、
# 未加 --privileged / 无 CAP_SYS_ADMIN 的 CI）里 unshare 会以
#   unshare: unshare failed: Operation not permitted
# 失败。那是**环境能力缺失**，不是被测代码的缺陷，不能让整个作业染红
# （private canonical repository run 245 job 901 即因此失败，其余 13 个套件全过）。
# 所以先探一次能力；不可用就显式 skip 并给可操作的说明，退出码 0。
if ! unshare --user --map-root-user --mount --pid --fork true 2>/dev/null; then
    echo "SKIP: 当前环境不允许 unshare(CLONE_NEWUSER) —— 跳过 Web root 所有权隔离回归"
    echo "      （这是 runner 能力限制，不是代码缺陷。需要覆盖请在本机或 --privileged 容器中运行）"
    exit 0
fi

# 不抽取或改写被测函数：inside namespace 直接 source 完整正式脚本。
grep -q '^if \[\[ "${VLESS_SOURCE_ONLY:-0}" == "1" \]\]; then$' "$SCRIPT" ||
    fail "正式 source-only 测试入口缺失"

mkdir -p "$WORK/root/etc/nginx/sites-available" \
         "$WORK/root/etc/nginx/sites-enabled" \
         "$WORK/root/etc/nginx/conf.d" \
         "$WORK/root/etc/nginx/http.d" \
         "$WORK/root/etc/vless-reality" \
         "$WORK/root/etc/systemd/system/multi-user.target.wants" \
         "$WORK/root/var/html" \
         "$WORK/root/var/log" \
         "$WORK/root/run" \
         "$WORK/root/tmp" \
         "$WORK/root/home" \
         "$WORK/bin"
# Bind whole parents in the namespace; never create missing absolute targets on the host.
cp /etc/os-release "$WORK/root/etc/os-release"

printf '%s\n' 'third-party-marker: keep exactly' > "$WORK/root/var/html/index.html"
printf '%s\n' 'third-party-default-site-v1' > "$WORK/root/etc/nginx/sites-available/default"
ln -s ../sites-available/default "$WORK/root/etc/nginx/sites-enabled/default"
printf '%s\n' '[Unit]' 'Description=Third-party Nginx' > "$WORK/root/etc/systemd/system/nginx.service"
ln -s ../nginx.service "$WORK/root/etc/systemd/system/multi-user.target.wants/nginx.service"
printf '%s\n' '127.0.0.1 localhost' > "$WORK/root/etc/hosts"
printf '%s\n' '{"version":"4.0.0","xray":{},"singbox":{},"meta":{}}' > "$WORK/root/etc/vless-reality/db.json"
printf '%s\n' '11111111-2222-3333-4444-555555555555' > "$WORK/root/etc/vless-reality/sub_uuid"
printf '%s\n' 'third-party-vless-site' > "$WORK/root/etc/nginx/conf.d/vless-third-party.conf"

cat > "$WORK/bin/nginx" <<'SH'
#!/bin/bash
set -eu
printf 'nginx %s\n' "$*" >> "$SPY_LOG"
[[ "$#" -eq 1 && "$1" == "-t" ]] || { printf 'forbidden nginx command: %s\n' "$*" >> "$SPY_FAIL"; exit 97; }
exit 0
SH
cat > "$WORK/bin/systemctl" <<'SH'
#!/bin/bash
set -eu
printf 'systemctl %s\n' "$*" >> "$SPY_LOG"
case "${1:-} ${2:-}" in
    'is-active --quiet') [[ "${3:-}" == nginx ]] || exit 1; exit 0 ;;
    'is-active nginx') exit 0 ;;
    'enable nginx'|'reload nginx') exit 0 ;;
    'daemon-reload ') exit 0 ;;
    'stop vless-*'|'disable vless-*') exit 0 ;; # project wildcard only
    *) printf 'forbidden systemctl command: %s\n' "$*" >> "$SPY_FAIL"; exit 98 ;;
esac
SH
cat > "$WORK/bin/ss" <<'SH'
#!/bin/bash
exit 0
SH
cat > "$WORK/bin/netstat" <<'SH'
#!/bin/bash
exit 0
SH
chmod +x "$WORK/bin/nginx" "$WORK/bin/systemctl" "$WORK/bin/ss" "$WORK/bin/netstat"
: > "$WORK/spy.log"
: > "$WORK/spy.fail"

# HTTP listener is a real socket in the isolated network namespace. It serves the exact shared Web root.
cat > "$WORK/http-server.py" <<'PY'
import http.server, os, socketserver, sys
os.chdir('/var/www/html')
class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass
with socketserver.TCPServer(('0.0.0.0', 18080), Quiet) as server:
    print('ready', flush=True)
    server.serve_forever()
PY

cat > "$WORK/inside.sh" <<'SH'
#!/bin/bash
set -euo pipefail
WORK="$1"
SCRIPT="$2"
exec {WORK_FD}<"$WORK"
WORK_ROOT="/proc/self/fd/$WORK_FD"
mount --make-rprivate /
for path in etc var/log run tmp home; do
    mount --bind "$WORK_ROOT/root/$path" "/$path"
done
mkdir -p /var/www/html
mount --bind "$WORK_ROOT/root/var/html" /var/www/html
mount -t proc proc /proc
export HOME=/home PATH="$WORK_ROOT/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
hash -r
export SPY_LOG="$WORK_ROOT/spy.log" SPY_FAIL="$WORK_ROOT/spy.fail"
unset DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy
export VLESS_SOURCE_ONLY=1
# shellcheck disable=SC1090
source "$SCRIPT"
WORK="$WORK_ROOT"

_log() { :; }
_info() { :; }
_ok() { :; }
_warn() { :; }
_err() { printf 'ERR: %s\n' "$*" >&2; }
_header() { return 0; }
_line() { return 0; }
_item() { return 0; }
_pause() { return 0; }
read() {
    local target="${!#}"
    if builtin read "$@"; then return 0; fi
    [[ "$target" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] && printf -v "$target" '%s' ''
    return 0
}
check_cmd() { command -v "$1" >/dev/null 2>&1; }
check_installed() { [[ -d "$CFG" && ( -f "$CFG/config.json" || -f "$CFG/db.json" ) ]]; }
install_nginx() { return 99; }
gen_uuid() { printf '%s\n' 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'; }
get_sub_uuid() { cat "$CFG/sub_uuid"; }
is_internal_port_occupied() { return 1; }
get_ipv4() { printf '%s\n' '127.0.0.1'; }
generate_sub_files() {
    local sub_uuid sub_dir
    sub_uuid=$(get_sub_uuid)
    sub_dir="$CFG/subscription/$sub_uuid"
    mkdir -p "$sub_dir"
    printf '%s\n' 'isolated-v2ray' > "$sub_dir/base64"
    printf '%s\n' 'proxies: []' > "$sub_dir/clash.yaml"
    printf '%s\n' '[Proxy]' > "$sub_dir/surge.conf"
}
show_sub_links() { [[ -f "$CFG/sub.info" ]]; }
manage_external_nodes() { return 99; }
stop_services() { :; }
warp_status() { printf '%s\n' not_configured; }
force_cleanup() { :; }
get_installed_protocols() { :; }
find() {
    # do_uninstall only: preserve command flow while avoiding recursive host-visible traversal.
    [[ " $* " == *" $CFG "* ]] && return 0
    command find "$@"
}

sha() { sha256sum "$1" | cut -d' ' -f1; }
http_sha() {
    local headers="$WORK/http.headers" body="$WORK/http.body" code
    code=$(curl --noproxy '*' -fsS --max-time 3 -D "$headers" -o "$body" -w '%{http_code}' http://127.0.0.1:18080/index.html)
    [[ "$code" == 200 ]] || return 1
    sha "$body"
}
snapshot() {
    local stage="$1"
    [[ -s "$WEBROOT_INDEX" ]] || { echo "FAIL: $stage marker missing" >&2; exit 1; }
    [[ "$(sha "$WEBROOT_INDEX")" == "$MARKER_SHA" ]] || { echo "FAIL: $stage marker hash changed" >&2; exit 1; }
    [[ "$(http_sha)" == "$MARKER_SHA" ]] || { echo "FAIL: $stage HTTP 200 body hash changed" >&2; exit 1; }
    [[ "$(readlink /etc/nginx/sites-enabled/default)" == "$DEFAULT_LINK" ]] || { echo "FAIL: $stage default link changed" >&2; exit 1; }
    [[ "$(sha /etc/nginx/sites-available/default)" == "$DEFAULT_SHA" ]] || { echo "FAIL: $stage default target changed" >&2; exit 1; }
    [[ "$(stat -Lc '%d:%i:%s:%u:%g:%a' /etc/nginx/sites-available/default)" == "$DEFAULT_ID" ]] || { echo "FAIL: $stage default metadata changed" >&2; exit 1; }
    [[ "$(sha /etc/systemd/system/nginx.service)" == "$UNIT_SHA" ]] || { echo "FAIL: $stage nginx unit changed" >&2; exit 1; }
    [[ "$(stat -Lc '%d:%i:%s:%u:%g:%a' /etc/systemd/system/nginx.service)" == "$UNIT_ID" ]] || { echo "FAIL: $stage nginx unit metadata changed" >&2; exit 1; }
    [[ "$(readlink /etc/systemd/system/multi-user.target.wants/nginx.service)" == "$UNIT_LINK" ]] || { echo "FAIL: $stage nginx enable link changed" >&2; exit 1; }
    [[ ! -e "$WEBROOT_PLACEHOLDER_META" ]] || { echo "FAIL: $stage third-party marker claimed" >&2; exit 1; }
    [[ ! -s "$SPY_FAIL" ]] || { echo "FAIL: $stage forbidden service command" >&2; cat "$SPY_FAIL" >&2; exit 1; }
    echo "  OK   $stage: marker hash/HTTP200/default site/Nginx unit 保持"
}

python3 "$WORK/http-server.py" > "$WORK/http.ready" 2> "$WORK/http.err" &
HTTP_PID=$!
export HTTP_PID
for _ in $(seq 1 50); do
    [[ -s "$WORK/http.ready" ]] && break
    kill -0 "$HTTP_PID" 2>/dev/null || { cat "$WORK/http.err" >&2; exit 1; }
    sleep 0.05
done
[[ -s "$WORK/http.ready" ]] || { echo 'FAIL: HTTP listener not ready' >&2; exit 1; }
# Fresh network namespaces start with loopback down; bring up only lo, never an external interface.
ip link set lo up

MARKER_SHA=$(sha "$WEBROOT_INDEX")
DEFAULT_LINK=$(readlink /etc/nginx/sites-enabled/default)
DEFAULT_SHA=$(sha /etc/nginx/sites-available/default)
DEFAULT_ID=$(stat -Lc '%d:%i:%s:%u:%g:%a' /etc/nginx/sites-available/default)
UNIT_SHA=$(sha /etc/systemd/system/nginx.service)
UNIT_ID=$(stat -Lc '%d:%i:%s:%u:%g:%a' /etc/systemd/system/nginx.service)
UNIT_LINK=$(readlink /etc/systemd/system/multi-user.target.wants/nginx.service)
snapshot before

# Real enable function: keep existing UUID, explicit opt-in, default port, empty domain, HTTP.
printf '%s\n' n y 18443 '' n | setup_subscription_interactive
[[ -f "$CFG/sub.info" ]] || { echo 'FAIL: enable did not create sub.info' >&2; exit 1; }
[[ -f /etc/nginx/http.d/vless-sub.conf ]] || { echo 'FAIL: enable did not create vless-sub.conf' >&2; exit 1; }
[[ -s "$CFG/subscription/11111111-2222-3333-4444-555555555555/base64" ]] || { echo 'FAIL: enable did not create subscription content' >&2; exit 1; }
snapshot enable

# Real manage function: option 5, then option 0 once disabled; display-only pause is stubbed.
# A final blank line absorbs the loop body's bare `echo`, whose status is the function status on return.
printf '%s\n' 5 0 '' | manage_subscription || true
[[ ! -e "$CFG/sub.info" && ! -e "$CFG/subscription" ]] || { echo 'FAIL: disable did not remove project subscription state' >&2; exit 1; }
[[ ! -e /etc/nginx/http.d/vless-sub.conf ]] || { echo 'FAIL: disable did not remove project config' >&2; exit 1; }
snapshot disable

# Leave one project-pattern config so real uninstall exercises nginx_cleaned + safe reload.
printf '%s\n' 'project-owned-residual' > /etc/nginx/conf.d/vless-residual.conf
printf '%s\n' y | do_uninstall
[[ ! -e /etc/nginx/conf.d/vless-residual.conf ]] || { echo 'FAIL: uninstall did not remove project residual' >&2; exit 1; }
snapshot uninstall

grep -qx 'systemctl enable nginx' "$SPY_LOG" || { echo 'FAIL: enable did not request nginx enable' >&2; exit 1; }
reloads=$(grep -c '^systemctl reload nginx$' "$SPY_LOG" || true)
[[ "$reloads" -ge 3 ]] || { echo "FAIL: expected reload across lifecycle, got $reloads" >&2; exit 1; }
if grep -Eq '^systemctl (stop|disable|restart|mask|kill) nginx$' "$SPY_LOG"; then
    echo 'FAIL: lifecycle attempted destructive shared nginx action' >&2
    exit 1
fi
printf 'PASS: 真实函数级 enable→disable→do_uninstall 生命周期保持（隔离 HTTP + 严格 service spy）\n'
kill "$HTTP_PID"
wait "$HTTP_PID" || true
SH
chmod +x "$WORK/inside.sh"

# Namespace has no external network; host /var/www is absent, so it is created only inside the
# private mount namespace before the isolated Web root is bound. All mutation targets map to WORK.
unshare --user --map-root-user --mount --net --pid --fork --kill-child \
    "$WORK/inside.sh" "$WORK" "$SCRIPT"
