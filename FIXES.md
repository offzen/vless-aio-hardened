# FIXES — 改动清单与验证记录

基线：`vless-all-in-one` v3.4.10 服务端脚本（上游 24898 行）→ 本补丁 **25362 行**；当前修订 `3.4.10-h5`。

本文件逐条列出改动、位置与验证方式，便于审核与回归。

---

## 零、`do_update()` 升级流程整合自动生效（本版新增）

### 痛点

上游的升级流程只**替换脚本文件**，然后打印「请重新运行脚本以使用新版本」，要求用户
手工重新生成配置并重启服务。实际后果是：**升级后新配置从未落地**。

实测证据（测试机 C，Debian 13 + systemd，2026-10-25）：该机自建站起 `config.json`
的 mtime 一直停在建站时刻（2026-10-20 02:02），此后所有针对 `generate_xray_config`
的加固改动（BitTorrent / 私网拦截）**在生产配置里一直没有生效** —— 因为没人手工重建过配置。

### 修复

`do_update()` 在脚本替换成功后，自动执行：

```bash
init_db 2>/dev/null
rebuild_and_reload_xray "silent" 2>/dev/null
rebuild_and_reload_singbox "silent" 2>/dev/null
```

`rebuild_and_reload_*` 内部为「重新生成配置 → 若服务在运行则重启」的既有函数，
故升级后配置与服务**一次完成**，提示语改为「升级完成，配置已自动生成并生效」。

### 验证（生产实机 A/B，同一台机、同一份数据）

| 阶段 | 配置是否重建 | 服务是否重启 | 提示语 |
|---|---|---|---|
| 旧版 `do_update` | ❌ 否（config sha 与 mtime 均未变） | ❌ 否（MainPID 未变） | 「请重新运行脚本以使用新版本」 |
| 新版 `do_update` | ✅ 是（config sha 改变、mtime 刷新） | ✅ 是（MainPID 变更） | 「升级完成，配置已自动生成并生效」 |

两次升级前后 `db.json` 的 sha256 **完全一致**（用户数据零丢失）；重建后的配置
`xray -test` = `Configuration OK.`，监听端口、入站 tag、REALITY 私钥、SS 密码均未变，
并正确补齐了此前缺失的私网/BitTorrent 拦截规则。

> 实现位置：`do_update()` 内脚本替换成功分支（本版约第 24877 行起）。

---

## 一、`db.json` 写入安全（修复「清空用户列表」）

### 新增函数 `_db_safe_write`

位置：原 `_db_apply` 之后（约第 103 行起）。

```
_db_safe_write <allow_wipe:0|1> <guard-core> [jq args...] 'filter'
```

| 行为 | 说明 |
|---|---|
| 唯一临时文件 | `mktemp "${DB_FILE}.tmp.XXXXXX"`，替换原先共享的 `${DB_FILE}.tmp` |
| 并发串行化 | `mkdir "${DB_FILE}.lock"` 原子目录锁，最多等 5 秒 |
| 空结果中止 | `jq` 输出为空（如库被并发置空）→ 中止，不覆盖 |
| 原子替换 | 同目录 `mv`（rename 原子性），崩溃不会留坏库 |
| 清空护栏 | `allow_wipe=0` 时，若守卫 key 下用户数 `>0 → 0`，返回 2 拒绝写入 |
| 返回值 | 0=成功；1=jq/锁失败；2=命中清空护栏 |

### 改造的 11 个写入函数

| 函数 | allow_wipe | 说明 |
|---|---|---|
| `db_add_user` | 0 | 添加用户（护栏防误清） |
| `db_del_user` | 1 | 删除用户（合法清空） |
| `db_update_user_traffic` | 0 | 流量累加 |
| `db_set_user_traffic` | 0 | 流量覆盖 |
| `db_set_user_quota` | 0 | 配额 |
| `db_set_user_enabled` | 0 | 启用/禁用 |
| `db_set_user_alert_state` | 0 | 告警状态 |
| `db_set_user_routing` | 0 | 用户路由 |
| `db_set_user_expire_date` | 0 | 到期日 |
| `db_add_port` | 0 | 增加端口实例 |
| `db_remove_port` | 1 | 删除端口 |
| `db_update_port` | 1 | 覆盖端口配置 |

### `db_del_user` 多端口结构修复

改动前（会污染没有 users 数组的端口）：

```jq
.[$c][$p] = [$cfg[] | .users = ([.users // [] | .[] | select(.name != $n)])]
```

改动后（只动真正含 users 的端口）：

```jq
.[$c][$p] = [$cfg[] | if (.users // [] | length) > 0 then
    .users = ([.users[] | select(.name != $n)])
else . end]
```

同样的 `if (.users|length) > 0` 保护也应用到了 traffic / quota / enabled /
alert_state / routing / expire_date 的多端口分支。

### 修复过程中发现并修掉的自身回归

`db_add_port` / `db_remove_port` / `db_update_port` 的 guard 参数最初写成 `${proto}`，
但这三个函数的形参名是 `protocol` → 在 `set -u` 下报 `unbound variable`；
在无 `set -u` 的正常运行中会静默变成 `xray.`（护栏失效）。已修正为 `${protocol}`。

---

