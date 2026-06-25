# 备份与恢复（CronJob → 对象存储）

## 功能概述

Chart 内置 **CronJob**，定时从 Redis master 拉取 RDB 快照，gzip 压缩后上传到对象存储（MinIO/S3/阿里云 OSS/腾讯云 COS 等 S3 兼容存储），并按保留天数自动清理旧备份。

- **零 Operator、零 PVC 冲突**：通过 `redis-cli --rdb` 经 master Service 拉取，不挂载 Redis PVC（避免 RWO 卷冲突）
- **不绑定特定厂商**：上传工具用 **rclone**（覆盖 S3/MinIO/阿里云 OSS/腾讯云 COS/Azure/GCS 等 40+ 后端，切换存储只改 `endpoint` + `provider`）
- **双容器分离**：`rdb-dumper`（redis 镜像）负责拉取压缩，`uploader`（rclone 镜像）负责上传与清理
- **多实例隔离**：备份对象路径默认以 `instanceName` 为前缀，同 bucket 多实例互不覆盖
- **凭证解耦**：对象存储凭证独立 Secret，可明文配置或引用已有 Secret
- **不依赖 role-tagger**：备份 Job 用默认 ServiceAccount，仅通过 Service 网络访问 Redis + 对象存储，不调用 K8s API

## 架构流程

```
┌─────────────────────────────────────────────────────────────┐
│  CronJob (schedule, e.g. 0 2 * * *)                          │
│                                                              │
│  ┌────────────────────┐      ┌──────────────────────────┐  │
│  │ init: rdb-dumper   │ →    │ main: uploader          │  │
│  │ image: redis:5.0.8 │      │ image: rclone/rclone    │  │
│  │                    │      │                         │  │
│  │ redis-cli --rdb    │      │ rclone copyto dump.rdb.gz│  │
│  │   via <inst>-master│      │   dst:<bucket>/<prefix>/ │  │
│  │   .svc.cluster.local│     │ rclone delete --min-age │  │
│  │ gzip → emptyDir    │      │   (保留策略)              │  │
│  └────────────────────┘      └──────────────────────────┘  │
│           ↑                              ↓                 │
│      <inst>-master                 对象存储 bucket          │
│      Service (role-tagger)        <bucket>/<inst>/         │
│      → 当前 master pod            <inst>-dump-<ts>.rdb.gz   │
└─────────────────────────────────────────────────────────────┘
```

**rclone 配置全部走环境变量**（无需 `rclone.conf` 文件）：

```
RCLONE_CONFIG_DST_TYPE=s3                    # 后端类型
RCLONE_CONFIG_DST_PROVIDER=Minio             # 厂商: Minio/AWS/Alibaba/Tencent/Ceph/Other
RCLONE_CONFIG_DST_ENDPOINT=http://...        # S3 兼容端点
RCLONE_CONFIG_DST_ACCESS_KEY_ID=...           # AK
RCLONE_CONFIG_DST_SECRET_ACCESS_KEY=...      # SK
RCLONE_CONFIG_DST_NO_CHECK_CERTIFICATE=true  # 自签名证书跳过校验 (可选)
```

访问语法统一为 `dst:<bucket>/<prefix>/<object>`。

**为什么用 `redis-cli --rdb` 而非直接拷 PVC 上的 dump.rdb**：
1. PVC 多为 RWO，Job 调度到的节点未必有卷；强制同节点会破坏 `podAntiAffinity`
2. `--rdb` 走 Redis 复制协议，始终从**当前 master**（Service 自动路由）拉取，failover 后仍正确
3. master fork 一次产生快照，是 Redis 备份的固有代价，与生产 RDB/AOF 持久化机制一致

**为什么用 rclone 而非 minio/mc**：
1. rclone 支持 40+ 后端（S3/MinIO/阿里云 OSS/腾讯云 COS/Azure Blob/GCS/本地/SFTP…），mc 仅 S3 兼容
2. rclone 不绑定特定厂商，切换存储只改 `endpoint` + `provider`，脚本零改动
3. rclone 镜像含完整 coreutils（awk/grep/cut 等），mc 镜像精简需绕开
4. rclone 原生支持保留策略（`rclone delete --min-age`），无需 `--exec` 拼接

