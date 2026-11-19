# Roadmap

## 已达成（0.1.0）

- Jenkins 2.2xx/2.3xx/2.4xx → 2.580.x LTS：容器化控制器 + 宿主机 agent，数据副本演练、切换/回滚、逐任务真实验收（开发 + 生产两套环境验证）
- nginx 高危漏洞批量升级：基线门禁、试运行对比、五种形态（compose / rpm / 源码 / OpenResty / 私仓入口）、TLS 1.2/1.3 收紧
- 私仓（Harbor 1.8 → 2.15.5）与前端镜像链路：换底重建、kubectl 滚动、Jenkins FROM 批量替换

## 计划

- [ ] Jenkins 升级技能：把"逐任务验收"做成半自动报告生成（从构建日志抽取证据）
- [ ] nginx 技能：更多 OpenResty 网关场景（WAF lua 规则迁移）的坑
- [ ] 镜像链路：Maven/java 后端镜像内嵌 Tomcat/nginx 的处理
- [ ] fleet 执行器：并行执行 + 按业务分批（主备不同批）
- [ ] 案例报告：更多环境（AWS / 自建机房）的实战沉淀
