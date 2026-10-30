#!/bin/bash
# 单元测试：check-version-bump.sh（发布闸门「改了脚本必须抬 VERSION」）。
#
# 覆盖两条基准路径：
#   * 有父提交（gitorca 全历史正本）→ 用 HEAD^
#   * 无父提交（gitpub / GitHub 是无父单 commit 快照）→ 用仓库内最高语义化 tag
# 以及放行路径（首次发布 / 新增文件 / 无基准可比）与非法版本号。
#
# 全离线、纯本地临时 git 仓，不碰网络与真实仓库。
set -uo pipefail

GATE="$(cd "$(dirname "$0")" && pwd)/check-version-bump.sh"
[ -f "$GATE" ] || { echo "FAIL: 找不到 $GATE" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vless-bump-gate.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# 隔离宿主 git 配置，避免签名/钩子/默认分支名干扰
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=gate-test GIT_AUTHOR_EMAIL=gate@test.invalid
export GIT_COMMITTER_NAME=gate-test GIT_COMMITTER_EMAIL=gate@test.invalid

pass=0; fail=0
check() { # desc actual expected
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1)); echo "  OK   $1"
    else
        fail=$((fail + 1)); echo "  FAIL $1（期望 $3，实得 $2）" >&2
    fi
}

mk_script() { # dir version marker
    cat > "$1/vless-server.sh" <<EOF
#!/bin/bash
readonly VERSION="$2"
# content-marker: $3
EOF
}

new_repo() { # name -> dir
    local d="$WORK/$1"
    mkdir -p "$d"
    git -C "$d" init -q
    printf '%s' "$d"
}

commit() { git -C "$1" add -A && git -C "$1" commit -qm "$2"; }

# 把 HEAD 树重做成一个**无父**提交（模拟 gitpub / GitHub 的单 commit 快照）
orphan_head() { # dir msg
    local tree new
    tree="$(git -C "$1" rev-parse 'HEAD^{tree}')" || return 1
    new="$(git -C "$1" commit-tree "$tree" -m "$2")" || return 1
    git -C "$1" update-ref refs/heads/master "$new" || return 1
    git -C "$1" reset -q --hard "$new"
}

run_gate() { # dir [args...] -> rc
    local d="$1"; shift
    ( cd "$d" && bash "$GATE" "$@" >/dev/null 2>&1 )
    echo $?
}

echo "########## 1. 有父提交（gitorca 全历史路径） ##########"

r="$(new_repo p1)"; mk_script "$r" 3.4.10-h5 a; commit "$r" init
check "未改脚本 → 通过" "$(run_gate "$r")" "0"

r="$(new_repo p2)"; mk_script "$r" 3.4.10-h5 a; commit "$r" init
mk_script "$r" 3.4.10-h6 b; commit "$r" bump
check "改脚本 + 抬版本 → 通过" "$(run_gate "$r")" "0"

r="$(new_repo p3)"; mk_script "$r" 3.4.10-h5 a; commit "$r" init
mk_script "$r" 3.4.10-h5 b; commit "$r" no-bump
check "改脚本 + 未抬版本 → 拦下(1)" "$(run_gate "$r")" "1"

r="$(new_repo p4)"; mk_script "$r" 3.4.10-h5 a; commit "$r" init
mk_script "$r" 3.4.10-h4 b; commit "$r" downgrade
check "改脚本 + 版本回退 → 拦下(1)" "$(run_gate "$r")" "1"

r="$(new_repo p5)"; mk_script "$r" 3.4.10-h5 a; commit "$r" init
mk_script "$r" 3.4.10-h10 b; commit "$r" bump
check "h9→h10 数字比较（抬版本）→ 通过" "$(run_gate "$r")" "0"

r="$(new_repo p6)"; mk_script "$r" 3.4.10-h9 a; commit "$r" init
mk_script "$r" 3.4.10-h10 b; commit "$r" bump
check "h9→h10 不是字符串比较 h10<h9 → 通过" "$(run_gate "$r")" "0"

r="$(new_repo p7)"; mk_script "$r" 3.4.10-h5 a; commit "$r" init
mk_script "$r" 3.5.0 b; commit "$r" bump
check "跨基础版本抬升 3.4.10→3.5.0 → 通过" "$(run_gate "$r")" "0"

echo ""
echo "########## 2. 无父提交（gitpub / GitHub 单 commit 快照路径） ##########"

