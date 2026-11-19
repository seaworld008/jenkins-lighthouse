# 验证矩阵（验证矩阵与证据口径）

## 1. 稳定探测（每个实例必做）

| 项 | 口径 |
|---|---|
| 探测目标 | 阶段 1 从 `nginx -T` 解析出的全部 (协议, 端口, server_name)，每 server 探测 `/` + 不存在路径 |
| 基线 | 变更前两轮一致的结果（状态码、跳转地址、正文 md5） |
| 门禁比较 | 2xx：状态码 + 正文 md5；3xx：状态码 + Location；非 2xx/3xx：仅状态码 |
| 通过标准 | 变更后对基线探测 **差异 = 0**；有预期改动（如 80 端口 308→401 直通）单独列出并说明 |
| 已存在的 500/502/403 | 属后端/业务状态，升级前后一致即通过 |

## 2. TLS 逐版本握手

| 检查项 | 期望 |
|---|---|
| TLS 1.0 | 拒绝（握手失败，cipher 行 `New, (NONE)`） |
| TLS 1.1 | 拒绝 |
| TLS 1.2 | 成功 |
| TLS 1.3 | 成功（需要新客户端，见 pitfalls P3/P9） |

- 工具：`scripts/tls_scan.py`（openssl s_client 子进程，`(NONE)` 判定拒绝），输出逐 host:port 表格。
- 证据口径：以握手结果为准，**不**以旧客户端打印的请求版本为准。

## 3. 按场景的专项验证

| 场景 | 验证项 | 证据 |
|---|---|---|
| 容器 | `docker exec <c> nginx -v`；restart 策略与开机自启核对 | 版本输出、inspect 输出 |
| compose 容器 | `docker compose ps` healthy/running；镜像引用是目标 tag | compose ps 输出 |
| docker run 容器 | 新容器名沿用原名；旧容器 rename 保留且 restart=no | `docker ps -a` |
| rpm | `rpm -q nginx`；`systemctl status nginx` master PID 变化 | 包版本、PID 前后对照 |
| 源码 | `nginx -v`（新二进制）；systemd MainPID 跟随；旧二进制 .bak 在位 | PID 对照、文件列表 |
| OpenResty 过渡 | `openresty -V`；试运行对比项 0 差异；记录"本批 CVE 未修复，待再升级" | 版本输出、对比表 |
| 私仓（Harbor）入口 | 真实 `docker pull`（不同主机）；token → manifest → blob 全流程；HTTP/HTTPS × 公网/内网四组合各测一遍 | pull 输出、各步 HTTP 状态码（凭据不打印） |
| K8s 前端 | `kubectl rollout status`；ingress 状态码前后对比；pod 内 `nginx -v`（注意校验 pod 的 image 字段，Terminating 旧 pod 仍显示 Running phase） | rollout 输出、ingress 前后对比 |
| Jenkins FROM 替换 | 重启后 `/login` 200、任务数完好、磁盘无残留旧 FROM | 控制器健康输出 |

## 4. 汇总表模板

| 实例 | 稳定探测数 | 变更后差异 | TLS 1.0/1.1 | TLS 1.2/1.3 | 专项验证 |
|---|---|---|---|---|---|
| host-a / 容器 nginx | 22 | 0 | 拒绝/拒绝 | 成功/成功 | exec -v = 1.30.7 |
| host-b / 源码 | 10 | 0 | 拒绝/拒绝 | 成功/成功 | MainPID 跟随 |
| host-c / 私仓入口 | 12 | 0 | 拒绝/拒绝 | 成功/成功 | 四组合拉取 200 |
