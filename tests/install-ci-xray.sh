#!/usr/bin/env bash
set -euo pipefail

readonly XRAY_VERSION="26.3.27"
readonly BASE_URL="https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}"

usage() {
    echo "Usage: $0 DEST_DIR" >&2
    exit 2
}

[[ $# -eq 1 && -n "$1" ]] || usage
for dep in curl install sha256sum unzip uname; do
    command -v "$dep" >/dev/null 2>&1 || {
        echo "FAIL: required command is missing: $dep" >&2
        exit 2
    }
done

case "$(uname -m)" in
    x86_64|amd64)
        asset="Xray-linux-64.zip"
        expected_sha256="23cd9af937744d97776ee35ecad4972cf4b2109d1e0fe6be9930467608f7c8ae"
        ;;
    aarch64|arm64)
        asset="Xray-linux-arm64-v8a.zip"
        expected_sha256="4d30283ae614e3057f730f67cd088a42be6fdf91f8639d82cb69e48cde80413c"
        ;;
    *)
        echo "FAIL: unsupported CI architecture: $(uname -m)" >&2
        exit 2
        ;;
esac

readonly dest=$1
readonly tmp=$(mktemp -d "${TMPDIR:-/tmp}/aio-ci-xray.XXXXXX")
cleanup() {
    rm -rf -- "$tmp"
}
trap cleanup EXIT INT TERM

archive="$tmp/$asset"
mkdir -p -- "$dest" "$tmp/unpack"
curl --fail --location --silent --show-error \
    --retry 3 --retry-delay 1 --retry-connrefused \
    --proto '=https' --tlsv1.2 \
    --output "$archive" "$BASE_URL/$asset"
printf '%s  %s\n' "$expected_sha256" "$archive" | sha256sum -c - >/dev/null
unzip -q "$archive" xray geoip.dat geosite.dat -d "$tmp/unpack"
install -m 0755 "$tmp/unpack/xray" "$dest/xray"
install -m 0644 "$tmp/unpack/geoip.dat" "$tmp/unpack/geosite.dat" "$dest/"

version_line=$("$dest/xray" version | sed -n '1p')
case "$version_line" in
    "Xray $XRAY_VERSION"*) ;;
    *)
        echo "FAIL: installed Xray reports an unexpected version: $version_line" >&2
        exit 1
        ;;
esac

printf 'PASS: installed pinned %s (%s)\n' "$version_line" "$expected_sha256"
