# Changelog

## H20 — 全维度安全加固、深模块收敛与发布门禁闭环版（2026-11-28；公开基线 H17 直升包含 H18 + H19 + H20 全部整改）

兼容握手：`3.4.10-h20`。产品 SHA-256：`4f781c66b7d40721281db85f3f66471643c6cf690f60e8e43bb8664a60a92be6`。详见 [RELEASE-H20.md](./RELEASE-H20.md)。

> **公开升级总览（`v3.4.10-h17` → `v3.4.10-h20`）**：内部审计基线 H18（F01–F08 / R01 / R03）与 H19（D2–D5、D7–D12、SA-01–SA-07）未单独公开发行；本次公开版 `v3.4.10-h20` 一并交付 H18、H19 与 H20 全部安全与可靠性改进（含外部自签 `hy2`/`anytls` 默认严格校验证书迁移说明，详见下方与 [RELEASE-H20.md](./RELEASE-H20.md)）。

**供应链安全、零 `eval` 与外部订阅边界加固（SEC-1–SEC-4）**
- SEC-1 移除 `download_wgcf` 非可信第三方 GitHub 代理（`gh-proxy.com`/`ghps.cc`/`gh.ddlc.top`/`ghproxy.net`），统一收口至官方 GitHub Release + `_install_binary` digest/ELF/原子安装校验。
- SEC-2 抽出唯一安全拉取原语 `_http_fetch_sub_raw` 统一 `fetch_subscription` 与 `parse_subscription`（强制空白/控制字符拒绝、`jq -Rn` 编码、`curl -K -`、`--proto '=http,https'`、`--proto-redir '=http,https'`、`--max-redirs 5`、`--max-filesize 2097152` + `head -c 2097153` 流式硬截断防无 `Content-Length` 分块 OOM）；彻底删除旧 `urldecode`（`printf '%b'`），`_urldecode` 与新增 `_strict_base64_decode_noctrl` 严格保留字面 `+`、对裸/残缺 `%`、非法 Base64 及 `%00..%1F`/`%7F` 控制字符（含尾随 LF/NUL）fail-closed 返回错误，统一 `parse_proxy_link` 各协议查询参数解码、先截断 `?query` 再必检 `@` 并归一化方括号 IPv6（`ss://` 支持明文/旧格式密码含 `@` 并对畸形无 `:` userinfo 输出 stderr 告警）。
- SEC-3 全仓彻底清零 `eval`：`_install_binary` 改为白名单 `_install_binary_extract`（`xray_zip`/`singbox_tar`/`anytls_zip`/`raw_bin:*`），`_save_join_info` 改为显式参数计数 + 数组参数调用（仅索引 0 替换 `%s`，移除 `_q`、`--` 分隔符冲突与 `eval "$cmd"`）。
- SEC-4 `install_snell` / `install_snell_v5` / `install_naive` / `install_cloudflared` 补齐 `--max-time 900`、ELF 魔数校验与 GitHub API `digest` 校验（移除 `install_naive` 以 root 执行未验签产物的探针）；`_get_release_changelog` 补超时，`get_ipv4`/`get_ipv6`/`get_ip_country` 切至 HTTPS + 超时。

**生命周期收敛、升级闭环、证书/流量/Nginx 与解析修复（SA-08–SA-14、STYLE-1–STYLE-2）**
- SA-08（升级闭环）：`create_server_scripts` 改为临时文件原子替换并校验写入返回码（写失败保留原脚本不截断），`_apply_configs_cli` 自动刷新 `$CFG/watchdog.sh`（运行且未暂停时重启 `vless-watchdog`，脚本刷新或重启失败显式告警并置非零退出码；`migrate-anytls-singbox.sh` 在 `sing-box` 端口接管成功后仅对辅助刷新异常输出告警而不误回滚）与 Alpine `/etc/init.d/vless-singbox`。
- SA-09（F04/ACME 统一守卫）：`_apply_configs_cli --ensure-singbox` 补齐 `! is_paused && [[ -f "$CFG/singbox.json" && ! -e "$CFG/.singbox-stopped-empty" ]]` 门禁；新增顶层 `_acme_cert_reload_cmd` 统一 HTTP-01 / DNS-01 / 手动 DNS 三条证书签发路径（统一 `0600` 权限、拒绝路径控制字符并对单引号做 POSIX 安全转义、传播 `--install-cert` 与重载失败码、遵守 `paused` 与 `.singbox-stopped-empty`、仅重载已运行服务与平滑 reload 活跃 Nginx）。
- SA-10（AnyTLS 证书一致性）：`generate_singbox_config` 的 `anytls` 分支改用 `_anytls_secure "$sni"`（与 `hy2`/`tuic` 完全对齐），全局证书异常时安全回退独立自签证书不再拖垮 `sing-box check`。
- SA-11（流量配额防漏禁与退避）：`_traffic_collect_to_journal` 过滤 `statsquery` 空闲零值计数，`_sync_all_user_traffic_locked` 阶段 2 配额扫描或禁用失败时原子持久化 `$CFG/cache/.quota-check-pending`（`0600`，`fail_count<TAB>next_retry_epoch`，落盘失败保留 `traffic.pending` 不截断），首次失败下轮立即补扫，连续失败按 60s–3600s 指数退避（含十进制解析与 `>3600s` 时钟回拨保护）跳过空 pending 时的冗余整库 `jq` 扫描（仍返回非零）。
- SA-12（Clash YAML / IPv6 / SS / 日期边界）：`_flatten_clash_yaml_proxies` 跟踪 `item_indent` 正确解析节点内缩进块序列与 flow 数组，对多元素 `alpn` 无损保留并联动 `external_link_to_clash` 输出合法多元素 YAML 数组 `["h3", "http/1.1"]`、`external_link_to_surge` 取主 ALPN 不再误丢节点；`_valid_sub_server` 与 `_normalize_sub_server` 正式兼容并规范化方括号 IPv6 `[2001:db8::1]`；修复 `parse_ss_link` 与 `parse_proxy_link` 旧/明文格式密码含 `@`；`_date_add_days_ymd` 增加偏移上限与 `_valid_ymd` 校验防溢出。
- SA-13（Nginx 隔离与原子安装）：`create_fake_website` 改用 `$CFG/certs/server.crt`（修复硬编码 `/etc/vless-reality/certs/`）并统一经 `_nginx_install_conf` 原子安装与前置备份校验。
- SA-14（深模块收敛）：`_rebuild_and_reload_{xray,singbox}_impl` 内建 `is_paused` 守卫，`_regenerate_proxy_configs`、`uninstall_specific_protocol` 剩余协议重载与 `do_install_server` 443 主协议替换全部委托 `rebuild_and_reload_{xray,singbox}`（继承 `.reload-apply.<core>.lock` 与 `.reload-pending` ack）。
- STYLE-1/2：修复 `gen_xray_ip_routing_outbounds`/`gen_xray_ip_routing_rules`/`gen_xray_routing_rules`/`gen_singbox_routing_rules`/`show_single_protocol_info` 5 处末行条件码泄漏；`start_services` ShadowTLS 后端重启失败不再 `|| true` 吞错；分流域名切分改 `IFS=',' read -ra` 防通配符展开；`vless-server.sh` 与 `migrate-anytls-singbox.sh` flock 锁文件改为子 shell `umask 077` 创建不污染外层 `umask`；`rm -rf` 统一补充 `--`。

