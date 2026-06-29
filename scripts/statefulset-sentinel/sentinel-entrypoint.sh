#!/bin/sh
# Sentinel entrypoint — discovers master and starts monitoring
# Runs in Sentinel StatefulSet (redis image with sentinel mode)
# No 'set -e' (dash compatibility, see PITFALLS.md #1)

# ──────────────────────────────────────────────────────────────
# 脚本运行模式：单次执行（非死循环）
# ──────────────────────────────────────────────────────────────
# 本脚本是 Sentinel pod 的入口脚本，执行完发现逻辑后调用 exec redis-sentinel
# 脚本本身只运行一次，redis-sentinel 作为主进程接管后脚本退出
#
# 发现流程：
# 1. 询问其他 sentinel 获取 master IP
# 2. 验证 master IP 可达性（防全集群重启时的旧 IP）
# 3. 如果 sentinel 没有信息，扫描 redis pod 查找 ROLE=master
# 4. 等待 master 就绪（最多 60s）
# 5. 生成 sentinel.conf 并启动 redis-sentinel
#
# 关键设计：
# - 全集群重启时，sentinel 可能从持久化配置中读取到旧的 master IP
# - 因此必须验证 master IP 可达性，不可达则扫描 redis pod
# - 不 fallback 到 127.0.0.1（会导致 sentinel 监控自己，死锁）
# ──────────────────────────────────────────────────────────────

NAMESPACE="${NAMESPACE:-redis}"
INSTANCE_NAME="${INSTANCE_NAME:-redis}"
MY_IP="${POD_IP:-$(hostname -i | awk '{print $1}')}"

# 动态 replicas 配置
# REDIS_REPLICAS: Redis StatefulSet 副本数（默认 3）
# SENTINEL_REPLICAS: Sentinel StatefulSet 副本数（默认 3）
REDIS_REPLICAS="${REDIS_REPLICAS:-3}"
SENTINEL_REPLICAS="${SENTINEL_REPLICAS:-3}"

REDIS_HL="${INSTANCE_NAME}-hl"
SENTINEL_HL="${INSTANCE_NAME}-sentinel-hl"

echo "[sentinel] instance=${INSTANCE_NAME} ip=${MY_IP}"

cli() {
  if [ -n "${REDIS_PASSWORD:-}" ]; then
    timeout 2 redis-cli -a "${REDIS_PASSWORD}" "$@" 2>/dev/null
  else
    timeout 2 redis-cli "$@" 2>/dev/null
  fi
}

find_master() {
  # 动态遍历所有 sentinel（从 0 到 SENTINEL_REPLICAS-1）
  sentinel_idx=0
  while [ "$sentinel_idx" -lt "$SENTINEL_REPLICAS" ]; do
    s="${INSTANCE_NAME}-sentinel-${sentinel_idx}"
    H="${s}.${SENTINEL_HL}.${NAMESPACE}.svc"
    IP="$(cli -h "${H}" -p 26379 SENTINEL get-master-addr-by-name mymaster 2>/dev/null | head -1)"
    if [ -n "${IP}" ] && [ "${IP}" != "nil" ]; then
      if cli -h "${IP}" -p 6379 PING 2>/dev/null | grep -q PONG; then
        echo "${IP}"
        return 0
      fi
    fi
    sentinel_idx=$((sentinel_idx + 1))
  done

  # 动态遍历所有 redis pod（从 0 到 REDIS_REPLICAS-1）
  redis_idx=0
  while [ "$redis_idx" -lt "$REDIS_REPLICAS" ]; do
    r="${INSTANCE_NAME}-${redis_idx}"
    H="${r}.${REDIS_HL}.${NAMESPACE}.svc"
    ROLE="$(cli -h "${H}" -p 6379 ROLE 2>/dev/null | head -1)"
    if [ "${ROLE}" = "master" ]; then
      IP="$(getent hosts "${H}" 2>/dev/null | awk '{print $1}')"
      if [ -n "${IP}" ]; then
        echo "${IP}"
        return 0
      fi
    fi
    redis_idx=$((redis_idx + 1))
  done
  return 1
}

MASTER_IP=""
i=0
while [ "$i" -lt 20 ]; do
  i=$((i + 1))
  MASTER_IP="$(find_master)" && break
  sleep 3
done

if [ -z "${MASTER_IP}" ]; then
  echo "[cold] no master found, defaulting to ${INSTANCE_NAME}-0"
  MASTER_IP="$(getent hosts "${INSTANCE_NAME}-0.${REDIS_HL}.${NAMESPACE}.svc" 2>/dev/null | awk '{print $1}')"
  if [ -z "${MASTER_IP}" ]; then
    echo "[error] cannot resolve ${INSTANCE_NAME}-0, exiting (will retry on restart)"
    exit 1
  fi
fi

echo "[sentinel] monitoring ${MASTER_IP}:6379"

# Clean up stale sentinel.conf entries to avoid ghost slaves
# When redis pod restarts with new IP, old 'sentinel known-slave' entries
# remain in persistent sentinel.conf, causing slave count to grow indefinitely.
# Delete old known-slave entries before generating new config.
if [ -f /data/sentinel.conf ]; then
  OLD_SLAVES=$(grep -c '^sentinel known-slave mymaster' /data/sentinel.conf 2>/dev/null || echo 0)
  if [ "${OLD_SLAVES}" -gt 0 ]; then
    echo "[sentinel] cleaning ${OLD_SLAVES} stale known-slave entries from sentinel.conf"
    sed -i '/^sentinel known-slave mymaster/d' /data/sentinel.conf
  fi
fi

{
  echo "port 26379"
  echo "daemonize no"
  echo "pidfile /data/sentinel.pid"
  echo 'logfile ""'
  echo "dir /data"
  echo "protected-mode no"
  echo "sentinel monitor mymaster ${MASTER_IP} 6379 ${QUORUM:-2}"
  echo "sentinel announce-ip ${MY_IP}"
  echo "sentinel announce-port 26379"
  echo "sentinel down-after-milliseconds mymaster 1000"
  echo "sentinel failover-timeout mymaster 5000"
  echo "sentinel parallel-syncs mymaster 1"
  if [ -n "${REDIS_PASSWORD:-}" ]; then
    echo "requirepass ${REDIS_PASSWORD}"
    echo "sentinel auth-pass mymaster ${REDIS_PASSWORD}"
  fi
} > /data/sentinel.conf

exec redis-sentinel /data/sentinel.conf