#!/usr/bin/env bash
# CI / Release workflow governance & public-tree hygiene contract test
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")/.." && pwd)
CI_YML="$ROOT/.github/workflows/ci.yml"
REL_YML="$ROOT/.github/workflows/release.yml"
GITEA_YML="$ROOT/.gitea/workflows/ci.yml"
HYGIENE="$ROOT/scripts/check-public-hygiene.py"

pass=0
fail=0
check() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        pass=$((pass + 1))
        printf '  OK   %s\n' "$desc"
    else
        fail=$((fail + 1))
        printf '  FAIL %s\n' "$desc" >&2
    fi
}

check 'public ci.yml exists' test -f "$CI_YML"
check 'public release.yml exists' test -f "$REL_YML"
check 'private Forgejo .gitea/workflows/ci.yml exists' test -f "$GITEA_YML"
check 'legacy PROVENANCE.json is retired' test ! -e "$ROOT/PROVENANCE.json"
check 'hygiene scanner script exists' test -f "$HYGIENE"

# Optional PyYAML full parse when PyYAML is available
if python3 -c 'import yaml' >/dev/null 2>&1; then
    for wf in "$CI_YML" "$REL_YML" "$GITEA_YML"; do
        check "YAML syntax valid: ${wf#"$ROOT/"}" python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1], encoding="utf-8"))' "$wf"
    done
fi

# Public CI workflow invariants (Ruleset check names + workflow_call + fail-closed)
check 'ci.yml supports workflow_call for release DAG' grep -Eq '^[[:space:]]*workflow_call:' "$CI_YML"
check 'ci.yml sets least-privilege contents: read' grep -Eq '^[[:space:]]*contents:[[:space:]]*read' "$CI_YML"
check 'ci.yml defines PR concurrency cancellation' grep -Fq "cancel-in-progress: \${{ github.event_name == 'pull_request' }}" "$CI_YML"
check 'ci.yml guards jobs to GitHub server_url' grep -Fq "if: github.server_url == 'https://github.com'" "$CI_YML"
check 'ci.yml preserves Ruleset check #1 (Static, Manifest, Dual-AWK Unit & Upgrade)' grep -Fq 'name: Static, Manifest, Dual-AWK Unit & Upgrade' "$CI_YML"
check 'ci.yml preserves Ruleset check #2 (Pinned Cores, Webroot & Isolated Installer E2E)' grep -Fq 'name: Pinned Cores, Webroot & Isolated Installer E2E' "$CI_YML"
check 'ci.yml contains no self-hosted skip fallback' bash -c '! grep -Fq "is_self_hosted_container" "$1"' _ "$CI_YML"
check 'ci.yml does not hardcode a 64-hex product SHA' bash -c '! grep -Eq "[0-9a-f]{64}" "$1"' _ "$CI_YML"

# Release workflow invariants (tag trigger -> preflight -> workflow_call ci -> Sigstore release)
check 'release.yml triggers on v* tags' grep -Fq "'v*'" "$REL_YML"
check 'release.yml calls ./.github/workflows/ci.yml via workflow_call' grep -Fq 'uses: ./.github/workflows/ci.yml' "$REL_YML"
check 'release.yml gates release job on preflight and ci' grep -Fq 'needs: [preflight, ci]' "$REL_YML"
check 'release.yml uses Sigstore actions/attest-build-provenance@v2' grep -Fq 'uses: actions/attest-build-provenance@v2' "$REL_YML"
check 'release.yml restricts attestation/publish to public repos' grep -Fq 'github.event.repository.private == false' "$REL_YML"

# Hygiene scanner positive + negative verification in isolated temp git repo
TMP=$(mktemp -d "${TMPDIR:-/tmp}/aio-hygiene-test.XXXXXX")
trap 'rm -rf -- "$TMP"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid

git -C "$TMP" init -q
printf 'clean public content\n' > "$TMP/README.md"
git -C "$TMP" add README.md
git -C "$TMP" commit -qm "init clean"
check 'hygiene scanner passes on clean repo' python3 "$HYGIENE" --repo "$TMP"

printf 'url=%s%s\n' 'http://10.' '0.0.1:8080/repo' > "$TMP/leak.txt"
git -C "$TMP" add leak.txt
git -C "$TMP" commit -qm "add rfc1918 leak"
check 'hygiene scanner rejects RFC1918 HTTP endpoint' bash -c '! python3 "$1" --repo "$2"' _ "$HYGIENE" "$TMP"

git -C "$TMP" rm -q leak.txt
printf 'token=%s%s\n' 'ghp_' '000000000000000000000000000000000000' > "$TMP/tok.txt"
git -C "$TMP" add tok.txt
git -C "$TMP" commit -qm "add token leak"
check 'hygiene scanner rejects GitHub token' bash -c '! python3 "$1" --repo "$2"' _ "$HYGIENE" "$TMP"

git -C "$TMP" rm -q tok.txt
printf 'custom-internal-host.example\n' > "$TMP/custom.txt"
git -C "$TMP" add custom.txt
git -C "$TMP" commit -qm "add custom host"
check 'hygiene scanner honors VLESS_HYGIENE_FORBIDDEN_REGEX' bash -c '! VLESS_HYGIENE_FORBIDDEN_REGEX="custom-internal-host" python3 "$1" --repo "$2"' _ "$HYGIENE" "$TMP"

check 'hygiene scanner passes on live repository (--allow-dirty)' python3 "$HYGIENE" --repo "$ROOT" --allow-dirty

if [[ "$fail" -eq 0 ]]; then
    printf 'PASS: CI/release workflow governance & hygiene contract (%d assertions)\n' "$pass"
else
    printf 'FAIL: CI/release workflow governance & hygiene contract (%d failed, %d passed)\n' "$fail" "$pass" >&2
    exit 1
fi