**发布流程、静态不变量与真变异门禁（REL-1–REL-4、SA-15）**
- REL-1/REL-4：全面对齐 `README.md`、`USAGE.md`、`RELEASE-H20.md`、`CHANGELOG.md`、`FIXES.md`、`tests/README.md` 至 `3.4.10-h20` 与最新 SHA-256，并在 `tests/test-ci-workflow-contract.sh` 固化文档-版本-哈希一致性硬门禁。
- REL-2：`check-version-bump.sh` 在 tag push 全零 `--base` 时仅匹配有效 `refs/tags/v*` 对比严格低于 `CUR_VER` 的最高语义化 tag 并统一十进制比较；`scripts/check-public-hygiene.py` 扩展扫描待发提交范围的提交头、标签附注与历史补丁；`.gitea/workflows/ci.yml` 补齐 `--base` 传递；`.github/workflows/release.yml` 全 3 作业限定公开仓执行（私有仓零配额消耗且不输出假绿通告）。
- SA-15：`scripts/check-static-invariants.py` 升级至 8 项结构不变量（支持 heredoc-aware 函数抽取、注释剥离、全词 `eval`、禁用旧 `urldecode` 与非可信代理、校验 `--proto-redir`/`--max-filesize` 与深模块收敛）；`tests/run-ci.sh` 将静态不变量改为 fail-closed 并抬升 `MIN_UNIT_TESTS=29`；重写 `tests/test-h19-audit-regression.sh` M6/M8/M9/M10 为真实函数体变异测试并新增 `tests/test-h20-hardening.sh`。

**包含的前置内部基线（H18 + H19，相对公开基线 H17 新增）**
- H18（F01–F08 / R01 / R03）：外部订阅 YAML 双引号序列化与控制字符拒绝、统一默认开启证书校验（`skip-cert-verify: false`）、`_is_real_cert` 严格 CA 链+SAN+私钥配对校验、sing-box 全禁用自动停服与自动恢复（F04）、`_nginx_install_conf` 前置备份校验、Clash YAML 解析重构与 TUIC 支持、Debian `dpkg-query` 严格依赖检查、订阅 URL `curl -K -` 脱敏与流量单遍聚合。
- H19（D2–D5、D7–D12、SA-01–SA-07）：流量聚合失败保账、单次整库配额读取、证书防误删与残余 issuer 子串清零、gRPC `serviceName` 往返、Alpine `gcompat` `_pgrep` 与 OpenRC POSIX `start_pre`/非执行 `STLS_PASSWORD`、纯 AWK 公历日期替代 `date -d`、`watchdog.sh` `paused`/F04 守卫。

## H19 — H18 审计回归闭环与全仓类级自审加固版（2026-11-27；修复 D2–D5、D7–D12、Alpine 实机缺陷及全仓自审 SA-01–SA-07）

兼容握手：`3.4.10-h19`。产品 SHA-256：`07dae560f3fd73cfdbe82a72687fd50617a20e0cd771130f8b3f6c9f4bf0b912`。详见 [RELEASE-H19.md](./RELEASE-H19.md)。

**数据完整性与控制面性能（D4、D5 / R03）**
- D4 聚合失败保留日志防丢账：`_sync_all_user_traffic_locked` 在 `awk | jq` 单遍聚合失败时输出明确告警并立即返回 `1`，跳过截断步骤完整保留 `traffic.pending` 待下轮重试，消除整批未入账流量被 `: > "$pending"` 清空的丢账窗口；保留纯整数精确文本避免大整数浮点精度损失。
- D5 真正的单遍整库配额状态读取（`O(D)`）：将配额/已用/启用/告警状态读取移出逐用户循环，在入账阶段结束后仅执行一次整库 `jq` 扫描（保持多端口数组首匹配语义），并移除 `|| true` 静默吞错——读取失败时显式告警并传播非 0 退出码。

**服务生命周期与证书安全闭环（D8、D12 / F04；D2、D3 / F03）**
- D8/D12 F04 全入口守卫闭环：`_regenerate_proxy_configs`（覆盖路由规则、WARP、菜单 14 等 15+ 入口）与 `uninstall_specific_protocol` 剩余协议重载路径统一接入 `is_paused`、`svc status` 与 `.singbox-stopped-empty` 守卫——管理员主动停服或存在 `$CFG/paused` 时仅更新配置不越权拉起 Xray/sing-box；仅在未暂停且存在自动停服标记时自动恢复 `vless-singbox`；`_rebuild_and_reload_singbox_impl` 运行态分支仅在 `svc restart` 成功后清除 `.singbox-stopped-empty`。
- D2/D3 证书防误删与残余 issuer 清理：新增 `_cert_is_non_self_signed` 专用于破坏性覆盖前防误删保护（绝不授予 TLS 信任），`_handle_standalone_cert`（`force_new=true`）与 `gen_self_cert` 改用带域名/私钥的 `_is_real_cert` 并在检测到未过期非自签证书时拒绝删毁；`create_fake_website` 改用 `_is_real_cert "$domain" "$CFG/certs/server.key"` 并在校验失败回退 HTTP 时输出明确告警；同步清理 `gen_self_cert`、`gen_hy2_server_config`、`show_single_protocol_info` 及 4 处安装向导中残余的 7 处 issuer 子串（`R3`/`ZeroSSL`/`Buypass` 等）判定。

