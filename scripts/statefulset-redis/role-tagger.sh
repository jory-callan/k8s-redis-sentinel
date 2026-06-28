#!/bin/sh
# Role-tagger sidecar — PATCH pod label redis-role=master|slave
# Runs in Redis StatefulSet sidecar (curlimages/curl container)
# No 'set -e' (dash compatibility)

# ──────────────────────────────────────────────────────────────
# 脚本运行模式：死循环（持续运行）
# ──────────────────────────────────────────────────────────────
# 本脚本是 sidecar 容器的入口，以死循环方式持续运行：
# 1. 等待 redis 就绪（最多 60s）
# 2. 每 5s 查询一次 redis 角色
# 3. 仅角色变化时才 PATCH K8s API 更新 pod label
# 4. 每轮 touch 心跳文件（供 livenessProbe 检测）
#
# Shell 死循环可靠性说明：
# ✅ 可靠。K8s 对容器的管理方式：
#    - 容器进程 PID=1，如果死循环退出，容器会重启
#    - livenessProbe 检测心跳文件，防止死循环内部 hang
#    - sleep 5s 保证 CPU 消耗极低（几乎不占 CPU）
# ✅ 相比其他方案的优势：
#    - 比 cronjob 更及时（5s 间隔 vs cron 的最小 1min）
#    - 比 readinessProbe 更安静（不产生失败事件）
#    - 直接查 redis，不依赖 exporter 容器
#
# 关键设计：
# - 直接查 redis（curl telnet），不依赖 exporter 容器
# - 仅角色变化时才调用 K8s API（减少 etcd 压力）
# - 常态零 etcd 写入（只有 failover 时才 PATCH）
# ──────────────────────────────────────────────────────────────

hash -r 2>/dev/null || true

TOKEN="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
CACERT="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
NS="$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)"
APISERVER="https://kubernetes.default.svc"
ALIVE_FILE="/tmp/last_alive"

echo "[role-tagger] starting, pod=$POD_NAME ns=$NS"

AUTH_CMD=""
if [ -n "${REDIS_PASSWORD:-}" ]; then
  AUTH_CMD="AUTH ${REDIS_PASSWORD}\r\n"
fi

i=0
while [ "$i" -lt 30 ]; do
  if printf "${AUTH_CMD}PING\r\n" | curl -s --max-time 2 telnet://127.0.0.1:6379 2>/dev/null | grep -q PONG; then
    echo "[role-tagger] redis ready"
    break
  fi
  i=$((i+1)); sleep 2
done

INTERVAL="${INTERVAL_SECONDS:-5}"

LAST_ROLE=""
while true; do
  ROLE="$(printf "${AUTH_CMD}INFO replication\r\n" \
          | curl -s --max-time 3 telnet://127.0.0.1:6379 2>/dev/null \
          | grep '^role:' | head -1 | cut -d: -f2 | tr -d '[:space:]')"

  if [ "$ROLE" = "master" ] || [ "$ROLE" = "slave" ]; then
    if [ "$ROLE" != "$LAST_ROLE" ]; then
      HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' --cacert "$CACERT" -X PATCH \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/merge-patch+json" \
        --data "{\"metadata\":{\"labels\":{\"redis-role\":\"$ROLE\"}}}" \
        "$APISERVER/api/v1/namespaces/$NS/pods/$POD_NAME")"
      if [ "$HTTP_CODE" = "200" ]; then
        echo "[role-tagger] role=$ROLE (label updated, http=$HTTP_CODE)"
        LAST_ROLE="$ROLE"
      else
        echo "[role-tagger] role=$ROLE but patch failed http=$HTTP_CODE"
      fi
    fi
    : > "$ALIVE_FILE"
  else
    echo "[role-tagger] role unknown (empty?), skip"
  fi
  sleep "${INTERVAL}"
done