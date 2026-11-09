#!/usr/bin/env bash
# Regression: every generate_xray_config branch must emit EXPANDED log paths.
#
# Modes:
#   test-xray-log-path.sh                      normal mode (4 exclusive fixtures + 2 default-path cases)
#   test-xray-log-path.sh --mutation-selfcheck revert each of the 4 jq sites to the h9 literal, one at a
#                                              time, and prove the normal-mode run fails for exactly
#                                              that site's fixture label
# Env:
#   KEEP=1                          keep the temp dir (default: evidence is dumped to stderr on failure, then removed)
#   VLESS_LOG_PATH_TEST_SRC=<file>  test this product script instead of $SCRIPT_DIR/vless-server.sh (internal)
#   VLESS_LOG_PATH_TEST_REPORT=<f>  write the sorted failed fixture labels to <f> (internal, used by selfcheck)
#
# NOTE: this file must never enable errexit. The product script turns errexit on when
# sourced, so it is switched off again right after `source`. Every check is explicit.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
SRC="${VLESS_LOG_PATH_TEST_SRC:-$SCRIPT_DIR/../vless-server.sh}"

MODE=normal
case "${1:-}" in
    '') ;;
    --mutation-selfcheck) MODE=selfcheck ;;
    *) echo "usage: $0 [--mutation-selfcheck]" >&2; exit 2 ;;
esac

[[ -f "$SRC" ]] || { echo "FAIL: product script not found: $SRC" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo 'FAIL: jq not found' >&2; exit 2; }

WORK="$(mktemp -d /tmp/vless-logpath.XXXXXXXX)" || { echo 'FAIL: mktemp' >&2; exit 2; }
WORK_PIN="$WORK"   # cleanup uses the pinned copy so a clobbered $WORK can never redirect rm -rf
readonly WORK_PIN