## 配置参数（`values.yaml` → `backup`）

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `backup.enabled` | `false` | 是否启用备份 CronJob |
| `backup.schedule` | `"0 2 * * *"` | Cron 表达式（默认每天 02:00 UTC） |
| `backup.concurrencyPolicy` | `Forbid` | 上次未完成则跳过，避免并发备份 |
| `backup.historyLimit` | `3` | 保留的成功/失败 Job 数 |
| `backup.endpoint` | `http://minio.minio.svc.cluster.local:80` | 对象存储端点（集群内 MinIO 用 http） |
| `backup.provider` | `"Minio"` | rclone S3 backend 类型：`Minio` / `AWS` / `Alibaba` / `Tencent` / `Ceph` / `Other`（空=自动） |
| `backup.insecure` | `false` | 自签名 https 时设 `true`（等价 rclone `NO_CHECK_CERTIFICATE=true`） |
| `backup.bucket` | `"redis-test"` | 桶名（需**预先存在**，Job 不会创建桶） |
| `backup.prefix` | `""`（= instanceName） | 桶下子路径前缀，默认按实例隔离 |
| `backup.region` | `"us-east-1"` | S3 region |
| `backup.accessKey` | `"minioadmin"` | 明文 access key |
| `backup.secretKey` | `"minioadmin"` | 明文 secret key |
| `backup.existingSecret` | `""` | 引用已有 Secret（优先于明文，需含 `access-key`/`secret-key`） |
| `backup.retentionDays` | `7` | 超过 N 天的备份自动删除 |
| `backup.image` | `rclone/rclone:1.66.0` | 上传镜像 |
| `backup.dumperImage` | `redis:5.0.8` | RDB 拉取镜像（需含 `redis-cli`） |
| `backup.resources` | `cpu 50m / mem 64Mi` | Job 资源请求 |

### 切换存储后端示例

只需改 `endpoint` + `provider`，其他配置不变：

```bash
# MinIO (集群内)
--set backup.endpoint=http://minio.minio.svc.cluster.local:80 \
--set backup.provider=Minio

# 阿里云 OSS
--set backup.endpoint=https://oss-cn-hangzhou.aliyuncs.com \
--set backup.provider=Alibaba \
--set backup.region=cn-hangzhou

# 腾讯云 COS
--set backup.endpoint=https://cos.ap-shanghai.myqcloud.com \
--set backup.provider=Tencent \
--set backup.region=ap-shanghai

# AWS S3
--set backup.endpoint=https://s3.us-east-1.amazonaws.com \
--set backup.provider=AWS \
--set backup.region=us-east-1
```

## 启用备份

```bash
helm install my-app ./helm/redis-sentinel -n redis \
  --set common.instanceName=my-app \
  --set common.auth.password=<密码> \
  --set backup.enabled=true \
  --set backup.endpoint=http://minio.minio.svc.cluster.local:80 \
  --set backup.provider=Minio \
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
例: redis-test/my-app/my-app-dump-20260625-165354.rdb.gz
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

预期输出：

```
[upload] -> dst:redis-test/<inst>/<inst>-dump-20260625-165354.rdb.gz
[upload] ok, object=<inst>-dump-20260625-165354.rdb.gz, size=223 bytes
[retention] removing backups older than 7d under redis-test/<inst>/
[retention] current backups:
<inst>-dump-20260625-165248.rdb.gz
<inst>-dump-20260625-165354.rdb.gz
```

## 恢复流程

备份文件是标准 Redis RDB（gzip 压缩）。恢复 = 下载 → 解压 → 替换 `dump.rdb` → 启动 Redis。

### 方式一：恢复到新实例（推荐，零风险）

```bash
# 1. 用 rclone 下载最新备份到本地
kubectl run restore-<inst> --rm -i --restart=Never \
  --image=rclone/rclone:1.66.0 \
  --env=RCLONE_CONFIG_DST_TYPE=s3 \
  --env=RCLONE_CONFIG_DST_PROVIDER=Minio \
  --env=RCLONE_CONFIG_DST_ENDPOINT=http://minio.minio.svc.cluster.local:80 \
  --env=RCLONE_CONFIG_DST_REGION=us-east-1 \
  --env=RCLONE_CONFIG_DST_ACCESS_KEY_ID=<AK> \
  --env=RCLONE_CONFIG_DST_SECRET_ACCESS_KEY=<SK> \
  -- sh -c 'mkdir -p /config/rclone && : > /config/rclone/rclone.conf && \
            LATEST=$(rclone lsf "dst:<bucket>/<inst>/" | sort | tail -1) && \
            rclone copyto "dst:<bucket>/<inst>/${LATEST}" /tmp/dump.rdb.gz && \
            cat /tmp/dump.rdb.gz' > dump.rdb.gz

# 2. 解压
gunzip dump.rdb.gz

# 3. 用该 RDB 启动一个独立 Redis (数据校验)
docker run -d --name redis-restore -p 6380:6379 -v "$PWD/dump.rdb:/data/dump.rdb" redis:5.0.8
redis-cli -p 6380 -a <密码> DBSIZE   # 应与原库一致

# 4. 验证无误后, 部署新的 Helm 实例承接流量, 或迁移数据
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
cat > /tmp/rdb-check.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: rdb-check
  namespace: redis
