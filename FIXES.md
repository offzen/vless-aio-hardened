# FIXES — H17

产品 SHA-256：`f66536a0d74e36e90f461293ca9212669e87b492628e93e9b1900ec9aefbd548`（兼容握手：`3.4.10-h17`）。针对第二轮外部审计 16 项缺陷、`034c2853` 复审全部 13 项功能边界（R01–R13）与双核心更新测试缺口（T01），以及 `718c53f`/`ffdc318` 复核新增并发与边角缺陷（N0–N9、D1–D4）的整改摘要见 [CHANGELOG.md](./CHANGELOG.md) 与 [RELEASE-H17.md](./RELEASE-H17.md)：同核心配置生成与重载改为 `.reload-apply.<core>.lock` 整段串行并经 `db.lock` 围栏取快照，闭合旧批次覆盖新配置与 `pre-arm` 误清竞态并清理死代码；旧单用户迁移与统计按协议对齐生效凭据优先级（密码型协议优先顶层 `password` 且 `anytls` 同步落盘 `password`）；AnyTLS 迁移器持久化阶段状态并在冲突/重启失败时恢复旧服务与保留状态继承运行态，续接以 DB 当前端口为准、`--dry-run` 允许预览、`port_listening` 消除 `pipefail` SIGPIPE；区分 WARP 官方客户端归属、以 `dpkg-query` 精准校验卸载结果（避免 `rc` 态误判）并由 `do_uninstall` 统一复用 `uninstall_warp_official`；流量入账完整保留当前未清批次全部 ID 并传播失败退出码；按端口卸载、独立协议安装与沿用 UUID 的订阅重配置均事务化；统一 HY2 双字段凭据、TUIC/HY2/AnyTLS 证书对校验与 `db_validate` 严格对象类型检查。

# FIXES — H16

产品 SHA-256：`7645d99e0b935c31c2462ae3328d0d806c77efe7ee35909f347b9aed97decc16`（兼容握手：`3.4.10-h16`）。针对外部审计 13 项发现的整改摘要见 [CHANGELOG.md](./CHANGELOG.md) 与 [RELEASE-H16.md](./RELEASE-H16.md)。

# FIXES — H15-rc.1

产品 SHA-256：`f8606553c3410e6c66c177bb205ee81052681a228a3e704d6ed549fbc060f13a`（兼容握手：`3.4.10-h15`）。

- **C-1 命令注入清除**：移除 `_display_sorted_latencies`、`xray_api_query`、`_issue_cert_dns` 中的 `eval`；用 `0600` 纯键值 `_load_sub_info`/`_write_sub_info` 替代全部 `source "$CFG/sub.info"`；`/dev/tcp` 探测改用位置参数。
- **C-2 路由顺序与私网/BT 拦截**：移除 WARP 私网 `direct` 放行；sing-box 强制 `sniff → 私网/CGNAT/回环 block → BT block → auth_user → global`；Xray 补全 IPv4/IPv6 保留网段并将多 IP 绑定规则移至 `block` 之后。
- **H-1 / H-2 凭据撤销与 fail-closed**：sing-box 零有效用户删除残留 `singbox.json` 并停止 `vless-singbox`；Xray 全协议显式 `users: []` 不再回退顶层凭据。
- **H-3 / H-4 / L-4 权限与 `/tmp` 加固**：移除卸载私钥复制 `/tmp/vless-certs-backup`；状态/凭据文件统一 `0600` 与原子写；缓存迁至 `$CFG/cache`（`0700`）；ShadowTLS 密码迁至 `EnvironmentFile=` 并加固 systemd 沙箱；Telegram 改用 `curl -K -` 隐藏 Token；拒绝 `..` 版本号穿越。
- **H-5 ~ H-10**：新增 `--apply-configs` 供 `do_update` 新进程应用；Xray `.dgst` 校验；重写 `migrate-anytls-singbox.sh`；Xray 多端口只读渲染；`_is_real_cert` 拒绝自签伪造并按真证书关闭 `allowInsecure`/`skip-cert-verify`；外部节点订阅防注入与零有效用户过滤。
- **M-1 ~ M-8 / L-1 ~ L-3 / I-1 ~ I-2**：修复 DB 死锁自愈、`vmess-ws`、校时、纯 IPv6、Tunnel 重启、硬编码凭据、CI 语法门禁静默跳过与测试拼写错误。

完整审计与修复记录见 [docs/AUDIT-H14-RC1.md](./docs/AUDIT-H14-RC1.md)、[docs/REMEDIATION-AND-ARCHITECTURE.md](./docs/REMEDIATION-AND-ARCHITECTURE.md)、[CHANGELOG.md](./CHANGELOG.md) 与 [RELEASE-H15.md](./RELEASE-H15.md)。
