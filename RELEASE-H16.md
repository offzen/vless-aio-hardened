# RELEASE-H16 — 审计整改版

- 兼容握手 / Tag：`3.4.10-h16` / `v3.4.10-h16`
- 产品 SHA-256：`7645d99e0b935c31c2462ae3328d0d806c77efe7ee35909f347b9aed97decc16`
- 基线：H15（`v3.4.10-h15`，`f8606553c3410e6c66c177bb205ee81052681a228a3e704d6ed549fbc060f13a`）；审计对象 commit `6356d18e95cf178e77fc6b4d3cc197eb71c08bbc`
- 变更清单见 [CHANGELOG.md](./CHANGELOG.md)。本文件只记录升级注意事项与有意保留的行为。

## 升级

与 H15 相同：先备份 `/etc/vless-reality/` 与 `/usr/local/bin/vless-server.sh`，再用菜单 12 或手动替换脚本后执行 `sudo /usr/local/bin/vless-server.sh --apply-configs`。

升级后会发生的可见变化：

1. **配置渲染多了一道预检**：已安装 `xray` / `sing-box` 时，新配置必须通过 `xray run -test` / `sing-box check` 才会替换正式文件。预检失败 = 保留原配置、不重启、返回失败（过去会直接重启）。
2. **Xray 下载校验失败即中止**：取不到官方 SHA-256（`.dgst` 与 GitHub API 都不可用）时不再继续安装。受限网络中可显式设置 `VLESS_ALLOW_UNVERIFIED_DOWNLOAD=1`。
3. **菜单 12 / 自更新需要能访问同目录的 `SHA256SUMS`**。离线镜像或自托管分支可设置 `VLESS_UPDATE_SKIP_MANIFEST=1`。该校验拦截传输截断与 CDN 新旧混杂，**不防御仓库本身被篡改**；需要更强保证请改用 tag + 离线核对 `SHA256SUMS`。
4. **`traffic.pending`**：`$CFG/cache/traffic.pending` 是未入库的流量增量日志（`0600`）。正常情况下每次同步后为空；升级或回滚脚本时不要手工删除。
5. 完全卸载会移除本项目 cron 条目。

## 回滚

`do_update` 仍会保留 `${script}.bak`。回到 H15 不需要迁移数据：`db.json` 结构未变；`$CFG/cache/traffic.pending` 若非空，应先在 H16 下执行一次 `--sync-traffic` 把增量入库，再回滚。H15 不认识该日志，会忽略它。

## 有意保留的行为 / 未做的事（均有依据）

- **分层锁（外层 `flock` + 内层 `db.json.lock` 目录锁）**：在实测多核并发时发现纯 `mkdir` 目录锁仍存在极窄竞态窗口，因此采用双层设计：外层用内核 `flock`（自动兼容 util-linux `-w` 与 Alpine BusyBox `-n`）消除 H16 进程间竞态并由内核在崩溃时自动释放，内层继续保留 `db.json.lock` + `pid` 目录协议以与 `migrate-anytls-singbox.sh` 及存量 H15 进程保持互斥。
- **sing-box「零有效配置」仍删除 `singbox.json` 并停服**：这是 H15 的 fail-closed 设计（凭据撤销优先于可用性）并有回归测试；本版没有改变。
- **`curl https://get.acme.sh | sh` 未固定版本**：这是上游官方安装方式；固定提交会随 CA 变更而过期。需要更严格时，请预装 acme.sh 并固定到自己审核过的版本。
- 不再规划模块化重构（沿用 H15 结论）。
