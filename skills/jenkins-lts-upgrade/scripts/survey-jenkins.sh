#!/bin/bash
# survey-jenkins.sh - Jenkins 升级前只读勘察（不修改任何东西）
# 用法: bash survey-jenkins.sh [JENKINS_HOME] > survey.txt
#       JENKINS_HOME 缺省时自动探测。末尾 RISK FLAGS 段是重点。
# 只读：本脚本不写任何文件、不改任何服务，只调用 cat/ls/df/grep/systemctl show 等只读命令。
export LC_ALL=C
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

FLAGS=""
flag() { FLAGS="${FLAGS}[$1] $2"$'\n'; }   # 级别: BLOCKER / HIGH / MEDIUM / INFO
sec()  { echo; echo "===== $* ====="; }
has()  { command -v "$1" >/dev/null 2>&1; }

# ---------- 定位 JENKINS_HOME 与运行方式 ----------
HOME_GUESS=""
for c in /var/lib/jenkins /data/jenkins/home /data/jenkins/controller /root/.jenkins; do
  [ -f "$c/config.xml" ] && HOME_GUESS="$HOME_GUESS $c"
done
[ $# -ge 1 ] && JH="$1" || JH="${HOME_GUESS%% *}"
if [ -z "$JH" ] || [ ! -f "$JH/config.xml" ]; then
  # 从进程命令行里找 -DJENKINS_HOME=
  JH=$(ps -eo args 2>/dev/null | grep -oE '\-DJENKINS_HOME=[^ ]+' | head -1 | cut -d= -f2)
fi
if [ -z "$JH" ] || [ ! -f "$JH/config.xml" ]; then
  echo "找不到 JENKINS_HOME（config.xml 不存在）。用法: $0 <JENKINS_HOME>"
  exit 1
fi
[ $# -ge 1 ] || echo "(自动探测到 JENKINS_HOME=$JH；多处存在时请显式指定)"
[ "$(echo $HOME_GUESS | wc -w)" -gt 1 ] && flag HIGH "机器上有多个疑似 JENKINS_HOME（$HOME_GUESS）：改任何配置前先 docker inspect 确认真实挂载，防止改到幽灵目录（见 pitfalls G1）"

sec RUN_MODE
MODE=unknown
RUNUSER=""
if systemctl list-units --type=service --no-legend 2>/dev/null | grep -qiE '^\s*jenkins'; then
  UNIT=$(systemctl list-units --type=service --no-legend 2>/dev/null | grep -iE '^\s*jenkins' | awk '{print $1}' | head -1)
  echo "systemd unit: $UNIT ($(systemctl is-active "$UNIT" 2>/dev/null))"
  RUNUSER=$(systemctl show -p User --value "$UNIT" 2>/dev/null)
  systemctl cat "$UNIT" 2>/dev/null | sed 's/^/  unit| /'
  MODE=systemd
  systemctl cat "$UNIT" 2>/dev/null | grep -qE 'ExecStart=.*\.war' && MODE="systemd-war"
  systemctl cat "$UNIT" 2>/dev/null | grep -qiE 'ExecStart=.*catalina|/tomcat' && MODE="systemd-tomcat"
fi
if docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null | grep -qiE 'jenkins'; then
  docker ps --format '{{.Names}} {{.Image}} {{.Ports}}' 2>/dev/null | grep -i jenkins | sed 's/^/  container| /'
  MODE=docker
fi
rpm -q jenkins >/dev/null 2>&1 && { echo "rpm: $(rpm -q jenkins)"; rpm -V jenkins 2>/dev/null | grep -q 'jenkins\.war$' && flag INFO "jenkins.war 被手工替换过，rpm 版本不代表实际运行版本"; }
echo "mode=$MODE run_user=${RUNUSER:-?} JENKINS_HOME=$JH"
[ "$MODE" = "unknown" ] && flag HIGH "没识别出 Jenkins 的运行方式（war/systemd/Tomcat/Docker），手工确认后再继续"

# ---------- 版本与 Java ----------
sec VERSION_AND_JAVA
JPID=$(ps -eo pid,args 2>/dev/null | grep -E 'jenkins\.war|jenkins\.wars?[[:space:]]|-jar.*jenkins' | grep -v grep | awk '{print $1}' | head -1)
[ -z "$JPID" ] && [ "$MODE" = docker ] && JPID=$(docker ps -q --filter name=jenkins 2>/dev/null | head -1 | xargs -r docker inspect -f '{{.State.Pid}}' 2>/dev/null)
if [ -n "$JPID" ] && [ -r "/proc/$JPID" ]; then
  echo "controller pid=$JPID"
  tr '\0' ' ' < /proc/$JPID/cmdline | head -c 400; echo
fi
[ -f "$JH/config.xml" ] && echo "core=$(grep -oE '<version>[^<]+' "$JH/config.xml" | head -1 | cut -d'>' -f2)"
# 运行 Jenkins 的 Java
JEXE=$(ps -eo args 2>/dev/null | grep -E 'jenkins\.war' | grep -v grep | head -1 | grep -oE '^[^ ]+/bin/java' | head -1)
[ -z "$JEXE" ] && JEXE=$(readlink -f "$(ps -eo pid,comm 2>/dev/null | awk '$2=="java"{print $1}' | head -1 | xargs -r -I{} readlink -f /proc/{}/exe)" 2>/dev/null)
if [ -n "$JEXE" ] && [ -x "$JEXE" ]; then "$JEXE" -version 2>&1 | head -2; else echo "运行 Java: 未定位到（容器内时进容器执行 java -version）"; fi
# 业务/全局 JDK
echo "--- /etc/profile 里的 JAVA_HOME/PATH:"
grep -nE 'JAVA_HOME|^PATH=|export PATH' /etc/profile 2>/dev/null | sed 's/^/  /'
alternatives --display java 2>/dev/null | grep -E '^\s*[=/]|currently' | sed 's/^/  /'
echo "--- 全局 JDK 工具（config.xml）:"
grep -A2 '<jdk>' "$JH/config.xml" 2>/dev/null | sed 's/^/  /'
JDKPATH=$(sed -n 's/.*<home>\([^<]*\)<\/home>.*/\1/p' "$JH/config.xml" 2>/dev/null | head -1)
[ -n "$JDKPATH" ] && [ ! -d "$JDKPATH" ] && flag HIGH "全局 JDK 工具指向的目录不存在: $JDKPATH"
if [ -n "$JDKPATH" ]; then
  case "$JDKPATH" in *jdk1.8*|*jdk8*|*1\.8\.0*) flag MEDIUM "全局 JDK 工具是旧 Oracle JDK 8（$JDKPATH）：会进所有选用它任务的 PATH，规划替换成受支持的 JDK 8 发行版（pitfalls A2）";; esac
fi

sec PLUGINS
PDIR="$JH/plugins"
if [ -d "$PDIR" ]; then
  NP=$(ls "$PDIR" 2>/dev/null | grep -c '\.jpi$\|\.hpi$')
  echo "plugins: $NP 个 jpi/hpi"
  # 过期程度：统计一年以上没动过的插件文件
  OLD=$(find "$PDIR" -maxdepth 1 -name '*.jpi' -mtime +365 2>/dev/null | wc -l)
  echo "一年以上未更新的插件文件: $OLD"
  [ "$NP" -gt 0 ] && [ "$OLD" -gt 0 ] && flag HIGH "插件普遍陈旧（$OLD/$NP 一年以上未更新）：跨大版本时插件目录要整体替换成目标版本更新中心解析出的清单，不要逐个升级（pitfalls A6）"
  ls -lt "$PDIR" 2>/dev/null | head -6 | sed 's/^/  /'
else
  flag HIGH "没有 plugins 目录: $PDIR"
fi

sec JOBS
JDIR="$JH/jobs"
if [ -d "$JDIR" ]; then
  types() { for t in freestyle-project maven2-moduleset workflow-job matrix-project folder; do
    n=$(grep -l "<$t>" "$JDIR"/*/config.xml 2>/dev/null | wc -l); [ "$n" -gt 0 ] && echo "  $t: $n"; done; }
  types
  NJ=$(ls -d "$JDIR"/*/ 2>/dev/null | wc -l)
  NDIS=$(grep -l '<disabled>true' "$JDIR"/*/config.xml 2>/dev/null | wc -l)
  echo "顶层任务目录: $NJ，其中停用: $NDIS"
  NPROF=$(grep -lE '(source|\.)\s+/etc/profile' "$JDIR"/*/config.xml 2>/dev/null | wc -l)
  echo "source /etc/profile 的任务: $NPROF"
  [ "$NPROF" -gt 0 ] && flag HIGH "$NPROF 个任务 source /etc/profile：profile 会改写 JAVA_HOME，agent 需要绑定调整过的只读副本（pitfalls A3）"
  NMAV=$(grep -l '<maven2-moduleset>' "$JDIR"/*/config.xml 2>/dev/null | wc -l)
  [ "$NMAV" -gt 0 ] && flag HIGH "$NMAV 个 Maven 项目类型：受控制器 Java 约束，需要 JDK 8 的要改成自由风格 Shell 调 mvn（pitfalls A4）"
  NWS=$(grep -lE '/var/lib/jenkins/workspace|/data/jenkins/workspace' "$JDIR"/*/config.xml 2>/dev/null | wc -l)
  echo "写死 workspace 绝对路径的任务: $NWS"
  [ "$NWS" -gt 0 ] && flag INFO "$NWS 个任务写死 workspace 绝对路径：新 HOME 用 bind mount 回原路径可保持兼容"
  # 活跃构建的判断口径（mtime，不是 build.xml）
  RECENT=$(find "$JDIR" -maxdepth 3 -type d -name builds -newermt '-10 minutes' 2>/dev/null | wc -l)
  [ "$RECENT" -gt 0 ] && flag INFO "有 $RECENT 个任务的 builds 目录 10 分钟内有变动：切换窗口要按目录 mtime 判断活跃构建，被杀掉的构建也没有 build.xml（见 pitfalls G2）"
else
  flag BLOCKER "没有 jobs 目录: $JDIR"
fi

sec EXECUTORS
grep -A1 '<numExecutors>' "$JH/config.xml" 2>/dev/null | sed 's/^/  /'
NEX=$(sed -n 's/.*<numExecutors>\([0-9]*\)<\/numExecutors>.*/\1/p' "$JH/config.xml" 2>/dev/null)
[ -n "$NEX" ] && [ "$NEX" -gt 0 ] && flag MEDIUM "内置节点有 $NEX 个执行器：升级后应设为 0，全部构建走宿主机 agent（见 architecture.md）"

sec DISK
df -hT "$JH" / /data 2>/dev/null
FREE_MB=$(df -Pm "$JH" 2>/dev/null | awk 'NR==2{print $4}')
[ -n "$FREE_MB" ] && [ "$FREE_MB" -lt 10240 ] && flag HIGH "JENKINS_HOME 所在文件系统仅剩 ${FREE_MB}MB：迁移副本、备份、构建缓存需要数倍空间，先清理"
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT 2>/dev/null

sec CREDENTIALS_ON_DISK
# 构建实际依赖、但不属于 Jenkins 凭据库的凭据（只列存在性和主机名，绝不打印内容）
RUNU="${RUNUSER:-root}"
RH="/root"; [ "$RUNU" != "root" ] && RH=$(getent passwd "$RUNU" 2>/dev/null | cut -d: -f6)
echo "运行账号: $RUNU (home=$RH)"
if [ -f "$RH/.docker/config.json" ]; then
  echo "  ~/.docker/config.json 存在，auths 里的 registry 主机名:"
  grep -oE '"[a-zA-Z0-9._:-]+":\s*\{' "$RH/.docker/config.json" 2>/dev/null | grep -oE '"[a-zA-Z0-9._:-]+"' | tr -d '"' | sed 's/^/    /'
  flag MEDIUM "运行账号的 ~/.docker/config.json 有私仓登录项：迁移到新账号时要按旧任务实际推送范围补入（0600）（pitfalls B5）"
else
  echo "  ~/.docker/config.json 不存在"
fi
for f in "$RH/.ssh/id_rsa" "$RH/.ssh/id_ed25519" "$RH/.ssh/config" "$RH/.ssh/known_hosts"; do
  [ -f "$f" ] && echo "  有 $f"
done
[ -f "$RH/.ssh/known_hosts" ] && flag MEDIUM "known_hosts 存在：新版 Git 插件主机密钥校验更严格，需要时更新过期的条目（pitfalls E3）"
[ -d "$JH/secrets" ] && echo "  Jenkins secrets/ 存在（主密钥，迁移时整体带走）"

echo
echo "===== RISK FLAGS ====="
if [ -n "$FLAGS" ]; then printf '%s' "$FLAGS"; else echo "(无)"; fi
