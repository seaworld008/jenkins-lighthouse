---
date: 2026-11-19
cloud: huawei
profile: "生产 Jenkins，289 个任务，独立账号 + rootless Docker 发布 Agent，镜像交付为主"
source_version: "Jenkins 2.275 / Java 8"
target_version: "Jenkins 2.580.2 LTS / Java 25 控制器 / Java 21 Remoting / Temurin 8u512 应用构建"
result: partial
duration_hours: 8
skill_version: 0.1.0
operator: agent+human
---

# 生产环境 Jenkins 2.275 → 2.580.2（容器化控制器 + rootless 发布 Agent）

## 1. 机器画像（脱敏）

- 华为云 server17，AlmaLinux 10.2，4 核以上、数据盘约 50G（切换前剩余 16G）。旧 Jenkins、rsyncd、既有应用容器继续运行。
- 旧服务：Jenkins 2.275（Java 8），宿主机直接运行，JENKINS_HOME 约 289 个顶层任务、357 份构建记录。
- 构建依赖：宿主机 Maven、NodeJS（多版本工具）、PHP CLI、Git、docker；大量任务 `source /etc/profile`（会把 Maven 切回旧 Oracle JDK）；写死的共享绝对路径；旧工作区顶层归 root。
- 凭据：Jenkins 凭据库与主密钥之外，旧运行账号的 `~/.docker/config.json`（私仓 `registry.example.com` 登录项）、`~/.ssh`、known_hosts 也被构建使用。
- 私仓：registry.example.com（Harbor v1.8），每小时整点 GC（GC 期间只读），证书不含 IP SAN。
- survey 的 BLOCKER / HIGH 摘要：无 BLOCKER；HIGH——source `/etc/profile` 的任务数、旧工作区归 root 新账号无法写、全局 JDK 工具指向旧 Oracle JDK（会进 PATH）、数据盘余量偏小。

## 2. 与业务方确认的决定

- 架构选方案 B（`references/architecture.md`）：控制器进容器（数据盘持久化 HOME），构建走独立账号 `jenkins-release` 的发布 Agent（Java 21 Remoting、4 执行器）+ 该账号自己的 rootless Docker；线上容器仍由系统 Docker 承载，构建碰不到它们。
- 26 个预发任务和 5 个已确认停用的任务在迁移副本中停用，保留原配置和历史；旧控制器已删除的一个任务从新版任务目录移出，单独归档配置与 36 份历史。
- 两个 Git 仓库不可见的任务和一组节日活动任务按业务方要求保留待确认，继续验收其他在用任务。
- 会写生产的任务（PHP/Composer、rsync 拉取、对象存储上传、SSH 到目标机的 Compose 发布）需要业务方给发布窗口，每类先做一个真实发布；本次先完成"只构建并推送镜像"的 36 个任务的真实构建与推送。
- rootless Docker 对私仓的 insecure 例外：业务方批准后，只对指定仓库配置，不动全局。

## 3. 时间线

| 时间 | 步骤 | 结果 / 备注 |
|---|---|---|
| 升级前 | 勘察、任务依赖扫描（命令/远端目标/分支）、SSH 与 Git 身份验证 | 134 个仓库、17 个发布目标验证 |
| 升级前 | 隔离副本演练：容器化控制器 + 新 Agent + rootless Docker | 合成任务、代表性真实构建通过 |
| 升级前 | 任务副本改造（PHP 包装、暂存目录、profile 副本）、切换与回滚脚本演练 | 改动逐项留证 |
| 切换日 上午 | 静默模式 → 队列 0 → 停旧服务 → 停机补同步（含凭据与主密钥）→ 启新控制器 → 起 Agent | 旧 HOME 原样保留 |
| 切换日 下午 | 36 个镜像交付任务分批真实构建并推送私仓 | 33 成功 / 3 失败（均为仓库自身问题） |
| 切换日 傍晚 | 收尾复查 + 全量 ThinBackup | 发现并修复全局 JDK 未落盘（pitfalls A1） |