r="$(new_repo o1)"; mk_script "$r" 3.4.10-h5 a; commit "$r" init
git -C "$r" tag v3.4.10-h5
mk_script "$r" 3.4.10-h5 b; commit "$r" changed; orphan_head "$r" snapshot
check "无父提交 + 改脚本未抬版本 → 拦下(1)" "$(run_gate "$r")" "1"

r="$(new_repo o2)"; mk_script "$r" 3.4.10-h5 a; commit "$r" init
git -C "$r" tag v3.4.10-h5
mk_script "$r" 3.4.10-h6 b; commit "$r" changed; orphan_head "$r" snapshot
check "无父提交 + 改脚本已抬版本 → 通过" "$(run_gate "$r")" "0"

r="$(new_repo o3)"; mk_script "$r" 3.4.10-h5 a; commit "$r" init
mk_script "$r" 3.4.10-h5 b; commit "$r" changed; orphan_head "$r" snapshot
check "无父提交且无语义化 tag → 跳过(0)" "$(run_gate "$r")" "0"

r="$(new_repo o4)"; mk_script "$r" 3.4.10-h5 a; commit "$r" init
git -C "$r" tag dev            # 滚动 tag 不得当基准
mk_script "$r" 3.4.10-h5 b; commit "$r" changed; orphan_head "$r" snapshot
check "只有滚动 tag dev → 视为无基准，跳过(0)" "$(run_gate "$r")" "0"

# 多个语义化 tag 时必须取最高的那个当基准（否则会拿旧内容误报）
r="$(new_repo o5)"; mk_script "$r" 3.4.10-h4 a; commit "$r" init
git -C "$r" tag v3.4.10-h4
mk_script "$r" 3.4.10-h5 b; commit "$r" h5
git -C "$r" tag v3.4.10-h5
orphan_head "$r" snapshot
check "最高语义化 tag 当基准（内容与 h5 tag 一致）→ 通过" "$(run_gate "$r")" "0"

r="$(new_repo o6)"; mk_script "$r" 3.4.10-h5 a; commit "$r" init
git -C "$r" tag v3.4.10-h5
mk_script "$r" 3.4.10-h6 b; commit "$r" changed; orphan_head "$r" snapshot
check "--base 显式指定（无父提交时）→ 通过" "$(run_gate "$r" --base refs/tags/v3.4.10-h5)" "0"

r="$(new_repo o7)"; mk_script "$r" 3.4.10-h5 a; commit "$r" init
git -C "$r" tag v3.4.10-h5
mk_script "$r" 3.4.10-h5 b; commit "$r" changed; orphan_head "$r" snapshot
check "--base 全 0 哨兵值 → 降级选基准并拦下(1)" "$(run_gate "$r" --base 0000000000000000000000000000000000000000)" "1"

echo ""
echo "########## 3. 边界与放行 ##########"

r="$(new_repo e1)"; printf '#!/bin/bash\nreadonly VERSION="dev"\n' > "$r/vless-server.sh"
commit "$r" init
check "VERSION 非语义化(dev) → 拦下(1)" "$(run_gate "$r")" "1"

r="$(new_repo e2)"; printf '#!/bin/bash\necho no-version\n' > "$r/vless-server.sh"
commit "$r" init
check "脚本缺 readonly VERSION → 拦下(1)" "$(run_gate "$r")" "1"

r="$(new_repo e3)"; mk_script "$r" 3.4.10-h5 a; commit "$r" init
printf '#!/bin/bash\necho other\n' > "$r/other.sh"
commit "$r" changed-other
check "只改了别的文件、脚本未动 → 通过" "$(run_gate "$r")" "0"

r="$(new_repo e4)"; printf '#!/bin/bash\necho placeholder\n' > "$r/README.md"; commit "$r" init
mk_script "$r" 3.4.10-h5 a; commit "$r" add-script
check "脚本在基准中不存在（新增文件）→ 通过" "$(run_gate "$r")" "0"

check "用法错误（未知参数）→ 2" "$(run_gate "$WORK" --nope)" "2"

echo ""
if [ "$fail" -eq 0 ]; then
    echo "PASS: 发布闸门行为正确（共 $pass 条断言）"
else
    echo "FAIL: $fail 条断言未通过（通过 $pass 条）" >&2
    exit 1
fi
