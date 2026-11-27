#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly PINNED_XRAY_VERSION="26.3.27"
readonly PINNED_SINGBOX_VERSION="1.14.4"
readonly MIN_UNIT_TESTS=19
cd "$ROOT"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

shell_files() {
    local file
    local -a files=(
        vless-server.sh
        migrate-anytls-singbox.sh
        check-version-bump.sh
    )
    if [[ -d .github/scripts ]]; then
        local -a gh_scripts=()
        shopt -s nullglob
        gh_scripts=(.github/scripts/*.sh)
        shopt -u nullglob
        files+=("${gh_scripts[@]}")
    fi
    if [[ -d scripts ]]; then
        local -a repo_scripts=()
        shopt -s nullglob
        repo_scripts=(scripts/*.sh)
        shopt -u nullglob
        files+=("${repo_scripts[@]}")
    fi
    local -a test_scripts=()
    shopt -s nullglob
    test_scripts=(tests/*.sh)
    shopt -u nullglob
    ((${#test_scripts[@]} > 0)) || fail "shell source discovery found no tests/*.sh files"
    files+=("${test_scripts[@]}")

    for file in "${files[@]}"; do
        [[ -f "$file" ]] || fail "shell source discovery produced a missing path: $file"
        printf '%s\n' "$file"
    done
}

run_syntax() {
    local file count=0
    local -a discovered=()
    mapfile -t discovered < <(shell_files)
    # 显式检查 shell_files 自身是否成功（避免进程替换吞掉 fail 退出码）
    shell_files >/dev/null
    for file in "${discovered[@]}"; do
        [[ -n "$file" ]] || continue
        bash -n "$file"
        count=$((count + 1))
    done
    ((count > 0)) || fail "no shell sources discovered"
    printf 'PASS: bash syntax (%d files)\n' "$count"
}

run_static() {
    command -v shellcheck >/dev/null 2>&1 || fail "shellcheck is required"
    local file count=0
    local -a discovered=()
    mapfile -t discovered < <(shell_files)
    shell_files >/dev/null
    for file in "${discovered[@]}"; do
        [[ -n "$file" ]] || continue
        if [[ "$file" == tests/test-high-risk-repair.sh ]]; then
            # The imported harness intentionally replaces this function with a spy.
            shellcheck -S error -e SC2218 "$file"
        else
            shellcheck -S error "$file"
        fi
        count=$((count + 1))
    done
    ((count > 0)) || fail "no shell sources discovered"
    printf 'PASS: ShellCheck error gate (%d files)\n' "$count"
    if [[ -f scripts/check-static-invariants.py ]]; then
        python3 scripts/check-static-invariants.py
    fi
}

run_unit() (
    local awk_bin="${1:-}" awk_version test count=0 shim=""
    local -a tests=(tests/test-*.sh)
    ((${#tests[@]} >= MIN_UNIT_TESTS)) || fail \
        "unit-test discovery found ${#tests[@]} files; expected at least $MIN_UNIT_TESTS"

    if [[ -n "$awk_bin" ]]; then
        command -v "$awk_bin" >/dev/null 2>&1 || fail "requested awk is missing: $awk_bin"
        shim=$(mktemp -d "${TMPDIR:-/tmp}/aio-ci-awk.XXXXXX")
        trap 'rm -rf -- "$shim"' EXIT INT TERM
        ln -s "$(command -v "$awk_bin")" "$shim/awk"
        export PATH="$shim:$PATH"
        awk_version=$(awk -W version 2>&1 || true)
        case "$awk_bin:$awk_version" in
            mawk:*mawk*) ;;
            gawk:*GNU\ Awk*) ;;
            *) fail "awk shim did not activate $awk_bin: $awk_version" ;;
        esac
        printf 'INFO: awk portability pass uses %s (%s)\n' \
            "$(command -v "$awk_bin")" "${awk_version%%$'\n'*}"
    fi

    for test in "${tests[@]}"; do
        case "$test" in
            tests/test-auth-schema-parser-e2e.sh|tests/test-installer-e2e.sh|tests/test-singbox-native-e2e.sh|tests/test-ss-legacy-xray-e2e.sh|tests/test-webroot-ownership.sh)
                continue
                ;;
        esac
        printf '\n==> %s\n' "$test"
        bash "$test"
        count=$((count + 1))
    done

    printf '\n==> tests/test-xray-log-path.sh --mutation-selfcheck\n'
    bash tests/test-xray-log-path.sh --mutation-selfcheck
    printf '\n==> tests/test-installer-e2e.sh --identity-selftest\n'
    bash tests/test-installer-e2e.sh --identity-selftest

    ((count >= MIN_UNIT_TESTS)) || fail \
        "only $count unit tests ran; expected at least $MIN_UNIT_TESTS"
    printf 'PASS: offline/loopback unit suite (%d scripts + mutation + identity)\n' "$count"
)

require_pinned_xray() {
    local xray_bin version_line
    xray_bin="${XRAY_BIN:-$(command -v xray || true)}"
    [[ -n "$xray_bin" && -x "$xray_bin" ]] || fail "executable Xray is required"
    version_line=$("$xray_bin" version | sed -n '1p')
    case "$version_line" in
        "Xray $PINNED_XRAY_VERSION"*) ;;
        *) fail "Xray $PINNED_XRAY_VERSION is required; got: $version_line" ;;
    esac
    printf '%s\n' "$xray_bin"
}

run_xray_e2e() {
    local xray_bin receipt
    xray_bin=$(require_pinned_xray)
    receipt=$(mktemp "${TMPDIR:-/tmp}/aio-ci-xray-receipt.XXXXXX")
    if ! XRAY_BIN="$xray_bin" bash tests/test-ss-legacy-xray-e2e.sh 2>&1 | tee "$receipt"; then
        rm -f -- "$receipt"
        fail "Xray data-plane test failed"
    fi
    if ! grep -Fq '(3/3)' "$receipt" || grep -Fq 'SKIP' "$receipt"; then
        rm -f -- "$receipt"
        fail "Xray data-plane completion marker missing or skipped"
    fi
    rm -f -- "$receipt"
    echo "PASS: required Xray data-plane gate completed without skip"
}

run_auth_schema_e2e() {
    local xray_bin receipt
    xray_bin=$(require_pinned_xray)
    receipt=$(mktemp "${TMPDIR:-/tmp}/aio-ci-auth-schema.XXXXXX")
    if ! XRAY_BIN="$xray_bin" bash tests/test-auth-schema-parser-e2e.sh 2>&1 | tee "$receipt"; then
        rm -f -- "$receipt"
        fail "auth-schema parser/data-plane gate failed"
    fi
    if ! grep -Fq 'PASS: auth-schema native parser/data-plane gate (2/2;' "$receipt" || grep -Fq 'SKIP' "$receipt"; then
        rm -f -- "$receipt"
        fail "auth-schema completion marker missing or skipped"
    fi
    rm -f -- "$receipt"
    echo "PASS: required auth-schema gate completed without skip"
}

require_pinned_singbox() {
    local singbox_bin version_line
    singbox_bin="${SINGBOX_BIN:-$(command -v sing-box || true)}"
    [[ -n "$singbox_bin" && -x "$singbox_bin" ]] || fail "executable sing-box is required"
    version_line=$("$singbox_bin" version | sed -n '1p')
    [[ "$version_line" == "sing-box version $PINNED_SINGBOX_VERSION" ]] || \
        fail "sing-box $PINNED_SINGBOX_VERSION is required; got: $version_line"
    printf '%s\n' "$singbox_bin"
}

run_singbox_e2e() {
    local singbox_bin receipt
    singbox_bin=$(require_pinned_singbox)
    receipt=$(mktemp "${TMPDIR:-/tmp}/aio-ci-singbox-receipt.XXXXXX")
    if ! SINGBOX_BIN="$singbox_bin" bash tests/test-singbox-native-e2e.sh 2>&1 | tee "$receipt"; then
        rm -f -- "$receipt"
        fail "sing-box parser/data-plane gate failed"
    fi
    if ! grep -Fq 'PASS: pinned sing-box native parser/data-plane gate (3/3;' "$receipt" || grep -Fq 'SKIP' "$receipt"; then
        rm -f -- "$receipt"
        fail "sing-box completion marker missing or skipped"
    fi
    rm -f -- "$receipt"
    echo "PASS: required sing-box native gate completed without skip"
}

run_stateful_upgrade() {
    bash tests/test-stateful-upgrade.sh
}

run_webroot_e2e() {
    local receipt
    local -a cmd=(bash tests/test-webroot-ownership.sh)
    if [[ "$(id -u)" -ne 0 ]] \
        && ! unshare --user --map-root-user --mount --pid --fork true 2>/dev/null \
        && command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        # Ubuntu 24.04 hosted runners restrict unprivileged userns via AppArmor;
        # run the isolated namespace test under passwordless sudo when available.
        cmd=(sudo -n bash tests/test-webroot-ownership.sh)
    fi
    receipt=$(mktemp "${TMPDIR:-/tmp}/aio-ci-webroot-receipt.XXXXXX")
    if ! "${cmd[@]}" 2>&1 | tee "$receipt"; then
        rm -f -- "$receipt"
        fail "Web root namespace lifecycle test failed"
    fi
    if ! grep -Fq 'PASS: 真实函数级' "$receipt" || grep -Fq 'SKIP' "$receipt"; then
        rm -f -- "$receipt"
        fail "Web root namespace test was skipped or lacks its completion marker"
    fi
    rm -f -- "$receipt"
    echo "PASS: required Web root namespace gate completed without skip"
}

run_installer_e2e() {
    command -v docker >/dev/null 2>&1 || fail "docker is required"
    docker info >/dev/null 2>&1 || fail "docker daemon is unavailable"
    local xray_bin xray_assets product_sha receipt
    xray_bin=$(require_pinned_xray)
    xray_assets="${XRAY_LOCATION_ASSET:-$(dirname -- "$xray_bin")}"
    [[ -s "$xray_assets/geoip.dat" && -s "$xray_assets/geosite.dat" ]] || fail \
        "non-empty Xray geo assets are required in $xray_assets"
    product_sha=$(sha256sum vless-server.sh | awk '{print $1}')
    [[ "$product_sha" =~ ^[0-9a-f]{64}$ ]] || fail "invalid product SHA-256"
    receipt=$(mktemp "${TMPDIR:-/tmp}/aio-ci-installer-receipt.XXXXXX")
    if ! AIO_E2E_EXPECTED_SHA="$product_sha" XRAY_BIN="$xray_bin" \
        XRAY_LOCATION_ASSET="$xray_assets" \
        bash tests/test-installer-e2e.sh 2>&1 | tee "$receipt"; then
        rm -f -- "$receipt"
        fail "installer lifecycle E2E failed"
    fi
    if ! grep -Fq 'PASS: 10 lifecycle groups;' "$receipt" || grep -Fq 'SKIP' "$receipt"; then
        rm -f -- "$receipt"
        fail "installer lifecycle 10/10 completion marker missing or skipped"
    fi
    rm -f -- "$receipt"
    echo "PASS: required installer lifecycle gate completed without skip"
}

usage() {
    cat >&2 <<'EOF'
Usage: tests/run-ci.sh MODE [--awk-bin COMMAND]

Modes:
  syntax        bash -n every repository shell file
  static        ShellCheck error gate for every repository shell file
  unit          auto-discovered offline/loopback tests
  xray-e2e      required Xray 26.3.27 authentication/data-plane test
  auth-e2e      native parser/data-plane representatives by auth schema
  singbox-e2e   pinned sing-box parser and AnyTLS authentication/data plane
  stateful-upgrade real H13 artifact -> working-tree candidate with DB state
  webroot-e2e   required namespace-isolated Web root lifecycle test
  installer-e2e required Docker lifecycle test bound to the product SHA
  all           run every mode (unit uses the default awk)
EOF
    exit 2
}

mode="${1:-}"
[[ -n "$mode" ]] || usage
shift || true
awk_bin=""
while (($#)); do
    case "$1" in
        --awk-bin)
            (($# >= 2)) || usage
            awk_bin=$2
            shift 2
            ;;
        *) usage ;;
    esac
done
[[ "$mode" == unit || -z "$awk_bin" ]] || usage

case "$mode" in
    syntax) run_syntax ;;
    static) run_static ;;
    unit) run_unit "$awk_bin" ;;
    xray-e2e) run_xray_e2e ;;
    auth-e2e) run_auth_schema_e2e ;;
    singbox-e2e) run_singbox_e2e ;;
    stateful-upgrade) run_stateful_upgrade ;;
    webroot-e2e) run_webroot_e2e ;;
    installer-e2e) run_installer_e2e ;;
    all)
        run_syntax
        run_static
        run_unit
        run_xray_e2e
        run_auth_schema_e2e
        run_singbox_e2e
        run_stateful_upgrade
        run_webroot_e2e
        run_installer_e2e
        ;;
    *) usage ;;
esac
