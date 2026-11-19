// set-global-jdk.groovy - 脚本控制台片段：改全局 JDK 工具并确保落盘
// 关键点（pitfalls A1）：JDK.DescriptorImpl.setInstallations() 只改内存，descriptor.save()
// 写的是无关的 hudson.model.JDK.xml；JDK 列表实际存放在主 config.xml，要由 Jenkins.get().save() 写盘。
// 本片段：比较内存配置与磁盘 config.xml → 只在预期差异时备份并保存 → 保存后从磁盘读回复核。
// 用法：改 JDK_NAME / NEW_HOME 两个常量后粘贴到 Script Console。

import jenkins.model.Jenkins
import hudson.model.JDK

def JDK_NAME  = 'java'                       // <-- 全局 JDK 工具名（config.xml 里 <name>）
def NEW_HOME  = '/data/jenkins/tools/temurin8' // <-- 新 JDK 8 路径
def j = Jenkins.get()
def f = new File(j.rootDir, 'config.xml')

// 1. 内存替换（只改内存）
def d = j.getDescriptorByType(JDK.DescriptorImpl)
def changed = d.installations.find { it.name == JDK_NAME && it.home != NEW_HOME }
d.setInstallations(d.installations.collect { it.name == JDK_NAME ? new JDK(JDK_NAME, NEW_HOME) : it } as JDK[])

// 2. 比较内存配置与磁盘 config.xml（逐行 trim 后的差集）
def disk = f.text.readLines()*.trim().findAll { it }
def mem  = Jenkins.XSTREAM2.toXML(j).readLines()*.trim().findAll { it }
println "ONLY_DISK=" + (disk - mem)
println "ONLY_MEM="  + (mem - disk)
def unexpected = (disk - mem).findAll { !it.startsWith('<jdk') && !it.startsWith('<name') && !it.startsWith('<home') }
if (unexpected) { println "ABORT: 磁盘上还有非 JDK 的差异，先人工核对：$unexpected"; return }

// 3. 备份 → 保存 → 从磁盘读回复核（防止只改了内存）
if (changed || (disk - mem)) {
    new File(j.rootDir, 'config.xml.bak-' + new Date().format('yyyyMMddHHmmss')).text = f.text
    j.save()                                   // 主 config.xml 由 Jenkins.get().save() 写盘
}
def onDisk = f.text.contains(NEW_HOME)
println "on disk contains $NEW_HOME : $onDisk"
if (!onDisk) println "FAIL: 保存后磁盘上仍是旧路径，不要重启，人工检查"
// 4. 提醒：随后的全量备份里也要能看到新路径，才算真正闭环
