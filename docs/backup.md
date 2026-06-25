# 备份与恢复（CronJob → MinIO/S3）

## 功能概述

Chart 内置 **CronJob**，定时从 Redis master 拉取 RDB 快照，gzip 压缩后上传到 MinIO/S3 对象存储，并按保留天数自动清理旧备份。

- **零 Operator、零 PVC 冲突**：通过 `redis-cli --rdb` 经 master Service 拉取，不挂载 Redis PVC（避免 RWO 卷冲突）
- **双容器分离**：`rdb-dumper`（redis 镜像）负责拉取压缩，`uploader`（minio/mc 镜像）负责上传与清理
- **多实例隔离**：备份对象路径默认以 `instanceName` 为前缀，同 bucket 多实例互不覆盖
- **凭证解耦**：MinIO 凭证独立 Secret，可明文配置或引用已有 Secret
- **不依赖 role-tagger**：备份 Job 用默认 ServiceAccount，仅通过 Service 网络访问 Redis + 对象存储，不调用 K8s API

## 架构流程

```
┌─────────────────────────────────────────────────────────────┐
│  CronJob (schedule, e.g. 0 2 * * *)                          │
│                                                              │
│  ┌────────────────────┐      ┌──────────────────────────┐  │
│  │ init: rdb-dumper   │ →    │ main: uploader          │  │
│  │ image: redis:5.0.8 │      │ image: minio/mc         │  │
│  │                    │      │                         │  │
│  │ redis-cli --rdb    │      │ mc alias set            │  │
│  │   via <inst>-master│      │ mc cp dump.rdb.gz       │  │
│  │   .svc.cluster.local│     │ mc find --older-than    │  │
│  │ gzip → emptyDir    │      │   --exec "mc rm {}"     │  │
│  └────────────────────┘      └──────────────────────────┘  │
│           ↑                              ↓                 │
│      <inst>-master                 MinIO bucket             │
│      Service (role-tagger)        redis-test/<inst>/        │
│      → 当前 master pod            <inst>-dump-<ts>.rdb.gz   │
└─────────────────────────────────────────────────────────────┘
```

**为什么用 `redis-cli --rdb` 而非直接拷 PVC 上的 dump.rdb**：
1. PVC 多为 RWO，Job 调度到的节点未必有卷；强制同节点会破坏 `podAntiAffinity`
2. `--rdb` 走 Redis 复制协议，始终从**当前 master**（Service 自动路由）拉取，failover 后仍正确
3. master fork 一次产生快照，是 Redis 备份的固有代价，与生产 RDB/AOF 持久化机制一致

## 配置参数（`values.yaml` → `backup`）

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `backup.enabled` | `false` | 是否启用备份 CronJob |
| `backup.schedule` | `"0 2 * * *"` | Cron 表达式（默认每天 02:00 UTC） |
| `backup.concurrencyPolicy` | `Forbid` | 上次未完成则跳过，避免并发备份 |
| `backup.historyLimit` | `3` | 保留的成功/失败 Job 数 |
| `backup.endpoint` | `http://minio.minio.svc.cluster.local:80` | MinIO/S3 端点（集群内用 http） |
| `backup.insecure` | `false` | 外部 https 自签名证书时设 `true`（mc `--insecure`） |
| `backup.bucket` | `"redis-test"` | 桶名（需**预先存在**，Job 不会创建桶） |
| `backup.prefix` | `""`（= instanceName） | 桶下子路径前缀，默认按实例隔离 |
| `backup.region` | `"us-east-1"` | S3 region |
| `backup.accessKey` | `"minioadmin"` | 明文 access key |
| `backup.secretKey` | `"minioadmin"` | 明文 secret key |
| `backup.existingSecret` | `""` | 引用已有 Secret（优先于明文，需含 `access-key`/`secret-key`） |
| `backup.retentionDays` | `7` | 超过 N 天的备份自动删除 |
| `backup.image` | `minio/mc:RELEASE.2024-01-11T05-49-32Z` | 上传镜像（需含 `mc`） |
| `backup.dumperImage` | `redis:5.0.8` | RDB 拉取镜像（需含 `redis-cli`） |
| `backup.resources` | `cpu 50m / mem 64Mi` | Job 资源请求 |

## 启用备份

```bash
helm install my-app ./helm/redis-sentinel -n redis \
  --set common.instanceName=my-app \
  --set common.auth.password=<密码> \
  --set backup.enabled=true \
  --set backup.endpoint=http://minio.minio.svc.cluster.local:80 \
  --set backup.bucket=redis-test \
  --set backup.accessKey=minioadmin \
  --set backup.secretKey=minioadmin \
  --set backup.retentionDays=7
```

**生产建议**：用 `existingSecret` 引用外部管理的凭证，避免明文进 values：

```bash
kubectl -n redis create secret generic my-app-backup-secret \
  --from-literal=access-key=<AK> --from-literal=secret-key=<SK>

helm install my-app ./helm/redis-sentinel -n redis \
  --set backup.enabled=true \
  --set backup.existingSecret=my-app-backup-secret ...
```

## 备份对象路径

```
<bucket>/<prefix>/<instanceName>-dump-<UTC时间戳>.rdb.gz
例: redis-test/my-app/my-app-dump-20260625-162457.rdb.gz
```

时间戳格式 `YYYYMMDD-HHMMSS`（UTC）。多实例默认按 `instanceName` 前缀隔离，互不覆盖。