## 4. 遇到的问题

### 4.1 ProtectHome 挡住 rootless Docker socket
- 阶段：改造
- 现象：合成任务拿到正确 JDK，但 `docker info` 报权限错误。
- 原因：systemd `ProtectHome` 同时覆盖了运行时 socket 所在的用户目录。
- 处理：不用 ProtectHome，改 `InaccessiblePaths=` 显式屏蔽旧家目录和控制器数据目录。四路构建复测通过。
- 状态：promoted → `references/pitfalls.md` B1。

### 4.2 NodeJS 插件安装报 AccessDenied
- 阶段：验收
- 现象：任务首次用到 NodeJS 工具时报 AccessDenied。
- 原因：插件要在 agent remoteFS 的 `tools/` 下建自己的目录，而 `tools/` 属 root、只读。
- 处理：只建这一层子目录并交给发布账号；从控制器同名缓存复制旧版本（连同 `.installedFrom` 等标记文件，否则会重新下载）；`tools/` 保持只读。
- 状态：promoted → `references/pitfalls.md` B2。

### 4.3 构建日志 PATH 开头出现旧 Oracle JDK
- 阶段：验收
- 现象：Agent 明明用新 JDK 启动，构建日志里 PATH 开头却是旧 JDK 的 `bin`。
- 原因：全局 JDK 工具仍指向旧安装目录，构建封装把它的 `bin` 加到 PATH 前面。
- 处理：用脚本控制台把全局 JDK 工具改到 Temurin 8；复测 `java -version` 为 1.8.0_512。**收尾复查发现这次修改只写进了内存，`config.xml` 还是旧路径**（见 4.4）。
- 状态：promoted → `references/pitfalls.md` A2/A1。

### 4.4 脚本控制台改的全局 JDK 只在内存里
- 阶段：收尾
- 现象：界面和构建都显示新 JDK，但主 `config.xml` 和随后的备份里还是旧路径；一旦重启就会恢复。
- 原因：`JDK.DescriptorImpl.setInstallations()` 只改内存，`descriptor.save()` 写的是无关的 `hudson.model.JDK.xml`；JDK 列表存放在主 `config.xml`，要由 `Jenkins.get().save()` 写盘。
- 处理：比较内存配置和磁盘 config.xml，确认只有 JDK 一项差异后备份、`Jenkins.get().save()`，再从磁盘读回复核；随后手动全量 ThinBackup 并确认其中已是 Temurin 8。
- 预防：沉淀为 `scripts/groovy/set-global-jdk.groovy`（保存后从磁盘读回复核）。
- 状态：promoted → `references/pitfalls.md` A1。

### 4.5 整点前后推送失败（私仓 GC）
- 阶段：验收
- 现象：整点前后几分钟的推送报 `denied`/`read-only`，过后重跑就好。
- 原因：私仓每小时整点 GC，GC 期间只读；旧环境原本就有此现象。
- 处理：批量调度避开 :50–:03（`scripts/groovy/trigger-batch.groovy` 有时间窗口参数）；这类失败直接重跑，不要当成认证问题去改凭据。3 个任务重跑成功。
- 状态：promoted → `references/pitfalls.md` C1。

### 4.6 Docker 29 BuildKit 拉 FROM 基础镜像 x509 失败
- 阶段：验收
- 现象：`docker pull/push` 正常，`docker build` 在 `load metadata` 阶段报 `failed to fetch oauth token ... x509: certificate ... doesn't contain any IP SANs`，只发生在本地还没有的基础镜像上。
- 原因：Docker 29 新装默认 containerd 镜像存储，BuildKit 获取令牌时不按 `insecure-registries` 例外处理（moby/moby#51080，未修复）。
- 处理：扫描在用任务的 FROM，列出发布账号本地缺少的 6 个私仓基础镜像，由守护进程逐个预拉并记录；4 个受影响任务复测成功。沉淀为 `scripts/find-missing-base-images.sh`。
- 状态：promoted → `references/pitfalls.md` C2/C3。

