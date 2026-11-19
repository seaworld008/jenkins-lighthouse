# 踩坑清单

格式：现象 → 原因 → 处理。来源标注：`[生产]` 生产环境 2.275 → 2.580.2，`[开发]` 开发环境 2.346.1 → 2.580.2（见 `../../../case-studies/`）。新坑请按同样格式追加，并在 PR 里写明验证程度。

## A. 配置与 Java

### A1. 脚本控制台改全局 JDK，重启后恢复旧路径 `[生产]`
- 现象：界面和构建都显示新 JDK，但 `config.xml` 和随后的备份里还是旧路径。
- 原因：`JDK.DescriptorImpl.setInstallations()` 只改内存；`descriptor.save()` 写的是无关的 `hudson.model.JDK.xml`。JDK 列表存放在主 `config.xml`，要由 `Jenkins.get().save()` 写盘。
- 处理：`scripts/groovy/set-global-jdk.groovy`：先比较内存与磁盘，只有预期差异时才备份并保存，再读回磁盘文件确认。**脚本控制台改的任何全局配置都要看一眼磁盘**，最好再看一眼随后的备份。

### A2. 全局 JDK 工具指向旧 Oracle JDK，出现在所有任务的 PATH 里 `[生产][开发]`
- 现象：agent 明明用新 JDK 启动，构建日志里 PATH 开头却是旧 JDK 的 `bin`。
- 原因：任务选了全局 JDK 工具时，构建封装会把它的 `bin` 加到 PATH 前面。
- 处理：把全局工��改到新的 JDK 8（见 A1），在 agent 上用合成任务输出 `which java; java -version` 验证。

### A3. `source /etc/profile` 把 Maven 切回旧 JDK `[生产]`
- 现象：直接 `java -version` 是新 JDK；任务 `source /etc/profile` 后 `mvn -version` 显示旧 JDK。
- 原因：系统配置重设了 JAVA_HOME，Maven 优先使用 JAVA_HOME。
- 处理：修改 `/etc/profile`，或者给 agent 的 systemd unit 用 `BindReadOnlyPaths=` 绑定一份调整过的副本。用 `scripts/run-as-agent.sh` 按任务的方式 `source /etc/profile` 后看 `mvn -version`。

### A4. Maven 项目类型受控制器 Java 约束 `[生产][开发]`
- 原因：Maven Integration 插件要求构建 JDK 不低于控制器 Java。
- 处理：需要 JDK 8 的，改成自由风格 Shell 调 `mvn`。长期不用的 Maven 任务先记录，用时再改。`scripts/scan-job-commands.py` 会列出这类任务。

### A5. 运行 Java 的支持期 `[开发]`
- Java 21 计划支持到 2027-09，Java 25 到 2029-09。镜像换成 `-jdk25` 标签、agent 换同一镜像拷出的 JDK 即可，停服十几秒。见 `version-matrix.md`。

### A6. 插件目录混用新旧版本
- 现象：新核心启动后大量插件加载失败、`SEVERE`，或配置页面空白。
- 原因：旧插件没跟上 Jakarta EE 9 等核心变化。
- 处理：演练环境里把 `plugins/` 整体替换为目标版本更新中心解析出的清单；切换时同样整体替换，而不是在新核心上"逐个升级"。

## B. 发布 agent 与权限 `[生产]`

### B1. systemd `ProtectHome` 挡住 rootless Docker 的 socket
- 现象：合成任务拿到正确的 JDK，但 `docker info` 报权限错误。
- 处理：不用 `ProtectHome`，改为 `InaccessiblePaths=` 显式屏蔽旧家目录和控制器数据目录。

### B2. NodeJS 插件安装报 AccessDenied
- 原因：插件要在 agent remoteFS 的 `tools/` 下建 `jenkins.plugins.nodejs.tools.NodeJSInstallation/`，而 `tools/` 属 root、只读。
- 处理：只建这一层子目录并交给发布账号；从控制器同名缓存复制旧版本（连同 `.installedFrom` 等标记文件，否则会重新下载），`tools/` 保持只读。

