# nginx 漏洞升级 pitfalls（现象 → 原因 → 处理）

以下全部来自 2026-11-19 两个云的真实批量升级。

### P1. 新镜像里 `ls`、`[ -x ]` 报 Operation not permitted，nginx 本身正常

- 现象：trixie/debian12 底的 nginx 镜像在 CentOS 7 + Docker 19.03 主机上，容器内 `ls`、`[ -x /path ]` 报 `Operation not permitted`；nginx 的启动、worker、时区、TLS 全部正常；入口日志可能出现 `Ignoring … not executable`。
- 原因：Docker 19.03 内置的旧 seccomp allowlist 不认识新 glibc 使用的 `statx`、`faccessat2`、`clone3` 系统调用，coreutils/bash 退回旧调用失败前被 seccomp 拦截。是系统调用层面的问题，不是文件权限问题。
- 处理：不要去 chmod/chown。先起试运行容器验证 nginx 本身与业务路径；被跳过的入口脚本步骤（IPv6 监听、模板渲染、worker 自动调优等）确认不为本机配置所依赖即可。根治需升级宿主 Docker。
- 预防：老 Docker + 新基础镜像的组合，一律"试运行容器先验证"再切换。

### P2. Harbor 2.x 私仓 proxy 换官方 nginx 镜像：Permission denied 起不来

- 现象：`docker compose up -d --no-deps proxy` 后容器退出，日志 `open() "/etc/nginx/nginx.conf" failed (13: Permission denied)`；直接换镜像会被门禁自动回滚。
- 原因：Harbor 2.x 的 `./prepare` 把 `nginx.conf` 与证书属主设为 uid 10000（权限 440/600）。原 `nginx-photon` 镜像以 uid 10000 运行所以可读；官方 nginx 镜像默认 root 运行，而 Harbor compose 定义了 `cap_drop: ALL`（无 `CAP_DAC_OVERRIDE`），root 也读不了 10000 属主的文件。
- 处理：compose 的 proxy 服务加 `user: "10000:10000"`。8080/8443 均为非特权端口，master/worker 全部以 10000 运行，与 photon 行为一致，不影响回滚。
- 预防：换"运行用户约定"不同的镜像时，先核对目标文件属主与容器 uid、cap 集合。

### P3. CentOS 7 的 openssl 1.0.2 `s_client` 显示 `Protocol : TLSv1`，误判旧协议仍放行

- 现象：改完 `ssl_protocols TLSv1.2 TLSv1.3` 后，在 EL7 宿主机用 `openssl s_client -tls1` 测试，输出里仍有 `Protocol : TLSv1`。
- 原因：openssl 1.0.2 的 s_client 输出的 `Protocol :` 是**请求**的版本，握手失败也会打印；旧客户端工具本身不支持 TLS 1.3。
- 处理：看握手是否成功——失败时 cipher 行为 `New, (NONE)`；或者干脆用新客户端验证：容器内 `openssl s_client -tls1_3`，或控制机 `scripts/tls_scan.py`（内部用 `(NONE)` 判定拒绝）。
- 预防：TLS 验证工具版本要 >= 被测协议集；证据以"握手结果"为准，不以"打印的请求参数"为准。

### P4. 重跑 Harbor `./prepare` / `install.sh`，所有手工改动丢失

- 现象：之后某次运维重跑 prepare 或 install.sh，proxy 镜像回到 `nginx-photon`、`user:` 没了、`ssl_protocols` 回旧值、80 端口直通块消失。
- 原因：prepare/install 会按模板**重新生成** `docker-compose.yml` 与 `common/config/nginx/nginx.conf`，手工改动全部被覆盖。
- 处理：把所有改动写成可重放的变更脚本（改 compose 的 user/镜像、直通 location、ssl_protocols），重跑 prepare 后按脚本重放；并在运维文档里标注"禁止裸跑 install.sh 后不重放"。
- 预防：任何"配置由上游工具生成"的场景，改动必须脚本化、可幂等重放。

### P5. 门禁比较 308 重定向页正文长度，1 字节差异导致误判失败

- 现象：Harbor proxy 首次切换被门禁自动回滚；差异只有 `http→https` 的 308 页正文长度 172 vs 171 字节，状态码与 Location 完全一致。
- 原因：不同 nginx 版本的默认 404/308 错误页 HTML 有 1 字节的版本相关差异，重定向页无自定义模板时正文不具可比性。
- 处理：门禁口径改为**只对 2xx 比较正文（md5/长度）；3xx 只比状态码 + 跳转地址**。改后重切，0 差异。
- 预防：门禁比较的字段要按响应类别分级，越严的口径越容易被无意义的字节差触发。

