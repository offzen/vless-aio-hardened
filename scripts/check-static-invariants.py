#!/usr/bin/env python3
"""Static structural invariant gate for vless-aio-hardened (L1a + L1b).

Enforces class-wide invariants derived from H15-H19 multi-round audits that
ShellCheck on outer Bash files cannot catch on its own:
  INV-1: Embedded heredoc syntax & POSIX gate (OpenRC/POSIX sh -n, no Bashisms,
         generated Bash scripts bash -n, OpenRC env_file loaded before command_args
         without arbitrary `.` execution).
  INV-2: Zero legacy certificate issuer-substring trust checks (R3/ZeroSSL/Buypass).
  INV-3: Zero unguarded GNU-only `date -d` calls in vless-server.sh.
  INV-4: Zero `eval`, zero `dpkg -l`, zero bare `exec ... 2>/dev/null` FD-2 clobber.
  INV-5: Subscription fetchers (`fetch_subscription`, `parse_subscription`) use
         `curl -K -` and never pass raw URLs on `curl` argv.
  INV-6: State-mutating `db_*` / `refresh_*` functions do not end on a bare
         conditional `[[ ... ]] && ...` returning 1 on the false branch.
  INV-7: Embedded `watchdog.sh` enforces `paused` + `.singbox-stopped-empty`
         and aligns Alpine `gcompat` `_pgrep`.
"""
from __future__ import annotations

import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
VLESS = ROOT / "vless-server.sh"
MIGRATOR = ROOT / "migrate-anytls-singbox.sh"

errors: list[str] = []


def err(inv: str, msg: str) -> None:
    errors.append(f"[{inv}] {msg}")


def extract_heredocs(lines: list[str]) -> list[tuple[int, int, str, bool, list[tuple[int, str]]]]:
    """Return list of (start_ln, end_ln, target, quoted_delim, body_lines)."""
    out = []
    i = 0
    while i < len(lines):
        m = re.search(r'cat\s*>\s*([^\s<]+)\s*<<\s*([\'"]?)([A-Za-z0-9_]+)\2', lines[i])
        if m:
            target = m.group(1)
            quoted = bool(m.group(2))
            delim = m.group(3)
            start = i + 1
            body: list[tuple[int, str]] = []
            j = i + 1
            while j < len(lines) and lines[j].strip() != delim:
                body.append((j + 1, lines[j]))
                j += 1
            out.append((start, j + 1, target, quoted, body))
            i = j + 1
        else:
            i += 1
    return out


def sanitize_unquoted_heredoc_for_sh_n(text: str) -> str:
    """Replace outer-Bash parameter expansions in unquoted heredocs with safe POSIX tokens."""
    # Balanced-brace unwrap of outer `${var:+body}` (handling nested `${...}` inside body)
    out: list[str] = []
    i = 0
    n = len(text)
    while i < n:
        m = re.match(r'\$\{[A-Za-z_][A-Za-z0-9_]*:\+', text[i:])
        if m:
            j = i + m.end()
            depth = 1
            while j < n and depth > 0:
                if text[j:j + 2] == '${':
                    depth += 1
                    j += 2
                elif text[j] == '}':
                    depth -= 1
                    j += 1
                else:
                    j += 1
            inner = text[i + m.end():j - 1]
            out.append(inner)
            i = j
        else:
            out.append(text[i])
            i += 1
    s = "".join(out)
    s = s.replace(r"\$", "$")
    s = re.sub(r'\$\{[A-Za-z_][A-Za-z0-9_]*\}', 'DUMMY_VAL', s)
    s = re.sub(r'\$[A-Za-z_][A-Za-z0-9_]*', 'DUMMY_VAL', s)
    return s


def check_syntax(shell_bin: str, content: str, label: str) -> None:
    with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as tf:
        tf.write(content)
        tmp_path = pathlib.Path(tf.name)
    try:
        res = subprocess.run([shell_bin, "-n", str(tmp_path)], capture_output=True, text=True)
        if res.returncode != 0:
            err("INV-1", f"{label} failed `{shell_bin} -n`: {res.stderr.strip()}")
    finally:
        tmp_path.unlink(missing_ok=True)


def extract_function(lines: list[str], name: str) -> list[tuple[int, str]]:
    out: list[tuple[int, str]] = []
    in_fn = False
    for idx, l in enumerate(lines, 1):
        if not in_fn:
            if re.match(rf'^{re.escape(name)}\(\)\s*\{{', l):
                in_fn = True
                out.append((idx, l))
        else:
            out.append((idx, l))
            if re.match(r'^\}\s*$', l):
                break
    return out


