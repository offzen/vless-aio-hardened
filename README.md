# vless-aio-hardened

[`vless-all-in-one`](https://gitlab.com/chil30-group/vless-all-in-one)（Chil30，基线 3.4.10）的第三方加固版服务端脚本。

## 功能概览

- 单文件安装与管理脚本：`vless-server.sh`（当前版本 `3.4.10-h20`）
- 支持 Xray、sing-box 与独立服务协议；多协议可共存，Xray / sing-box 托管协议支持多端口与逐用户管理
- 凭据与状态文件统一最小权限（`0600`）与原子写入：唯一临时文件、分层 `flock` + 目录锁、异常清空护栏，全仓零 `eval`、敏感凭据与订阅 URL 经 `curl -K -` 隐藏不进入进程命令行或 `/tmp`
- Xray / sing-box 默认优先拦截私网目标（含 IPv4/IPv6 回环与 CGNAT）与 BitTorrent 出站流量
- 显式空用户列表严格拒绝回退（fail-closed）；sing-box 无有效入站时自动清理配置并停服，恢复启用用户后自动拉起，全入口与 `watchdog.sh`/ACME 续期统一遵守 `paused` 守卫
- AnyTLS 由 sing-box 提供实际入站，支持多用户、多端口、到期/禁用过滤与证书配置（旧独立 AnyTLS 可使用 `migrate-anytls-singbox.sh` 无损迁移）
- 真实证书校验统一使用系统 CA 链、SAN 主机名、有效期与公私钥配对验证并拒绝自签伪造；外部订阅默认开启严格证书校验，并对 YAML/URI 字段执行控制字符拒绝与注入清洗
- 内置更新器支持新进程配置重载与 `watchdog.sh`/Alpine init 刷新（`--apply-configs`）、防降级检查及官方源 SHA-256/ELF 校验；通用下载器拒绝含未替换占位符的 URL 与非可信第三方代理

详细的支持范围、安装/升级步骤、菜单说明、用户管理、证书与排障见 [USAGE.md](USAGE.md)；H20 完整变更与从 H17 升级必读见 [RELEASE-H20.md](RELEASE-H20.md)、[RELEASE-H19.md](RELEASE-H19.md)、[RELEASE-H18.md](RELEASE-H18.md) 与 [CHANGELOG.md](CHANGELOG.md)。

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
- `RELEASE-H15.md` .. `RELEASE-H20.md`：各版本发布与升级手册
- `CHANGELOG.md` / `FIXES.md`：版本更新清单与修复摘要
- `SHA256SUMS`：文件哈希清单（供在线更新与离线包校验）

## 发行身份与验证

H20 全维度加固版交付身份：

- 发布版本 / Tag：`v3.4.10-h20`（脚本 `readonly VERSION="3.4.10-h20"`）
- `vless-server.sh` SHA-256：`4f781c66b7d40721281db85f3f66471643c6cf690f60e8e43bb8664a60a92be6`
- 上一公开正式版 H17：`v3.4.10-h17`（`f66536a0d74e36e90f461293ca9212669e87b492628e93e9b1900ec9aefbd548`）；H18（`3.4.10-h18`）与 H19（`3.4.10-h19`）为内部审计与自审基线未单独公开发行，从 `v3.4.10-h17` 直升 `v3.4.10-h20` 将一并包含 H18、H19 与 H20 全部整改

本仓通过自动化 CI 覆盖 Bash 语法、ShellCheck 静态检查、8 项静态结构不变量门禁、版本抬升闸门、`mawk`/`gawk` 双引擎单元测试与真变异验证、状态升级回归、Xray/sing-box 原生配置与数据面 E2E 以及隔离安装器测试。

## 归属

本仓为第三方加固维护副本，版权与主要设计归上游作者；请遵守适用许可与当地法律法规，仅用于合法用途。