### B3. 独立账号执行 Git 报 `detected dubious ownership`
- 处理：为核实过的旧工作区逐个登记 `safe.directory`（精确路径，不用 `*`），排除符号链接和他人可写目录。

### B4. 旧工作区归 root，新账号无法写
- 处理：先在隔离目录验证 ACL 授权和恢复方法，切换窗口内、构建停稳后再处理生产工作区。

### B5. Jenkins 凭据库之外还有凭据
- 运行账号的 `~/.docker/config.json`、`~/.ssh/`、`known_hosts` 也是构建依赖的凭据。按旧任务实际推送/连接过的范围，给新账号补入，权限 0600。

## C. 镜像仓库与 Docker

### C1. 私仓定时 GC 期间只读，推送失败 `[生产]`
- 现象：整点前后几分钟的推送报 `denied` 或 `read-only`，过后重跑就好。
- 处理：批量调度避开 GC 时段（`scripts/groovy/trigger-batch.groovy` 有时间窗口参数）。这类失败直接重跑，不要当成认证问题去改凭据。

### C2. Docker 29 的 BuildKit 拉 FROM 基础镜像时 x509 失败 `[生产]`
- 现象：`docker pull/push` 正常，`docker build` 在 `load metadata` 阶段报 `failed to fetch oauth token ... x509: certificate ... doesn't contain any IP SANs`，只发生在本地还没有的基础镜像上。
- 原因：Docker 29 新装默认使用 containerd 镜像存储（`docker info` 的存储驱动显示 overlayfs），BuildKit 获取令牌时不按 `insecure-registries` 例外处理。上游 [moby/moby#51080](https://github.com/moby/moby/issues/51080)。
- 处理：`scripts/find-missing-base-images.sh` 列出在用任务需要、本地缺少的私仓基础镜像，逐个 `docker pull`。基础镜像标签更新后要重新拉。长期方案：给仓库证书加上正确的 SAN，或改用域名。

### C3. 宿主机能拉，rootless 账号报证书问题 `[生产]`
- 原因：两个独立的 Docker 守护进程，配置和登录信息各自独立。
- 处理：只对发布账号的守护进程配置必要的例外；用专用测试标签推送、删本地、拉回比对摘要。

### C4. 构建缓存撑满数据盘 `[生产]`
- 现象：批量验收后数据盘剩余空间快速下降，构建缓存几十 G。
- 坑：`docker builder prune --filter until=72h` 按"最近使用时间"判断，批量构建刚用过的缓存一个都不会删。
- 处理：`docker builder prune -f --keep-storage 8GB`。推送失败的构建会留下本地镜像（后面的 `rmi` 没执行），也要清掉。每批构建后看 `df` 和 `docker system df`。

## D. 任务脚本与依赖 `[生产]`

### D1. 远端调用已注释，回滚分支还在连失联节点
- 处理：读脚本实际生效的路径，把"只推镜像"的任务明确成镜像交付，推送成功后输出完整镜像引用。

### D2. 发布脚本在产物缺失时会进入写操作
- 处理：目标端脚本增加只读检查模式；动目标目录前核对产物完整性，异常就退出。

### D3. 前端依赖漂移
- `package.json` 的范围与锁文件不一致，每次构建重新解析，上游新版要求更高的 Node → 失败。
- pnpm 7 格式的锁文件遇到 pnpm 8 的冻结安装直接失败。
- 旧锁文件指向证书已过期的 npm 镜像；原生扩展（如 node-sass）绑定特定 ABI。
- 这些是仓库本身的问题，旧环境下同样会失败。记录证据交给业务方，不擅自改代码仓库。

### D4. 任务配置的分支在远端不存在
- 用 `git ls-remote --heads` 或 `git branch -r` 核对，交业务方确认。看"上次成功"用的是哪个分支。

### D5. Maven 共享父 POM 未展开
- 处理：在既有制品库里找到固定版本的发布 POM 和 JAR，按校验值验证后放入独立的 Maven 缓存。

## E. 入口、Webhook、备份 `[开发]`

### E1. Webhook 长期全部失败
- 原因：hook 地址用了公网不通的端口。
- 处理：统一改成可达入口，例如 `https://ci.example.com/project/<任务名>`。**GitLab 修改 hook 地址会清空 secret token：事先导出备份，改完恢复。** 用"删除分支"类型的推送事件验证（插件会忽略，不触发构建）。返回 404 的通常是 Jenkins 里已经没有的任务。

### E2. "反向代理设置有误"提示
- nginx 补 `proxy_set_header X-Forwarded-Proto $scheme;` 和 `proxy_set_header X-Forwarded-Port $server_port;`。

### E3. 其他
- 旧更新站点镜像 404：改为 `https://updates.jenkins.io/update-center.json`。
- ThinBackup 新版会把配置文件改名为 `org.jvnet.hudson.plugins.thinbackup.ThinBackupPluginImpl.xml`，切换后核对备份路径和计划。
- Git 主机密钥校验策略在新版默认更严格：改为"手动提供的密钥"或 known_hosts，并更新宿主机过期的 known_hosts。
- 为旧漏洞写的缓解 init 脚本在新版不再需要，停用前先读一遍内容。
- 重启后所有会话失效，需要人登录的验证提前约好。

## F. 工具与操作习惯

- 从 Windows/PowerShell 远程执行多行命令时，`$`、引号会被改写：写成脚本文件上传再执行。
- 通过浏览器自动化调用 `/scriptText` 时单次调用可能有超时（实测约 90 秒），等待构建的循环控制在 60 秒内，分多次轮询。
- 轮询结果时任务可能还没有任何构建（`lastBuild == null`），脚本要判空。
- `du` 扫整个 workspace 很慢，会拖到命令超时；看磁盘先用 `df` 和 `docker system df`。

## G. 升级后的日常运维 `[生产]`

容器化迁移完成后，宿主机上还留着旧 JENKINS_HOME、控制器把配置缓存在内存里——这几条坑都在切换后真实发生过。

### G1. 旧 JENKINS_HOME 变成"幽灵目录"，误改它毫无效果 `[生产]`
- 现象：切换后去改宿主机上的旧目录（如 `/root/.jenkins`）里的 `jobs/*/config.xml`，改完 Jenkins 行为毫无变化；目录结构看起来完全正常，极具迷惑性。
- 原因：容器化控制器的真实 JENKINS_HOME 挂在数据盘目录上（compose 的 volumes 定义），旧目录只是留在宿主机上、没有任何进程读取的副本。
- 处理：**改任务前先 `docker inspect <控制器容器> --format '{{json .Mounts}}'` 确认真实 JENKINS_HOME 挂载**，只改真实挂载点下的文件。旧目录尽快改名（如 `*.ghost-<日期>`）或归档，避免再被误改。`scripts/survey-jenkins.sh` 会提示机器上存在多个疑似 JENKINS_HOME。

### G2. 判断活跃构建不能只看 `builds/<n>/` 有没有 `build.xml` `[生产]`
- 现象：重启控制器前按 `build.xml` 是否存在判断"有没有在跑的构建"，得出错误结论（把在跑的当成没跑，或把被杀掉的当成在跑）。
- 原因：构建目录在开始时就创建，但 `build.xml` 要到构建**结束**才写盘；被杀掉的构建则永远没有 `build.xml`。
- 处理：**按目录 mtime 判断活跃**：`find jobs -maxdepth 3 -type d -name builds -newermt '-10 minutes'`，10 分钟内变动的视为可能活跃；再结合 API 的 `executors`/队列字段确认。`scripts/survey-jenkins.sh` 会报告这类目录。

### G3. 批量 sed 任务 `config.xml` 后必须重启控制器（或 reload）才生效 `[生产]`
- 现象：批量 `sed` 修改磁盘上的任务 `config.xml` 后，界面和构建行为没有任何变化。
- 原因：控制器把任务配置缓存在内存里，磁盘文件改了不会自动重读。
- 处理：**批量 sed 后重启控制器（或对涉及任务执行 reload）**。重启前先确认无活跃构建（按 G2 的 mtime 口径）；**队列会跨重启保留**——排着的任务重启后会继续执行，所以重启时机同样要避开批量调度和私仓 GC 时段。
