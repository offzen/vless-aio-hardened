# vless-aio-hardened — H15

基于上游 [vless-all-in-one](https://gitlab.com/chil30-group/vless-all-in-one)（Chil30，3.4.10）的第三方加固版服务端脚本。H15 是在 H14-rc.1 完整安全审计基础上完成 Stage 1（P0）与 Stage 2（P1）及关键 P2 修复的正式定版，项目此后进入按需小修的维护态（不再规划 H16 模块化重构）；`readonly VERSION="3.4.10-h15"` 用于旧客户端发现与防降级。

## H15 更新了什么

- **消除命令注入与路由绕过（C-1 / C-2）**：移除 `eval` 与 `source "$CFG/sub.info"`，改用 nameref、参数数组与 `0600` 纯键值读写；强制 Xray/sing-box 私网（含 `::1/128`、`100.64.0.0/10`、`0.0.0.0/8`）与 BitTorrent `block` 规则优先于用户/多 IP/WARP 放行规则。
- **零有效用户彻底撤销与权限加固（H-1 ~ H-4）**：sing-box 零有效用户删除残留 `singbox.json` 并停服；Xray 全协议显式 `users: []` fail-closed；所有凭据与状态文件统一 `0600`、移除 `/tmp/vless-certs-backup`、缓存迁入 `$CFG/cache`、ShadowTLS 密码迁入 `EnvironmentFile=`、Telegram Token 通过 `curl -K -` 隐藏。
- **更新器、迁移脚本与证书/订阅加固（H-5 ~ H-10）**：新增 `--apply-configs` 供更新器新进程重载；校验 Xray `.dgst`；重写 `migrate-anytls-singbox.sh`；Xray 多端口只读渲染不改写 `db.json`；`_is_real_cert` 拒绝自签伪造并在真证书场景关闭 `allowInsecure`/`skip-cert-verify`；清洗外部订阅 YAML/Surge 注入。
- **可靠性与 CI 门禁补强（M-1 ~ M-8 / I-1 ~ I-2）**：修复 `tests/run-ci.sh` 在缺失 `.github/scripts` 时静默跳过全部语法检查的问题，新增 `test-h15-security-hardening.sh` 与 `test-migrate-anytls.sh`。

完整审计见 [docs/AUDIT-H14-RC1.md](./docs/AUDIT-H14-RC1.md)，整改记录与（已决定不实施的）模块化评估见 [docs/REMEDIATION-AND-ARCHITECTURE.md](./docs/REMEDIATION-AND-ARCHITECTURE.md)，完整变更见 [CHANGELOG.md](./CHANGELOG.md)，部署与升级见 [RELEASE-H15.md](./RELEASE-H15.md)，日常管理见 [USAGE.md](./USAGE.md)。

## 交付身份与发布边界

| 项目 | 本次基线（H15） |
|---|---|
| 兼容握手 | `3.4.10-h15` |
| 发布标签 | `v3.4.10-h15`（此前预发布 `v3.4.10-h15-rc.1`） |
| 产品 SHA-256 | `f8606553c3410e6c66c177bb205ee81052681a228a3e704d6ed549fbc060f13a` |
| 上游 H14-rc.1 基线 SHA-256 | `6ea18a9e5af7ca2802ee6982d478d042ffcbcd4108b3a978c26e50aaf77eaa34` |
| 自动化验收 | `tests/run-ci.sh` 全部 9 个门禁（syntax / static / unit×mawk+gawk / Xray / auth / sing-box / stateful-upgrade / Webroot / installer 9 组）+ `check-version-bump.sh`，见 [RELEASE-H15.md](./RELEASE-H15.md) |

校验清单见随包 [SHA256SUMS](./SHA256SUMS) 与 [PROVENANCE.json](./PROVENANCE.json)。部署请校验完整本地包或本仓 tag 制品。

## 支持范围

- 服务端可管理 Xray、sing-box 和独立核心协议，多协议可共存。
- 当前逐用户管理支持：`vless`、`vless-xhttp`、`vless-ws`、`vmess-ws`、`vless-vision`、`trojan`、`socks`、`ss-legacy`、`Hysteria2`、`tuic`、`anytls`。它不等于所有协议都有自动流量计量或配额封禁。
- 面向 Alpine、Ubuntu、Red Hat 系、Debian-like；Alpine 使用 OpenRC，非 Alpine 假定 systemd。不能把未知系统被识别为 Debian 当作受支持证明。
- 交互安装/管理需要 root。安装器不是离线安装，会按协议下载核心并可能安装系统依赖；通用下载器映射 x86_64、aarch64、armv7l，个别核心范围更窄。
- 默认阻断私网目标与 BitTorrent；共享服务、证书、NAT、Tunnel、cron 和卸载副作用请先阅读完整手册。

## 使用本地校验包安装

先将同一套交付文件放到目标主机。不要混用旧文档的校验清单。

```bash
sha256sum -c SHA256SUMS
printf '%s  %s\n' \
  f8606553c3410e6c66c177bb205ee81052681a228a3e704d6ed549fbc060f13a \
  vless-server.sh | sha256sum -c -
chmod +x vless-server.sh
sudo ./vless-server.sh
```

全新主机在菜单选择 `1 安装协议` 并配置所需协议；无参启动会初始化数据库并同步系统脚本及快捷入口。仅 `--help` 不执行这些初始化操作。

## 从旧版手工升级

1. **启动新脚本前**备份现有系统脚本、整个配置目录，包含 DB、派生配置与证书/私钥；如有 Tunnel、cron 等辅助状态一并记录。备份须 root-only，不提交凭据到发行包。
2. 校验同一套 H15 文件与产品 SHA，手工替换脚本后从新进程启动；不要从未核对的在线源获取另一个制品。
3. 使用菜单 `14 重建全部配置`，随后检查实际生成文件、对应服务、监听及真实客户端连接。菜单 14 的完成提示/返回值不是验收收据。
4. updater 的部分失败合同是：三个自动应用步骤全部尝试，返回非零，保留新脚本和 `.bak`，不自动回滚。恢复旧版时须使用启动前完整备份，不只换回脚本。

## 验证结果与限制

run288 验证了 15 项 required：mawk/gawk 各 21 脚本及 mutation/identity、37 条产品策略断言、11 rows/110 动态断言、真实升级 13 条断言；Xray 26.3.27 auth 2/2 与 SS 3/3；固定 sing-box 1.14.4 native/data-plane 3/3；Web root 生命周期；Docker installer 9/9；34 文件 syntax 与 ShellCheck 0.9.0 error gate。required gate 无 SKIP；非 required Release job skipped，未发布。

CI Web 的 service spy 不是宿主真实 Nginx/systemd；Docker 使用固定 leaf pin，不等于公网 CA、强安全沙箱或重启失败自动回滚，也未包含“已删除 alice 直接负向重连”断言。目标主机必须有独立运行验收。

## 交付文件

- [USAGE.md](./USAGE.md)：完整使用手册；[RELEASE-H15.md](./RELEASE-H15.md)：本版本部署/升级手册（[RELEASE-H14.md](./RELEASE-H14.md) 为历史手册）。
- [CHANGELOG.md](./CHANGELOG.md)：更新清单；[FIXES.md](./FIXES.md)：当前修复摘要。
- [SHA256SUMS](./SHA256SUMS)、[PROVENANCE.json](./PROVENANCE.json)：发行包一致性与代码来源。
- 测试及 CI 文件只在私有源码树，不参与此可安装交付包。

版权与主要设计归上游作者；请遵守适用许可与当地法律法规，仅用于合法用途。

## 派生来源

DO NOT EDIT — derived from the exact private source snapshot recorded in PROVENANCE.json. 本去敏可安装包含六个 payload 与两个 identity 文件，不携带私有 Git 历史、测试/CI、WIKI 或运维收据。代码 CI 证据与后补文档哈希分别绑定；此快照尚未晋升 canonical 发布入口。

## Rolling distribution

This is a generated clean-history source distribution. Download `vless-server.sh` and `SHA256SUMS` from this repository’s `master`. The bundled script retains its existing built-in updater; publishing this copy does not change that updater.
