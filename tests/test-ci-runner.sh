#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PROBE="$ROOT/tests/zz-ci-discovery-probe.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/aio-ci-runner-selftest.XXXXXX")
cleanup() {
    rm -f -- "$PROBE"
    rm -rf -- "$TMP"
}
trap cleanup EXIT INT TERM

printf '#!/usr/bin/env bash\nif [[\n' > "$PROBE"
if bash "$ROOT/tests/run-ci.sh" syntax >"$TMP/syntax.log" 2>&1; then
    echo "FAIL: syntax gate accepted an auto-discovered malformed test" >&2
    exit 1
fi
grep -Fq 'zz-ci-discovery-probe.sh' "$TMP/syntax.log" || {
    echo "FAIL: syntax failure did not identify the discovery probe" >&2
    exit 1
}
rm -f -- "$PROBE"

cat > "$TMP/xray" <<'SH'
#!/usr/bin/env sh
echo 'Xray 0.0.0 (negative fixture)'
SH
chmod +x "$TMP/xray"
if XRAY_BIN="$TMP/xray" bash "$ROOT/tests/run-ci.sh" xray-e2e >"$TMP/xray.log" 2>&1; then
    echo "FAIL: Xray gate accepted an unpinned version" >&2
    exit 1
fi
grep -Fq 'Xray 26.3.27 is required' "$TMP/xray.log" || {
    echo "FAIL: Xray version failure lacked the expected diagnostic" >&2
    exit 1
}

printf 'PASS: CI runner rejects auto-discovered syntax failures and unpinned Xray (2/2)\n'
