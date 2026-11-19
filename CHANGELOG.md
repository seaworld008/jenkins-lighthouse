# Changelog

本仓库遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [SemVer](https://semver.org/lang/zh-CN/)。每个版本的全部说明也会作为 GitHub Release 的发布说明。

## [0.1.0] - 2026-11-19

首个版本。内容来自 2026-11 阿里云 + 华为云两套生产环境的真实升级（开发环境 Jenkins 2.346.1、生产环境 Jenkins 2.275 均升级到 2.580.2 LTS；两个云十几台主机的 nginx 高危漏洞批量升级与私仓/前端镜像链路改造）。

### Added

- 技能 **jenkins-lts-upgrade**：把老 Jenkins（2.2xx/2.3xx/2.4xx，war/Tomcat/rpm，Java 8/11）升级或迁移到当前 LTS（2.580.x，Java 21/25）：
  - 只把控制器放进 Docker Compose，构建留在宿主机 agent，业务构建环境尽量不变；
  - 数据副本演练 → 一次性切换 → 回滚预案；
  - 勘察/批量触发/结果收集/全局 JDK 落盘复核脚本控制台片段；
  - 以真实构建为证据的逐任务验收方法。
- 技能 **nginx-vuln-upgrade**：nginx 高危漏洞的批量升级（2026-11-18 10 CVE，修复版本 1.30.7 stable / 1.31.9 mainline）：
  - fleet 勘察与基线门禁（两轮一致才作基线）、试运行容器逐项对比、切换自动回滚；
  - compose 容器、rpm、源码编译平滑替换、OpenResty 网关过渡、Harbor 私仓入口（uid 10000 + cap_drop 坑）各形态的处理；
  - TLS 1.2/1.3 收紧与验证矩阵（含 openssl 1.0.2 误判坑）；
  - 内嵌 nginx 的前端镜像升级链路：换底重建 → 推私仓/云仓 → kubectl 滚动 → Jenkins 任务 FROM 批量替换。
- 实战案例 4 篇（全部脱敏）：[case-studies/](case-studies/README.md)。
- 仓库自检 `tools/check_repo.py`（技能结构、版本一致性、敏感信息扫描）与 CI（bash -n、ShellCheck、py_compile、单测、gitleaks、Claude 插件清单校验）。

[0.1.0]: https://github.com/seaworld008/jenkins-lighthouse/releases/tag/v0.1.0
