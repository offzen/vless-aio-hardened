#!/usr/bin/env bash
# 重算并校验仓库 SHA256SUMS 清单（供在线自更新与离线包校验使用）。
# 用法（仓库根目录）：bash scripts/refresh-manifest.sh [--check]
#   --check  只校验当前 SHA256SUMS 是否与 git 跟踪树一致，不写文件（不一致时 rc=1）
set -Eeuo pipefail
cd "$(dirname -- "${BASH_SOURCE[0]:-$0}")/.."
export LC_ALL=C

check=0
[[ "${1:-}" == "--check" ]] && check=1

product=vless-server.sh
sha=$(sha256sum "$product" | cut -d' ' -f1)
version=$(sed -n 's/^readonly VERSION="\([^"]*\)".*/\1/p' "$product" | head -1)
[[ -n "$version" ]] || { echo "cannot read VERSION" >&2; exit 2; }

# 清单覆盖：git 跟踪的全部文件，不含 SHA256SUMS 自身（避免递归）
mapfile -t files < <(git ls-files | grep -vx 'SHA256SUMS' | sort)
sums=$(for f in "${files[@]}"; do sha256sum -- "$f"; done)

if ((check)); then
    if ! diff -u <(printf '%s\n' "$sums") SHA256SUMS >/dev/null 2>&1; then
        echo "SHA256SUMS stale" >&2
        exit 1
    fi
    echo "OK: manifest up to date (product $sha, ${#files[@]} files)"
    exit 0
fi

printf '%s\n' "$sums" > SHA256SUMS
echo "refreshed: product $sha, version $version, ${#files[@]} files"