**外部订阅协议完整度、输入校验与卫生清理（D1、D7、D9–D11 / F02、F06）**
- D9 gRPC `serviceName` 全链路往返：`_parse_clash_yaml_proxies`、`_clash_emit_proxy_link`、`parse_vless_link`、`parse_vmess_link`、`parse_trojan_link` 与 `external_link_to_clash` 完整支持 `grpc-opts.grpc-service-name` / `service-name` / `serviceName` 往返保留与 YAML 导出（覆盖 VLESS TLS、VLESS Reality、VMess、Trojan）。
- D10/D11 外部节点 `server` 校验与诊断告警：新增 `_valid_sub_server` 拒绝 `@ ? / #` 及空白等 URI 结构污染字符（兼容 IPv4/域名/IPv6 及方括号 IPv6）；`_clash_emit_proxy_link` 对缺字段/非法端口/非法主机/控制字符/不支持传输层等丢弃场景统一输出 stderr `_warn` 诊断。
- D1 行为变化显式文档化：保持 F02 默认严格校验证书安全基线，在 [RELEASE-H19.md](./RELEASE-H19.md) 明确点名外部自签 `hysteria2`/`hy2`/`anytls` 节点迁移路径（显式添加 `insecure=1`/`allowInsecure=1` 或 `skip-cert-verify: true`）。
- D7 死代码清理：移除无生产引用的 `_sanitize_sub_scalar`，同步更新 `tests/test-h15-security-hardening.sh` 验证现行 `_yaml_quote`。

**测试、静态不变量门禁与全仓类级自审（SA-01–SA-07）**
- 修复 L5 Alpine 3.23 真实 OpenRC 捕获的两处真机缺陷：`_pgrep` 在 Alpine 下补充匹配 `gcompat` 加载器命令行（`ld-linux-*.so* ... -- /usr/local/bin/<proc>`），解决 `start_services` 误报 glibc `sing-box` 未运行；`create_singbox_service` 的 OpenRC `start_pre()` 改用 POSIX `[ -x ... ]` 替换 Bash `[[`。
- SA-01 `watchdog.sh` 守卫与 `_pgrep` 对齐：`watchdog.sh` 抽离 `_watchdog_cycle`（支持 `VLESS_WATCHDOG_ONCE=1` 实测），补齐 `$CFG/paused` 与 F04 `$CFG/.singbox-stopped-empty` 守卫防止无用户停服后 60s 触发崩溃循环，并同步对齐 Alpine `gcompat` 精确 `_pgrep`。
- SA-02/SA-06 手写双核重载收敛与隧道守卫：`configure_direct_outbound`（修复原停服后漏启 `vless-singbox`）与 `setup_warp_ipv6_chain` 收敛调用 `_regenerate_proxy_configs`；`_sync_tunnel_config` 与 `add_protocol_to_tunnel` 补齐 `! is_paused && svc status vless-reality` 守卫及 `jq` 失败清理临时文件。
- SA-03 纯 AWK 公历日期可移植性：新增 `_ymd_to_days` / `_days_to_ymd` / `_date_add_days_ymd` 替代 GNU `date -d` / BSD `date -v/-j`，修复 Alpine BusyBox 下按天数设置到期静默变“永不过期”与剩余天数倒计时失效。
- SA-04/SA-05 链式订阅与 OpenRC ShadowTLS 凭据安全：`parse_subscription` 改用 `curl -K -` 隐藏订阅 URL/Token；`parse_proxy_link` 全协议补齐 `_valid_sub_port`（1–65535）与 `_valid_sub_server`、修复旧 `ss://` 冒号密码截断与 `hy2://` `allowInsecure`；`_write_openrc()` 将 `STLS_PASSWORD` 非执行 `sed` 解析前置到 `command_args` 之前，修复 Alpine ShadowTLS 密码为空并消除 `. "${env_file}"` 注入面。
- SA-07 状态函数退出码修复：修复 `db_set_user_expire_date ""`、`db_migrate_to_multiuser`、`db_del_chain_node`、`refresh_external_subs` 末行 `[[ ... ]] && ...` 在合法假分支返回 `1` 的问题。
- 新增静态结构不变量门禁 `scripts/check-static-invariants.py`（接入 L1a 本机预检与 `tests/run-ci.sh static`），新增 `tests/test-h19-audit-regression.sh`（D2–D12 + M5–M10）与 `tests/test-h19-self-audit.sh`（SA-01–SA-07 + 变异与 BusyBox 日期模拟测试）。

## H18 — 静态审计全量安全与恢复整改版（2026-11-27；基于 H17 `0d3cb73` 审计 F01–F08 与 R01/R03）

兼容握手：`3.4.10-h18`。产品 SHA-256：`08001f1e9fc911ea2792df7ee0e4341ebb6645efa0192ce26e3f6e78983aefdb`。详见 [RELEASE-H18.md](./RELEASE-H18.md)。

