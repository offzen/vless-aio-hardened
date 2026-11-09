# FIXES — 改动清单与验证记录

基线：`vless-all-in-one` v3.4.10 服务端脚本；当前冻结修订 `3.4.10-h13`。`master` 制品仍是唯一真相源，VERSION 仅作兼容握手；本节所列 H13 结论只适用于冻结脚本 SHA `33c953bde77f587cb6601751ea404f92b134be0cc663c2e765685393225dfa88`。

本文件逐条列出改动、位置与验证方式，便于审核与回归。

## 十二、H13 证据收敛候选（2026-11-09）

- **候选身份 fail-closed**：生命周期 E2E 不再接受硬编码旧 SHA 或 dirty bypass；release gate 必须注入 64 位小写 SHA-256，并在宿主与容器内双重核对。产品或测试脚本任一字节变化后，旧收据失效。
- **updater 部分失败返回非零**：脚本完成校验和替换后，仍依次尝试 `init_db`、Xray 重建/重载、sing-box 重建/重载；任一步失败时保留新脚本与 `.bak`，明确要求人工核对/重建，并以非零退出，不再把自动应用失败冒充完整成功。
- **版本兼容握手**：`readonly VERSION` 单调抬升为 `3.4.10-h13`，用于 H4/H5/H12 客户端发现与防降级；同版本不同字节仍按滚动 `master` 允许更新。
- **最终门禁结果**：冻结 H13 产品 SHA 后，16 个命名离线脚本全部通过；updater 集成 97/97；Xray 日志路径 mutation 4/4；候选身份 fail-closed 4/4；注入该精确 SHA 的 Docker 隔离生命周期 E2E 9/9，并完成真实 Xray 26.3.27 数据面与零容器/镜像遗留核验。固定 sing-box 1.13.0 对 H13 生成的 1247-byte AnyTLS 配置执行原生 `check` rc=0，私有网络命名空间 AnyTLS→SOCKS→HTTP marker 数据面通过。私有 manifest 和测试收据已绑定产品与关键测试脚本 SHA。普通 CI 中 `test-webroot-ownership.sh` 仍可能因 runner 不支持 user/mount namespace 而以 SKIP 0 退出；只有明确未跳过的受控环境运行可作为该项 required 证据。

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
老配置）。先备份整个 `$CFG`，尤其是 `db.json`、证书与私钥，再按 `USAGE.md` 的迁移边界
人工核对数据库、用当前菜单重建配置，并逐项验证服务与真实连接。

旧的独立迁移脚本存在覆盖既有 `singbox.anytls`、先停旧服务且无法证明新服务可用等风险，
因此不随 H13 发行。不要从旧提交复制或执行该脚本。

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

- `bash -n` 全过（`vless-server.sh` 与三个测试脚本）。
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
同一提交在自托管 self-hosted runner（awk 为 **mawk**）上全绿
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
  （无 gawk 则告警跳过），使 mawk runner 也能拦住这类差异。

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
  （带全历史的正本）→ **仓库内最高的语义化 tag `v<X>`**
  （历史发布快照曾采用无父单 commit、没有父提交；该 tag 由 ② 幂等维护，
  正好等于「上一次发布」的锚点）→ 都没有则告警放行（首次发布可接受）；
- 额外拦住：`VERSION` 非语义化（`dev` 之类）、`VERSION` 回退或不可比、脚本缺
  `readonly VERSION=` 常量——这三种都会让客户端**永远收不到更新提示**。

**② `.github/scripts/sync-release.sh` —— Release 与 `VERSION` 恒一致（幂等）**

- 读脚本 `VERSION` → tag 名 `v<VERSION>` → `/releases/tags/v<VERSION>` 已存在则 no-op，
  缺失则 `POST /releases`（`target_commitish` = 本次提交，`draft/prerelease` 均 false）；
