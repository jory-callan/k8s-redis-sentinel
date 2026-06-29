#!/bin/sh
# Redis startup — decides master/slave role
# Runs in Redis StatefulSet initContainer (redis image)
# No 'set -e' (dash + local + $() = silent exit, see PITFALLS.md #1)

# ──────────────────────────────────────────────────────────────
# 脚本运行模式：单次执行（非死循环）
# ──────────────────────────────────────────────────────────────
# 本脚本是 Redis pod 的入口脚本，执行完决策逻辑后调用 exec redis-server
# 脚本本身只运行一次，redis-server 作为主进程接管后脚本退出
#
# 决策流程（四分支）：
# 1. 问 sentinel → 有 master → 验证可达 → 可达则跟随
# 2. 问 sentinel → 有 master → 验证失败 → fallback 到冷启动
# 3. 无 sentinel → ordinal=0 → 自举 master
# 4. 无 sentinel → ordinal>0 → 搜索任意 master（sentinel 重查 + DNS 扫描，永不自举）
#
# 防脑裂关键：ordinal>0 永不自举为 master，宁可 crash loop 也不脑裂
# ──────────────────────────────────────────────────────────────

NAMESPACE="${NAMESPACE:-redis}"
INSTANCE_NAME="${INSTANCE_NAME:-redis}"
ORDINAL="$(hostname | awk -F- '{print $NF}')"
MY_IP="${POD_IP:-$(hostname -i | awk '{print $1}')}"

# 动态 replicas 配置
# REDIS_REPLICAS: Redis StatefulSet 副本数（默认 3）
# SENTINEL_REPLICAS: Sentinel StatefulSet 副本数（默认 3）
REDIS_REPLICAS="${REDIS_REPLICAS:-3}"
SENTINEL_REPLICAS="${SENTINEL_REPLICAS:-3}"

REDIS_HL="${INSTANCE_NAME}-hl"
SENTINEL_HL="${INSTANCE_NAME}-sentinel-hl"

echo "[startup] instance=${INSTANCE_NAME} ordinal=${ORDINAL} ip=${MY_IP}"

cp /conf/redis.conf /data/redis.conf
sed -i "s/__ANNOUNCE_IP__/${MY_IP}/" /data/redis.conf

if [ -n "${REDIS_PASSWORD:-}" ]; then
  echo "requirepass ${REDIS_PASSWORD}" >> /data/redis.conf
  echo "masterauth ${REDIS_PASSWORD}"   >> /data/redis.conf
  echo "[auth] password set"
else
  echo "[auth] no password (insecure)"
fi

cli() {
  if [ -n "${REDIS_PASSWORD:-}" ]; then
    timeout 2 redis-cli -a "${REDIS_PASSWORD}" "$@" 2>/dev/null
  else
    timeout 2 redis-cli "$@" 2>/dev/null
  fi
}

get_master_from_sentinel() {
  i=0
  while [ "$i" -lt 5 ]; do
    i=$((i + 1))
    # 动态遍历所有 sentinel（从 0 到 SENTINEL_REPLICAS-1）
    # 使用 shell 算术扩展计算范围，兼容 dash
    sentinel_idx=0
    while [ "$sentinel_idx" -lt "$SENTINEL_REPLICAS" ]; do
      s="${INSTANCE_NAME}-sentinel-${sentinel_idx}"
      H="${s}.${SENTINEL_HL}.${NAMESPACE}.svc"
      IP="$(cli -h "${H}" -p 26379 SENTINEL get-master-addr-by-name mymaster 2>/dev/null | head -1)"
      if [ -n "${IP}" ] && [ "${IP}" != "nil" ]; then
        echo "${IP}"
        return 0
      fi
      sentinel_idx=$((sentinel_idx + 1))
    done
    sleep 3
  done
  return 1
}

# ── Quick sentinel check (single pass, no internal retries) ────
# 用于 cold-start 循环：每次迭代做一次快速检查，
# 而不是调用 get_master_from_sentinel（5 次重试 ~15s）。
get_master_from_sentinel_quick() {
  sentinel_idx=0
  while [ "$sentinel_idx" -lt "$SENTINEL_REPLICAS" ]; do
    s="${INSTANCE_NAME}-sentinel-${sentinel_idx}"
    H="${s}.${SENTINEL_HL}.${NAMESPACE}.svc"
    IP="$(cli -h "${H}" -p 26379 SENTINEL get-master-addr-by-name mymaster 2>/dev/null | head -1)"
    if [ -n "${IP}" ] && [ "${IP}" != "nil" ]; then
      echo "${IP}"
      return 0
    fi
    sentinel_idx=$((sentinel_idx + 1))
  done
  return 1
}