**安全与 TLS 信任合同（F01–F03、F08）**
- F01 外部订阅 YAML 序列化与注入防护：所有外部节点解析器与 `external_link_to_clash` / `external_link_to_surge` 统一拒绝凭据/主机/路径/SNI 等字段中的 ASCII 控制字符（含 CR/LF/TAB/`%00`），不再以删字符方式静默篡改凭据；`external_link_to_clash` 将全部字符串标量通过 `_yaml_quote`（`jq -Rn`）编码为合法 YAML 1.2 双引号标量，并校验端口范围（1–65535）与传输层枚举白名单；修复 `external_link_to_clash` 读取 VLESS Reality `.pbk`/`.sid` 为 `null`（实际字段 `.publicKey`/`.shortId`）与 `parse_vless_link` 双重转义节点名问题；`gen_clash_sub` 安全提取带转义引号的外部节点名写入 `proxy-groups`。
- F02 统一 TLS 验证策略：新增 `_local_tls_skip_verify` 统一 `show_single_protocol_info` 全部协议（`vless-vision`、`vless-ws`、`vmess-ws`、`hy2`、`trojan`、`trojan-ws`、`anytls`、`tuic`、`socks` TLS）的 Surge/Loon/Clash 输出，真实证书匹配 SNI 时关闭 `skip-cert-verify`；外部节点解析与导出严格保留自身显式 `insecure`/`allowInsecure`/`allow_insecure`/`skip-cert-verify` 标志（默认严格校验 `false`），不再无条件输出 `skip-cert-verify: true`，也不再用本机 `_anytls_secure` 推断外部节点信任。
- F03 严格密码学证书校验：重写 `_is_real_cert`，拆离 `fullchain` 的叶证书与中间链并执行 `openssl verify -purpose sslserver`（传入 `-untrusted` 中间链与 `-verify_hostname` 主机名校验）、`-checkend 0` 有效期校验以及公私钥配对校验，**彻底移除所有基于 issuer 子串（`R3`/`E1`/`Let's Encrypt` 等）的信任回退**；统一 `_anytls_secure`、HY2 入站与证书复用向导复用同一判据。
- F08 外部订阅 URL 去敏与安全拉取：`fetch_subscription` 严格校验 `http(s)://` 且通过 `curl -K -` 经 stdin 传递 URL（URL 与 bearer token 永不进入进程 argv），限制 `--proto =http,https`、`--proto-redir =http,https`、`--max-redirs 5`、`--max-filesize 2097152`；`refresh_external_subs`、`show_external_nodes`、`delete_external_node` 通过 `_redact_url` 仅展示 `scheme://host/***`，并收紧订阅/链接缓存文件为 `0600`/`0700`。

**服务恢复、配置事务与订阅语义（F04–F07）**
- F04 sing-box 全禁用自动停服后的自动恢复：当 `generate_singbox_config` 因无启用用户返回 `2` 并在运行态自动停服时，落盘 `$CFG/.singbox-stopped-empty`；后续重新启用用户且未被管理员手动暂停（无 `$CFG/paused`、未执行 `stop_services`）时，`rebuild_and_reload_singbox` 自动执行 `svc start vless-singbox` 并在启动失败时保留 `.singbox-stopped-empty` 与 `.reload-pending.singbox` 供重试；管理员主动停服场景保持停止不误启。
- F05 `_nginx_install_conf` 备份前置闸门与防删原配置：目标已存在时必须在同目录完成备份与 `cmp -s` 字节核对，备份失败在任何覆盖前立即中止返回非 0；新配置同目录暂存原子替换；回滚严格按“原文件是否存在”分枝，禁止无备份删除原文件，保留原 symlink 目标，若回滚恢复失败则保留备份文件并在 stderr 报告路径。
- F06 Clash YAML 外部订阅解析重构：提取唯一 `_clash_emit_proxy_link` 消除循环内节点与末节点两套逻辑分叉（修复末节点 VLESS-WS 丢失 `path`/`host` 与重复 `type=ws`）；区分 VLESS Reality（有 `public-key`）与普通 VLESS+TLS（不再误转为 `security=reality`）；VMess 改用 `jq -nc` 序列化；新增 `parse_tuic_link` 与 `external_link_to_clash`/`external_link_to_surge` 的 `tuic` 闭环支持；`_flatten_clash_yaml_proxies` 支持任意键顺序块映射、嵌套 `ws-opts`/`reality-opts`/`headers` 与单行/多行 flow mapping，并限制 YAML 别名数（≤50）与节点数（≤2000）。
- F07 Debian/Ubuntu `install_deps` 严格依赖校验：通过 `awk` 与 `PIPESTATUS[0]` 分离包管理器真实退出码与进度展示，`apt-get update` 失败明确告警；改用 `dpkg-query -W -f='${Status}\n'` 逐项验证 `install ok installed`（拒绝 `deinstall ok config-files` 残留配置与 `install ok unpacked` 未配置态）并校验关键运行时命令可执行性。

**计量透明化与控制面优化（R01、R03）**
- R01 `_traffic_collect_to_journal` 拆分 `statsquery -reset` 原始响应落盘与 `jq`/`awk` 解析追加，明确标注 best-effort 计量语义；若在 reset 之后解析或写日志失败，显式告警采样缺口并返回非 0；Xray 重启前 flush 失败亦记录告警。
- R03 `_sync_all_user_traffic_locked` 改为单遍 `awk | jq` 聚合 `traffic.pending` 与单次 `jq` 读取用户配额/告警状态，消除逐用户重复扫描日志与多次整库解析，同时保持逐用户失败重试与幂等去重合同不变。

**测试与验证**
- 新增 `tests/test-h18-audit-fixes.sh`（113 条断言，覆盖 F01–F08、R01/R03 及 4 组防假绿变异自检，双 AWK `mawk` + `gawk` 100% 通过）；更新 `tests/test-stateful-upgrade.sh` 接受 `3.4.10-h14+` 候选版本号。

## H17 — 第二轮外部审计及复审整改版（2026-11-26；基于内部 H16 基线）

兼容握手：`3.4.10-h17`。产品 SHA-256：`f66536a0d74e36e90f461293ca9212669e87b492628e93e9b1900ec9aefbd548`。详见 [RELEASE-H17.md](./RELEASE-H17.md)。

**凭据 / 用户完整性**
- 旧单用户配置（顶层 uuid/password，无 `users` 数组）在添加首个用户时，先在同一次原子写里把原凭据落成 `default` 用户，再追加新用户；此前新用户的写入会让刚发出的原链接失效。SOCKS 保留原 `username` 作为账号名。启动迁移、禁用 `default` 共用同一段迁移定义。
- TUIC：迁移保存独立 password；渲染与按用户导出对「uuid 与顶层一致但缺 password」的用户回退顶层 password，修复已被旧版迁移写坏的 DB。

