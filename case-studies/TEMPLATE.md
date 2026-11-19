---
date: YYYY-MM-DD
cloud: aliyun | huawei | aws | other
profile: <一句话画像，如 "老 war Jenkins + 全部构建在宿主机 root">
source_version: <旧 Jenkins 版本与运行 Java>
target_version: <目标 Jenkins LTS 与运行 Java / 编译 JDK>
result: success | partial | rolled-back | aborted
duration_hours: <总时长（含勘察演练）>
skill_version: 0.1.0
operator: agent+human
---

# <标题>

## 1. 机器画像（脱敏）
- 云厂商 / 系统 / CPU / 内存：
- 磁盘布局（系统盘、数据盘、JENKINS_HOME 位置与大小）：
- Jenkins 运行方式（war / systemd / Tomcat / rpm / 容器）、任务数与类型、触发方式：
- 构建依赖（宿主机命令、`/etc/profile`、写死路径、运行账号家目录里的凭据）：
- 访问路径（公网 / VPN / 反向代理）：
- `scripts/survey-jenkins.sh` 的 BLOCKER / HIGH 摘要：

## 2. 与业务方确认的决定
- 维护窗口、可接受的停服时长：
- 哪些任务属于"会写生产"，发布窗口由谁给：
- 停用 / 下线 / 保留待确认的组件：
- 其它：

## 3. 时间线
| 时间 | 步骤 | 结果 / 备注 |
|---|---|---|

## 4. 遇到的问题
每个问题一节：

### 4.x <问题标题>
- 阶段：勘察 / 设计 / 演练 / 改造 / 切换 / 验收 / 收尾 / 运维
- 现象（原始报错，脱敏）：
- 原因：
- 处理：
- 预防（脚本 / 检查项改进建议）：
- 状态：promoted → `skills/jenkins-lts-upgrade/references/pitfalls.md` 的哪一节 / not yet

## 5. 结果对比（升级前 → 升级后）
| 检查项 | 升级前 | 升级后 | 备注 |
|---|---|---|---|

含：核心版本、运行 Java、部署方式、构建位置、编译 JDK、插件（数量/加载失败/安全警告）、任务数、数据位置、代表性任务的构建结果。

## 6. 技能脚本的不足
- 哪一步脚本没覆盖、需要手工处理：
- 文档哪里不清楚：

## 7. 遗留事项
-