# ── Scan all redis pods via DNS for a master ────
# IP 无关：使用 StatefulSet 稳定 DNS 名，即使 pod IP 变化也能找到 master。
# 返回 DNS 主机名（不是 IP），redis-server 会在重连时重新解析。
scan_redis_for_master() {
  redis_idx=0
  while [ "$redis_idx" -lt "$REDIS_REPLICAS" ]; do
    # 跳过自己
    if [ "$redis_idx" -eq "$ORDINAL" ]; then
      redis_idx=$((redis_idx + 1))
      continue
    fi
    r="${INSTANCE_NAME}-${redis_idx}"
    H="${r}.${REDIS_HL}.${NAMESPACE}.svc"
    if cli -h "${H}" -p 6379 PING 2>/dev/null | grep -q PONG; then
      ROLE="$(cli -h "${H}" -p 6379 ROLE 2>/dev/null | head -1)"
      if [ "${ROLE}" = "master" ]; then
        echo "${H}"
        return 0
      fi
    fi
    redis_idx=$((redis_idx + 1))
  done
  return 1
}

MASTER_IP="$(get_master_from_sentinel)"

if [ -n "${MASTER_IP}" ]; then
  MASTER_REACHABLE=0
  i=0
  while [ "$i" -lt 5 ]; do
    i=$((i + 1))
    if [ "${MASTER_IP}" = "${MY_IP}" ]; then
      MASTER_REACHABLE=1
      break
    fi
    if cli -h "${MASTER_IP}" -p 6379 PING 2>/dev/null | grep -q PONG; then
      MASTER_REACHABLE=1
      break
    fi
    echo "[warn] master ${MASTER_IP} unreachable, retrying sentinel..."
    sleep 3
    NEW_IP="$(get_master_from_sentinel)"
    [ -n "${NEW_IP}" ] && MASTER_IP="${NEW_IP}"
  done

  if [ "${MASTER_REACHABLE}" = "1" ]; then
    if [ "${MASTER_IP}" = "${MY_IP}" ]; then
      echo "[role] master (sentinel confirmed)"
      exec redis-server /data/redis.conf
    else
      echo "[role] slave of ${MASTER_IP} (sentinel)"
      exec redis-server /data/redis.conf --slaveof "${MASTER_IP}" 6379
    fi
  else
    echo "[warn] sentinel master ${MASTER_IP} unreachable after retries, fallback to cold start"
  fi
fi

if [ "${ORDINAL}" = "0" ]; then
  echo "[role] master (cold start, ordinal=0)"
  exec redis-server /data/redis.conf
fi

# ordinal > 0: find any available master (NEVER self-promote — prevents split-brain)
# Three strategies in priority order:
#   1. Re-check sentinel (quick single pass — may have completed failover during restart)
#   2. Scan all redis pods via DNS (handles IP changes, stale sentinel data)
#   3. Retry loop (wait for any master to appear, including redis-0 self-bootstrap)
echo "[cold] ordinal=${ORDINAL}, searching for master..."
i=0
while [ "$i" -lt 30 ]; do
  i=$((i + 1))

  # Strategy 1: Quick sentinel re-check
  MASTER_IP_QUICK="$(get_master_from_sentinel_quick)"
  if [ -n "${MASTER_IP_QUICK}" ]; then
    if [ "${MASTER_IP_QUICK}" = "${MY_IP}" ]; then
      echo "[cold] sentinel says I am master"
      exec redis-server /data/redis.conf
    fi
    if cli -h "${MASTER_IP_QUICK}" -p 6379 PING 2>/dev/null | grep -q PONG; then
      echo "[cold] found master via sentinel: ${MASTER_IP_QUICK}"
      exec redis-server /data/redis.conf --slaveof "${MASTER_IP_QUICK}" 6379
    fi
  fi

  # Strategy 2: Scan all redis pods via DNS (IP-independent)
  MASTER_HOST="$(scan_redis_for_master)"
  if [ -n "${MASTER_HOST}" ]; then
    echo "[cold] found master via scan: ${MASTER_HOST}"
    exec redis-server /data/redis.conf --slaveof "${MASTER_HOST}" 6379
  fi

  sleep 2
done

# Cannot find any master — crash (K8s restarts). Do NOT become standalone master.
echo "[error] cannot find master after 60s, exiting"
exit 1