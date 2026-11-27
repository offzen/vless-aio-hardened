# FIXES — H20

产品 SHA-256：`4f781c66b7d40721281db85f3f66471643c6cf690f60e8e43bb8664a60a92be6`（兼容握手：`3.4.10-h20`）。面向公开基线 H17（`0d3cb73`）的累计完整发行版（一并包含内部基线 H18/H19、H20 全维度编码安全审计整改及 D20/C20 异构复核闭环），摘要见 [CHANGELOG.md](./CHANGELOG.md) 与 [RELEASE-H20.md](./RELEASE-H20.md)：移除 `download_wgcf` 非可信第三方代理并全核心收口超时/摘要/ELF 校验；全仓清零 `eval` 与旧 `urldecode`（`_urldecode` 与 `_strict_base64_decode_noctrl` 对裸/残缺 `%`、非法 Base64 及 `%00..%1F`/`%7F` 控制字符 fail-closed，统一 `parse_proxy_link` 查询参数解码）；抽出 `_http_fetch_sub_raw` 统一防 SSRF/分块 OOM/Token 泄漏；`--apply-configs` 原子刷新 `watchdog.sh`/NAT 脚本与 Alpine init（写失败不截断现存脚本，重启失败告警并传播退出码，AnyTLS 迁移器区分端口接管与辅助刷新）并为 `--ensure-singbox` 及三条 ACME 签发路径补齐 `paused`/F04 守卫、路径单引号安全转义与 `--install-cert` 失败传播；`anytls` 对齐 `_anytls_secure`；过滤 `statsquery` 零值空闲计数，流量阶段 2 失败原子持久化 `.quota-check-pending`（落盘失败保留 `traffic.pending`）并在连续失败时按 60s–3600s 指数退避且防时钟回拨冻结；修复 Clash YAML 单/多元素块序列与 flow 数组 `alpn` 无损导出、方括号 IPv6、旧/明文 `ss://` `@` 密码与畸形 userinfo 告警及日期偏移越界；`create_fake_website` 改 `$CFG` + `_nginx_install_conf` + 同分区订阅配置暂存保护；`_regenerate_proxy_configs`/`uninstall_specific_protocol`/`do_install_server` 全量收敛至持锁 `rebuild_and_reload_{xray,singbox}`；加固 `check-version-bump.sh`（严格 `v*` tag 与十进制比较）、`check-public-hygiene.py`（待发提交历史与邮箱扫描）及 `release.yml`；升级 8 项静态不变量门禁、真实函数体变异测试、文档-版本一致性契约校验及 `tests/test-h20-hardening.sh`。

# FIXES — H19

产品 SHA-256：`07dae560f3fd73cfdbe82a72687fd50617a20e0cd771130f8b3f6c9f4bf0b912`（兼容握手：`3.4.10-h19`）。针对 H18（`58eb5f0`）静态回归复核确认缺陷（D2–D5、D7–D12 及 D1 升级迁移说明）、Alpine OpenRC/`gcompat` 实机缺陷及全仓类级自审新发现缺陷（SA-01–SA-07）的闭环修复摘要见 [CHANGELOG.md](./CHANGELOG.md) 与 [RELEASE-H19.md](./RELEASE-H19.md)：`_sync_all_user_traffic_locked` 在聚合失败时立即早退保留 `traffic.pending` 防整批丢账，配额/告警状态改为单次整库 `jq` 扫描（`O(D)`）并传播读取错误；`_regenerate_proxy_configs`、`uninstall_specific_protocol`、`configure_direct_outbound`（修复漏启 `vless-singbox`）、`setup_warp_ipv6_chain`、`_sync_tunnel_config`、`add_protocol_to_tunnel` 及 `watchdog.sh` 全入口统一接入 `paused`/运行态/`.singbox-stopped-empty` 守卫且运行态 `svc restart` 成功后才清标记；`_handle_standalone_cert` 与 `gen_self_cert` 增加非自签证书防误删保护，`create_fake_website` 改用完整域名+私钥 `_is_real_cert` 并在降级 HTTP 时明确告警，彻底清零全脚本残余的 7 处 issuer 子串判定；补齐 Clash YAML ↔ 分享链接 gRPC `serviceName` 往返支持（VLESS/Reality/VMess/Trojan）、`_valid_sub_server` URI 结构字符拒绝、丢节点告警诊断、`parse_subscription` `curl -K -` 脱敏与 `parse_proxy_link` 主机/端口/冒号密码加固；修复 Alpine `gcompat` 主脚本与 `watchdog.sh` `_pgrep`、OpenRC `start_pre()` POSIX 语法与 `_write_openrc` `STLS_PASSWORD` 加载顺序、纯 AWK 公历日期替代 GNU `date -d` 及 4 处状态函数末行条件退出码泄漏；移除死代码 `_sanitize_sub_scalar`；新增 `scripts/check-static-invariants.py`（7 项静态结构不变量门禁）、`tests/test-h19-audit-regression.sh`（M5–M10）与 `tests/test-h19-self-audit.sh`（SA-01–SA-07）。

# FIXES — H18

产品 SHA-256：`08001f1e9fc911ea2792df7ee0e4341ebb6645efa0192ce26e3f6e78983aefdb`（兼容握手：`3.4.10-h18`）。针对 H17（`0d3cb73`）静态审计全部 8 组确定实现缺陷（F01–F08）及 R01/R03 可靠性与控制面性能改进的整改摘要见 [CHANGELOG.md](./CHANGELOG.md) 与 [RELEASE-H18.md](./RELEASE-H18.md)：外部订阅全字段 YAML 双引号序列化与控制字符 fail-closed 拒绝（同时修复 VLESS Reality `publicKey`/`shortId` 导出 `null`）；菜单与外部 Clash/Surge 统一 TLS 验证策略（默认校验、不复用本机证书推断外部节点）；`_is_real_cert` / `_anytls_secure` / HY2 统一为全链密码学+SAN+有效期+公私钥配对校验并彻底移除 issuer 子串回退；sing-box 区分无用户自动停服与管理员手动停服，重新启用用户时自动拉起；`_nginx_install_conf` 同目录备份校验前置并禁止无备份删原配置；Clash YAML 导入统一单一导出器、区分 VLESS TLS 与 Reality、支持任意键序与 flow mapping 及 TUIC 全链路闭环；Debian `install_deps` 改用 `dpkg-query` 严格安装态与命令检查；`fetch_subscription` 经 `curl -K -` 隐藏订阅 URL 并在提示/列表脱敏；流量采集显式告警 reset 后采样缺口并改为单遍日志索引。

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