- 历史实现使用托管 CI 的仓库级短期凭据（`permissions: contents: write`），不需要外部 PAT；
  作业用 `if:` 限定只在对应托管 CI 的 `master` push 上跑（私有 Gitea 侧不建 Release）；
- **纵深防御：脚本自己也判定一次**。非 `api.github.com` 时脚本**跳过并 exit 0**
  （`RELEASE_SYNC=skipped`），不依赖 `if:` 一定写对——若 `if:` 哪天被改坏，
  私有侧也不会因「这里不是 GitHub」而红；
- **安全阀**：若已存在**高于** `VERSION` 的 Release（回滚/误发），直接失败——
  否则用户会被提示升级到 master 上并不存在的版本，更新后版本号追不上 ⇒ 又是死循环；
- 建完**读回核验** `/releases/latest` 必须就是该 tag（带 5 次重试），不认 POST 201。

**③ `ci.yml`**：新增 `version-bump-gate`（`fetch-depth: 0`，否则浅克隆会让闸门静默放行）
与 `github-release` 两个作业；`bash -n`、shellcheck 硬闸门、单测清单同步扩列。

> **可移植性说明（2026-10-30 实测，含一次自我纠错）**：
> - Gitea 1.27.3 的 `if:` **是生效的**：私有 CI 历史 run 86 日志明确记录
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
- CI 实跑见下方「验证结果」：私有 CI run 88 与托管 CI run 41025032838 全绿，
  Release 由 `github-release` 作业自动建成。

### 验证结果（2026-10-30 本版发布，逐条实跑取证）

**① Release 对象（本版的核心交付）**

- `github-release` 作业在 GitHub 上自动建成 Release `v3.4.10-h5`
  （`created_at 2026-10-30T08:13:38Z`，`target_commitish c8effa5`，`draft=false`，
  `prerelease=false`），仓库 `releases` 计数 **0 → 1**；
- `/releases/latest` → `tag_name = v3.4.10-h5`，客户端 `sed 's/^v//'` 后得 `3.4.10-h5`
  ⇒ **release 快路径命中**，不再依赖 raw 4KB Range 回退；
- 真实网络端到端（用脚本里**真实的**函数，不打 stub）：`_get_latest_version()` → `3.4.10-h5`、
  `_get_latest_script_version()` → `3.4.10-h5`；与本地版本比较的最终结论：
  本地 `h5` ⇒「已是最新」（**死循环未复发**）、本地 `h4`/`h3` ⇒「提示更新」。
- 附带发现：建了语义化 tag 之后，`_get_latest_tag_version()`（`tags?per_page=1`）
  现在返回 `3.4.10-h5` 而不再是滚动名 `dev` ⇒ **tag 回退路径也顺带变得可用**。
  但不要依赖它：GitHub 的 tags 排序无正式承诺，若它返回滚动 tag 名，
  `_is_semver_version()` 会拒绝并继续回退到 raw（两条路都安全）。

**② VERSION 抬升闸门（两种仓形态各实跑一次）**

| 仓形态 | 基准来源 | 实跑结果 |
|---|---|---|
| 托管侧（历史无父单 commit 快照） | `tag v3.4.10-h5`（日志原文：`基准：tag v3.4.10-h5（c8effa5）`） | ✅ success，判定「内容未变，无需抬升」 |
| 私有发布侧（历史无父快照、无语义化 tag） | 无 → 告警跳过 | ✅ success，日志：`无法确定发布基准…跳过 VERSION 抬升校验` |
| 全历史私有正本 | `HEAD^` | ⚠️ **未核 CI**；该路径以**本地全历史仓实测**替代：改脚本不抬版本 → `rc=1` 并给出抬到 `3.4.10-h6` 的指引，抬了 → `rc=0` |

- 拦截能力的真实验证（本地，非模拟脚本）：把 `vless-server.sh` 改掉但 `VERSION` 不动 →
  `check-version-bump.sh --base HEAD` 返回 **rc=1**；抬到 `h6` → **rc=0**。

