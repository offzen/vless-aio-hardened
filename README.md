# vless-aio-hardened

`vless-all-in-one`（Chil30，v3.4.10）的**加固修补版**服务端脚本：修复真实故障、
为出站增加 BitTorrent / 私网拦截，并把「升级后配置不生效」这个长期痛点一并解决。

- 上游项目：https://gitlab.com/chil30-group/vless-all-in-one
- 本仓只包含**服务端脚本** `vless-server.sh`（单文件，无依赖安装器）
- 版本基线：`3.4.10-h5`（`<上游版本>-h<本仓修订号>`）
- **升级源为本仓 GitHub，已脱离上游更新链**（版本比较/下载均指向本仓，不再触碰上游 GitLab）

> 📖 **使用手册见 [`USAGE.md`](USAGE.md)**：安装/升级/迁移、主菜单速查、用户与配额管理、
> AnyTLS 真实证书、db.json 真相源架构、排障与常见操作速查。
> 本 README 主要记录「修了什么」与改动要点；改动清单与验证记录见 [`FIXES.md`](FIXES.md)。

---

## 修了什么

### 1. 修复「用户列表被清空」bug（数据安全）

**症状**：菜单里的服务/用户莫名消失；`db.json` 变成空/非法 JSON；后续安装新协议报
`✗ 协议配置不存在`，但安装流程仍显示「安装完成」。

**根因**（两个叠加）：

1. **写入非原子 + 临时文件共享**。改 `db.json` 的 11 个函数都写同一个固定路径
   `${DB_FILE}.tmp`，再 `mv` 覆盖。当定时任务（流量同步）与菜单操作并发写时，
   两个写者互踩同一个临时文件：一方 `jq > tmp` 后，另一方已把 tmp `mv` 走 →
   `mv: cannot stat`，且可能把**空/半成品**覆盖到 `db.json` → 整个 `users` 数组丢失。
2. **多端口结构被污染**。`db_del_user` 在多端口（数组）形态下用
   `.[$c][$p] = [$cfg[] | .users = (...)]`，会给**每一个**端口元素强行写入 `.users`
   字段 —— 包括原本只靠 `uuid` 提供默认凭证、**根本没有 users 数组**的端口，
   破坏其结构。

**修复**：

- 新增 `_db_safe_write`，作为所有 `db.json` 写入的唯一入口：
  - `mktemp` 生成**唯一**临时文件（不再共享固定名）；
  - `mkdir` 原子目录锁串行化并发写，杜绝丢更新；
  - 只有 `jq` 成功且输出非空才 `mv`（同目录原子替换）；
  - **清空护栏**：非删除类操作若把某协议的用户数从 `>0` 变成 `0`，拒绝写入并报错。
- 11 个写函数全部改走 `_db_safe_write`；`db_del_user` / `db_remove_port` /
  `db_update_port` 显式标记为「允许清空」（合法删除不误拦）。
- 修正 `db_del_user` 多端口分支：只从**含 users 数组**的端口删除，不再污染其它端口。

### 2. 出站增加 BitTorrent 与私网拦截

在 `generate_xray_config` / `generate_singbox_config` 生成的配置里，**恒定**注入：

```json
{"type":"field","ip":["10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","127.0.0.0/8",
 "169.254.0.0/16","224.0.0.0/4","240.0.0.0/4","fc00::/7","fe80::/10"],"outboundTag":"block"}
{"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"}
```

出站同时提供 `block` 与 `blocked`（别名）两个 blackhole，兼容不同写法。

> ⚠️ **为什么不用 `geoip:private`**：部分 Xray 发行版的 `geoip.dat` 不含 `PRIVATE`
> 条目，写进配置会导致 **Xray 启动失败**（`code not found in geoip.dat: PRIVATE`）。
> 故改用显式 CIDR 列表，不依赖 `geoip.dat` 内容。已在 Xray 26.3.27 实测。

### 3. 升级流程整合「配置自动生效」（本版重点）

