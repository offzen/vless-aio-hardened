# RELEASE-H20 — 全维度安全加固、深模块收敛与发布门禁闭环版

- 兼容握手 / Tag：`3.4.10-h20` / `v3.4.10-h20`
- 产品 SHA-256：`4f781c66b7d40721281db85f3f66471643c6cf690f60e8e43bb8664a60a92be6`
- 公开基线：`v3.4.10-h17`（`0d3cb73`）；内部基线：`v3.4.10-h18`（`58eb5f0`）与 `v3.4.10-h19`（`9d64a9b`）均未单独公开发行，从 `v3.4.10-h17` 直升 `v3.4.10-h20` 将一并包含 **H18 + H19 + H20** 全部安全与可靠性整改。
- 详细变更见 [CHANGELOG.md](./CHANGELOG.md)（另可查阅内部基线说明 [RELEASE-H18.md](./RELEASE-H18.md) 与 [RELEASE-H19.md](./RELEASE-H19.md)）。

## 升级说明

与 H15–H19 完全兼容：先以 root-only 权限备份 `/etc/vless-reality/` 与 `/usr/local/bin/vless-server.sh`（如有 Cloudflare Tunnel 一并备份 `/etc/cloudflared/`），再通过菜单 `12` 或手动替换脚本后执行：

```bash
sudo /usr/local/bin/vless-server.sh --apply-configs
```

H20 起 `--apply-configs` 会自动刷新 `/etc/vless-reality/watchdog.sh`（以及 Alpine `/etc/init.d/vless-singbox`），并在 `vless-watchdog` 运行且未暂停时自动重启使其立即获得最新守卫；`db.json` 结构完全向后兼容。

## 从 H17 升级必读（重要行为变化与迁移提示）

1. **外部 `hysteria2://`/`hy2://` 与 `anytls://` 节点默认严格校验证书（H18 F02 / D1）**：
   - 所有外部订阅节点（含 `hysteria2`/`hy2`/`anytls`/`tuic`/`trojan`/`vless`/`vmess`）统一默认导出 `skip-cert-verify: false` / `skip-cert-verify=false`，不再对外部 `hy2`/`anytls` 无条件硬编码跳过证书校验。
   - **本脚本自身生成的自签节点不受影响**（已自动附带 `insecure=1` / `allowInsecure=1` / `allow_insecure=1`）。
   - **第三方存量自签外链迁移**：若外部订阅或手工外链使用了自签证书且链接未显式携带跳过参数，请在链接查询串补充 `insecure=1`（或 `allowInsecure=1`），或在来源 Clash YAML 中显式设置 `skip-cert-verify: true`。
2. **严格密码学证书校验与防误删保护（H18 F03 / H19 D2–D3 / H20 SA-10）**：
   - `_is_real_cert` / `_anytls_secure` 统一执行系统 CA 链验证（`openssl verify -purpose sslserver`）、SAN 主机名、有效期与公私钥配对校验，彻底移除全部 issuer 子串回退；`generate_singbox_config` 的 `anytls` 分支现与 `hy2`/`tuic` 一致复用 `_anytls_secure`，全局证书异常时安全回退独立自签证书不再拖垮 `sing-box check`。
   - 请确保 `/etc/vless-reality/certs/server.crt` 为完整证书链（`fullchain.pem`）。
3. **移除 `wgcf` 非可信第三方代理镜像并强化全核心供应链校验（H20 SEC-1 / SEC-3 / SEC-4）**：
   - `download_wgcf` 移除 `gh-proxy.com`、`ghps.cc`、`gh.ddlc.top`、`ghproxy.net` 等第三方代理镜像，统一改为直连官方 GitHub Release 并经无 `eval` 的 `_install_binary` 执行 SHA-256 digest、ELF 魔数与原子安装校验。
   - `install_snell`、`install_snell_v5`、`install_naive`（Caddy）、`install_cloudflared` 补齐 `--max-time 900`、ELF 校验及 GitHub API `digest` 校验（并移除 `install_naive` 以 root 直接执行未验签产物的探针）。
   - 全脚本彻底清零 `eval`（`_install_binary` 改为白名单 `case` 分发、`_save_join_info` 改为直接数组参数调用）与旧 `urldecode`。
4. **生命周期、流量配额、ACME 续期与订阅解析全链路收敛（H20 SA-08–SA-14 / SEC-2）**：
   - `rebuild_and_reload_{xray,singbox}` 统一内建 `is_paused`、F04 `.singbox-stopped-empty`、`.reload-apply.<core>.lock` 串行锁与 `.reload-pending` 代次确认，并收口 `_regenerate_proxy_configs`、`uninstall_specific_protocol` 与 `do_install_server` 替换主协议路径。
   - `--apply-configs` 经临时文件原子刷新 `watchdog.sh`/NAT 脚本与 Alpine `/etc/init.d/vless-singbox`（写失败不截断现存脚本，重启运行中 `vless-watchdog` 失败显式告警并传播非零退出码，`migrate-anytls-singbox.sh` 在端口接管成功后仅对辅助脚本刷新异常告警而不误回滚）；`--ensure-singbox` 与三条 ACME 签发路径（HTTP-01 / DNS-01 / 手动 DNS）统一接入守卫式 reload（含路径控制字符拒绝、POSIX 单引号转义与 `--install-cert` 失败传播），绝不拉起已停服/暂停/空用户停服实例。
   - 过滤 `statsquery` 空闲零值计数，流量同步阶段 2 配额检查失败原子落盘 `.quota-check-pending`（落盘失败保留 `traffic.pending`），首次失败下轮立即补扫，连续失败按 60s–3600s 指数退避并具备时钟回拨上限保护，杜绝清日志后超额用户漏禁。
   - `fetch_subscription` 与 `parse_subscription` 收敛至统一 `_http_fetch_sub_raw`（`curl -K -` + `--proto '=http,https'` + `--proto-redir '=http,https'` + `--max-redirs 5` + 2 MiB 上限）；`_urldecode` 与 `_strict_base64_decode_noctrl` 对非法/残缺 `%`、非法 Base64 及控制字符（含尾随 LF/NUL）fail-closed 返回错误，统一 `parse_proxy_link` 查询参数解码；修复 Clash YAML 单/多元素块序列与 flow 数组 `alpn` 无损往返导出（Clash YAML 多元素数组、Surge 取主 ALPN）、方括号 IPv6 `[2001:db8::1]` 规范化、旧/明文 `ss://` 密码含 `@` 及畸形 userinfo 告警、以及 `_date_add_days_ymd` 偏移越界校验。
   - `create_fake_website` 改用 `$CFG/certs/server.crt` 并统一经 `_nginx_install_conf` 原子安装（同分区暂存保护冲突订阅配置）。
5. **CI/发布门禁与真实变异自检加固（H20 REL-1–REL-4 / SA-15 / C20-5–C20-6）**：
   - `check-version-bump.sh` 修复多提交分支打 tag（`--base 0000...`）时仅匹配有效 `refs/tags/v*` 对比最高前置 tag 并统一十进制比较；`scripts/check-public-hygiene.py` 扩展扫描待发提交范围的提交元数据、标签附注与历史补丁；`.github/workflows/release.yml` 私有仓全作业零配额跳过不假绿；`scripts/check-static-invariants.py` 扩展至 8 项静态结构不变量；`tests/run-ci.sh` 强制校验静态不变量并抬升 `MIN_UNIT_TESTS=29`；重写 `test-h19-audit-regression.sh` M6/M8/M9/M10 为真实函数体变异证伪并新增 `tests/test-h20-hardening.sh` 与文档-版本一致性契约校验。