## 手动触发备份

不等调度，立即跑一次：

```bash
kubectl -n redis create job --from=cronjob/<inst>-backup <inst>-backup-manual-1
```

查看执行：

```bash
kubectl -n redis logs job/<inst>-backup-manual-1 -c uploader
```

## 恢复流程

备份文件是标准 Redis RDB（gzip 压缩）。恢复 = 下载 → 解压 → 替换 `dump.rdb` → 启动 Redis。

### 方式一：恢复到新实例（推荐，零风险）

```bash
# 1. 下载并解压最新备份
kubectl run restore-<inst> --rm -i --restart=Never --image=minio/mc:RELEASE.2024-01-11T05-49-32Z \
  -- sh -c 'mc alias set src http://minio.minio.svc.cluster.local:80 <AK> <SK> && \
            mc cp src/<bucket>/<inst>/<inst>-dump-<ts>.rdb.gz /tmp/dump.rdb.gz && \
            gunzip /tmp/dump.rdb.gz && cat /tmp/dump.rdb' > dump.rdb

# 2. 用该 RDB 启动一个独立 Redis（数据校验）
docker run -d --name redis-restore -p 6380:6379 -v "$PWD/dump.rdb:/data/dump.rdb" redis:5.0.8
redis-cli -p 6380 -a <密码> DBSIZE   # 应与原库一致

# 3. 验证无误后, 部署新的 Helm 实例承接流量, 或迁移数据
```

### 方式二：原地恢复（需停写）

> 仅在数据损坏需回滚时使用。会中断写入。

```bash
# 1. 停止 Redis StatefulSet (或缩容到 0)
kubectl -n redis scale statefulset <inst> --replicas=0

# 2. 对每个 PVC: 下载备份覆盖 dump.rdb (路径通常 /data/dump.rdb)
#    通过临时 pod 挂载 PVC 操作, 略

# 3. 恢复 StatefulSet, ordinal=0 加载 dump.rdb 自举为 master
kubectl -n redis scale statefulset <inst> --replicas=3
```

### 校验备份有效性

无需恢复整个实例，用 `redis-check-rdb` 快速校验：

```bash
kubectl run rdb-check --rm -i --restart=Never --image=minio/mc:RELEASE.2024-01-11T05-49-32Z \
  -- sh -c 'mc alias set src http://minio.minio.svc.cluster.local:80 <AK> <SK> && \
            mc cp src/<bucket>/<inst>/<最新备份>.rdb.gz /tmp/x.rdb.gz' \
  > /tmp/x.rdb.gz

# 解压 + redis-check-rdb
gunzip /tmp/x.rdb.gz
redis-check-rdb /tmp/x.rdb   # 应输出 "\o/ RDB looks OK! \o/" 与 keys 数
```

## 实测验证记录

在 3 节点 k3s 集群部署实例 `bktest`（master=bktest-0）写入 5 个 key 后触发备份：

```
[dump] connecting master bktest-master.redis.svc.cluster.local:6379
[dump] pulling RDB...
[dump] rdb size=236 bytes
[dump] gzipped=235 bytes
[upload] -> redis-test/bktest/bktest-dump-20260625-162457.rdb.gz
[upload] ok, object=redis-test/bktest/bktest-dump-20260625-162457.rdb.gz
[retention] current backups:
[2026-06-25 16:24:57 UTC]   236B STANDARD bktest-dump-20260625-162457.rdb.gz
```

恢复校验（拉回 → `gunzip` → `redis-check-rdb`）：

```
=== RDB 头 (magic) ===
0000000   R   E   D   I   S   0   0   0   9 372     ← 标准 Redis 5 RDB 头
=== redis-check-rdb 校验 ===
[offset 167] AUX FIELD aof-preamble = '0'
[offset 169] Selecting DB ID 0
[offset 241] Checksum OK
[offset 241] \o/ RDB looks OK! \o/
[info] 5 keys read                          ← 与写入数量一致
```

链路完整可用：拉取 → 压缩 → 上传 → 下载 → 解压 → 校验 → 数据完整。

## 注意事项

1. **bucket 必须预先存在**：CronJob 不创建桶，上传前会检查，不存在则报错退出。MinIO 桶可用 `mc mb` 预建。
2. **自签名 https**：若 endpoint 用 `https://` 且证书未受信任，设 `backup.insecure=true`（等价 `mc --insecure`）。集群内 `http://` 无需。
3. **大数据集超时**：`redis-cli --rdb` 外层包了 `timeout 600`（10 分钟）。数据集 >10GB 时按需调大或改用 `BGSAVE` + PVC 快照方案。
4. **failover 期间备份**：`concurrencyPolicy: Forbid` + Job 通过 master Service 访问。若备份进行中发生 failover，`--rdb` 会因连接断开失败，Job 重试（`backoffLimit: 2`）后到下次调度。不会产生损坏的 RDB。
5. **凭证安全**：明文 `accessKey`/`secretKey` 会进 Helm values 和 Secret。生产用 `existingSecret` 引用外部管理的 Secret。
6. **资源占用**：`rdb-dumper` 执行时 master 会 fork 一次（Redis 备份固有行为，非本方案特有）。Job 资源默认 `cpu 50m / mem 64Mi`，大数据集时按需上调。
7. **多实例隔离**：`prefix` 默认 `= instanceName`，同 bucket 多实例互不覆盖。如需统一前缀可显式设置。
