# RELEASE-H19 — H18 审计回归闭环加固版

- 兼容握手 / Tag：`3.4.10-h19` / `v3.4.10-h19`
- 产品 SHA-256：`07dae560f3fd73cfdbe82a72687fd50617a20e0cd771130f8b3f6c9f4bf0b912`
- 基线：`v3.4.10-h18`（`58eb5f0`）/ 公开基线 `v3.4.10-h17`（`0d3cb73`）
- 详细变更见 [CHANGELOG.md](./CHANGELOG.md)。

## 升级说明

与 H15–H18 完全兼容：先备份 `/etc/vless-reality/` 与 `/usr/local/bin/vless-server.sh`，再通过菜单 12 或替换脚本后运行 `sudo /usr/local/bin/vless-server.sh --apply-configs`。`db.json` 结构向后兼容。

## 重要行为变化与迁移提示（从 H17 升级必读）

1. **外部 `hysteria2://`/`hy2://` 与 `anytls://` 节点默认严格校验证书（F02 / D1 迁移提示）**：
   - H18 起所有外部订阅节点（含 `hysteria2`/`hy2`/`anytls`/`tuic`/`trojan`/`vless`/`vmess`）统一默认导出 `skip-cert-verify: false` / `skip-cert-verify=false`，不再像 H17 那样对外部 `hy2`/`anytls` 节点无条件硬编码 `skip-cert-verify: true`。
   - **本脚本自身生成的自签节点不受影响**：`gen_hy2_link`、`gen_anytls_link`、`gen_tuic_link` 在自签场景下已自动附带 `insecure=1` / `allowInsecure=1` / `allow_insecure=1`。
   - **第三方存量自签外链迁移**：若您手动添加或外部订阅导入了使用自签证书、且链接中未显式携带跳过校验参数的 `hysteria2://`/`hy2://`/`anytls://` 节点，请在分享链接查询参数中显式补充 `insecure=1`（或 `allowInsecure=1`），或在来源 Clash YAML 中显式设置 `skip-cert-verify: true`。
2. **完整证书链要求与防误删保护（F03 / D2 / D3）**：
   - `_is_real_cert` 严格校验系统 CA 信任链、SAN 主机名、有效期与公私钥配对，并已清除全脚本残余的 7 处 issuer 子串（`R3`/`ZeroSSL`/`Buypass` 等）回退判定；请确保 `/etc/vless-reality/certs/server.crt` 为完整证书链（`fullchain.pem`）。
   - 若 `server.crt` 因缺少中间链或私钥不匹配未能通过严格校验：Nginx 伪装/订阅配置不再静默降级，会输出明确告警并回退 HTTP 端口；同时 `_handle_standalone_cert`（`force_new=true`）与 `gen_self_cert` 新增非自签证书保护，拒绝删毁有效 CA 证书。
3. **管理员停服 / `paused` 全入口闭环（F04 / D8 / D12）**：
   - `_regenerate_proxy_configs`（路由规则/WARP/菜单 14）与按端口卸载路径现已统一接入 `$CFG/paused` 与运行态守卫：管理员停服或暂停后仅更新磁盘配置，绝不越权拉起 Xray 或 sing-box；仅当 sing-box 因无启用用户自动停服且未处于 `paused` 状态时才自动恢复启动；运行态 `svc restart` 失败时保留 `.singbox-stopped-empty` 标记直至成功重载。
4. **流量计量防丢账与单遍配额检查（R03 / D4 / D5）**：
   - `_sync_all_user_traffic_locked` 在 `traffic.pending` 单遍聚合失败时立即中止并完整保留 `traffic.pending` 待下轮重试，彻底消除整批丢账窗口；配额与告警状态读取改为单次整库 `jq` 扫描（`O(D)`），且读取失败显式告警并传播非 0 退出码。
5. **Clash YAML gRPC 往返、服务器地址校验与丢节点诊断（F06 / D9 / D10 / D11）**：
   - 完整打通 `vless`（TLS / Reality）、`vmess`、`trojan` 的 gRPC `grpc-opts.grpc-service-name` ↔ `serviceName` 往返导入与导出；外部节点 `server` 字段统一经 `_valid_sub_server` 拒绝 `@ ? / #` 及空白等 URI 结构污染字符；Clash YAML 导入跳过非法节点时统一输出明确 stderr 告警。
6. **Alpine OpenRC + `gcompat` 实机与全仓类级自审修复（SA-01–SA-07）**：
   - 修复 Alpine 下通过 `gcompat` 运行 glibc 版 `sing-box` 时主脚本与 `watchdog.sh` 的 `_pgrep` 识别问题，并将 `create_singbox_service()` 的 OpenRC `start_pre()` 改为纯 POSIX `[ -x ... ]`。
   - `watchdog.sh` 补齐 `$CFG/paused` 与 F04 `$CFG/.singbox-stopped-empty` 守卫；`configure_direct_outbound`（修复原停服后漏启 `vless-singbox`）与 `setup_warp_ipv6_chain` 收敛调用 `_regenerate_proxy_configs`；`_sync_tunnel_config` / `add_protocol_to_tunnel` 补齐暂停/运行态守卫与临时文件清理。
   - 用户到期加减与剩余天数改用纯 AWK 公历算法（`_ymd_to_days`/`_days_to_ymd`/`_date_add_days_ymd`），消除 Alpine BusyBox `date -d` 静默失效；修复 `db_set_user_expire_date ""` 等 4 处状态变更函数末行条件码返回 `1` 的缺陷。
   - `parse_subscription` 统一改用 `curl -K -` 隐藏订阅 URL/Token；`parse_proxy_link` 补齐端口范围与 `_valid_sub_server` 校验及旧 `ss://` 冒号密码兼容；OpenRC `_write_openrc()` 将 `STLS_PASSWORD` 非执行 `sed` 读取前置到 `command_args` 之前。
   - 新增静态结构不变量门禁 `scripts/check-static-invariants.py`（L1a+L1b）与全仓自审回归套件 `tests/test-h19-self-audit.sh`。