**③ CI 全绿（本版最终快照）**

- 私有 CI run **88**（`fab15e0`）：`syntax + anytls unit tests` ✅、`shellcheck + bashate` ✅、
  `VERSION 抬升闸门` ✅、托管 Release 同步 = **skipped**（`if:` 生效）；
- 托管 CI run **41025032838**（`c8effa5`）：4 个作业全部 ✅（含两个新作业）。

**④ 发布链自身的历史（如实记录）**

- 私有 CI run 86：4 作业全绿（该快照的 `if:` 已正确 skip 掉 release 作业）；
- 私有 CI run 87：**红** —— `test-sync-release.sh` 继承了 runner 导出的 `GITHUB_API_URL`
  （私有侧指向 Gitea `/api/v1`），导致「缺 GITHUB_REPOSITORY 应 exit 2」被误判为走了
  「非 GitHub 跳过」分支。已在 run 88 前修掉（用例显式覆盖该变量），并在此留档。

### 判据失效条件

- 「改了脚本必须抬 VERSION」：前提是**用户装的是 raw master 上的脚本**（README 的安装方式）。
  若哪天改为分发 Release 资产或固定 tag，这条约定要跟着改（闸门本身仍然有意义）。
- 「无父提交时用最高语义化 tag 当基准」：前提是 **② 在每次发版后确实建了 tag**。
  若 CI 的 `github-release` 作业被长期禁用（或仓库换了 GitHub 之外的主机导致 `if:` 不命中），
  该降级路径会退化成「无基准 → 告警放行」，闸门在无父发布快照侧就**只剩告警**，
  真正的强制点回到带父提交的全历史正本。
- 「Release 与 VERSION 恒一致」：由 `sync-release.sh` 保证，但它只在 GitHub 侧跑。
  **手工在 GitHub 网页上建/改 Release 会绕过该保证**——要改版本必须走发版流程（改脚本 VERSION）。
- 「安全阀拦住超前 Release」：只看非 draft / 非 prerelease。若有人把超前版本以
  draft/prerelease 形式留着，安全阀看不见（但也正因如此客户端也读不到它，无实际风险）。
- 「闸门按提交的**净效果**判定」：基准是 `HEAD^`（或最高语义化 tag），比的是
  「基准 ↔ 工作树」。若**一次 push 含多个提交**、中间某个提交改了脚本没抬版本、
  而最后一个提交又抬了版本，净效果是「脚本变了 + 版本抬了」⇒ 闸门放行。
  这是有意的取舍（刻意不用 `github.event.before` 这类表达式，换三端可移植性）；
  真要逐提交校验，就在本地跑 `bash check-version-bump.sh --base <每个父提交>`。

---

## 历史正本延续：h6–h11

> 以下章节从私有历史正本提交 `b582338` 恢复。它们保留 h6–h11 的问题、修复、实测与失效条件；H13 新证据见本文开头的 H13 章节，两者不得互相替代。旧发布平台操作文字仅作历史证据，不构成当前写入入口。

### 十一、HTTP-01 失败后切换 DNS-01 报 `command not found`（h6）

#### 症状与根因

用户先选 HTTP-01；当 80 端口被其他服务占用、申请失败后，在错误处理菜单选
「使用 DNS 验证模式」，脚本调用了从未定义的 `get_acme_cert_dns "$domain" "$protocol"`，
因此立即报 `command not found`，随后上层把失败当成证书申请失败并生成自签证书。
这不是 DNS-01 本身失败，更不代表第二次申请成功。

脚本已有唯一 DNS-01 实现 `_issue_cert_dns <domain> <cert_dir> <protocol>`；首次直接选择
DNS 验证的分支本来就正确调用它，只有「HTTP 失败后切 DNS」这个二级入口名称和参数写错。

#### 修复

把错误处理菜单的调用改为：

