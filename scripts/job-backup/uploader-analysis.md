# uploader 容器分析文档

## 容器信息

| 项目 | 值 |
|------|-----|
| 容器名 | `uploader` |
| 镜像 | `rclone/rclone:latest` |
| 运行模式 | 单次执行（main container，执行完退出） |
| 脚本 | [uploader.sh](uploader.sh) |
| 进程 | `sh uploader.sh` |

## 核心职责

1. **配置验证**：检查 rclone 连接和 bucket 存在
2. **上传备份**：使用 rclone 将 gzipped RDB 上传到对象存储
3. **上传验证**：确认对象已成功上传
4. **清理旧备份**：删除超过 RETENTION_DAYS 的文件
5. **列出清单**：显示当前备份列表

## 执行流程

```
┌─────────────────────────────────────────────────────────────────────┐
│                      Uploader 执行流程                              │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  1. 配置验证                                                         │
│     └── rclone lsd dst: → 检查连接                                   │
│     └── rclone lsf "dst:${BUCKET}" → 检查 bucket 存在                │
│     └── 失败 → exit 1（CronJob 失败）                               │
│                                                                     │
│  2. 生成备份文件名                                                   │
│     └── OBJECT_NAME = <instance>-dump-YYYYMMDD-HHMMSS.rdb.gz        │
│                                                                     │
│  3. 上传备份                                                         │
│     └── rclone copyto /rdb/dump.rdb.gz "dst:${BUCKET}/${PREFIX}/..."│
│     └── copyto: 单文件到单目标（避免目录遍历语义）                    │
│     └── 失败 → exit 1（CronJob 失败）                               │
│                                                                     │
│  4. 上传验证                                                         │
│     └── rclone lsf "${REMOTE_PATH}" → 确认对象存在                   │
│     └── 失败 → exit 1（上传不完整）                                 │
│                                                                     │
│  5. 清理旧备份                                                       │
│     └── rclone delete "dst:${BUCKET}/${PREFIX}/" --min-age N天      │
│     └── 仅删除文件，不删除目录                                       │
│                                                                     │
│  6. 列出当前备份清单                                                  │
│     └── rclone lsf "dst:${BUCKET}/${PREFIX}/" | tail -10           │
│                                                                     │
│  7. 脚本退出（容器完成）                                              │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

## 稳定性设计

### 1. 无配置文件（环境变量驱动）

```bash
# rclone 默认会找 /config/rclone/rclone.conf 并报 NOTICE
# 创建空文件让 NOTICE 闭嘴（env 配置仍优先生效）
mkdir -p /config/rclone && : > /config/rclone/rclone.conf
```

**为什么稳定**：
- 通过环境变量配置，无需 rclone.conf 文件
- 环境变量命名规范：`RCLONE_CONFIG_DST_TYPE`, `RCLONE_CONFIG_DST_PROVIDER`, ...
- 支持 40+ 后端（S3/MinIO/阿里云 OSS/腾讯云 COS 等）
- 不绑定特定厂商，灵活切换

### 2. 连接和 bucket 验证

```bash
if ! rclone lsd dst: >/dev/null 2>&1; then
  echo "[error] cannot connect to object storage, check endpoint/credentials"
  exit 1
fi
if ! rclone lsf "dst:${BUCKET}" >/dev/null 2>&1; then
  echo "[error] bucket ${BUCKET} not found, please create it first"
  exit 1
fi
```

**为什么稳定**：
- 先验证连接，再上传
- 避免在连接失败的情况下浪费时间
- bucket 必须预创建（不自动创建，防止误操作）

### 3. copyto 单文件上传（非 copy）

```bash
if ! rclone copyto /rdb/dump.rdb.gz "${REMOTE_PATH}" 2>&1; then
  echo "[error] upload failed"
  exit 1
fi
```

**为什么稳定**：
- `copyto`：单文件到单目标，语义明确
- `copy`：目录到目录，可能产生意外行为
- 避免目录遍历，上传结果可预测

### 4. 上传验证

```bash
if ! rclone lsf "${REMOTE_PATH}" >/dev/null 2>&1; then
  echo "[error] upload verify failed, object not found"
  exit 1
fi
```

**为什么稳定**：
- 上传后验证对象存在
- 防止上传不完整或网络中断导致的损坏备份
- 如果验证失败，脚本退出，CronJob 标记失败

### 5. 保留策略（删除旧备份）

```bash
echo "[retention] removing backups older than ${RETENTION_DAYS}d under ${BUCKET}/${PREFIX}/"
rclone delete "dst:${BUCKET}/${PREFIX}/" --min-age "${RETENTION_DAYS}d" 2>&1 || true
```

**为什么稳定**：
- `--min-age N天`：只删除超过 N 天的文件
- `rclone delete`：仅删除文件，不删除目录
- `|| true`：即使删除失败也不影响主流程（可能是权限问题）
- 防止存储无限增长

### 6. 时间戳命名

```bash
TS=$(date -u +%Y%m%d-%H%M%S)
OBJECT_NAME="${INSTANCE_NAME}-dump-${TS}.rdb.gz"
```

**为什么稳定**：
- UTC 时间戳，避免时区问题
- 包含实例名，支持多实例隔离
- 格式：`<instance>-dump-YYYYMMDD-HHMMSS.rdb.gz`

## 可靠性评估

| 场景 | 行为 | 结果 |
|------|------|------|
| 正常执行 | 上传，验证，清理，退出 | ✅ CronJob 成功 |
| 连接失败 | lsd 失败，exit 1 | ✅ CronJob 失败 |
| bucket 不存在 | lsf 失败，exit 1 | ✅ CronJob 失败 |
| 上传失败 | copyto 失败，exit 1 | ✅ CronJob 失败 |
| 验证失败 | lsf 失败，exit 1 | ✅ 不接受不完整备份 |
| 删除失败 | `|| true` 忽略 | ✅ 主流程不受影响 |

## 总结

**uploader 容器的稳定性设计体现在**：

1. **环境变量配置**：无需配置文件，灵活支持多种后端
2. **连接验证**：先验证再上传，避免无效操作
3. **单文件上传**：`copyto` 语义明确，避免目录遍历
4. **上传验证**：确认对象存在，防止损坏备份
5. **保留策略**：自动清理旧备份，防止存储无限增长
6. **时间戳命名**：UTC 时间，多实例隔离

这是一个单次执行的脚本，执行完退出，由 CronJob 管理调度。失败时 CronJob 会记录日志并等待下次执行。