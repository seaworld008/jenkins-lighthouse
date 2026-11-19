# 版本与 Java

数据来自 Jenkins 官方 [Java Support Policy](https://www.jenkins.io/doc/book/platform-information/support-policy-java/) 和 [LTS Upgrade Guide](https://www.jenkins.io/doc/upgrade-guide/)，2026-11 核对。动手前请再看一次官方页面。

## 运行 Jenkins 所需的 Java

| Java | 最后支持它的 LTS | 说明 |
|---|---|---|
| Java 8 | 2.346.3 | 老 Jenkins 常见组合；2.361.1 起不能用 |
| Java 11 | 2.462.3 | |
| Java 17 | 2.541.3 | 2.555.1 起不能用 |
| Java 21 | 当前支持，计划到 2027-09 | |
| Java 25 | 当前支持（2.541.1 起），计划到 2029-09 | 新装优先选 |

这些要求适用于控制器、**所有 agent** 和 CLI 客户端。agent 的 Remoting 进程也要用 21 或 25。

**构建用的 JDK 与运行 Jenkins 的 Java 无关**：Shell 里调用的 `java`、`mvn` 可以继续是 JDK 8。例外是 Maven Integration 插件（Maven 项目类型）：它要求构建 JDK 不低于控制器的 Java，所以需要 JDK 8 的 Maven 项目要改成自由风格 Shell 调 `mvn`（pitfalls A4）。

## 跨版本要注意的变化（摘要）

跳过多个 LTS 时，官方建议把中间每个 LTS 的升级说明都读一遍。下面是老版本升级时最常碰到的：

| 跨过的版本 | 变化 | 对升级的影响 |
|---|---|---|
| 2.361.1 | 需要 Java 11 | Java 8 上的老 Jenkins 必须同时换运行 Java |
| 2.4xx | 多个插件从 war 中拆出（如 jdk-tool、mailer、matrix-auth、bouncycastle-api 等，以实际版本为准） | 插件清单要显式列出它们，否则相关配置加载失败 |
| 2.479.1 | 需要 Java 17；Jakarta EE 9 / Jetty 12 | 没跟上的旧插件无法加载：插件目录整体替换成目标版本更新中心的版本 |
| 2.555.1 | 需要 Java 21 | 镜像选 `-jdk21` 或 `-jdk25` |
| 一直在变 | 安全加固（CSP、脚本审批、CLI、密码存储等） | 读对应 LTS 的说明；在演练环境里看管理页面的提示 |

## 镜像标签

- `jenkins/jenkins:<版本>-lts-jdk25`、`jenkins/jenkins:<版本>-lts-jdk21`：控制器。
- agent 的 Java 可以直接从同一镜像拷出来（`docker cp <容器>:/opt/java/openjdk <目录>`），版本和控制器完全一致。

## 编译用的 JDK 8

- 选一个仍在维护的发行版，例如 Eclipse Temurin 8。
- 切换前用旧 JDK 和新 JDK 各打一次包，比较：jar 文件清单、`META-INF/MANIFEST.MF` 的 `Build-Jdk`、class 主版本（52 = Java 8）。
- 三处都要改：`/etc/profile`（或 agent 专用副本）、alternatives、全局 JDK 工具（会进 PATH，pitfalls A2）。

## 插件清单

- 只保留在用的插件，全部固定到目标版本更新中心里的版本。可以用 [jenkins-plugin-manager](https://github.com/jenkinsci/plugin-installation-manager-tool) 按目标核心版本解析依赖，在演练环境确认 0 个加载失败。
- 已下架或有未修复漏洞的插件，先在旧环境找替代方案。
- 更新站点用 `https://updates.jenkins.io/update-center.json`；旧镜像站地址可能已经失效。