## 二、出站拦截规则

### Xray（`generate_xray_config`）

在 4 个配置组装分支里，`routing.rules` 的**首部**恒定注入三条：

```json
[
  {"type": "field", "inboundTag": ["api"], "outboundTag": "api"},
  {"type": "field", "ip": ["10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","127.0.0.0/8",
   "169.254.0.0/16","224.0.0.0/4","240.0.0.0/4","fc00::/7","fe80::/10"], "outboundTag": "block"},
  {"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"}
]
```

出站数组额外补 `{"protocol":"blackhole","tag":"blocked"}` 别名。

### sing-box（`generate_singbox_config`）

`route.rules` 尾部恒定追加：

```json
[
  {"action":"route","outbound":"block","ip_cidr":["10.0.0.0/8","172.16.0.0/12",
   "192.168.0.0/16","127.0.0.0/8","169.254.0.0/16","224.0.0.0/4","240.0.0.0/4",
   "fc00::/7","fe80::/10"]},
  {"action":"route","outbound":"block","protocol":["bittorrent"]}
]
```

### 为什么不用 `geoip:private`（重要）

首版按常见示例使用 `{"ip":["geoip:private"]}`，在生产机（Xray 26.3.27）重启后**启动失败**：

```
Failed to start: main: failed to load config files: [/etc/vless-reality/config.json]
  > infra/conf: failed to build routing configuration > infra/conf: invalid field rule
  > infra/conf: failed to load GeoIP: private > infra/conf: code not found in geoip.dat: PRIVATE
```

`geoip:private` 依赖 `geoip.dat` 内存在 `PRIVATE` 条目，部分发行版没有。已改为显式 CIDR。

---

## 三、流量统计 cron 智能触发

原版流量统计 cron（`sync-traffic`）需用户**手动**在菜单开启；忘记开启则配额不生效、
已用流量恒为 0。现于 `db_add_user()` 中增加守卫：带配额用户（`quota_gb > 0`）自动安装 cron。

```bash
ensure_traffic_cron() {
    local interval="${1:-$(get_traffic_interval)}"
    local script_path="$(readlink -f "$0" 2>/dev/null || echo "$0")"
    local cron_cmd="*/$interval * * * * $script_path --sync-traffic >/dev/null 2>&1"
    if crontab -l 2>/dev/null | grep -q "sync-traffic"; then return 0; fi
    (crontab -l 2>/dev/null; echo "$cron_cmd") | crontab - 2>/dev/null
    set_traffic_interval "$interval"
}
```

无配额/免费用户不强制挂载 cron。

---

## 四、验证记录

### 隔离环境（函数级，原版 vs 修复版对比）

| 场景 | 原版 | 修复版 |
|---|---|---|
| 20 并发写 db.json | ✗ 丢更新（u1 只剩 100/1000） | ✓ 1000/500 精确 |
| 30 并发写 | ✗ 用户列表被清空 | ✓ 用户保留 |
| 多端口删除污染 | ✗ 8443 端口被注入 `users:[]` | ✓ 未被污染 |
| 异常清空护栏 | ✗ 无护栏，users→0 | ✓ rc=2 拒绝 |
| 正常增删 | ✓ | ✓ 不误伤 |
| **合计** | **pass=11 fail=6** | **pass=18 fail=0** |

### 升级流程自动生效（隔离 mount-namespace A/B）

真实路径语义下（`/etc/vless-reality`、`/usr/local/bin/vless-server.sh` 均 bind 到沙箱，
`systemctl` 用 shim 记录调用），同一份「上游发布了新版本」负载：

| case | config_changed | service_restarted | 提示语 |
|---|---|---|---|
| 旧版逻辑 | NO | NO | 请重新运行脚本 |
| 新版逻辑 | YES | YES | 升级完成，配置已自动生成并生效 |

### 生产升级实测

| 主机 | 平台 | 数据 | 结果 |
|---|---|---|---|
| 测试机 A | Debian 13 + systemd | 单端口 uuid | ✅ `Configuration OK.`，db 指纹零变化 |
| 测试机 B | Alpine + OpenRC | 双端口数组，4 用户 | ✅ 4 用户零丢失，双端口监听正常 |
| 测试机 C | Debian 13 + systemd | 单端口 + 双协议 | ✅ 旧版/新版升级行为 A/B 对比通过；配置自动重建、服务自动重启、db 零变化 |

升级后 `routing.rules` 实测：

```json
[{"type":"field","inboundTag":["api"],"outboundTag":"api"},
 {"type":"field","ip":["10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","127.0.0.0/8",
  "169.254.0.0/16","224.0.0.0/4","240.0.0.0/4","fc00::/7","fe80::/10"],"outboundTag":"block"},
 {"type":"field","protocol":["bittorrent"],"outboundTag":"block"}]
```

> 说明：本次验证**只确认配置正确生成**，未发起任何真实 BitTorrent 流量测试。

### 回归清单（升级后建议自查）

```bash
xray run -test -c /etc/vless-reality/config.json          # 必须 Configuration OK
jq -r '[.inbounds[]|select(.protocol=="vless")|.settings.clients|length]' /etc/vless-reality/config.json
jq -r '.routing.rules' /etc/vless-reality/config.json      # 应含 bittorrent
ss -ltnpH | grep xray                                       # 端口都在听
```

