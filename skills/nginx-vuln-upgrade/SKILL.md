---
name: nginx-vuln-upgrade
description: Upgrade nginx across a mixed fleet (Docker Compose containers, docker run, rpm, source-compiled, OpenResty, Harbor registry proxy, K8s frontend base images) to a patched release after nginx.org publishes CVEs. Covers read-only survey, two-round baseline probing, image prep by digest, trial-run container comparison, gated cutover with auto-rollback, separate TLS tightening, per-instance verification matrix, and rollback rehearsal. Use when the user asks to patch nginx CVEs, batch-upgrade nginx across hosts/clouds, convert OpenResty to nginx, replace the Harbor proxy image, or rebuild frontend images embedding nginx.
---

# nginx 漏洞批量升级

把混合形态的 nginx（容器 / rpm / 源码 / OpenResty / 私仓入口 / K8s 底镜像）安全地升到修复版本：**每一步有门禁、可自动回滚、以真实流量验证**。本技能来自一次覆盖两个云、十几台主机的真实 CVE 批量升级（2026-11-19），见 `../../case-studies/`。

## 原则

1. **变更有门禁、可自动回滚。** 切换前先跑 `nginx -t`、起试运行容器对比、探测基线；任何基线变化自动还原，不允许"看起来正常"就切。
2. **试运行容器与现网逐项对比后再切。** 同挂载、同网络起临时实例，逐 (协议, 端口, server_name, 路径) 对比状态码、跳转地址、正文 md5，全一致才动现网。
3. **版本切换与 TLS 修改分开做。** 各自有独立门禁与回滚，一次只变更一个维度。
4. **探测基线 = 两轮一致。** 对 `/` 与不存在路径各探测两轮，取两轮一致的结果作为基线；一轮噪声不进门禁。
5. **以真实流量验证。** 探测之外，容器场景 `docker exec nginx -v`，私仓场景真实 `docker pull` + token → manifest → blob 全流程。
6. **影响业务的事问人。** 移除 Lua WAF、改 TLS 放行版本、OpenResty 只能跟版本过渡、删除旧容器/镜像，先向用户确认再执行。
7. **不碰凭据。** 不代输密码、不在输出中打印 token/凭据；SSH 用密钥认证，凭据不落盘。

## 流程

按阶段推进，每个阶段的详细检查清单在 `references/playbook.md`。

| 阶段 | 做什么 | 产出 |
|---|---|---|
| 1 勘察（只读） | `nginx -T` 解析 (协议, 端口, server_name) 清单；区分二进制 / 容器 / OpenResty；记录 `ssl_protocols` | 实例清单、TLS 现状 |
| 2 基线探测 | 每 server 两轮探测 `/` 与不存在路径，输出状态码 + 跳转地址 + 正文 md5 | 两轮一致的基线表 |
| 3 目标镜像准备 | 官方镜像按 digest 拉取（内容校验）、推私仓、image ID 核对 | 私仓镜像 + digest 记录 |
| 4 试运行对比 | 同挂载同网络起临时容器，逐项对比基线 | 对比记录，0 差异才继续 |
| 5 门禁切换 | compose 改镜像 `up -d --no-deps`；docker run 先 rename 旧容器；rpm `dnf upgrade`；源码 USR2/WINCH/QUIT | 切换日志 + 自动回滚兜底 |
| 6 TLS 收紧 | `ssl_protocols` 改 `TLSv1.2 TLSv1.3`，单独 reload，独立门禁 | TLS 变更记录 |
| 7 验证 | 探测对比 + 真实 curl/pull + 逐版本 TLS 握手（`scripts/tls_scan.py`） | 验证矩阵，差异 0 |
| 8 回滚演练 | `references/rollback.md` 每形态演练一次（或核对备份可用） | 回滚确认记录 |
| 9 收尾 | 批量归档输出、开机自启核对、写案例报告 | 案例报告、遗留事项 |

## 关键做法

- **批量执行**用 `scripts/fleet_exec.py`：inventory 从 JSON 读，每台输出落盘 `outdir/<host>.<tag>.txt`（首行带 rc），失败自动停，先灰度单台再批量。
- **门禁口径**：只对 2xx 比较正文；3xx 只比状态码 + 跳转地址（不同 nginx 版本默认重定向页正文长度差 1 字节属预期）。
- **OpenResty 分流**：无实际 Lua 业务的转纯 nginx（配置转换，删 `lua_package_*`、Lua block 改等效 return）；有 Lua 路由/JWT/限流的只能跟 OpenResty 版本，记录"过渡方案 + 待升级"。
- **老 Docker + 新镜像**：Docker 19.03 旧 seccomp 规则与新 glibc 系统调用冲突，先起试运行容器验证入口脚本与业务路径，见 `references/pitfalls.md`。
- **私仓入口（Harbor proxy）**：换官方 nginx 镜像时注意属主/uid 与 capability，见 `references/pitfalls.md`；`./prepare` 会重生成配置，改动要可重放。
- **内嵌 nginx 的业务镜像**走 `references/image-chain.md` 的七步链路（扫描 → 新底镜像 → 换底重建 → 本地对比 → 推仓库 → kubectl 滚动 → Jenkins FROM 批量替换）。
- **TLS 1.3 验证需要新客户端**：EL7 自带 openssl 1.0.2 验不了 1.3，且其 `s_client` 输出的 `Protocol : TLSv1` 是请求版本不能当放行证据；用容器内新 openssl 或 `scripts/tls_scan.py`。

## 参考

- `references/playbook.md`：分阶段详细检查清单
- `references/pitfalls.md`：现象 → 原因 → 处理（10 个真实坑）
- `references/verification.md`：验证矩阵与证据口径
- `references/rollback.md`：各形态回滚方法
- `references/image-chain.md`：内嵌 nginx 业务镜像升级链路
- `scripts/fleet_exec.py`：批量执行器（inventory 见 `scripts/inventory.example.json`，依赖 paramiko）
- `scripts/tls_scan.py`：TLS 逐版本握手扫描
- `scripts/trial_swap.sh`：试运行对比 + 门禁切换 + 自动回滚模板

## 结束时

写一份脱敏的案例报告（格式参照 `../../case-studies/` 既有报告的前置元数据 + 编号章节），把新坑补进 `references/pitfalls.md`，更新 `CHANGELOG.md`。
