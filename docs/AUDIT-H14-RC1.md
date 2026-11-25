# vless-aio-hardened `v3.4.10-h14-rc.1` 安全与可靠性审计报告

> **审计基线**：`vless-aio-hardened` `v3.4.10-h14-rc.1`（产品握手 `3.4.10-h14`，原始产品 SHA-256：`6ea18a9e5af7ca2802ee6982d478d042ffcbcd4108b3a978c26e50aaf77eaa34`）。
> **修复状态**：本文档记录 H14 RC1 发现的全部缺陷；其中阶段 1（P0）与阶段 2（P1）核心修复已在本仓库 `3.4.10-h15` 预发布分支（`v3.4.10-h15-rc.1`）中落地并通过自动化回归验证。

---

## 一、核心功能与架构概览

- **主脚本** `vless-server.sh`（25,284 行）：单体 Bash 部署与管理脚本，以 `/etc/vless-reality/db.json` 为事实源派生多核心配置：
  - **Xray**（`vless-reality.service` → `config.json`）：VLESS Reality / XHTTP / CDN / WS / Vision、VMess WS、Trojan / Trojan WS、SOCKS5、SS2022、传统 Shadowsocks（`ss-legacy`）与 localhost Stats API（`127.0.0.1:10085`）。
  - **sing-box**（`vless-singbox.service` → `singbox.json`）：Hysteria2、TUIC v5、AnyTLS。
  - **独立服务**：Snell v4/v5、NaïveProxy（Caddy）、ShadowTLS v3 组合后端。
- **辅助脚本**：`migrate-anytls-singbox.sh`、`check-version-bump.sh`、`tests/run-ci.sh` 及 27 个测试脚本。

---

## 二、审计发现清单（H14 RC1 基线行号）

### Critical（严重）
1. **C-1. 多处 `eval` / `source` / `bash -c` 命令注入**
   - `vless-server.sh:12526`（`_display_sorted_latencies` 对外部订阅节点名执行 `eval`）、`:6207-6252`（`_issue_cert_dns` 对 DNS API 密钥执行 `eval "export $dns_env"`）、`:2197-2201`（`xray_api_query` 对 pattern 执行 `eval`）、`:21792-21797` / `:5625-5630` / `:21490`（无转义写 `sub.info` 后多处 `source`）、`:5948` / `:14207`（`bash -c "echo >/dev/tcp/$ip/$port"`）。
   - **H15 修复**：全部替换为 Bash nameref、显式 `export`、数组执行、键值读取 `_load_sub_info`/`_write_sub_info` 与位置参数校验。
2. **C-2. sing-box 与 Xray 路由顺序错误导致私网 SSRF 与 BitTorrent 拦截被彻底绕过**
   - `vless-server.sh:9141-9221, 9538-9544`（sing-box 将 `auth_user` 用户级路由置于 `sniff` 和 `block` 之前，且将 `sb_default_block_rules` 追加在全局规则和 WARP 私网 `direct` 规则之后）；`:3683-3688`（Xray 多 IP 路由规则插在私网/BT `block` 之前）；两端私网 CIDR 遗漏 `::1/128` 与 `100.64.0.0/10`。
   - **H15 修复**：强制 `[sniff] → [私网(含 ::1/128, 100.64.0.0/10, 0.0.0.0/8, ::/128)/BT block] → [用户级/多 IP 路由] → [全局规则]`，移除 WARP 私网 `direct` 规则。

