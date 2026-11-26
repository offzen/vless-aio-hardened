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
            r"https?://(?:10\.\d{1,3}\.\d{1,3}\.\d{1,3}"
            r"|192\.168\.\d{1,3}\.\d{1,3}"
            r"|172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3})(?:[:/]|$)"
        ),
    ),
)


def git(repo: pathlib.Path, *args: str) -> subprocess.CompletedProcess[bytes]:
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    return subprocess.run(
        ["git", "--no-pager", "-c", "core.quotepath=false", "-C", str(repo), *args],
        env=env,
        capture_output=True,
        check=True,
    )


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--repo", type=pathlib.Path, default=ROOT, help="Git repository root to scan")
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

    if findings:
        print("HYGIENE_FAILED: potential secret or internal coordinate detected:", file=sys.stderr)
        for item in findings[:30]:
            print(f"  - {item}", file=sys.stderr)
        return 1

    print(f"HYGIENE_OK: scanned {len(tracked)} tracked files (0 findings)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