```bash
_issue_cert_dns "$domain" "$cert_dir" "$protocol"
```

不改证书流程、服务商选择或凭据处理，属于单行最小修复。

#### 回归验证

新增 `test-acme-dns-fallback.sh`，静态验证三件事：

1. 不再存在未定义的 `get_acme_cert_dns` 调用；
2. 首次选择 DNS 与 HTTP 失败后切 DNS 两个入口都向 `_issue_cert_dns` 传齐三参；
3. `_issue_cert_dns()` 定义存在且唯一。

该测试已接入 CI 的 `bash -n`、功能测试和 ShellCheck error 级闸门。

---

### 十二、DNS-01 使用 Cloudflare Token 仍无法签发（h7）

#### 现场复现与根因

在隔离测试环境用 h6 继续测试发现三项独立问题：

1. 脚本硬编码 `admin@example.com` 并把它注册为 ACME 联系邮箱；`example.com` 是保留示例域，Let's Encrypt 明确以 `invalidContact` 拒绝。
2. DNS 签发命令位于 `acme.sh | tee | grep | sed` 管道中，`if` 取得的是最后一个过滤命令的状态，而不是 `acme.sh` 的真实返回码，存在失败被误判为成功的风险。
3. Cloudflare Token `active` 只代表 token 本身有效，不代表它覆盖目标 zone。测试 token 不覆盖目标测试 zone；逐级查询成功返回空结果，因此不能为该 zone 写 TXT。

隔离复现还显示 ZeroSSL 在 DNS 插件运行前即以 `rejectedIdentifier: DNS identifier is disallowed` 拒绝测试标识符；因此不能把所有失败都归因于 CF token。

#### 修复

- 不再使用保留示例域邮箱；支持通过 `ACME_ACCOUNT_EMAIL` 提供真实邮箱，未提供时为 Let's Encrypt 注册无邮箱账户；
- DNS-01 明确使用 Let's Encrypt，绕开现场 ZeroSSL 对该标识符的策略拒绝；
- Cloudflare 分支在 CA 下单前只读检查 token 状态并逐级查找目标 zone；token active 但不覆盖 zone 时给出明确错误；
- Token 输入改为静默读取；签发后立即清空相关环境变量；
- 先保存 `acme.sh` 退出码，再单独过滤日志展示；
- `--install-cert` 失败不再继续写成功状态。

#### 回归验证

`test-acme-dns-fallback.sh` 最终扩为 7 条断言：原 h6 三项，加上返回码判据、Cloudflare zone 预检、禁止保留示例邮箱，以及禁止组合会被 acme.sh v3.1.7 解析为 production 的 `--server letsencrypt --staging` 参数。本地 h7 候选的语法、7/7 回归、19/19 VERSION 闸门、版本判定和 ShellCheck error 级均通过。

隔离环境验收结论（2026-11-01）：

- **verified**：错误 zone token 在 CA 下单前失败，不写 TXT、不替换证书；h7 脚本部署不重启 Reality/Caddy；
- **verified**：使用独立的 root-only 目标 zone token 引用完成 active/zone/DNS read、临时 TXT create/read/delete/absent；
- **verified（纠错后）**：首轮 `--server letsencrypt --staging` 实际仍命中 production，不能作为 staging 证据；经源码复核和用户确认后，改用明确 staging directory 补跑成功（issuer 含 `(STAGING)`），测试 SAN 与私钥匹配。production DNS-01 也成功；实际顺序为 production 后补验真正 staging；
- **verified**：正式证书安装后 Reality PID 与 `NRestarts=0` 不变，端到端探针返回 HTTP 204；Caddy 未 stop/restart，邮件入口状态保持 302/200/302，challenge/probe TXT 均无残留。

运维边界：该次签发使用隔离 ACME home，因此**自动续期尚未配置**；不要把这次一次性验证误写成续期已启用。现场完整证据、回滚目录与适用范围见外部审计交付物。