**服务切换 / 失败传播**
- `migrate-anytls-singbox.sh`：生产 DB 改库前先校验 `sing-box` 与系统脚本均就绪（缺一即拒绝半迁移并保持 DB 与旧服务不变）；切换时先释放端口再调用 `--apply-configs --ensure-singbox`（自动建/启 `vless-singbox` 单元，覆盖纯旧 AnyTLS 主机），以「`vless-singbox` 运行 + 迁移端口在监听」为接管判据；失败时先停掉半启动的 `vless-singbox`（纯旧主机同时清理新 `singbox.json`）、通过分层锁原子恢复 DB 并重新拉起旧服务；若主机已处半迁移状态（DB 已迁到 `singbox.anytls` 而旧 `vless-anytls` 仍在运行），重跑自动续接接管而非误报“无需迁移”；备用 `--db` 只改该文件，不触碰生产服务；修复 `pipefail` + `grep -q` 的 SIGPIPE 误判。
- 按端口卸载（Xray / sing-box）：不再先 `svc stop` + 删配置；先预检新配置，失败保留原配置与运行进程，成功只重启一次；卸载结果如实提示。
- 菜单 14（`_regenerate_proxy_configs`）：任一核心预检失败则不重启该核心并返回非 0，菜单据此报错而非“成功”。
- 到期 / 配额撤销：DB 已禁用但重建或重载失败时落 `.reload-pending.<core>` 标记；`--check-expire`、`--sync-traffic` 下一轮重试，且二者在重载仍未成功时均返回退出码 1。

**输入处理 / 共享主机**
- `_save_join_info`：链接命令里的用户值统一经 `_q`（`printf %q`）转义，占位符只替换第一处；自定义口令中的 `$()`、反引号、空格、`%s` 不再被二次 Shell 解释。
- 完全卸载只清理本项目配置的 WARP，不再因存在 `warp-cli` 就移除其它应用使用的 WARP。

**写库 / 订阅 / 更新链路（审计第 10–16 项）**
- 协议注册写库失败（锁超时 / jq 失败）现在向上传递：`db_add` → `register_protocol` → `do_install_server` 中止安装，`_save_join_info` 不再为未注册的协议生成链接，也不再由「现有 DB 里的旧服务」误判安装成功。
- 订阅（通用 / Clash / Surge）改用 `_cfg_effective`：只导出第一个生效用户的凭据（`enabled != false` 且 `expire_date` 未过期，与服务端渲染器一致），不再分发已禁用 / 已过期用户的顶层凭据；修复 `(.enabled // true)` 把 `false` 当缺省、以及误读 `.expire`（实际字段为 `expire_date`）。
- 流量入账幂等：日志条目带唯一标识，`used` 与「已入账标识」在同一次加锁原子写里提交；入账后、清日志前被中断，重放不会重复扣量。
- 自更新：先在同目录生成并逐字节核对备份，再原子更新 `.bak`；备份失败即中止，当前脚本与上一份 `.bak` 均不变。
- `--apply-configs`（生产入口）先校验 DB：损坏 / 结构异常返回非 0 且不改动配置；有效空库仍为成功空操作。
- 订阅重新配置事务化：新 UUID 与新站点配置先在暂存区生成并 `nginx -t` + 重载，全部成功后才切换 UUID、写 `sub.info`、删旧目录；取消 / 预检失败 / 重载失败都恢复原配置（并清理本轮新建的 Web placeholder），旧链接保持可用。
- TUIC：入站与链接 / 订阅导出共用 `_anytls_secure` 判据；SNI 命中可信证书域名时入站使用该证书，否则使用独立自签证书（链接保留 `allow_insecure`），不再出现链接严格校验、入站却出示自签证书。

**复审边界整改（针对 `034c2853` 复审报告 R01–R13 与 T01）**
- R01 / R02 AnyTLS 迁移器：改库与停旧服务前落盘 `$CFG/.migrate-anytls.state.json` 持久化状态，停旧后进程异常中断重跑可完成接管或恢复旧服务（不误报“无需迁移”，也不误启已迁完且被管理员停用的服务）；回滚改为锁内字段级逆转，仅撤销 `xray.anytls` / `singbox.anytls`，保留迁移期间其他协议的并发 DB 修改，同字段冲突时保留现场并明确报错。
- R03 / R06 到期与配额撤销：`_db_set_user_enabled_nowrite` 在写 DB 前即持久化代次令牌 `.reload-pending.<core>`、写库后再推进一代，重建成功仅在代次匹配快照时清除标记，防止写库后中断漏撤销与并发批次互相误清；`generate_singbox_config` 用返回码 `2` 区分「所有协议均无启用用户并已清配置」与真实失败，成功停服后清除标记并返回 0，停服失败则保留标记并返回 1。
- R04 共享 WARP 归属：`install_warp_official` 记录 `.routing.warp_official_owned`（复用预装标 `false`、本项目安装标 `true`、历史库为 `unknown`）；完整卸载、`uninstall_warp_official` 与模式切换仅在 `true` 时操作 `warp-svc` / 卸包。
- R05 / R13 流量入账与退出码：`db_update_user_traffic` 完整保留当前未清批次全部 ID（任意 >200 条积压重放均不重复扣量，已退休历史收敛在 200 条）；`sync_all_user_traffic` 传播单用户写库失败与运行中采集失败的退出码（Xray 未运行时主动跳过返回 0）；`--setup-expire-cron` 传播失败退出码并同步更新 `USAGE.md`。
- R07 / R08 / R11 写库与发布事务化：按端口卸载先检查 `db_remove_port` / `unregister_protocol` 返回码并在 DB 删除成功后才清 NAT / 删配置 / 重载；Snell / Snell v5 / NaïveProxy / ShadowTLS 组合协议先写私有临时文件、待 `register_protocol` 成功后才原子发布；订阅重配置无论是否轮换 UUID 均先在独立暂存目录生成三份文件并检查返回值，待 `nginx -t` + 重载成功后才发布。
- R09 / R10 / R12 一致性与类型校验：HY2 入站与 `_cfg_effective` 三端订阅统一按「非空 `.uuid` 优先、`.password` 兜底」选密；`db_validate` 改为显式检查 `has(...)` 与 `type == "object"`，拒绝 `{"xray":false}` / `null`；`_anytls_secure` 与 sing-box 入站统一要求 `server.crt` 与 `server.key` 同时存在。
- 并发安全与边角补强（N0–N9 & D1–D4）：同核心 `rebuild_and_reload_*` 与 `generate_*_config` 全程持有 `.reload-apply.<core>.lock`（严守全局锁序 `.reload-apply → traffic → db → .reload-pending` 且 `_lock_flock_release` 显式 `flock -u`、`BASHPID` 归属隔离，注释明示同进程释放约束并清理死代码 `_reload_pending_mark`），`_db_set_user_enabled_nowrite` 在 `db.lock` 围栏内完成 `pre-arm → 写库 → post-arm`、重建前经同锁围栏取快照，彻底闭合并发旧批次覆盖新配置与 `pre-arm` 被误清的竞态；`_DB_MIG_JQ` 与 `db_get_users_stats` 按协议区分凭据优先级（`anytls`/`hy2`/`trojan`/`ss-legacy`/`socks` 优先顶层 `password`，`anytls` 同步落盘 `password` 字段），杜绝顶层 `{uuid,password}` 共存场景迁移时静默改写生效密码；`migrate-anytls-singbox.sh` 在冲突/回滚失败时同样先释放半启 `vless-singbox` 并拉起 `vless-anytls` 避免端口中断、旧服务重启失败时保留状态文件并在重跑继承 `legacy_was_active=1` 避免双服务 down 循环、续接优先使用 DB 当前端口、`--dry-run` 缺前置条件仅告警、`port_listening` 先落变量再匹配彻底消除 `pipefail` SIGPIPE、`--help` 不再泄漏 `set -euo pipefail`；`uninstall_warp_official` 改用 `dpkg-query -W -f='${db:Status-Status}'`（避免 `config-files`/`rc` 态误阻断）并复核 `warp-cli` 已消失后才写 `warp_official_owned=false` 与报成功，`do_uninstall` 直接复用 `uninstall_warp_official` 消除双份判定。

