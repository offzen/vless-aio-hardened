#!/bin/bash
# H16 审计整改回归：配额生命周期、流量计数持久化、DB 锁、下载完整性、配置原子渲染、
# 到期日期校验、批量到期禁用、cron 路径、用户增删返回语义、nginx 回滚。
# 全部离线：外部边界（xray/curl/nginx/crontab/svc）都用桩替换；每个分区在独立子 shell 里
# 重新 source 产品脚本，互不污染。
set -uo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")/.." && pwd)
PRODUCT="${1:-$ROOT/vless-server.sh}"
[[ -f "$PRODUCT" ]] || { echo "FAIL: missing product: $PRODUCT" >&2; exit 2; }
for dep in jq awk grep sed sha256sum mktemp; do
    command -v "$dep" >/dev/null 2>&1 || { echo "FAIL: missing dependency: $dep" >&2; exit 2; }
done

TMP=$(mktemp -d "${TMPDIR:-/tmp}/aio-h16.XXXXXX")
TMP=$(cd -- "$TMP" && pwd -P) || exit 2
trap '[[ "$TMP" == /tmp/* || "$TMP" == "${TMPDIR:-/nonexistent}"/* ]] && rm -rf -- "$TMP"' EXIT

RESULTS="$TMP/results.log"
: >"$RESULTS"

# 每个分区调用 fresh_env 得到隔离的 CFG/日志目录并 source 产品
fresh_env() {
    local name="$1"
    SEC="$TMP/$name"
    mkdir -p "$SEC/cfg" "$SEC/log" "$SEC/bin"
    export VLESS_SOURCE_ONLY=1 VLESS_TEST_CFG="$SEC/cfg" VLESS_TEST_LOG_ROOT="$SEC/log"
    cp "$PRODUCT" "$SEC/product.sh"
    # shellcheck disable=SC1090
    source "$SEC/product.sh"
    [[ "$CFG" == "$SEC/cfg" ]] || { echo "FAIL isolation" >>"$RESULTS"; exit 2; }
    _ok() { :; }; _info() { :; }; _warn() { :; }; _log() { :; }
    _err() { printf '%s\n' "$*" >&2; }
    export PATH="$SEC/bin:$PATH"
    # 安全护栏：任何分区都不得碰宿主机真实 crontab；需要的分区自己覆盖成假实现
    crontab() { echo "crontab $*" >>"$TMP/crontab-guard.log"; return 1; }
}
check() { # check <desc> <command...>
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then echo "OK   $desc" >>"$RESULTS"; printf '  OK   %s\n' "$desc"
    else echo "FAIL $desc" >>"$RESULTS"; printf '  FAIL %s\n' "$desc" >&2; fi
}
eq() { [[ "$1" == "$2" ]]; }

write_db() { cat >"$DB_FILE"; chmod 600 "$DB_FILE"; }
# 假 xray：statsquery 从 $STATS_FILE 读，带 -reset 时原子清空；run -test 返回 $XRAY_TEST_RC
install_fake_xray() {
    cat >"$SEC/bin/xray" <<'EOF'
#!/bin/bash
echo "xray $*" >>"${XLOG:-/dev/null}"
if [[ "$1" == api && "$2" == statsquery ]]; then
    reset=0; for a in "$@"; do [[ "$a" == -reset ]] && reset=1; done
    if [[ -s "${STATS_FILE:-/nonexistent}" ]]; then cat "$STATS_FILE"; else echo '{"stat":[]}'; fi
    [[ $reset -eq 1 ]] && echo '{"stat":[]}' > "$STATS_FILE"
    exit 0
fi
if [[ "$1" == run && "$2" == -test ]]; then
    [[ "${XRAY_TEST_RC:-0}" == 0 ]] || { echo "bad config" >&2; exit "${XRAY_TEST_RC}"; }
    exit 0
fi
exit 0
EOF
    chmod +x "$SEC/bin/xray"
}
stats() { # stats <user@proto> <up> <down>
    printf '{"stat":[{"name":"user>>>%s>>>traffic>>>uplink","value":%s},{"name":"user>>>%s>>>traffic>>>downlink","value":%s}]}\n' "$1" "$2" "$1" "$3" >"$STATS_FILE"
}