---

### 十三、订阅/Nginx 默认关闭与 Reality 多端口解耦（h8）

#### 现场触发

在已有 `8443` Reality 的 Debian 主机新增 `9443` Reality，并复用真实证书域名时，旧逻辑在最终安装确认前就自动生成订阅文件、写 Nginx 配置并尝试启动 Nginx。发行版默认站点要监听 `:80`，与现役共享 Web 服务冲突，留下 `nginx.service=failed`；同时新端口被生成成 `dest=127.0.0.1:8443`，把 Reality 数据面错误绑定到未运行的本机 Nginx/另一个 Xray inbound。

另一个既有缺陷是：生成的独立 `watchdog.sh` 调用了只存在于主脚本作用域的 `_pgrep`，journal 每分钟出现 `command not found`。

#### 修复

1. 协议安装、证书复用和 ACME 路径只处理协议与证书，**不再**生成订阅、不再安装/配置/启停 Nginx；HTTP-01 发现 80 被占用时明确失败并提示 DNS-01，不自动停止共享 Web 服务。
2. 菜单 6 是唯一订阅启用入口；进入后还需再次输入 `y` opt-in，之后才允许首次生成订阅或安装 Nginx。`generate_sub_files` / `create_fake_website` / `setup_nginx_sub` 均增加显式调用守卫。
3. 停用订阅、卸载协议/整套脚本只删除本项目文件，并对正在运行的共享 Nginx 做语法检查后平滑 reload；不自动 stop/disable，不删除发行版默认站点。
4. Reality target 恒为所选 `SNI:443`；删除“真证书域名 → 固定 `127.0.0.1:8443`”改写和隐式 Nginx helper。
5. Reality 选择随机 SNI 时只影响新入站，不再删除共享 `server.crt` / `server.key` / `cert_domain`，避免破坏其它 TLS 协议与续期。
6. 生成的 watchdog 内嵌兼容 `_pgrep`，不再依赖主脚本函数作用域。

#### 回归

- `test-subscription-opt-in.sh`：7 条断言覆盖证书/协议路径无 Nginx 副作用、首次生成订阅与 Nginx 的 opt-in 守卫、停用/卸载不 stop/disable 共享 Nginx、不得删除默认站点、随机 SNI 不删除共享证书。
- `test-reality-target-watchdog.sh`：5 条断言覆盖 Reality target、不依赖本机 8443、watchdog 语法、自包含 helper 及连续两轮进程检测。
- 两个测试均接入 CI 的 syntax、功能和 ShellCheck error 级闸门。

#### 边界

h8 当前只完成源码与隔离回归；尚未在干净 Debian/Alpine 真实组件环境跑完整交互式新装/订阅启停，也未修改已有生产主机的半配置状态。不能仅凭本节宣称 GA 已放行。

---

### 十四、卸载 Web root 所有权与第三方首页保护（h9）

#### 问题与原则

h8 的 `do_uninstall()` 仍无条件删除共享 `/var/www/html/index.html`，而旧 `create_fake_website()` / NaïveProxy 路径还会覆盖既存首页。这无法证明文件属于本项目，也与“共享 Nginx/默认站点保持”承诺冲突。

h9 采用 fail-closed 所有权语义：

1. 全部项目首页入口统一调用 `create_webroot_placeholder()`；路径已存在（含符号链接）即原样保留，不覆盖、不备份、不声称所有权。
2. 只在路径原先不存在时以 `noclobber` 创建 placeholder，并将路径、`device:inode:size:uid:gid:mode` identity 与 SHA-256 写入 root-only 的 `$CFG/webroot-placeholder.meta`。
3. `do_uninstall()` 只调用 `cleanup_webroot_placeholder()`；仅当记录版本/路径、identity 与 SHA-256 全部匹配且目标不是符号链接时才删除。任何修改、替换、记录损坏或工具不可用都保留文件并告警。
4. 所有权检查后总会删除元数据，避免过期记录将未来同路径文件误判为项目资产。

