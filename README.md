# vless-aio-hardened

[`vless-all-in-one`](https://gitlab.com/chil30-group/vless-all-in-one)（Chil30，基线 3.4.10）的第三方加固版服务端脚本。

本仓采用滚动 `master` 发布：`master` 中的 `vless-server.sh` 是当前交付制品，不使用独立公开版本号。菜单中的脚本更新直接比较本地与远程 `master` 制品的 SHA-256，不依赖 release 或 tag 名称。

## 功能概览

- 单文件安装与管理脚本：`vless-server.sh`
- 支持 Xray、sing-box 与独立服务协议；多协议可共存，Xray / sing-box 托管协议支持多端口
- 主要用户/协议数据库变更采用安全写入：唯一临时文件、目录锁、原子替换与异常清空护栏
- Xray / sing-box 默认拦截私网目标与 BitTorrent 出站流量
- AnyTLS 由 sing-box 提供实际入站，支持多用户、多端口、到期/禁用过滤与证书配置
- Xray 用户变更由数据库驱动完整重建；NAT 清理只处理数据库精确归属且已启用的端口跳跃规则
- 单端口卸载保留仍被其它端口使用的共享证书；进入主菜单不会隐式同步 Tunnel
- 通用二进制下载路径会拒绝含未替换变量占位符的 URL

详细的支持范围、安装/升级差异、菜单、用户管理、证书、卸载和排障说明见 [USAGE.md](USAGE.md)。

## 支持环境

- 目标环境为 Alpine、Ubuntu、Red Hat 系和 Debian-like 系统；脚本只明确识别前三类，其它系统一律按 Debian 处理。Alpine 路径使用 OpenRC，所有非 Alpine 路径均假定 systemd
- 安装和交互式管理必须以 root 权限运行；`--help` 可无需 root，以下管理示例仍统一使用 `sudo`
- 下载启动脚本前需已有 `wget`；安装不是离线操作，脚本会安装通用系统依赖，并按所选协议下载相应核心或组件
- 通用下载器识别 `x86_64`、`aarch64`、`armv7l`；个别协议组件的架构支持可能更窄
- 已有部署必须先备份 `/etc/vless-reality/`，尤其是 `db.json`、`certs/` 和私钥

## 安装

### 简易安装

```bash
wget -O vless-server.sh https://raw.githubusercontent.com/offzen/vless-aio-hardened/master/vless-server.sh
chmod +x vless-server.sh
sudo ./vless-server.sh
```

### 下载并校验完整发行包

```bash
base=https://raw.githubusercontent.com/offzen/vless-aio-hardened/master
for file in vless-server.sh README.md USAGE.md SHA256SUMS PROVENANCE.json; do
  wget -O "$file" "$base/$file"
done
sha256sum -c SHA256SUMS
chmod +x vless-server.sh
sudo ./vless-server.sh
```

`master` 是滚动分支。需要可复现留档时，应同时保存下载时的仓库 commit ID、全部五个文件和校验结果；不要把不同时刻下载的脚本与校验清单混用。

全新主机进入菜单后选择 `1 安装协议`，再按向导配置协议、端口、域名和用户。无参数运行脚本时，它会尝试把自身复制到 `/usr/local/bin/vless-server.sh`，并创建 `vless` 快捷命令；首次协议安装成功后也会再次确保快捷命令存在。

## 更新已有部署

必须在启动新脚本前先备份 `/etc/vless-reality/`；已有 CF Tunnel 时还要备份 `/etc/cloudflared/`。无参数进入主菜单仍会在显示菜单和询问更新前初始化/迁移数据库并同步系统脚本，但不会仅因进入菜单就自动同步 Tunnel、改写相关配置或重启/HUP相关服务。

从旧的编号版本首次迁移到滚动 `master` 时，必须使用下面的**手动替换**路径：旧脚本仍按 release/tag 版本号判断更新，无法自动发现不带版本号的新制品。完成这次替换后，后续菜单更新才会改用 SHA-256 比较。

可选两种路径：

1. **菜单更新**：仅适用于已经进入滚动 `master` 模式的安装。运行 `sudo vless`，选择 `12 检查脚本更新`。脚本下载远程 `master`，比较 SHA-256，并在替换前检查 shebang 与 Bash 语法。该流程不验证签名或 `PROVENANCE.json`；需要完整发行包一致性时应使用上面的手动下载和校验流程。
2. **手动替换**：重新下载并校验完整发行包，再无参数启动本地脚本；这是旧编号版本迁移到滚动 `master` 的必经路径。随后选择 `14 重建全部配置`，并检查配置、服务状态与真实连接。

替换成功后脚本会尝试重建并重载 Xray / sing-box，但完成提示不是运行态验收；必须继续检查配置、服务状态和真实连接。

安装或更新后使用：

```bash
sudo vless
sudo /usr/local/bin/vless-server.sh --help
```

## 文件

- `vless-server.sh`：安装与管理脚本
- `README.md`：项目入口和安装说明
- `USAGE.md`：完整使用手册
- `SHA256SUMS`：README、USAGE 与安装脚本的校验清单
- `PROVENANCE.json`：发行包身份、上游基线与逐文件哈希；为避免递归哈希，不包含自身哈希

## 归属

本仓为第三方补丁副本，版权与主要设计归原项目作者；请遵守适用许可与当地法律法规，仅用于合法用途。
