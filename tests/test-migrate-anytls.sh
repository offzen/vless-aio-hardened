#!/usr/bin/env bash
# Regression tests for migrate-anytls-singbox.sh (H-7).
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
MIGRATE="$ROOT/migrate-anytls-singbox.sh"
[[ -f "$MIGRATE" ]] || { echo "FAIL: missing $MIGRATE" >&2; exit 2; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/aio-migrate-anytls.XXXXXX")
trap 'rm -rf -- "$TMP"' EXIT INT TERM

pass=0
fail=0
check() {
    local label=$1
    shift
    if "$@"; then
        pass=$((pass + 1))
        printf '  OK   %s\n' "$label"
    else
        fail=$((fail + 1))
        printf '  FAIL %s\n' "$label" >&2
    fi
}

# 1. Bare --db without value exits 2 immediately (no infinite loop)
timeout 3 bash "$MIGRATE" --db >/dev/null 2>&1
rc=$?
check 'bare --db exits 2 without infinite loop' test "$rc" -eq 2

# 2. --dry-run works when passed before --db
cat > "$TMP/db1.json" <<'JSON'
{"xray":{"anytls":{"port":18443,"password":"pw1","sni":"a.example"}},"singbox":{}}
JSON
before_sha=$(sha256sum "$TMP/db1.json" | awk '{print $1}')
bash "$MIGRATE" --dry-run --db "$TMP/db1.json" >/dev/null 2>&1
rc=$?
after_sha=$(sha256sum "$TMP/db1.json" | awk '{print $1}')
check '--dry-run before --db succeeds' test "$rc" -eq 0
check '--dry-run does not mutate DB' test "$before_sha" = "$after_sha"

# 3. Single-object migration moves xray.anytls -> singbox.anytls with 0600 backup
bash "$MIGRATE" --db "$TMP/db1.json" >/dev/null 2>&1
rc=$?
check 'single-object migration succeeds' test "$rc" -eq 0
check 'single-object migration moves to singbox.anytls and deletes xray.anytls' jq -e '.xray.anytls == null and .singbox.anytls.port == 18443 and .singbox.anytls.password == "pw1"' "$TMP/db1.json" >/dev/null
bak_count=$(find "$TMP" -maxdepth 1 -name 'db1.json.bak-migrate-*' | wc -l | tr -d ' ')
check 'migration creates backup file' test "$bak_count" -ge 1

# 4. Existing singbox.anytls on different port is merged into array (no overwrite/data loss)
cat > "$TMP/db2.json" <<'JSON'
{"xray":{"anytls":{"port":18444,"password":"pw-old","sni":"old.example"}},"singbox":{"anytls":{"port":18443,"password":"pw-existing","sni":"new.example"}}}
JSON
bash "$MIGRATE" --db "$TMP/db2.json" >/dev/null 2>&1
rc=$?
check 'non-conflicting existing singbox.anytls merges cleanly' test "$rc" -eq 0
check 'merged singbox.anytls preserves both ports without overwrite' jq -e '.xray.anytls == null and (.singbox.anytls | type == "array" and length == 2) and ([.singbox.anytls[].port] | sort) == [18443, 18444]' "$TMP/db2.json" >/dev/null

# 5. Conflicting port fails closed without mutating DB
cat > "$TMP/db3.json" <<'JSON'
{"xray":{"anytls":{"port":18443,"password":"pw-old","sni":"old.example"}},"singbox":{"anytls":{"port":18443,"password":"pw-existing","sni":"new.example"}}}
JSON
before3=$(sha256sum "$TMP/db3.json" | awk '{print $1}')
bash "$MIGRATE" --db "$TMP/db3.json" >/dev/null 2>&1
rc=$?
after3=$(sha256sum "$TMP/db3.json" | awk '{print $1}')
check 'conflicting port migration fails closed' test "$rc" -ne 0
check 'conflicting port leaves DB unchanged' test "$before3" = "$after3"

# 6. No bare pkill command in migration script (excluding comments/logs)
check 'migrate-anytls-singbox.sh contains no bare pkill command' bash -c '! grep -vE "^[[:space:]]*(#|log )" "$1" | grep -qE "\b(pkill|killall)\b"' _ "$MIGRATE"

printf '\n'
if [[ "$fail" -eq 0 ]]; then
    printf 'PASS: migrate-anytls-singbox regression (%d assertions)\n' "$pass"
else
    printf 'FAIL: migrate-anytls-singbox regression (%d failed, %d passed)\n' "$fail" "$pass" >&2
    exit 1
fi
