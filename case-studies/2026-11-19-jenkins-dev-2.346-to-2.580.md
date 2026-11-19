---
date: 2026-11-19
cloud: aliyun
profile: "开发环境 war Jenkins，367 个任务全部在宿主机 root 构建，靠 GitLab webhook 触发"
source_version: "Jenkins 2.346.1 / Oracle JDK 1.8.0_92（war + systemd）"
target_version: "Jenkins 2.580.2 LTS / Temurin 25.0.5 控制器 / Temurin 8u512 业务编译"
result: success
duration_hours: 5
skill_version: 0.1.0
operator: agent+human
---

# 开发环境 Jenkins 2.346.1 → 2.580.2（war 换 Docker Compose 控制器）

## 1. 机器画像（脱敏）

- 阿里云 server08，CentOS 7，构建全部在 Jenkins 进程内以 root 执行；入口经 nginx 反代 `https://ci.example.com/`。
- 磁盘：`/` 分区 40G（旧 JENKINS_HOME `/var/lib/jenkins` 就在上面，其中 workspace 约 38G）；数据盘 `/data` 剩余约 39G，升级后使用率 84%。
- 旧服务：systemd `jenkins.service` + `java -jar jenkins.war`（Oracle JDK 8u92，`--httpPort=8888`）。
- 任务：367 个——362 自由风格、3 个 Maven 类型（2022 年后未构建）、2 个 Pipeline；无定时/轮询，靠 GitLab webhook（121 个 GitLabPushTrigger）和手工触发。
- 构建依赖宿主机：ssh/scp、docker、rsync、npm/pnpm/yarn、Maven 3.6.3、PHP CLI、composer、`/root/script/` 下的脚本；320 个任务 `source /etc/profile`；180 个任务写死 `/var/lib/jenkins/workspace/<job>`。
- 全局 JDK 工具指向旧 Oracle JDK 8u92；`/etc/profile` 与 alternatives 指向 8u271。
- 凭据：除 Jenkins 凭据库外，root 的 `~/.docker/config.json`（私仓 `registry.example.com` 登录项）、`~/.ssh`、known_hosts 都被构建使用。
- survey 的 BLOCKER / HIGH 摘要：无 BLOCKER；HIGH——320 个任务 source `/etc/profile`（profile 会改写 JAVA_HOME）、3 个 Maven 项目类型（受控制器 Java 约束）、180 个任务写死 workspace 路径、插件 133 个且 10 个已下架（更新站点 404，长期无法更新）。

## 2. 与业务方确认的决定

- 停服窗口约 5 分钟，业务方可接受；切换会让所有人登出，需要登录的验证提前完成。
- 编译 JDK 从 Oracle 8u271 换成 Temurin 8u512（唯一有意的行为变化）：切换前用两个 JDK 各打一次包，jar 文件清单一致、class 主版本都是 52。
- 44 个插件移除：已下架的、SVN 全家、未使用的 github/gitlab-oauth/ldap/sshd 等，清单固定为 2.580.2 更新中心的版本。
- 84 个长期失败的 GitLab webhook（升级前 30 天全部 internal error）统一改为可达入口，属于修复而非行为变更。
- 数据搬到 `/data/jenkins/home` 并 bind mount 回 `/var/lib/jenkins`，写死路径的脚本照常可用。

## 3. 时间线

| 时间 | 步骤 | 结果 / 备注 |
|---|---|---|
| 升级前 | 勘察（survey + 任务扫描）、插件清单解析、切换/回滚脚本编写 | 风险全部分级，无 BLOCKER |
| 升级前 | 数据副本演练：127.0.0.1:18888、0 执行器、收不到 webhook，`-jdk25` 镜像 | 111 个插件全部加载、无 SEVERE |
| 升级前 | 切换前对比构建（8u271 vs 8u512）、回滚脚本演练 | jar 清单一致、class 52 |
| 13:31 | 静默模式 → 队列排空 → 停旧服务 → 最后一次 rsync → 启容器控制器 → 起 agent | **停服约 2 分 40 秒** |
| 13:31–14:00 | 6 类代表任务验证 | 全部 SUCCESS（见第 5 节） |
| 13:58 | GitLab webhook 地址统一修复 | 75 个返回 200，10 个 404（Jenkins 无对应任务，升级前即如此） |
| 14:06 | 运行 Java 21 → 25 | 停服 14 秒；Java 21 支持期提示消失 |

## 4. 遇到的问题

### 4.1 webhook 地址升级前就长期失败
- 阶段：改造/收尾
- 现象：GitLab 近 30 天 42 次 hook 调用全部 internal error；hook 地址是 `http://域名:8888/...`，域名解析到公网，公网 8888 不通。
- 原因：hook 地址使用了公网不可达的端口，与升级无关、升级前就一直失败。
- 处理：84 个 hook 统一改为 `https://ci.example.com/project/<任务名>`（走 nginx）。GitLab 改地址会清空 hook 的 token——改前导出备份，改完恢复 7 个 token。用"删除分支"类型的 push 事件验证（插件按设计忽略，不触发构建）。
- 预防：勘察时把"Git 平台 hook 最近调用结果"列入检查项（已在 playbook.md 阶段 1）。
- 状态：promoted → `references/pitfalls.md` E1。

### 4.2 旧更新站点 404，插件四年没更新
- 阶段：勘察/设计
- 现象：更新站点（镜像站）404，133 个插件里 10 个已下架、多个有未修复漏洞。
- 原因：镜像站早已失效。
- 处理：更新站点改为 `https://updates.jenkins.io/update-center.json`；插件清单用 jenkins-plugin-manager 按 2.580.2 解析，演练环境确认 0 加载失败后整体替换插件目录。
- 状态：promoted → `references/pitfalls.md` A6/E3。