当前 h9 不再替换既存文件，因此新流程无需产生第三方备份。h8 及更早版本若已经覆盖第三方首页且当时未留备份，h9 无法验证或恢复原内容；这是不可逆历史状态，不能伪造恢复语义。

#### 自动回归

新增 `test-webroot-ownership.sh`：

- 在 user/mount/network/PID namespace 中直接 source 完整正式脚本（`VLESS_SOURCE_ONLY=1` 仅跳过 CLI 入口），依次调用真实 `setup_subscription_interactive` → `manage_subscription` 停用分支 → `do_uninstall`；不再抽 helper 或手工模拟生命周期；
- 预置第三方 marker、默认站点软链和 Nginx unit/enable-link fixture；在 before、enable、disable、uninstall 四个阶段逐次断言 marker SHA-256、真实 loopback HTTP 200 响应体 SHA、默认站点链接/目标 hash/元数据、unit hash/元数据/enable-link 全部保持，且不生成项目所有权记录；
- 严格 nginx/systemctl spy 只允许语法检查、enable/reload 及项目自己的卸载动作，任何共享 Nginx stop/disable/restart/mask/kill 或未知调用都会留下粘性失败记录；
- 项目 placeholder 的身份匹配删除与被替换后 fail-closed 仍由正式 helper 语义及 lifecycle 调用覆盖。

同时将 `test-subscription-opt-in.sh` 扩为 8 条断言，新增“卸载不得无条件删除共享首页”；两项均接入 CI 的 syntax、功能与 ShellCheck error 级入口。

#### 边界

本节直接证明本地真实函数控制流、真实 loopback HTTP 内容保持及 Nginx 服务命令契约；没有运行 Debian/Alpine 真实 Nginx 组件或隔离 init/systemd，因此不把 spy/fixture 称为真实 Nginx reload 或 unit 运行态 E2E。也没有远端 CI、生产迁移或旧版本受损首页恢复。

### 十五、手动禁用后空客户端入站仍保留（h9 候选补丁）

`gen_xray_vmess_clients` / `gen_xray_trojan_clients` 已能返回 `[]` 防止禁用用户从顶层 UUID/密码复活，但 `add_xray_inbound_v2` 的 VMess-WS、Trojan/Trojan-WS 分支仍将空客户端 inbound 拼入最终 Xray JSON。候选修复在这些分支中与 VLESS 一致：无启用客户端时跳过该端口，不再留下可监听但没有用户的代理 inbound。

`test-manual-user-disable.sh` 新增混合 enabled VLESS-WS 与 disabled VMess-WS 的完整生成器断言：修复前「disabled VMess-WS has no listener」FAIL，修复后 PASS，且 enabled peer 保留。此为合成配置回归，**不是** Xray 原生校验、实际监听或客户端数据面验收；详细测试分级保存在私有正本的分层测试计划中。

### 十六、Xray 日志路径被写成字面量 shell 语法（h10）

`generate_xray_config` 用四处 `jq -n '...'` 构建配置，jq 程序是**单引号**的，因此其中的 `"${VLESS_TEST_LOG_ROOT:-/var/log}/xray/access.log"` 从未被 shell 展开，而是原样写进 JSON。Xray 启动时真的去 `open()` 这个含 `${...}` 的路径，直接失败：

```text
Failed to start: main: failed to create server > app/log: failed to initialize access logger
  > open ${VLESS_TEST_LOG_ROOT:-/var/log}/xray/access.log: no such file or directory   (rc=23)
```

与此同时第 3000 行的 `mkdir -p "${VLESS_TEST_LOG_ROOT:-/var/log}/xray"` 是 **Bash 层**、会正常展开，于是目录建在真实路径、配置指向字面量路径，两者永远不一致。这是 h9 引入 `VLESS_TEST_LOG_ROOT` 间接层时产生的回归，**影响全新安装**（新装通常无分流规则，正好走无路由分支）。

