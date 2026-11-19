---
name: jenkins-lts-upgrade
description: Upgrade or migrate a legacy Jenkins (2.2xx/2.3xx/2.4xx on Java 8/11, war or Tomcat or rpm) to the current Jenkins LTS (2.580.x, Java 21/25) with near-zero downtime. Covers read-only survey, rehearsal on a data copy, Docker Compose controller + host build agent, keeping builds on Java 8, rootless Docker publishing agents, cutover/rollback, per-job release acceptance and post-upgrade checks. Use when the user asks to upgrade, migrate, dockerize, or harden an old Jenkins, or when Jenkins builds break after such an upgrade.
---

# Jenkins LTS 升级与迁移

把老 Jenkins 安全地升级到当前 LTS：**业务构建不变、可回滚、每一步有证据**。本技能来自两套真实环境的升级（开发环境 2.346.1 → 2.580.2，生产环境 2.275 → 2.580.2），见 `../../case-studies/`。

## 原则

1. **只把控制器放进容器，构建留在宿主机 agent。** 构建脚本看到的命令、路径、`/etc/profile` 尽量不变。唯一有意的变化是编译 JDK 换成受支持的 JDK 8 发行版（如 Temurin 8）。
2. **运行 Jenkins 的 Java 和编译业务的 Java 分开。** 控制器用镜像自带的 Java 25（或 21）；agent 用绝对路径启动，不设 JAVA_HOME、不进 PATH。
3. **先在数据副本上演练，再一次性切换。** 可以直接跨大版本，但插件目录要整体替换成目标版本的插件，不让旧插件在新核心上加载。
4. **每个改动都落盘验证。** 脚本控制台改的全局配置可能只在内存里（见 pitfalls A1）。
5. **以真实构建为证据。** 镜像推送回执的摘要、jar 的 class 主版本、`java -version` 输出，比"看起来正常"可靠。
6. **会改变业务行为的事向用户确认：** 真实生产发布、删除或改写 webhook、改任务分支或依赖、删除他人的测试资源、回滚。不要自动执行。
7. **不代输密码，不打印凭据。** 需要登录 Jenkins 的操作，让用户在浏览器里登录；需要凭据的命令从文件或 systemd credential 读取。

## 流程

按阶段推进，每个阶段的详细检查项在 `references/playbook.md`。

| 阶段 | 做什么 | 产出 |
|---|---|---|
| 0 约定 | 维护窗口、回滚条件、谁能拍板、浏览器登录由谁完成 | 书面约定 |
| 1 勘察（只读） | `scripts/survey-jenkins.sh`、`scripts/scan-job-commands.py` | 风险分级、任务依赖清单 |
| 2 设计 | 选架构（`references/architecture.md`），定 Java 版本（`references/version-matrix.md`）、插件清单 | compose、agent unit、插件清单 |
| 3 演练 | 数据副本 + 不同端口 + 0 执行器 + 收不到 webhook；合成任务和代表性真实任务 | 演练记录、切换和回滚脚本 |
| 4 改造 | agent、工具目录、全局 JDK、凭据（含 Jenkins 之外的 docker/ssh 配置）、基础镜像 | 改造清单 |
| 5 切换 | 静默模式 → 队列为 0 → 停旧服务 → 最后同步 → 启新控制器 → 起 agent | 切换日志、停服时长 |
| 6 验收 | 按发布方式分类，每类一个代表，再分批跑（`references/acceptance.md`） | 每个任务的结果和证据 |
| 7 收尾 | 健康检查、手动全量备份并核对、清理、写记录 | 案例报告、遗留事项 |

回滚方案在切换前就要写好并演练：`references/rollback.md`。

## 关键做法

- **勘察时**特别看：全局 JDK 工具指向哪里（会进 PATH）、`source /etc/profile` 的任务数、写死的 workspace 路径、Maven 类型任务（受控制器 JVM 约束）、Jenkins 凭据库以外的凭据（`~/.docker/config.json`、`~/.ssh`、known_hosts）、私仓证书和 GC 计划、数据盘余量。
- **以 agent 身份复现问题**：`scripts/run-as-agent.sh <unit> -- <命令>` 进入 agent 进程的挂载命名空间和环境，用与构建完全相同的条件执行 `java -version`、`mvn -version`、`docker info`。
- **批量验收**用脚本控制台：`scripts/groovy/trigger-batch.groovy` 按默认参数触发并避开私仓 GC 时段，`scripts/groovy/poll-results.groovy` 收集构建号、镜像 tag、推送摘要和第一条错误。每批 4–8 个，每批后看磁盘。
- **改全局 JDK** 用 `scripts/groovy/set-global-jdk.groovy`，它会比较内存配置和磁盘文件并在保存后复核。
- **Docker 29 + 私有仓库证书不规范**时，预拉基础镜像：`scripts/find-missing-base-images.sh`。
- **失败分类**：环境问题马上修；升级前就失败的旧问题和依赖漂移（锁文件与 `package.json` 不一致等），记录后交给业务方，不擅自改代码仓库。

## 参考

- `references/playbook.md`：分阶段检查清单
- `references/architecture.md`：两种 agent 架构（root 同环境 / 独立账号 + rootless Docker）及取舍
- `references/version-matrix.md`：Jenkins 与 Java 的版本要求、跨版本注意事项
- `references/pitfalls.md`：现象 → 原因 → 处理
- `references/acceptance.md`：逐任务验收方法和证据口径
- `references/rollback.md`：回滚设计
- `scripts/`：勘察、扫描、以 agent 身份执行、基础镜像检查；`scripts/groovy/`：脚本控制台片段
- `assets/`：compose、systemd unit、切换/回滚脚本模板、验收表模板

## 结束时

写一份脱敏的案例报告（模板 `../../case-studies/TEMPLATE.md`），把新坑补进 `references/pitfalls.md`，更新 `CHANGELOG.md`。