### High（高危）
3. **H-1. 全禁用/全过期时 `singbox.json` 不清理导致权限吊销失效**（`vless-server.sh:9463-9466, 1963-1982`）→ **H15 已修复**：生成前删除旧 `singbox.json`，零活跃用户时停止运行中的 `vless-singbox`。
4. **H-2. 显式空数组 `users: []` 在非 SS 协议下回退复活顶层旧凭据**（`vless-server.sh:1848-1865, 736-973`）→ **H15 已修复**：统一按 `(.users | type) == "array"` fail-closed。
5. **H-3. 私钥与核心凭据在 `/tmp` 与全局可读目录暴露**（`vless-server.sh:18179-18185` 复制私钥到 `/tmp/vless-certs-backup`、`:11335-11369` wgcf 在 `/tmp` 生成私钥、多处配置文件默认 `0644`、ShadowTLS 密码进 unit 文件、TG Bot Token 进命令行 URL）→ **H15 已修复**：删除 `/tmp/vless-certs-backup`、wgcf 改用 `0700` `mktemp -d`、敏感文件统一 `0600`、ShadowTLS 改用 `0600` `EnvironmentFile`、TG `curl` 改用 stdin `-K -`。
6. **H-4. 固定 `/tmp` 路径符号链接与缓存投毒风险**（`VERSION_CACHE_DIR=/tmp/vless-version-cache`、`/tmp/acme*.log`、`/tmp/acme.sh`、`/tmp/svc_error.log`、版本号允许 `..`）→ **H15 已修复**：版本缓存迁至 `$CFG/cache`（`0700`），所有临时文件改用 `mktemp`，版本号校验拒绝 `..`。
7. **H-5. `do_update()` 在旧进程中执行旧版渲染且单核心必败**（`vless-server.sh:25028-25053, 25091-25092`）→ **H15 已修复**：新增 `--apply-configs` 非交互入口，生产模式替换后启动新进程按已安装引擎条件重建，并透传失败退出码。
8. **H-6. 核心下载缺少完整性校验且 `install_xray` / `install_snell*` 掩盖安装失败**（`vless-server.sh:7858-7862, 9631-9694`）→ **H15 已修复**：Xray 下载校验官方 `.dgst` SHA-256 并修复 `; fix_selinux_context` 吞错；Snell 改用 `curl -fsSLo` 并严格检查解压安装返回码。
9. **H-7. `migrate-anytls-singbox.sh` 参数解析失效、死循环、静默覆写丢数据与断服**（`migrate-anytls-singbox.sh:24-126`）→ **H15 已彻底修复并新增 `tests/test-migrate-anytls.sh`**。
10. **H-8. `generate_xray_config` 多端口渲染期无锁篡改线上 `db.json`**（`vless-server.sh:3616-3633`）→ **H15 已修复**：`add_xray_inbound_v2` 改为内存传参，渲染期 `db.json` 严格只读。
11. **H-9. 多协议分享链接与 Clash 订阅硬编码 `allowInsecure=1` / `skip-cert-verify: true` 且 `_is_real_cert` 可被自签 CN 绕过**（`vless-server.sh:2554-2560, 5741-5845, 21178`）→ **H15 已修复**：`_is_real_cert` 优先 `openssl verify` 并拒绝自签证书（`issuer == subject`）；真实证书匹配 SNI 时关闭不安全跳过校验。
12. **H-10. 外部订阅导出 Clash/Surge 存在 YAML/INI 注入**（`vless-server.sh:20383-20594`）→ **H15 已加固**：增加 `_sanitize_sub_scalar` 剥离 CR/LF 并转义引号/反斜杠。

### Medium / Low / Info
- **M-1**：`_db_safe_write` 增加持锁 PID 记录与死锁回收，同目录 `mktemp` + `0600` 原子替换（**H15 已修复**）。
- **M-2**：`_add_user` 补全 `vmess-ws` 生成 UUID（**H15 已修复**）。
- **M-3**：`sync_time` 移除明文 `http://www.baidu.com` 校时，改为 `timedatectl` / `ntpdate` / HTTPS 兜底（**H15 已修复**）。
- **M-4**：统一 `send_tg_message` 优先读取 `$CFG/telegram.json` 修复过期通知裂脑、`tg_set_config` 失败保护、`--data-urlencode`（**H15 已修复**）。
- **M-5**：修复 `watchdog.sh` 独立协议分类、`hy2-nat.sh`/`tuic-nat.sh` 多端口数组支持、`_gen_user_share_link` 纯 IPv6 兜底与回落端口判断（**H15 已修复**）。
- **M-6**：移除 `_sync_tunnel_config` 与 `add_protocol_to_tunnel` 的错误服务名与裸 `pkill -HUP xray`（**H15 已修复**）。
- **M-7**：修复未定义函数 `install_warp_go`、`generate_singbox_config` 未定义变量 `$p` 与用户级 WARP 缺 outbound、`uninstall_expire_check_cron` 防清空 crontab（**H15 已修复**）。
- **M-8**：`sync_all_user_traffic` 改用 `while IFS= read -r` 且仅在配置生成成功后重启服务（**H15 已修复**）。
- **L-1 ~ L-4**：清理 `_import_akile_nodes` 硬编码凭据、回退 JSON 改用 `jq -cn`、`_auto_update_system_script` 增加防降级与原子替换、`main_menu` 修复全新安装判断、systemd unit 增加最小权限沙箱指令（**H15 已修复**）。
- **I-1 & I-2**：修复 `tests/run-ci.sh` 进程替换吞错漏洞与 `tests/test-manual-user-disable.sh` 键名拼写/同义反复断言，并新增 `tests/test-h15-security-hardening.sh` 与 `tests/test-migrate-anytls.sh`（**H15 已修复**）。
