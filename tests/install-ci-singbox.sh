#!/usr/bin/env bash
set -Eeuo pipefail

readonly SINGBOX_VERSION="1.14.4"
readonly BASE_URL="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}"

usage() {
    echo "Usage: $0 DEST_DIR" >&2
    exit 2
}

[[ $# -eq 1 && -n "$1" ]] || usage
for dep in curl install sha256sum tar uname; do
    command -v "$dep" >/dev/null 2>&1 || {
        echo "FAIL: required command is missing: $dep" >&2
        exit 2
    }
done

case "$(uname -m)" in
    x86_64|amd64)
        arch="amd64"
        expected_sha256="699a1b510aa4396b2176d32d1181920399ebf1e267835da6f3b598d0f7c24968"
        ;;
    aarch64|arm64)
        arch="arm64"
        expected_sha256="436441f76ee2f7fe21b5b2d426d3cb261a480455a704865789ad533e4273ec26"
        ;;
    *)
        echo "FAIL: unsupported CI architecture: $(uname -m)" >&2
        exit 2
        ;;
esac

readonly dest=$1
readonly asset="sing-box-${SINGBOX_VERSION}-linux-${arch}.tar.gz"
readonly package_dir="sing-box-${SINGBOX_VERSION}-linux-${arch}"
readonly tmp=$(mktemp -d "${TMPDIR:-/tmp}/aio-ci-singbox.XXXXXX")
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
tar -xzf "$archive" -C "$tmp/unpack" "$package_dir/sing-box"
install -m 0755 "$tmp/unpack/$package_dir/sing-box" "$dest/sing-box"

version_line=$("$dest/sing-box" version | sed -n '1p')
case "$version_line" in
    "sing-box version $SINGBOX_VERSION") ;;
    *)
        echo "FAIL: installed sing-box reports an unexpected version: $version_line" >&2
        exit 1
        ;;
esac

printf 'PASS: installed pinned %s (%s)\n' "$version_line" "$expected_sha256"