修复：函数内先算 `local log_root="${VLESS_TEST_LOG_ROOT:-/var/log}/xray"`，四处 jq 增加 `--arg logroot "$log_root"` 并改为 `access: ($logroot + "/access.log")` / `error: ($logroot + "/error.log")`。`VERSION` 抬到 `3.4.10-h10`（版本闸门要求）。

验证：新增 `test-xray-log-path.sh` 强制四个分支（无路由 / 有路由 / 多 IP / 用户规则）逐条断言 `log.access`、`log.error` 等于真实展开路径且生成物不含 `${`；**修复前 12 条断言全部 FAIL，修复后全 PASS**。另在隔离测试机上用真实 Xray 26.3.27 跑 `xray run -test`：`rc=0`、`Configuration OK.`，生成路径为真实临时目录。

升级路径已核对：`do_update` 替换脚本后调用 `rebuild_and_reload_xray "silent"`，因此带字面量旧配置的既有安装**会在脚本升级时自动重建并治愈**，无需额外一次性补丁。

#### 边界

本节证明的是配置生成正确性与 Xray 原生**配置解析**通过；不含真实端口监听、客户端数据面、真实 Nginx/systemd 生命周期或完整安装器 E2E。测试环境现役服务全程未改（MainPID/NRestarts/config/db 指纹前后一致）。

### 3.4.10-h11：日志路径与下载 URL 加固

h10 修复了 `jq -n` 单引号内日志路径字面量的缺陷。h11 在同一缺陷类上补三项加固，并抬升版本号：

1. **`generate_xray_config` 的日志目录只算一次，并检查 `mkdir` 返回值。**
   - 先计算 `log_root="${VLESS_TEST_LOG_ROOT:-/var/log}/xray"`，再用 `mkdir -p "$log_root"` 建目录。
   - 建目录失败时 `_err` 并 `return 1`，不用 `exit`，以免杀掉交互菜单。
   - `VLESS_TEST_LOG_ROOT` 非空且不是绝对路径时直接拒绝。
   - 回退语义不变：未设置或空串都回退 `/var/log`（用 `:-`，不是 `-`）。
   - 修正了过期注释，它原先写的是 `XDG_STATE_HOME`，实际机制是 `VLESS_TEST_LOG_ROOT`。
2. **`_install_binary` 增加"URL 不得残留占位符"断言。** 替换完成后若 `url` 仍含 `$`，报出具体残留的占位符和完整 URL，并 `return 1`，不再发起 `curl`。
3. **`VERSION` 从 `3.4.10-h10` 抬升到 `3.4.10-h11`**，满足 `test-version-bump-gate.sh` 对"行为变更必须抬版本"的要求。

**判据**
- **为什么 `mkdir` 失败必须 fail-fast：** 忽略返回值会产出一个指向不存在目录的 `config.json`，失败被推迟到 Xray 启动期（h9 那种"跑到最后才炸"）。提前到生成期后，错误发生在最靠近原因的位置，调用方能拿到非零返回值，报错也能指向真正的路径。
- **为什么要拒绝相对路径：** `mkdir` 按脚本 cwd 建目录，Xray 按自己的 cwd 打开文件，两者错位会造成"目录存在但服务起不来"，极难排查。
- **为什么下载 URL 要断言无残留 `$`：** URL 模板是单引号的，靠显式替换表展开。表外的新占位符会静默拼出含字面量 `$` 的 URL，只表现为 404 和"下载失败"。这与 h10 的单引号字面量是同一缺陷类，所以让它在请求前就大声失败。

**失效条件：** 若将来日志路径不再走 `VLESS_TEST_LOG_ROOT`，或 `_install_binary` 不再用单引号占位符加显式替换表，本节判据需要重写。