---

## 五、升级链路脱离上游与默认即升级（2026-10-25 新增）

### 痛点

原版服务端脚本的版本检查（`_get_latest_script_version`）与下载（`_fetch_script_tmp`）均指向 GitLab 上游（`chil30-group/vless-all-in-one`）。在加固版机器上若用户或管理员运行菜单 12「检查脚本更新」，脚本会直接从上游拉取未加固的原版覆盖本地 `/usr/local/bin/vless-server.sh`，导致此前的原子写入、BitTorrent/私网拦截与自动生效等加固特性被覆盖丢失。

### 修复

1. **常量与源解耦**：
   - `REPO_URL` 与 `SCRIPT_REPO` 切至 `offzen/vless-aio-hardened`。
   - `SCRIPT_RAW_URL` 切至 `https://raw.githubusercontent.com/offzen/vless-aio-hardened/master/vless-server.sh`。
   - Tag 回退从 GitLab API 切换为 GitHub Tags API。
2. **独立版本号体系与后缀比较**：
   - 采用 `<上游版本>-h<修订号>` 格式（首版 `3.4.10-h1`）。
   - 改造 `_version_gt`：先分离基础版本与 `-h` 修订号，基础版本相同比较修订号（如 `3.4.10-h2 > 3.4.10-h1 > 3.4.10`）。
3. **主菜单默认即升级（启动自愈）**：
   - `main_menu` 在检测到已安装协议的前提下，若云端有更新版本，主动弹出「是否立即升级并自动生效？[Y/n]」，默认回车确认升级并直接调用 `do_update`。


## 六、AnyTLS 移入 sing-box 核心，支持真实 ACME 证书（2026-10-28 新增，v3.4.10-h2）

### 痛点

原 AnyTLS 由独立 `anytls-go` 进程承载（`anytls-server -l <host:port> -p <pw>`）。
经源码核实（`anytls/anytls-go` v0.0.13，`cmd/server/main.go`），该二进制**只接受
`-l` / `-p` / `-padding-scheme` 三个 flag**，没有 `-cert` / `-key`；服务端每次启动都
用 `util.GenerateKeyPair(time.Now,"")` 生成**内存临时自签证书**，从不读磁盘证书文件。
因此客户端链接只能带 `?sni=…&allowInsecure=1`，无法配置真实 TLS 域名证书做指纹防护。

### 修复：走 sing-box anytls inbound（sing-box 原生支持 `tls.certificate_path`）

| 位置 | 改动 |
|---|---|
| `SINGBOX_PROTOCOLS` | `"hy2 tuic"` → `"hy2 tuic anytls"`（anytls 入库归 `singbox` 核心） |
| `STANDALONE_PROTOCOLS` | 移除 `anytls`（不再当独立进程） |
| `PROTO_SVC[anytls]` | `vless-anytls` → `vless-singbox`；`PROTO_KIND[anytls]="singbox"` |
| `gen_anytls_server_config` | 重写：只存 `password/port/sni`（与 hy2 一致，**不写 default 用户进 DB**，由生成器合成；多用户经 `db_add_user("singbox","anytls",…)` 追加） |
| `generate_singbox_config` | 新增 `anytls)` 分支，inbound `{type:"anytls", users, tls:{enabled, certificate_path, key_path, alpn:["http/1.1"]}}` |
| `create_service` / watchdog / 日志视图 | 移除独立 `vless-anytls` 分支；anytls 归 `vless-singbox` 统一服务 |

**证书选择（与 hy2 同构，ACME 优先、自签兜底）**：

```bash
# sni 命中已申请域名 → 用真实 ACME 证书；否则回落自签
[[ "$sni" == "$(cat "$CFG/cert_domain")" ]] \
    && cert_path="$CFG/certs/server.crt" key_path="$CFG/certs/server.key" \
    || cert_path="$CFG/certs/anytls/server.crt"
```

**多用户收益**：sing-box anytls 支持多用户 + 流量统计；原独立进程只有单密码。

### 验证（函数级隔离，不跑全脚本）

- `test-gen-anytls.sh` —— 复刻 `gen_anytls_server_config`：REGISTER 落 `singbox`、
  存 `password/port/sni`、`SAVE anytls`、`role=server`。**PASS**
- `test-anytls-branch.sh` —— 复刻 `generate_singbox_config` 的 anytls 分支：
  ① 真实证书路径（sni==cert_domain）+ 合成 default + 合并 alice 多用户 + `tls.enabled`；
  ② 自签兜底（sni≠cert_domain → 全局自签、单默认用户）。**PASS**
- `bash -n vless-server.sh` 通过；`shellcheck -S error` **0 命中**（基线亦 0，补丁无新增）。

### 存量迁移（老安装：anytls 在 xray 核心 + 跑 vless-anytls 独立服务）

**非自动化**。本补丁默认「新装走 sing-box」；存量安装不自动迁移（避免动到正在跑的
老配置）。迁移用本仓 `migrate-anytls-singbox.sh`：

```bash
sudo bash migrate-anytls-singbox.sh --dry-run  # 只读预演（不改库、不重启）
sudo bash migrate-anytls-singbox.sh            # 实际迁移
```

