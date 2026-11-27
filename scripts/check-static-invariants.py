#!/usr/bin/env python3
"""Static structural invariant gate for vless-aio-hardened (L1a + L1b).

Enforces class-wide invariants derived from H15-H20 multi-round audits that
ShellCheck on outer Bash files cannot catch on its own:
  INV-1: Embedded heredoc syntax & POSIX gate (OpenRC/POSIX sh -n, no Bashisms
         including `==`/`declare`/`local -a`/`${v//a/b}`, generated Bash scripts
         bash -n including unquoted heredocs, OpenRC env_file loaded before
         command_args without arbitrary `.` execution — comments stripped).
  INV-2: Zero legacy certificate issuer-substring trust checks (R3/E1/R10/ZeroSSL/Buypass/Let's Encrypt).
  INV-3: Zero unguarded GNU/BSD `date -d` / `date --date` / `date -v` across product scripts.
  INV-4: Zero `eval` anywhere (including `if ! eval` and `$(eval ...)`), zero legacy
         `urldecode`, zero untrusted third-party GitHub proxy mirrors (`gh-proxy.com` etc.),
         zero `dpkg -l`, zero bare `exec ... 2>/dev/null` FD-2 clobber.
  INV-5: Subscription fetchers (`_http_fetch_sub_raw`, `fetch_subscription`, `parse_subscription`)
         share `curl -K -` + `--proto '=http,https'` + `--proto-redir '=http,https'` +
         `--max-redirs` + `--max-filesize 2097152` and never leak `$url`/`${url}` on argv.
  INV-6: State-mutating & routing/display functions (`db_*`, `refresh_*`, `gen_*_routing_*`,
         `show_single_protocol_info`) do not end on bare conditional `[[ ... ]] && ...`.
  INV-7: Embedded `watchdog.sh` (non-comment code) enforces `paused` + `.singbox-stopped-empty`
         and aligns Alpine `gcompat` `_pgrep`.
  INV-8: Deep-module consolidation invariants: `_regenerate_proxy_configs` delegates to
         `rebuild_and_reload_{xray,singbox}`, `create_fake_website` uses `_nginx_install_conf`
         and `$CFG/certs/server.crt` (never hardcoded `/etc/vless-reality/certs/`),
         `generate_singbox_config` `anytls` branch uses `_anytls_secure`, and
         `_apply_configs_cli` refreshes `create_server_scripts` and guards `--ensure-singbox`.
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


def strip_comments(lines: list[str]) -> str:
    return "\n".join(l for l in lines if not l.lstrip().startswith("#")) + "\n"


def extract_heredocs(lines: list[str]) -> list[tuple[int, int, str, bool, list[tuple[int, str]]]]:
    """Return list of (start_ln, end_ln, target, quoted_delim, body_lines)."""
    out = []
    i = 0
    while i < len(lines):
        m = re.search(r'cat\s*>\s*([^\s<]+)\s*<<-?\s*([\'"]?)([A-Za-z0-9_]+)\2', lines[i])
        if not m:
            m2 = re.search(r'cat\s*<<-?\s*([\'"]?)([A-Za-z0-9_]+)\1\s*>\s*([^\s<]+)', lines[i])
            if m2:
                target, quoted, delim = m2.group(3), bool(m2.group(1)), m2.group(2)
            else:
                i += 1
                continue
        else:
            target, quoted, delim = m.group(1), bool(m.group(2)), m.group(3)
        start = i + 1
        body: list[tuple[int, str]] = []
        j = i + 1
        while j < len(lines) and lines[j].strip() != delim:
            body.append((j + 1, lines[j]))
            j += 1
        out.append((start, j + 1, target, quoted, body))
        i = j + 1
    return out


def sanitize_unquoted_heredoc(text: str) -> str:
    """Replace outer-Bash parameter expansions in unquoted heredocs with safe tokens."""
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
    heredoc_delim: str | None = None
    for idx, l in enumerate(lines, 1):
        if not in_fn:
            if re.match(rf'^{re.escape(name)}\(\)\s*\{{', l):
                in_fn = True
                out.append((idx, l))
            continue
        out.append((idx, l))
        if heredoc_delim is not None:
            if l.strip() == heredoc_delim:
                heredoc_delim = None
            continue
        m_hd = re.search(r'<<-?\s*[\'"]?([A-Za-z0-9_]+)[\'"]?(?:\s|$)', l)
        if m_hd and not l.lstrip().startswith("#"):
            heredoc_delim = m_hd.group(1)
            continue
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
    watchdog_code_lines: list[str] = []
    for start, end, target, quoted, body in heredocs:
        if not body:
            continue
        first = body[0][1].strip()
        raw_lines = [bl for _, bl in body]
        raw_text = "\n".join(raw_lines) + "\n"
        code_only = strip_comments(raw_lines)
        if first.startswith("#!/sbin/openrc-run") or first.startswith("#!/bin/sh") or "init.d" in target:
            openrc_count += 1
            for ln, bl in body:
                if bl.lstrip().startswith("#"):
                    continue
                if re.search(r'\[\[|\]\]|\(\(|&>|<<<|\bsource\b|\bfunction\b|\bdeclare\b|\blocal\s+-[a-zA-Z]|\[\s+[^]]*==|\$\{[^}]*//', bl):
                    err("INV-1", f"POSIX/OpenRC heredoc {target} (L{ln}) contains Bashism: {bl.strip()}")
            check_text = raw_text if quoted else sanitize_unquoted_heredoc(raw_text)
            check_syntax("sh", check_text, f"{target} (L{start}-L{end})")
            if "${name}" in target and "env_file" in code_only:
                env_pos = code_only.find("env_file")
                args_pos = code_only.find("command_args=")
                if args_pos != -1 and (env_pos == -1 or env_pos > args_pos):
                    err("INV-1", f"OpenRC {target} (L{start}-L{end}) evaluates command_args before env_file")
                if re.search(r'(?:^|[;&|]\s*|then\s+)\.\s+"?\$\{?env_file', code_only, re.M):
                    err("INV-1", f"OpenRC {target} (L{start}-L{end}) executes env_file via `.` instead of safe parsing")
        elif first.startswith("#!/bin/bash") or first.startswith("#!/usr/bin/env bash"):
            bash_gen_count += 1
            check_text = raw_text if quoted else sanitize_unquoted_heredoc(raw_text)
            check_syntax("bash", check_text, f"{target} (L{start}-L{end})")
            if "watchdog.sh" in target:
                watchdog_code_lines = [bl for bl in raw_lines if not bl.lstrip().startswith("#")]

    if openrc_count < 3:
        err("INV-1", f"Expected >=3 OpenRC heredocs in vless-server.sh, found {openrc_count}")
    if bash_gen_count < 3:
        err("INV-1", f"Expected >=3 generated bash script heredocs in vless-server.sh, found {bash_gen_count}")

    # ── INV-7: Watchdog F04 / paused / gcompat alignment (non-comment code) ───
    watchdog_code = "\n".join(watchdog_code_lines)
    if not watchdog_code:
        err("INV-7", "Could not locate generated watchdog.sh heredoc")
    else:
        for req, desc in [
            ('paused', 'paused guard'),
            ('.singbox-stopped-empty', 'F04 .singbox-stopped-empty guard'),
            ('ld-(linux|musl)', 'Alpine gcompat _pgrep alignment'),
        ]:
            if req not in watchdog_code:
                err("INV-7", f"watchdog.sh non-comment code missing {desc} ({req!r})")

    # ── INV-2: Zero legacy issuer-substring trust checks ──────────────────────
    for idx, l in enumerate(v_lines, 1):
        if l.lstrip().startswith("#"):
            continue
        if re.search(r'\b(ZeroSSL|Buypass|Let\'s Encrypt|R3|E1|R10)\b', l) and re.search(r'issuer|grep', l, re.I):
            err("INV-2", f"Legacy issuer-substring check at L{idx}: {l.strip()}")

    # ── INV-3: Zero unguarded GNU/BSD `date -d/--date/-v` in product scripts ──
    for fname, lines in [("vless-server.sh", v_lines), ("migrate-anytls-singbox.sh", m_lines)]:
        for idx, l in enumerate(lines, 1):
            if l.lstrip().startswith("#"):
                continue
            if re.search(r'(?:^|[;&|(`]\s*)date\s+[^|;&\n]*(-d\b|--date\b|-v\s*[-+0-9])', l):
                err("INV-3", f"{fname}:L{idx} uses non-portable date flag: {l.strip()}")

    # ── INV-4: Zero eval / legacy urldecode / untrusted proxies / dpkg -l / bare exec 2>/dev/null
    for fname, lines in [("vless-server.sh", v_lines), ("migrate-anytls-singbox.sh", m_lines)]:
        for idx, l in enumerate(lines, 1):
            if l.lstrip().startswith("#"):
                continue
            if re.search(r'(?:^|[^A-Za-z0-9_$-])eval(?:\s|$)', l):
                err("INV-4", f"{fname}:L{idx} uses forbidden `eval`: {l.strip()}")
            if re.search(r'(?:^|[^A-Za-z0-9_])urldecode\s*(\(\)|\s)', l):
                err("INV-4", f"{fname}:L{idx} uses retired legacy `urldecode` (must use `_urldecode`): {l.strip()}")
            if re.search(r'(gh-proxy\.com|ghps\.cc|gh\.ddlc\.top|ghproxy\.net)', l):
                err("INV-4", f"{fname}:L{idx} references untrusted third-party GitHub proxy: {l.strip()}")
            if re.search(r'\bdpkg\s+-l\b', l):
                err("INV-4", f"{fname}:L{idx} uses `dpkg -l` instead of `dpkg-query`: {l.strip()}")
            if re.search(r'^\s*exec\s+.*2>/dev/null', l):
                err("INV-4", f"{fname}:L{idx} bare `exec ... 2>/dev/null` clobbers process stderr: {l.strip()}")

    # ── INV-5: Subscription fetchers share _http_fetch_sub_raw with full SSRF/DoS guards
    raw_fn = extract_function(v_lines, "_http_fetch_sub_raw")
    if not raw_fn:
        err("INV-5", "Missing canonical _http_fetch_sub_raw function")
    else:
        raw_code = strip_comments([l for _, l in raw_fn])
        for tok in ("curl ", "-K -", "--proto '=http,https'", "--proto-redir '=http,https'", "--max-redirs", "--max-filesize 2097152"):
            if tok not in raw_code:
                err("INV-5", f"_http_fetch_sub_raw missing required guard {tok!r}")
        for ln, l in raw_fn:
            if not l.lstrip().startswith("#") and re.search(r'\bcurl\b.*"\$\{?url\}?"', l):
                err("INV-5", f"_http_fetch_sub_raw:L{ln} leaks $url on curl argv: {l.strip()}")
    for fn_name in ("fetch_subscription", "parse_subscription"):
        fn_lines = extract_function(v_lines, fn_name)
        if not fn_lines:
            err("INV-5", f"Missing function {fn_name}")
            continue
        code = strip_comments([l for _, l in fn_lines])
        if "_http_fetch_sub_raw" not in code:
            err("INV-5", f"{fn_name} must delegate to _http_fetch_sub_raw")
        for ln, l in fn_lines:
            if not l.lstrip().startswith("#") and re.search(r'\bcurl\b', l):
                err("INV-5", f"{fn_name}:L{ln} invokes curl directly instead of _http_fetch_sub_raw: {l.strip()}")

    # ── INV-6: State/routing/display functions must not end in bare `[[ ... ]] && ...`
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
            monitored = (
                func.startswith("db_")
                or func.startswith("refresh_")
                or (func.startswith("gen_") and "_routing_" in func)
                or func == "show_single_protocol_info"
            )
            if monitored and last_code:
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

    # ── INV-8: Deep-module consolidation invariants ───────────────────────────
    regen_code = strip_comments([l for _, l in extract_function(v_lines, "_regenerate_proxy_configs")])
    if "rebuild_and_reload_xray" not in regen_code or "rebuild_and_reload_singbox" not in regen_code:
        err("INV-8", "_regenerate_proxy_configs must delegate to rebuild_and_reload_xray & rebuild_and_reload_singbox")

    fake_code = strip_comments([l for _, l in extract_function(v_lines, "create_fake_website")])
    if "_nginx_install_conf" not in fake_code:
        err("INV-8", "create_fake_website must install Nginx config via _nginx_install_conf")
    if "/etc/vless-reality/certs/" in fake_code:
        err("INV-8", "create_fake_website hardcodes /etc/vless-reality/certs/ instead of $CFG/certs/")

    sb_fn = extract_function(v_lines, "generate_singbox_config")
    sb_code = strip_comments([l for _, l in sb_fn])
    m_anytls = re.search(r'(?ms)anytls\)(.*?);;', sb_code)
    if not m_anytls or "_anytls_secure" not in m_anytls.group(1):
        err("INV-8", "generate_singbox_config anytls branch must validate global certs via _anytls_secure")

    apply_code = strip_comments([l for _, l in extract_function(v_lines, "_apply_configs_cli")])
    if "create_server_scripts" not in apply_code:
        err("INV-8", "_apply_configs_cli must refresh watchdog/NAT scripts via create_server_scripts on upgrade")
    if ".singbox-stopped-empty" not in apply_code or "is_paused" not in apply_code:
        err("INV-8", "_apply_configs_cli --ensure-singbox must guard on is_paused and .singbox-stopped-empty")
    if re.search(r'svc\s+restart\s+vless-watchdog[^\n]*\|\|\s*true', apply_code):
        err("INV-8", "_apply_configs_cli must not silently swallow vless-watchdog restart failure with `|| true`")

    if errors:
        for e in errors:
            print(f"FAIL: {e}", file=sys.stderr)
        return 1

    print(
        f"PASS: static structural invariants verified "
        f"(8 invariants; {openrc_count} OpenRC/POSIX heredocs sh -n, {bash_gen_count} generated bash heredocs bash -n)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
