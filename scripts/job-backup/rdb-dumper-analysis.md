# rdb-dumper 容器分析文档

## 容器信息

| 项目 | 值 |
|------|-----|
| 容器名 | `rdb-dumper` |
| 镜像 | `redis:5.0.8` |
| 运行模式 | 单次执行（initContainer，执行完退出） |
| 脚本 | [rdb-dumper.sh](rdb-dumper.sh) |
| 进程 | `sh rdb-dumper.sh` |

## 核心职责

1. **连接 master**：通过 `<instance>-master.svc` 服务访问当前 master
2. **探活验证**：AUTH + PING 确认 master 可达
3. **拉取 RDB**：`redis-cli --rdb` 从 master 拉取快照（触发 master fork）
4. **大小验证**：检查 RDB 文件大小，防止空文件
5. **压缩**：gzip 压缩，节省带宽与存储

## 执行流程

```
┌─────────────────────────────────────────────────────────────────────┐
│                      RDB Dumper 执行流程                            │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  1. 通过 Service 获取 master                                        │
│     MASTER_HOST = <instance>-master.<namespace>.svc.cluster.local  │
│                                                                     │
│  2. 探活验证（AUTH + PING）                                          │
│     └── 不可达 → exit 1（CronJob 失败）                             │
│                                                                     │
│  3. redis-cli --rdb /rdb/dump.rdb                                  │
│     └── 触发 master fork，拉取 RDB 快照                             │
│     └── timeout 600 秒防止大数据集 hang                             │
│     └── 失败 → exit 1（CronJob 失败）                              │
│                                                                     │
│  4. 大小验证                                                        │
│     └── SIZE < 10 bytes → exit 1（空文件）                         │
│                                                                     │
│  5. gzip 压缩                                                       │
│     └── /rdb/dump.rdb → /rdb/dump.rdb.gz                           │
│                                                                     │
│  6. 脚本退出（initContainer 完成）                                   │
│     └── 下一容器（uploader）开始执行                                 │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

## 稳定性设计

### 1. 通过 Service 访问 master（不直接操作 PVC）

```bash
MASTER_HOST="${INSTANCE_NAME}-master.${NAMESPACE}.svc.cluster.local"
```

**为什么稳定**：
- `<instance>-master.svc` 自动路由到当前 master（role-tagger 维护 redis-role=master label）
- 不直接操作 PVC（避免 RWO 卷冲突）
- 即使 master 切换，Service 自动更新，无需修改脚本

### 2. 探活验证

```bash
AUTH_ARGS=""
[ -n "${REDIS_PASSWORD:-}" ] && AUTH_ARGS="-a ${REDIS_PASSWORD}"
if ! redis-cli -h "${MASTER_HOST}" ${AUTH_ARGS} PING 2>/dev/null | grep -q PONG; then
  echo "[error] master ${MASTER_HOST} unreachable"
  exit 1
fi
```

**为什么稳定**：
- 先验证 master 可达，再执行 --rdb
- 避免在不可达的 master 上浪费时间
- 密码参数通过环境变量传入，不硬编码

### 3. timeout 保护（大数据集）

```bash
if ! timeout 600 redis-cli -h "${MASTER_HOST}" ${AUTH_ARGS} --rdb /rdb/dump.rdb 2>/dev/null; then
  echo "[error] --rdb failed or timed out"
  exit 1
fi
```

**为什么稳定**：
- `timeout 600` 限制最长等待 10 分钟
- 防止大数据集时 redis-cli hang 住
- 如果超时，脚本退出，CronJob 标记失败

### 4. 大小验证（防空文件）

```bash
SIZE=$(wc -c < /rdb/dump.rdb 2>/dev/null || echo 0)
echo "[dump] rdb size=${SIZE} bytes"
if [ "${SIZE}" -lt 10 ]; then
  echo "[error] rdb too small, aborting"
  exit 1
fi
```

**为什么稳定**：
- RDB 文件最小也有几十字节（头部信息）
- 如果 SIZE < 10，说明下载失败或文件损坏
- 不上传空文件或损坏文件

### 5. gzip 压缩

```bash
gzip -f /rdb/dump.rdb
GZ_SIZE=$(wc -c < /rdb/dump.rdb.gz)
echo "[dump] gzipped=${GZ_SIZE} bytes"
```

**为什么稳定**：
- RDB 文件通常能压缩 50-70%
- 减少上传时间和存储成本
- `-f` 强制覆盖（防止已有文件）

## 可靠性评估

| 场景 | 行为 | 结果 |
|------|------|------|
| 正常执行 | 拉取 RDB，压缩，退出 | ✅ initContainer 完成，uploader 开始 |
| master 不可达 | PING 失败，exit 1 | ✅ CronJob 失败，等待下次执行 |
| --rdb 超时 | timeout 触发，exit 1 | ✅ CronJob 失败，等待下次执行 |
| RDB 文件太小 | SIZE < 10，exit 1 | ✅ 不上传空文件 |
| gzip 失败 | 脚本退出，exit 1 | ✅ CronJob 失败 |

## 总结

**rdb-dumper 容器的稳定性设计体现在**：

1. **Service 路由**：通过 `<instance>-master.svc` 访问，自动跟随 master 切换
2. **探活验证**：先 PING 再 --rdb，避免无效操作
3. **超时保护**：`timeout 600` 防止大数据集 hang
4. **大小验证**：防止空文件或损坏文件上传
5. **压缩优化**：gzip 减少带宽和存储

这是一个单次执行的脚本，执行完退出，由 CronJob 管理调度。失败时 CronJob 会记录日志并等待下次执行。