**测试与 CI/发布治理**
- 重构 GitHub Actions 与私有 Forgejo CI 分层：`.github/workflows/ci.yml` 改为标准 YAML 与双并行 fail-closed 作业（`Static, Manifest, Dual-AWK Unit & Upgrade`、`Pinned Cores, Webroot & Isolated Installer E2E`），支持 `workflow_call`、`concurrency` 与 `timeout-minutes`；新增 `.github/workflows/release.yml`（`v*` tag 触发 `preflight → workflow_call ci.yml → Sigstore 构建证明与 Release 资产自动发布`，私有仓自动跳过发布）、`.gitea/workflows/ci.yml` 与 `scripts/check-public-hygiene.py`；退役冗余的 `PROVENANCE.json` 与 `ci.yml` 硬编码 SHA，保留运行时所需的 `SHA256SUMS` 与 `scripts/refresh-manifest.sh`。
- 生产入口与双核心更新链路（T01）：`tests/test-installer-e2e.sh` 扩展第 10 组，补充 `{"xray":false}` 布尔核心拒绝与「双核心（Xray + sing-box）经菜单 12 替换脚本并起全新进程 `--apply-configs`」的成功及单核心重载失败传递断言；`tests/test-singbox-native-e2e.sh` 补齐 HY2 双字段入站/导出一致性断言。
- 新增 `tests/test-h16-external-audit.sh`（A1–A14，147 条断言，含 `anytls`/`hy2`/`trojan`/`ss-legacy`/`socks` 顶层双字段共存迁移保密断言）、`tests/test-h17-reaudit-fixes.sh`（R01–R13 + T01 + N0–N9 + D1–D4，184 条断言）与 `tests/test-ci-workflow-contract.sh`（CI/Release DAG 与脱敏扫描契约断言）；`tests/test-installer-e2e.sh` 在添加首个用户后增加「原安装用户配置仍在 + 真实 Xray 数据面仍通」断言。

## H16 — 审计整改版（2026-11-26；基于外部独立审计 `6356d18` 的 13 项发现）

兼容握手：`3.4.10-h16`。产品 SHA-256：`7645d99e0b935c31c2462ae3328d0d806c77efe7ee35909f347b9aed97decc16`。详见 [RELEASE-H16.md](./RELEASE-H16.md)。

**正确性 / 数据完整性**
- F1 配额只触发一次：`quota_exceeded_notified` / `last_alert_percent` 现在会在「重置流量 / 改配额 / 重新启用」时清除，且超额禁用不再依赖一次性标记（仍启用且 `used>=quota` 就禁用）；改到期日同时清除临期提醒标记。
- F2 配置原子渲染：Xray 配置先渲染到同目录临时文件，JSON 校验与 `xray run -test` 通过后才原子替换；sing-box 同理（`sing-box check`）。「所有入站渲染失败」不再被误判为「全部用户禁用」，失败时保留原配置且不重启服务。
- F3 流量计数不再丢失：读出即落盘（`traffic.pending` 日志），写库失败的增量下一轮重试；重启 Xray 前先把内存计数落盘；cron / 菜单 / 重启前 flush 用同一把锁串行。
- F4 DB 写入全面加锁：`_db_apply` / `_db_touch` 与 `_db_safe_write` 共用分层互斥锁（外层内核 `flock` 兼容 util-linux 与 Alpine BusyBox，内层保留 `db.json.lock` 目录锁与旧进程 / `migrate-anytls-singbox.sh` 互通，支持同进程可重入）；原先裸写 `db.json` 的分流 / 链式代理 / 负载均衡 / Telegram 等 27 处写入全部改走加锁原语；无 pid 文件的陈旧锁按 mtime 回收，回收改为原子改名并核对 inode。
- F8 到期日期必须是真实日历日期；旧版本遗留的非法日期（如 `2026-02-30`）在 `--check-expire` 与配置渲染间保持一致。
- F9 批量到期禁用：数据库内批量禁用，每个核心只重建 / 重启一次；只统计并通知写入成功的用户；`svc` 错误详情走 stderr，不再污染计数。
- F11 增删用户：数据库已提交但重载失败时返回 3（非 0）并明确提示「已写入、未生效」，避免误以为失败而重复添加。

