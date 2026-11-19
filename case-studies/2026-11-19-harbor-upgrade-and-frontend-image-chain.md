---
date: 2026-11-19
cloud: huawei
profile: "Harbor 私仓（proxy 入口 nginx）+ CCE K8s 前端镜像链路 + Jenkins 构建任务"
source_version: Harbor 1.8.0（入口 nginx 1.15.11，OpenSSL 1.0.2r）/ Docker 19.03.8 / 前端底镜像 nginx 1.25.2-1.31.4
target_version: Harbor 2.15.5 / Docker 26.1.4 / 底镜像 nginx 1.30.7
result: success
duration_hours: 6
skill_version: 0.1.0
operator: agent+human
---

# Harbor 私仓升级与前端镜像链路（第二阶段）

## 0. 背景

第一阶段把 Harbor 入口 proxy 换成了官方 nginx 1.30.7，但 Harbor 本体仍是 v1.8.0（2019 年版本，portal 亦为旧 nginx）。本阶段完成：Harbor 逐跳升级到 2.15.5 并重做 proxy 替换、宿主 Docker 升级、9 个 K8s 前端应用换底重建滚动更新、23 个 Jenkins 任务 FROM 替换。

## 1. 机器画像（脱敏）

- server18：Harbor 私仓主机，CentOS 7 + Docker 19.03.8，`harbor.service`（compose）管理；数据盘承载 3460 个工件。
- server17：构建/控制节点（Docker 新版本可拉取），承担新底镜像构建、Jenkins 控制器容器。
- server20：kubectl 节点；CCE 生产命名空间 prod。
- 业务侧架构：生产业务镜像走云厂商镜像仓库（registry.example.com），Harbor 承担 Jenkins 构建底镜像与少量中间件镜像。

## 2. 与业务方确认的决定

- Harbor 原地升级（可停机窗口）；升级后须兼容旧地址拉取，HTTP 与 HTTPS 都能拉。
- php-fpm 底镜像不动；9 个前端换底重建 + 滚动更新 + 改 Jenkins FROM。
- 破损 blob 的镜像（升级前已坏）从 Jenkins 重推。

## 3. 时间线（要点）

| 时间 | 步骤 | 结果 |
|---|---|---|
| 18:24 | 全量备份（pg_dumpall、DB 目录、安装文件、fs-tags） | LATEST 指针就绪 |
| 18:40 | 首次迁移尝试 | 失败（glibc collation 索引失效，DB 隔离，未动原数据） |
| 19:00-22:00 | 逐跳迁移 1.10.19→2.4.3→2.6.4→2.8.6→2.10.3→2.12.4→2.14.6→2.15.5，每跳增量备份 + `reindexdb -a` 校验索引 | 全部成功；PG 18.6、schema 181、项目 12 / 仓库 352 / 工件 3460 |
| 22:00 | OCI tag 重注册（manifest PUT）39 个 | 成功 33 个；6 个 blob 本身缺失（升级前已坏） |
| 22:30 | proxy 换 nginx 1.30.7（重做，含 uid 10000 修复、80 直通、TLS） | 首次 Permission denied 自动回滚 → 加 user 后 0 差异 |
| 23:00 | HTTP/HTTPS × 公网/内网四组合真实拉取实测 | 全部 200 |
| 23:30 | 9 前端换底重建、推仓库、K8s 逐个滚动 | 全部 2/2 ready，0 差异 |
| 00:20 | Jenkins 23 个任务 FROM 替换 + 控制器重启 | 15s 恢复 healthy，329 任务完好 |

## 4. 遇到的问题

### 4.1 glibc collation 变更导致 PG 索引失效，core 空指针 panic
- 阶段：Harbor 迁移首跳
- 现象：core 容器 panic，quota-sync 空指针。
- 原因：跨大版本迁移中 glibc collation 变更使 PG 索引失效。
- 处理：每跳先起 db 再 `reindexdb -a` 并校验索引，最终 collation 全部一致；首次失败的 DB 单独隔离留存。
- 状态：promoted → `pitfalls.md` P8（关联）