### 4.3 compose 启动保护
- 阶段：设计
- 现象：如果 `/data` 没挂载就启动容器，会初始化出一个空 Jenkins，覆盖真实数据。
- 处理：compose entrypoint 先检查 `config.xml` 存在，不存在拒绝启动（已进 `assets/compose-controller.yaml.tmpl`）。
- 状态：promoted → `references/pitfalls.md` E3。

### 4.4 Java 21 支持期提示
- 阶段：切换
- 现象：2.580.2 上提示 "Java 21 end of life"。
- 原因：Java 21 官方支持到 2027-09，Java 25 到 2029-09。
- 处理：镜像换 `-jdk25` 标签，agent 换从同一镜像拷出的 JDK；先在数据副本演练再切换，停服 14 秒。
- 状态：promoted → `references/pitfalls.md` A5 / `references/version-matrix.md`。

### 4.5 反向代理设置有误提示
- 阶段：收尾
- 现象：管理页面提示反向代理设置有误。
- 处理：nginx 补 `proxy_set_header X-Forwarded-Proto $scheme;` 和 `X-Forwarded-Port $server_port;`（改前备份）。
- 状态：promoted → `references/pitfalls.md` E2。

### 4.6 Git 主机密钥校验、thinBackup、旧缓解脚本
- 阶段：收尾
- 现象：新版默认密钥校验更严格；thinBackup 配置文件被新插件改名；为旧 CLI 漏洞写的 init 缓解脚本残留。
- 处理：Git 主机密钥校验改为"手动提供的密钥"（GitLab 容器真实公钥），同时更新宿主机 known_hosts 里过期条目（备份）；thinBackup 配置改名为 `org.jvnet.hudson.plugins.thinBackup.ThinBackupPluginImpl.xml`，核对备份路径 `/data/jenkins/backup/thinbackup/`；旧缓解脚本停用（改名为 `*.disabled-after-2.580`，先读过内容再停）。
- 状态：promoted → `references/pitfalls.md` E3。

## 5. 结果对比

| 检查项 | 升级前 | 升级后 |
|---|---|---|
| 核心版本 | 2.346.1（2022-06，几十个已知 CVE） | 2.580.2 LTS |
| 运行 Java | Oracle 1.8.0_92 | Temurin 25.0.5（14:06 由 21 换到 25） |
| 部署方式 | systemd + `java -jar jenkins.war` | `/data/jenkins/docker-compose.yml`，容器名 `jenkins` |
| 构建位置 | 控制器进程内（root） | 宿主机 agent `server08-host`（systemd `jenkins-agent.service`，WebSocket，4 执行器）；内置节点 0 执行器 |
| 业务编译 JDK | Oracle 8u271 | Temurin 8u512-b09（`/etc/profile`、alternatives、全局工具三处） |
| 插件 | 133 个，10 个已下架 | 111 个，0 个加载失败 |
| 数据位置 | `/var/lib/jenkins`（/ 分区 40G） | `/data/jenkins/home`，bind mount 回 `/var/lib/jenkins` |
| webhook | 84 个 hook 全部失败 | 75 个 200，10 个 404（Jenkins 无对应任务） |

6 类代表任务全部 SUCCESS（任务名按模式脱敏）：

| 类型 | 模式 | 构建号 | 检查点 |
|---|---|---|---|
| Java K8s | Java + mvn + docker push + kubectl apply | #2168 | 打包、推送、apply 成功 |
| Java Docker | Java + docker build/push | #33 | jar Build-Jdk 1.8.0_512，class 主版本 52 |
| PHP Docker | PHP + composer + docker | #519 | 镜像构建与发布成功 |
| PHP 传统 | PHP + rsync/ssh | #4155 | composer/rsync/ssh 发布成功 |
| H5 K8s | NodeJS 工具 + docker | #127 | NodeJS 工具未重新下载，构建发布成功 |
| H5 传统 | NodeJS + rsync | #114 | 构建发布成功 |

其他：367 个任务全部加载；agent 上 `java -version` 为 1.8.0_512（Temurin）；Temurin 8 访问 `https://nexus.example.com` TLS 正常。

## 6. 技能脚本的不足

- 当时 survey/切换/回滚都是一次性脚本，没有沉淀成技能模板（本次已补 `scripts/survey-jenkins.sh`、`assets/cutover.sh.tmpl`、`assets/rollback.sh.tmpl`）。
- webhook 的批量修改、token 备份恢复依赖 GitLab 侧 API 手工操作，技能里只有 checklist，没有脚本。
- 插件清单解析依赖 jenkins-plugin-manager（Java 11+ 运行时），在 CentOS 7 宿主机上要单独准备运行环境。

## 7. 遗留事项

- 回滚窗口（一周）结束后释放旧 HOME `/var/lib/jenkins.pre-upgrade-<日期>`（40G）、旧版本格式的 15 份全量备份（3.1G）。
- 3 个 Maven 类型任务（2022 年后未构建）：以后要用时改成自由风格 Shell 调 `mvn`。
- 10 个返回 404 的 webhook：GitLab 里删除或补建对应任务。
- 后续加固（独立变更）：矩阵权限替代"登录后完全控制"；控制器改非 root；CSP 先开"仅报告"模式；清理 38G workspace 与缓存；"管理旧数据"里约 366 条空属性稳定一周后丢弃。