该脚本做：① 备份 `$CFG/db.json`；② 把 `xray.anytls` 对象**原子搬移**到
`singbox.anytls`（字段兼容：`password/port/sni`，旧格式可直接复用）；③ 停用并禁用
旧独立服务 `vless-anytls`（systemd / OpenRC 都处理）。**最后一步**——重新生成
`singbox.json` 并重启 `vless-singbox`——因需脚本内部函数，请在脚本菜单
「服务管理」里执行（重建 Sing-box 配置 + 重启），迁移脚本会打印该指引。

> 迁移前建议手动再备份一次；先在测试机演练。

---

## 七、-h3 修复：anytls 自签证书补齐 + 分享链接 secure 条件化（2026-10-29 新增）

承接 §六（AnyTLS 移入 sing-box）。回归验证 §六 后发现两个遗留缺陷，一并在此修复，
版本 `3.4.10-h2 → 3.4.10-h3`。

### 修复 ①：`$CFG/certs/anytls/server.crt` 从未被生成 —— 无真证书时 sing-box 加载失败

**问题**：`generate_singbox_config` 的 anytls 分支在 `sni != cert_domain` 时把
`tls.certificate_path` 指向 `$CFG/certs/anytls/server.crt`，但**全脚本没有任何函数
生成该路径**（hy2/tuic 各自在 `gen_hy2_server_config` / `gen_tuic_server_config` 里
`openssl req` 生成，anytls 漏了）。结果：未先申请真证书的机器装 anytls，
sing-box 指向不存在的证书文件 → `vless-singbox` 起不来 / anytls 端口不监听。

**修复**：`gen_anytls_server_config` 增加与 hy2 同构的自签证书生成块（CN 随 SNI，
SNI 变化自动重签；`openssl req -x509 … -subj "/CN=$sni"` 落到
`$CFG/certs/anytls/server.{crt,key}`），补齐「ACME 优先、自签兜底」承诺里的兜底腿。

### 修复 ②：分享链接/订阅导出恒带 `allowInsecure=1` / `skip-cert-verify=true`

**问题**：`gen_anytls_link` 硬编码 `&allowInsecure=1`，订阅/导出也硬编码
`skip-cert-verify=true`。即使服务器已用真实证书，客户端仍跳过证书校验 ——
README §六 那句「去掉 allowInsecure 才真正受益」一直是手工步骤，secure 功能不生效。

**修复**：新增辅助函数 `_anytls_secure <sni>`——当 `$CFG/cert_domain` 与
`$CFG/certs/server.crt` 均存在、`_is_real_cert` 判为真实 CA 证书、且 `sni == cert_domain`
时返回 0（真证书场景）。据此条件化：

- `gen_anytls_link`：真证书时**省略** `&allowInsecure=1`，自签时保留；
- Surge 导出（`show_single_protocol_info` anytls 分支）：`skip-cert-verify=false` / `true`；
- 订阅生成（`add_external_link`、`gen_surge_sub` anytls 分支）：`skip-cert-verify=false` / `true`。

### 验证

- `bash -n` 全过（`vless-server.sh` / `migrate-anytls-singbox.sh` / 三个测试脚本）。
- 单测：`test-gen-anytls.sh`（补 `_info`/`_ok` 桩 + 断言自签证书已生成，CN==sni）、
  `test-anytls-branch.sh`（不变，自签兜底分支仍走全局自签）、
  新增 `test-anytls-secure.sh`（真证书链接去 allowInsecure / 自签保留）。**全部 PASS**。
- `shellcheck -S error`：`vless-server.sh` 0 命中；新交付 `test-anytls-secure.sh` 硬闸门 0 命中。

## 八、-h4 修复：AnyTLS 多用户/分享链接/多端口/BT 拦截/重建入口（2026-10-29 新增）

来源：用户在真实机器上手动测试 AnyTLS 后提出的五个问题，逐条核查（见
`AUDIT-2026-10-29-vless-aio-hardened-anytls.md`）后落地修复。**只有第 2 项是 h3 已修、
用户测的是 h1**，其余为真实缺口。

### 修复 ①：用户级分享链接缺 anytls 分支（问题「看不到 anytls 链接」的真缺口之一）

`_gen_user_share_link`（用户管理 → s 查看用户分享链接）的 `case` 块覆盖
vless/xhttp/vision/ws/vmess-ws/ss2022/hy2/trojan/tuic/socks，**唯独没有 anytls** ⇒
对 anytls 用户恒输出「无法生成链接」。补齐：
`anytls) link=$(gen_anytls_link "$ipv4" "$display_port" "$uuid" "$sni" "$remark") ;;`
（anytls 用户凭证存 `.uuid` 字段，与 hy2 同构。）

> 注：`show_all_share_links` / `show_single_protocol_info` 本来就有 anytls case，
> 所以「一键展示所有分享链接」在正常单端口安装下是正常的。

### 修复 ②：多端口实例在 sing-box 配置里整体消失（问题「菜单有、实际连不上」）

