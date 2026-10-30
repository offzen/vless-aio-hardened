# vless-aio-hardened 使用手册

> 适用版本：**v3.4.10-h5**（`vless-server.sh`）
> 本手册面向服务器管理员：安装、升级、迁移、日常运维、多用户与配额、AnyTLS 证书、
> 配置文件架构与排障。改动清单与验证记录见 [`FIXES.md`](FIXES.md)。

---

## 目录

1. [这是什么](#1-这是什么)
2. [支持哪些协议](#2-支持哪些协议)
3. [安装 / 升级 / 迁移](#3-安装--升级--迁移)
4. [配置文件架构（db.json 是唯一真相源）](#4-配置文件架构dbjson-是唯一真相源)
5. [主菜单速查](#5-主菜单速查)
6. [用户管理（多用户 / 配额 / 到期）](#6-用户管理多用户--配额--到期)
7. [让 AnyTLS 用上真实证书（开启 secure）](#7-让-anytls-用上真实证书开启-secure)
8. [命令行参数（定时任务 / 无交互）](#8-命令行参数定时任务--无交互)
9. [常见操作速查表](#9-常见操作速查表)
10. [排障](#10-排障)
11. [升级已有安装 / 切换到本加固版](#11-升级已有安装--切换到本加固版)

---

## 1. 这是什么

`vless-aio-hardened` 是上游 [`vless-all-in-one`](https://gitlab.com/chil30-group/vless-all-in-one)（Chil30，v3.4.10）
的**加固修补版服务端脚本**。本仓只含服务端脚本 `vless-server.sh`（单文件，无安装器）。

- **版本号**：`3.4.10-h5` = `<上游版本>-h<本仓修订号>`。
- **升级源已脱离上游**：版本比较 / 脚本下载均指向**本仓 GitHub**（`offzen/vless-aio-hardened`），
  不会从上游 GitLab 拉取任何内容。
- **默认即升级**：已装环境下重跑一键命令，检测到本仓新版本即提示「是否立即升级并自动生效？」
  （默认 Yes，回车即升级）。

---

## 2. 支持哪些协议

脚本按「核心」组织协议，安装时自动归类：

| 核心 | 协议 | 菜单选项 |
|---|---|---|
| **Xray** | VLESS + Reality / VLESS + Reality + XHTTP / VLESS + WS + TLS / VMess + WS / VLESS-XTLS-Vision / Trojan / Shadowsocks(2022/传统) / SOCKS5 | 1/2/3/4/5/6/8/9 |
| **sing-box** | Hysteria2 / AnyTLS / TUIC | 7/12/13 |
| **独立进程** | Snell v4 / Snell v5 / NaïveProxy | 10/11/14 |

> 协议常量：`XRAY_PROTOCOLS="vless vless-xhttp vless-xhttp-cdn vless-ws vless-ws-notls vmess-ws vless-vision trojan trojan-ws socks ss2022 ss-legacy"`，
> `SINGBOX_PROTOCOLS="hy2 tuic anytls"`，`STANDALONE_PROTOCOLS="snell snell-v5 snell-shadowtls snell-v5-shadowtls ss2022-shadowtls naive"`。

**AnyTLS 已从独立 `anytls-go` 进程移入 sing-box 统一服务**（-h2 起），与 hy2/tuic 同核心，
因此支持多用户、多端口、真实证书与出站拦截。

---

## 3. 安装 / 升级 / 迁移

### 3.1 一条命令，既是安装也是升级

```bash
wget -O vless-server.sh https://raw.githubusercontent.com/offzen/vless-aio-hardened/master/vless-server.sh
chmod +x vless-server.sh
./vless-server.sh
```

- **全新机器**：进入交互式菜单 → 选「安装协议」，按向导走完。
- **已装本加固版**：直接重跑同一命令即升级 —— **默认就是升级**，自动重建配置并重启服务，
  **不重装协议、用户数据零丢失**（升级前后 `db.json` 一致）。
- 想跳过本次升级：在「是否立即升级」提示处输 `n`。

### 3.2 安装完成后脚本被安装到系统路径

安装/升级完成后，脚本会拷贝到 **`/usr/local/bin/vless-server.sh`** 并建立 **`/usr/local/bin/vless`**
软链。之后可直接用 `vless` 命令进入菜单。

### 3.3 迁移存量 AnyTLS（老安装：anytls 在 xray 核心 + 独立 vless-anytls 服务）

用本仓 `migrate-anytls-singbox.sh`：

```bash
sudo bash migrate-anytls-singbox.sh                # 默认 DB /etc/vless-reality/db.json
sudo bash migrate-anytls-singbox.sh --dry-run      # 先演练，只打印不改库
sudo bash migrate-anytls-singbox.sh --db /path/to/db.json
```

迁移内容：① `xray.anytls` → `singbox.anytls`（对象原样搬移）；② 重建 `singbox.json` 并重启
`vless-singbox`；③ 停止并禁用旧独立服务 `vless-anytls`。迁移前自动备份 DB
（`$CFG/db.json.*.bak-migrate-*`），失败不改原库。

---

## 4. 配置文件架构（db.json 是唯一真相源）

**最重要的一条认知**（本版最核心的架构事实）：

```
/etc/vless-reality/
├── db.json            ← 唯一真相源（用户 / 端口 / 配额 / 到期 / 路由全部在这）
├── config.json        ← Xray 派生产物（由 db.json 生成，可被覆盖）
├── singbox.json       ← sing-box 派生产物（由 db.json 生成，可被覆盖）
└── certs/             ← 证书目录（server.crt / server.key / anytls/）
```

- **`db.json` 是唯一事实源；`config.json` / `singbox.json` 是派生产物**。
- **只改 `config.json` / `singbox.json` 不生效**——它们会被 `generate_xray_config` /
  `generate_singbox_config` 重写覆盖。
- **手改 `db.json` 后，普通 restart 无效**，必须**重建配置**：
  - 菜单 → **「14 重建全部配置」**（`_regenerate_proxy_configs`，同时重建 xray + singbox），或
  - 调用 `rebuild_and_reload_xray` / `rebuild_and_reload_singbox`。
- 写库函数全部走 `_db_safe_write`（原子临时文件 + 目录锁串行化 + 清空护栏），
  杜绝并发写导致的用户列表被清空。

> 配置文件路径可通过改 `CFG` 变量调整（默认 `/etc/vless-reality`）。

---

## 5. 主菜单速查

已装协议时，主菜单：

| 选项 | 功能 |
|---|---|
| **1** | 安装新协议（多协议共存） |
| **2** | 核心版本管理（Xray / Sing-box） |
| **3** | 卸载指定协议 |
| **4** | 用户管理（多用户/流量/通知） |
| **5** | 查看协议配置 |
| **6** | 订阅服务管理 |
| **7** | 管理协议服务 |
| **8** | 分流管理 |
| **9** | CF Tunnel（Argo） |
| **10** | BBR 网络优化 |
| **11** | 查看运行日志 |
| **12** | 检查脚本更新 |
| **13** | 完全卸载 |
| **14** | 重建全部配置（手改 db 后生效） |
| **0** | 退出 |

未装协议时只显示 1（安装协议）/ 12（检查脚本更新）/ 0（退出）。

安装新协议（选项 1）的协议选择菜单：

| 选项 | 协议 |
|---|---|
| 1 | VLESS + Reality（推荐，抗封锁） |
| 2 | VLESS + Reality + XHTTP（多路复用） |
| 3 | VLESS + WS + TLS（CDN友好，可作回落） |
| 4 | VMess + WS（回落分流/免流） |
| 5 | VLESS-XTLS-Vision（支持回落） |
| 6 | Trojan（支持回落） |
| 7 | Hysteria2（UDP高速） |
| 8 | Shadowsocks（再选 2022/传统版） |
| 9 | SOCKS5 |
| 10 | Snell v4 |
| 11 | Snell v5 |
| 12 | AnyTLS |
| 13 | TUIC v5 |
| 14 | NaïveProxy |
| 0 | 返回 |

> 提示：5/6 用 8443 端口时，3/4 可作为回落共用。

---

## 6. 用户管理（多用户 / 配额 / 到期）

主菜单 **4 → 用户管理** 进入子菜单：

| 选项 | 功能 |
|---|---|
| **1** | 查看用户列表 |
| **2** | 添加用户 |
| **3** | 删除用户 |
| **4** | 设置用户配额 |
| **5** | 重置用户流量 |
| **6** | 启用/禁用用户 |
| **e** | 设置到期日期 |
| **r** | 修改用户路由 |
| **s** | 查看用户分享链接 |
| **7** | 实时流量统计 |
| **8** | 同步流量数据 |
| **9** | 流量统计设置 |
| **t** | TG 通知配置 |
| **0** | 返回 |

> 用户操作（1/2/3/4/5/6/e/r/s）会先让你**选择协议**，再操作该协议下的用户。

### 关键行为（-h4 修复后）

- **到期 / 启用禁用对 sing-box 协议（hy2/anytls/tuic）真正生效**：
  用户合并时按 `enabled` 与 `expire_date` 过滤，禁用/过期后同时重建 xray 与 sing-box。
- **用户级分享链接对 anytls 已补齐**（此前恒显示「无法生成链接」）。
- **多端口实例各端口独立生成 inbound**（tag 带 `-<port>` 后缀），不再整体消失。
- **流量配额对 sing-box 协议只能如实告警**（见下节注意事项）。

### ⚠️ 关于流量配额（sing-box 协议）

官方 sing-box 二进制**未编译 `with_v2ray_api`**，没有 per-user 流量统计（StatsService），
因此对 hy2 / anytls / tuic：

- **到期与禁用**：可真正生效（-h4 已修）。
- **流量配额**：**不会**自动计量 / 封禁。设置配额时会明确告警，不假装生效。
- Xray 系协议（vless / trojan / ss 等）有 xray API，配额可正常计量。

---

## 7. 让 AnyTLS 用上真实证书（开启 secure）

**一句话**：脚本**不会为 AnyTLS 单独申请证书**。必须先让任一 TLS 协议申请到
`/etc/vless-reality/certs/server.crt`，再装 AnyTLS 时把 **SNI 填成同一个域名**。
只有 `anytls.sni == $CFG/cert_domain` 时，生成器才把该 inbound 指向真实证书。

1. **申请真证书（一次）**：装 VLESS+Reality（选「真实域名」）或 VMess-WS / Trojan /
   NaïveProxy，向导里填你的域名。证书落 `$CFG/certs/server.crt`，域名写 `$CFG/cert_domain`。
   > 需域名已解析到本机、80 端口公网可达（NAT/无公网 80 用 DNS 验证）。
2. **装 AnyTLS**：设密码后出现 `SNI 配置`，已存在真证书时 `ask_sni_config` 自动回填该域名；
   否则选「自定义SNI」手动输入**与证书逐字符相同的域名**（大小写敏感）。
3. **验证 inbound 已指向真证书**：
   ```bash
   jq -r '.inbounds[]|select(.tag=="anytls-in")|{listen_port,tls:.tls.certificate_path}' \
       /etc/vless-reality/singbox.json
   # 期望 certificate_path = /etc/vless-reality/certs/server.crt
   systemctl status vless-singbox        # active
   ```
4. **客户端吃真证书**：-h3 起生成的分享链接在真证书场景**已自动去掉 `allowInsecure`**，
   客户端直接导入即可校验服务器证书（旧链接需手动删一次 `&allowInsecure=1` / `skip-cert-verify=true`）。

### 给已装的 AnyTLS 补开真证书（不必重装）

把 `db.json` 里 `singbox.anytls.sni` 改成证书域名，再重建 singbox 配置并重启
`vless-singbox` 即可（菜单「服务管理」或 `rebuild_and_reload_singbox`）。

### 续期自动生效

`get_acme_cert` 的 `--install-cert` 带 `--reloadcmd`，申请/续期后自动
`systemctl restart vless-reality vless-singbox`，AnyTLS 无需手工干预即吃到新证书。

### 自签兜底

- h3 起补齐了 `$CFG/certs/anytls/server.crt` 自签证书的**生成**（此前该路径从未生成，
  无真证书时 sing-box 会指向不存在的证书文件而加载失败）。
- 无真证书时用自签兜底，分享链接保留 `allowInsecure`（避免客户端被证书阻断）。

---

## 8. 命令行参数（定时任务 / 无交互）

脚本支持无交互的命令行参数（也供 cron 调用）：

```bash
vless-server.sh --help
```

| 参数 | 用途 |
|---|---|
| `--sync-traffic` | 同步流量数据到数据库（用于定时任务） |
| `--show-traffic` | 显示实时流量统计 |
| `--check-expire` | 检查并禁用过期用户，发送提醒；`--check-expire --notify` 同时发提醒 |
| `--setup-expire-cron` | 安装过期检查定时任务 |
| `--help`, `-h` | 显示帮助信息 |

无参数时启动交互式菜单。

**自带 cron 逻辑**：
- 添加**带配额**用户（`quota_gb > 0`）时自动安装流量同步 cron（`sync-traffic`）；
- 到期检查 cron（`--check-expire`）随到期功能启用自动安装。

---

## 9. 常见操作速查表

| 想做什么 | 怎么做 |
|---|---|
| 全新安装 | `./vless-server.sh` → 选项 1 安装协议 |
| 升级到新版本 | 重跑一键命令（默认 Yes）或菜单 12 |
| 添加用户 | 菜单 4 → 2 → 选协议 |
| 查看某用户分享链接 | 菜单 4 → s → 选协议 |
| 设配额 | 菜单 4 → 4 → 选协议 |
| 设到期 | 菜单 4 → e → 选协议 |
| 启用/禁用用户 | 菜单 4 → 6 → 选协议 |
| 手改 db.json 后让配置生效 | **菜单 14 重建全部配置**（普通 restart 无效） |
| 装第二个端口 | 菜单 1 再装一次同一协议 |
| 看 anytls 链接 | 菜单 4 → s 选 anytls（已补齐） |
| 校验 xray 配置 | `xray run -test -c /etc/vless-reality/config.json` |
| 校验 singbox 配置 | `sing-box check -c /etc/vless-reality/singbox.json` |
| 开 xray 调试日志 | `sed -i 's/"loglevel":"warning"/"loglevel":"debug"/' /etc/vless-reality/config.json && systemctl restart vless-reality` |
| 开 singbox 调试日志 | `sed -i 's/"level":"warn"/"level":"debug"/' /etc/vless-reality/singbox.json && systemctl restart vless-singbox` |
| 删除证书 | `rm -rf $CFG/certs $CFG/cert_domain` |
| 完全卸载 | 菜单 13；配置文件全在 `$CFG`（`/etc/vless-reality`） |

---

## 10. 排障

### 10.1 改了 anytls / vless 配置文件不生效？

**根因**：`config.json` / `singbox.json` 是 `db.json` 的派生产物，直改会被覆盖，
且普通 restart 不读 db.json。

**解决**：改 `db.json` → 菜单 **14 重建全部配置**（或 `_regenerate_proxy_configs`）。

### 10.2 anytls 客户端报证书问题 / 一直 allowInsecure？

- 真证书场景（`sni == cert_domain`）生成器已自动去掉 `allowInsecure`；
  老客户端里旧链接需手动删一次 `&allowInsecure=1`。
- 商业 CA 证书（不在 `_is_real_cert` 白名单）会被漏判 → 仍带 allowInsecure（已知边界）。
- 确认 inbound 是否真的指向真证书：`jq -r '.inbounds[]|select(.tag=="anytls-in")' /etc/vless-reality/singbox.json`。

### 10.3 anytls 不拦 BT？

-h4 已在 sing-box 路由最前插入 `{"action":"sniff"}`，`protocol:["bittorrent"]` 才能命中。
需 **sing-box ≥ 1.11**（脚本已用 `action:"route"` schema）。旧版本不适用。

### 10.4 多端口实例「菜单有、实际连不上」？

-h4 已修：`generate_singbox_config` 对数组逐元素展开，多端口各生成独立 inbound，
`tag` 带 `-<port>` 后缀。若仍异常，确认 `db.json` 里该协议是数组（多端口）结构，
重建配置（菜单 14）。

### 10.5 用户列表莫名被清空？

-h1 已修（`_db_safe_write` 原子写 + 清空护栏）。若仍出现，检查是否手改过 db.json
或并发写（流量同步 cron + 菜单同时操作）。

---

## 11. 升级已有安装 / 切换到本加固版

### 已装本加固版

跑一键命令（默认 Yes 升级）或菜单 12（检查脚本更新）。

### 已装上游版、只想换成加固版（不重装协议）

```bash
wget -O vless-server.sh https://raw.githubusercontent.com/offzen/vless-aio-hardened/master/vless-server.sh
cp vless-server.sh /usr/local/bin/vless-server.sh
chmod +x /usr/local/bin/vless-server.sh
/usr/local/bin/vless-server.sh   # 进入菜单后走「检查脚本更新」或直接重建配置
```

### 手工控制重建配置（想先校验再重启）

```bash
# 生成函数区 + 调用（保留脚本内的生产路径）
MARK=$(grep -n '^# 命令行参数处理' /usr/local/bin/vless-server.sh | cut -d: -f1)
sed -n "1,$((MARK-1))p" /usr/local/bin/vless-server.sh > /tmp/prodgen.sh
printf '\ngenerate_xray_config\necho "RC=$?"\n' >> /tmp/prodgen.sh
bash /tmp/prodgen.sh

# 关键：先校验，再重启
xray run -test -c /etc/vless-reality/config.json     # 必须看到 Configuration OK
systemctl restart vless-reality                      # 或 rc-service vless-reality restart (Alpine)
```

> 上面用 `grep` 定位截断点而不是写死行号 —— 行号随版本变化，硬编码会失效。

---

## 兼容性实测

| 平台 | 结果 |
|---|---|
| Debian 13 + systemd（Xray 26.3.27） | ✅ 升级成功，用户零丢失，`Configuration OK.`，配置自动重建 + 服务自动重启 |
| Alpine + OpenRC（Xray 26.3.27） | ✅ `mkdir` 锁 / `mktemp` / `sleep 0.1` / `seq` 均可用；4 用户零丢失 |

双端口数组格式 `db.json`（一端口多用户 + 另一端口 uuid 凭证）实测通过。

---

## 免责与归属

- 本仓是**第三方脚本的补丁副本**，非官方发布；版权与主要设计归上游作者 Chil30。
- 请遵守所在地区法律法规与上游项目许可，仅用于合法用途。
- 本补丁只改了上述逻辑，其余保持上游原样。