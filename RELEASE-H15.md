# H15 正式版部署／升级手册（v3.4.10-h15）

## 1. 版本身份

| 项目 | 身份 |
|---|---|
| 上游与兼容握手 | Chil30 3.4.10；`3.4.10-h15` |
| 发布标签 | `v3.4.10-h15`（预发布历史：`v3.4.10-h15-rc.1`，commit `651640f0`） |
| 当前产品 SHA-256 | `f8606553c3410e6c66c177bb205ee81052681a228a3e704d6ed549fbc060f13a` |
| 基线版本（H14-rc.1）产品 SHA-256 | `6ea18a9e5af7ca2802ee6982d478d042ffcbcd4108b3a978c26e50aaf77eaa34` |
| 审计与治理文档 | [docs/AUDIT-H14-RC1.md](./docs/AUDIT-H14-RC1.md)、[docs/REMEDIATION-AND-ARCHITECTURE.md](./docs/REMEDIATION-AND-ARCHITECTURE.md) |

> **发布状态**：H15 正式版 = RC1 修复代码（产品字节不变，SHA 同上）+ 完整历史检出的 CI 工作流 + 修复后的 installer/stateful 测试夹具；保持单文件 `vless-server.sh` 交付合同。项目 2026-11-25 决定不做 H16 模块化重构，此后仅按需小修（任何改动 `vless-server.sh` 必须抬 `VERSION`，由 `check-version-bump.sh` 闸门强制）。

## 2. H15-rc.1 核心修复清单

### P0 严重安全漏洞（全部修复）
1. **消除命令注入路径（C-1）**：
   - `_display_sorted_latencies` 移除 `eval`，改用 Bash nameref（`local -n`）并校验变量名。
   - `_issue_cert_dns` 移除 `eval "export $dns_env"`，改为按 DNS 服务商显式 `export`，敏感密钥改用 `read -rsp`，临时日志改用 `mktemp`。
   - `xray_api_query` 移除 `eval "$cmd"`，改用数组参数直接执行。
   - 新增 `_write_sub_info` / `_load_sub_info`（`0600` 权限、`builtin read` 纯键值对解析），彻底移除全部 4 处 `source "$CFG/sub.info"`。
   - `test_latency` / `_wait_local_port` 校验 IP/端口并通过位置参数传给 `/dev/tcp/$1/$2`。
2. **修复路由规则优先级与私网/BT 绕过（C-2）**：
   - `generate_singbox_config` 移除 WARP 保护规则中的私网 `direct` 放行，强制规则顺序为 `sniff → 私网/回环/CGNAT block → BitTorrent block → 用户路由 → 全局路由`。
   - `generate_xray_config` 移除 WARP 私网 `direct` 放行，在所有默认规则段补齐 `0.0.0.0/8`、`100.64.0.0/10`、`::/128`、`::1/128`，并将多 IP 绑定路由移至 `api`/`block` 规则之后。

### P1 高危安全与可靠性缺陷（全部修复）
3. **凭据撤销与显式空用户表 fail-closed（H-1 / H-2）**：
   - `generate_singbox_config` 渲染前及零有效入站时主动清理残留 `$CFG/singbox.json`；`rebuild_and_reload_singbox` 在配置已清空时主动停止运行中的 `vless-singbox`。
   - `gen_xray_vless_clients` / `gen_xray_vmess_clients` / `gen_xray_trojan_clients` / `gen_xray_socks_accounts` / `db_get_users_stats` 统一改为 `(.users | type) == "array"` 判断，确保显式 `users: []` 不回退顶层凭据；fallback JSON 构造全部改用 `jq -cn`（L-2）。