# ═════════════════════════ F1 配额生命周期 ═════════════════════════
sec_quota() ( fresh_env quota
    write_db <<'J'
{"version":"4.0.0","xray":{"vless":{"port":443,"uuid":"aaaa","users":[
 {"name":"u1","uuid":"aaaa","quota":100,"used":0,"enabled":true},
 {"name":"u2","uuid":"bbbb","quota":0,"used":0,"enabled":true}]}},"singbox":{},"meta":{}}
J
    install_fake_xray
    STATS_FILE="$SEC/stats.json"; XLOG="$SEC/xray.log"; export STATS_FILE XLOG
    NOTIFY="$SEC/notify.log"; : >"$NOTIFY"
    _pgrep() { return 0; }
    svc() { [[ "$1" == status ]] && return 1; return 0; }   # 服务视为未运行：只改配置不重启
    generate_xray_config() { return 0; }
    check_daily_report() { :; }
    tg_get_config() { echo 80; }
    tg_send_over_quota() { echo "over:$1" >>"$NOTIFY"; }
    tg_send_quota_alert() { echo "alert:$1:$5" >>"$NOTIFY"; }
    field() { db_get_user_field xray vless "$1" "$2"; }

    stats u1@vless 150 50
    sync_all_user_traffic true
    check 'F1 first overage disables the user'            eq "$(field u1 enabled)" false
    check 'F1 first overage records used bytes'           eq "$(field u1 used)" 200
    check 'F1 first overage notifies exactly once'        eq "$(grep -c '^over:u1$' "$NOTIFY")" 1

    db_reset_user_traffic xray vless u1
    db_set_user_enabled xray vless u1 true
    check 'F1 reset+enable clears exceeded flag'          eq "$(db_get_user_alert_state xray vless u1 quota_exceeded_notified)" ""
    check 'F1 reset zeroes usage'                         eq "$(field u1 used)" 0

    stats u1@vless 150 50
    sync_all_user_traffic true
    check 'F1 second billing cycle disables again'        eq "$(field u1 enabled)" false
    check 'F1 second overage notifies again'              eq "$(grep -c '^over:u1$' "$NOTIFY")" 2

    # 手动重新启用但不重置：下一次有流量时仍必须再次禁用（不能因为旧标记而放行）
    db_set_user_enabled xray vless u1 true
    stats u1@vless 1 1
    sync_all_user_traffic true
    check 'F1 re-enabled over-quota user is disabled again' eq "$(field u1 enabled)" false

    # 调大配额清除告警状态；80% 告警可再次触发
    db_set_user_quota xray vless u1 1
    db_reset_user_traffic xray vless u1
    db_set_user_enabled xray vless u1 true
    db_set_user_alert_state xray vless u1 last_alert_percent 95
    db_set_user_quota xray vless u1 1
    check 'F1 quota change resets alert percent'          eq "$(db_get_user_alert_state xray vless u1 last_alert_percent)" 0
    check 'F1 unlimited user is never disabled'           eq "$(field u2 enabled)" true
)

# ═════════════════════════ F3 流量持久化 ═════════════════════════
sec_traffic() ( fresh_env traffic
    write_db <<'J'
{"version":"4.0.0","xray":{"vless":{"port":443,"uuid":"aaaa","users":[
 {"name":"u1","uuid":"aaaa","quota":0,"used":0,"enabled":true}]}},"singbox":{},"meta":{}}
J
    install_fake_xray
    STATS_FILE="$SEC/stats.json"; XLOG="$SEC/xray.log"; : >"$XLOG"; export STATS_FILE XLOG
    _pgrep() { return 0; }
    svc() { echo "svc $*" >>"$SEC/svc.log"; return 0; }
    generate_xray_config() { return 0; }
    check_daily_report() { :; }
    tg_get_config() { echo 80; }
    pending="$CFG/cache/traffic.pending"

    # 写库失败：增量保留在 pending 日志，下一轮重试且不重复计数
    real_update=$(declare -f db_update_user_traffic)
    db_update_user_traffic() { return 1; }
    stats u1@vless 700 300
    sync_all_user_traffic true
    check 'F3 counters were reset in Xray (read+reset is atomic)' grep -q -- '-reset' "$XLOG"
    check 'F3 failed DB write keeps the delta in the journal'    grep -q 'user>>>u1@vless>>>traffic>>>uplink 700' "$pending"
    check 'F3 failed DB write leaves DB untouched'               eq "$(db_get_user_field xray vless u1 used)" 0
    eval "$real_update"
    : >"$STATS_FILE"
    sync_all_user_traffic true
    check 'F3 retry persists the journaled delta'                eq "$(db_get_user_field xray vless u1 used)" 1000
    check 'F3 journal is empty after a successful sync'          test ! -s "$pending"
    sync_all_user_traffic true
    check 'F3 re-sync does not double count'                     eq "$(db_get_user_field xray vless u1 used)" 1000

    # 多轮未处理的日志按名求和
    printf 'user>>>u1@vless>>>traffic>>>uplink 5\nuser>>>u1@vless>>>traffic>>>downlink 5\nuser>>>u1@vless>>>traffic>>>uplink 10\n' >"$pending"
    : >"$STATS_FILE"
    sync_all_user_traffic true
    check 'F3 multiple journal rounds are summed'                eq "$(db_get_user_field xray vless u1 used)" 1020

    # 重启 Xray 之前先把内存计数落盘（重启会清零计数器）
    : >"$XLOG"; : >"$SEC/svc.log"
    svc() { echo "svc $*" >>"$SEC/svc.log"; echo "$(date +%s%N) svc $1" >>"$SEC/order.log"; return 0; }
    stats u1@vless 40 60
    rebuild_and_reload_xray silent
    check 'F3 restart path flushed counters before restarting'   grep -q 'user>>>u1@vless>>>traffic>>>uplink 40' "$pending"
    check 'F3 the service restart still happened after the flush' grep -q 'svc restart' "$SEC/svc.log"
)