`db_add_port` 会把 `.singbox.<proto>` 从对象转成**数组**；而 `generate_singbox_config`
的 inbound 循环直接 `jq -r '.port'`，对数组取 `.port` 得空 → `continue` →
**整个协议的 inbound 不生成**，但分享链接菜单照样打印。⇒ 第二次安装同一协议（anytls/hy2/tuic）
后服务端就没这个入站了。

修复：循环内先判类型，数组则逐元素展开生成多个 inbound（与 `show_all_share_links`
的写法对齐），并给多端口的 inbound `tag` 加 `-<port>` 后缀避免同名冲突
（`anytls-in-18443` / `hy2-in-20001` …）。对 hy2/tuic/shadowsocks 同样生效。

### 修复 ③：多用户「到期 / 启用禁用」对 sing-box 协议不生效（问题「无法限制到期」）

三处缺口：
1. 用户合并 jq 只 `map(select(.enabled != false))`，**不看 `expire_date`** ⇒ 过期用户仍在 inbound；
2. `db_set_user_enabled` 与 `check_and_disable_expired_users` **只重建 xray**，sing-box 不重建；
3. 合并结果未按 `name` 去重，`db_migrate_to_multiuser` 造的重复 `default` 会一起进 inbound。

修复：
- 用户合并增加过期过滤（`expire_date` 为空或 `>= today` 才保留，`--arg today "$(date '+%Y-%m-%d')"`），
  并按 `name` 去重；hy2 与 anytls 两处同步；
- `db_set_user_enabled` 改为按核心分别重建（singbox 走 `rebuild_and_reload_singbox`）；
- `check_and_disable_expired_users` 在禁用后同时重建 xray 与 singbox。

⇒ **到期时间与启用/禁用现在对 anytls/hy2/tuic 真正生效**（重建配置时过滤）。

### 修复 ④：流量配额对 sing-box 协议无法计量 —— 如实告知（问题「无法限制流量」）

