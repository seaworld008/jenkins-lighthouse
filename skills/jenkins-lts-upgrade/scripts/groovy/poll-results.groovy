// poll-results.groovy - 脚本控制台片段：收集一批任务的构建号、结果和第一条错误
// 用法：粘贴到 Script Console（或经 /scriptText 调用）。单次调用超时约 90 秒，
//       下面的等待循环控制在 60 秒内，没跑完就再调一次本片段。
// Jenkins 2.580 API：lastBuild 可能为 null（判空）；getLog(200000)；durationString。
// 与 trigger-batch.groovy 配套，JOBS 名单保持一致。

import hudson.model.Result

def JOBS = ["job-a", "job-b", "job-c"]      // <-- 与 trigger-batch.groovy 一致
def j = Jenkins.get()
def t0 = System.currentTimeMillis()
while (System.currentTimeMillis() - t0 < 60000 &&
       JOBS.any { def jb = j.getItemByFullName(it); jb && (jb.isInQueue() || jb.isBuilding()) }) {
    sleep(5000)
}
JOBS.each { n ->
    def jb = j.getItemByFullName(n)
    if (jb == null)        { println "$n NO_SUCH_JOB"; return }
    def b = jb.lastBuild
    if (b == null)         { println "$n NO_BUILD_YET"; return }
    def ls = b.getLog(200000)
    def tag = ls.find { it.startsWith('JENKINS_IMAGE_TAG=') } ?: ''
    def dig = ls.findAll { it =~ /: digest: sha256:/ }.collect { (it =~ /sha256:[0-9a-f]+/)[0] }.join(',')
    def err = ''
    if (!b.isBuilding() && b.result != Result.SUCCESS) {
        def i = ls.findIndexOf { it =~ /(?i)(FATAL|ERROR|error:|Exception|denied|not found|No such file|command not found|Permission|cannot|failed)/ }
        err = i >= 0 ? ls[i].take(230) : (ls ? ls[-1].take(200) : '')
    }
    println "$n #${b.number} " + (jb.isInQueue() ? 'QUEUED' : b.isBuilding() ? 'BUILDING' : b.result) + \
            " ${b.durationString} ${tag} ${dig} ${err}".toString()
}