### 4.2 Harbor 2.x proxy 换官方 nginx：Permission denied
- 阶段：proxy 重做
- 现象：直接换镜像后容器退出，`open() "/etc/nginx/nginx.conf" failed (13: Permission denied)`。
- 原因：prepare 把 nginx.conf/证书属主设 uid 10000（440/600）；官方镜像 root 运行 + `cap_drop: ALL`（无 DAC_OVERRIDE）读不了。
- 处理：compose 的 proxy 服务加 `user: "10000:10000"`（8080/8443 非特权端口，与 photon 行为一致）。
- 状态：promoted → `pitfalls.md` P2

### 4.3 `./prepare` / `install.sh` 会重生成 compose 与 nginx.conf
- 阶段：运维约定
- 现象：重跑 prepare 后镜像、user、ssl_protocols、80 直通全部回旧值。
- 处理：改动写成可重放脚本（镜像、user、直通 location、ssl_protocols），重跑后按脚本重放。
- 状态：promoted → `pitfalls.md` P4

### 4.4 OCI tag 与 Harbor DB 不一致
- 阶段：迁移收尾
- 现象：39 个 tag DB 无记录；其中 6 个连 blob 都缺失。
- 原因：迁移历史遗留；blob 缺失的属升级前已损坏。
- 处理：manifest PUT 重注册 33 个；6 个从 Jenkins 重推重建。
- 状态：promoted → `pitfalls.md` P8

### 4.5 exec 确认 pod 版本时打到 Terminating 旧容器
- 阶段：K8s 滚动验证
- 现象：滚动后 exec 查到的 nginx 版本仍是旧的。
- 原因：Terminating 旧 pod 仍为 Running phase，exec 未校验目标。
- 处理：校验 pod 的 `image` 字段后再 exec。
- 状态：promoted → `image-chain.md` 第 ⑥ 步注意事项

### 4.6 节点本地网络隔离导致 nodePort 探测 000
- 阶段：滚动验证
- 现象：无 ingress 的应用，某节点本机访问 nodePort 返回 000。
- 原因：既有网络隔离，非本次引入。
- 处理：改在 pod 所在节点实测 200，记录为已知问题。
- 状态：记录于遗留事项

## 5. 关键改动明细

### Harbor 本体
- Docker 19.03.8 → 26.1.4（compose 插件 2.27.1、containerd 1.6.33），yum versionlock 锁定；临时 vault 源用完即删。
- 逐跳 8 个版本，每跳前增量备份 DB；备份 `/data/harbor-backup/1.8.0-20261119-182425/`（LATEST 指针），含 pg_dumpall、DB、安装文件、fs-tags 3411 个；旧 1.8 文件与首次失败 DB 均单独留存。
- systemd 重写为 oneshot `harbor.service`（compose up -d / down），daemon-reload 后 enabled + active。

### proxy 入口
- 换官方 nginx 1.30.7 + `user: "10000:10000"`（见 4.2）。
- 80 端口不再无差别 308：8080 server 块为 `/v2/`、`/service/` 加直通后端的 location（HTTP 可直接拉镜像），其余路径 `return 308 https://$host:443$request_uri`。
- `ssl_protocols TLSv1.2 TLSv1.3`；proxy 容器内 openssl 3.x 实测 1.0/1.1 拒绝、1.2/1.3 成功。
- 回滚包：compose、nginx.conf、systemd unit 三件备份，恢复后 `up -d --no-deps proxy`。

