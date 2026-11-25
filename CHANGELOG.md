# Changelog

## H15 — 正式版（2026-11-25；安全与可靠性深度加固，原 H15-rc.1 2026-11-21）

- 正式版相对 rc.1：产品字节不变；修复 installer E2E 夹具（TEST-NET 靶机 + 回环仍阻断的负向断言）、stateful 测试改用已知 H14 基线、工作流 `fetch-depth: 0` 并覆盖全部门禁、新增 `ci/**` 与 PR 触发、`check-version-bump.sh` 补可执行位、新增 `scripts/refresh-manifest.sh`、清理文档中的 H14 残留。
- 不再规划 H16 模块化重构。


- 兼容握手：`3.4.10-h15`（预发布标签：`v3.4.10-h15-rc.1`）。
- 最终产品 SHA-256：`f8606553c3410e6c66c177bb205ee81052681a228a3e704d6ed549fbc060f13a`。
- 审计基线：H14-rc.1（`6ea18a9e5af7ca2802ee6982d478d042ffcbcd4108b3a978c26e50aaf77eaa34`）。
- 审计报告与整改架构见 [docs/AUDIT-H14-RC1.md](./docs/AUDIT-H14-RC1.md)、[docs/REMEDIATION-AND-ARCHITECTURE.md](./docs/REMEDIATION-AND-ARCHITECTURE.md) 与 [RELEASE-H15.md](./RELEASE-H15.md)。

### 安全与可靠性修复（Stage 1 P0 + Stage 2 P1 + 关键 P2）

1. **消除全部命令注入入口（C-1）**：移除 `_display_sorted_latencies`、`xray_api_query`、`_issue_cert_dns` 中的 `eval`，用纯键值解析 `_load_sub_info`/`_write_sub_info`（`0600`）替代全部 `source "$CFG/sub.info"`，`/dev/tcp` 探测改用位置参数传值。
2. **修复路由顺序与私网/BT SSRF 绕过（C-2）**：移除 WARP 规则中的私网 `direct` 放行；sing-box 强制 `sniff → 私网/CGNAT/回环 block → BT block → auth_user → global`；Xray 补齐 `0.0.0.0/8`、`100.64.0.0/10`、`::/128`、`::1/128` 并将多 IP 绑定路由移至 `block` 之后。
3. **凭据撤销与显式空 `users: []` fail-closed（H-1 / H-2）**：sing-box 零有效用户时删除残留 `singbox.json` 并停止运行中的 `vless-singbox`；Xray 全部多用户协议将显式空 `users: []` 视为零有效用户，不再回退顶层凭据。
4. **凭据文件权限与 `/tmp` 加固（H-3 / H-4 / L-4）**：移除卸载复制私钥到 `/tmp/vless-certs-backup`；所有状态/凭据文件落盘 `0600` 与原子替换；缓存目录迁至 `$CFG/cache`（`0700`）；ShadowTLS 密码迁至 `0600` `EnvironmentFile=` 并为基础 systemd unit 启用 `NoNewPrivileges`/`PrivateTmp`/`ProtectKernel*`；Telegram 改用 `curl -K -` 隐藏 Bot Token 并消除双配置裂脑（M-4）；拒绝 `..` 版本号路径穿越。
5. **更新器新进程应用与下载校验（H-5 / H-6）**：新增 `--apply-configs`，`do_update` 生产态新进程执行配置重建；`main_menu` 更新后立即退出避免继续运行旧代码；`_auto_update_system_script` 增加防降级与原子替换；`_install_binary` 自动校验 Xray `.dgst` 并修复安装退出码掩盖。
6. **重写 `migrate-anytls-singbox.sh` 与只读渲染（H-7 / H-8）**：修复参数解析死循环、多端口无损合并与冲突 fail-closed、去除裸 `pkill`；Xray 多端口渲染不再临时改写 `db.json`。
7. **TLS 证书防伪造与订阅防注入（H-9 / H-10）**：`_is_real_cert` 使用 `openssl verify` 并拒绝 `issuer == subject` 自签伪造；真证书场景下所有 TLS 链接与 Clash/Surge 订阅关闭 `allowInsecure`/`skip-cert-verify`；外部节点转换清洗换行/引号/逗号注入，订阅生成过滤零有效用户实例。
8. **运维可靠性与清理（M-1 ~ M-8、L-1 ~ L-3、I-1 ~ I-2）**：DB 锁死进程回收、`vmess-ws` UUID 生成、移除明文百度 HTTP 校时、纯 IPv6 分享链接、Tunnel 改用 `svc restart vless-reality`、修复未定义函数/变量与硬编码第三方测试凭据、修复 CI 语法门禁静默跳过及多端口禁用测试拼写错误。

### 新增回归测试

- `tests/test-h15-security-hardening.sh`：覆盖 C-1、C-2、H-1~H-4、H-8~H-10、M-3/M-5/M-6/M-7、L-1 的 35+ 条自动化断言。
- `tests/test-migrate-anytls.sh`：覆盖 `migrate-anytls-singbox.sh` 参数解析、dry-run、单端口/多端口合并、冲突 fail-closed 及无裸 `pkill` 断言。
- `tests/test-stateful-upgrade.sh`：支持在无私有 H13 历史的洁净仓库中自动对真实 H14 基线制品执行 H14 → H15 有状态升级回归。