上游的升级流程只**替换脚本文件**，然后提示「请重新运行脚本以使用新版本」，需要用户
手工重新生成配置并重启服务。实践中的真实后果是：**升级完，新配置从未落地**。

实测（一台跑了 5 天的生产机）：`config.json` 的 mtime 一直停在建站那一刻，此后所有
加固改动都没进过生产配置 —— 因为没人手工重建过配置。

本补丁把这一步并入 `do_update()`：脚本替换成功后自动 `init_db` →
`rebuild_and_reload_xray` → `rebuild_and_reload_singbox`，即**重新生成配置并在服务
运行时重启**，提示语变为「升级完成，配置已自动生成并生效」。

生产实机 A/B（同一台机、同一份数据）对比：

| | 配置重建 | 服务重启 | 提示语 |
|---|---|---|---|
| 旧版 | ❌ | ❌ | 请重新运行脚本 |
| 本版 | ✅ | ✅ | 升级完成，配置已自动生成并生效 |

两次升级前后 `db.json` sha256 完全一致（用户数据零丢失）。

### 4. 流量统计 cron 智能触发

原版流量统计 cron（`sync-traffic`）需**手动**在菜单开启；忘记开启则配额不生效、
已用流量恒为 0。本补丁在添加**带配额**用户（`quota_gb > 0`）时自动安装 cron；
无配额用户不强制挂载。

### 5. 升级链路脱离上游、默认即升级（2026-10-25 新增）

原版的版本比较与脚本下载均指向上游 GitLab（`chil30-group/vless-all-in-one`）——
在加固版上走「检查脚本更新」会把脚本**替换回上游原版**，加固逻辑随之丢失。

本版改动：

- 版本源/下载源全部指向**本仓 GitHub**（`offzen/vless-aio-hardened`）：
  `SCRIPT_REPO` / `SCRIPT_RAW_URL` / release / tag 回退，全部不再触碰上游。
- 版本号引入本仓修订后缀：`<上游版本>-h<修订号>`（当前 `3.4.10-h5`）。
  `_version_gt` 支持后缀比较：`3.4.10-h5 > 3.4.10-h4 > 3.4.10-h3 > 3.4.10-h2 > 3.4.10-h1 > 3.4.10`。
- 版本来源优先级：release tag → git tag → **master 脚本内的 `VERSION` 常量**。
  本仓 GitHub 已建 Release（语义化 tag `v<版本>`，如 `v3.4.10-h5`），正常情况下走
  release 快路径；滚动 tag `dev`（不是版本号）与非语义化版本号一律不参与比较、不被缓存，
  避免「更新后仍提示更新」的死循环（v3.4.10-h5 修复，见 `FIXES.md` §十）。
- 发布约定由 CI 强制：改了 `vless-server.sh` 就必须抬 `readonly VERSION=`
  （`check-version-bump.sh` 硬闸门），且每次发版 Release 与 `VERSION` 由
  `.github/scripts/sync-release.sh` 自动保持一致——否则存量机器会静默收不到更新
  （见 `FIXES.md` §十一）。
- **默认即升级**：已安装环境下跑一键命令，启动时检测到本仓新版本即主动提示
  「是否立即升级并自动生效？」（默认 Yes）；全新安装不受打扰。

### 6. AnyTLS 移入 sing-box，支持真实 ACME 证书（2026-10-28 新增，v3.4.10-h2；-h3 补齐自签证书生成 + 链接 secure 条件化；-h4 修多用户/分享链接/多端口/BT/重建入口）

**背景**：原 AnyTLS 走独立 `anytls-go` 进程（`anytls-server -l … -p …`）。该二进制
**不支持 TLS 证书参数**——每次启动都生成内存临时自签证书，从不读磁盘证书文件，
客户端分享链接只能带 `allowInsecure=1`，无法用真实域名证书做 TLS 指纹防护。

