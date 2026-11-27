#!/usr/bin/env python3
"""Lightweight public-tree hygiene and secret/internal-coordinate scanner.

Ensures tracked files contain no private keys, credential tokens, or internal RFC1918
endpoints before pushing or releasing to a public repository. Additional private
patterns can be supplied via VLESS_HYGIENE_FORBIDDEN_REGEX without hardcoding internal
infrastructure names in this script.
"""
from __future__ import annotations

import argparse
import os
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

BUILTIN_RULES: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("private-key-header", re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY-----")),
    ("github-classic-token", re.compile(r"\bgh[pousr]_[A-Za-z0-9]{30,}\b")),
    ("github-fine-grained-pat", re.compile(r"\bgithub_pat_[A-Za-z0-9_]{30,}\b")),
    ("gitlab-pat", re.compile(r"\bglpat-[A-Za-z0-9_-]{20,}\b")),
    ("aws-access-key", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
    (
        "rfc1918-http-endpoint",
        re.compile(
            r"https?://(?:10\.\d{1,3}\.\d{1,3}\.\d{3}"
            r"|10\.\d{1,3}\.\d{1,3}\.\d{1,2}"
            r"|192\.168\.\d{1,3}\.\d{1,3}"
            r"|172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3})(?:[:/]|$)"
        ),
    ),
)

INTERNAL_COMMIT_EMAIL_RE = re.compile(
    r"<[^>\s]*@(?:[A-Za-z0-9-]+\.)*(?:internal|lan|home\.arpa)>",
    re.IGNORECASE,
)


def git(repo: pathlib.Path, *args: str, check: bool = True) -> subprocess.CompletedProcess[bytes]:
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    return subprocess.run(
        ["git", "--no-pager", "-c", "core.quotepath=false", "-C", str(repo), *args],
        env=env,
        capture_output=True,
        check=check,
    )


def _semver_key(ver: str) -> tuple[tuple[int, ...], int]:
    base, _, rev = ver.partition("-h")
    parts = tuple(int(p) if p.isdigit() else 0 for p in base.split("."))
    h_num = int(rev) if rev.isdigit() else -1
    return (parts, h_num)


def _select_history_base(repo: pathlib.Path, explicit_base: str) -> str:
    head_res = git(repo, "rev-parse", "--verify", "-q", "HEAD", check=False)
    if head_res.returncode != 0:
        return ""
    head_sha = head_res.stdout.decode("utf-8", "replace").strip()
    if explicit_base:
        res = git(repo, "rev-parse", "--verify", "-q", f"{explicit_base}^{{commit}}", check=False)
        if res.returncode == 0:
            return res.stdout.decode("utf-8", "replace").strip()
    tags_out = git(repo, "for-each-ref", "--format=%(refname:short)", "refs/tags/v*", check=False).stdout.decode("utf-8", "replace")
    candidates: list[tuple[tuple[tuple[int, ...], int], str]] = []
    for raw_t in tags_out.splitlines():
        t = raw_t.strip()
        if not t.startswith("v"):
            continue
        peel = git(repo, "rev-parse", "--verify", "-q", f"refs/tags/{t}^{{commit}}", check=False)
        if peel.returncode != 0:
            continue
        tag_sha = peel.stdout.decode("utf-8", "replace").strip()
        if tag_sha == head_sha:
            continue
        anc = git(repo, "merge-base", "--is-ancestor", tag_sha, head_sha, check=False)
        if anc.returncode == 0:
            candidates.append((_semver_key(t[1:]), tag_sha))
    if not candidates:
        return ""
    candidates.sort(key=lambda item: item[0])
    return candidates[-1][1]


def _scan_commit_and_tag_history(
    repo: pathlib.Path,
    rules: list[tuple[str, re.Pattern[str]]],
    explicit_base: str,
    findings: list[str],
) -> None:
    head_res = git(repo, "rev-parse", "--verify", "-q", "HEAD", check=False)
    if head_res.returncode != 0:
        return
    base_sha = _select_history_base(repo, explicit_base)
    rev_spec = f"{base_sha}..HEAD" if base_sha else "-1"
    log_args = ["log", "--format=COMMIT %H%nAuthor: %an <%ae>%nCommit: %cn <%ce>%n%B"]
    log_args.append(rev_spec if base_sha else "-n1")
    meta_text = git(repo, *log_args, check=False).stdout.decode("utf-8", "replace")
    cur_commit = "HEAD"
    for line in meta_text.splitlines():
        if line.startswith("COMMIT "):
            cur_commit = line.split()[1][:12]
            continue
        if (line.startswith("Author: ") or line.startswith("Commit: ")) and INTERNAL_COMMIT_EMAIL_RE.search(line):
            findings.append(f"commit:{cur_commit}: matched internal-commit-email")
        for label, pattern in rules:
            if pattern.search(line):
                findings.append(f"commit:{cur_commit}: matched {label}")

    if base_sha:
        patch_out = git(
            repo,
            "log",
            "-p",
            "--no-ext-diff",
            "--unified=0",
            rev_spec,
            "--",
            ".",
            ":!scripts/check-public-hygiene.py",
            check=False,
        ).stdout.decode("utf-8", "replace")
        cur_commit = "HEAD"
        for line in patch_out.splitlines():
            if line.startswith("commit "):
                cur_commit = line.split()[1][:12]
                continue
            if line.startswith("+") and not line.startswith("+++"):
                added = line[1:]
                for label, pattern in rules:
                    if pattern.search(added):
                        findings.append(f"history:{cur_commit}: matched {label} in outgoing patch")

    points_at = git(repo, "tag", "--points-at", "HEAD", check=False).stdout.decode("utf-8", "replace")
    for raw_tag in points_at.splitlines():
        tag = raw_tag.strip()
        if not tag.startswith("v"):
            continue
        obj_type = git(repo, "cat-file", "-t", f"refs/tags/{tag}", check=False).stdout.decode("utf-8", "replace").strip()
        if obj_type == "tag":
            tag_body = git(repo, "cat-file", "-p", f"refs/tags/{tag}", check=False).stdout.decode("utf-8", "replace")
            for line in tag_body.splitlines():
                if line.startswith("tagger ") and INTERNAL_COMMIT_EMAIL_RE.search(line):
                    findings.append(f"tag:{tag}: matched internal-tagger-email")
                for label, pattern in rules:
                    if pattern.search(line):
                        findings.append(f"tag:{tag}: matched {label}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--repo", type=pathlib.Path, default=ROOT, help="Git repository root to scan")
    ap.add_argument("--base-ref", default="", help="Optional base ref/SHA for outgoing commit-range hygiene scan")
    ap.add_argument("--allow-dirty", action="store_true", help="Skip clean working-tree check during local WIP")
    args = ap.parse_args()
    repo = args.repo.resolve()

    if not args.allow_dirty:
        diff = git(repo, "status", "--porcelain", "--untracked-files=normal").stdout.decode("utf-8", "replace").strip()
        if diff:
            print("HYGIENE_FAILED: working tree has uncommitted or untracked files:\n" + diff, file=sys.stderr)
            return 1

    rules = list(BUILTIN_RULES)
    extra = os.environ.get("VLESS_HYGIENE_FORBIDDEN_REGEX", "").strip()
    if extra:
        rules.append(("env-custom-forbidden", re.compile(extra)))

    tracked = [p for p in git(repo, "ls-files", "-z").stdout.decode("utf-8", "surrogateescape").split("\0") if p]
    findings: list[str] = []
    self_rel = "scripts/check-public-hygiene.py"

    for rel in tracked:
        if rel == self_rel:
            continue
        path = repo / rel
        if not path.is_file() or path.is_symlink():
            continue
        raw = path.read_bytes()
        if b"\0" in raw:
            continue
        text = raw.decode("utf-8", "replace")
        for lineno, line in enumerate(text.splitlines(), 1):
            for label, pattern in rules:
                if pattern.search(line):
                    findings.append(f"{rel}:{lineno}: matched {label}")

    _scan_commit_and_tag_history(repo, rules, args.base_ref.strip(), findings)

    if findings:
        print("HYGIENE_FAILED: potential secret or internal coordinate detected:", file=sys.stderr)
        for item in findings[:30]:
            print(f"  - {item}", file=sys.stderr)
        return 1

    print(f"HYGIENE_OK: scanned {len(tracked)} tracked files (0 findings)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