# ═════════════════════════ F4 DB 锁 ═════════════════════════
sec_lock() ( fresh_env lock
    init_db
    ( f=0; for _ in $(seq 1 40); do _db_safe_write 0 "" '.meta.x=((.meta.x//0)+1)' || f=$((f+1)); done; exit "$f" ) & local p1=$!
    ( f=0; for _ in $(seq 1 40); do _db_apply '.meta.y=((.meta.y//0)+1)' || f=$((f+1)); done; exit "$f" ) & local p2=$!
    local r1=0 r2=0; wait "$p1" || r1=$?; wait "$p2" || r2=$?
    local got; got=$(jq -c '[.meta.x,.meta.y]' "$DB_FILE")
    [[ "$r1:$r2:$got" == "0:0:[40,40]" ]] || printf 'DEBUG sec_lock: r1=%s r2=%s got=%s db=%s\n' "$r1" "$r2" "$got" "$(cat "$DB_FILE")" >&2
    check 'F4 both concurrent writers exited cleanly'          eq "$r1:$r2" '0:0'
    check 'F4 _db_apply and _db_safe_write never lose updates' eq "$got" '[40,40]'

    # 无 pid 文件、目录已超过 10 秒：视为陈旧锁并回收
    mkdir "$DB_FILE.lock"; touch -d '30 seconds ago' "$DB_FILE.lock"
    _db_safe_write 0 "" '.meta.z=1'; rc=$?
    check 'F4 pid-less stale lock is reclaimed'                 eq "$rc" 0
    check 'F4 lock directory is released afterwards'            test ! -e "$DB_FILE.lock"

    # 持锁进程已死
    mkdir "$DB_FILE.lock"; echo 999999 >"$DB_FILE.lock/pid"
    _db_safe_write 0 "" '.meta.w=1'; rc=$?
    check 'F4 dead-owner lock is reclaimed'                     eq "$rc" 0

    # 活锁不能被抢
    mkdir "$DB_FILE.lock"; echo $$ >"$DB_FILE.lock/pid"
    _LOCK_DEPTH=()
    _lockdir_acquire "$DB_FILE.lock" 3; rc=$?
    check 'F4 live foreign lock is respected (acquire times out)' eq "$rc" 1
    rm -rf "$DB_FILE.lock"

    # 同进程可重入：内层 release 不能提前放锁
    _lockdir_acquire "$TMP/relock"; _lockdir_acquire "$TMP/relock"
    _lockdir_release "$TMP/relock"
    check 'F4 nested release keeps the outer lock'              test -d "$TMP/relock"
    _lockdir_release "$TMP/relock"
    check 'F4 outermost release removes the lock'               test ! -e "$TMP/relock"

    # 路由/链式代理等原先裸写 db.json 的路径现在也走锁：源码中不再有直接覆盖 DB_FILE 的 mv
    n=$(grep -cE 'mv .*"\$DB_FILE"$' "$PRODUCT" || true)
    check 'F4 only the locked primitives still mv onto DB_FILE'  test "$n" -le 3
)