**本版改动**：把 AnyTLS 从独立进程移入 **sing-box 统一服务**（与 hy2/tuic 同核心）。
sing-box 的 `anytls` inbound 原生支持 `tls.certificate_path/key_path`，因此在
`setup_cert_and_nginx` 已申请过 ACME 证书的机器上，AnyTLS 自动吃上真实证书：

- `SINGBOX_PROTOCOLS="hy2 tuic anytls"` —— anytls 入库归 `singbox` 核心。
- `generate_singbox_config` 新增 `anytls)` 分支：**ACME 证书优先、自签兜底**的
  证书选择与 hy2 分支同构（`sni == $CFG/cert_domain` 时用 `$CFG/certs/server.crt`）。
- **-h3 修复 ①**：补齐 `$CFG/certs/anytls/server.crt` 自签证书的**生成**（此前该路径
  只在生成器被引用、从未生成，无真证书时 sing-box 会指向不存在的证书文件而加载失败）。
  现在安装/重建 anytls 时自动落一份 CN 随 SNI 的自签证书作兜底。
- **-h3 修复 ②**：分享链接与订阅导出对 `allowInsecure`/`skip-cert-verify` 做**条件化**——
  当 `sni == cert_domain` 且 server 用的是真实 CA 证书时**自动去掉**，客户端才真正校验
  证书指纹；自签兜底场景保留，避免客户端被证书阻断。
- 支持多用户（sing-box anytls 多用户 + 流量统计；原独立进程只有单密码）。
- 存量迁移：老安装 anytls 仍在 `xray` 核心、跑 `vless-anytls` 独立服务。
  用本仓 `migrate-anytls-singbox.sh` 迁移（DB 搬移 + 停旧服务），详见 FIXES §六。

> ⚠️ 客户端吃到真实证书后，分享链接应**去掉 `allowInsecure`** 才真正受益。
> -h3 起，服务端生成链接/订阅在真证书场景**已自动去掉**；老客户端里已导入的旧链接
> 需手动把 `&allowInsecure=1` / `skip-cert-verify=true` 移除一次。

#### 怎么让 AnyTLS 用上真实证书（开启 secure）

**一句话**：脚本**不会为 AnyTLS 单独申请证书**。必须先让任一 TLS 协议
（VLESS+Reality / VMess-WS / Trojan / NaïveProxy）申请到
`/etc/vless-reality/certs/server.crt`，再装 AnyTLS 时把 **SNI 填成同一个域名**。
只有 `anytls.sni == $CFG/cert_domain` 时生成器才把该 inbound 指向真实证书。

1. **申请真证书（一次）**：装 VLESS+Reality（选「真实域名」）或 VMess-WS / Trojan /
   NaïveProxy，向导里填你的域名。证书落 `$CFG/certs/server.crt`，域名写 `$CFG/cert_domain`。
   > 需域名已解析到本机、80 端口公网可达（NAT/无公网 80 用 DNS 验证）。
2. **装 AnyTLS**：设密码后出现 `SNI 配置`，已存在真证书时 `ask_sni_config` 会**自动回填**
   该域名；否则选「自定义SNI」手动输入**与证书逐字符相同的域名**（大小写敏感）。
3. **验证 inbound 已指向真证书**：
   ```bash
   jq -r '.inbounds[]|select(.tag=="anytls-in")|{listen_port,tls:.tls.certificate_path}' \
       /etc/vless-reality/singbox.json
   # 期望 certificate_path = /etc/vless-reality/certs/server.crt
   systemctl status vless-singbox        # active
   ```
4. **客户端吃真证书**：-h3 起生成的分享链接在真证书场景已自动去掉 `allowInsecure`，
   客户端直接导入即可校验服务器证书（旧链接需手动删一次 `&allowInsecure=1`）。

**给已装的 AnyTLS 补开真证书**（不必重装）：把 `db.json` 里 `singbox.anytls.sni` 改成
证书域名，再重建 singbox 配置并重启 `vless-singbox` 即可（菜单「服务管理」或
`rebuild_and_reload_singbox`）。

