# 实战案例 / Case Studies

每次真实升级（成功、失败、回滚）后的脱敏报告。按 [TEMPLATE.md](TEMPLATE.md) 写，写完加进下表。所有内容已脱敏（IP 用 RFC 5737 文档段、域名用 example.com、任务名抽象化），可安全公开。

| 日期 | 云 | 主题 | 路径 | 结果 |
|---|---|---|---|---|
| 2026-11-19 | aliyun | 开发环境 Jenkins 升级与容器化 | [2026-11-19-jenkins-dev-2.346-to-2.580.md](2026-11-19-jenkins-dev-2.346-to-2.580.md) | success |
| 2026-11-19 | huawei | 生产环境 Jenkins 升级（宿主机 agent + rootless 发布） | [2026-11-19-jenkins-prod-2.275-to-2.580.md](2026-11-19-jenkins-prod-2.275-to-2.580.md) | partial |
| 2026-11-19 | huawei + aliyun | 多主机 nginx 高危漏洞批量升级 | [2026-11-19-nginx-cve-fleet-upgrade.md](2026-11-19-nginx-cve-fleet-upgrade.md) | success |
| 2026-11-19 | huawei | 私仓 Harbor 1.8→2.15.5 与前端镜像链路 | [2026-11-19-harbor-upgrade-and-frontend-image-chain.md](2026-11-19-harbor-upgrade-and-frontend-image-chain.md) | success |

## 怎么写一篇

见 [TEMPLATE.md](TEMPLATE.md)。要点：

1. 前置元数据齐全（date/cloud/profile/source_version/target_version/result/duration_hours/skill_version/operator）。
2. 每个问题按"现象 → 原因 → 处理 → 预防"写，处理完判断要不要提升（promoted）到技能的 `pitfalls.md`。
3. **脱敏是硬性要求**：`python tools/check_repo.py` 会扫 IPv4、密钥、token、邮箱。
