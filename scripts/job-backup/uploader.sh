#!/bin/sh
set -u
# Backup Phase 2: Uploader + Retention
# Runs in Backup CronJob main container (rclone image)
# Uploads to object storage and cleans up old backups

# ──────────────────────────────────────────────────────────────
# 脚本运行模式：单次执行（非死循环）
# ──────────────────────────────────────────────────────────────
# 本脚本是 CronJob main container 的入口，执行完上传后退出
# 执行流程：
# 1. 检查 rclone 配置（通过环境变量传入，无需 rclone.conf 文件）
# 2. 验证对象存储连接和 bucket 存在
# 3. 上传 gzipped RDB（单文件 copyto，避免目录遍历）
# 4. 验证上传成功（列出对象确认存在）
# 5. 清理旧备份（删除超过 RETENTION_DAYS 的文件）
# 6. 列出当前备份清单
#
# 设计要点：
# - 使用 rclone，支持 40+ 后端（S3/MinIO/阿里云 OSS/腾讯云 COS 等）
# - 通过环境变量配置，不绑定特定厂商
# - 命名规范: RCLONE_CONFIG_DST_TYPE, RCLONE_CONFIG_DST_PROVIDER, ...
# - 保留策略: --min-age 删除过期文件，不删除目录
# ──────────────────────────────────────────────────────────────

mkdir -p /config/rclone && : > /config/rclone/rclone.conf

if ! rclone lsd dst: >/dev/null 2>&1; then
  echo "[error] cannot connect to object storage, check endpoint/credentials"
  exit 1
fi
if ! rclone lsf "dst:${BUCKET}" >/dev/null 2>&1; then
  echo "[error] bucket ${BUCKET} not found, please create it first"
  exit 1
fi

TS=$(date -u +%Y%m%d-%H%M%S)
OBJECT_NAME="${INSTANCE_NAME}-dump-${TS}.rdb.gz"
REMOTE_PATH="dst:${BUCKET}/${PREFIX}/${OBJECT_NAME}"
echo "[upload] -> ${REMOTE_PATH}"

if ! rclone copyto /rdb/dump.rdb.gz "${REMOTE_PATH}" 2>&1; then
  echo "[error] upload failed"
  exit 1
fi

if ! rclone lsf "${REMOTE_PATH}" >/dev/null 2>&1; then
  echo "[error] upload verify failed, object not found"
  exit 1
fi

SIZE=$(rclone size "${REMOTE_PATH}" --json 2>/dev/null | grep -oE '"bytes":[0-9]+' | cut -d: -f2 || echo 0)
echo "[upload] ok, object=${OBJECT_NAME}, size=${SIZE} bytes"

echo "[retention] removing backups older than ${RETENTION_DAYS}d under ${BUCKET}/${PREFIX}/"
rclone delete "dst:${BUCKET}/${PREFIX}/" --min-age "${RETENTION_DAYS}d" 2>&1 || true

echo "[retention] current backups:"
rclone lsf "dst:${BUCKET}/${PREFIX}/" 2>&1 | tail -10