# nginx 漏洞升级 playbook（分阶段检查清单）

## 阶段 1：勘察（只读）

- 逐主机盘点 nginx 形态，明确升级方式：

| 形态 | 识别方式 | 升级方式 |
|---|---|---|
| compose 容器 | `docker ps` + `docker inspect` 找 compose 工作目录 | 改镜像 + `up -d --no-deps` |
| docker run 容器 | `docker inspect` 无 compose 标签 | rename 旧容器保留回滚，起新容器 |
| rpm 二进制 | `rpm -q nginx`、`systemctl status nginx` | `dnf upgrade nginx-<目标>` |
| 源码编译 | `/usr/local/nginx`、非包管理器二进制 | 同参数重编译 + USR2/WINCH/QUIT |
| OpenResty | `openresty -V`、`resty` 目录、`lua_package_*` | 无 Lua 业务→转 nginx；有 Lua→跟 OpenResty 版本 |
| Harbor proxy | harbor compose 的 `proxy`/`nginx` 服务 | 见 pitfalls #2，单独处理 |

- `nginx -T`（或 `docker exec <c> nginx -T`）全量 dump 配置，解析出 **(协议, 端口, server_name) 清单**，记录每个 server 的 `ssl_protocols`、证书路径、是否有 Lua 指令。
- 记录容器挂载、网络、restart 策略、systemd unit（enabled/active）、开机自启链路。
- 区分监听 80 直通/308 跳转语义，切换后要按语义验证而不是死板的"字节一致"。

## 阶段 2：基线探测

口径（两轮一致才作为基线）：

1. 对每个 (协议, 端口, server_name)：用 `Host: <server_name>`（HTTPS 场景可加 `--resolve <name>:443:127.0.0.1`）探测两个路径：`/` 与一个不存在的路径（如 `/__nonexist_probe__`）。
2. 每轮输出：**HTTP 状态码 + 跳转地址（Location，若有）+ 正文 md5 + 正文长度**。
3. 跑两轮，间隔 5 秒以上；两轮完全一致的项目进入基线表；不一致的项目（有随机内容、后端抖动）标注"不稳定，不进门禁"。
4. 已存在的 500/502/403 是后端/业务状态，属预期基线，记录后不处理。
5. 基线表与 `nginx -T` dump、compose 文件一起落盘备份目录（如 `/root/nginx-upgrade-backup/<时间戳>/`）。

## 阶段 3：目标镜像准备

- 从官方渠道确认目标 tag 与 **index digest**（nginx.org 公告 + Docker Hub 页面）。
- 无法直连 Docker Hub 时，经可信加速源**按 digest 拉取**（digest 定内容，来源不改变内容）。
- 推私仓（如 `registry.example.com/library/nginx:1.30.7-trixie`），回拉核对 image ID / manifest 一致。
- 不配 insecure registry 的主机：`docker save` → 控制机中转 → `docker load`，image ID 核对一致；**不改 daemon.json**（避免重启 Docker 影响其它容器）。
- 需要增量（TZ、curl 等）时构建自定义底镜像，FROM 官方镜像按 digest，推私仓并记录 manifest。

## 阶段 4：试运行容器

- 用**完全相同的挂载、网络、环境变量**起临时容器（compose 场景 `docker compose run --no-deps` 或临时 service；docker run 场景复制 inspect 参数）。
- 试运行容器内先 `nginx -t`（新版本对旧配置）。
- 按基线口径对试运行容器逐项探测，与现网基线逐项对比。
- 老内核/老 Docker 上的兼容性（seccomp 坑）见 `pitfalls.md` #1：确认 nginx 本身启动、worker、监听、TLS 正常即可，入口脚本的可选步骤被跳过不一定影响业务。
- 对比 0 差异（按门禁口径）才进入切换；否则先解决差异。

## 阶段 5：门禁切换

统一动作：

1. 备份：compose 文件 / docker inspect / `nginx -T` / 基线表 → 备份目录。
2. compose：改镜像引用（`.env` 与 compose 内默认值都改，防 `.env` 丢失回退旧版本），`docker compose up -d --no-deps <svc>`。
3. docker run：旧容器 `docker rename <name> <name>-old-<旧版本>` 并 `docker update --restart=no` + stop；新容器沿用原容器名与挂载，启动脚本另存（如 `run-nginx-<版本>.sh`）。
4. rpm：`dnf upgrade nginx-<目标>`，rpm 包脚本自动平滑升级（master 继承监听 socket），核对 master PID 变化。
5. 源码：见 `pitfalls.md` #6（perl 依赖、vault 源）；编译产物先 `-t`，再 USR2 → 等新 worker 起来 → WINCH（优雅停旧 worker）→ QUIT（停旧 master）；systemd forking 模式 MainPID 自动跟随新 master。
6. 切换后立即按基线复查（脚本模板 `../scripts/trial_swap.sh` 内置"不一致自动还原 + up 回旧镜像"）。
7. 开机自启核对：restart 策略、docker enabled、systemd unit enabled/active、unit 描述里的版本号同步更新。

## 阶段 6：TLS 收紧

- 单独一轮变更，与版本切换分开（见原则 3）。
- `ssl_protocols TLSv1 TLSv1.1 TLSv1.2` → `TLSv1.2 TLSv1.3`；`nginx -t` 后 reload。
- 兼容旧客户端的残留配置（如 `openssl-legacy.cnf` 挂载）一并移除。
- 用**新客户端**验证（见阶段 7 与 `pitfalls.md` #3/#9）。

## 阶段 7：验证

详见 `verification.md` 验证矩阵。要点：稳定探测 N 项差异 0；TLS 1.0/1.1 拒绝、1.2/1.3 成功；容器内 `nginx -v`；私仓真实拉取全流程。

## 阶段 8：回滚演练

- 每个形态在切换前**核对**备份可用（compose 备份存在且能 diff、旧二进制 .bak 存在、旧容器 rename 后还在）；能演练的（非生产高峰）实际演练一次。
- 回滚方法见 `rollback.md`，逐实例写清备份目录路径与恢复命令。

## 阶段 9：收尾

- 批量输出归档（`fleet_exec.py` 的 `outdir/<host>.<tag>.txt`）。
- 写案例报告回填 `pitfalls.md`；列出内嵌 nginx 的业务镜像、第三方产品内置 nginx、待升级项（如 OpenResty 出修复版后的二次升级）。
