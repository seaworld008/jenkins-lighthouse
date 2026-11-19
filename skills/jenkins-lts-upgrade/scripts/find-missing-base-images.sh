#!/bin/bash
# find-missing-base-images.sh - 列出节点上缺失、需要预拉的基础镜像清单（只读）
# 用法: find-missing-base-images.sh <JENKINS_HOME> [本地镜像清单文件]
#   本地镜像清单缺省时用 `docker images` 现取；rootless 发布 Agent 场景请先用
#   run-as-agent.sh 以发布账号身份导出清单文件再传入。
# 背景: Docker 29 默认 containerd 镜像存储，BuildKit 拉 FROM 基础镜像取令牌时
#       不认 insecure-registries（moby/moby#51080），本地没有的镜像会 x509 失败。
#       处理就是扫描任务引用、预拉缺的（pitfalls C2）。
export LC_ALL=C
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

[ $# -lt 1 ] && { echo "用法: $0 <JENKINS_HOME> [本地镜像清单文件]" >&2; exit 2; }
JH="$1"; JDIR="$JH/jobs"
[ -d "$JDIR" ] || { echo "没有 jobs 目录: $JDIR" >&2; exit 1; }

LOCAL="$2"
if [ -z "$LOCAL" ]; then
  command -v docker >/dev/null 2>&1 || { echo "没有 docker，请导出清单后作为第二参数传入" >&2; exit 1; }
  LOCAL=$(mktemp /tmp/local-imgs.XXXXXX)
  trap 'rm -f "$LOCAL"' EXIT
  docker images --format '{{.Repository}}:{{.Tag}}' | sort -u > "$LOCAL"
  docker images --format '{{.Repository}}' | sort -u >> "$LOCAL"   # 无 tag 引用也按仓库名匹配
fi

# 从 jobs/*/config.xml 抽 FROM <registry>/<image> 与 IMAGE=<...> 引用（含 XML 转义还原）
USES=$(grep -rhoE 'FROM[[:space:]]+[^<"#[:space:]]+|IMAGE=[^<"]+' "$JDIR"/*/config.xml 2>/dev/null \
  | sed -e 's/\&amp;/\&/g; s/\&quot;/"/g; s/\&lt;/</g; s/\&gt;/>/g' -e 's/^[[:space:]]*FROM[[:space:]]*//' -e 's/^IMAGE=//' \
  | grep -vE '^\$|^scratch|^\\\$\{' | sort -u)
[ -z "$USES" ] && { echo "任务配置里没找到 FROM/IMAGE 引用"; exit 0; }

MISSING=""
while IFS= read -r img; do
  # docker images 列表里也包含了纯仓库名行；匹配 <image>:<tag> 或 <仓库前缀>
  if grep -qxF "$img" "$LOCAL" || grep -qxE "^${img%%:*}$" "$LOCAL"; then
    echo "LOCAL   $img"
  else
    echo "MISSING $img"
    MISSING="$MISSING $img"
  fi
done <<< "$USES"

echo
if [ -n "$MISSING" ]; then
  echo "需要预拉的基础镜像（$MISSING）："
  for img in $MISSING; do echo "  docker pull $img"; done
  echo "拉取后记录 RepoDigests；基础镜像标签更新后要重新拉。以发布账号身份执行请配合 run-as-agent.sh。"
else
  echo "本地镜像齐全，无需预拉。"
fi