## H14 — 当前验收修订（2026-11-19）

- 兼容握手：`3.4.10-h14`。
- 最终产品 SHA-256：`6ea18a9e5af7ca2802ee6982d478d042ffcbcd4108b3a978c26e50aaf77eaa34`。
- 已验收代码 commit/tree：`90dea0335f646c5d6e69cc7d3ad41919ef2da16f` / `0019ae4fab386547a7fecf6a1a830a4d1080f881`。
- 本次更新文档和本地发行包，不改变已验收产品；新文档不冒充包含在旧 CI commit 内。未改 canonical refs、tag，未执行公开 Release。

### 产品修复

1. **传统 Shadowsocks 多用户**：显式 DB `users` 写入 Xray `settings.clients`，避免未知字段 `settings.users` 被静默忽略、仍只接受顶层密码的问题。
2. **fail closed 与旧库兼容区分**：显式空表、所有用户禁用或过期时不生成该 SS inbound，不回退顶层密码。只有完全不存在 `users` 字段的旧库维持单密码模式。
3. **用户分享链接**：新增 `ss-legacy` URI 分派，按用户所在端口实例读取加密方法；一键展示不包含禁用/过期用户。
4. **partial identifier 负向一致性**：`vless-xhttp-cdn`、`vless-ws-notls`、`trojan-ws`、`ss2022` 拒绝逐用户管理，selector 隐藏、写库前拒绝；不删除既有单用户安装/运行能力。
5. **测试接缝**：source-only 下显式绝对测试目录可重定向 CFG；普通运行保持 `/etc/vless-reality`。接缝不使进入普通菜单变成只读操作。

### 测试与 CI 补强

- 源码 registry ↔ 能力 manifest 双向对账，未知/遗留 identifier 未分类即失败；5 类 mutation 自证。
- 当前 11 个 supported row 参数化动态合同：DB → 菜单/URI → renderer，110 条断言，涵盖 default、second、disabled、expired、零有效用户和多端口隔离；产品拒绝策略 37 条断言。
- 固定 Xray 26.3.27：auth schema/data-plane 2/2、传统 SS 两启用凭据正向及禁用负向 3/3。
- 固定 sing-box 1.14.4：HY2/TUIC/AnyTLS 原生解析，AnyTLS second-active 正向、disabled 负向，native/data-plane gate 3/3。
- 真实 H13 制品 updater success/partial-failure，安装 H14 后 fresh process 真重渲染，13 条断言；不把 instrumented helper 当作真实配置收据。
- mawk、gawk 各完整 21 脚本及 mutation/identity；Web root required 生命周期与 Docker installer 9/9 无 SKIP。
- DinD 仅在自有 private cgroup namespace 执行固定官方初始化，不改共享 runner/宿主 cgroup。旧 run287 的 failure 保留，新授权事务 run288 成功。
- private CI run288：六 required job success；34 文件 syntax / ShellCheck 0.9.0 error gate；15 required verified。非 required Release job skipped，零发布动作。

### deployment host 实际部署

- 现场未发现旧版，因此本次为新装，非旧版原位升级实证。
- 部署原样 H14、固定 Xray 26.3.27，传统 SS `aes-256-gcm` 使用现有防火墙已放行且原先空闲的 TCP 443；真实 `vless-reality.service` active/enabled，NRestarts=0。
- 原生 parser 与两组启用凭据代理至外部 HTTPS HTTP 204 通过；disabled 连接失败，client/server 仍存活；DB 与共享状态、防火墙不漂移。
- 凭据和 URI 仅保存在 deployment host root-only 文件，不包含在发行包。公网入站与外部客户端连接的最终范围见 [RELEASE-H14.md](./RELEASE-H14.md)。

### 保持不变的合同与限制

- updater 部分失败会尝试全部三个 helper、返回非零、保留新脚本与 `.bak`，**不自动回滚**。菜单 14 的完成提示/返回状态不可靠，不能套用 updater 的退出码合同。
- `ss-legacy`、SOCKS5、官方 sing-box 协议没有本项目的有效逐用户自动流量计量/配额封禁；到期与禁用需重新生成并应用配置才影响运行态。
- Web CI 为函数/HTTP/service spy，不等同于宿主真实 Nginx/systemd。Docker 固定 leaf pin 不证明公网 CA、强安全沙箱、自动回滚或已删 alice 的直接负向重连。
- 进入主菜单会初始化/迁移 DB 并同步脚本；必须事先备份。菜单 12 历史固定下载源未在本次 promote，不把其在线字节称为此 SHA。
- 卸载并不完全恢复共享 WARP、cron、DNS64、sysctl、证书或核心二进制，详见 [USAGE.md](./USAGE.md)。

## H13 — 历史基线

产品 SHA-256：`33c953bde77f587cb6601751ea404f92b134be0cc663c2e765685393225dfa88`。

- 来源寻址制品与 updater 部分失败收敛；旧库与 `.bak` 保留、全部 helper 尝试、非零诊断。
- 该历史制品是 H14 real-artifact 升级测试输入；H13 门禁不能代替当前 H14 收据。
- 更早加固与历史记录保留在 [FIXES.md](./FIXES.md)。早期 H14 SHA `e7c52036949398f10391ac3ae3724558995e42cd7be3b4654de21e6c9d44f137` 是历史草案，不是当前交付身份。
