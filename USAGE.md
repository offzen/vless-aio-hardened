# vless-aio-hardened 使用手册

> 当前 H20 产品：`3.4.10-h20`，SHA-256 `4f781c66b7d40721281db85f3f66471643c6cf690f60e8e43bb8664a60a92be6`（公开仓上一正式版 H17：`f66536a0d74e36e90f461293ca9212669e87b492628e93e9b1900ec9aefbd548`；内部审计基线 H18/H19 未单独公开发行，直升 H20 一并包含 H18、H19 与 H20 全部整改；源自 H14-rc.1 `6ea18a9e5af7ca2802ee6982d478d042ffcbcd4108b3a978c26e50aaf77eaa34` 安全加固）。
>
> 请使用已核验本地包或本仓 tag 制品；无参启动会初始化/迁移 DB 并同步系统脚本，旧版必须先备份；仅 `--help` 与 `--apply-configs` 按其明确契约执行。新版变更及从 H17 升级必读见 [RELEASE-H20.md](./RELEASE-H20.md)、[RELEASE-H19.md](./RELEASE-H19.md)、[RELEASE-H18.md](./RELEASE-H18.md) 与 [CHANGELOG.md](./CHANGELOG.md)。

## 目录

1. [项目与支持范围](#1-项目与支持范围)
2. [安装前准备](#2-安装前准备)
3. [安装与升级](#3-安装与升级)
4. [配置文件架构](#4-配置文件架构)
5. [菜单与协议速查](#5-菜单与协议速查)
6. [用户、配额与到期](#6-用户配额与到期)
7. [AnyTLS 与证书](#7-anytls-与证书)
8. [命令行与常见操作](#8-命令行与常见操作)
9. [验证与排障](#9-验证与排障)
10. [更新与卸载边界](#10-更新与卸载边界)
11. [H20 验收基线](#11-h20-验收基线)

## 1. 项目与支持范围

`vless-aio-hardened` 是上游 [`vless-all-in-one`](https://gitlab.com/chil30-group/vless-all-in-one)（Chil30，基线 3.4.10）的第三方加固版服务端脚本。`3.4.10` 仅说明上游基线；本次交付以本手册顶部 H20 SHA 和随包校验清单为准，不将未更新的在线滚动分支当作相同字节。

脚本按实际运行核心管理协议：

| 核心 | 协议 |
|---|---|
| Xray | VLESS Reality、Reality + XHTTP、VLESS WS + TLS、VMess WS、VLESS-XTLS-Vision、Trojan、Shadowsocks、SOCKS5 |
| sing-box | Hysteria2、AnyTLS、TUIC v5 |
| 独立服务 | Snell v4/v5、NaïveProxy，以及可选 ShadowTLS 组合 |

主要加固包括：

- 主要用户/协议数据库变更通过 `_db_safe_write` 采用唯一临时文件、目录锁和原子替换，并阻止非删除操作意外清空用户；脚本中的其它 JSON 写入不都经过这条路径。
- Xray 与 sing-box 默认加入私网和 BitTorrent 出站拦截；sing-box 显式执行 sniff 以识别协议。
- AnyTLS 的实际入站由 sing-box 生成，支持多用户、多端口、到期/禁用过滤、用户分享链接及真实证书。
- 菜单更新替换脚本后会尝试重新生成 Xray / sing-box 配置并重载服务；任一自动应用步骤失败时，新脚本与备份会保留、更新流程返回非零并要求人工核对/重建。无论返回值如何，操作后仍须人工验证。
- 生成 Xray 配置前会先建立日志目录，创建失败立即停止；测试日志根路径必须是绝对路径。
- Xray 用户增删只走数据库驱动的完整重建；NAT 清理只删除数据库精确归属且已启用的 v4/v6 端口跳跃规则；卸载不按裸进程名终止共享实例；Hysteria2/TUIC 证书只在协议最后一个端口删除后清理；主菜单不隐式同步 Tunnel。
- 通过通用 `_install_binary` 路径下载核心时，先检查 URL 是否仍含未替换的变量占位符，避免把模板错误伪装成网络 404；其它自定义下载路径不受此守卫覆盖。

“单文件脚本”不表示离线安装：安装过程会先安装通用系统依赖，再按所选协议下载相应核心或组件。

## 2. 安装前准备

1. **系统、架构与权限**：脚本明确识别 Alpine、Red Hat 系和 Ubuntu；其它系统（包括 Debian，也包括不受支持者）都会被默认当作 Debian，安装前必须确认 `apt` 等兼容性，不能把检测成功当作受支持证明。Alpine 路径使用 OpenRC，所有非 Alpine 路径均假定 systemd。交互式主菜单要求 root。下载启动脚本前需已有 `wget`（或等价下载工具）。通用下载器只映射 `x86_64`、`aarch64`、`armv7l`，个别组件支持范围可能更窄。本文命令统一使用 `sudo`。
2. **备份**：已有部署先备份整个 `/etc/vless-reality/`，尤其是 `db.json`、`certs/`、`cert_domain` 和私钥。不要把备份提交到仓库；完整目录也包含通知、订阅、WARP 等辅助状态。root crontab 和 CF Tunnel 的 `/etc/cloudflared/` 不在该目录内，需另行备份或记录。
3. **端口与网络**：准备所选协议需要的端口、域名、DNS 和防火墙规则。脚本可能安装并启用 cron；首次配置端口跳跃、BBR、WARP、Nginx/Caddy、订阅与 CF Tunnel 需选择相应功能。脚本不会仅因无参数进入主菜单就同步已有 Tunnel；协议变更时仍可能显式同步相关配置。端口跳跃清理依据数据库中的精确启用记录删除本项目对应的 IPv4/IPv6 规则。
4. **依赖安装**：启动和安装流程会检查并安装一组通用依赖，而不是只安装所选协议专用包；根据发行版会使用 `apk`、`apt-get` 或 `yum` 安装 `curl`、`jq`、`openssl`、解压/网络/DNS 工具、二维码工具、CA 证书和 cron 等，并尝试启用 cron 服务。
5. **纯 IPv6 判定**：依赖检查前若脚本无法 ping 通 `8.8.8.8`，会按纯 IPv6 环境处理：首次备份 `/etc/resolv.conf` 为 `/etc/resolv.conf.bak`，然后写入 DNS64 解析器。若环境只是禁用了 ICMP，应先审查这一行为。
6. **证书**：脚本内置的 ACME 申请流程需要相应公网连通条件，常见 HTTP-01 场景要求 80 端口可达。不能满足时，不要把域名存在等同于证书已签发。
7. **可选节点导入**：`_import_alice_nodes()` 中的 `<SET-ME-*>` 是环境占位符，普通安装不依赖它。占位符未配置时函数会在任何数据库修改前退出；如要启用该预设，仍须先审查并配置节点地址与凭据。
8. **旧版 AnyTLS 迁移**：本仓提供独立迁移脚本 `migrate-anytls-singbox.sh`（支持 `--dry-run`、多端口数组无损合并、端口冲突 fail-closed、`0600` 备份与 `--apply-configs` 自动应用）。执行前仍须先备份 `db.json` 与 `/etc/vless-reality/`。

## 3. 安装与升级

### 3.1 全新安装

将本次完整校验包传入目标主机，在包目录执行：

```bash
sha256sum -c SHA256SUMS
printf '%s  %s\n' \
  4f781c66b7d40721281db85f3f66471643c6cf690f60e8e43bb8664a60a92be6 \
  vless-server.sh | sha256sum -c -
chmod +x vless-server.sh
sudo ./vless-server.sh
```

制品必须来自已核验的 H20 代码 commit、`v3.4.10-h20` tag 或本地交付包；使用滚动 `master` 下载时务必按上面命令核对 SHA-256。包文件清单见 `SHA256SUMS` 与 [RELEASE-H20.md](./RELEASE-H20.md)。

无参数运行当前文件进入主菜单时，脚本会尝试把它复制到 `/usr/local/bin/vless-server.sh`，并创建 `/usr/local/bin/vless` 与 `/usr/bin/vless` 软链接；首次协议安装成功后也会再次确保快捷命令存在。只运行 `--help` 等 CLI 分支不会触发这一步。进入菜单后选择 `1 安装协议`；成功后可运行：

```bash
sudo vless
sudo /usr/local/bin/vless-server.sh --help
```

### 3.2 已有部署：菜单更新的历史行为

**此节说明现有更新器。** 菜单 12 固定公开滚动 `master`；H20 晋升到该源后，更新器取得的即为本修订，并自动与远端 `SHA256SUMS` 交叉核对，但仍须按上文备份并核对。需要最可控的路径时按 3.3 节手工替换。

旧编号版本仍可能按 release/tag 版本号判断，首次迁移需要手工替换；已经采用滚动模式的安装，其更新器行为如下：

1. 在启动新脚本前备份 `/etc/vless-reality/`；已有 CF Tunnel 时同时备份 `/etc/cloudflared/`。无参数启动会在任何菜单选择和更新询问前初始化/迁移数据库并同步系统脚本；仅进入菜单不会自动同步 Tunnel、改写 Xray/cloudflared 配置或重启/HUP相关服务。不能先启动再补备份。
2. 运行 `sudo vless`，选择 `12 检查脚本更新`。
3. 脚本下载远程 `master` 制品并与 `SHA256SUMS` 核对；版本不低于本地且字节不同时才询问更新。
4. 替换前检查下载内容的 Bash shebang 与语法，先在同目录生成并逐字节核对 `.bak` 备份（备份失败即中止，不替换现役脚本）；替换成功后通过新进程执行 `--apply-configs` 重建并重载 Xray 与 sing-box，并同步刷新 `/etc/vless-reality/watchdog.sh` 与 Alpine `/etc/init.d/vless-singbox`。
5. 自动应用失败时流程返回非零并明确提示，已验证的新脚本与 `.bak` 备份均保留。无论是否报错，更新后仍建议执行第 9 节的配置、服务与连接验证。

### 3.3 已有部署：手动替换

H20 可使用手工替换路径：启动前备份现役脚本和配置目录，再按 3.1 校验本地交付包；替换 `/usr/local/bin/vless-server.sh` 后执行 `sudo /usr/local/bin/vless-server.sh --apply-configs`（同时刷新核心配置与 `watchdog.sh`/Alpine init）或进入菜单选择 `14 重建全部配置`，并执行第 9 节验证。菜单 14 与 `--apply-configs` 统一经持锁 `rebuild_and_reload_{xray,singbox}` 在重载前执行预检（`xray run -test` / `sing-box check`）并遵守 `paused`/F04 守卫；任一核心预检失败时保留原配置、不重启该核心并返回非零提示。

## 4. 配置文件架构

默认目录：

```text
/etc/vless-reality/
├── db.json        # 用户、端口、配额、到期与路由的管理数据
├── config.json    # 有 Xray 协议时，由 db.json 生成
├── singbox.json   # 有 sing-box 协议时，由 db.json 生成
├── cert_domain    # 已记录的 ACME 证书域名（存在时）
└── certs/         # 证书与私钥；协议可有独立子目录
```

核心规则：

- `db.json` 是生成 Xray / sing-box 配置时协议、用户和路由的主要数据源；证书、通知、订阅、WARP、Tunnel 等辅助状态另有文件或系统配置。`config.json` 和 `singbox.json` 是派生产物。
- 直接修改派生配置会在下一次重建时被覆盖。
- 手动修改 `db.json` 后，普通服务 restart 不会重新生成配置；使用主菜单 `14 重建全部配置`，并另行确认生成器与服务实际成功。
- 对数据库或证书做任何人工修改前先备份；重建后继续做语法、服务和数据面验证。

## 5. 菜单与协议速查

### 已安装协议时的主菜单

| 选项 | 功能 |
|---:|---|
| 1 | 安装新协议（多协议共存） |
| 2 | 核心版本管理（菜单标签为 Xray / sing-box；子菜单也管理 Snell v5） |
| 3 | 卸载指定协议 |
| 4 | 用户管理（多用户、流量、通知） |
| 5 | 查看协议配置 |
| 6 | 订阅服务管理 |
| 7 | 管理协议服务 |
| 8 | 分流管理 |
| 9 | CF Tunnel（Argo） |
| 10 | BBR 网络优化 |
| 11 | 查看运行日志 |
| 12 | 检查脚本更新 |
| 13 | 完全卸载 |
| 14 | 重建全部配置（实际重建 Xray / sing-box JSON 并重启这两个服务；须另行验收） |
| 0 | 退出 |

未安装协议时只显示 `1 安装协议`、`12 检查脚本更新` 和 `0 退出`。

**服务与协议卸载风险：**

- 菜单 7 的“停止/重启所有服务”、卸载 Hysteria2/TUIC，以及完全卸载都会执行端口跳跃清理。清理只根据 `db.json` 中 `hop_enable=1` 的精确协议/端口/范围，成对删除对应 IPv4/IPv6 `PREROUTING` 与 `OUTPUT` 规则；数据库缺失或字段无效时不删除任何规则。操作后仍应核对本项目规则是否清干净。
- 卸载单个 Xray/sing-box 协议或端口时，先校验数据库删除成功，再通过持锁的 `rebuild_and_reload_{xray,singbox}` 在临时文件渲染并预检剩余协议配置（`xray run -test` / `sing-box check`）；预检失败时保留原配置与运行中服务，不会拖停其余正常端口，预检通过后才原子替换并重载一次（尊重 `paused` 与 F04 空用户自动停服状态）。操作前仍建议备份 `db.json` 与派生配置。
- 仅在 Hysteria2 或 TUIC 的最后一个端口（或全部端口）删除后清理该协议共享证书目录；删除单个端口且仍有保留端口时证书继续保留。

### 安装协议菜单

| 选项 | 协议 |
|---:|---|
| 1 | VLESS + Reality |
| 2 | VLESS + Reality + XHTTP |
| 3 | VLESS + WS + TLS |
| 4 | VMess + WS |
| 5 | VLESS-XTLS-Vision |
| 6 | Trojan |
| 7 | Hysteria2 |
| 8 | Shadowsocks（随后选择 SS2022 或传统版） |
| 9 | SOCKS5 |
| 10 / 11 | Snell v4 / v5 |
| 12 | AnyTLS |
| 13 | TUIC v5 |
| 14 | NaïveProxy |
| 0 | 返回 |

## 6. 用户、配额与到期

主菜单 `4 用户管理` 提供查看、添加、删除、配额、流量重置、启用/禁用、到期、用户路由、分享链接、流量同步与通知等操作，但当前存在以下硬边界：

- Xray 用户添加/删除只更新 `db.json` 后执行一次完整配置重建，不再运行会覆盖全部 VLESS inbound 并强制 Vision flow 的二次补丁。操作后仍须检查重建返回值、目标用户与其它协议的 inbound。
- 当前 manifest 的 11 个逐用户 supported identifier 是：`vless`、`vless-xhttp`、`vless-ws`、`vmess-ws`、`vless-vision`、`trojan`、`socks`、`ss-legacy`、`Hysteria2`、`tuic`、`anytls`。每项均完成 DB→菜单/URI→配置凭据及多端口隔离的动态合同。逐用户管理支持不代表具备自动流量计量。
- 传统 Shadowsocks 的显式 DB `users` 表映射到 Xray `settings.clients`，只纳入启用且未过期用户。显式空表或零有效用户不生成该 inbound，不回退顶层密码；完全没有 `users` 字段的旧安装才保持单密码。字段必须是 `clients`，`settings.users` 会被静默忽略。
- `vless-xhttp-cdn`、`vless-ws-notls`、`trojan-ws`、`ss2022` 拒绝逐用户管理：selector 隐藏，`db_add_user` 写前拒绝且 DB 不变；不影响既有单用户安装/运行。独立服务 identifier 也不纳入此多用户模型。
- sing-box 用户管理走全量重建，但其用户级路由只支持 `direct`、`warp` 和 `chain`；菜单即使显示 `balancer`，也不会生成相应规则。
- TUIC 用户级 URI 已读取匹配用户的 `password` 或 `uuid`，不再错用顶层密码；当前新增用户默认使用自身 UUID 作为 password，显式用户密码按实际用户配置核对。

重要边界：

- 具有 email 标识客户端的 VLESS / VMess / Trojan 可使用 Xray Stats API 做按用户流量统计；SOCKS5 与 Shadowsocks 不在这套按用户计量/配额执行范围内。**只有流量同步实际执行成功时**才会累计数据库用量并在达到配额后禁用用户。添加用户时设置非零配额会尝试安装同步 cron；之后修改已有用户配额不会自动安装，因此仍须在 `4 → 9` 核对或启用 cron 与同步。
- 当前脚本安装的官方 sing-box 二进制没有 per-user V2Ray API 统计能力，因此 Hysteria2、AnyTLS、TUIC **不能按用户自动计量流量，也不能因流量配额自动封禁**。数据库可以保存配额值，但它不是已生效的计量收据。
- sing-box 用户的到期日期和启用/禁用状态只在配置生成时过滤；在菜单中修改到期日期后，需用菜单 14 重建（到期检查任务在真正过期后也会禁用并重建）。到期日当天仍有效，脚本从次日才判定过期，并在下一次检查（默认 03:00）禁用。这与流量配额是两套不同机制。
- 多端口协议会为各端口生成独立 inbound；添加用户的旧入口仍写入首个端口实例，不代表已提供任意端口选择 UI。当前 VMess/Trojan 等生成器按目标端口过滤，supported 动态合同证明第二端口只保留本端口有效凭据，用户 URI 按明确端口匹配。异常时先检查 `db.json` 数组结构，再使用菜单 14 重建并逐端口验收。

## 7. AnyTLS 与证书

AnyTLS 的实际 inbound 与服务由 sing-box 管理。当前安装路径仍会额外下载未用于 inbound 服务的 `anytls-server` / `anytls-client`；实际运行服务仍是 sing-box。安装 AnyTLS 时，脚本会在 `/etc/vless-reality/certs/anytls/` 生成独立自签证书；SNI 变化时会重新生成。

配置生成器默认使用这份独立自签证书；当全局 `server.crt`/`server.key` 通过统一严格校验 `_anytls_secure "$sni"`（底层调用 `_is_real_cert` 执行系统 CA 链验证 `openssl verify -purpose sslserver`、`-untrusted` 中间链、`-verify_hostname` SAN 主机名匹配、`-checkend 0` 有效期及公私钥配对检验，且 `cert_domain` 与 SNI 一致）时，会与 Hysteria2 / TUIC 一致切换到全局真实证书；若全局证书缺少中间链、过期或私钥不匹配，则安全回退独立自签证书，避免拖垮 `sing-box check`。

完成证书配置后使用菜单 14 重建，并核对 inbound：

```bash
jq -r '.inbounds[] | select(.type=="anytls") | {tag,listen_port,tls:.tls.certificate_path}' \
  /etc/vless-reality/singbox.json
```

随后检查服务状态并重新生成客户端链接。分享链接、Clash/Surge 订阅以及入站证书选择现已统一共用 `_anytls_secure` / `_is_real_cert` 密码学校验判据（已彻底移除旧版基于 `R3`/`E1`/`ZeroSSL` 等 issuer 子串的回退判定）：仅当全局 `server.crt` 为完整证书链（`fullchain.pem`）且通过系统 CA 信任链、SAN、有效期与私钥配对校验时，才关闭 `allowInsecure` / `skip-cert-verify`；自签兜底仍自动附带跳过验证参数。外部导入的第三方 `hysteria2`/`anytls` 节点默认输出 `skip-cert-verify: false`（见 [RELEASE-H20.md](./RELEASE-H20.md) 迁移说明）。

## 8. 命令行与常见操作

脚本入口实际支持以下参数：

```bash
sudo /usr/local/bin/vless-server.sh --help
sudo /usr/local/bin/vless-server.sh --show-traffic
sudo /usr/local/bin/vless-server.sh --sync-traffic
sudo /usr/local/bin/vless-server.sh --check-expire
sudo /usr/local/bin/vless-server.sh --check-expire --notify
sudo /usr/local/bin/vless-server.sh --setup-expire-cron
```

- `--sync-traffic` 会读出并清零 Xray API 计数器，先把增量追加到 `$CFG/cache/traffic.pending` 日志，再写回数据库；写库失败的增量留在日志里下一轮重试，不会丢失。重启 Xray 前也会先把内存计数落盘（重启会清零计数器）。达到配额时会先持久化待重载标记、禁用用户、发送通知并重建/重启 Xray；重置流量、修改配额或重新启用用户会重新武装配额告警与封禁。Xray 未运行时会主动跳过采集并返回 0；若运行中采集失败、任一用户写库失败或挂起重载仍未成功，均返回非 0。
- `--check-expire` 会检查并禁用过期用户，且总会尝试发送三日内临期提醒；附加 `--notify` 时还会发送过期禁用通知。写库前先持久化代次待重载标记；若所有 sing-box 协议均无启用用户且已清配置并成功停服，标记会清除并返回 0；若重建、重载或停服失败则保留标记并返回非 0，由下一轮自动重试。
- `--setup-expire-cron` 与 cron 条目统一指向 `/usr/local/bin/vless-server.sh`（不存在时用当前脚本的绝对真实路径），不会再写入相对路径；已存在但路径或间隔不同的旧条目会被替换。`--setup-expire-cron` 安装失败时返回非 0，执行后仍建议核对 root crontab 中的精确命令。
- 流量统计 cron 通过菜单 `4 用户管理 → 9 流量统计设置` 管理；脚本**没有**可调用的 `--setup-traffic-cron` 命令行分支。设置配额时的自动安装也可能失败，不能只凭数据库里已有配额值判断限额已生效。
- 生产 CLI 退出码约定：`--apply-configs`（含 `--ensure-singbox`）、`--sync-traffic`、`--check-expire`、`--setup-expire-cron` 均会在数据库损坏、写库/采集失败或挂起重载未收敛时返回非 0；自动化或 cron 仍建议结合日志、数据库、crontab 与服务状态联合核对。
- 流量/到期 cron 的检测、替换和删除按完整参数词（`--sync-traffic` / `--check-expire`）匹配，不验证脚本路径或所有权；读取 crontab 失败（非「没有 crontab」）时脚本拒绝改写。操作前仍建议备份 root crontab。

| 操作 | 菜单路径 |
|---|---|
| 添加用户 | `4 → 2 → 选择协议` |
| 查看用户分享链接 | `4 → s → 选择协议` |
| 设置到期 | `4 → e → 选择协议` |
| 启用/禁用用户 | `4 → 6 → 选择协议` |
| 修改 `db.json` 后应用 | `14` |
| 为 Xray / sing-box 协议安装第二端口 | `1 → 选择同一协议 → 1 添加新端口实例`；选择 `2` 会覆盖指定现有端口，独立服务协议走重新安装流程 |
| 查看配置 | `5` |
| 查看日志 | `11` |

## 9. 验证与排障

### 配置与运行验证

只对实际安装的核心运行对应检查：

```bash
xray run -test -c /etc/vless-reality/config.json
sing-box check -c /etc/vless-reality/singbox.json
```

还要核对对应服务状态、监听端口和真实客户端连接。配置语法通过不等于服务已启动，也不等于数据面已验证。

### 常见问题

**修改配置后不生效**

确认修改的是 `db.json`，然后使用菜单 14 重建；不要只改派生 JSON 或只重启服务。菜单完成提示不是充分证据，还要验证生成文件和服务。

**手动下载新脚本后配置仍旧**

启动本地新脚本会尝试同步系统脚本，但不会因这一步自动重建既有配置。选择菜单 14，再验证服务。

**AnyTLS 仍显示不安全验证**

核对 `/etc/vless-reality/cert_domain`、AnyTLS SNI、以及 `/etc/vless-reality/certs/server.crt` 是否包含完整中间链（`fullchain.pem`）且与 `server.key` 公私钥配对、未过期并被系统 CA 信任库验证通过（可用 `openssl verify -purpose sslserver` 自检）。自签兜底保留 `allowInsecure` 是预期行为。

**sing-box 配额没有自动封禁**

这是当前官方 sing-box 二进制缺少 per-user 流量统计能力的边界，不是到期/禁用过滤失效。不要把数据库里的配额值当作已计量结果。

**多端口菜单存在但无法连接**

检查每个端口是否同时出现在 `db.json` 与生成的 inbound 中，重建配置，再核对监听与防火墙。

**Xray 配置生成失败且日志目录不存在**

脚本在生成配置前创建日志目录并检查返回值。失败时修复目录或权限；不要跳过错误继续启动 Xray。`VLESS_TEST_LOG_ROOT` 仅用于隔离测试，设置时必须是绝对路径。

**二进制下载 URL 中仍有变量**

通用 `_install_binary` 下载路径在发起请求前拒绝包含 `$VAR` 或 `${VAR}` 的未替换 URL，并指出占位符。其它自定义下载函数不受此守卫覆盖；命中时应修复 URL 生成逻辑，而不是当成普通网络故障反复重试。

## 10. 更新与卸载边界

### 在线更新

脚本版本和下载源固定到本仓：

- 仓库：`https://github.com/offzen/vless-aio-hardened`
- 脚本：`https://raw.githubusercontent.com/offzen/vless-aio-hardened/master/vless-server.sh`

菜单 12 会下载远程 `master` 制品，比较本地与远程 SHA-256，并与同源 `SHA256SUMS` 交叉核对，在替换前检查 Bash shebang 和语法。脚本内语义化 `VERSION` 用于兼容发现和拒绝降级；公开正式发版制品同时随 GitHub Release 提供 `SHA256SUMS` 与官方 Sigstore 构建证明（`gh attestation verify`）。需要完整发行包一致性时应按第 3.1 节核对 `SHA256SUMS`。替换完成后的三个自动应用步骤会全部尝试；任一步骤失败时返回非零、保留新脚本与 `.bak`，仍须按第 9 节复核。

### 完全卸载

菜单 `13 完全卸载` 需要再次确认，主要行为包括：

- 按 `vless-*` 通配符停止/禁用并删除服务文件，不验证文件所有权；管理员自建的同名前缀 unit 必须提前备份或改名。脚本不按裸进程名全局终止 `xray`、`sing-box`、Snell、AnyTLS 或 ShadowTLS，只通过本项目 `vless-*` 服务边界停止；
- 对 WARP 官方客户端区分「本项目使用（`warp_mode=official`）」与「由本项目安装（`warp_official_owned=true`）」：仅当数据库明确记录软件包由本项目安装时，才会断开、停用 `warp-svc` 并卸载 `cloudflare-warp` 软件包；主机原有复用或历史归属未知的官方客户端均会保留软件包与共享服务，仅清理本项目分流集成与 WGCF 配置；
- 会按 `vless-*` / `xhttp-cdn*` 文件名模式删除 Nginx 配置，不验证文件所有权；共享 Nginx 不会自动 stop/disable，管理员自建的同名前缀文件必须提前备份或改名；
- 会按通用服务名停止、禁用并删除活动的 `fake-web.service`，不验证是否由本项目创建；仅 Web placeholder 文件的删除会核对身份和内容，管理员修改过的页面会保留；
- 存在 `certs/` 时会保留证书目录，并一并保留 `cert_domain` 以便下次复用；没有 `certs/` 时会删除整个配置目录；有证书时，卸载只按扩展名清理部分生成文件，`role`、`traffic_interval`、日志、辅助脚本、订阅状态等其它文件也可能留在目录中；
- Xray、sing-box、Snell 等核心二进制通常保留，脚本会显示进一步删除命令。若卸载开始前能由数据库、join 文件或项目 `Caddyfile` 证明本项目用过 NaïveProxy，脚本只通过 `vless-naive` 服务边界停止；`/usr/local/bin/caddy` 始终保留，确认无其它 unit/站点引用后才能手动删除；
- 完全卸载会移除本项目的流量同步与到期检查 cron 条目；仍请在卸载后用 `crontab -l` 核对没有残留 `--sync-traffic` / `--check-expire` 任务；
- 不会自动停止或卸载菜单 9 配置的 cloudflared / CF Tunnel，也不会删除 BBR 的 sysctl 配置；这些功能应先在各自菜单中单独停用、删除或恢复；
- 不会恢复 DNS64 对 `/etc/resolv.conf` 的修改，也不会删除或回退 `/etc/sysctl.d/99-vless-dualstack.conf` 与实时 `net.ipv6.bindv6only=0`；须另行核对和恢复；
- 完全卸载会按卸载前数据库中的精确 `hop_enable=1` 记录成对清理本项目 IPv4/IPv6 端口跳跃规则，不再枚举或删除第三方 REDIRECT 规则；数据库缺失或记录无效时不会猜测清理。

“完全卸载”并不等于删除所有证书、核心二进制或主机级副作用。执行前备份配置、root crontab、iptables/ip6tables、相关 sysctl 与共享服务状态；如需连证书和整个配置目录一并删除，必须按脚本最后显示的命令另行操作。

## 11. H20 验收基线

H20 产品 SHA-256 为 `4f781c66b7d40721281db85f3f66471643c6cf690f60e8e43bb8664a60a92be6`（握手 `3.4.10-h20`；公开仓上一正式版 H17 为 `f66536a0d74e36e90f461293ca9212669e87b492628e93e9b1900ec9aefbd548`；内部审计基线 H18/H19 未单独公开发行），相对 H14-rc.1（`6ea18a9e…eaa34`）累计完成初始审计 P0/P1/关键 P2、H16/H17 外部审计与复审，以及 H18–H20 全维度安全加固、类级同类自审与深模块收敛全部整改，详见 [docs/AUDIT-H14-RC1.md](./docs/AUDIT-H14-RC1.md)、[docs/REMEDIATION-AND-ARCHITECTURE.md](./docs/REMEDIATION-AND-ARCHITECTURE.md)、[RELEASE-H18.md](./RELEASE-H18.md)、[RELEASE-H19.md](./RELEASE-H19.md) 与 [RELEASE-H20.md](./RELEASE-H20.md)。

CI 入口为 `bash tests/run-ci.sh <mode>`，模式：`syntax`、`static`（ShellCheck error 级 + 强制 8 项 `scripts/check-static-invariants.py` 静态结构不变量门禁）、`unit`（`--awk-bin mawk|gawk` 各一遍，含真实函数体变异自检与文档一致性契约校验）、`xray-e2e`、`auth-e2e`、`singbox-e2e`（固定 Xray 26.3.27 / sing-box 1.14.4）、`stateful-upgrade`（H13/H14 → H20 真实制品升级）、`webroot-e2e`、`installer-e2e`（Docker 10 组生命周期，无网络、TEST-NET 靶机，同时断言回环仍被阻断与真实 `--apply-configs` 入口）。工作流使用完整历史检出（`fetch-depth: 0`），否则 `stateful-upgrade` 会因找不到历史基线而失败。

边界：CI Web 只覆盖函数/HTTP/service spy；Docker 为私有 leaf pin，不证明公网 CA、强沙箱或自动回滚；干净 Debian/systemd 与 Alpine/OpenRC 的真实 init 全生命周期未自动化；sing-box 协议、`ss-legacy`、SOCKS5 无逐用户流量计量。

仓库哈希清单（`SHA256SUMS`）在任何文件变更后用 `bash scripts/refresh-manifest.sh` 一键重算；正式发布通过不可变 `v*` tag 触发 `.github/workflows/release.yml`（`preflight → workflow_call ci.yml → Sigstore 证明与 Release 资产上传`）。仅文档变更不要求重复已绿的产品门禁。

安装只需要 `vless-server.sh` 与校验文件；`tests/` 与 `.github/` 属于仓库自身的测试与 CI 基础设施，不参与安装，也不随发行制品提供。

本仓为第三方补丁副本，版权与主要设计归原项目作者；请遵守适用许可与当地法律法规，仅用于合法用途。
