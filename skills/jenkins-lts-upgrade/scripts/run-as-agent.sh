#!/bin/bash
# run-as-agent.sh - 以 Jenkins agent 进程的挂载命名空间和环境执行命令（只读勘察用）
# 用法: run-as-agent.sh <agent-unit> -- <命令...>
#   例: run-as-agent.sh jenkins-agent.service -- bash -lc 'source /etc/profile; java -version; mvn -version; docker info'
# 原理: 取 agent systemd unit 的 MainPID，用 nsenter 进入它的 mount/env/pid 命名空间，
#       再以 agent 的 uid/gid 执行命令 —— 看到的 PATH、/etc/profile、rootless Docker socket
#       与真实构建完全一致。脚本本身不改任何系统状态。
export LC_ALL=C
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

[ $# -lt 3 ] || [ "$2" != "--" ] && { echo "用法: $0 <agent-unit> -- <命令...>" >&2; exit 2; }
UNIT="$1"; shift 2
COMMAND="$*"

systemctl is-active --quiet "$UNIT" || { echo "unit $UNIT 不在运行状态" >&2; exit 1; }
PID=$(systemctl show -p MainPID --value "$UNIT")
[ -n "$PID" ] && [ "$PID" -gt 0 ] || { echo "取不到 $UNIT 的 MainPID" >&2; exit 1; }

RUID=$(systemctl show -p User --value "$UNIT"); RUID=${RUID:-root}
RUN_AS_UID=$(id -u "$RUID" 2>/dev/null) || { echo "账号 $RUID 不存在" >&2; exit 1; }
RUN_AS_GID=$(id -g "$RUID")
echo "# unit=$UNIT pid=$PID user=$RUID($RUN_AS_UID:$RUN_AS_GID) cmd=$COMMAND" >&2

# /proc/PID/environ 的环境（去掉 systemd 注入的内部变量），用 env -i 完整还原。
# 等价写法（root 会话里临时 unit 记账）：systemd-run --scope --unit=jenkins-as-agent-$$ \
#   nsenter -t $PID -m -e -p -- setpriv --reuid=$RUN_AS_UID --regid=$RUN_AS_GID --clear-groups env -i ... bash -c "$COMMAND"
# 有 machinectl 的系统也可用 `machinectl shell`，但 nsenter 在 CentOS 7 最通用。
ENV_ARGS=()
while IFS= read -r line; do
  case "$line" in CREDENTIALS_DIRECTORY=*|INVOCATION_ID=*|JOURNAL_STREAM=*) continue;; esac
  ENV_ARGS+=("$line")
done < <(tr '\0' '\n' < "/proc/$PID/environ")

# CentOS 7 无 nsenter -m -e -p 的组合问题时用显式参数；有 machinectl 的系统也可用
# `machinectl shell`，但 nsenter 更通用。
setpriv --reuid="$RUN_AS_UID" --regid="$RUN_AS_GID" --clear-groups \
  nsenter -t "$PID" -m -e -p -- \
  env -i "${ENV_ARGS[@]}" bash -c "$COMMAND"