### K8s 前端镜像链路（9 个应用，frontend-1…frontend-9）
- 新底镜像：`registry.example.com/library/nginx-…:1.30.7`（nginx 1.30.7 + TZ + curl）；需 node 运行时的前端用 +node20 变体。按 digest 拉取官方镜像构建，推私仓并 HEAD manifest 核对。
- 换底重建（`FROM 新底 + COPY --from=旧镜像`，conf/html 不变，`nginx -t` 通过），tag 加 `-n1307` 后缀。
- 新旧镜像本地起容器逐路径对比：状态码/缓存头/压缩/正文 md5，仅 nginx 默认 404 页版本字符串差异属预期。
- 推业务镜像仓库；`kubectl set image` + `rollout status --timeout=300s` 逐个滚动，9 个 deployment 全部 2/2 ready、updated=2，pod 内实测 `nginx/1.30.7`；ingress 状态码前后一致，无 ingress 的经 nodePort 在 pod 所在节点实测 200。

### Jenkins 任务 FROM 替换（23 个前端构建任务）
- 先 `tar` 备份全部 `config.xml`；sed 替换运行时阶段 FROM（多个旧底 tag → 新底 tag；需 node 的换 node 变体）；重启控制器约 15s 恢复 healthy，`/login` 200，329 个任务完好，磁盘无残留旧运行时 FROM。
- builder 阶段、php-fpm 任务、仅作构建容器使用（产物为静态 dist）的任务不动。

## 6. 结果对比（验证矩阵）

| 检查项 | 升级前 | 升级后 | 备注 |
|---|---|---|---|
| Harbor 版本 / health | 1.8.0 / 停机 | 2.15.5 / healthy | core 重启 0 次（修复 collation 后） |
| 入口 nginx | 1.15.11（OpenSSL 1.0.2r） | 1.30.7 | proxy 服务单独替换 |
| 入口稳定探测 | 基线 12 项 | 差异 0 | `/v2/`、`/service/token` 由 308 变 401 为预期直通改动 |
| TLS | 1.1/1.2 | 1.0/1.1 拒、1.2/1.3 成 | 容器内 openssl 3.x 实测 |
| 真实拉取 | — | token→manifest→blob 全流程，HTTP/HTTPS × 公网/内网四组合 | 全部 200，凭据未打印 |
| Docker | 19.03.8 | 26.1.4 | versionlock |
| 前端 deployment | 底镜像 nginx 1.25.2-1.31.4 | 全部 1.30.7 | 9 个，ingress 前后一致 |
| Jenkins 任务 | 旧底 FROM | 新底 FROM ×23 | 备份 tar 在位 |

## 7. 回滚（第二阶段形态）

| 对象 | 方法 |
|---|---|
| Harbor proxy | 备份目录覆盖 compose + nginx.conf（+ systemd unit），`docker compose up -d --no-deps proxy` |
| Harbor 本体 | 1.8.0 全量备份（pg_dumpall + DB 目录 + 安装文件）+ 旧版本文件目录可整体回装；逐跳备份支持回退到任一中间版 |
| K8s 前端 | `kubectl set image` 回旧 tag（旧 tag 未删）逐个回退 |
| Jenkins FROM | 备份 tar 覆盖 config.xml + 重启控制器 |

## 8. 技能/脚本的不足

- Harbor 逐跳迁移与 reindex 属一次性重活，本技能只沉淀为检查口径（playbook/pitfalls），未做成通用脚本（各版本路径差异大）。
- 镜像换底重建当时逐应用手写 Dockerfile，`image-chain.md` 已固化为七步模板。

## 9. 遗留事项

- 重跑 `./prepare`/`install.sh` 后必须重放变更脚本（见 4.3）。
- 6 个 blob 缺失镜像从 Jenkins 重推（业务方执行中）。
- 云厂商仓库中一个旧测试镜像已不可拉取且 pod 依赖节点缓存，建议换用新 `-n1307` tag 或删除。
- 清理项：各跳离线安装包（约 6GB）、首次失败的 DB 目录、旧版本镜像、旧 Jenkins home 归档。
- 待云厂商升级其 nginx-ingress 插件（内嵌 nginx 亦有旧版本）。
