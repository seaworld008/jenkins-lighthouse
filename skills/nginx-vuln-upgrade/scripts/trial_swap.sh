#!/usr/bin/env bash
# trial_swap.sh — 试运行容器对比 + 门禁切换 + 自动回滚（compose 容器场景模板）。
#
# 环境变量注入（无硬编码）:
#   COMPOSE_FILE   compose 文件路径（必填）
#   SERVICE        服务名（必填）
#   NEW_IMAGE      目标镜像（必填，私仓 tag）
#   BACKUP_DIR     备份目录（必填）
#   PROBE_TARGETS  探测目标，每行一个 "schema://host:port server_name"，
#                  例: "http://127.0.0.1:80 example.com"
#   PROBE_PATHS    探测路径，空格分隔，默认 "/ /__nonexist_probe__"
#   ROUNDS         基线轮数，默认 2
#   COMPOSE_CMD    compose 命令，默认 "docker compose"
#
# 流程: 基线(两轮一致) -> 起试运行容器(同挂载同网络) 对比 -> 全一致才改镜像
#       up -d --no-deps -> 探测复查 -> 不一致自动还原 compose 并 up 回旧镜像。
# 门禁口径: 2xx 比状态码+正文md5; 3xx 只比状态码+Location。
set -euo pipefail

COMPOSE_FILE="${COMPOSE_FILE:?COMPOSE_FILE required}"
SERVICE="${SERVICE:?SERVICE required}"
NEW_IMAGE="${NEW_IMAGE:?NEW_IMAGE required}"
BACKUP_DIR="${BACKUP_DIR:?BACKUP_DIR required}"
PROBE_TARGETS="${PROBE_TARGETS:?PROBE_TARGETS required}"
PROBE_PATHS="${PROBE_PATHS:-/ /__nonexist_probe__}"
ROUNDS="${ROUNDS:-2}"
COMPOSE_CMD="${COMPOSE_CMD:-docker compose}"

mkdir -p "$BACKUP_DIR"

probe_one() {  # $1=base_url $2=server_name $3=path -> "code|location|md5"
    local url="$1$3" hdr
    hdr=$(mktemp)
    local out code loc md5
    out=$(curl -sS -o - -D "$hdr" -H "Host: $2" --max-time 10 "$url" || true)
    code=$(awk 'NR==1{print $2}' "$hdr" | tr -d '\r')
    loc=$(awk 'tolower($1)=="location:"{sub(/\r$/,"");print $2}' "$hdr" | head -1)
    md5=$(printf '%s' "$out" | md5sum | cut -d' ' -f1)
    rm -f "$hdr"
    printf '%s|%s|%s\n' "${code:-000}" "${loc:-}" "${md5:-}"
}

gate_key() {  # 2xx 比 code+md5; 3xx 只比 code+location
    local code="$1" rest="$2"
    case "$code" in
        2??) printf '2xx:%s:%s\n' "$code" "$rest" ;;
        3??) printf '3xx:%s\n' "$code" ;;
        *)   printf 'other:%s\n' "$code" ;;
    esac
}

probe_all() {  # $1=输出文件
    : > "$1"
    while read -r base sni; do
        [ -n "$base" ] || continue
        for p in $PROBE_PATHS; do
            line=$(probe_one "$base" "$sni" "$p")
            code="${line%%|*}"; rest="${line#*|}"
            printf '%s %s %s %s\n' "$base" "$sni" "$p" "$(gate_key "$code" "$rest")" >> "$1"
        done
    done < "$PROBE_TARGETS"
}

echo "== 0. 备份 compose =="
cp -p "$COMPOSE_FILE" "$BACKUP_DIR/docker-compose.yml.pre"
$COMPOSE_CMD -f "$COMPOSE_FILE" config > "$BACKUP_DIR/compose.resolved.pre" 2>/dev/null || true

echo "== 1. 基线探测（${ROUNDS} 轮，取一致项） =="
probe_all "$BACKUP_DIR/baseline.r1.txt"
sleep 5
probe_all "$BACKUP_DIR/baseline.r2.txt"
if ! diff -q "$BACKUP_DIR/baseline.r1.txt" "$BACKUP_DIR/baseline.r2.txt" >/dev/null; then
    echo "BASELINE UNSTABLE: 两轮不一致，中止且不做任何改动" >&2
    diff "$BACKUP_DIR/baseline.r1.txt" "$BACKUP_DIR/baseline.r2.txt" || true
    exit 2