spec:
  restartPolicy: Never
  initContainers:
  - name: download
    image: rclone/rclone:1.66.0
    env:
    - {name: RCLONE_CONFIG_DST_TYPE, value: s3}
    - {name: RCLONE_CONFIG_DST_PROVIDER, value: Minio}
    - {name: RCLONE_CONFIG_DST_ENDPOINT, value: "http://minio.minio.svc.cluster.local:80"}
    - {name: RCLONE_CONFIG_DST_REGION, value: "us-east-1"}
    - {name: RCLONE_CONFIG_DST_ACCESS_KEY_ID, value: <AK>}
    - {name: RCLONE_CONFIG_DST_SECRET_ACCESS_KEY, value: <SK>}
    command: ["sh","-c"]
    args:
    - |
      mkdir -p /config/rclone && : > /config/rclone/rclone.conf
      LATEST=$(rclone lsf "dst:<bucket>/<inst>/" | sort | tail -1)
      echo "downloading ${LATEST}"
      rclone copyto "dst:<bucket>/<inst>/${LATEST}" /shared/dump.rdb.gz
    volumeMounts:
    - {name: shared, mountPath: /shared}
  containers:
  - name: verify
    image: redis:5.0.8
    command: ["sh","-c"]
    args:
    - |
      gunzip -f /shared/dump.rdb.gz
      echo "magic:"; head -c 10 /shared/dump.rdb | od -c | head -1
      redis-check-rdb /shared/dump.rdb 2>&1 | tail -10
    volumeMounts:
    - {name: shared, mountPath: /shared}
  volumes:
  - {name: shared, emptyDir: {}}
EOF
kubectl apply -f /tmp/rdb-check.yaml
sleep 15
kubectl -n redis logs rdb-check -c verify
```

## 实测验证记录

在 3 节点 k3s 集群部署实例 `ftest`（master=ftest-0）写入 1 个 key (`test:key`) 后触发备份：

```
[dump] connecting master ftest-master.redis.svc.cluster.local:6379
[dump] pulling RDB...
[dump] rdb size=204 bytes
[dump] gzipped=223 bytes
[upload] -> dst:redis-test/ftest/ftest-dump-20260625-165354.rdb.gz
[upload] ok, object=ftest-dump-20260625-165354.rdb.gz, size=223 bytes
[retention] removing backups older than 7d under redis-test/ftest/
[retention] current backups:
ftest-dump-20260625-165248.rdb.gz
ftest-dump-20260625-165354.rdb.gz
```

恢复校验（rclone 下载 → `gunzip` → `redis-check-rdb`）：

```
[download] latest=ftest-dump-20260625-165354.rdb.gz
[restore] decompressed size=204 bytes
=== RDB magic ===
0000000   R   E   D   I   S   0   0   0   9 372     ← 标准 Redis 5 RDB 头
=== redis-check-rdb ===
[offset 151] AUX FIELD repl-id = '5b6004ba95b1de3760fb2bfc58b45c7ea013bdd9'
[offset 167] AUX FIELD aof-preamble = '0'
[offset 169] Selecting DB ID 0
[offset 204] Checksum OK
[offset 204] \o/ RDB looks OK! \o/
[info] 1 keys read                          ← 与写入数量一致
```

链路完整可用：拉取 → 压缩 → 上传 → 下载 → 解压 → 校验 → 数据完整。

## 注意事项

1. **bucket 必须预先存在**：CronJob 不创建桶，上传前会检查，不存在则报错退出。可用 `rclone mkdir dst:<bucket>` 或 `mc mb` 预建。
2. **自签名 https**：endpoint 用 `https://` 且证书未受信任时设 `backup.insecure=true`（等价 rclone `NO_CHECK_CERTIFICATE=true`）。集群内 `http://` 无需。
3. **大数据集超时**：`redis-cli --rdb` 外层包了 `timeout 600`（10 分钟）。数据集 >10GB 时按需调大或改用 `BGSAVE` + PVC 快照方案。
4. **failover 期间备份**：`concurrencyPolicy: Forbid` + Job 通过 master Service 访问。若备份进行中发生 failover，`--rdb` 会因连接断开失败，Job 重试（`backoffLimit: 2`）后到下次调度。不会产生损坏的 RDB。
5. **凭证安全**：明文 `accessKey`/`secretKey` 会进 Helm values 和 Secret。生产用 `existingSecret` 引用外部管理的 Secret。
6. **资源占用**：`rdb-dumper` 执行时 master 会 fork 一次（Redis 备份固有行为，非本方案特有）。Job 资源默认 `cpu 50m / mem 64Mi`，大数据集时按需上调。
7. **多实例隔离**：`prefix` 默认 `= instanceName`，同 bucket 多实例互不覆盖。如需统一前缀可显式设置。
8. **不绑定特定厂商**：用 rclone 替代 mc。切换存储后端只改 `endpoint` + `provider`，脚本零改动。已实测 MinIO；切阿里云 OSS/腾讯云 COS/AWS S3 只需替换这两个参数。
9. **master host 必须用 FQDN**：`<inst>-master.<ns>.svc.cluster.local`（不能用 `.svc` 短名，K8s DNS 解析会失败）。