# ═════════════════════════ F5 下载完整性 ═════════════════════════
sec_integrity() ( fresh_env integrity
    set +u   # 产品里的 _install_binary 与 set -u 不兼容（xarch/sarch 等占位变量可能未设置）
    check_cmd() { return 1; }
    PAYLOAD_SHA=$(printf 'payload\n' | sha256sum | awk '{print $1}')
    API_JSON=""; DGST_MODE=ok
    curl() {
        local out="" url="" a
        while [[ $# -gt 0 ]]; do
            case "$1" in -o) out="$2"; shift 2;; --connect-timeout|--max-time|--speed-limit|--speed-time|--retry) shift 2;; -*) shift;; *) url="$1"; shift;; esac
        done
        case "$url" in
            *.dgst)
                case "$DGST_MODE" in
                    fail) return 22;;
                    ok) printf 'MD5= x\nSHA2-256= %s\n' "$PAYLOAD_SHA" >"$out";;
                    nospace) printf 'SHA2-256=%s\n' "$PAYLOAD_SHA" >"$out";;
                    wrong) printf 'SHA2-256= %064d\n' 0 >"$out";;
                    empty) : >"$out";;
                esac;;
            https://api.github.com/*) [[ -n "$API_JSON" ]] || return 22; if [[ -n "$out" ]]; then printf '%s' "$API_JSON" >"$out"; else printf '%s' "$API_JSON"; fi;;
            *) printf 'payload\n' >"$out";;
        esac
    }
    run() { _install_binary "$@" >/dev/null 2>&1; }
    X=(xray XTLS/Xray-core 'https://github.com/XTLS/Xray-core/releases/download/v$version/x.zip' true stable true 1.2.3)
    S=(sing-box SagerNet/sing-box 'https://github.com/SagerNet/sing-box/releases/download/v$version/sb.tgz' true stable true 1.2.3)

    DGST_MODE=ok;      run "${X[@]}"; check 'F5 Xray: matching .dgst installs'                      eq $? 0
    DGST_MODE=nospace; run "${X[@]}"; check 'F5 Xray: .dgst without space after = is parsed'       eq $? 0
    DGST_MODE=wrong;   run "${X[@]}"; check 'F5 Xray: mismatching .dgst aborts'                    test $? -ne 0
    DGST_MODE=fail;    API_JSON=""; run "${X[@]}"; check 'F5 Xray: unreachable .dgst and no API digest aborts (fail closed)' test $? -ne 0
    DGST_MODE=empty;   API_JSON=""; run "${X[@]}"; check 'F5 Xray: empty .dgst and no API digest aborts' test $? -ne 0
    DGST_MODE=fail;    API_JSON="{\"assets\":[{\"name\":\"x.zip\",\"digest\":\"sha256:$PAYLOAD_SHA\"}]}"
    run "${X[@]}"; check 'F5 Xray: falls back to API digest when .dgst is unreachable'              eq $? 0
    DGST_MODE=fail;    API_JSON="{\"assets\":[{\"name\":\"x.zip\",\"digest\":\"sha256:$(printf '%064d' 1)\"}]}"
    run "${X[@]}"; check 'F5 Xray: API digest mismatch aborts'                                      test $? -ne 0
    DGST_MODE=fail;    API_JSON=""; VLESS_ALLOW_UNVERIFIED_DOWNLOAD=1 run "${X[@]}"
    check 'F5 explicit VLESS_ALLOW_UNVERIFIED_DOWNLOAD=1 is honoured'                               eq $? 0

    API_JSON="{\"assets\":[{\"name\":\"sb.tgz\",\"digest\":\"sha256:$PAYLOAD_SHA\"}]}"
    run "${S[@]}"; check 'F5 sing-box: matching API digest installs'                                eq $? 0
    API_JSON="{\"assets\":[{\"name\":\"sb.tgz\",\"digest\":\"sha256:$(printf '%064d' 2)\"}]}"
    run "${S[@]}"; check 'F5 sing-box: mismatching API digest aborts'                               test $? -ne 0
    API_JSON=""
    run "${S[@]}"; check 'F5 sing-box: no digest available warns and continues'                     eq $? 0
    VLESS_REQUIRE_VERIFIED_DOWNLOAD=1 run "${S[@]}"
    check 'F5 VLESS_REQUIRE_VERIFIED_DOWNLOAD=1 makes missing digest fatal'                         test $? -ne 0

    # 超时：下载不再允许无限挂起
    check 'F13 binary download has an overall time limit'  grep -q -- '--max-time 900 --speed-limit 1024 --speed-time 60' "$PRODUCT"
    check 'F13 script fetch fails on HTTP errors (-f)'     grep -q 'curl -fsSL --connect-timeout "$connect_timeout" --max-time "$max_time"' "$PRODUCT"
)