### 4.7 构建缓存撑满数据盘
- 阶段：验收
- 现象：批量验收后数据盘剩余空间跌到 9G；构建缓存约 26G。
- 坑：`docker builder prune --filter until=72h` 按"最近使用时间"判断，批量构建刚用过的缓存一个都不会删。
- 处理：经业务方同意删除测试镜像后，`docker builder prune -f --keep-storage 8GB`，剩余回到 19G。每批构建后看 `df` 和 `docker system df`。
- 状态：promoted → `references/pitfalls.md` C4。

### 4.8 三个失败任务都是仓库自身问题（旧环境同样失败）
- 阶段：验收
- 现象：36 个镜像交付任务 33 个真实构建推送成功；3 个失败，均为升级前就存在的问题。
- 原因与处理（交业务方，不擅自改仓库）：
  - 一个前端项目 `package.json` 声明 `diagram-js ^15`，锁文件里只有 7.x，每次构建重新解析，上游新版要求 Node ≥ 20.12，任务用的 Node 16。可选：提交匹配锁文件 / 固定版本 / 换 Node 20。
  - 一个任务的分支在 2025-01 被改成远端不存在的名字，此后一直没有构建；上次成功用的是另一个分支。
  - 一个任务从未成功过：pnpm 7 格式锁文件遇到工具自带 pnpm 8 的冻结安装直接失败。
- 状态：promoted → `references/pitfalls.md` D3/D4。

### 4.9 迁移后的"幽灵目录"：误改旧 JENKINS_HOME 毫无效果
- 阶段：运维（切换后）
- 现象：切换后想改一个任务的配置，直接去改宿主机上的旧 JENKINS_HOME（如 `/root/.jenkins`）里的 `config.xml`，改完毫无效果， Jenkins 行为不变。
- 原因：容器化控制器的真实 JENKINS_HOME 挂在数据盘目录（由 compose 的 volumes 定义），旧目录只是留在宿主机上没人读取的"幽灵目录"——它看起来结构齐全（jobs/、config.xml 都在），极具迷惑性。
- 处理：**改任务前先 `docker inspect <控制器容器> --format '{{json .Mounts}}'` 确认真实 JENKINS_HOME 挂载**，只改真实挂载点下的文件；旧目录应尽快改名（如 `*.ghost-<日期>`）或归档，避免再被误改。
- 预防：已加入 `scripts/survey-jenkins.sh`（检测多个疑似 JENKINS_HOME 时发 HIGH）。
- 状态：promoted → `references/pitfalls.md` G1。

### 4.10 判断活跃构建不能只看 build.xml
- 阶段：运维（切换后）
- 现象：想重启控制器前检查"有没有还在跑的构建"，按 `builds/<n>/build.xml` 是否存在来判断，以为没有活跃构建，重启时发现还有任务在跑（或反之，把正在跑的当成没跑）。
- 原因：构建目录在构建开始时就创建，但 `build.xml` 要到构建**结束**才写盘；被杀掉的构建则永远没有 `build.xml`。所以"有 build.xml"不等于已完成、"没有 build.xml"不等于没在跑。
- 处理：**按目录 mtime 判断活跃构建**：`find jobs -maxdepth 3 -type d -name builds -newermt '-10 minutes'`，10 分钟内变动的视为可能活跃；再结合 API 的 `executors`/队列字段确认。
- 状态：promoted → `references/pitfalls.md` G2。

