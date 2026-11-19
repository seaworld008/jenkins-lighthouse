// trigger-batch.groovy - 脚本控制台片段：按默认参数触发一批任务，避开私仓 GC 时段
// 用法：粘贴到 Manage Jenkins > Script Console（或经 /scriptText 调用）。
// 先改 JOBS 列表；GC 窗口按仓库实际计划调整（示例 :50–:03）。
// Jenkins 2.580 API：scheduleBuild2 + ParametersAction；任务可能没有参数定义（判空）。

import jenkins.model.Jenkins
import hudson.model.*

def JOBS = ["job-a", "job-b", "job-c"]      // <-- 改成要触发的任务全名
def GC_FROM = 50, GC_TO = 3                   // 避开的分钟区间（整点 GC，示例 :50–:03）

def j = Jenkins.get()
def m = (new Date().format('mm') as int)
if (m >= GC_FROM || m < GC_TO) {
    println "ABORT: 当前分钟 $m 在私仓 GC 窗口（:$GC_FROM–:$GC_TO），改时间再来"
    return
}
JOBS.each { n ->
    def job = j.getItemByFullName(n)
    if (job == null)            { println "$n SKIP 任务不存在"; return }
    if (!(job instanceof AbstractProject) && !job.getClass().simpleName.contains('WorkflowJob')) { println "$n SKIP 不可触发"; return }
    if (job.disabled)           { println "$n SKIP 已停用"; return }
    if (job.isBuilding() || job.isInQueue()) { println "$n SKIP 排队/构建中"; return }
    def defs = job.getProperty(ParametersDefinitionProperty)?.parameterDefinitions ?: []
    def vals = defs.collect { it.defaultParameterValue }.findAll { it != null }
    job.scheduleBuild2(0, new Cause.UserIdCause(), new ParametersAction(vals))
    println "$n queued params=" + vals.collect { it.name + '=' + it.value }
}
println "触发完成，用 poll-results.groovy 收结果"
