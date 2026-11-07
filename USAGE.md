# vless-aio-hardened 使用手册

> 适用安装器：本仓 `master` 分支中的 `vless-server.sh`
>
> 本仓采用滚动 `master` 发布，不使用独立公开版本号。本手册描述当前脚本的实际行为；脚本与手册冲突时，以当前脚本为准并提交修正。

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

## 1. 项目与支持范围

`vless-aio-hardened` 是上游 [`vless-all-in-one`](https://gitlab.com/chil30-group/vless-all-in-one)（Chil30，基线 3.4.10）的第三方加固版服务端脚本。`3.4.10` 仅说明上游基线；本仓交付以 `master` 当前制品为准。

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
- 菜单更新替换脚本后会尝试重新生成 Xray / sing-box 配置并重载服务；操作后仍须人工验证。
- 生成 Xray 配置前会先建立日志目录，创建失败立即停止；测试日志根路径必须是绝对路径。
- Xray 用户增删只走数据库驱动的完整重建；NAT 清理只删除数据库精确归属且已启用的 v4/v6 端口跳跃规则；卸载不按裸进程名终止共享实例；HY2/TUIC 证书只在协议最后一个端口删除后清理；主菜单不隐式同步 Tunnel。
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
8. **迁移边界**：本仓没有独立的旧版 AnyTLS 迁移脚本。迁移旧部署时以 `db.json` 备份和当前菜单功能为准，不要照抄不存在文件的命令。

## 3. 安装与升级

### 3.1 全新安装

简易安装：

```bash
wget -O vless-server.sh https://raw.githubusercontent.com/offzen/vless-aio-hardened/master/vless-server.sh
chmod +x vless-server.sh
sudo ./vless-server.sh
```

需要完整性校验时，同时下载完整发行包：

```bash
base=https://raw.githubusercontent.com/offzen/vless-aio-hardened/master
for file in vless-server.sh README.md USAGE.md SHA256SUMS PROVENANCE.json; do
  wget -O "$file" "$base/$file"
done
sha256sum -c SHA256SUMS
chmod +x vless-server.sh
sudo ./vless-server.sh
```

`master` 是滚动分支；可复现留档应同时保存下载时的仓库 commit ID、全部五个文件和校验结果。

无参数运行当前文件进入主菜单时，脚本会尝试把它复制到 `/usr/local/bin/vless-server.sh`，并创建 `/usr/local/bin/vless` 与 `/usr/bin/vless` 软链接；首次协议安装成功后也会再次确保快捷命令存在。只运行 `--help` 等 CLI 分支不会触发这一步。进入菜单后选择 `1 安装协议`；成功后可运行：

```bash
sudo vless
sudo /usr/local/bin/vless-server.sh --help
```

### 3.2 已有部署：菜单更新

旧的编号版本必须先按 3.3 节手动替换；它仍使用 release/tag 版本号判断，无法自动发现不带版本号的滚动 `master` 制品。完成首次迁移后，后续才可使用本节菜单更新。

1. 在启动新脚本前备份 `/etc/vless-reality/`；已有 CF Tunnel 时同时备份 `/etc/cloudflared/`。无参数启动会在任何菜单选择和更新询问前初始化/迁移数据库并同步系统脚本；仅进入菜单不会自动同步 Tunnel、改写 Xray/cloudflared 配置或重启/HUP相关服务。不能先启动再补备份。
2. 运行 `sudo vless`，选择 `12 检查脚本更新`。
3. 脚本下载远程 `master` 制品并比较 SHA-256；字节不同时才询问更新。release 和 tag 不参与判断。
4. 替换前检查下载内容的 Bash shebang 与语法，并尝试写入同路径 `.bak` 备份；替换成功后会尝试重建、重载 Xray 与 sing-box。
5. 重建/重载的返回值没有形成可靠的整体成功判据；即使界面显示更新完成，也必须执行第 9 节的配置、服务与连接验证。

### 3.3 已有部署：手动替换

这是旧编号版本迁移到滚动 `master` 的必经路径。重新执行 3.1 的完整发行包下载、校验和无参数启动命令。进入主菜单时脚本会尝试创建或同步 `/usr/local/bin/vless-server.sh` 及快捷方式，但不会因此重建既有派生配置。随后选择 `14 重建全部配置`，并执行第 9 节验证：菜单 14 会依次尝试生成配置和重启服务，但内部失败不会形成可靠的最终失败状态。

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
- 卸载单个 Xray/sing-box 协议或端口会先停止对应共享核心并删除整份派生配置，再为所有剩余协议重建；重建失败时共享服务不会恢复，所有剩余协议会中断。操作前备份 `db.json`、派生配置并安排停机/回滚。
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
- SOCKS5、Shadowsocks（SS2022 与传统版）和独立服务协议不支持这套有效的多用户添加：前两者当前生成器仍读取顶层凭据，独立服务协议不使用该用户模型。
- sing-box 用户管理走全量重建，但其用户级路由只支持 `direct`、`warp` 和 `chain`；菜单即使显示 `balancer`，也不会生成相应规则。
- TUIC 新增用户的菜单分享链接会使用错误的顶层密码；修复前不要直接使用该子用户链接，当前服务端为新增用户使用其自身 UUID 作为 password。

重要边界：

- 具有 email 标识客户端的 VLESS / VMess / Trojan 可使用 Xray Stats API 做按用户流量统计；SOCKS5 与 Shadowsocks 不在这套按用户计量/配额执行范围内。**只有流量同步实际执行成功时**才会累计数据库用量并在达到配额后禁用用户。添加用户时设置非零配额会尝试安装同步 cron；之后修改已有用户配额不会自动安装，因此仍须在 `4 → 9` 核对或启用 cron 与同步。
- 当前脚本安装的官方 sing-box 二进制没有 per-user V2Ray API 统计能力，因此 Hysteria2、AnyTLS、TUIC **不能按用户自动计量流量，也不能因流量配额自动封禁**。数据库可以保存配额值，但它不是已生效的计量收据。
- sing-box 用户的到期日期和启用/禁用状态只在配置生成时过滤；在菜单中修改到期日期后，需用菜单 14 重建（到期检查任务在真正过期后也会禁用并重建）。到期日当天仍有效，脚本从次日才判定过期，并在下一次检查（默认 03:00）禁用。这与流量配额是两套不同机制。
- 多端口协议会为各端口生成独立 inbound；添加用户只写入首个端口实例。VLESS 按端口读取用户；VMess / Trojan 会合并所有端口的用户并把全集写入每个 inbound，因此首端口中的用户会在该协议所有端口有效。异常时先检查 `db.json` 的数组结构，再使用菜单 14 重建。

## 7. AnyTLS 与证书

AnyTLS 的实际 inbound 与服务由 sing-box 管理。当前安装路径仍会额外下载未用于 inbound 服务的 `anytls-server` / `anytls-client`；实际运行服务仍是 sing-box。安装 AnyTLS 时，脚本会在 `/etc/vless-reality/certs/anytls/` 生成独立自签证书；SNI 变化时会重新生成。

配置生成器默认使用这份独立证书；若独立证书缺失，会回退到全局 `server.crt` / `server.key`。此外，当 `cert_domain`、全局 `server.crt` 存在且记录域名与 AnyTLS SNI 一致时，也会切换到全局证书。两条分支都不验证 `server.key` 是否存在，也不验证证书链或颁发者，因此必须人工核对证书、私钥和域名匹配。

完成证书配置后使用菜单 14 重建，并核对 inbound：

```bash
jq -r '.inbounds[] | select(.type=="anytls") | {tag,listen_port,tls:.tls.certificate_path}' \
  /etc/vless-reality/singbox.json
```

随后检查服务状态并重新生成客户端链接。分享链接是否去掉 `allowInsecure` 使用另一套判定：SNI 必须匹配 `cert_domain`，且全局证书的 issuer 文本必须命中脚本内置的子串列表。它不是 CA/证书链验证，既可能拒绝其它可信 issuer，也可能因 `R3`、`E1` 等短标记出现在无关 issuer 中而误判。自签兜底会保留不安全验证选项；仍须独立检查证书链、有效期、SAN/主机名与私钥匹配。

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

- `--sync-traffic` 会查询并重置 Xray API 计数器、把增量写回数据库；达到配额时可能禁用用户、发送通知并重建/重启 Xray。
- `--check-expire` 会检查并禁用过期用户，且总会尝试发送三日内临期提醒；附加 `--notify` 时还会发送过期禁用通知。
- `--setup-expire-cron` 必须使用绝对脚本路径调用；不要从相对路径调用，因为任务会原样记录调用时的 `$0`。该分支即使内部失败也最终返回 0，且可能被其它含 `check-expire` 的任务误判为已安装，因此执行后必须核对 root crontab 中的精确命令。
- 流量统计 cron 通过菜单 `4 用户管理 → 9 流量统计设置` 管理；脚本**没有**可调用的 `--setup-traffic-cron` 命令行分支。设置配额时的自动安装也可能失败，不能只凭数据库里已有配额值判断限额已生效。
- 这些 CLI 分支不传播内部失败，最终均返回 0；自动化或 cron 不能以退出码作为成功证据，必须核对日志、数据库、crontab 与服务状态。
- 流量/到期 cron 的检测、替换和删除只按整行是否包含 `sync-traffic` / `check-expire` 子串匹配，不验证脚本路径或所有权。操作前备份 root crontab，避免无关任务使用这些字符串，并在操作后核对精确命令。

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

核对 `cert_domain`、AnyTLS SNI、inbound 证书/私钥路径，并检查证书 issuer 是否命中脚本内置的 CA 识别列表。自签兜底保留 `allowInsecure` 是预期行为；若使用其它可信 CA，脚本仍可能因 issuer 不在列表中而保留该参数。

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

菜单 12 会下载远程 `master` 制品，比较本地与远程 SHA-256，并在替换前检查 Bash shebang 和语法。它不会把 release/tag 当作版本源，也不验证签名或 `PROVENANCE.json`；需要完整发行包一致性时应按第 3.1 节同时下载全部文件并核对 `SHA256SUMS`。替换完成后的自动重建是“尝试执行”而不是完整验收；始终按第 9 节复核。

### 完全卸载

菜单 `13 完全卸载` 需要再次确认，主要行为包括：

- 按 `vless-*` 通配符停止/禁用并删除服务文件，不验证文件所有权；管理员自建的同名前缀 unit 必须提前备份或改名。脚本不按裸进程名全局终止 `xray`、`sing-box`、Snell、AnyTLS 或 ShadowTLS，只通过本项目 `vless-*` 服务边界停止；
- 若项目状态显示 WARP 已 configured/connected，或系统 `PATH` 中存在 `warp-cli`，会断开并卸载 `cloudflare-warp`；脚本不验证它是否由本项目安装，系统共享或既有 WARP 必须先评估；
- 会按 `vless-*` / `xhttp-cdn*` 文件名模式删除 Nginx 配置，不验证文件所有权；共享 Nginx 不会自动 stop/disable，管理员自建的同名前缀文件必须提前备份或改名；
- 会按通用服务名停止、禁用并删除活动的 `fake-web.service`，不验证是否由本项目创建；仅 Web placeholder 文件的删除会核对身份和内容，管理员修改过的页面会保留；
- 存在 `certs/` 时会保留证书目录，并一并保留 `cert_domain` 以便下次复用；没有 `certs/` 时会删除整个配置目录；有证书时，卸载只按扩展名清理部分生成文件，`role`、`traffic_interval`、日志、辅助脚本、订阅状态等其它文件也可能留在目录中；
- Xray、sing-box、Snell 等核心二进制通常保留，脚本会显示进一步删除命令。若卸载开始前能由数据库、join 文件或项目 `Caddyfile` 证明本项目用过 NaïveProxy，脚本只通过 `vless-naive` 服务边界停止；`/usr/local/bin/caddy` 始终保留，确认无其它 unit/站点引用后才能手动删除；
- 当前卸载流程没有调用流量同步 cron / 到期检查 cron 的卸载函数；卸载后应从 `crontab` 移除所有包含 `--sync-traffic` 或 `--check-expire` 的本项目任务，无论其脚本路径是否仍存在；
- 不会自动停止或卸载菜单 9 配置的 cloudflared / CF Tunnel，也不会删除 BBR 的 sysctl 配置；这些功能应先在各自菜单中单独停用、删除或恢复；
- 不会恢复 DNS64 对 `/etc/resolv.conf` 的修改，也不会删除或回退 `/etc/sysctl.d/99-vless-dualstack.conf` 与实时 `net.ipv6.bindv6only=0`；须另行核对和恢复；
- 完全卸载会按卸载前数据库中的精确 `hop_enable=1` 记录成对清理本项目 IPv4/IPv6 端口跳跃规则，不再枚举或删除第三方 REDIRECT 规则；数据库缺失或记录无效时不会猜测清理。

“完全卸载”并不等于删除所有证书、核心二进制或主机级副作用。执行前备份配置、root crontab、iptables/ip6tables、相关 sysctl 与共享服务状态；如需连证书和整个配置目录一并删除，必须按脚本最后显示的命令另行操作。

本仓为第三方补丁副本，版权与主要设计归原项目作者；请遵守适用许可与当地法律法规，仅用于合法用途。
