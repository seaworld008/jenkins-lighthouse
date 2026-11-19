# CLAUDE.md

本仓库的工作规则、经验沉淀流程与提交/发版规范全部在 [AGENTS.md](AGENTS.md)，维护前请先读完。

一句话版：

- 每次真实升级后：写脱敏的 `case-studies/` 报告 → 新坑回填 `pitfalls.md` → 更新 `CHANGELOG.md`。
- 绝不提交真实 IP/域名/凭据/公司名；示例用 `192.0.2.x`、`example.com`。
- 提交前 `python tools/check_repo.py` 必须通过。
- 版本号三处同步（plugin.json、marketplace.json、CHANGELOG），Release 工作流自动发版。
