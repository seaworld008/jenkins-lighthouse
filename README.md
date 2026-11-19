<div align="center">

<img src=".claude-plugin/icon.png" width="128" alt="Jenkins Lighthouse">

# Jenkins Lighthouse 🗼

**AI 时代，给还在跑老 Jenkins 和老 nginx 的你一座灯塔。**
把老 Jenkins **安全升级到 2.580.x LTS**（业务构建不停、可回滚、逐任务验收）；把 nginx 高危漏洞**批量修完**（容器、rpm、源码、OpenResty、私仓入口，一路门禁到底）。

[![CI](https://github.com/seaworld008/jenkins-lighthouse/actions/workflows/ci.yml/badge.svg)](https://github.com/seaworld008/jenkins-lighthouse/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/seaworld008/jenkins-lighthouse?color=0F4266)](https://github.com/seaworld008/jenkins-lighthouse/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Jenkins 2.2xx → 2.580 LTS](https://img.shields.io/badge/Jenkins-2.2xx%20%E2%86%92%202.580%20LTS-D24938?logo=jenkins&logoColor=white)](skills/jenkins-lts-upgrade/SKILL.md)
[![nginx → 1.30.7 / 1.31.9](https://img.shields.io/badge/nginx-%E2%86%92%201.30.7%20%2F%201.31.9-009639?logo=nginx&logoColor=white)](skills/nginx-vuln-upgrade/SKILL.md)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-skill%20%2B%20plugin-D97757?logo=anthropic&logoColor=white)](https://docs.claude.com/en/docs/claude-code)
[![Agent-first](https://img.shields.io/badge/maintained%20by-AI%20agents%20%2B%20humans-7B61FF)](AGENTS.md)
<br>
[![Alibaba Cloud](https://img.shields.io/badge/Alibaba%20Cloud-verified-FF6A00?logo=alibabacloud&logoColor=white)](case-studies/)
[![Huawei Cloud](https://img.shields.io/badge/Huawei%20Cloud-verified-C7000B?logo=huawei&logoColor=white)](case-studies/)

[English](README.en.md) · [快速开始](#-快速开始) · [两大技能](#-能做什么) · [避坑手册](skills/nginx-vuln-upgrade/references/pitfalls.md) · [实战报告](case-studies/) · [给 AI Agent](AGENTS.md)

</div>

---

## 💡 为什么需要它

老 Jenkins（2.2xx～2.4xx，Java 8）插件带不动、安全补丁没有、谁也不敢动：**真正的风险不在 Jenkins 本身，而在上面跑了多年的几百个任务**——写死的路径、`source /etc/profile`、藏在 `~/.docker/config.json` 里的凭据、只有某个 JDK 能编的代码。

nginx 漏洞公告一出，十几台主机、五种部署形态（compose 容器、rpm、源码编译、OpenResty 网关、私仓入口）要在同一个窗口内修完，还要保证 Harbor 拉镜像、K8s 前端、CI 构建链路不断。

这个仓库把 **两套生产环境 2026-11 真实升级里踩过的每一个坑**，都做成了自动检测、门禁、回滚和验证手册：

| 真实踩过的坑 | 这里怎么防 |
|---|---|
| 升级后改任务没生效：改的是迁移前的"幽灵" JENKINS_HOME（如 `/root/.jenkins`） | 改配置前先 `docker inspect` 确认真实 JENKINS_HOME 挂载 |
| 判断"有没有构建在跑"被 89 个被杀构建的残目录骗了 | 无 `build.xml` ≠ 在跑；按目录 mtime 判断 |
| 私仓入口换官方 nginx 镜像起不来：Harbor 配置属主 uid 10000 + `cap_drop: ALL` 读不了 | proxy 服务加 `user: "10000:10000"`，与 photon 行为一致 |
| CentOS 7 openssl 1.0.2 `s_client` 显示 TLS1.0 "成功"——其实是请求版本，握手早失败了 | 验证看 cipher 行 `(NONE)`，或用容器内新 openssl |
| Docker 19.03 旧 seccomp 不认识 trixie 新 glibc 的 `statx`/`clone3`，容器内 `ls` 报错 | 提前起试运行容器验证，必要时升级 Docker |
| 升级门禁误报：两个 nginx 版本的 308/404 默认页正文差 1 字节 | 门禁只对 2xx 比正文，3xx 只比状态码+跳转地址 |
| Harbor 跨大版本迁移后 PG 索引因 glibc collation 失效，core 空指针崩溃 | 每跳先起 db 再 `reindexdb -a` 并校验 |
| Docker 化 Jenkins 控制器升级窗口误杀在跑构建 | 静默模式 → 队列排空 → mtime 校验无活跃构建 → 快速重启 |

## ✨ 能做什么

### 技能一：[jenkins-lts-upgrade](skills/jenkins-lts-upgrade/SKILL.md) — Jenkins LTS 升级与迁移

- 🔍 **只读勘察**：war/Tomcat/rpm/docker 四种形态、全局 JDK、任务类型分布、磁盘上的凭据、写死的路径，输出分级风险
- 🐳 **只把控制器放进容器**：Docker Compose 控制器（Java 21/25）+ 宿主机 agent（业务编译 JDK 用绝对路径，不进 PATH），构建环境尽量不变
- 🧪 **数据副本演练**：副本 + 不同端口 + 0 执行器，先跑代表性任务再一次性切换
- ✅ **逐任务真实验收**：按发布方式分类，以镜像推送回执、class 主版本、`java -version` 为证据
- 🔄 **切换与回滚**：静默模式 → 队列为 0 → 停旧 → 最后同步 → 启新，全程时间戳；回滚脚本演练过才切换

### 技能二：[nginx-vuln-upgrade](skills/nginx-vuln-upgrade/SKILL.md) — nginx 高危漏洞批量升级

- 📸 **基线门禁**：`nginx -T` 解析出 (协议, 端口, server_name) 逐个探测，两轮一致才作基线；变更后任一基线变化自动回滚
- 🧪 **试运行容器对比**：同挂载起临时容器，与现网逐项对比（状态码、头、正文 md5）一致后才切
- 🧱 **五种形态全覆盖**：compose 容器换镜像、rpm 平滑升级、源码编译 USR2/WINCH 平滑替换、OpenResty 网关过渡（含 Lua 业务不能换纯 nginx 的判断）、私仓（Harbor）入口替换
- 🔐 **TLS 1.2/1.3 收紧**：与版本切换分开做、各自有门禁，验证矩阵含逐版本握手
- 🚀 **镜像链路一条龙**：前端镜像换底重建 → 逐路径对比 → 推私仓/云仓 → kubectl 逐个滚动（rollout + ingress 前后对比）→ Jenkins 任务 FROM 批量替换（备份 + sed + 重启加载）
- 🤖 **为 AI agent 设计**：Claude Code 技能 + 插件。Agent 按流程推进，遇到需要人拍板的事会停下来问你

## 🚀 快速开始

### 方式一：Claude Code 插件（推荐）

```
/plugin install jenkins-lighthouse --marketplace seaworld008/jenkins-lighthouse
```

然后直接说："帮我把这台 2.346 的 war 方式 Jenkins 升到最新 LTS，构建不能断" 或 "nginx 刚爆了高危 CVE，帮我把这几台都修到 1.30.7"。

### 方式二：手动安装技能

```bash
git clone https://github.com/seaworld008/jenkins-lighthouse.git
cp -r jenkins-lighthouse/skills/* ~/.claude/skills/
```

### 方式三：不用 AI，直接用脚本

```bash
# 批量在目标机执行门禁切换模板（inventory.json 用文档 IP 段示例，自备真实清单，勿提交）
python skills/nginx-vuln-upgrade/scripts/fleet_exec.py skills/nginx-vuln-upgrade/scripts/trial_swap.sh trial web-01
python skills/nginx-vuln-upgrade/scripts/tls_scan.py 192.0.2.10 443   # TLS 逐版本握手扫描
bash skills/jenkins-lts-upgrade/scripts/survey-jenkins.sh    # 在目标机只读勘察
```

之后按各技能的 [SKILL.md](skills/jenkins-lts-upgrade/SKILL.md) 阶段推进。

## 🗂 仓库结构

```
skills/jenkins-lts-upgrade/   Jenkins LTS 升级技能（SKILL + references + scripts + assets）
skills/nginx-vuln-upgrade/    nginx 漏洞批量升级技能（SKILL + references + scripts）
case-studies/                 4 篇真实生产升级的脱敏报告
tools/check_repo.py           仓库自检：结构、版本一致性、敏感信息
tests/                        单元测试（含 Jenkins 任务配置扫描器）
.github/workflows/            CI（lint + shellcheck + 单测 + gitleaks）与自动 Release
```

## 📚 实战报告（全部脱敏）

| 日期 | 场景 | 结果 |
|---|---|---|
| 2026-11-19 | [开发环境 Jenkins 2.346.1 → 2.580.2 LTS（容器化）](case-studies/2026-11-19-jenkins-dev-2.346-to-2.580.md) | 成功，停服 2 分 40 秒 |
| 2026-11-19 | [生产环境 Jenkins 2.275 → 2.580.2 LTS（独立账号 + rootless 发布 Agent）](case-studies/2026-11-19-jenkins-prod-2.275-to-2.580.md) | 成功，36 个交付任务 33 个真实构建通过 |
| 2026-11-19 | [多主机 nginx CVE 批量升级（10 CVE → 1.30.7/1.31.9）](case-studies/2026-11-19-nginx-cve-fleet-upgrade.md) | 成功，全部门禁 0 差异 |
| 2026-11-19 | [私仓 Harbor 1.8.0 → 2.15.5 与前端镜像链路](case-studies/2026-11-19-harbor-upgrade-and-frontend-image-chain.md) | 成功，HTTP/HTTPS 拉取四组合实测通过 |

## 🤝 参与与安全

- 贡献流程见 [CONTRIBUTING.md](CONTRIBUTING.md)，行为准则见 [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)，漏洞披露见 [SECURITY.md](SECURITY.md)。
- 本仓库**绝不包含**真实 IP、域名、主机名、凭据或客户信息；提交前 `python tools/check_repo.py` 必须通过（CI 还有 gitleaks）。

## License

[MIT](LICENSE)
