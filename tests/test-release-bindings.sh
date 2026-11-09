#!/usr/bin/env bash
# 发行包绑定一致性闸门
#
# 背景（2026-11-09 实测事故）：PR #1 改了 README.md 却没有重算 SHA256SUMS 与
# PROVENANCE.files，结果 README/USAGE 里教终端用户执行的 `sha256sum -c SHA256SUMS`
# 在发行树上直接 FAILED，而当时 CI 的四个作业没有任何一个覆盖这项。
# 本测试让这类缺陷必然变红：只改文档也必须同步校验和。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

[ -f SHA256SUMS ] || fail "缺少 SHA256SUMS"
[ -f PROVENANCE.json ] || fail "缺少 PROVENANCE.json"

# 1) SHA256SUMS 与实际字节一致
sha256sum -c SHA256SUMS || fail "SHA256SUMS 与实际字节不一致（改了文件必须重算校验和）"
pass "SHA256SUMS 与实际字节一致"

# 2) 条目格式：<64 hex><两空格><文件名>，且只覆盖发行包内非递归载荷
while IFS= read -r line; do
  [ -n "$line" ] || continue
  if ! printf '%s' "$line" | grep -Eq '^[0-9a-f]{64}  [^/]+$'; then
    fail "SHA256SUMS 条目格式非法: $line"
  fi
done < SHA256SUMS
pass "SHA256SUMS 条目格式合法"

# 3) PROVENANCE.files 与 SHA256SUMS 同集同值，file_count 自洽
python3 - <<'PY'
import hashlib
import json
import sys

sums = {}
with open('SHA256SUMS', encoding='utf-8') as fh:
    for line in fh:
        line = line.rstrip('\n')
        if not line:
            continue
        digest, name = line.split('  ', 1)
        sums[name] = digest

with open('PROVENANCE.json', encoding='utf-8') as fh:
    doc = json.load(fh)

files = doc.get('files', {})
bad = []
if set(files) != set(sums):
    bad.append('集合不一致: PROVENANCE=%s SHA256SUMS=%s' % (sorted(files), sorted(sums)))
for name, digest in sums.items():
    if files.get(name) != digest:
        bad.append('%s: PROVENANCE=%s SHA256SUMS=%s' % (name, files.get(name), digest))
    actual = hashlib.sha256(open(name, 'rb').read()).hexdigest()
    if actual != digest:
        bad.append('%s: 实际=%s 记录=%s' % (name, actual, digest))
if doc.get('file_count') != len(sums):
    bad.append('file_count=%s 实际条目=%s' % (doc.get('file_count'), len(sums)))

if bad:
    print('FAIL: PROVENANCE 绑定与发行包不一致')
    for item in bad:
        print('  - ' + item)
    sys.exit(1)
print('PASS: PROVENANCE.files 与 SHA256SUMS 同集同值（%d 项），file_count 一致' % len(sums))
PY