### 4.11 批量 sed 任务 config.xml 后必须重启控制器
- 阶段：运维（切换后）
- 现象：批量 `sed` 修改磁盘上的任务 `config.xml` 后，界面和构建行为没有任何变化。
- 原因：控制器把任务配置缓存在内存里，磁盘文件改了不会自动重读。
- 处理：**批量 sed 后必须重启控制器（或对涉及任务执行 reload/job）才生效**。重启前先确认无活跃构建（按 4.10 的 mtime 口径）；**队列会跨重启保留**，排着的任务会在重启后继续执行，所以重启时机也要避开批量调度窗口。
- 状态：promoted → `references/pitfalls.md` G3。

## 5. 结果对比

| 检查项 | 升级前 | 升级后 |
|---|---|---|
| 核心版本 | 2.275 | 2.580.2 LTS |
| 运行 Java | Oracle Java 8 | Temurin 25.0.5（控制器）/ Java 21（Remoting） |
| 部署方式 | 宿主机直接运行 | 容器化控制器（compose，JENKINS_HOME 在数据盘），重启策略 always |
| 构建位置 | 旧账号宿主机构建 | 独立账号发布 Agent（4 执行器）+ rootless Docker；线上容器仍由系统 Docker 承载 |
| 业务编译 JDK | 旧 Oracle JDK 8 | Temurin 8u512（全局 JDK 工具，已确认 `config.xml` 落盘） |
| 插件 | 旧版本，多个有安全警告 | 121 个，无安全警告、无更新；3 个弃用仅提示 |
| 备份 | 无自动全量 | ThinBackup：周日 3 点全量、其余日增量、保留 4 轮 |

切换后首轮验收（36 个镜像交付任务，默认参数真实构建并推送私仓，以推送回执的 manifest 摘要为准、抽样用仓库 HEAD 复核）：

| 分组 | 数量 | 成功 | 说明 |
|---|---|---|---|
| 两地客户侧镜像任务 | 6 | 6 | 3 个第一次撞上整点 GC，重跑成功 |
| K8s 镜像任务（部署调用已注释，按镜像交付验收） | 30 | 27 | 失败 3 个均为仓库自身问题（4.8） |

切换后 43 次构建：33 成功、10 失败，其中 7 个重跑成功，剩 3 个即上表仓库自身问题。安全复查：核心与 121 个插件在更新站点数据中无安全警告；核心升级提示指向的 2.591 是每周版，继续留在 LTS。

## 6. 技能脚本的不足

- 迁移时的任务依赖扫描是临时 Python/awk 脚本，本次已沉淀为 `scripts/scan-job-commands.py`，但它不解析 rsyncd 模块配置与目标机脚本内容（后者靠手工核对）。
- "以发布 Agent 身份执行命令"当时靠手工 nsenter 命令串，已沉淀为 `scripts/run-as-agent.sh`，但未覆盖 machinectl 路径。
- 批量触发/轮询当时经浏览器 `/scriptText` 逐段粘贴，已沉淀为 `scripts/groovy/trigger-batch.groovy`、`poll-results.groovy`；"任务没有任何构建时 lastBuild 为 null"已判空，但仍需要人来判断首条错误的归属。
- 活跃构建判断（4.10）当时没有脚本支持，`scripts/survey-jenkins.sh` 现在只报告 builds 目录 mtime，切换前的"队列排空等待"逻辑在 `assets/cutover.sh.tmpl` 里，还未在真实切换中跑过。

## 7. 遗留事项

- 会写生产环境的任务（PHP/Composer、rsync 拉取、对象存储上传、SSH 到目标机的 Compose 发布）待业务方给窗口，每类先做一个真实发布。
- 一组节日活动任务和一个 Git 仓库不可见的任务待业务方确认去留。
- 3 个仓库自身问题（依赖漂移 / 分支不存在 / pnpm 锁文件格式）交业务方处理。
- 3 个弃用插件（bootstrap4-api、workflow-cps-global-lib、popper-api）仅提示，暂不处理。
- 幽灵目录建议尽快改名归档（4.9）；回滚窗口结束后释放旧 HOME 与切换前快照（向用户确认后）。