### P6. CentOS 7 源码编译 nginx 1.18→1.30.7：OpenSSL 3 的 Configure 报缺 perl 模块

- 现象：`./config` OpenSSL 3.5.x 时报 `Can't locate IPC/Cmd.pm` / `Time/Piece.pm`。
- 原因：CentOS 7 base 源未配置（或已 EOL 下架），系统 perl 缺 `IPC::Cmd`、`Time::Piece`，这是 OpenSSL 3 Configure 的硬依赖。
- 处理：临时挂 centos-vault 7.9.2009 os 源（gpgcheck=1，官方 key），`yum install perl-IPC-Cmd perl-Time-Piece`，装完**即删 repo 文件**（perl 包保留无害）。
- 编译与切换：configure 沿用原参数（`--prefix=/usr/local/nginx --with-http_ssl_module --with-pcre`），按需追加模块与 `--with-openssl=<源码目录>`（静态链接）；gcc 4.8.5 可过。切换用 **USR2 → 确认新 master/worker → WINCH → QUIT** 平滑替换，systemd forking 的 MainPID 自动跟随新 master，无需改 unit。旧二进制留存 `nginx-<旧版本>.bak`。
- 预防：老系统上任何带 OpenSSL 3 的编译，先核对 perl 模块；源码包做 PGP 签名 + SHA-256 双重校验。

### P7. 有 Lua 业务的 OpenResty 网关不能换纯 nginx

- 现象：某网关用 Lua 做路由、JWT、限流、排队、熔断；换成官方 nginx 后这些能力全部失效。
- 原因：OpenResty 的 Lua 能力来自 lua-nginx-module，官方 nginx 无此模块；OpenResty 出基于新 nginx 补丁版的版本滞后于 nginx.org 发布。
- 处理：只能跟 OpenResty 版本（如 1.31.1.1 → 1.31.8.1，修复了部分历史 CVE），并在报告中**明确记录**：本批 CVE 在该版本仍未修复，属"过渡方案 + 待升级"，OpenResty 发布基于修复版 nginx 的版本后需再次升级。镜像按 digest 拉取、推私仓，`.env` 与 compose 默认值同改。
- 预防：勘察阶段就要识别 Lua 指令的真实使用（`lua_package_*`、`*_by_lua*`），据此分流升级路径；无实际引用的 Lua 指令可以直接转 nginx。

### P8. 镜像 tag 与 Harbor DB 不一致（跨大版本迁移后 OCI tag 丢记录）

- 现象：Harbor 1.x→2.x 逐跳迁移后，部分 tag 在 UI 不显示或 `docker pull` 报 manifest unknown，但 blob 数据在磁盘上存在；另有一些 tag 连 blob 也缺失。
- 原因：跨大版本迁移时 glibc collation 变更曾使 PG 索引失效（core 空指针 panic），修复后仍有 39 个 OCI tag 的 DB 记录缺失；blob 缺失的个别 tag 是升级前就已损坏。
- 处理：先起 db `reindexdb -a` 修 collation 索引；DB 缺记录的 tag 用 manifest PUT 重注册（实测可恢复大部分）；blob 数据本身缺失的（升级前就坏）只能重新构建推送（走 CI 重推）。
- 预防：大版本迁移每跳前增量备份 DB；迁移后用 `HEAD manifest` 清单比对磁盘 tag 与 DB 记录。

### P9. TLS 1.3 验证需要新客户端，EL7 自带工具验不了

- 现象：宿主机 openssl 1.0.2 无法发起 TLS 1.3 握手，验不出"1.3 成功"。
- 原因：TLS 1.3 需要 openssl 1.1.1+，EL7 系 openssl 是 1.0.2。
- 处理：在 nginx 容器内用自带 openssl 3.x 验证；或控制机用 `scripts/tls_scan.py`（新 openssl 子进程实现）。与 P3 同根：验证工具的能力集要先于结论。

### P10. 批量 fleet 执行：失败继续跑等于放大事故

- 现象：十几台主机的批量升级，若一台切换失败后续主机继续执行，回滚面扩大。
- 处理：批量执行器逐台把输出落盘归档（`outdir/<host>.<tag>.txt`，首行带 rc），**任一台非零 rc 自动停止**后续；执行顺序先灰度单台（选风险最低的实例）确认无坑，再批量。
- 预防：批量脚本默认 `fail-fast`；需要"尽力跑完"的场景必须显式开关。每台留档，事后可审计每一步证据。
