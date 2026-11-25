# vless-aio-hardened

[`vless-all-in-one`](https://gitlab.com/chil30-group/vless-all-in-one)（Chil30，基线 3.4.10）的第三方加固版服务端脚本。

## 功能概览

- 单文件安装与管理脚本：`vless-server.sh`（当前版本 `3.4.10-h15`）
- 支持 Xray、sing-box 与独立服务协议；多协议可共存，Xray / sing-box 托管协议支持多端口与逐用户管理
- 凭据与状态文件统一最小权限（`0600`）与原子写入：唯一临时文件、带过期回收的目录锁、异常清空护栏，敏感凭据不暴露在进程命令行或 `/tmp`
- Xray / sing-box 默认优先拦截私网目标（含 IPv4/IPv6 回环与 CGNAT）与 BitTorrent 出站流量
- 显式空用户列表严格拒绝回退（fail-closed）；sing-box 无有效入站时自动清理配置并停服
- AnyTLS 由 sing-box 提供实际入站，支持多用户、多端口、到期/禁用过滤与证书配置（旧独立 AnyTLS 可使用 `migrate-anytls-singbox.sh` 无损迁移）
- 真实证书校验使用系统 CA 链验证并拒绝自签伪造；真证书场景默认关闭订阅中的 `allowInsecure` / `skip-cert-verify`，并对外部订阅字段做注入清洗
- 内置更新器支持新进程配置重载（`--apply-configs`）、防降级检查及 Xray 下载摘要校验；通用二进制下载拒绝含未替换占位符的 URL

详细的支持范围、安装/升级步骤、菜单说明、用户管理、证书与排障见 [USAGE.md](USAGE.md)；H15 完整变更与升级细节见 [RELEASE-H15.md](RELEASE-H15.md) 与 [CHANGELOG.md](CHANGELOG.md)。

## 支持环境

- 目标环境为 Alpine、Ubuntu、Red Hat 系和 Debian-like 系统；脚本明确识别前三类，其余系统按 Debian-like 处理。Alpine 使用 OpenRC，非 Alpine 假定 systemd
- 安装和交互式管理必须以 root 权限运行；`--help` 无需 root，以下管理示例统一使用 `sudo`
- 下载启动脚本前需已有 `wget` 或 `curl`；安装不是离线操作，脚本会安装通用系统依赖，并按所选协议下载相应核心或组件
- 通用下载器识别 `x86_64`、`aarch64`、`armv7l`；个别协议组件的架构支持可能更窄
- 已有部署更新前务必先以 root-only 权限备份 `/etc/vless-reality/`（含 `db.json`、`certs/` 与私钥）及 `/usr/local/bin/vless-server.sh`

## 安装

### 简易安装

```bash
wget -O vless-server.sh https://raw.githubusercontent.com/offzen/vless-aio-hardened/master/vless-server.sh
chmod +x vless-server.sh
sudo ./vless-server.sh
```

### 下载并校验完整性

```bash
base=https://raw.githubusercontent.com/offzen/vless-aio-hardened/master
wget -O vless-server.sh "$base/vless-server.sh"
wget -O SHA256SUMS "$base/SHA256SUMS"
grep '  vless-server.sh$' SHA256SUMS | sha256sum -c -
chmod +x vless-server.sh
sudo ./vless-server.sh
```

如需校验完整仓库文件，可 `git clone` 本仓或下载对应 Release 源码包后在仓库根目录执行 `sha256sum -c SHA256SUMS`。

全新主机进入菜单后选择 `1 安装协议`，按向导配置协议、端口、域名和用户。无参数运行脚本时，会自动同步自身到 `/usr/local/bin/vless-server.sh` 并创建 `vless` 快捷命令。

## 更新已有部署

**启动新脚本前务必先备份** `/etc/vless-reality/` 与 `/usr/local/bin/vless-server.sh`（如有 Cloudflare Tunnel 一并备份 `/etc/cloudflared/`）。

可选两种路径：

1. **菜单更新**：运行 `sudo vless`，选择 `12 检查脚本更新`。脚本拉取远端版本并校验语法后替换自身，随后通过新进程执行 `--apply-configs` 重建并重载核心配置。
2. **手动替换**：下载并校验新版 `vless-server.sh`，原子替换 `/usr/local/bin/vless-server.sh` 后执行：
   ```bash
   sudo /usr/local/bin/vless-server.sh --apply-configs
   ```
   或进入菜单选择 `14 重建全部配置`。

更新完成后建议手动检查核心配置与服务状态（`xray run -test`、`sing-box check`、`systemctl is-active` 及实际客户端连接）。

安装或更新后常用命令：

```bash
sudo vless
sudo /usr/local/bin/vless-server.sh --help
```

## 文件

- `vless-server.sh`：安装与管理主脚本
- `migrate-anytls-singbox.sh`：独立 AnyTLS 到 sing-box 托管模式的迁移脚本
- `README.md`：项目入口与安装说明
- `USAGE.md`：完整使用手册
- `RELEASE-H15.md`：H15 正式版发布与升级手册
- `CHANGELOG.md` / `FIXES.md`：版本更新清单与修复摘要
- `SHA256SUMS` / `PROVENANCE.json`：文件哈希清单与版本来源记录

## 发行身份与验证

H15 正式版交付身份：

- 发布版本 / Tag：`v3.4.10-h15`（脚本 `readonly VERSION="3.4.10-h15"`）
- `vless-server.sh` SHA-256：`f8606553c3410e6c66c177bb205ee81052681a228a3e704d6ed549fbc060f13a`

本仓通过自动化 CI 覆盖 Bash 语法、ShellCheck 静态检查、版本抬升闸门、`mawk`/`gawk` 双引擎单元测试、状态升级回归、Xray/sing-box 原生配置与数据面 E2E 以及隔离安装器测试。

## 归属

本仓为第三方加固维护副本，版权与主要设计归上游作者；请遵守适用许可与当地法律法规，仅用于合法用途。
