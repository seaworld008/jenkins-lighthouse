# 贡献指南 / Contributing

感谢你帮忙让更多老 Jenkins 和老 nginx 平稳上岸！人类和 AI agent 都欢迎贡献。**Agent 请先读 [AGENTS.md](AGENTS.md)**，那里是完整的规则。

## 最有价值的贡献（按优先级）
1. **实战报告**：真实升级一次后，按 [case-studies/TEMPLATE.md](case-studies/TEMPLATE.md) 写一份脱敏报告（失败的也要）。
2. **新坑**：写进对应技能的 `references/pitfalls.md`，格式为"现象 → 原因 → 处理"，放到对应的阶段。
3. **自动检测**：能提前发现的问题，在 `survey-jenkins.sh` / 勘察脚本里加一个分级 `flag`。
4. **自动处理**：改进试运行对比 / 门禁 / 回滚脚本，并给 `tests/` 加覆盖。
5. 新的部署形态（Tomcat war、systemd、K8s 内 Jenkins、OpenResty 网关）、新的云厂商、文档改进、英文翻译。

## 流程
1. Fork / 新建分支，例如 `pitfall/harbor-proxy-xxx`、`report/2026-12-01-aws-jenkins`
2. 修改后本地自检：
   ```bash
   python tools/check_repo.py
   python -m unittest discover -s tests
   shellcheck -S warning -e SC2010 -s bash skills/*/scripts/*.sh
   ```
3. 提交信息遵循 Conventional Commits：`feat:` `fix:` `docs:` `pitfall:` `report:` `ci:`
4. 提 PR，按模板写清"验证状态"（真实机器 / 单元测试 / 未测）
5. 更新 `CHANGELOG.md` 的 `[Unreleased]`

## 脱敏规则（硬性）
- 不得出现真实 IP、域名、主机名、账号、密码、密钥、公司或客户名、私有镜像仓库地址、真实 Jenkins 任务名
- 示例统一用 `192.0.2.x`（RFC 5737）、`example.com`、`registry.example.com`、`frontend-1`
- `tools/check_repo.py` 和 CI 的 gitleaks 会拦截常见模式，但它们不能代替你自己检查

## 脚本兼容性要求
`scripts/*.sh` 在目标机上运行，必须兼容 CentOS 7 的 bash 4.2 与老版本 coreutils（技能可能跑在还没升级 OS 的老机器上）。具体规则见 AGENTS.md「铁律 3」。

---

**English summary**: The most valuable contributions are sanitized case reports from real runs, new pitfalls (symptom → cause → fix), detections in the survey scripts, and automation in the gate/rollback scripts. Run `python tools/check_repo.py` and shellcheck before opening a PR, state the verification level honestly, and never include real IPs, domains, hostnames, credentials or job names. AI agents: read [AGENTS.md](AGENTS.md) first.
