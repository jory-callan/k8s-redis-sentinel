# 07 - 备份与恢复（CronJob → 对象存储）

CronJob 定时从 master 拉取 RDB 快照，gzip 压缩后上传到对象存储（MinIO/S3/阿里云 OSS/腾讯云 COS 等），并按保留天数自动清理旧备份。

## 架构设计

```
┌─────────────────────────────────────────────────────────────┐
│  CronJob (schedule: 0 2 * * *, concurrencyPolicy: Forbid)   │
│                                                              │
│  ┌────────────────────┐      ┌──────────────────────────┐   │
│  │ init: rdb-dumper   │ →    │ main: uploader           │   │
│  │ image: redis:5.0.8 │      │ image: rclone/rclone:1.66 │   │
│  │                    │      │                          │   │
│  │ redis-cli --rdb    │      │ rclone copyto dump.rdb.gz │   │
│  │   via <inst>-master│      │   dst:<bucket>/<prefix>/  │   │
│  │   .svc.cluster.local│     │ rclone delete --min-age   │   │
│  │ gzip → emptyDir    │      │   (保留策略)              │   │
│  └─────────┬──────────┘      └──────────┬───────────────┘   │
│            ↑                             ↓                  │
│       <inst>-master                对象存储 bucket          │
│       Service (role-tagger)        <bucket>/<inst>/         │
│       → 当前 master pod            <inst>-dump-<ts>.rdb.gz  │
└─────────────────────────────────────────────────────────────┘
```

**核心设计**：
1. **零 PVC 冲突**：通过 `redis-cli --rdb` 经 master Service 拉取，不挂载 Redis PVC（避免 RWO 卷冲突 + podAntiAffinity 破坏）
2. **双容器分离**：`rdb-dumper`（redis 镜像，含 redis-cli）+ `uploader`（rclone 镜像，覆盖 40+ 后端）
3. **不绑定特定厂商**：用 **rclone** 替代 minio/mc，支持 S3/MinIO/阿里云 OSS/腾讯云 COS/Azure/GCS 等 40+ 后端，切换存储只改 `endpoint` + `provider`
4. **凭证解耦**：独立 Secret，可明文或引用已有 Secret
5. **不依赖 role-tagger**：备份 Job 用默认 SA，仅通过 Service 网络访问 Redis + 对象存储，不调 K8s API
6. **failover 安全**：`concurrencyPolicy: Forbid` + Job 通过 master Service 访问。failover 时 `--rdb` 失败 → Job 重试 → 下次调度

**为什么用 rclone 而非 mc**：
1. rclone 支持 40+ 后端（mc 仅 S3 兼容），切换存储零脚本改动
2. rclone 不绑定 MinIO 生态，未来换 OSS/COS/AWS S3 只改 `endpoint`+`provider`
3. rclone 镜像含完整 coreutils（awk/grep/cut 等），mc 镜像精简需绕开
4. rclone 原生支持保留策略（`rclone delete --min-age`），无需 `--exec` 拼接

## 实现设计

### 涉及文件

| 文件 | 作用 |
|------|------|
| [helm/redis-sentinel/templates/backup-cronjob.yaml](../helm/redis-sentinel/templates/backup-cronjob.yaml) | CronJob（双容器：rdb-dumper + uploader） |
| [helm/redis-sentinel/templates/backup-secret.yaml](../helm/redis-sentinel/templates/backup-secret.yaml) | 对象存储凭证 Secret |
| [helm/redis-sentinel/templates/_helpers.tpl](../helm/redis-sentinel/templates/_helpers.tpl) | `backupSecretName` helper |

### rdb-dumper 脚本（initContainer）

```sh
set -u
MASTER_HOST="${INSTANCE_NAME}-master.${NAMESPACE}.svc.cluster.local"  # FQDN 必须
AUTH_ARGS=""
[ -n "${REDIS_PASSWORD:-}" ] && AUTH_ARGS="-a ${REDIS_PASSWORD}"

# 1. AUTH 探活, 确认 master 可达
redis-cli -h "${MASTER_HOST}" ${AUTH_ARGS} PING | grep -q PONG || exit 1

# 2. --rdb 拉取 (复制协议, master fork 一次), timeout 防大数据集 hang
timeout 600 redis-cli -h "${MASTER_HOST}" ${AUTH_ARGS} --rdb /rdb/dump.rdb

# 3. 大小校验 (避免空 RDB 上传)
SIZE=$(wc -c < /rdb/dump.rdb)
[ "${SIZE}" -lt 10 ] && exit 1

# 4. gzip 压缩
gzip -f /rdb/dump.rdb
```

### uploader 脚本（mainContainer, rclone）

