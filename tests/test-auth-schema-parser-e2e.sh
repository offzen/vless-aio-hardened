#!/usr/bin/env bash
# Native parser/data-plane representatives selected from the capability manifest.
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
MANIFEST="$ROOT/tests/protocol-capabilities.tsv"
XRAY_BIN=${XRAY_BIN:-$(command -v xray || true)}
[[ -x "$XRAY_BIN" ]] || { echo "FAIL: executable pinned Xray is required" >&2; exit 2; }
version=$($XRAY_BIN version | sed -n '1p')
[[ "$version" == 'Xray 26.3.27'* ]] || { echo "FAIL: Xray 26.3.27 is required; got: $version" >&2; exit 1; }
[[ -f "$MANIFEST" ]] || { echo "FAIL: capability manifest missing" >&2; exit 2; }

# Every declared Xray renderer/auth class must have a native evidence owner.
missing=""
while IFS=$'\t' read -r proto engine contract uri renderer cluster; do
    [[ -z "$proto" || "$proto" == \#* || "$engine" != xray ]] && continue
    case "$cluster" in
        xray-uuid) owner=test-installer-e2e.sh ;;
        xray-ss-legacy) owner=test-ss-legacy-xray-e2e.sh ;;
        xray-vmess|xray-password|xray-userpass|xray-ss2022) owner=parser-below ;;
        *) missing+=" $proto:$cluster"; continue ;;
    esac
    [[ "$owner" == parser-below || -f "$ROOT/tests/$owner" ]] || missing+=" $proto:$owner"
done <"$MANIFEST"
[[ -z "$missing" ]] || { echo "FAIL: auth cluster lacks native evidence owner:$missing" >&2; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/aio-auth-schema.XXXXXX")
trap 'rm -rf -- "$TMP"' EXIT INT TERM
cat >"$TMP/config.json" <<'JSON'
{
  "log":{"loglevel":"warning"},
  "inbounds":[
    {"listen":"127.0.0.1","port":21001,"protocol":"vmess","settings":{"clients":[{"id":"11111111-1111-4111-8111-111111111111","email":"second@vmess"}]}},
    {"listen":"127.0.0.1","port":21002,"protocol":"trojan","settings":{"clients":[{"password":"second-trojan","email":"second@trojan"}]}},
    {"listen":"127.0.0.1","port":21003,"protocol":"socks","settings":{"auth":"password","accounts":[{"user":"second","pass":"second-socks"}],"udp":true}}
  ],
  "outbounds":[{"protocol":"freedom","tag":"direct"}]
}
JSON
"$XRAY_BIN" run -test -c "$TMP/config.json" >/dev/null 2>&1 || { echo "FAIL: native Xray parser rejected auth-schema representatives" >&2; exit 1; }
printf '  OK   pinned Xray parser accepts VMess, Trojan, and SOCKS credential schemas\n'

receipt="$TMP/ss-legacy.log"
XRAY_BIN="$XRAY_BIN" bash "$ROOT/tests/test-ss-legacy-xray-e2e.sh" >"$receipt" 2>&1
! grep -Fq SKIP "$receipt" || { echo "FAIL: ss-legacy data plane skipped" >&2; exit 1; }
grep -Fq '(3/3)' "$receipt" || { echo "FAIL: ss-legacy 3/3 receipt missing" >&2; exit 1; }
printf '  OK   password/cipher cluster proves second active accepted and disabled rejected\n'

printf 'PASS: auth-schema native parser/data-plane gate (2/2; %s)\n' "$version"
