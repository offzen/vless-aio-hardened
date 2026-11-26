# Test workflow

The repository has one entry point for local and CI validation: `tests/run-ci.sh`.
Test discovery is automatic, so a new `tests/test-*.sh` file enters the syntax,
ShellCheck, and unit-test gates without duplicating a filename list in workflow YAML.

## Fast local checks

```bash
bash tests/run-ci.sh syntax
bash tests/run-ci.sh static
bash tests/run-ci.sh unit --awk-bin mawk
bash tests/run-ci.sh unit --awk-bin gawk
```

`unit` excludes the explicitly isolated E2E tests. It includes a source-derived protocol
capability gate: `protocol-capabilities.tsv` must exactly classify every identifier in the
three product registries (with no fixed count), supported identifiers must have direct URI
and renderer dispatch, and five deliberate source/manifest mutations must be rejected.
It also runs the Xray log-path mutation self-check, the installer candidate-identity
self-test, and a negative self-test that proves malformed auto-discovered files and an
unpinned Xray cannot pass. The Web
root lifecycle has its own required mode; it rejects the test's legacy `SKIP` result:

```bash
sudo bash tests/run-ci.sh webroot-e2e
```

## Required data-plane gates

CI installs Xray 26.3.27 from the exact upstream release URL through
`tests/install-ci-xray.sh`. The archive SHA-256 is pinned separately for Linux amd64
and arm64, and a checksum or version mismatch fails closed.

```bash
xray_dir=$(mktemp -d)
bash tests/install-ci-xray.sh "$xray_dir"
XRAY_BIN="$xray_dir/xray" XRAY_LOCATION_ASSET="$xray_dir" \
  bash tests/run-ci.sh xray-e2e
XRAY_BIN="$xray_dir/xray" XRAY_LOCATION_ASSET="$xray_dir" \
  bash tests/run-ci.sh auth-e2e
XRAY_BIN="$xray_dir/xray" XRAY_LOCATION_ASSET="$xray_dir" \
  bash tests/run-ci.sh installer-e2e
singbox_dir=$(mktemp -d)
bash tests/install-ci-singbox.sh "$singbox_dir"
SINGBOX_BIN="$singbox_dir/sing-box" bash tests/run-ci.sh singbox-e2e
```

- `xray-e2e` must end with the `3/3` authentication/data-plane marker. Missing Xray,
  another Xray version, a skip marker, or a missing receipt is a failure.
- `auth-e2e` runs Xray's native parser for UUID/password/account schema representatives
  and reuses the real `ss-legacy` 3/3 accept/accept/reject data plane.
- `installer-e2e` computes the current `vless-server.sh` SHA-256, injects it into the
  fail-closed candidate identity check, and must end with the full `10 lifecycle groups`
  marker. Running only `--identity-selftest` cannot satisfy this gate.
- `singbox-e2e` installs sing-box 1.14.4 from SHA-256-pinned amd64/arm64 assets,
  checks the product-generated Hysteria2/TUIC/AnyTLS configuration with the native parser,
  then proves a second active AnyTLS credential succeeds and a disabled credential is
  rejected on an isolated loopback data plane. Missing/wrong binaries and skips fail closed.
- `stateful-upgrade` extracts the exact H13 parent artifact from Git (SHA-256
  `33c953bde77f587cb6601751ea404f92b134be0cc663c2e765685393225dfa88`), updates it to
  the real working-tree candidate, preserves a populated historical DB, and proves both
  success and the established partial-apply contract: candidate plus `.bak` retained,
  all three helpers attempted, and exit 1. Missing Git history is a hard failure.

Both tests use loopback or a disposable Docker container. They do not connect to a
production host. The Docker build downloads its disposable dependency image/packages;
the test container itself runs with `--network none`, all capabilities dropped, and a
read-only repository mount.

## Rolling release CI

The master/`ci/**` push and pull-request workflow (`.github/workflows/ci.yml`) verifies, in order: the product SHA-256 pinned in the workflow, `SHA256SUMS`, `scripts/refresh-manifest.sh --check`, the version-bump gate, Bash syntax, the ShellCheck error gate, the `mawk` and `gawk` unit suites, `stateful-upgrade` (it needs the full Git history, hence `fetch-depth: 0`), and then the pinned-core jobs `xray-e2e`, `auth-e2e`, `singbox-e2e`, `webroot-e2e` and `installer-e2e`. It does not deploy, create tags or publish assets. `tests/test-h16-audit-fixes.sh` is picked up by the unit-suite auto-discovery and also runs under both AWK engines.
