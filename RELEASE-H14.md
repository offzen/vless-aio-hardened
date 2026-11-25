# H14 新版本发布与部署／升级手册

## 1. 版本身份

| 项目 | 身份 |
|---|---|
| 上游与兼容握手 | Chil30 3.4.10；`3.4.10-h14` |
| 当前产品 SHA-256 | `6ea18a9e5af7ca2802ee6982d478d042ffcbcd4108b3a978c26e50aaf77eaa34` |
| 已验收代码 commit | `90dea0335f646c5d6e69cc7d3ad41919ef2da16f` |
| 已验收 tree | `0019ae4fab386547a7fecf6a1a830a4d1080f881` |
| 代码验收 | private CI run288，15 required verified |
| 历史 H13 产品 SHA | `33c953bde77f587cb6601751ea404f92b134be0cc663c2e765685393225dfa88` |

早期 H14 `e7c52036949398f10391ac3ae3724558995e42cd7be3b4654de21e6c9d44f137` 为历史草案，不是本次产品。此文档包在验收后更新，产品字节未改；新文档哈希独立记录在 [SHA256SUMS](./SHA256SUMS)、[PROVENANCE.json](./PROVENANCE.json)，不伪称新文档已包含在 run288 commit 内。

### 发布状态

本次完成内容寻址候选的部署与文档更新，**不代表 canonical main/master、tag 或公开 Release 已更新**。run288 的 Release job skipped，无发布执行。菜单 12 仍指向脚本历史固定在线源，本轮未核验该源与本产品相同；请使用已核验的本地包或精确 commit 制品，不依赖在线“最新版”。

## 2. H14 的更新内容

- 传统 SS 的显式 `users` 生成 Xray `settings.clients`，不再使用会被静默忽略的 `settings.users`；链接、菜单与运行配置使用一致凭据和端口。
- 禁用/过期用户过滤；显式空表或零有效 SS 用户不生成该 inbound，不回退顶层密码。无 `users` 字段旧库仍可用原单密码。
- 四个 partial identifier（`vless-xhttp-cdn`、`vless-ws-notls`、`trojan-ws`、`ss2022`）只保留单用户运行，拒绝逐用户管理；selector 隐藏、DB 写前 fail closed。
- 11 supported row 动态合同、固定 Xray/sing-box parser 与数据面、真实 H13→H14 fresh-process 重渲染、mawk/gawk、Web root、Docker required 验收齐全。
- 所有已知 source fixture 显式设置测试 CFG 并校验身份，避免旧 sed 未命中而落到生产目录；普通运行默认路径不变。

逐条说明、历史与已知限制见 [CHANGELOG.md](./CHANGELOG.md)、[FIXES.md](./FIXES.md)。

## 3. 使用同一套校验包

交付包包含产品、README、USAGE、CHANGELOG、RELEASE-H14、FIXES、以及校验清单和 provenance。测试/CI 不参与终端安装。校验清单不包含自身与 provenance，避免递归哈希；provenance 的产品与代码身份需单独核对。

在目标主机的包目录执行：

```bash
sha256sum -c SHA256SUMS
printf '%s  %s\n' \
  6ea18a9e5af7ca2802ee6982d478d042ffcbcd4108b3a978c26e50aaf77eaa34 \
  vless-server.sh | sha256sum -c -
./vless-server.sh --help
```

文件可能需要先 `chmod +x vless-server.sh`。仅 `--help` 不初始化业务数据；无参数启动会迁移/初始化 DB 并同步系统脚本与快捷入口。因此旧版必须先备份。

## 4. 全新部署

先核对 root 权限、兼容 OS/服务管理器、所需核心、端口占用与现有防火墙放行。不要自动占用共享 Nginx/Caddy/邮件端口。普通向导会安装系统依赖、下载所选核心，并可能影响 DNS64、IPv6、cron、证书等，须按目标最小执行。

常规交互路径：校验后 `sudo ./vless-server.sh`，选择 `1 安装协议`，配置端口与用户，再完成第 6 节验收。

