# 修复计划与模块化重构评估（H15 → H16）

## 一、分阶段实施路线

### 阶段 1（P0 安全止血）—— 已在 `v3.4.10-h15-rc.1` 完成
- **1A（命令注入）**：消除 `_display_sorted_latencies`、`_issue_cert_dns`、`xray_api_query` 中的 `eval`；移除 `sub.info` 的 `source` 执行；加固 `test_latency` 与 `_wait_local_port`。
- **1B（路由防绕过）**：固定 sing-box/Xray 路由顺序为 `sniff → 私网(含 ::1/128, 100.64.0.0/10)/BT block → 用户/多 IP 路由 → 全局规则`。
- **1C（吊销与 fail-closed）**：修复 sing-box 全禁用时残留旧 `singbox.json` 并主动停服；修复 VLESS/VMess/Trojan/SOCKS5 空 `users: []` 回退顶层凭据。
- **1D（凭据与 `/tmp` 加固）**：删除 `/tmp/vless-certs-backup`、隔离 wgcf 与版本缓存至 `0700` 目录、敏感文件统一 `0600`、ShadowTLS 密码迁入 `EnvironmentFile`、TG Token 改为 `curl -K -` stdin 传递。
- **1E（迁移脚本与 CI 门禁）**：彻底修复 `migrate-anytls-singbox.sh` 与 `tests/run-ci.sh` 假绿漏洞、补齐 `test-h15-security-hardening.sh` 与 `test-migrate-anytls.sh`。

### 阶段 2（P1 可靠性与供应链）—— 已在 `v3.4.10-h15-rc.1` 核心落地
- 新增 `--apply-configs` 使 `do_update` 在生产模式通过新进程条件重建配置；修复 `_auto_update_system_script` 防降级与 `main_menu` 新装判断。
- 修复 `install_xray` 掩盖解压失败并加入官方 `.dgst` SHA-256 校验；修复 `install_snell*` 缺少 `-f` 及未检查解压结果。
- `generate_xray_config` 改为内存传参不再写库；`_db_safe_write` 增加持锁 PID 死锁回收。
- `_is_real_cert` 升级为 `openssl verify` + 拒绝自签 CN 伪造，真实证书下关闭 `allowInsecure`/`skip-cert-verify`；外部订阅增加 `_sanitize_sub_scalar` 防注入。
- 修复 `_add_user` 遗漏 `vmess-ws`、Telegram 过期通知裂脑、明文 HTTP 校时、`watchdog.sh` 独立协议分类、多端口 NAT 脚本、IPv6 分享链接、裸 `pkill -HUP xray`、`install_warp_go` 未定义调用、`_import_akile_nodes` 硬编码凭据以及 systemd 基础沙箱。

### 阶段 3（H16+ 架构演进：源码模块化 + 单文件构建）— 评估结论：2026-11-25 决定不实施，H15 定版收官
当前 `vless-server.sh` 规模已超过 2.5 万行，长期维护成本与回归风险高，但老客户端在线升级强依赖单文件交付契约。建议 H16 采用 **“源码模块化 + 构建期拼装单文件产物（Build-to-Single-File）”**：

```text
src/
  00-header.sh           # 常量、安全原语（锁/原子写/转义/校验）
  10-db.sh               # 唯一 DB 读写层（flock + 同目录原子替换）
  20-users.sh            # 统一用户模型、配额、到期与过滤合同
  30-render-xray.sh      # 纯函数：只读 DB -> 输出 Xray JSON
  31-render-singbox.sh   # 纯函数：只读 DB -> 输出 sing-box JSON
  40-certs-acme.sh       # openssl verify 与 ACME 证书管理
  50-network-routing.sh  # WARP、链式代理、分流与 NAT 端口跳跃
  60-subscription.sh     # Nginx 订阅与多用户状态同步导出
  70-services.sh         # systemd/OpenRC/Watchdog/Tunnel
  80-updater.sh          # 下载校验与新进程 apply 事务
  90-cli-tui.sh          # 交互菜单与 CLI 入口
scripts/build.sh         # 按序组装 dist/vless-server.sh + SHA256SUMS + PROVENANCE.json
```

**长期边界**：若后续演进至复杂配额计量、API 化运维或多核心编排，建议将 **DB 管理 + 配置渲染 + 订阅生成** 重写为静态编译的轻量 Go CLI，Shell 仅保留安装引导与服务编排薄层。