# ═════════════════════════ F8 到期日期 ═════════════════════════
sec_expiry() ( fresh_env expiry
    check 'F8 accepts a real date'               _valid_ymd 2030-02-28
    check 'F8 accepts a leap day'                _valid_ymd 2032-02-29
    _valid_ymd 2031-02-29 && echo "FAIL F8 accepted non-leap Feb 29" >>"$RESULTS" || echo "OK   F8 rejects non-leap Feb 29" >>"$RESULTS"
    for bad in 2026-02-30 2026-13-45 2026-00-10 2026-04-31 26-01-01 2026-1-1 abcd-ef-gh ''; do
        _valid_ymd "$bad" && echo "FAIL F8 accepted '$bad'" >>"$RESULTS" || echo "OK   F8 rejects '$bad'" >>"$RESULTS"
    done
    write_db <<'J'
{"version":"4.0.0","xray":{"vless":{"port":443,"uuid":"aaaa","users":[
 {"name":"legacybad","uuid":"aaaa","enabled":true,"expire_date":"2020-02-30"},
 {"name":"futurebad","uuid":"bbbb","enabled":true,"expire_date":"2099-02-30"},
 {"name":"ok","uuid":"cccc","enabled":true,"expire_date":""}]}},"singbox":{},"meta":{}}
J
    ensure_expire_check_cron() { :; }
    db_set_user_expire_date xray vless ok 2031-13-40; rc=$?
    check 'F8 db_set_user_expire_date rejects an impossible date' test "$rc" -ne 0
    check 'F8 rejected date leaves the stored value unchanged'    eq "$(db_get_user_expire_date xray vless ok)" ""
    db_set_user_expire_date xray vless ok 2031-12-31
    check 'F8 valid date is stored'                               eq "$(db_get_user_expire_date xray vless ok)" 2031-12-31
    check 'F8 legacy invalid past date is treated as expired'     eq "$(db_get_user_days_left xray vless legacybad)" -1
    check 'F8 legacy invalid future date does not warn/expire'    eq "$(db_get_user_days_left xray vless futurebad)" ""
    db_set_user_alert_state xray vless ok last_expire_warn_day 2
    db_set_user_expire_date xray vless ok 2032-01-01
    check 'F1 changing expiry resets the expiry-warning marker'   eq "$(db_get_user_alert_state xray vless ok last_expire_warn_day)" ""
)

# ═════════════════════════ F9 批量到期禁用 ═════════════════════════
sec_batch_expire() ( fresh_env batch
    write_db <<'J'
{"version":"4.0.0","xray":{"vless":{"port":443,"uuid":"a","users":[
 {"name":"e1","uuid":"1","enabled":true,"expire_date":"2000-01-01"},
 {"name":"e2","uuid":"2","enabled":true,"expire_date":"2000-01-02"},
 {"name":"e3","uuid":"3","enabled":true,"expire_date":"2000-01-03"},
 {"name":"live","uuid":"4","enabled":true,"expire_date":"2999-01-01"}]}},"singbox":{},"meta":{}}
J
    RB="$SEC/rebuild.log"; : >"$RB"
    rebuild_and_reload_xray() { echo xray >>"$RB"; return 0; }
    rebuild_and_reload_singbox() { echo singbox >>"$RB"; return 0; }
    tg_send_message() { :; }
    NOTIFY="$SEC/notify.log"; : >"$NOTIFY"
    send_tg_expired_notice() { echo "$1" >>"$NOTIFY"; }
    out=$(check_and_disable_expired_users --notify)
    check 'F9 stdout carries only the count'                  eq "$out" 3
    check 'F9 three expired users cause exactly one Xray restart' eq "$(grep -c xray "$RB")" 1
    check 'F9 no sing-box restart when only Xray users changed'   eq "$(grep -c singbox "$RB")" 0
    check 'F9 every disabled user is notified'                eq "$(wc -l <"$NOTIFY" | tr -d ' ')" 3
    check 'F9 live user stays enabled'                        eq "$(db_get_user_field xray vless live enabled)" true
    check 'F9 expired user is disabled'                       eq "$(db_get_user_field xray vless e2 enabled)" false
    # 重载失败时仍只输出计数，并把告警写进 expire.log
    db_set_user_enabled() { :; }
    write_db <<'J'
{"version":"4.0.0","xray":{"vless":{"port":443,"uuid":"a","users":[{"name":"e1","uuid":"1","enabled":true,"expire_date":"2000-01-01"}]}},"singbox":{},"meta":{}}
J
    rebuild_and_reload_xray() { echo "svc noise from failing restart"; return 1; }
    out=$(check_and_disable_expired_users)
    check 'F9 failing reload cannot pollute the count on stdout'  eq "$out" 1
    check 'F9 failing reload is recorded in expire.log'           grep -q '重载失败' "$CFG/expire.log"
    check 'F9 svc failure details go to stderr, not stdout'       grep -q 'cat "$err" >&2' "$PRODUCT"
)