4. **敏感文件权限与 `/tmp` 加固（H-3 / H-4 / L-4）**：
   - 卸载流程移除将私钥明文复制到 `/tmp/vless-certs-backup` 的逻辑。
   - `db.json`、`config.json`、`singbox.json`、`warp.json`、`telegram.json`、`Caddyfile`、`sub.info`、`*.join`、自签 `server.key` 统一落实 `0600` 与同目录原子替换。
   - `VERSION_CACHE_DIR` 迁入 `$CFG/cache`（`0700`）；`register_warp`、`acme.sh` 与服务错误日志全部改为 `mktemp`/`mktemp -d`。
   - ShadowTLS 密码迁出 systemd `ExecStart` 命令行，改用 `0600` `EnvironmentFile=`；为 Xray / sing-box / 独立服务 unit 添加 `NoNewPrivileges=true`、`PrivateTmp=true`、`ProtectKernel*` 基础沙箱。
   - Telegram 通知通过 `curl -K -` 标准输入传递配置（防止 Bot Token 进入 `ps` 进程参数），并统一优先读取 `$CFG/telegram.json`（修复 M-4 裂脑）。
   - `_install_binary` / `install_snell_v5` 拒绝包含 `..` 的版本号，并在下载失败时清理临时目录。
5. **更新器新进程重载与下载完整性（H-5 / H-6）**：
   - 新增 `--apply-configs` 入口，按需重建已安装的核心配置并重载服务；`do_update` 在生产模式通过新进程执行 `"$script_path" --apply-configs`，同时保持 `VLESS_SOURCE_ONLY=1` 单测兼容。
   - 修复 `main_menu` `do_update` 后继续执行旧进程逻辑（改为 `do_update; exit $?`）及新装分支误判；`_auto_update_system_script` 增加防降级与同目录原子替换。
   - `_install_binary` 支持自动校验 Xray `.dgst` SHA-256；修复 `install_xray` / `install_snell` / `install_snell_v5` 安装错误码被掩盖的问题。
6. **修复 `migrate-anytls-singbox.sh` 与只读渲染（H-7 / H-8）**：
   - 重写 `migrate-anytls-singbox.sh`：修复参数解析死循环、支持多端口数组、保留已有 `singbox.anytls` 无冲突合并、端口冲突 fail-closed、DB 锁 + 原子替换 + `0600` 备份、移除裸 `pkill`、默认通过 `--apply-configs` 自动应用。
   - `generate_xray_config` 多端口渲染改为内存传入 `$single_cfg`，不再临时改写 `db.json`。
7. **TLS 证书校验与订阅注入防护（H-9 / H-10）**：
   - `_is_real_cert` 优先使用 `openssl verify` 校验系统 CA 链，显式拒绝 `issuer == subject` 的自签伪造证书（如伪造 `CN=R3`），并补齐现代 LE 中间证书（`R12/R13/R14/E5/E6/Google Trust Services`）。
   - 真证书场景下，VLESS/VMess/Trojan/HY2/TUIC/AnyTLS 分享链接与 Clash/Surge 订阅统一关闭 `allowInsecure` / `skip-cert-verify`。
   - `external_link_to_clash` / `external_link_to_surge` 增加 `_sanitize_sub_scalar` 清洗换行、引号与逗号注入；`gen_v2ray_sub` / `gen_clash_sub` / `gen_surge_sub` 过滤零有效用户的节点实例。