**可靠性 / 防御性安全**
- F5 下载完整性：Xray `.dgst` 取不到或解析不出时回退 GitHub API `digest`，二者皆无则**中止**（原为放行）；sing-box 等 GitHub 资产在 API 提供 `digest` 时必须匹配；可用 `VLESS_ALLOW_UNVERIFIED_DOWNLOAD=1` 显式放行、`VLESS_REQUIRE_VERIFIED_DOWNLOAD=1` 对所有资产强制校验。
- F6 自更新与发布的 `SHA256SUMS` 交叉核对（不一致或取不到清单即中止；`VLESS_UPDATE_SKIP_MANIFEST=1` 可跳过）。该检查拦截传输截断与 CDN 新旧混杂，**不能**防御仓库本身被篡改。
- F7 脚本下载使用 `curl -f`，只有「像脚本」（shebang + 合法版本号）的远端才会写入哈希 / 版本缓存，错误页不再触发假更新提示。
- F10 cron：统一指向系统脚本的绝对路径；已存在但路径 / 间隔不同的旧条目会被替换；读取 crontab 失败时绝不覆盖；按完整参数词匹配（不再是任意子串）；完全卸载现在会移除本项目的两个 cron 条目。
- F12 nginx：XHTTP 反代先渲染到临时文件、`nginx -t` 失败回滚；伪装站点配置失败时恢复原有文件；代入配置的域名 / 路径 / 端口先做字符集校验。
- F13 下载总超时与低速中止（二进制 15 分钟、脚本 60 秒）。

**工程**
- 新增 `tests/test-h16-audit-fixes.sh`（112 条断言；对 H15 产品其中 52 条失败，作为变异证据）；更新 updater / version-check 测试以覆盖清单交叉核对与错误页场景。
- 未改动（有意）：`curl | sh` 安装 acme.sh（上游官方方式，固定提交会随 CA 变更过期，见 RELEASE-H16 说明）；sing-box「零有效配置」仍删除 `singbox.json` 并停服（fail-closed 设计）。

## H15 — 正式版（2026-11-25；安全与可靠性深度加固，原 H15-rc.1 2026-11-21）

- 正式版相对 rc.1：产品字节不变；修复 installer E2E 夹具（TEST-NET 靶机 + 回环仍阻断的负向断言）、stateful 测试改用已知 H14 基线、工作流 `fetch-depth: 0` 并覆盖全部门禁、新增 `ci/**` 与 PR 触发、`check-version-bump.sh` 补可执行位、新增 `scripts/refresh-manifest.sh`、清理文档中的 H14 残留。
- 不再规划模块化重构（H16 为审计整改版，不含重构）。


- 兼容握手：`3.4.10-h15`（预发布标签：`v3.4.10-h15-rc.1`）。
- 最终产品 SHA-256：`f8606553c3410e6c66c177bb205ee81052681a228a3e704d6ed549fbc060f13a`。
- 审计基线：H14-rc.1（`6ea18a9e5af7ca2802ee6982d478d042ffcbcd4108b3a978c26e50aaf77eaa34`）。
- 审计报告与整改架构见 [docs/AUDIT-H14-RC1.md](./docs/AUDIT-H14-RC1.md)、[docs/REMEDIATION-AND-ARCHITECTURE.md](./docs/REMEDIATION-AND-ARCHITECTURE.md) 与 [RELEASE-H15.md](./RELEASE-H15.md)。

### 安全与可靠性修复（Stage 1 P0 + Stage 2 P1 + 关键 P2）

1. **消除全部命令注入入口（C-1）**：移除 `_display_sorted_latencies`、`xray_api_query`、`_issue_cert_dns` 中的 `eval`，用纯键值解析 `_load_sub_info`/`_write_sub_info`（`0600`）替代全部 `source "$CFG/sub.info"`，`/dev/tcp` 探测改用位置参数传值。
2. **修复路由顺序与私网/BT SSRF 绕过（C-2）**：移除 WARP 规则中的私网 `direct` 放行；sing-box 强制 `sniff → 私网/CGNAT/回环 block → BT block → auth_user → global`；Xray 补齐 `0.0.0.0/8`、`100.64.0.0/10`、`::/128`、`::1/128` 并将多 IP 绑定路由移至 `block` 之后。
3. **凭据撤销与显式空 `users: []` fail-closed（H-1 / H-2）**：sing-box 零有效用户时删除残留 `singbox.json` 并停止运行中的 `vless-singbox`；Xray 全部多用户协议将显式空 `users: []` 视为零有效用户，不再回退顶层凭据。
4. **凭据文件权限与 `/tmp` 加固（H-3 / H-4 / L-4）**：移除卸载复制私钥到 `/tmp/vless-certs-backup`；所有状态/凭据文件落盘 `0600` 与原子替换；缓存目录迁至 `$CFG/cache`（`0700`）；ShadowTLS 密码迁至 `0600` `EnvironmentFile=` 并为基础 systemd unit 启用 `NoNewPrivileges`/`PrivateTmp`/`ProtectKernel*`；Telegram 改用 `curl -K -` 隐藏 Bot Token 并消除双配置裂脑（M-4）；拒绝 `..` 版本号路径穿越。
5. **更新器新进程应用与下载校验（H-5 / H-6）**：新增 `--apply-configs`，`do_update` 生产态新进程执行配置重建；`main_menu` 更新后立即退出避免继续运行旧代码；`_auto_update_system_script` 增加防降级与原子替换；`_install_binary` 自动校验 Xray `.dgst` 并修复安装退出码掩盖。
6. **重写 `migrate-anytls-singbox.sh` 与只读渲染（H-7 / H-8）**：修复参数解析死循环、多端口无损合并与冲突 fail-closed、去除裸 `pkill`；Xray 多端口渲染不再临时改写 `db.json`。
7. **TLS 证书防伪造与订阅防注入（H-9 / H-10）**：`_is_real_cert` 使用 `openssl verify` 并拒绝 `issuer == subject` 自签伪造；真证书场景下所有 TLS 链接与 Clash/Surge 订阅关闭 `allowInsecure`/`skip-cert-verify`；外部节点转换清洗换行/引号/逗号注入，订阅生成过滤零有效用户实例。
8. **运维可靠性与清理（M-1 ~ M-8、L-1 ~ L-3、I-1 ~ I-2）**：DB 锁死进程回收、`vmess-ws` UUID 生成、移除明文百度 HTTP 校时、纯 IPv6 分享链接、Tunnel 改用 `svc restart vless-reality`、修复未定义函数/变量与硬编码第三方测试凭据、修复 CI 语法门禁静默跳过及多端口禁用测试拼写错误。