# ═════════════════════════ F10 cron ═════════════════════════
sec_cron() ( fresh_env cron
    CRONTAB="$SEC/crontab.txt"; : >"$CRONTAB"; CRON_ERR=""
    crontab() {
        case "${1:-}" in
            -l) if [[ -n "$CRON_ERR" ]]; then echo "$CRON_ERR" >&2; return 1; fi
                [[ -s "$CRONTAB" ]] || { echo "no crontab for root" >&2; return 1; }
                cat "$CRONTAB";;
            -r) : >"$CRONTAB";;
            -) cat >"$CRONTAB";;
        esac
    }
    printf '%s\n' '15 4 * * * /usr/bin/backup.sh' >"$CRONTAB"
    L1='*/5 * * * * /usr/local/bin/vless-server.sh --sync-traffic >/dev/null 2>&1'
    _cron_ensure --sync-traffic "$L1"; rc=$?
    check 'F10 first ensure installs the entry (rc 1)'          eq "$rc" 1
    check 'F10 unrelated cron lines are preserved'              grep -qx '15 4 \* \* \* /usr/bin/backup.sh' "$CRONTAB"
    _cron_ensure --sync-traffic "$L1"; rc=$?
    check 'F10 identical entry is left alone (rc 0)'            eq "$rc" 0
    # 旧版本写入的失效路径（相对路径/已删除的下载副本）会被替换，而不是永远留着
    printf '%s\n' '15 4 * * * /usr/bin/backup.sh' '*/5 * * * * ./vless-server.sh --sync-traffic >/dev/null 2>&1' >"$CRONTAB"
    _cron_ensure --sync-traffic "$L1"; rc=$?
    check 'F10 stale/relative-path entry is replaced'           eq "$rc" 1
    check 'F10 exactly one sync-traffic line remains'           eq "$(grep -c -e '--sync-traffic' "$CRONTAB")" 1
    check 'F10 no relative script path is ever written'         bash -c '! grep -q -e " \./vless-server.sh" "$1"' _ "$CRONTAB"
    # 读取失败（非"没有 crontab"）时绝不覆盖用户 cron
    cp "$CRONTAB" "$SEC/before"; CRON_ERR="crontab: error reading spool: Permission denied"
    _cron_ensure --check-expire "0 3 * * * /x --check-expire"; rc=$?
    check 'F10 unreadable crontab is never overwritten'         eq "$rc" 2
    check 'F10 crontab content untouched after read failure'    cmp -s "$CRONTAB" "$SEC/before"
    CRON_ERR=""
    # 移除只删除本项目的行
    printf '%s\n' '15 4 * * * /usr/bin/backup.sh' "$L1" '0 3 * * * /usr/local/bin/vless-server.sh --check-expire --notify >/dev/null 2>&1' >"$CRONTAB"
    _cron_remove --sync-traffic; _cron_remove --check-expire
    check 'F10 remove deletes both project entries'             bash -c '! grep -qE -e "--(sync-traffic|check-expire)" "$1"' _ "$CRONTAB"
    check 'F10 remove keeps unrelated entries'                  grep -q 'backup.sh' "$CRONTAB"
    check 'F10 uninstall flow now removes the cron entries'     grep -q '_cron_remove "--sync-traffic"' "$PRODUCT"
    # 脚本路径：优先系统脚本；否则绝对路径
    p=$(_cron_script_path)
    check 'F10 cron script path is absolute'                    bash -c '[[ "$1" == /* ]]' _ "$p"
)

