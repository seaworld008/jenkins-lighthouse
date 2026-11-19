# 分阶段检查清单

## 阶段 0：约定

- [ ] 维护窗口和可接受的停服时长（经验值：同机切换 2–5 分钟）。
- [ ] 回滚条件：哪些现象出现就回滚，谁拍板。
- [ ] 需要登录 Jenkins 的步骤（触发真实发布、管理页面确认）由谁在浏览器里完成。重启后所有会话都会失效。
- [ ] 哪些任务属于"会写生产环境"，需要业务方给发布窗口。

## 阶段 1：勘察（只读）

- [ ] 运行 `scripts/survey-jenkins.sh`，看末尾的 RISK FLAGS。
- [ ] 运行 `scripts/scan-job-commands.py <JENKINS_HOME>/jobs`，得到命令、路径、远端目标、镜像仓库的使用清单。
- [ ] 核心版本、运行 Java、启动方式（war / Tomcat / rpm / 容器）、JENKINS_HOME 位置和大小（workspace 往往占大头）。
- [ ] 插件：数量、已下架、有安全警告的。
- [ ] 任务：总数、启用和停用、类型（自由风格 / Maven / Pipeline / 多配置）、触发方式（webhook、定时、轮询、手工）。
- [ ] 全局工具：JDK、NodeJS、Maven 各指向哪里；目录是否还存在。
- [ ] 构建依赖：宿主机命令、`/etc/profile` 里的 JAVA_HOME 和 PATH、写死的绝对路径、`/root` 下的脚本。
- [ ] 凭据：Jenkins 凭据库、主密钥（`secrets/`），以及运行账号的 `~/.docker/config.json`、`~/.ssh/`、`known_hosts`。
- [ ] 镜像仓库：版本、证书是否包含访问用的名称或 IP、垃圾回收计划。
- [ ] 入口：反向代理、webhook 实际回调地址是否可达（看 GitLab 等平台的 hook 最近调用结果）。
- [ ] 磁盘：数据盘余量，预估副本、备份、构建缓存的增长。
- [ ] 阅读官方升级指南中跨过的每个 LTS 的说明（`references/version-matrix.md` 有摘要）。

## 阶段 2：设计

- [ ] 选择 agent 架构（`references/architecture.md`）。
- [ ] 运行 Java：控制器镜像标签（`-jdk25` 或 `-jdk21`），agent 用同一镜像拷出的 JDK 或独立安装的 JDK 21/25。
- [ ] 编译 JDK：选一个受支持的 JDK 8 发行版，先用旧 JDK 和新 JDK 各打一次包，比较 jar 文件清单和 class 主版本（52）。
- [ ] 插件清单：只保留在用的，全部固定为目标版本更新中心里的版本。war 不再自带的插件（如 jdk-tool、mailer、matrix-auth、bouncycastle-api 等）要显式列出。
- [ ] 数据位置：新目录 + bind mount 回原路径，可以让写死路径的脚本照常运行。
- [ ] 安全基线：内置节点 0 执行器；不挂 docker.sock；不开 50000 端口（用 WebSocket）；控制器内存上限和健康检查。

## 阶段 3：演练

- [ ] 复制 JENKINS_HOME（可不含 workspace 和构建记录），用不同端口、0 执行器、收不到 webhook 的方式启动目标版本。
- [ ] 插件全部加载，日志没有 SEVERE。
- [ ] 合成任务：Freestyle 和 Pipeline 分别输出 `java -version`、`mvn -version`、`node -v`、`docker info`。
- [ ] 代表性真实任务：Java（class 主版本 52）、前端（Node 版本与旧任务一致）、PHP（Composer）、各打一个镜像。
- [ ] 切换脚本和回滚脚本都实际跑一遍（`assets/cutover.sh.tmpl`、`assets/rollback.sh.tmpl`，替换占位符后）。

## 阶段 4：改造

- [ ] agent 的 systemd unit：绝对路径的 Java、与旧服务一致的环境变量、`KillMode=process`、secret 从文件读取（`-secret @文件`）。
- [ ] 独立发布账号：rootless Docker、目标受限的 SSH 身份、精确登记 `safe.directory`、工具目录权限（NodeJS 插件要能在工具根目录下建自己的目录）。
- [ ] `/etc/profile` 会改写 JAVA_HOME 时，给 agent 绑定一份调整过的只读副本。
- [ ] 全局 JDK 工具改到新 JDK 8，确认 `config.xml` 已落盘。
- [ ] 私仓基础镜像预拉到构建身份本地（Docker 29 BuildKit 问题，见 pitfalls C2）。

## 阶段 5：切换

- [ ] 旧控制器进入静默模式，确认队列和执行中都为 0。
- [ ] 停旧服务并取消开机启动；最后一次同步，确认差异为 0。
- [ ] 替换插件目录，调整配置（内置节点执行器、更新站点、备份路径）。
- [ ] 启动新控制器，等日志出现 `Jenkins is fully up and running`。
- [ ] 启动 agent，确认在线。
- [ ] 核对：版本、运行 Java、任务数、构建记录数、插件加载、凭据可用。
- [ ] 反向代理补 `X-Forwarded-Proto` / `X-Forwarded-Port`；webhook 回调地址改到可达入口。

## 阶段 6：验收

见 `references/acceptance.md`。

## 阶段 7：收尾

- [ ] 健康检查：控制器状态和重启次数、`/login` 返回 200、agent 在线、`systemctl --failed`、近两小时日志的 SEVERE。
- [ ] 手动做一次全量备份，并在备份里核对关键配置（JDK 路径、节点、凭据文件）。
- [ ] 安全：更新站点数据中核心和插件没有安全警告。
- [ ] 清理自己产生的临时镜像、构建缓存；别人的测试资源确认后再删。
- [ ] 写案例报告、补 pitfalls、列遗留事项。
- [ ] 回滚窗口（建议一周）结束后再释放旧 HOME 和旧备份。
