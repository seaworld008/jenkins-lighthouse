# 架构：控制器进容器，构建留在宿主机

## 为什么不把构建也放进容器

老 Jenkins 的任务大多是 Shell：依赖宿主机的 `mvn`、`node`、`docker`、`rsync`、`ssh`、`/etc/profile`、写死的绝对路径，还有运行账号家目录里的凭据。把这些搬进容器镜像，等于逐个任务重新验证；升级窗口里很难做到。

所以只把**控制器**放进官方镜像（版本可控、运行 Java 自带、回滚就是换回旧服务），构建通过一个**宿主机 agent** 执行，环境尽量和旧服务给构建的环境一致。

```
            ┌──────────────── 宿主机 ────────────────┐
 浏览器/    │  ┌──────────────┐  WebSocket   ┌──────┐ │
 webhook ──▶│  │ 控制器容器    │◀────────────│agent │ │
 (反代)     │  │ jenkins:LTS  │  127.0.0.1   │systemd│ │──▶ mvn / node / docker / rsync / ssh
            │  │ 0 个执行器    │              └──────┘ │
            │  └──────────────┘                        │
            │   JENKINS_HOME 在数据盘，bind mount       │
            └─────────────────────────────────────────┘
```

共同点：

- 内置节点 0 个执行器，所有构建都在 agent 上。
- agent 用 WebSocket 连接 `127.0.0.1` 上的控制器，不开 50000 端口。
- 控制器不挂 `docker.sock`。
- agent 用绝对路径的 Java 启动 Remoting，不设 JAVA_HOME，不把它放进 PATH；构建看到的 Java 由 `/etc/profile`、alternatives 和全局 JDK 工具决定。
- secret 用 `-secret @文件`，文件权限 0600，不写进 unit 文件或命令行。

## 方案 A：root、同环境（开发环境用）

agent 以 root 运行，环境变量照抄旧 `jenkins.service`，remoteFS 就是原来的 JENKINS_HOME，所以 workspace、NodeJS 工具缓存都不用重下。

适合：开发/测试环境、任务以 root 运行多年且没法逐个审计、想最快完成升级。

| 优点 | 代价 |
|---|---|
| 构建行为几乎不变，验收快 | 构建仍然是 root，可以动宿主机上的一切 |
| 不用 chown 几十 G 的 HOME，回滚简单 | 控制器也常常保留 root（`user: "0:0"`） |
| 工作区、工具缓存原地复用 | 安全加固要另起变更 |

模板：`assets/compose-controller.yaml.tmpl`、`assets/jenkins-agent.service.tmpl`（同一份 unit 模板，方案 A/B 的差异在文件注释里标出）。agent 节点在控制台 Manage Jenkins > Nodes 里新建（WebSocket，`-secret @文件`），不需要单独脚本。

## 方案 B：独立账号 + rootless Docker（生产环境用）

agent 以专用账号（例如 `jenkins-release`）运行，用该账号自己的 rootless Docker 构建和推送镜像；线上容器仍由系统 Docker 承载，构建碰不到它们。

适合：生产环境、要把"能发布"和"能管理宿主机"分开。

要处理的事比方案 A 多，但每一项都能提前在隔离目录验证：

| 事项 | 做法 |
|---|---|
| 沙箱 | systemd `InaccessiblePaths=` 屏蔽 `/root`、`/home`、控制器数据目录；不用 `ProtectHome`（会挡住 rootless Docker 的 socket，见 pitfalls B1） |
| `/etc/profile` | 用 `BindReadOnlyPaths=` 给 agent 换一份调整过 JDK/Maven 路径的副本 |
| 写死的共享路径 | `BindPaths=` 把独立暂存目录挂到原路径，脚本照旧写，宿主机原目录不受影响 |
| 凭据 | `LoadCredential=` 读取对象存储等配置；Docker 登录项、SSH 身份按旧任务实际用过的范围补给新账号（0600） |
| SSH | 目标受限的身份，逐个验证主机密钥 |
| Git | 精确登记 `safe.directory`，不用 `*` |
| 工作区 | 旧工作区归 root：先在隔离目录验证 ACL 授权和恢复，切换窗口再处理 |
| 工具目录 | NodeJS 插件要能在 `tools/` 下建自己的目录，只把那一层交给新账号 |
| 私仓 | 只对新账号的 Docker 守护进程配置必要的例外 |

模板：`assets/jenkins-agent.service.tmpl`（方案 B 段落在同一文件里，按注释启用）。

## 控制器的共同设置

- 镜像：`jenkins/jenkins:<LTS>-jdk25`（或 `-jdk21`）。生产可以先推到自己的私仓，固定标签，比对配置摘要。
- 监听：方案 A 用 host 网络；方案 B 只绑 `127.0.0.1`，由反向代理或 systemd socket 转发对外端口。
- 数据：JENKINS_HOME 放数据盘，必要时 bind mount 回旧路径，写死路径的脚本照常可用。
- 启动保护：`config.xml` 不存在就拒绝启动，防止数据盘没挂载时初始化出一个空 Jenkins。
- 资源：`-Xmx` 加容器内存上限；健康检查 `/login`；日志轮转。
- 加固：`cap_drop: [ALL]`、`no-new-privileges`、非 root 用户（方案 B）。

## 怎么选

- 不确定时先用方案 A 完成版本升级，加固作为独立变更再做。一次只改一类东西，出问题时容易定位。
- 生产环境已经有"发布账号"的诉求，或者构建不应该能动线上容器时，用方案 B。