#### 3.4.10-h11 验收证据（三轮真实 E2E，2026-11-07/08）

h11 之前的验收只覆盖"函数级单测"，安装器本身因**无非交互入口**被记为 blocked。本轮用
`pty` 驱动器把 25k 行安装器真正跑通，在三个真实环境各自验收：

| 环境 | 发行版/init | 场景 | 结果 |
|---|---|---|---|
| 测试环境 A | Debian 13 / **systemd 257** | 覆盖现有端口重装（真实安装向导） | 通过 |
| 测试环境 B | Alpine 3.24.4 / **OpenRC**，纯 IPv6 | **全新安装（从零）** | 通过 |
| 测试环境 C | Alpine 3.19.1 / OpenRC | **3.4.8 → 3.4.10-h11 升级** | 通过 |

**关键证据（可复现，非推断）：**

1. **systemd 分支**：`vless-reality.service` / `vless-watchdog.service` 的 mtime 晚于安装时间戳
   ⇒ 证明 `_write_systemd` 确实被执行（而非沿用旧单元）；`systemd-analyze verify` rc=0；
   单元内容与 3.4.8 时代**字节一致**（sha12 `48b9bd326384` 未变）⇒ h11 未无意改动 systemd 单元格式。
2. **OpenRC 全新安装**：`/etc/init.d/vless-reality` 与 `vless-watchdog` **从无到有**被创建
   （mtime > 时间戳，`-x` 可执行），`/etc/runlevels/default/` 建出两条软链，`rc-service status`
   报 started，xray 新 pid 监听配置端口；`xray run -test` rc=0；配置内 `${` 字面量 **0** 处。
3. **真实 reboot 后的启动顺序**：`need net` 生效，重启后 **3 秒内**服务自启、地址恢复、数据面复测 200。
4. **数据面（三轮全部实测）**：真客户端 → reality → 目标站点，HTTP **200**、出口 IP 与直连**一致**、
   `generate_204` = **204**，且 `/var/log/xray/access.log` 运行时有增长（不是仅 `test -w`）。
5. **升级不动数据**：测试环境 C 3.4.8→h11 后 `db.json` sha256 **完全未变**（私有收据保留精确值），
   仅 `config.json` 被重建。

**顺带定论：`routing.rules` 从 1 条变 3 条不是回归。**
3.4.8 脚本内 `bittorrent` 出现 **0** 次、其生成配置只有 1 条 `api` 规则；h11 新增
①拦私网/链路本地（`10/8,172.16/12,192.168/16,127/8,169.254/16,224/4,240/4,fc00::/7,fe80::/10`）
②拦 `bittorrent`，属**有意加固**。注意这两条在 `generate_xray_config` 的 4 个 jq 站点
**各自硬编码**，与 `db_get_routing_rules` 是否为 `[]` **无关**——因此"外层门"只对
**用户自定义分流**成立，写测试时不要假设"无 routing 就没有 rules"。

**本轮暴露的两个可测性/健壮性缺陷（未在本版修复，留待 h12）：**

- `_write_openrc` / `_write_systemd` **嵌套在 `create_service()` 体内**，不是顶层函数。
  `VLESS_SOURCE_ONLY=1` source 后取不到，函数级单测无法覆盖，只能靠端到端。
  建议提升为顶层函数，直接可测。
- 安装流程大量使用**裸 `xray` / `sing-box`** 调用（13 + 6 处），依赖调用方 `$PATH` 含
  `/usr/local/bin`。脚本自身**从不设置 `$PATH`**。真实 Alpine/Debian 的 `/etc/profile`
  都含该路径，故常规场景无碍；但在 `pct exec`、精简容器、非登录 shell 等环境会表现为
  "密钥生成失败"这类**误导性报错**（真正原因是 command not found）。建议改为
  `"$XRAY_BIN"` 之类的绝对路径变量。