### 新增回归测试

- `tests/test-h15-security-hardening.sh`：覆盖 C-1、C-2、H-1~H-4、H-8~H-10、M-3/M-5/M-6/M-7、L-1 的 35+ 条自动化断言。
- `tests/test-migrate-anytls.sh`：覆盖 `migrate-anytls-singbox.sh` 参数解析、dry-run、单端口/多端口合并、冲突 fail-closed 及无裸 `pkill` 断言。
- `tests/test-stateful-upgrade.sh`：支持在无私有 H13 历史的洁净仓库中自动对真实 H14 基线制品执行 H14 → H15 有状态升级回归。

## H14 — 当前验收修订（2026-11-19）

- 兼容握手：`3.4.10-h14`。
- 最终产品 SHA-256：`6ea18a9e5af7ca2802ee6982d478d042ffcbcd4108b3a978c26e50aaf77eaa34`。
- 已验收代码 commit/tree：`90dea0335f646c5d6e69cc7d3ad41919ef2da16f` / `0019ae4fab386547a7fecf6a1a830a4d1080f881`。
- 本次更新文档和本地发行包，不改变已验收产品；新文档不冒充包含在旧 CI commit 内。未改 canonical refs、tag，未执行公开 Release。

### 产品修复

1. **传统 Shadowsocks 多用户**：显式 DB `users` 写入 Xray `settings.clients`，避免未知字段 `settings.users` 被静默忽略、仍只接受顶层密码的问题。
2. **fail closed 与旧库兼容区分**：显式空表、所有用户禁用或过期时不生成该 SS inbound，不回退顶层密码。只有完全不存在 `users` 字段的旧库维持单密码模式。
3. **用户分享链接**：新增 `ss-legacy` URI 分派，按用户所在端口实例读取加密方法；一键展示不包含禁用/过期用户。
4. **partial identifier 负向一致性**：`vless-xhttp-cdn`、`vless-ws-notls`、`trojan-ws`、`ss2022` 拒绝逐用户管理，selector 隐藏、写库前拒绝；不删除既有单用户安装/运行能力。
5. **测试接缝**：source-only 下显式绝对测试目录可重定向 CFG；普通运行保持 `/etc/vless-reality`。接缝不使进入普通菜单变成只读操作。

### 测试与 CI 补强

- 源码 registry ↔ 能力 manifest 双向对账，未知/遗留 identifier 未分类即失败；5 类 mutation 自证。
- 当前 11 个 supported row 参数化动态合同：DB → 菜单/URI → renderer，110 条断言，涵盖 default、second、disabled、expired、零有效用户和多端口隔离；产品拒绝策略 37 条断言。
- 固定 Xray 26.3.27：auth schema/data-plane 2/2、传统 SS 两启用凭据正向及禁用负向 3/3。
- 固定 sing-box 1.14.4：HY2/TUIC/AnyTLS 原生解析，AnyTLS second-active 正向、disabled 负向，native/data-plane gate 3/3。
- 真实 H13 制品 updater success/partial-failure，安装 H14 后 fresh process 真重渲染，13 条断言；不把 instrumented helper 当作真实配置收据。
- mawk、gawk 各完整 21 脚本及 mutation/identity；Web root required 生命周期与 Docker installer 9/9 无 SKIP。
- DinD 仅在自有 private cgroup namespace 执行固定官方初始化，不改共享 runner/宿主 cgroup。旧 run287 的 failure 保留，新授权事务 run288 成功。
- private CI run288：六 required job success；34 文件 syntax / ShellCheck 0.9.0 error gate；15 required verified。非 required Release job skipped，零发布动作。

### deployment host 实际部署

- 现场未发现旧版，因此本次为新装，非旧版原位升级实证。
- 部署原样 H14、固定 Xray 26.3.27，传统 SS `aes-256-gcm` 使用现有防火墙已放行且原先空闲的 TCP 443；真实 `vless-reality.service` active/enabled，NRestarts=0。
- 原生 parser 与两组启用凭据代理至外部 HTTPS HTTP 204 通过；disabled 连接失败，client/server 仍存活；DB 与共享状态、防火墙不漂移。
- 凭据和 URI 仅保存在 deployment host root-only 文件，不包含在发行包。公网入站与外部客户端连接的最终范围见 [RELEASE-H14.md](./RELEASE-H14.md)。

### 保持不变的合同与限制

- updater 部分失败会尝试全部三个 helper、返回非零、保留新脚本与 `.bak`，**不自动回滚**。菜单 14 的完成提示/返回状态不可靠，不能套用 updater 的退出码合同。
- `ss-legacy`、SOCKS5、官方 sing-box 协议没有本项目的有效逐用户自动流量计量/配额封禁；到期与禁用需重新生成并应用配置才影响运行态。
- Web CI 为函数/HTTP/service spy，不等同于宿主真实 Nginx/systemd。Docker 固定 leaf pin 不证明公网 CA、强安全沙箱、自动回滚或已删 alice 的直接负向重连。
- 进入主菜单会初始化/迁移 DB 并同步脚本；必须事先备份。菜单 12 历史固定下载源未在本次 promote，不把其在线字节称为此 SHA。
- 卸载并不完全恢复共享 WARP、cron、DNS64、sysctl、证书或核心二进制，详见 [USAGE.md](./USAGE.md)。

## H13 — 历史基线

产品 SHA-256：`33c953bde77f587cb6601751ea404f92b134be0cc663c2e765685393225dfa88`。

- 来源寻址制品与 updater 部分失败收敛；旧库与 `.bak` 保留、全部 helper 尝试、非零诊断。
- 该历史制品是 H14 real-artifact 升级测试输入；H13 门禁不能代替当前 H14 收据。
- 更早加固与历史记录保留在 [FIXES.md](./FIXES.md)。早期 H14 SHA `e7c52036949398f10391ac3ae3724558995e42cd7be3b4654de21e6c9d44f137` 是历史草案，不是当前交付身份。