### 中低危与 CI 工程缺陷修复（M-1 ~ M-8、L-1 ~ L-4、I-1 ~ I-2）
- `_db_safe_write` 目录锁写入 PID 并自动回收已死亡进程的陈旧锁（M-1）。
- `_add_user` 补全 `vmess-ws` UUID 分支（M-2）；`sync_time` 移除明文 HTTP `baidu.com` 校时（M-3）。
- `watchdog.sh` 正确识别 `.xray` 中的独立服务，NAT 脚本支持多端口，`_gen_user_share_link` 支持纯 IPv6 并复用 `_get_master_port`（M-5）。
- `_sync_tunnel_config` / `add_protocol_to_tunnel` 改用 `svc restart vless-reality`，消除裸 `pkill -HUP xray`（M-6）。
- 修复 `install_warp_go` 未定义函数、`$p` 未定义变量、sing-box 单用户 WARP 缺出站、`crontab -l` 误清空风险（M-7）以及 `sync_all_user_traffic` 空格分词与无检查重启（M-8）。
- 清除 `_import_akile_nodes` 中的硬编码第三方 IP 与凭据（L-1）；`db_migrate_to_multiuser` 跳过不支持逐用户管理的 partial 协议（L-3）；`uninstall_specific_protocol` 补全 `naive` `Caddyfile` 与 ShadowTLS `.env` 清理（L-3）。
- 修复 `tests/run-ci.sh` 在缺失 `.github/scripts` 时静默跳过所有测试语法检查的问题（I-1），并修复 `tests/test-manual-user-disable.sh` 多端口键名拼写与残留配置断言（I-2）。

## 3. 校验与安装

```bash
sha256sum -c SHA256SUMS
printf '%s  %s\n' \
  f8606553c3410e6c66c177bb205ee81052681a228a3e704d6ed549fbc060f13a \
  vless-server.sh | sha256sum -c -
chmod +x vless-server.sh
sudo ./vless-server.sh
```

## 4. 从 H14 升级

1. **升级前务必备份**（root-only 目录）：
   ```bash
   umask 077
   backup="/root/vless-pre-h15-$(date -u +%Y%m%dT%H%M%SZ)"
   install -d -m 0700 "$backup"
   cp -a /etc/vless-reality "$backup/"
   cp -a /usr/local/bin/vless-server.sh "$backup/"
   ```
2. 校验完整 H15 文件包后原子替换脚本，并调用新进程应用配置：
   ```bash
   install -m 0755 ./vless-server.sh /usr/local/bin/vless-server.sh.h15-new
   mv -- /usr/local/bin/vless-server.sh.h15-new /usr/local/bin/vless-server.sh
   sudo /usr/local/bin/vless-server.sh --apply-configs
   ```
3. 验证已安装核心配置与服务状态（按实际安装的核心执行）：
   ```bash
   xray run -test -c /etc/vless-reality/config.json
   sing-box check -c /etc/vless-reality/singbox.json
   systemctl is-active vless-reality.service vless-singbox.service
   ```

## 5. 自动化验证与发布流程

在本机环境执行以下验证项并全部通过：
- `bash tests/run-ci.sh syntax`：全部 33 个脚本通过 Bash 语法检查（无遗漏/静默跳过）。
- `bash tests/run-ci.sh unit`：全部单元测试套件通过，含新增的 `tests/test-h15-security-hardening.sh`、`tests/test-migrate-anytls.sh` 及真实 H14→H15 `tests/test-stateful-upgrade.sh`。
- `bash tests/test-webroot-ownership.sh`：独立 user/mount/net/PID namespace 下 `enable → disable → do_uninstall` 全生命周期通过。
- `./check-version-bump.sh`：确认版本号由 `3.4.10-h14` 合法单调递增至 `3.4.10-h15`。
- 注：本机未预装 `shellcheck`、`gawk` 及 Docker/真核心二进制，因此静态 ShellCheck、gawk 及 Xray/sing-box 数据面 E2E 需在完整 CI runner 上进一步复跑。


## 6. 维护与发布流程（小修）

1. 修改后运行 `bash scripts/refresh-manifest.sh` 重算 `SHA256SUMS`、`PROVENANCE.json` 与 `ci.yml` 内产品 SHA（`--check` 仅校验）。
2. 若改了 `vless-server.sh`：先抬 `readonly VERSION=`，再跑 `bash check-version-bump.sh`。
3. 推送到 `ci/<topic>` 分支或开 PR 触发工作流（不污染 `master`）；全部门禁绿后再合入 `master` 并打 `v<VERSION>` tag。
4. 实机 Debian/systemd 与 Alpine/OpenRC 完整安装仍需人工在一次性 VM 上验证。
