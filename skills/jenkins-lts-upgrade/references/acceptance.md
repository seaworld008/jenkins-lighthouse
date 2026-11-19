# 逐任务验收

目标：每个在用任务都有一条可以复查的证据，失败的有明确的归属。

## 1. 分类

按发布方式分类，而不是按项目名：

| 类别 | 例子 | 是否写生产 |
|---|---|---|
| 只推镜像 | 构建镜像推到私仓，由别人按 tag 发布 | 否（只写仓库） |
| Kubernetes | 推镜像后 `kubectl set image` / `rollout` | 是 |
| Docker Compose | SSH 到目标机 `docker compose pull && up -d` | 是 |
| rsync / 传统部署 | 产物放到 rsync 模块，目标机拉取；或 scp 后执行脚本 | 是 |
| PHP / Composer | 生成 vendor 后同步 | 是 |
| 对象存储 | 静态资源上传 | 是 |

写生产的类别，**每类先做一个真实发布，由业务方给窗口并确认**，再批量。

## 2. 顺序

1. 合成任务：Freestyle 和 Pipeline 各一个，输出 `which java; java -version; mvn -version; node -v; docker info`。
2. 每个类别一个代表性真实任务。
3. 分批：每批 4–8 个；避开私仓 GC 时段；每批后看 `df`、`docker system df`。
4. 失败的先分类，再决定修环境还是交业务方。

## 3. 证据口径

| 类型 | 证据 |
|---|---|
| 通用 | 构建号、结果、耗时、触发人、参数 |
| Java | `Build-Jdk`（MANIFEST）、class 主版本 52、`mvn -version` 输出 |
| 镜像 | 推送回执中的 `digest: sha256:...`，抽样用仓库 API 的 HEAD 请求复核 |
| K8s | 期望副本数就绪、观察到新修订 |
| Compose | 目标机容器运行数、镜像 ID |
| rsync | 目标机拉取后的 SHA-256 比对 |

`scripts/groovy/poll-results.groovy` 会输出构建号、结果、耗时、`JENKINS_IMAGE_TAG=` 行、推送摘要和第一条错误行。

## 4. 失败分类

| 类别 | 判断方法 | 处理 |
|---|---|---|
| 环境问题 | 合成任务也失败；或错误指向工具路径、权限、证书、PATH | 马上修，复测 |
| 时段问题 | 只在私仓 GC 等时段失败 | 过后重跑 |
| 旧问题 | 升级前最后几次构建也失败；或从未成功 | 记录证据，交业务方 |
| 依赖漂移 | 锁文件与声明不一致、分支不存在、上游新版本要求更高运行时 | 记录证据，交业务方，不擅自改仓库 |

## 5. 记录表

用 `assets/acceptance-table.md`。每行一个任务：类别、构建号、结果、证据、失败归属、跟进人。