# ═════════════════════════ F11 用户增删返回语义 ═════════════════════════
sec_user_rc() ( fresh_env userrc
    write_db <<'J'
{"version":"4.0.0","xray":{"vless":{"port":443,"uuid":"aaaa","users":[{"name":"base","uuid":"aaaa","enabled":true}]}},"singbox":{},"meta":{}}
J
    ensure_expire_check_cron() { :; }; ensure_traffic_cron() { :; }
    rebuild_and_reload_xray() { return 1; }
    db_add_user xray vless alice 11111111-1111-4111-8111-111111111111 0 ''; rc=$?
    check 'F11 add: committed-but-not-applied returns 3'        eq "$rc" 3
    check 'F11 add: the user really is in the DB'               eq "$(db_get_user_field xray vless alice uuid)" 11111111-1111-4111-8111-111111111111
    db_del_user xray vless alice; rc=$?
    check 'F11 delete: committed-but-not-applied returns 3'     eq "$rc" 3
    check 'F11 delete: the user really is gone'                 eq "$(db_get_user_field xray vless alice uuid)" ""
    rebuild_and_reload_xray() { return 0; }
    db_add_user xray vless bob 22222222-2222-4222-8222-222222222222 0 ''; rc=$?
    check 'F11 add: success returns 0'                          eq "$rc" 0
    db_add_user xray vless bob 22222222-2222-4222-8222-222222222222 0 ''; rc=$?
    check 'F11 add: duplicate is a real failure (1)'            eq "$rc" 1
)

# ═════════════════════════ F2 配置原子渲染 ═════════════════════════
sec_render() ( fresh_env render
    write_db <<'J'
{"version":"4.0.0","xray":{"vless":{"port":443,"uuid":"aaaa","users":[{"name":"u","uuid":"aaaa","enabled":true}]}},"singbox":{},"meta":{}}
J
    _listen_addr() { echo 127.0.0.1; }
    db_get_routing_rules() { echo '[]'; }; db_get_warp_mode() { echo ''; }; db_get_balancer_groups() { echo '[]'; }
    echo '{"previous":"config in use by the running service"}' >"$CFG/config.json"
    before=$(sha256sum "$CFG/config.json" | awk '{print $1}')

    real_add=$(declare -f add_xray_inbound_v2)
    add_xray_inbound_v2() { return 1; }      # 所有入站渲染失败，但数据库里有启用用户
    generate_xray_config 2>/dev/null; rc=$?
    check 'F2 all-inbounds-failed is reported as failure'        test "$rc" -ne 0
    check 'F2 failed render keeps the previous config byte-for-byte' eq "$(sha256sum "$CFG/config.json" | awk '{print $1}')" "$before"
    check 'F2 no staging files are left behind'                  bash -c '! ls "$1"/config.json.* >/dev/null 2>&1' _ "$CFG"
    eval "$real_add"

    # 真正的「全部用户禁用」仍是合法状态：写出只剩 api 入站的配置并返回 0
    write_db <<'J'
{"version":"4.0.0","xray":{"vless":{"port":443,"uuid":"aaaa","users":[{"name":"u","uuid":"aaaa","enabled":false}]}},"singbox":{},"meta":{}}
J
    generate_xray_config 2>/dev/null; rc=$?
    check 'F2 all-users-disabled still succeeds'                 eq "$rc" 0
    check 'F2 ...and leaves no proxy inbound in the new config'  jq -e '[.inbounds[]? | select(.tag != "api")] | length == 0' "$CFG/config.json"
    check 'F2 ...and the disabled credential is absent'          bash -c '! grep -q aaaa "$1"' _ "$CFG/config.json"

    # 正常渲染 + xray run -test 通过 → 新配置落盘
    write_db <<'J'
{"version":"4.0.0","xray":{"vless":{"port":443,"uuid":"aaaa","users":[{"name":"u","uuid":"aaaa","enabled":true}]}},"singbox":{},"meta":{}}
J
    install_fake_xray; XLOG="$SEC/xray.log"; : >"$XLOG"; export XLOG
    generate_xray_config 2>/dev/null; rc=$?
    check 'F2 valid render succeeds'                             eq "$rc" 0
    check 'F2 valid render contains the active credential'       grep -q aaaa "$CFG/config.json"
    check 'F2 xray run -test was used as a pre-flight'           grep -q 'run -test -format json -c' "$XLOG"
    check 'F2 config.json stays 0600'                            eq "$(stat -c %a "$CFG/config.json")" 600

    # xray run -test 失败：保留上一份配置
    good=$(sha256sum "$CFG/config.json" | awk '{print $1}')
    write_db <<'J'
{"version":"4.0.0","xray":{"vless":{"port":443,"uuid":"bbbb","users":[{"name":"u","uuid":"bbbb","enabled":true}]}},"singbox":{},"meta":{}}
J
    XRAY_TEST_RC=1 generate_xray_config 2>/dev/null; rc=$?
    check 'F2 failing xray pre-flight rejects the new config'    test "$rc" -ne 0
    check 'F2 ...and keeps the last good config'                 eq "$(sha256sum "$CFG/config.json" | awk '{print $1}')" "$good"

    # 失败路径下 rebuild 不得重启服务
    svc() { echo "svc $*" >>"$SEC/svc.log"; [[ "$1" == status ]]; }
    : >"$SEC/svc.log"
    XRAY_TEST_RC=1 rebuild_and_reload_xray silent 2>/dev/null; rc=$?
    check 'F2 rebuild reports failure when the config is rejected' test "$rc" -ne 0
    check 'F2 rebuild did not restart the service'               bash -c '! grep -q "svc restart" "$1"' _ "$SEC/svc.log"
)

