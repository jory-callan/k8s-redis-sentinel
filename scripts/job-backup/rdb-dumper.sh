#!/bin/sh
set -u
# Backup Phase 1: RDB dumper
# Runs in Backup CronJob initContainer (redis image)
# Pulls RDB from master via --rdb command

# ──────────────────────────────────────────────────────────────
# 脚本运行模式：单次执行（非死循环）
# ──────────────────────────────────────────────────────────────
# 本脚本是 CronJob initContainer 的入口，执行完 RDB 拉取后退出
# 执行流程：
# 1. 从 <instance>-master.svc 获取当前 master（自动路由）
# 2. AUTH 探活，确认 master 可达
# 3. redis-cli --rdb 拉取 RDB 快照（触发 master fork）
# 4. 验证 RDB 大小（防止空文件）
# 5. gzip 压缩（节省带宽与存储）
#
# 设计要点：
# - 通过 Service 访问 master，不直接操作 PVC（避免 RWO 冲突）
# - timeout 防止大数据集时 hang（最长 10 分钟）
# - 压缩后传给下一个容器（emptyDir 共享）
# ──────────────────────────────────────────────────────────────

MASTER_HOST="${INSTANCE_NAME}-master.${NAMESPACE}.svc.cluster.local"
echo "[dump] connecting master ${MASTER_HOST}:6379"

AUTH_ARGS=""
[ -n "${REDIS_PASSWORD:-}" ] && AUTH_ARGS="-a ${REDIS_PASSWORD}"
if ! redis-cli -h "${MASTER_HOST}" ${AUTH_ARGS} PING 2>/dev/null | grep -q PONG; then
  echo "[error] master ${MASTER_HOST} unreachable"
  exit 1
fi

echo "[dump] pulling RDB..."
if ! timeout 600 redis-cli -h "${MASTER_HOST}" ${AUTH_ARGS} --rdb /rdb/dump.rdb 2>/dev/null; then
  echo "[error] --rdb failed or timed out"
  exit 1
fi

SIZE=$(wc -c < /rdb/dump.rdb 2>/dev/null || echo 0)
echo "[dump] rdb size=${SIZE} bytes"
if [ "${SIZE}" -lt 10 ]; then
  echo "[error] rdb too small, aborting"
  exit 1
fi

gzip -f /rdb/dump.rdb
GZ_SIZE=$(wc -c < /rdb/dump.rdb.gz)
echo "[dump] gzipped=${GZ_SIZE} bytes"