```sh
set -u
# rclone 默认找 /config/rclone/rclone.conf, 创建空文件抑制 NOTICE
# (env 配置优先生效, 空文件只是让 rclone 不报 "config not found")
mkdir -p /config/rclone && : > /config/rclone/rclone.conf

# 1. 连接检查 (rclone 通过 RCLONE_CONFIG_DST_* env 自动配置)
rclone lsd dst: >/dev/null || exit 1

# 2. bucket 检查 (Job 不创建 bucket)
rclone lsf "dst:${BUCKET}" >/dev/null || exit 1

# 3. 上传 (copyto: 单文件到单目标)
TS=$(date -u +%Y%m%d-%H%M%S)
OBJECT_NAME="${INSTANCE_NAME}-dump-${TS}.rdb.gz"
REMOTE_PATH="dst:${BUCKET}/${PREFIX}/${OBJECT_NAME}"
rclone copyto /rdb/dump.rdb.gz "${REMOTE_PATH}"

# 4. 验证 (lsf 列出对象, 文件应存在)
rclone lsf "${REMOTE_PATH}" >/dev/null || exit 1
# rclone size --json 输出 {"count":N,"bytes":N}, 提取 bytes
SIZE=$(rclone size "${REMOTE_PATH}" --json | grep -oE '"bytes":[0-9]+' | cut -d: -f2)

# 5. 保留策略: 删除 prefix 下超过 N 天的文件
rclone delete "dst:${BUCKET}/${PREFIX}/" --min-age "${RETENTION_DAYS}d"
```

### rclone 配置（全环境变量，无 rclone.conf 文件）

```yaml
env:
  - {name: RCLONE_CONFIG_DST_TYPE,            value: s3}
  - {name: RCLONE_CONFIG_DST_PROVIDER,        value: Minio}  # Minio/AWS/Alibaba/Tencent/Ceph/Other
  - {name: RCLONE_CONFIG_DST_ENDPOINT,        value: http://minio.minio.svc.cluster.local:80}
  - {name: RCLONE_CONFIG_DST_REGION,          value: us-east-1}
  - {name: RCLONE_CONFIG_DST_ACCESS_KEY_ID,   valueFrom: secretKeyRef access-key}
  - {name: RCLONE_CONFIG_DST_SECRET_ACCESS_KEY, valueFrom: secretKeyRef secret-key}
  # insecure=true 时:
  - {name: RCLONE_CONFIG_DST_NO_CHECK_CERTIFICATE, value: "true"}
```

访问语法统一为 `dst:<bucket>/<prefix>/<object>`。

### 关键参数

| 参数 | 默认 | 说明 |
|------|------|------|
| `backup.enabled` | `false` | 总开关 |
| `backup.schedule` | `"0 2 * * *"` | Cron 表达式（每天 02:00 UTC） |
| `backup.concurrencyPolicy` | `Forbid` | 上次未完成则跳过 |
| `backup.historyLimit` | `3` | 保留历史 Job 数 |
| `backup.endpoint` | `http://minio.minio.svc.cluster.local:80` | 对象存储端点 |
| `backup.provider` | `"Minio"` | rclone S3 backend: Minio/AWS/Alibaba/Tencent/Ceph/Other |
| `backup.insecure` | `false` | https 自签名时设 `true`（跳过证书校验） |
| `backup.bucket` | `"redis-test"` | 桶名（**必须预先存在**） |
| `backup.prefix` | `""` (= instanceName) | 桶下子路径前缀 |
| `backup.region` | `"us-east-1"` | S3 region |
| `backup.accessKey` / `backup.secretKey` | `"minioadmin"` | 明文凭证 |
| `backup.existingSecret` | `""` | 引用已有 Secret（优先） |
| `backup.retentionDays` | `7` | 超过 N 天自动删除 |
| `backup.image` | `rclone/rclone:1.66.0` | 上传镜像 |
| `backup.dumperImage` | `redis:5.0.8` | RDB 拉取镜像 |
| `backup.resources` | `cpu 50m / mem 64Mi` | Job 资源 |

### 切换存储后端示例（脚本零改动）

```bash
# MinIO (集群内)
--set backup.endpoint=http://minio.minio.svc.cluster.local:80 --set backup.provider=Minio

# 阿里云 OSS
--set backup.endpoint=https://oss-cn-hangzhou.aliyuncs.com --set backup.provider=Alibaba --set backup.region=cn-hangzhou

# 腾讯云 COS
--set backup.endpoint=https://cos.ap-shanghai.myqcloud.com --set backup.provider=Tencent --set backup.region=ap-shanghai

# AWS S3
--set backup.endpoint=https://s3.us-east-1.amazonaws.com --set backup.provider=AWS --set backup.region=us-east-1
```

## 使用说明