**续期自动生效**：`get_acme_cert` 的 `--install-cert` 带 `--reloadcmd`，申请/续期后
会自动 `systemctl restart vless-reality vless-singbox`，AnyTLS 无需手工干预即吃到新证书。

---

### 7. -h4：AnyTLS 多用户 / 分享链接 / 多端口 / BT 拦截 / 重建入口（2026-10-29）

针对真实机器手动测试暴露的问题（详见 `FIXES.md` §八）：

- **用户级分享链接补齐 anytls**：用户管理 →「s 查看用户分享链接」此前对 anytls 恒显示
  「无法生成链接」，现已补齐。
- **多端口不再消失**：同一协议装第二个端口后，`db.json` 里该协议变成数组，旧版
  `generate_singbox_config` 对数组取 `.port` 得空 → 整个 inbound 不生成（菜单却仍显示链接）。
  现已逐元素展开，多端口各生成独立 inbound，`tag` 带 `-<port>` 后缀。
- **到期 / 启用禁用真正生效**：用户合并时按 `enabled` 与 `expire_date` 过滤，并在禁用/过期后
  同时重建 xray 与 sing-box。
- **流量配额如实告知**：官方 sing-box 二进制未编译 `with_v2ray_api`，无 per-user 流量统计，
  配额**不会**自动计量/封禁（到期与禁用有效）。设置配额时会明确告警，不假装生效。
- **BT 拦截真正生效**：sing-box 路由规则补 `{"action":"sniff"}`，`protocol:["bittorrent"]`
  才能命中（此前无嗅探，规则形同虚设）。
- **新增「14 重建全部配置」菜单项**：配置文件是 `db.json` 的派生产物，直改会被覆盖；
  改 `db.json` 后**普通 restart 无效**，必须重建。菜单也加了相应提示。

> 关键认知：`/etc/vless-reality/singbox.json`、`config.json` 都是**派生产物**，
> 唯一真相源是 `/etc/vless-reality/db.json`。改 db 后走菜单「14 重建全部配置」。

## 使用

**一条命令，既是安装也是升级**（单文件，直接跑）：

```bash
wget -O vless-server.sh https://raw.githubusercontent.com/offzen/vless-aio-hardened/master/vless-server.sh
chmod +x vless-server.sh
./vless-server.sh
```

- **全新机器**：进入交互式菜单 → 选「安装协议」，按向导走完即可。
- **已装本加固版**：直接再跑上面同一条命令即可升级 —— **默认就是升级**。
  启动时检测到已有安装且本仓有新版本时，会主动提示「是否立即升级并自动生效？」（默认 Yes，回车即升级）；
  升级过程自动重建配置并重启服务，**不重装协议、用户数据零丢失**（升级前后 `db.json` 一致）。
- 想跳过本次升级进入菜单：在提示处输 `n` 即可；菜单里也可随时走「检查脚本更新」手动升级。

> 升级源已**脱离上游**：版本比较与脚本下载均指向本仓（GitHub `offzen/vless-aio-hardened`），
> 不会从上游 GitLab 拉取任何内容，升级只会拿到本加固版。

**已装上游版、只想换成加固版（不重装协议）**：

```bash
wget -O vless-server.sh https://raw.githubusercontent.com/offzen/vless-aio-hardened/master/vless-server.sh
cp vless-server.sh /usr/local/bin/vless-server.sh
chmod +x /usr/local/bin/vless-server.sh
/usr/local/bin/vless-server.sh   # 进入菜单后走「检查脚本更新」或直接重建配置（见下）
```

**升级已有安装**：跑一键命令（默认 Yes）或走菜单「检查脚本更新」即可，配置会自动重建并让服务生效，无需手工操作。

若你更愿意手工控制（例如想先校验再重启），仍可按老办法重建配置：

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
- 本补丁只改了上述五处逻辑，其余保持上游原样。
