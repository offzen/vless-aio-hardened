# FIXES — H15-rc.1

产品 SHA-256：`f8606553c3410e6c66c177bb205ee81052681a228a3e704d6ed549fbc060f13a`（兼容握手：`3.4.10-h15`）。

- **C-1 命令注入清除**：移除 `_display_sorted_latencies`、`xray_api_query`、`_issue_cert_dns` 中的 `eval`；用 `0600` 纯键值 `_load_sub_info`/`_write_sub_info` 替代全部 `source "$CFG/sub.info"`；`/dev/tcp` 探测改用位置参数。
- **C-2 路由顺序与私网/BT 拦截**：移除 WARP 私网 `direct` 放行；sing-box 强制 `sniff → 私网/CGNAT/回环 block → BT block → auth_user → global`；Xray 补全 IPv4/IPv6 保留网段并将多 IP 绑定规则移至 `block` 之后。
- **H-1 / H-2 凭据撤销与 fail-closed**：sing-box 零有效用户删除残留 `singbox.json` 并停止 `vless-singbox`；Xray 全协议显式 `users: []` 不再回退顶层凭据。
- **H-3 / H-4 / L-4 权限与 `/tmp` 加固**：移除卸载私钥复制 `/tmp/vless-certs-backup`；状态/凭据文件统一 `0600` 与原子写；缓存迁至 `$CFG/cache`（`0700`）；ShadowTLS 密码迁至 `EnvironmentFile=` 并加固 systemd 沙箱；Telegram 改用 `curl -K -` 隐藏 Token；拒绝 `..` 版本号穿越。
- **H-5 ~ H-10**：新增 `--apply-configs` 供 `do_update` 新进程应用；Xray `.dgst` 校验；重写 `migrate-anytls-singbox.sh`；Xray 多端口只读渲染；`_is_real_cert` 拒绝自签伪造并按真证书关闭 `allowInsecure`/`skip-cert-verify`；外部节点订阅防注入与零有效用户过滤。
- **M-1 ~ M-8 / L-1 ~ L-3 / I-1 ~ I-2**：修复 DB 死锁自愈、`vmess-ws`、校时、纯 IPv6、Tunnel 重启、硬编码凭据、CI 语法门禁静默跳过与测试拼写错误。

完整审计与修复记录见 [docs/AUDIT-H14-RC1.md](./docs/AUDIT-H14-RC1.md)、[docs/REMEDIATION-AND-ARCHITECTURE.md](./docs/REMEDIATION-AND-ARCHITECTURE.md)、[CHANGELOG.md](./CHANGELOG.md) 与 [RELEASE-H15.md](./RELEASE-H15.md)。