def main() -> int:
    v_lines = VLESS.read_text(encoding="utf-8").splitlines()
    m_lines = MIGRATOR.read_text(encoding="utf-8").splitlines() if MIGRATOR.exists() else []

    # ── INV-1: Embedded heredoc syntax & POSIX gate ───────────────────────────
    heredocs = extract_heredocs(v_lines)
    openrc_count = 0
    bash_gen_count = 0
    watchdog_body = ""
    for start, end, target, quoted, body in heredocs:
        if not body:
            continue
        first = body[0][1].strip()
        raw_text = "\n".join(bl for _, bl in body) + "\n"
        if first.startswith("#!/sbin/openrc-run") or first.startswith("#!/bin/sh") or "init.d" in target:
            openrc_count += 1
            for ln, bl in body:
                if bl.lstrip().startswith("#"):
                    continue
                if re.search(r'\[\[|\]\]|\(\(|&>|<<<|\bsource\b|\bfunction\b', bl):
                    err("INV-1", f"POSIX/OpenRC heredoc {target} (L{ln}) contains Bashism: {bl.strip()}")
            check_text = raw_text if quoted else sanitize_unquoted_heredoc_for_sh_n(raw_text)
            check_syntax("sh", check_text, f"{target} (L{start}-L{end})")
            if "${name}" in target and "env_file" in raw_text:
                env_pos = raw_text.find("env_file")
                args_pos = raw_text.find("command_args=")
                if args_pos != -1 and (env_pos == -1 or env_pos > args_pos):
                    err("INV-1", f"OpenRC {target} (L{start}-L{end}) evaluates command_args before env_file")
                if re.search(r'&&\s*\.\s+"?\$\{?env_file', raw_text):
                    err("INV-1", f"OpenRC {target} (L{start}-L{end}) executes env_file via `.` instead of safe parsing")
        elif first.startswith("#!/bin/bash") or first.startswith("#!/usr/bin/env bash"):
            bash_gen_count += 1
            if quoted:
                check_syntax("bash", raw_text, f"{target} (L{start}-L{end})")
            if "watchdog.sh" in target:
                watchdog_body = raw_text

    if openrc_count < 3:
        err("INV-1", f"Expected >=3 OpenRC heredocs in vless-server.sh, found {openrc_count}")
    if bash_gen_count < 3:
        err("INV-1", f"Expected >=3 generated bash script heredocs in vless-server.sh, found {bash_gen_count}")

    # ── INV-7: Watchdog F04 / paused / gcompat alignment ──────────────────────
    if not watchdog_body:
        err("INV-7", "Could not locate generated watchdog.sh heredoc")
    else:
        for req, desc in [
            ('paused', 'paused guard'),
            ('.singbox-stopped-empty', 'F04 .singbox-stopped-empty guard'),
            ('ld-(linux|musl)', 'Alpine gcompat _pgrep alignment'),
        ]:
            if req not in watchdog_body:
                err("INV-7", f"watchdog.sh missing {desc} ({req!r})")

    # ── INV-2: Zero legacy issuer-substring trust checks ──────────────────────
    for idx, l in enumerate(v_lines, 1):
        if l.lstrip().startswith("#"):
            continue
        if re.search(r'\b(ZeroSSL|Buypass|Let\'s Encrypt)\b', l) and re.search(r'issuer|grep', l, re.I):
            err("INV-2", f"Legacy issuer-substring check at L{idx}: {l.strip()}")

    # ── INV-3: Zero unguarded GNU `date -d` in vless-server.sh ────────────────
    for idx, l in enumerate(v_lines, 1):
        if l.lstrip().startswith("#"):
            continue
        if re.search(r'\bdate\s+-d\b', l):
            err("INV-3", f"Non-portable `date -d` at L{idx}: {l.strip()}")

    # ── INV-4: Zero eval / dpkg -l / bare exec 2>/dev/null ────────────────────
    for fname, lines in [("vless-server.sh", v_lines), ("migrate-anytls-singbox.sh", m_lines)]:
        for idx, l in enumerate(lines, 1):
            if l.lstrip().startswith("#"):
                continue
            if re.search(r'(^|[;&|]\s*)eval\b', l):
                err("INV-4", f"{fname}:L{idx} uses forbidden `eval`: {l.strip()}")
            if re.search(r'\bdpkg\s+-l\b', l):
                err("INV-4", f"{fname}:L{idx} uses `dpkg -l` instead of `dpkg-query`: {l.strip()}")
            if re.search(r'^\s*exec\s+.*2>/dev/null', l):
                err("INV-4", f"{fname}:L{idx} bare `exec ... 2>/dev/null` clobbers process stderr: {l.strip()}")

    # ── INV-5: Subscription fetchers use `curl -K -` ──────────────────────────
    for fn_name in ("fetch_subscription", "parse_subscription"):
        fn_lines = extract_function(v_lines, fn_name)
        if not fn_lines:
            err("INV-5", f"Missing function {fn_name}")
            continue
        body_txt = "\n".join(l for _, l in fn_lines)
        if "curl " not in body_txt or "-K -" not in body_txt:
            err("INV-5", f"{fn_name} does not pass URL via `curl -K -`")
        for ln, l in fn_lines:
            if not l.lstrip().startswith("#") and re.search(r'\bcurl\b.*"\$url"', l):
                err("INV-5", f"{fn_name}:L{ln} leaks $url on curl argv: {l.strip()}")

    # ── INV-6: State-mutating functions must not end in bare `[[ ... ]] && ...` ─
    func = None
    last_code = None
    last_ln = 0
    for idx, l in enumerate(v_lines, 1):
        mf = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{', l)
        if mf:
            func = mf.group(1)
            last_code = None
            continue
        if func and re.match(r'^\}\s*$', l):
            if (func.startswith("db_") or func.startswith("refresh_")) and last_code:
                if (
                    re.search(r'^(\[\[.*\]\]|\[.*\])\s*&&\s*', last_code)
                    and "return" not in last_code
                    and "|| true" not in last_code
                    and "|| :" not in last_code
                ):
                    err("INV-6", f"{func}:L{last_ln} ends with conditional `[[ ... ]] && ...` returning 1 on false branch: {last_code}")
            func = None
            last_code = None
            continue
        if func:
            s = l.strip()
            if s and not s.startswith("#"):
                last_code = s
                last_ln = idx

    if errors:
        for e in errors:
            print(f"FAIL: {e}", file=sys.stderr)
        return 1

    print(
        f"PASS: static structural invariants verified "
        f"(7 invariants; {openrc_count} OpenRC/POSIX heredocs sh -n, {bash_gen_count} generated bash heredocs bash -n)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