```bash
# 1. 预创建 bucket (Job 不创建 bucket)
kubectl run mb --rm -i --restart=Never --image=rclone/rclone:1.66.0 \
  --env=RCLONE_CONFIG_DST_TYPE=s3 \
  --env=RCLONE_CONFIG_DST_PROVIDER=Minio \
  --env=RCLONE_CONFIG_DST_ENDPOINT=http://minio.minio.svc.cluster.local:80 \
  --env=RCLONE_CONFIG_DST_ACCESS_KEY_ID=minioadmin \
  --env=RCLONE_CONFIG_DST_SECRET_ACCESS_KEY=minioadmin \
  -- sh -c 'mkdir -p /config/rclone && : > /config/rclone/rclone.conf && rclone mkdir dst:redis-test'

# 2. 部署 (生产用 existingSecret)
kubectl -n redis create secret generic ftest-backup-secret \
  --from-literal=access-key=minioadmin --from-literal=secret-key=minioadmin

helm install ftest ./helm/redis-sentinel -n redis --create-namespace \
  --set common.instanceName=ftest \
  --set common.auth.password=testpw \
  --set backup.enabled=true \
  --set backup.endpoint=http://minio.minio.svc.cluster.local:80 \
  --set backup.provider=Minio \
  --set backup.bucket=redis-test \
  --set backup.existingSecret=ftest-backup-secret \
  --set backup.retentionDays=7

# 3. 手动触发一次备份 (不等调度)
kubectl -n redis create job --from=cronjob/ftest-backup ftest-backup-manual-1
```

## 校验

### 1. CronJob 已创建

```bash
kubectl -n redis get cronjob ftest-backup
# 预期: SCHEDULE, SUSPEND=False, ACTIVE
```

### 2. 备份执行成功

```bash
kubectl -n redis wait job/ftest-backup-manual-1 --for=condition=complete --timeout=120s
kubectl -n redis logs job/ftest-backup-manual-1 -c uploader
# 预期:
#   [upload] -> dst:redis-test/ftest/ftest-dump-20260625-165354.rdb.gz
#   [upload] ok, object=ftest-dump-20260625-165354.rdb.gz, size=223 bytes
#   [retention] removing backups older than 7d under redis-test/ftest/
#   [retention] current backups:
#   ftest-dump-20260625-165248.rdb.gz
#   ftest-dump-20260625-165354.rdb.gz
```

### 3. 对象存储文件存在

```bash
kubectl run mc-ls --rm -i --restart=Never --image=rclone/rclone:1.66.0 \
  --env=RCLONE_CONFIG_DST_TYPE=s3 \
  --env=RCLONE_CONFIG_DST_PROVIDER=Minio \
  --env=RCLONE_CONFIG_DST_ENDPOINT=http://minio.minio.svc.cluster.local:80 \
  --env=RCLONE_CONFIG_DST_ACCESS_KEY_ID=minioadmin \
  --env=RCLONE_CONFIG_DST_SECRET_ACCESS_KEY=minioadmin \
  -- sh -c 'mkdir -p /config/rclone && : > /config/rclone/rclone.conf && rclone lsf dst:redis-test/ftest/'
# 预期: 至少 1 个 .rdb.gz 文件
```

### 4. 恢复验证（核心：证明备份有效）

```bash
cat > /tmp/restore-verify.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: restore-verify
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
    - {name: RCLONE_CONFIG_DST_ACCESS_KEY_ID, value: minioadmin}
    - {name: RCLONE_CONFIG_DST_SECRET_ACCESS_KEY, value: minioadmin}
    command: ["sh","-c"]
    args:
    - |
      set -u
      mkdir -p /config/rclone && : > /config/rclone/rclone.conf
      LATEST=$(rclone lsf "dst:redis-test/ftest/" | sort | tail -1)
      echo "[download] latest=${LATEST}"
      rclone copyto "dst:redis-test/ftest/${LATEST}" /shared/dump.rdb.gz
      echo "[download] size=$(wc -c < /shared/dump.rdb.gz) bytes"
    volumeMounts:
    - {name: shared, mountPath: /shared}
  containers:
  - name: verify
    image: redis:5.0.8
    command: ["sh","-c"]
    args:
    - |
      set -u
      gunzip -f /shared/dump.rdb.gz
      echo "[restore] decompressed size=$(wc -c < /shared/dump.rdb) bytes"
      echo "=== RDB magic ==="
      head -c 10 /shared/dump.rdb | od -c | head -1
      echo "=== redis-check-rdb ==="
      redis-check-rdb /shared/dump.rdb 2>&1 | tail -10
    volumeMounts:
    - {name: shared, mountPath: /shared}
  volumes:
  - {name: shared, emptyDir: {}}
EOF
kubectl apply -f /tmp/restore-verify.yaml
sleep 15
kubectl -n redis logs restore-verify -c verify
# 预期:
#   [restore] decompressed size=204 bytes
#   === RDB magic ===
#   0000000   R   E   D   I   S   0   0   0   9 372     ← 标准 Redis 5 RDB 头
#   === redis-check-rdb ===
#   [offset 204] Checksum OK
#   [offset 204] \o/ RDB looks OK! \o/
#   [info] 1 keys read                          ← 与写入数量一致
```

