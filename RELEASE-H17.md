# RELEASE-H17 — 第二轮外部审计及复审整改版

- 兼容握手 / Tag：`3.4.10-h17` / `v3.4.10-h17`
- 产品 SHA-256：`f66536a0d74e36e90f461293ca9212669e87b492628e93e9b1900ec9aefbd548`
- 基线：内部 H16 审计基线（`3.4.10-h16`，未公开发行）；公开仓上一正式版为 `v3.4.10-h15`（`6356d18e95cf178e77fc6b4d3cc197eb71c08bbc`）
- 变更清单见 [CHANGELOG.md](./CHANGELOG.md)。本文件只记录升级注意事项与有意保留的行为；从 `v3.4.10-h15` 直升的用户请一并查阅 [RELEASE-H16.md](./RELEASE-H16.md)。

## 升级

与 H15/H16 相同：先备份 `/etc/vless-reality/` 与 `/usr/local/bin/vless-server.sh`，再用菜单 12 或手动替换脚本后执行 `sudo /usr/local/bin/vless-server.sh --apply-configs`。`db.json` 结构兼容，可按需回滚到上一版本。

升级后会发生的可见变化：

1. **TUIC 用户的独立 password 会被保留，密码型协议迁移与 HY2 双字段入站/订阅一致**。H16 及更早版本把旧单用户配置迁移成 `users` 表时只存了 uuid；下次重建会把 UUID 当密码。H17 迁移时按协议保留与渲染器同源的生效凭据（`anytls`/`hy2`/`trojan`/`ss-legacy`/`socks` 优先顶层 `password`，`anytls` 与 `tuic` 同步保留 `password` 字段），且 TUIC 渲染时对 uuid 与顶层一致、但缺 password 的用户回退到顶层 password；HY2 在用户同时存在 `uuid` 和 `password` 时，入站与三端订阅统一采用相同的凭据优先级（优先非空 `.uuid`，其次 `.password`）。
2. **`migrate-anytls-singbox.sh` 支持停旧中断恢复与字段级精细回滚**：生产 DB 改库前先校验 `sing-box` 与 `/usr/local/bin/vless-server.sh` 均已就绪（`--dry-run` 缺前置条件仅告警允许预览），并在改库与停旧服务前落盘 `$CFG/.migrate-anytls.state.json` 持久化阶段状态；即使停旧后进程异常中断（新旧服务均已停止），重跑也能按当前 DB 端口继续接管或回滚恢复，绝不误报“无需迁移”，同时已完成的迁移不会擅自拉起管理员有意停用的服务。接管失败回滚改为锁内字段级逆转，仅撤销本次触及的 `xray.anytls` / `singbox.anytls`，保留迁移窗口内其他协议的并发 DB 修改；若同字段已被并发修改则保留 DB 现场与状态标记并先释放半启 `vless-singbox`、拉起 `vless-anytls` 保证业务不断；若拉起旧服务失败则保留状态标记并在下次重跑继承运行态以避免双服务 down 循环。指定备用 `--db` 时只迁移该文件，不触碰任何服务；`--stop-legacy` 仅允许与生产 DB 同用。
3. **菜单 14 / 按端口卸载**：按端口卸载先检查 `db_remove_port` / `unregister_protocol` 返回码，写库失败立即中止且不清理 NAT 规则、不改动配置与服务、不报成功；剩余配置预检失败时保留原配置与运行进程；菜单 14 在失败时提示并保留原配置。
4. **`.reload-pending.xray` / `.reload-pending.singbox` 与同核配置发布锁**：禁用写入在 DB 锁围栏内完成 `pre-arm → 写库 → post-arm`；`rebuild_and_reload_*` 与 `generate_*_config` 通过 `.reload-apply.<core>.lock` 整段串行化「DB 锁围栏快照 → 配置渲染与原子替换 → 服务重启/停服 → 代次匹配确认」，防止并发旧批次覆盖新配置或误清标记，也防止写库后中断漏掉撤销。最后一个 sing-box 用户到期且成功停服清配置后，标记会清除、`--check-expire` 返回 0；停服失败则保留标记并返回 1。`--sync-traffic` 在运行中采集失败、任一用户写库失败或挂起重载失败时均返回 1（Xray 未运行时主动跳过采集返回 0）。
5. **共享 WARP 归属隔离与失败可重试**：区分「本项目使用（`warp_mode=official`）」与「软件包由本项目安装（`warp_official_owned=true`）」。复用主机原有 `warp-cli` 或历史归属未知时，完整卸载与菜单卸载均保留共享 `cloudflare-warp` 软件包与 `warp-svc` 服务，仅清理本项目分流配置；仅在确认卸包成功且 `warp-cli` 已移除后才重置 `warp_official_owned=false` 并报成功，卸载失败时保留状态供重试。
6. **订阅内容只含生效用户且全程事务暂存**：显式用户表下，订阅取第一个仍生效的用户凭据；用户全部禁用 / 过期时该协议不再出现在订阅里（fail-closed）。即使默认保留原有订阅 UUID，重新配置也会先把三份订阅文件生成到独立暂存目录并检查每项返回值，待 `nginx -t` 与重载全部成功后才发布，失败时旧 URL 下的三份文件逐字节保持不变。
7. **`traffic.pending` 日志行带唯一标识且无 200 条重放窗口上限**：`db_update_user_traffic` 使用哈希映射去重并完整保留当前未清批次的全部条目 ID（无论积压超过 200 条多少），历史已退休 ID 仍自动收敛在最近 200 条以控制体积；升级 / 回滚时请勿手工删除 `traffic.pending`。
8. **`--apply-configs` 严格校验 DB 结构**：损坏 JSON 或布尔/非对象核心字段（如 `{"xray":false}`）返回 1 且不改动任何配置与服务；有效空库仍为成功空操作。
9. **安装向导写库失败零配置副作用**：Snell / Snell v5 / NaïveProxy / ShadowTLS 组合协议先将配置写入私有临时文件，待 `register_protocol` 成功提交后才原子发布；写库失败立即删除临时文件并中止安装，不改写已有正式配置、不留残留文件。
10. **TUIC / HY2 / AnyTLS 证书对一致判据**：`_anytls_secure` 与 sing-box 入站渲染器共同要求全局 `server.crt` 与 `server.key` 均存在且命中可信证书域名；缺少全局私钥时入站与链接/Clash/Surge 导出一致回落到独立自签证书并保留不安全校验选项。

## 有意保留的行为 / 未做的事

- 按端口卸载在剩余配置预检失败时，DB 中该端口已删除、运行中的旧配置仍含该实例，直到修复后用菜单 14 重建；脚本会明确提示，不做隐式回滚（回滚会连带 NAT 规则 / 证书 / join 文件，风险更大）。
- 未拆分 `vless-server.sh`（沿用 H15/H16 结论）。