deployment host 本次采用**最小编排部署**：不启动完整交互向导、不改产品字节，预先固定 Xray，写入初始 DB，source-only 加载原样产品，调用真实配置和 systemd unit 生成器；避免不需要的 TLS/ACME、DNS64、NAT、BBR、WARP、cron 与 Web 组件。它是实际持久运行部署，不是一次性 Docker fixture；也不声称覆盖整个安装向导。

## 5. 从 H13／旧版本手工升级

### 启动前备份

备份应置于 root-only 目录；以下示例仅处理已核对的目标文件，不包含凭据回显：

```bash
umask 077
backup="/root/vless-pre-h14-$(date -u +%Y%m%dT%H%M%SZ)"
install -d -m 0700 "$backup"
cp -a /etc/vless-reality "$backup/"
cp -a /usr/local/bin/vless-server.sh "$backup/"
```

同时记录已安装协议/端口、unit 与核心版本；存在 CF Tunnel、cron、Nginx/Caddy、NAT、sysctl 等辅助状态时备份对应状态。不要先运行新脚本再补备份，也不要把 DB、私钥、URI 放进发行包或日志。

### 替换与重建

在同目录暂存经 SHA 核验的产品，再原子替换目标。管理员先确认下列固定目标正是现役系统脚本；不得对猜测路径执行移动：

```bash
install -m 0755 ./vless-server.sh /usr/local/bin/vless-server.sh.h14-new
mv -- /usr/local/bin/vless-server.sh.h14-new /usr/local/bin/vless-server.sh
/usr/local/bin/vless-server.sh
```

从新进程进入菜单，选择 `14 重建全部配置`。该菜单会尝试重建/重启 Xray、sing-box，但最终提示/返回值不是可靠验收。手工替换路径不冒充真实调用了 `do_update()`；H13→H14 updater 证据来自已绑定 CI 制品测试。

## 6. 部署／升级后的验收

只检查实际安装的核心与其精确配置文件，**不要对整个包含 DB 的目录做 Xray `-confdir`**：

```bash
xray run -test -c /etc/vless-reality/config.json
# 只有安装了 sing-box 时才运行：
sing-box check -c /etc/vless-reality/singbox.json
systemctl is-active vless-reality.service
systemctl is-enabled vless-reality.service
ss -ltnp
```

sing-box 对应 unit 为 `vless-singbox.service`。Alpine 应使用 OpenRC 的实际服务名，不照抄 systemd 命令。

必需验收包括：

1. 安装后产品 SHA、核心版本与预期一致；JSON/schema 原生解析通过。
2. DB、URI 与生成凭据相同；禁用/过期用户不在配置中；SS 显式零有效用户不重新启用顶层密码。
3. 对应服务 active、预期启动配置、无重启循环，端口由预期进程监听。
4. 默认与非默认启用用户经真实客户端访问成功；禁用用户拒绝时 client/server/目标仍可用，不能把全部网络不可达当作负向成功。
5. 共享服务、容器、DB 与防火墙无意外变化；密码/URI 权限受限，不打印。

CI parser 通过不等于现场已运行，监听也不等于认证通过。公网 TCP 建连只是入站可达；完整外部客户端数据面需另有直接收据。

## 7. 失败处理与恢复

`do_update()` 在已验证新脚本替换后依次尝试三个自动应用步骤；部分失败返回非零、保留新脚本与 `.bak`，**不自动回滚**。菜单 14 不承诺这一返回码合同；不要写成“失败会自动恢复旧版”。

失败先保留诊断，记录未验证项；需要恢复时使用启动前的脚本、DB、派生配置和必要 unit/核心备份，先验证旧配置，再按精确服务边界恢复。不要只恢复脚本，不运行宽泛 pkill，不删除无法确认归属的 `vless-*` 或共享组件。已有生产恢复须有对应前态和备份，不拿其它主机的配置冒充。

## 8. 已验现场范围（去敏摘要）

Debian 12 x86_64 全新安装传统 SS aes-256-gcm，TCP443，固定 Xray26.3.27；真实 systemd/native parser、两启用凭据正向与一禁用负向、外部客户端 HTTP204 和共享状态保护已验。不是旧版现场原位升级，未外推所有协议或宿主重启健康。内部 PID、主机别名、备份身份与收据不进入此包。