fi
BASELINE="$BACKUP_DIR/baseline.r2.txt"

echo "== 2. 试运行容器（同挂载同网络）对比 =="
OLD_IMAGE=$($COMPOSE_CMD -f "$COMPOSE_FILE" config --format json 2>/dev/null \
    | python3 -c "import json,sys;c=json.load(sys.stdin);print(c['services']['$SERVICE']['image'])" 2>/dev/null \
    || grep -A5 "  $SERVICE:" "$COMPOSE_FILE" | grep image: | head -1 | awk '{print $2}')
echo "old=$OLD_IMAGE new=$NEW_IMAGE"
TRIAL_TAG="$SERVICE-trial-$(date +%s)"
# 用 run 起临时容器: 继承 service 的挂载/网络/环境，不进 DNS 与LB
$COMPOSE_CMD -f "$COMPOSE_FILE" run --no-deps --name "$TRIAL_TAG" -d "$SERVICE" "$NEW_IMAGE" \
    || { echo "trial container failed to start"; exit 3; }
TRIAL_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$TRIAL_TAG")
# 试运行容器内先过 nginx -t（新版本对旧配置）
docker exec "$TRIAL_TAG" nginx -t
sed "s#127.0.0.1#$TRIAL_IP#g" "$PROBE_TARGETS" > "$BACKUP_DIR/probe.targets.trial"
probe_all_trial() {
    : > "$BACKUP_DIR/trial.txt"
    while read -r base sni; do
        [ -n "$base" ] || continue
        for p in $PROBE_PATHS; do
            line=$(probe_one "$base" "$sni" "$p")
            code="${line%%|*}"; rest="${line#*|}"
            printf '%s %s %s %s\n' "$base" "$sni" "$p" "$(gate_key "$code" "$rest")" >> "$BACKUP_DIR/trial.txt"
        done
    done < "$BACKUP_DIR/probe.targets.trial"
}
probe_all_trial
if ! diff -q "$BASELINE" "$BACKUP_DIR/trial.txt" >/dev/null; then
    echo "TRIAL DIFF: 试运行与基线不一致，不切换" >&2
    diff "$BASELINE" "$BACKUP_DIR/trial.txt" || true
    docker rm -f "$TRIAL_TAG"; exit 4
fi
docker rm -f "$TRIAL_TAG"

echo "== 3. 切换（改镜像 + up -d --no-deps） =="
sed -i "s#image: ${OLD_IMAGE}#image: ${NEW_IMAGE}#g" "$COMPOSE_FILE"
$COMPOSE_CMD -f "$COMPOSE_FILE" up -d --no-deps "$SERVICE"

echo "== 4. 探测复查（门禁，失败自动回滚） =="
probe_all "$BACKUP_DIR/after.txt"
if ! diff -q "$BASELINE" "$BACKUP_DIR/after.txt" >/dev/null; then
    echo "GATE FAILED: 变更后与基线不一致，自动回滚" >&2
    diff "$BASELINE" "$BACKUP_DIR/after.txt" || true
    cp -p "$BACKUP_DIR/docker-compose.yml.pre" "$COMPOSE_FILE"
    $COMPOSE_CMD -f "$COMPOSE_FILE" up -d --no-deps "$SERVICE"
    probe_all "$BACKUP_DIR/after-rollback.txt"
    diff -q "$BASELINE" "$BACKUP_DIR/after-rollback.txt" >/dev/null \
        && echo "ROLLBACK OK" || echo "ROLLBACK VERIFY FAILED — 人工介入" >&2
    exit 5
fi

echo "== 5. 通过 =="
QID="$($COMPOSE_CMD -f "$COMPOSE_FILE" ps -q "$SERVICE")"
[ -n "$QID" ] && docker exec "$QID" nginx -v 2>&1 || true
echo "基线 N 项 = $(wc -l < "$BASELINE")，差异 0。备份: $BACKUP_DIR"
