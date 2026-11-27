# RELEASE-H18 — 静态审计全量安全与恢复整改版

- 兼容握手 / Tag：`3.4.10-h18` / `v3.4.10-h18`
- 产品 SHA-256：`08001f1e9fc911ea2792df7ee0e4341ebb6645efa0192ce26e3f6e78983aefdb`
- 基线：`v3.4.10-h17`（`0d3cb73f56abfb81df529d81ab3de17783d66c04`）
- 详细变更见 [CHANGELOG.md](./CHANGELOG.md)。

## 升级说明

与 H15–H17 兼容：先备份 `/etc/vless-reality/` 与 `/usr/local/bin/vless-server.sh`，再通过菜单 12 或替换脚本后运行 `sudo /usr/local/bin/vless-server.sh --apply-configs`。`db.json` 结构完全向后兼容。

升级后的可见行为变化：

1. **真实 CA 证书校验严格化（F03）**：`_is_real_cert` 与 `_anytls_secure` 不再接受仅含 `R3`/`E1`/`Let's Encrypt` 等 issuer 字符串但未能通过系统信任链、SAN 主机名、有效期或公私钥配对校验的证书。若现有 `server.crt` 缺少中间证书链（非 `fullchain.pem`）或与 `server.key` 不匹配，将按自签兜底处理，请确保 `server.crt` 为完整证书链。
2. **默认 TLS 验证策略（F02）**：真实可信证书下菜单展示的 Surge/Loon/Clash 配置均输出 `skip-cert-verify=false` / `skip-cert-verify: false`；外部订阅节点默认严格校验证书（`false`），仅在输入显式携带 `allowInsecure=1`/`insecure=1`/`skip-cert-verify: true` 时保留 `true`。
3. **sing-box 自动停服恢复（F04）**：全部 sing-box 用户禁用/到期导致自动停服后，重新启用任意有效用户将自动拉起 `vless-singbox`；若管理员此前已手动停服或存在 `$CFG/paused`，仍保持停止状态不越权启动。
4. **外部订阅安全导入与去敏（F01 / F06 / F08）**：外部节点中含控制字符的异常条目会被拒绝而非静默篡改；Clash YAML 导入支持普通 VLESS+TLS、任意键序、flow mapping 与 TUIC 闭环；订阅拉取不再将带 token 的 URL 暴露在 `curl` 进程参数或终端提示中。
5. **流量统计语义说明（R01 / R03）**：Xray `statsquery -reset` 仍属 best-effort 采样而非金融级无损计费；若在 reset 之后发生解析或落盘失败，现在会显式告警采样缺口并返回非 0；控制面同步改为单遍索引 `traffic.pending` 与单次用户状态读取以降低多用户开销。