官方 SagerNet sing-box 二进制**未编译 `with_v2ray_api`**，没有 per-user gRPC StatsService，
因此无法采集每个用户的流量、配额无法自动触发封禁。这是二进制能力限制，不是脚本 bug
（[river2heaven/sing-box-v2rayapi](https://github.com/river2heaven/sing-box-v2rayapi)
明确记载；需要统计可用
[JuTemp/sing-box-releases-with-traffic-stats](https://github.com/JuTemp/sing-box-releases-with-traffic-stats)）。

处理方式（诚实优先，不假装生效）：
- `_set_user_quota` 对 singbox 协议在设置配额前明确告警「配额写入 DB 但不会自动计量/封禁」；
- `_show_users_list` 在 sing-box 协议用户列表顶部提示「已用恒为 0、配额不自动封禁（到期/禁用有效）」；
- 修正 `generate_singbox_config` 中「精简版 sing-box」的不准确注释为「官方二进制未编译 with_v2ray_api」。

### 修复 ⑤：BT 拦截对 sing-box 协议形同虚设（问题「anytls 是否拦 BT」）

`generate_singbox_config` **确实**下发了 `{"action":"route","outbound":"block","protocol":["bittorrent"]}`
且无 inbound 过滤（全局生效，anytls 受管辖）。但 sing-box ≥1.11 的 route `protocol` 条件
**依赖嗅探结果**，而脚本从未在 sing-box 侧配置嗅探（`grep sniff` 在 singbox 生成器内 = 0，
6 处 sniff 全是 Xray schema）⇒ `protocol:["bittorrent"]` **永不命中**，BT 实际未被拦截。

修复：在 `route.rules` 最前面插入 `{"action":"sniff"}`（sing-box ≥1.11 语法，脚本已用
`action:"route"` 故本就要求 1.11+）。私网 `ip_cidr` 拦截不依赖嗅探，原样保留。

### 修复 ⑥：`_regenerate_config` 对 singbox 是空操作 + 缺「重建配置」菜单项（问题「改配置不生效」）

- `_regenerate_config` 的 singbox 分支指向 `$CFG/singbox/config.json`（**该路径从未被写入**，
  真实文件是 `$CFG/singbox.json`）⇒ 恒早退，什么都不做。改为直接
  `rebuild_and_reload_singbox` 并 `return`（不套用 Xray 的 clients schema）。
- 主菜单新增 **`14) 重建全部配置 (手改 db 后生效)`**，调用 `_regenerate_proxy_configs`，
  并在菜单加提示「配置文件为 db.json 派生产物；手改 db 后请用 14 重建生效」。
  （此前菜单只有「重启/停止/启动」，而 **restart 只重读 singbox.json、不读 db.json**，
  改 db.json 后普通重启无效。）

### 验证（-h4）

- `bash -n` 全过（vless-server.sh + 4 个测试脚本 + migrate）。
- `shellcheck -S error vless-server.sh`：0 命中。
- 单测：`test-anytls-branch.sh` / `test-anytls-secure.sh` / `test-gen-anytls.sh` 全 PASS。
- 新增 `test-singbox-users.sh`：**运行真实的 `generate_singbox_config`**（非复刻逻辑），
  构造 mock db.json 断言——多端口生成 2 个 inbound 且 tag 带端口后缀、禁用用户被过滤、
  过期用户被过滤、`default` 去重、`route.rules[0].action=="sniff"`、
  bittorrent 与私网拦截规则均在。**ALL PASS**。

---

## 九、CI 修复：单测 awk 函数抽取改为 gawk 兼容（2026-10-30 新增）

### 痛点

GitHub Actions（`ubuntu-latest` = Ubuntu 26.04，`/usr/bin/awk` 实为 **gawk**）上，
`syntax + anytls unit tests` 作业的 `anytls secure-link conditional unit test` 步骤
exit 127，报 `_anytls_secure: command not found` / `gen_anytls_link: command not found`。
同一提交在自托管 act_runner（gitpub / gitorca，awk 为 **mawk**）上全绿
⇒ 是测试脚本的 awk 实现差异，**不是被测脚本 `vless-server.sh` 的问题**。

### 根因

`test-anytls-secure.sh` 的 `extract_fn()` 用动态正则抽取函数体：

```bash
awk -v fn="^$fn\\(\\) *\\{$" '$0 ~ fn{f=1} f{print} f&&/^}/{exit}' vless-server.sh
```

gawk 把字符串里的 `\(` `\{` 当作普通 `(` `{`（并打印
`awk: warning: escape sequence '\(' treated as plain '('`），pattern 退化成
`^fn() *{$` —— 其中 `()` 是空组，于是匹配不到源码里的 `fn() {` ⇒ 抽取结果为空文件；
`source` 后调用即 `command not found`。mawk 把 `\(` 当字面量 `(`，故本机与自托管 runner 不复现。

### 修复

- `extract_fn()` 改为 `index($0, fn "()") == 1` 的字符串前缀匹配，不再使用任何正则转义；
- 抽取结果为空或不含 `^fn()` 时**当场 FAIL 退出**，不再让问题留到几十行之后变成 `command not found`；
- CI 新增「awk 可移植性」步骤：runner 上若有 `gawk`，就用 gawk 复跑全部单测
  （无 gawk 则告警跳过），使 gitpub 侧的 mawk runner 也能拦住这类差异。

### 验证（2026-10-30）

- Ubuntu 26.04 容器 + gawk 5.3.2（`awk` 指向 gawk）：修复前 `test-anytls-secure.sh` rc=127、
  6 条 awk 告警；修复后 4 个单测全 PASS、0 告警。
- 本机 mawk 1.3.4：4 个单测全 PASS，无行为变化。
- `bash -n` 全过；`shellcheck -S error test-anytls-secure.sh` 0 命中。

---

## 十、修「更新后仍提示更新」死循环：滚动 tag `dev` 被当成版本号（2026-10-30 新增，v3.4.10-h5）

### 痛点

已装过旧版的机器上，按 README 的一键命令重装后，`vless` 仍然反复提示更新，
接受更新后版本号原地不动、下次进入又提示：

```
  当前版本: v3.4.10-h4
  ▸ 检查最新版本...
  最新版本: vdev
  发现新版本，是否更新? [Y/n]: y
  ✓ 更新成功! v3.4.10-h4 -> v3.4.10-h4
  ...
  发现本仓新版本 vdev（当前 v3.4.10-h4）
```

### 根因（两处叠加，缺一不成故障）

1. **版本来源取错**：本仓 GitHub **没有 Release 对象**（`/releases/latest` → 404），
   `_get_latest_script_version` 于是回退到 `_get_latest_tag_version`，取 `tags?per_page=1`
   的 `.[0].name`。本仓 tag 是**滚动发布名 `dev`**（不是版本号）⇒ 得到字符串 `dev`。
2. **比较函数不设防**：`_version_gt` 逐段比较时，遇到非纯数字段退化为字符串比较，
   于是 `"dev" > "3"` 成立 ⇒ `_version_gt("dev","3.4.10-h4")` **恒为真**，
   无论本地版本是多少都判「有新版本」。
3. 附带后果：更新下载的是 master 上的脚本，其 `VERSION` 仍是 `3.4.10-h4`
   ⇒ 打印「更新成功! v3.4.10-h4 -> v3.4.10-h4」的假成功，且版本号永远追不上 `dev`，
   下次运行继续提示 —— 形成死循环。

### 修复

- 新增 `_is_semver_version()`：只接受 `<数字>[.<数字>...][-h<数字>]`，
  `dev` / `dev3` / `latest` / `nightly` 这类滚动 tag 名一律拒绝；
- `_version_gt()` 入口加防御：任一侧非语义化版本即返回「不更新」，
  绝不让 tag 名参与数字/字符串比较；
- `_get_latest_script_version()` 取值顺序改为
  **release tag → git tag → master 脚本内的 `VERSION` 常量**，
  只采纳且只缓存语义化版本号；读到历史脏缓存（旧版写入的 `dev`）立即丢弃重取；
- 新增 `_get_remote_script_version_from_raw()`：用 HTTP `Range: 0-4095` 只取脚本前 4KB
  读 `readonly VERSION=`（该常量在第 23 行），**不下载整个 ~1MB 脚本**；
  Range 不被支持时回退整文件下载；
- `_has_script_update()` / `_get_script_update_info()` 读缓存时同样校验语义化版本；
- `do_update()` 校验下载到的版本号：非语义化版本或「远端发布版本 > master 脚本版本」
  时**中止更新并纠正缓存**，不再打印 `vX -> vX` 的假成功；
- `VERSION` 升到 `3.4.10-h5`（旧版 h4 的判定逻辑有 bug，只能靠一次真实升级把
  修复后的脚本装上去，故必须抬版本号让存量机器能升级到修复版）。

### 验证（2026-10-30）

- 新增单测 `test-version-check.sh`（全离线，网络函数用 stub）：**37 条硬断言 + 1 条真网
  冒烟软检查**（输出 38 行 OK）覆盖
  `_is_semver_version` / `_version_gt`（含 `h10 > h9` 数字比较）/ 脏缓存自愈 /
  tag 回退 / 全来源失败不写缓存 / 菜单读缓存路径，mawk 与 gawk 5.3.2 均 PASS；
- 真实 GitHub 端到端（不打 stub）：干净缓存解析出 `3.4.10-h4`（发布 h5 前）、
  缓存写脏为 `dev` 后自动纠正、本地 h4 判「已是最新」、本地 h3 判「提示更新」；
- `bash -n` 全过；`shellcheck -S error` 对 `vless-server.sh` 与 `test-version-check.sh` 均 0 命中；
- CI 增列：`bash -n test-version-check.sh`、单测步骤、gawk 复跑清单、shellcheck 硬闸门。

### 判据失效条件

- 「非语义化版本号一律不更新」：仅对本仓「tag 名不是版本号」的发布模型成立。
  2026-10-30 起本仓已建 Release（语义化 tag `v3.4.10-h5`），**release 路径直接命中**，
  raw 回退只在 Release 缺失时触发（逻辑仍然正确）。由此新增一条依赖：
  **Release 必须与脚本 `VERSION` 保持一致**——Release 一旦落后于 `VERSION`，
  存量机器会读到旧版本号而判「已是最新」，**永远收不到更新提示**（静默故障）。
  该一致性由 CI 的 `sync-release.sh` 幂等维护（见 §十一），不要手工乱建 Release。
- 「只取前 4KB 即可读到 VERSION」：依赖 `readonly VERSION=` 位于脚本前 4KB 内
  （当前第 23 行）。若将来把该常量移到文件更靠后，需调大 Range 或回退整文件下载
  （代码已有整文件回退，不会静默失败）。
- 「h4 存量机器能靠一次升级自愈」：成立的前提是用户**接受一次**更新提示；
  旧版判定逻辑本身有 bug，无法远程自我修正，只能靠覆盖安装或接受一次升级。

---

## 十一、发布流程闸门：CI 强制「抬 VERSION」+ GitHub Release 幂等同步（2026-10-30 新增）

### 痛点

§十 的死循环能发生，有一条**流程**成因：上一轮只改了测试/CI 层，
`vless-server.sh` 一个字节没变、`VERSION` 也没抬，于是用户按 README 重装拿到的
还是同一份 `3.4.10-h4`——**修了但用户装不到**。而这类失误没有任何机制拦得住。

同时，§十 的修复让版本检查有了新的依赖面：一旦本仓建了 Release，客户端就**优先**
读 `/releases/latest` 的 tag 名。若某次发版忘了同步 Release，Release 会停在旧版本号，
存量机器读到「远端 = 本地」⇒ 判「已是最新」⇒ **永远收不到更新提示**。
这是死循环的**反面**，更隐蔽（无报错、无提示、只是永远不更新）。

### 修复

**① `check-version-bump.sh` —— 改了脚本就必须抬 `readonly VERSION=`（CI 硬闸门）**

- 比较「基准」与当前工作树的 `vless-server.sh` sha256：未变 → 通过；变了 → 要求
  `VERSION` **单调递增**（用与脚本内 `_version_gt` 完全一致的算法比较，含 `-h<n>` 后缀）；
  变了但 `VERSION` 没动 → **CI 失败**并给出可直接照做的修复指引；
- 基准按可用性降级：`--base`（CI 传 `push.before` / PR base sha）→ `HEAD^`
  （gitorca 带全历史的正本）→ **仓库内最高的语义化 tag `v<X>`**
  （gitpub / GitHub 是无父单 commit 快照，没有父提交；该 tag 由 ② 幂等维护，
  正好等于「上一次发布」的锚点）→ 都没有则告警放行（首次发布可接受）；
- 额外拦住：`VERSION` 非语义化（`dev` 之类）、`VERSION` 回退或不可比、脚本缺
  `readonly VERSION=` 常量——这三种都会让客户端**永远收不到更新提示**。

**② `.github/scripts/sync-release.sh` —— Release 与 `VERSION` 恒一致（幂等）**

- 读脚本 `VERSION` → tag 名 `v<VERSION>` → `/releases/tags/v<VERSION>` 已存在则 no-op，
  缺失则 `POST /releases`（`target_commitish` = 本次提交，`draft/prerelease` 均 false）；
- 用**仓库自带 `GITHUB_TOKEN`**（`permissions: contents: write`），不需要外部 PAT；
  作业用 `if:` 限定只在 GitHub 侧、`master` push 上跑（gitorca/gitpub 不建 Release）；
- **纵深防御：脚本自己也判定一次**。非 `api.github.com` 时脚本**跳过并 exit 0**
  （`RELEASE_SYNC=skipped`），不依赖 `if:` 一定写对——若 `if:` 哪天被改坏，
  私有侧也不会因「这里不是 GitHub」而红；
- **安全阀**：若已存在**高于** `VERSION` 的 Release（回滚/误发），直接失败——
  否则用户会被提示升级到 master 上并不存在的版本，更新后版本号追不上 ⇒ 又是死循环；
- 建完**读回核验** `/releases/latest` 必须就是该 tag（带 5 次重试），不认 POST 201。

**③ `ci.yml`**：新增 `version-bump-gate`（`fetch-depth: 0`，否则浅克隆会让闸门静默放行）
与 `github-release` 两个作业；`bash -n`、shellcheck 硬闸门、单测清单同步扩列。

> **可移植性说明（2026-10-30 实测，含一次自我纠错）**：
> - Gitea 1.27.3 的 `if:` **是生效的**：gitpub run 86 日志明确记录
>   `expression '...' evaluated to 'false'` → `Skipping job 'GitHub Release 同步'`。
> - 但 Gitea 的 `actions/tasks` API 在 runner 求值之前会把该作业显示为 `queued`，
>   **不能据此判断 `if:` 失效**（本轮一度据此误判，实际是观察时机问题）。
> - 闸门作业仍**刻意不含任何 `${{ }}` 表达式**（基准全部由脚本用 `git` 自己算）：
>   这是简化与可移植性取舍，**不是**修复观测到的缺陷。三端共用同一份 `ci.yml`，
>   少一处表达式就少一处跨实现差异。
> - 实测教训：CI runner 自身会导出 `GITHUB_API_URL`（私有侧是 Gitea 的 `/api/v1`），
>   单测必须**显式控制**它，否则会继承环境、断言失真（本轮 `test-sync-release.sh` 踩了）。

### 验证（2026-10-30）

- `test-version-bump-gate.sh`：**19 条断言**，两条基准路径各覆盖一遍——
  有父提交（未改/抬版本/未抬/回退/`h9→h10` 数字比较/跨基础版本）与
  无父提交（未抬被拦/抬了通过/无语义化 tag 跳过/只有滚动 tag `dev` 视为无基准/
  多 tag 取最高/`--base` 显式指定/全 0 哨兵值降级）；纯本地临时 git 仓，全离线；
- `test-sync-release.sh`：**25 条断言**，用本地 mock GitHub API（`test/mock-github-api.py`）
  覆盖创建/幂等/安全阀/draft 与 prerelease 忽略/非语义化 tag 干扰/读回失败/
  **非 GitHub 侧跳过**；**不会建出任何真 Release**；
- 真实仓库实测（`/tmp/vah-git`，非模拟）：把脚本内容改掉但 `VERSION` 不动 → 闸门 rc=1
  并给出「抬到 3.4.10-h6」的指引；再抬 `VERSION` → rc=0；
- `bash -n` 全过；`shellcheck -S error` 与 `-S warning` 对 4 个新脚本均 0 命中；
- CI 实跑（见下方「验证结果」）：GitHub run 两端作业 success，Release 由作业自动建成。

### 验证结果（2026-10-30 本版发布）

- GitHub Release `v3.4.10-h5` 由 `github-release` 作业创建，
  `/releases/latest` → `v3.4.10-h5`（客户端解析为 `3.4.10-h5`，release 快路径命中）；
- `version-bump-gate` 在 gitorca（全历史 → `HEAD^` 基准）与 GitHub
  （无父快照 → 语义化 tag 基准）两种仓形态下均实跑通过。

### 判据失效条件

- 「改了脚本必须抬 VERSION」：前提是**用户装的是 raw master 上的脚本**（README 的安装方式）。
  若哪天改为分发 Release 资产或固定 tag，这条约定要跟着改（闸门本身仍然有意义）。
- 「无父提交时用最高语义化 tag 当基准」：前提是 **② 在每次发版后确实建了 tag**。
  若 CI 的 `github-release` 作业被长期禁用（或仓库换了 GitHub 之外的主机导致 `if:` 不命中），
  该降级路径会退化成「无基准 → 告警放行」，闸门在 gitpub/GitHub 侧就**只剩告警**，
  真正的强制点回到 gitorca（有父提交，始终有效）。
- 「Release 与 VERSION 恒一致」：由 `sync-release.sh` 保证，但它只在 GitHub 侧跑。
  **手工在 GitHub 网页上建/改 Release 会绕过该保证**——要改版本必须走发版流程（改脚本 VERSION）。
- 「安全阀拦住超前 Release」：只看非 draft / 非 prerelease。若有人把超前版本以
  draft/prerelease 形式留着，安全阀看不见（但也正因如此客户端也读不到它，无实际风险）。
- 「闸门按提交的**净效果**判定」：基准是 `HEAD^`（或最高语义化 tag），比的是
  「基准 ↔ 工作树」。若**一次 push 含多个提交**、中间某个提交改了脚本没抬版本、
  而最后一个提交又抬了版本，净效果是「脚本变了 + 版本抬了」⇒ 闸门放行。
  这是有意的取舍（刻意不用 `github.event.before` 这类表达式，换三端可移植性）；
  真要逐提交校验，就在本地跑 `bash check-version-bump.sh --base <每个父提交>`。
