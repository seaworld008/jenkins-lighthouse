# AGENTS.md — 给维护本仓库的 AI Agent

本仓库主要由 AI agent 阅读、执行、改进和沉淀经验。人类维护者负责审核与决策。开始任何工作前请先读完本文件（约 5 分钟）。

## 使命

给仍在使用老 Jenkins（2.2xx～2.4xx）和老 nginx 的团队两条可靠的路：**Jenkins 升级到当前 LTS，业务构建不断；nginx 高危漏洞批量修完，入口和镜像链路不破**。所有改动都服务于这三点：

1. **安全**：可回滚，不丢数据，不误杀在跑的构建
2. **可验证**：变更前后用基线对比和真实构建/拉取验证，而不是凭感觉
3. **可复用**：每次真实执行的经验都要沉淀成文档、检测和脚本

## 仓库地图

| 路径 | 作用 | 什么时候改 |
|---|---|---|
| `skills/jenkins-lts-upgrade/SKILL.md` | Jenkins 技能主流程，被 Claude 加载 | 流程/原则变化（保持 < 500 行，细节放 references） |
| `skills/jenkins-lts-upgrade/references/` | 架构、版本矩阵、坑、验收、回滚 | 每个新问题、每种新形态 |
| `skills/jenkins-lts-upgrade/scripts/` | 勘察、扫描、以 agent 身份执行、脚本控制台片段 | 修 bug、自动化新处理 |
| `skills/nginx-vuln-upgrade/SKILL.md` | nginx 漏洞升级技能主流程 | 同上 |
| `skills/nginx-vuln-upgrade/references/` | playbook、坑（各部署形态）、验证矩阵、回滚、镜像链路 | 每个新坑、新形态 |
| `skills/nginx-vuln-upgrade/scripts/` | fleet 批量执行、TLS 扫描、试运行门禁模板 | 同上 |
| `case-studies/` | 每次真实执行的脱敏报告 | **每次真实执行后必写** |
| `tools/check_repo.py` | 仓库自检（结构、版本一致、敏感信息） | 新规则 |
| `tests/` | Python 工具与扫描器的单元测试（unittest，标准库） | 改脚本时 |
| `.claude-plugin/` | Claude Code 插件与 marketplace 清单 | 发版时改版本号 |
| `CHANGELOG.md` | 变更记录 | 每个 PR |

## 铁律

1. **绝不提交敏感信息**：真实 IP、域名、主机名、账号、密码、密钥、客户/公司名、私有镜像仓库地址、真实任务名。示例统一用 `192.0.2.x`（RFC 5737）、`example.com`、`registry.example.com`、frontend-1..N。提交前必须 `python tools/check_repo.py` 通过（CI 还有 gitleaks）。
2. **诚实标注验证状态**：只在真实机器上跑通过的才写"已验证"。CHANGELOG 和 PR 描述里区分 `verified-on-real-run` 与 `untested`。
3. **脚本兼容性**：`scripts/*.sh` 必须在 CentOS 7 的 bash 4.2 下可用：
   - 不用 `ss -H`、`mapfile -d`、`${var@Q}` 等新特性
   - 每个 `for f in dir/*` 先判断 `[ -e "$f" ] || continue`
   - 不依赖可能缺失的命令；缺失时优雅降级
4. **只读脚本保持只读**：勘察、基线探测脚本不得修改系统。
5. **改业务前先确认"真实位置"**：容器化之后，旧路径（如 `/root/.jenkins`）是幽灵目录；改任务/服务前先 `docker inspect` 确认挂载，改完必须重启控制器（或 reload）才生效。
6. **会改变业务行为的事由人决定**：真实生产发布、重启生产 Jenkins、关闭旧 TLS、滚动生产 deployment、回滚。技能里写成"向用户确认"，不要自动执行。
7. **不要让 Agent 代输密码**：控制台登录由人完成；脚本里不打印、不在命令行参数中传递密码；凭据从文件或 credential store 读取。
8. **升级/迁移前必须已有回滚方案并演练过**；门禁（探测对比）失败即自动回滚，不"先看看"。

## 沉淀经验的工作流（最重要）

每次真实执行（无论成败）：

1. 按 `case-studies/TEMPLATE.md` 写 `case-studies/YYYY-MM-DD-<主题>.md`（脱敏），并更新 `case-studies/README.md` 的索引表。
2. 对报告里每个新问题判断：
   - 以后还会遇到 → 写进对应技能的 `references/pitfalls.md`（"现象 → 原因 → 处理"）
   - 能自动检测 → 在勘察脚本加 flag（BLOCKER 会失联/丢数据；HIGH 会坏业务；MEDIUM 需处理；INFO 提示）
   - 能自动修复 → 改进对应脚本，并给 `tests/` 加覆盖
   - 只是这一台的特例 → 只留在报告里
3. 在报告的问题小节标注 `状态：promoted → <位置>`。
4. 更新 `CHANGELOG.md` 的 `[Unreleased]` 段。

## 本地自检

```bash
python tools/check_repo.py                 # 结构、版本一致性、敏感信息、SKILL.md 引用的文件都存在
bash -n skills/*/scripts/*.sh               # 语法
python -m unittest discover -s tests        # 单元测试
shellcheck -S warning -e SC2010 -s bash skills/*/scripts/*.sh tests/*.sh
python -m py_compile skills/*/scripts/*.py tools/*.py tests/*.py
claude plugin validate .                    # 插件/marketplace 清单
```

## 提交与发版

- 分支 + PR；Conventional Commits（`feat:`、`fix:`、`docs:`、`pitfall:`、`report:`、`ci:`）；squash 合并。
- PR 描述说清楚：改了什么，为什么改，验证状态（真实机器 / 单测 / 未测）。
- 发版（semver）：
  1. 同步修改 `.claude-plugin/plugin.json` 的 `version`，以及 `marketplace.json` 里的 `metadata.version` 和 `plugins[0].version`
  2. 把 `CHANGELOG.md` 的 `[Unreleased]` 改成新版本号
  3. `check_repo.py` 会校验三处版本号与 CHANGELOG 一致
  4. 提 PR，CI 通过后合并。`Release` 工作流检测到 main 上 `plugin.json` 的版本变化后，会自动打 `vX.Y.Z` 标签，并用 CHANGELOG 对应段落发布 Release。不要手工打标签
- 分支：仓库只长期保留 `main`。

## 常见任务 → 去哪里

| 任务 | 入口 |
|---|---|
| 升级一台老 Jenkins | 加载 `jenkins-lts-upgrade` 技能，按 SKILL.md 执行，结束后写案例报告 |
| nginx 爆了高危 CVE | 加载 `nginx-vuln-upgrade` 技能；先勘察分级，再灰度单台，后批量 |
| 遇到没见过的报错 | 先搜两个技能的 `pitfalls.md`，再搜 `case-studies/` |
| 业务镜像里内嵌了老 nginx | `nginx-vuln-upgrade` 的 `references/image-chain.md` |
| 改进触发描述 | 对应技能 `SKILL.md` frontmatter 的 `description` |