# All helpers carry a t_ / T_ prefix so sourcing the 25k-line product cannot overwrite them.
t_dump_evidence() {
    [[ -d "$WORK_PIN/ev" ]] || return 0
    local f
    for f in "$WORK_PIN"/ev/*; do
        [[ -f "$f" && -s "$f" ]] || continue
        [[ "$f" == *.stdout ]] && continue
        printf '===== evidence: %s =====\n' "${f#"$WORK_PIN"/}" >&2
        head -c 16384 "$f" >&2
        printf '\n' >&2
    done
}

t_cleanup() {
    local rc=$?
    trap - EXIT
    case "$WORK_PIN" in
        /tmp/vless-logpath.*) ;;
        *) exit "$rc" ;;
    esac
    if [[ -d "$WORK_PIN" && ! -L "$WORK_PIN" ]]; then
        # Evidence first, deletion second (history: a trap once deleted gen.err before anyone read it).
        if (( rc != 0 )); then t_dump_evidence; fi
        if [[ "${KEEP:-0}" == 1 ]]; then
            printf 'KEEP=1: work dir kept at %s\n' "$WORK_PIN" >&2
        else
            rm -rf -- "$WORK_PIN"
        fi
    fi
    exit "$rc"
}
trap t_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# shellcheck disable=SC2218  # mkdir() guard is defined below on purpose; `command mkdir` bypasses it
command mkdir -p "$WORK/ev" "$WORK/cfg" "$WORK/log" "$WORK/home"

T_FAIL=0
T_GROUP=_global
FAILED_GROUPS="$WORK/failed.groups"
: > "$FAILED_GROUPS"

t_check() { # name expected actual
    if [[ "$2" == "$3" ]]; then
        printf '  OK   %s\n' "$1"
    else
        printf '  FAIL %s (expected=%s actual=%s)\n' "$1" "$2" "$3" >&2
        T_FAIL=1
        printf '%s\n' "$T_GROUP" >> "$FAILED_GROUPS"
    fi
}

# --------------------------------------------------------------------------
# Mutation self-check mode (never sources the product script)
# --------------------------------------------------------------------------
# h9 literal forms that replace the h10 forms, on the ONE targeted line only.
MUT_O_ACC='($logroot + "/access.log")'
MUT_O_ERR='($logroot + "/error.log")'
MUT_N_ACC='"${VLESS_TEST_LOG_ROOT:-/var/log}/xray/access.log"'
MUT_N_ERR='"${VLESS_TEST_LOG_ROOT:-/var/log}/xray/error.log"'

t_mutate_site() { # <src> <dst> <line>
    local src="$1" dst="$2" ln="$3" cnt
    LN="$ln" O_ACC="$MUT_O_ACC" N_ACC="$MUT_N_ACC" O_ERR="$MUT_O_ERR" N_ERR="$MUT_N_ERR" \
    awk '
        function rep(s, o, n,   i) {
            while ((i = index(s, o)) > 0) s = substr(s, 1, i - 1) n substr(s, i + length(o))
            return s
        }
        BEGIN {
            ln = ENVIRON["LN"] + 0
            oa = ENVIRON["O_ACC"]; na = ENVIRON["N_ACC"]
            oe = ENVIRON["O_ERR"]; ne = ENVIRON["N_ERR"]
        }
        NR == ln { $0 = rep($0, oa, na) }
        NR == ln || NR == ln + 1 { $0 = rep($0, oe, ne) }
        { print }
    ' "$src" > "$dst" || return 1
    # Only the targeted site may have changed: same line count, targeted line now literal,
    # exactly 3 of the 4 h10 access forms remain.
    [[ "$(wc -l < "$src")" == "$(wc -l < "$dst")" ]] || return 1
    [[ "$(sed -n "${ln}p" "$dst")" == *"$MUT_N_ACC"* ]] || return 1
    cnt="$(grep -cF -- "$MUT_O_ACC" "$dst")"
    [[ "$cnt" == 3 ]] || return 1
    return 0
}

CHILD_RC=0
CHILD_SET=""
t_run_child() { # <src> <tag>   -> CHILD_RC, CHILD_SET (space separated sorted failed labels)
    local src="$1" tag="$2" rep="$WORK/ev/$2.failed"
    rm -f "$rep"
    VLESS_LOG_PATH_TEST_SRC="$src" VLESS_LOG_PATH_TEST_REPORT="$rep" \
        bash "$SELF" > "$WORK/ev/$tag.stdout" 2> "$WORK/ev/$tag.stderr"
    CHILD_RC=$?
    CHILD_SET="<no-report>"
    if [[ -f "$rep" ]]; then
        CHILD_SET="$(tr '\n' ' ' < "$rep" | sed 's/ *$//')"
    fi
}

t_selfcheck() {
    local -a labels=(has-routing user-rules multi-ip no-routing)
    local -a lines=()
    local pat='access: ($logroot + "/access.log")'
    local i ln exp mut ok=0

    mapfile -t lines < <(grep -nF -- "$pat" "$SRC" | cut -d: -f1)
    if [[ "${#lines[@]}" != 4 ]]; then
        printf 'mutation-selfcheck: FAIL (expected exactly 4 sites matching [%s] in %s, found %s: %s)\n' \
            "$pat" "$SRC" "${#lines[@]}" "${lines[*]:-none}" >&2
        return 2
    fi

    # Control run: the unmutated product must be fully green, otherwise the comparison below is meaningless.
    t_run_child "$SRC" baseline
    if [[ "$CHILD_RC" == 0 && -z "$CHILD_SET" ]]; then
        printf '  OK   baseline (unmutated) passes\n'
    else
        printf '  FAIL baseline (unmutated) rc=%s failed-labels=[%s]\n' "$CHILD_RC" "$CHILD_SET" >&2
        printf 'mutation-selfcheck: FAIL (baseline not green)\n' >&2
        return 1
    fi

    for i in 0 1 2 3; do
        ln="${lines[$i]}"
        exp="${labels[$i]}"
        mut="$WORK/mut-$i.sh"
        if ! t_mutate_site "$SRC" "$mut" "$ln"; then
            printf '  FAIL site %s (line %s): could not build a precise single-site mutation\n' "$i" "$ln" >&2
            continue
        fi
        t_run_child "$mut" "mut-$i"
        if [[ "$CHILD_RC" == 1 && "$CHILD_SET" == "$exp" ]]; then
            printf '  OK   site line %s reverted -> failed labels exactly {%s}\n' "$ln" "$exp"
            ok=$((ok + 1))
        else
            printf '  FAIL site line %s reverted -> expected failed labels {%s}, actual {%s} (child rc=%s)\n' \
                "$ln" "$exp" "$CHILD_SET" "$CHILD_RC" >&2
        fi
    done

    if (( ok == 4 )); then
        printf 'mutation-selfcheck: PASS (4/4 sites individually detected)\n'
        return 0
    fi
    printf 'mutation-selfcheck: FAIL (%d/4 sites individually detected)\n' "$ok" >&2
    return 1
}

if [[ "$MODE" == selfcheck ]]; then
    t_selfcheck
    exit $?
fi

# --------------------------------------------------------------------------
# Normal mode: isolation scaffold (sed-rewrite CFG -> source copy -> stub -> call)
# --------------------------------------------------------------------------
sed -e "s@^readonly CFG=\"/etc/vless-reality\"@readonly CFG=\"$WORK/cfg\"@" "$SRC" > "$WORK/script.sh"
[[ "$(grep -cF "readonly CFG=\"$WORK/cfg\"" "$WORK/script.sh")" == 1 ]] || { echo 'FAIL: CFG rewrite' >&2; exit 2; }

export VLESS_SOURCE_ONLY=1 VLESS_TEST_LOG_ROOT="$WORK/log" HOME="$WORK/home" TMPDIR="$WORK"
export XDG_STATE_HOME="$WORK" XDG_CACHE_HOME="$WORK" XDG_CONFIG_HOME="$WORK"

# Gate-stub inputs (read by the stubs below); each fixture sets all three explicitly.
FX_ROUTING='[]'
FX_USER='[]'
FX_IPOUT='[]'
FX_DB='[]'   # db_get_routing_rules: the OUTER gate of the whole routing block
DB_RULES='[{"outbound":"direct","ip_version":"prefer_ipv4","domain":"geosite:cn"}]'

source "$WORK/script.sh" || { echo 'FAIL: source' >&2; exit 2; }
# The product script re-enables errexit (and may arm an ERR trap / clobber our vars): undo, re-arm.
set +e
trap - ERR
WORK="$WORK_PIN"
trap t_cleanup EXIT
[[ $- != *e* ]] || { echo 'FAIL: errexit still enabled after source' >&2; exit 2; }

# ---- stubs -----------------------------------------------------------------
_listen_addr() { printf '127.0.0.1\n'; }
svc() { printf 'FAIL: service invocation blocked\n' >&2; return 99; }
_ok() { :; }; _info() { :; }; _warn() { :; }; _err() { printf 'gen_err: %s\n' "$*" >&2; }
db_get() { jq -c --arg c "$1" --arg p "$2" '.[$c][$p] // empty' "$DB_FILE"; }
db_list_protocols() { jq -r --arg c "$1" '(.[$c] // {}) | keys[]' "$DB_FILE"; }
db_get_balancer_groups() { printf '[]\n'; }
db_get_warp_mode() { printf '\n'; }
get_xray_protocols() { db_list_protocols xray; }
# Superseded gate source; kept inert so a stray caller can never open a gate.
db_get_routing_rules() { printf '%s\n' "${FX_DB:-[]}"; }

# The REAL gate sources read by generate_xray_config (h9-era test stubbed the wrong function).
# Each stub records that it was consulted, so a renamed/never-called stub cannot silently go inert again.
gen_xray_routing_rules()        { printf 'gen_xray_routing_rules\n'        >> "$WORK/stub.calls"; printf '%s\n' "$FX_ROUTING"; }
gen_xray_user_routing_rules()   { printf 'gen_xray_user_routing_rules\n'   >> "$WORK/stub.calls"; printf '%s\n' "$FX_USER"; }
gen_xray_ip_routing_outbounds() { printf 'gen_xray_ip_routing_outbounds\n' >> "$WORK/stub.calls"; printf '%s\n' "$FX_IPOUT"; }
# Not a gate in the table, but if the product has it, keep it neutral.
if declare -F gen_xray_ip_routing_rules >/dev/null 2>&1; then
    gen_xray_ip_routing_rules() { printf '[]\n'; }
fi

# Filesystem guards (defined AFTER source). Arguments are logged one per line. Absolute paths outside
# $WORK are swallowed (so /var/log/xray is never created on the test host); paths inside $WORK pass
# through to the real command so the fixtures behave as before.
t_guard() { # <cmd> <log> args...
    local cmd="$1" log="$2" a outside=0
    shift 2
    if (( $# > 0 )); then printf '%s\n' "$@" >> "$log"; fi
    for a in "$@"; do
        case "$a" in
            "$WORK"|"$WORK"/*) ;;
            /*) outside=1 ;;
        esac
    done
    if (( outside )); then return 0; fi
    command "$cmd" "$@"
}
mkdir()   { t_guard mkdir   "$WORK/mkdir.log" "$@"; }
chown()   { t_guard chown   "$WORK/guard.log" "$@"; }
chmod()   { t_guard chmod   "$WORK/guard.log" "$@"; }
touch()   { t_guard touch   "$WORK/guard.log" "$@"; }
install() { t_guard install "$WORK/guard.log" "$@"; }

PEER='{"name":"on","uuid":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","enabled":true}'
T_DB="{\"xray\":{\"vless-ws-notls\":{\"port\":18447,\"uuid\":\"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee\",\"users\":[$PEER]}}}"

# ---- jq programs (jq 1.5/1.6 compatible) -------------------------------------
JQ_META='[.. | strings | select(test("[$`]"))] | length'
JQ_HAS_DOMAIN_CN='any((.routing.rules // [])[] | select(.domain != null) | .domain[]?; . == "geosite:cn")'
# Ambiguity: the spec says ".balancers == []". Xray keeps balancers under .routing; accept either location,
# but the value must be an explicit empty array (absent -> "<absent>" -> FAIL).
JQ_BALANCERS='(.routing.balancers // .balancers // "<absent>")'
JQ_ADS_TAGS='[(.routing.rules // [])[] | select(any((.domain // [])[]; . == "geosite:ads")) | .outboundTag] | unique'
JQ_HAS_IP_TAG='any((.outbounds // [])[]; .tag == "ip-1.1.1.1")'
JQ_BASE_TAGS='[(.outbounds // [])[] | .tag] as $t | all("direct","block","blocked","api"; . as $x | any($t[]; . == $x))'
JQ_DOMAIN_RULE_COUNT='[(.routing.rules // [])[] | select(.domain != null)] | length'

t_jq() { jq -rc "$1" "$CFG/config.json" 2>&1; }
t_called() { if grep -qxF -- "$1" "$WORK/stub.calls"; then echo yes; else echo no; fi; }

# Site-specific structural proof: the text of .log.* is identical across all four sites, so only
# structure can prove WHICH site produced the config.
t_structure() { # <group> <label>
    local group="$1" label="$2"
    case "$group" in
        has-routing)   # site A
            t_check "$label: site A: routing carries domain geosite:cn" true "$(t_jq "$JQ_HAS_DOMAIN_CN")"
            t_check "$label: site A: balancers == []" '[]' "$(t_jq "$JQ_BALANCERS")"
            ;;
        user-rules)    # site B
            t_check "$label: site B: geosite:ads rule -> blocked" '["blocked"]' "$(t_jq "$JQ_ADS_TAGS")"
            ;;
        multi-ip)      # site C
            t_check "$label: site C: outbound tag ip-1.1.1.1 present" true "$(t_jq "$JQ_HAS_IP_TAG")"
            ;;
        no-routing)    # site D
            t_check "$label: site D: base outbounds direct/block/blocked/api" true "$(t_jq "$JQ_BASE_TAGS")"
            t_check "$label: site D: no domain-bearing routing rule" 0 "$(t_jq "$JQ_DOMAIN_RULE_COUNT")"
            ;;
    esac
}

# <group> <label> <root-mode: set|unset|empty> <gen_xray_routing_rules> <gen_xray_user_routing_rules>
# <gen_xray_ip_routing_outbounds> <expected log root>
t_run_case() {
    local group="$1" label="$2" mode="$3" rules="$4" urules="$5" ipouts="$6" root="$7" dbrules="${8:-[]}"
    local tag="${label//[^A-Za-z0-9._-]/_}" rc access dir
    T_GROUP="$group"

    printf '%s\n' "$T_DB" > "$DB_FILE"
    FX_ROUTING="$rules"; FX_USER="$urules"; FX_IPOUT="$ipouts"; FX_DB="$dbrules"
    rm -f "$CFG/config.json"
    : > "$WORK/mkdir.log"; : > "$WORK/guard.log"; : > "$WORK/stub.calls"

    (
        case "$mode" in
            set)   export VLESS_TEST_LOG_ROOT="$WORK/log" ;;
            unset) unset VLESS_TEST_LOG_ROOT ;;
            empty) export VLESS_TEST_LOG_ROOT="" ;;
        esac
        generate_xray_config
    ) > "$WORK/gen.out" 2> "$WORK/gen.err"
    rc=$?

    # Preserve evidence per case (dumped to stderr by the EXIT trap if anything failed).
    cp -f "$WORK/gen.err"    "$WORK/ev/$tag.gen.err"     2>/dev/null
    cp -f "$WORK/gen.out"    "$WORK/ev/$tag.gen.out"     2>/dev/null
    cp -f "$WORK/mkdir.log"  "$WORK/ev/$tag.mkdir.log"   2>/dev/null
    cp -f "$WORK/stub.calls" "$WORK/ev/$tag.stub.calls"  2>/dev/null
    cp -f "$CFG/config.json" "$WORK/ev/$tag.config.json" 2>/dev/null

    t_check "$label: generation rc" 0 "$rc"
    # gen_xray_routing_rules lives INSIDE `if [[ -n "$(db_get_routing_rules)" ... ]]`, so it is only
    # consulted when the outer gate is open. Expecting "yes" unconditionally is what made the
    # h9-era test look green while sites A/B were unreachable.
    local exp_route=no; [[ -n "$dbrules" && "$dbrules" != "[]" ]] && exp_route=yes
    t_check "$label: gate stub gen_xray_routing_rules consulted" "$exp_route" "$(t_called gen_xray_routing_rules)"
    t_check "$label: gate stub gen_xray_user_routing_rules consulted"   yes "$(t_called gen_xray_user_routing_rules)"
    t_check "$label: gate stub gen_xray_ip_routing_outbounds consulted" yes "$(t_called gen_xray_ip_routing_outbounds)"
    if [[ ! -s "$CFG/config.json" ]]; then
        t_check "$label: config produced" yes no
        return
    fi
    t_check "$label: config is valid JSON" yes "$(if jq -e . "$CFG/config.json" >/dev/null 2>&1; then echo yes; else echo no; fi)"

    t_check "$label: log.access expanded" "$root/xray/access.log" "$(t_jq '.log.access // "<missing>"')"
    t_check "$label: log.error expanded"  "$root/xray/error.log"  "$(t_jq '.log.error // "<missing>"')"
    t_check "$label: no shell syntax" 0 "$(grep -c '\${' "$CFG/config.json")"
    t_check "$label: no shell metachars in log path" 0 "$(t_jq "$JQ_META")"

    # Directory consistency (the other half of h9: mkdir hit the real path, config pointed at a literal).
    access="$(t_jq '.log.access // empty')"
    if [[ -n "$access" ]]; then dir="$(dirname -- "$access")"; else dir='<none>'; fi
    t_check "$label: config log dir was passed to mkdir" yes \
        "$(if grep -qxF -- "$dir" "$WORK/mkdir.log"; then echo yes; else echo no; fi)"
    t_check "$label: mkdir recorded expected log dir $root/xray" yes \
        "$(if grep -qxF -- "$root/xray" "$WORK/mkdir.log"; then echo yes; else echo no; fi)"
    if [[ "$mode" == set ]]; then
        t_check "$label: config log dir exists on disk" yes "$(if [[ -d "$dir" ]]; then echo yes; else echo no; fi)"
    fi

    t_structure "$group" "$label"
}

R_HAS='[{"type":"field","domain":["geosite:cn"],"outboundTag":"direct"}]'
U_RULES='[{"type":"field","domain":["geosite:ads"],"outboundTag":"blocked"}]'
IP_OUT='[{"protocol":"freedom","tag":"ip-1.1.1.1","settings":{"domainStrategy":"UseIPv4"}}]'

VARLOG_PRE=no
[[ -e /var/log/xray ]] && VARLOG_PRE=yes

# Mutually exclusive gates: exactly one of the three sources is non-empty (none for site D),
# so each label lands on exactly one jq site. Never open two gates at once (later site overwrites earlier).
#            group        label        mode  routing     user       ip-outbounds  expected-root
# Reachability map (verified against the source, not assumed):
#   site A (3318): has_routing=TRUE  -> entered via db_get_routing_rules + gen_xray_routing_rules
#   site B (3462): has_routing=FALSE + user rules non-empty   (site B lives in the `else` at :3392)
#   site C (3488): has_routing=FALSE + user rules empty + ip routing non-empty
#   site D (3503): has_routing=FALSE + user rules empty + ip routing empty
t_run_case   has-routing  has-routing  set   "$R_HAS"    '[]'       '[]'          "$WORK/log" "$DB_RULES"   # site A
t_run_case   user-rules   user-rules   set   '[]'        "$U_RULES" '[]'          "$WORK/log" '[]'          # site B
t_run_case   multi-ip     multi-ip     set   '[]'        '[]'       "$IP_OUT"     "$WORK/log" '[]'          # site C
t_run_case   no-routing   no-routing   set   '[]'        '[]'       '[]'          "$WORK/log" '[]'          # site D

# Default-path cases (production never sets VLESS_TEST_LOG_ROOT). Attributed to group no-routing (site D)
# so that mutating site D is the only mutation that can trip them.
#   unset: ${VAR:-/var/log} falls back;  empty: ':-' also falls back (plain '-' would NOT) -> locks the semantics.
t_run_case   no-routing   'no-routing/LOG_ROOT-unset'  unset '[]' '[]' '[]' /var/log '[]'
t_run_case   no-routing   'no-routing/LOG_ROOT-empty'  empty '[]' '[]' '[]' /var/log '[]'

T_GROUP=_global
if [[ "$VARLOG_PRE" == no ]]; then
    t_check 'safety: test did not create /var/log/xray' no "$(if [[ -e /var/log/xray ]]; then echo yes; else echo no; fi)"
fi

if [[ -n "${VLESS_LOG_PATH_TEST_REPORT:-}" ]]; then
    sort -u "$FAILED_GROUPS" > "$VLESS_LOG_PATH_TEST_REPORT"
fi

if (( T_FAIL )); then
    echo 'test-xray-log-path: FAILED' >&2
    exit 1
fi
echo 'test-xray-log-path: PASS'
exit 0
