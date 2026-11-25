#!/usr/bin/env bash
# 重算发布元数据：SHA256SUMS、PROVENANCE.json、.github/workflows/ci.yml 内的产品 SHA。
# 用法（仓库根目录）：bash scripts/refresh-manifest.sh [--check]
#   --check  只校验当前元数据是否与工作树一致，不写文件（不一致时 rc=1）
set -Eeuo pipefail
cd "$(dirname -- "${BASH_SOURCE[0]:-$0}")/.."
export LC_ALL=C
check=0; [[ "${1:-}" == "--check" ]] && check=1
command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }

product=vless-server.sh
sha=$(sha256sum "$product" | cut -d' ' -f1)
version=$(sed -n 's/^readonly VERSION="\([^"]*\)".*/\1/p' "$product" | head -1)
[[ -n "$version" ]] || { echo "cannot read VERSION" >&2; exit 2; }

# 清单覆盖：git 跟踪的全部文件，不含 SHA256SUMS 与 PROVENANCE.json 自身（避免递归）
mapfile -t files < <(git ls-files | grep -vxE 'SHA256SUMS|PROVENANCE.json' | sort)
sums=$(for f in "${files[@]}"; do sha256sum -- "$f"; done)

# ci.yml 里硬编码的产品 SHA（以 -c - 校验的那一行）
ci=.github/workflows/ci.yml
ci_new=$(sed -E "s/[0-9a-f]{64}(  vless-server\.sh|' vless-server\.sh)/${sha}\1/" "$ci")

prov=$(jq -n --arg v "$version" --arg sha "$sha" --argjson old "$(cat PROVENANCE.json)" \
  --argjson files "$(for f in "${files[@]}"; do printf '%s\t%s\n' "$f" "$(sha256sum -- "$f" | cut -d' ' -f1)"; done \
      | jq -Rn '[inputs|split("\t")|{(.[0]):.[1]}]|add')" \
  '$old | .version=$v | .product_sha256=$sha | .file_count=($files|length) | .files=$files | del(.prerelease_tag) | .release_tag=("v"+$v)')

if ((check)); then
  rc=0
  diff <(printf '%s\n' "$sums") SHA256SUMS >/dev/null || { echo "SHA256SUMS stale" >&2; rc=1; }
  [[ "$ci_new" == "$(cat "$ci")" ]] || { echo "ci.yml product SHA stale" >&2; rc=1; }
  [[ "$(jq -S . <<<"$prov")" == "$(jq -S . PROVENANCE.json)" ]] || { echo "PROVENANCE.json stale" >&2; rc=1; }
  ((rc)) || echo "OK: manifest up to date (product $sha, ${#files[@]} files)"
  exit $rc
fi
printf '%s\n' "$ci_new" > "$ci"
# ci.yml 变更后需重新计算清单
sums=$(for f in "${files[@]}"; do sha256sum -- "$f"; done)
printf '%s\n' "$sums" > SHA256SUMS
prov=$(jq --argjson files "$(for f in "${files[@]}"; do printf '%s\t%s\n' "$f" "$(sha256sum -- "$f" | cut -d' ' -f1)"; done | jq -Rn '[inputs|split("\t")|{(.[0]):.[1]}]|add')" '.files=$files|.file_count=($files|length)' <<<"$prov")
printf '%s\n' "$prov" > PROVENANCE.json
echo "refreshed: product $sha, version $version, ${#files[@]} files"