# ═════════════════════════ F12 nginx 回滚 ═════════════════════════
sec_nginx() ( fresh_env nginx
    NGINX_RC=0
    nginx() { [[ "$1" == "-t" ]] && return "$NGINX_RC"; return 0; }
    d="$SEC/nginx"; mkdir -p "$d/avail" "$d/enabled"
    echo 'OLD CONFIG' >"$d/avail/site"
    echo 'NEW CONFIG' >"$SEC/new.conf"
    NGINX_RC=1
    _nginx_install_conf "$SEC/new.conf" "$d/avail/site" "$d/enabled/site" 2>/dev/null; rc=$?
    check 'F12 failed nginx -t reports failure'                  test "$rc" -ne 0
    check 'F12 failed nginx -t restores the previous config'     eq "$(cat "$d/avail/site")" 'OLD CONFIG'
    rm -f "$d/avail/site" "$d/enabled/site"
    _nginx_install_conf "$SEC/new.conf" "$d/avail/site" "$d/enabled/site" 2>/dev/null; rc=$?
    check 'F12 failed first install removes the broken file'     test ! -e "$d/avail/site"
    check 'F12 ...and removes the enabled symlink'               test ! -e "$d/enabled/site" -a ! -L "$d/enabled/site"
    NGINX_RC=0
    _nginx_install_conf "$SEC/new.conf" "$d/avail/site" "$d/enabled/site" 2>/dev/null; rc=$?
    check 'F12 passing nginx -t keeps the new config'            eq "$(cat "$d/avail/site")" 'NEW CONFIG'
    check 'F12 ...and links it into sites-enabled'               test -L "$d/enabled/site"
    # 代入 sed/nginx 配置的输入必须先校验
    for bad in '/a|b' '/a&b' '/a b' 'noslash' '/a;b'; do
        _setup_nginx_xhttp_proxy example.com 18080 "$bad" >/dev/null 2>&1; rc=$?
        [[ $rc -ne 0 ]] && echo "OK   F12 rejects xhttp path '$bad'" >>"$RESULTS" || echo "FAIL F12 accepted xhttp path '$bad'" >>"$RESULTS"
    done
    _setup_nginx_xhttp_proxy 'bad domain;' 18080 /ok >/dev/null 2>&1; rc=$?
    check 'F12 rejects a hostile domain'                         test "$rc" -ne 0
)

for sec in sec_quota sec_traffic sec_lock sec_integrity sec_expiry sec_batch_expire sec_cron sec_user_rc sec_render sec_nginx; do
    printf '\n########## %s ##########\n' "$sec"
    before_fail=$(grep -c '^FAIL' "$RESULTS" || true)
    "$sec" 2>"$TMP/$sec.err"
    rc=$?
    after_fail=$(grep -c '^FAIL' "$RESULTS" || true)
    if [[ $rc -ne 0 ]]; then
        echo "FAIL $sec exited with $rc" >>"$RESULTS"
        printf '  FAIL %s exited with %s\n' "$sec" "$rc" >&2
        tail -n 30 "$TMP/$sec.err" >&2
    elif [[ "$after_fail" -gt "$before_fail" && -s "$TMP/$sec.err" ]]; then
        tail -n 30 "$TMP/$sec.err" >&2
    fi
done

[[ ! -e "$TMP/crontab-guard.log" ]] || { echo "FAIL a section touched the real crontab: $(head -n1 "$TMP/crontab-guard.log")" >>"$RESULTS"; }
pass=$(grep -c '^OK' "$RESULTS" || true)
fail=$(grep -c '^FAIL' "$RESULTS" || true)
printf '\n'
if [[ "$fail" -eq 0 && "$pass" -gt 0 ]]; then
    printf 'PASS: H16 audit-fix regression (%d assertions)\n' "$pass"
else
    grep '^FAIL' "$RESULTS" >&2
    printf 'FAIL: H16 audit-fix regression (%d failed, %d passed)\n' "$fail" "$pass" >&2
    exit 1
fi