### 5. 保留策略生效

```bash
# 触发多次备份 (时间戳不同)
for i in 1 2 3; do
  kubectl -n redis create job --from=cronjob/ftest-backup "ftest-backup-r${i}"
  sleep 5
done

# 列出所有备份
kubectl run mc-ls2 --rm -i --restart=Never --image=rclone/rclone:1.66.0 \
  --env=RCLONE_CONFIG_DST_TYPE=s3 \
  --env=RCLONE_CONFIG_DST_PROVIDER=Minio \
  --env=RCLONE_CONFIG_DST_ENDPOINT=http://minio.minio.svc.cluster.local:80 \
  --env=RCLONE_CONFIG_DST_ACCESS_KEY_ID=minioadmin \
  --env=RCLONE_CONFIG_DST_SECRET_ACCESS_KEY=minioadmin \
  -- sh -c 'mkdir -p /config/rclone && : > /config/rclone/rclone.conf && rclone lsf dst:redis-test/ftest/'
# 预期: 多个文件, retentionDays 内的保留

# 模拟过期: 改 retentionDays=0 触发清理 (慎用, 会删所有)
# kubectl -n redis create job --from=cronjob/ftest-backup ftest-backup-cleanup-test
```

## 清理

```bash
# 删 Job + CronJob
kubectl -n redis delete job ftest-backup-manual-1 ftest-backup-r1 ftest-backup-r2 ftest-backup-r3 --ignore-not-found
kubectl -n redis delete pod restore-verify --force --ignore-not-found

# 删 helm release (CronJob + Secret 随之删除)
helm uninstall ftest -n redis

# 删 PVC
kubectl -n redis delete pvc -l app.kubernetes.io/instance=ftest --force

# 删对象存储中的备份文件 (按需)
kubectl run mc-rm --rm -i --restart=Never --image=rclone/rclone:1.66.0 \
  --env=RCLONE_CONFIG_DST_TYPE=s3 \
  --env=RCLONE_CONFIG_DST_PROVIDER=Minio \
  --env=RCLONE_CONFIG_DST_ENDPOINT=http://minio.minio.svc.cluster.local:80 \
  --env=RCLONE_CONFIG_DST_ACCESS_KEY_ID=minioadmin \
  --env=RCLONE_CONFIG_DST_SECRET_ACCESS_KEY=minioadmin \
  -- sh -c 'mkdir -p /config/rclone && : > /config/rclone/rclone.conf && rclone delete dst:redis-test/ftest/ --rmdirs'
rm -f /tmp/restore-verify.yaml /tmp/rdb-check.yaml
```

## 注意事项

1. **bucket 必须预先存在**：CronJob 不创建桶，上传前会检查，不存在则报错退出。可用 `rclone mkdir dst:<bucket>` 预建
2. **自签名 https**：endpoint 用 `https://` 且证书未受信任时设 `backup.insecure=true`（等价 `RCLONE_CONFIG_DST_NO_CHECK_CERTIFICATE=true`）。集群内 `http://` 无需
3. **大数据集超时**：`redis-cli --rdb` 外层 `timeout 600`（10 分钟）。数据集 >10GB 时按需调大或改用 BGSAVE + PVC 快照方案
4. **failover 期间备份**：`--rdb` 会因 master 连接断开失败，Job 重试（`backoffLimit: 2`）后到下次调度。不会产生损坏的 RDB
5. **凭证安全**：明文 `accessKey`/`secretKey` 会进 Helm values 和 Secret。生产用 `existingSecret` 引用外部管理的 Secret
6. **资源占用**：`rdb-dumper` 执行时 master 会 fork 一次（Redis 备份固有行为，非本方案特有）。大数据集时按需上调 `backup.resources`
7. **多实例隔离**：`prefix` 默认 `= instanceName`，同 bucket 多实例互不覆盖。如需统一前缀可显式设置
8. **不绑定特定厂商**：用 rclone 替代 mc。切换存储后端只改 `endpoint` + `provider`，脚本零改动。已实测 MinIO；切阿里云 OSS/腾讯云 COS/AWS S3 只需替换这两个参数
9. **master host 必须用 FQDN**：`<inst>-master.<ns>.svc.cluster.local`（不能用 `.svc` 短名，K8s DNS 解析会失败）
10. **rclone 配置全走环境变量**：无需 rclone.conf 文件，env 名格式 `RCLONE_CONFIG_<REMOTE>_<KEY>`。脚本开头创建空 `/config/rclone/rclone.conf` 仅用于抑制 "config not found" NOTICE
