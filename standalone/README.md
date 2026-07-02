# Redis-Standalone (K8s)

生产就绪的 Redis 单机模式 Helm Chart。1 副本 Deployment + PVC 持久化，零 Operator，纯 YAML + Shell。

> ⚠️ **无故障转移** — master 宕机即停服，靠 Pod 重启 + RDB 恢复。生产关键业务请评估是否能接受短暂中断，否则请用同仓库的 `redis-sentinel` chart（自动 failover ~15s）。

## 适用场景

- 缓存（数据可丢失或可重建）
- 非关键业务（可接受短暂中断）
- 开发/测试环境
- 数据量小、QPS 适中、单点风险可控的服务

## 特性

- **Redis 6.2** 单机模式
- **Deployment + PVC** 持久化（RDB 快照）
- **Prometheus exporter** sidecar（可选）
- **NetworkPolicy** 入站隔离（可选）
- **ServiceMonitor + 告警规则**（可选，6 条关键告警）
- **CronJob 备份** → 对象存储（rclone，支持 S3/MinIO/OSS/COS 等 40+ 后端）
- **多实例隔离**：独立 label 前缀 `redis-standalone.k8s.io/*`，可与 `redis-sentinel` chart 同集群混部
- **零 Operator**：纯 Helm + Shell

## 快速开始

```bash
# 默认部署
helm install my-redis ./helm/redis-standalone -n redis --create-namespace

# 自定义实例名 + 密码 + 持久化
helm install cache ./helm/redis-standalone -n middleware \
  --set common.instanceName=redis-app-cache \
  --set common.auth.password=mypassword \
  --set redis.persistence.size=5Gi

# 用已有 Secret 存密码
helm install my-redis ./helm/redis-standalone -n redis \
  --set common.auth.existingSecret=my-redis-secret

# 启用备份
helm install my-redis ./helm/redis-standalone -n redis \
  --set backup.enabled=true \
  --set backup.endpoint=http://minio.minio.svc:80 \
  --set backup.bucket=my-redis-backup \
  --set backup.accessKey=xxx \
  --set backup.secretKey=yyy
```

## 连接

```bash
# 获取密码
kubectl -n redis get secret my-redis-secret -o jsonpath='{.data.redis-password}' | base64 -d

# 进入 redis-cli
kubectl -n redis exec deploy/my-redis -- redis-cli -a '<PASSWORD>'

# 验证
127.0.0.1:6379> PING
PONG
127.0.0.1:6379> INFO server
```

应用连接地址：`my-redis.redis.svc.cluster.local:6379`

## 恢复时间参考

单机模式无故障转移，恢复依赖 Pod 重启 + RDB 加载。下表为各场景的**约值**恢复时间（基于 K8s 默认参数 + 小到中等 RDB <100MB）：

| 场景 | 恢复时间 | 机制 | 说明 |
|------|---------|------|------|
| **Redis 进程崩溃**（OOM/panic） | ~10–30s | restartPolicy + kubelet 重启 | livenessProbe 检测失败 → kill → 重启容器，PVC 数据保留 |
| **Pod 误删**（`kubectl delete pod`） | ~10–60s | Deployment 重建 Pod | 重新调度 + 挂载已有 PVC + Redis 启动 + RDB 加载 |
| **Pod 所在节点 drain**（自愿） | ~30s–2min | 优雅终止 + 重新调度 | ⚠️ 若启用 PDB `minAvailable:1` 会**阻塞 drain**；未启用则正常驱逐重建 |
| **Pod 所在节点宕机**（非自愿） | ~5–10min | kubelet 标记 NotReady + Pod eviction + 重新调度 | 默认 `tolerationSeconds=300` 等 5min 才驱逐；之后重新调度 + 挂载 PVC + 启动 |
| **PVC 存储后端故障** | **无法恢复** | — | 数据不可达，需从备份恢复（RPO = 上次备份时间） |
| **误删 Deployment** | ~30s–2min | 重新 `helm install` | Pod 重建 + 挂载已有 PVC（数据不丢） + RDB 加载 |
| **误删 PVC** | **数据丢失** | — | 需从备份恢复：下载 RDB → 拷入新 PVC → 启动 Redis |
| **K8s API server 不可用** | **无影响**（已运行 Pod） | kubelet 本地维持 | 已调度 Pod 由节点上 kubelet 维持，不受控制面影响 |
| **整个集群宕机重启** | ~2–5min | 控制面恢复 + Pod 调度 + RDB 加载 | 视 RDB 大小，大 RDB 加载更久 |
| **从备份恢复** | ~5–30min | 下载 RDB.gz → 解压 → 拷入 PVC → 重启 Pod | 取决于 RDB 大小 + 网络带宽 + 对象存储延迟 |

### 关键参数调优

影响恢复时间的可调参数：

| 参数 | 默认 | 影响 | 调优建议 |
|------|------|------|---------|
| `redis.probes.liveness.initialDelaySeconds` | 30s | 进程崩溃后多久开始检测 | 大 RDB 加载需增大（避免误杀） |
| `redis.probes.liveness.failureThreshold` | 3 | 检测失败次数触发重启 | × period(10s) = 30s 容忍窗口 |
| `terminationGracePeriodSeconds` | 30s | 优雅终止等待时间 | 大 RDB 触发 SAVE 时需增大 |
| `tolerations` (节点宕机) | 未配置 | 节点宕机后多久驱逐 Pod | 加 `node.kubernetes.io/not-ready:300s` toleration 控制 |
| `backup.schedule` | `0 2 * * *` | 备份频率 = RPO | 数据重要时提高频率（如每小时） |
| `redis.persistence.size` | 1Gi | RDB 存储空间 | 需容纳数据集 + fork 临时空间 |

### 与 Sentinel 模式对比

| 维度 | standalone | sentinel |
|------|-----------|----------|
| 进程崩溃 | ~10–30s（重启） | ~15s（failover） |
| 节点宕机 | ~5–10min（重新调度） | ~15s（failover，slave 提升） |
| 数据丢失风险 | 高（单点） | 低（多副本复制） |
| 适用 | 缓存/非关键 | 关键业务 |

## 配置

完整参数见 [values.yaml](helm/redis-standalone/values.yaml) 注释。关键配置：

| 参数 | 默认 | 说明 |
|------|------|------|
| `common.instanceName` | `release.Name` | 实例名（资源前缀，多实例隔离） |
| `common.auth.enabled` | `true` | 启用密码 |
| `common.auth.password` | `redis123` | 密码（生产用 `existingSecret`） |
| `common.auth.existingSecret` | `""` | 已有 Secret（优先于 password） |
| `redis.image.tag` | `6.2.20` | Redis 版本 |
| `redis.replicas` | `1` | 副本数（单机固定 1） |
| `redis.persistence.enabled` | `true` | 持久化 |
| `redis.persistence.size` | `1Gi` | PVC 大小 |
| `redis.maxmemory` | `0` | 内存上限（0=不限，生产建议设） |
| `redis.exporter.enabled` | `true` | Prometheus exporter |
| `networkPolicy.enabled` | `false` | NetworkPolicy 入站隔离 |
| `monitoring.enabled` | `false` | ServiceMonitor + 告警 |
| `backup.enabled` | `false` | CronJob 备份 |
| `pdb.enabled` | `false` | PDB（单副本默认禁用） |

## 文件结构

```
standalone/
├── helm/redis-standalone/
│   ├── Chart.yaml              # Chart 元数据
│   ├── values.yaml             # 可配置参数
│   └── templates/
│       ├── _helpers.tpl        # 名称/标签/镜像/探针助手
│       ├── secret.yaml         # 密码 Secret
│       ├── configmap.yaml      # redis.conf + startup.sh
│       ├── pvc.yaml            # 数据 PVC (持久化)
│       ├── deployment.yaml     # Redis Deployment (含 exporter sidecar)
│       ├── service.yaml        # ClusterIP Service (+ exporter Service)
│       ├── pdb.yaml            # PDB (默认禁用)
│       ├── networkpolicy.yaml  # NetworkPolicy (可选)
│       ├── servicemonitor.yaml # ServiceMonitor + PrometheusRule (可选)
│       ├── backup-secret.yaml  # 备份凭证 Secret (可选)
│       └── backup-cronjob.yaml # 备份 CronJob (可选)
├── README.md                   # 本文件
└── AGENTS.md                   # AI 协作上下文
```

## 备份恢复

### 备份（自动）

启用 `backup.enabled=true`，CronJob 定时从 Redis 拉 RDB 上传对象存储：

```bash
helm install my-redis ./helm/redis-standalone -n redis \
  --set backup.enabled=true \
  --set backup.endpoint=http://minio.minio.svc:80 \
  --set backup.bucket=my-backups \
  --set backup.accessKey=xxx --set backup.secretKey=yyy \
  --set backup.schedule="0 */6 * * *"  # 每 6 小时
```

### 恢复（手动）

```bash
# 1. 下载最新备份
rclone copy dst:my-backups/my-redis/dump-20260101-020000.rdb.gz /tmp/

# 2. 解压
gunzip /tmp/dump-20260101-020000.rdb.gz

# 3. 停止 redis (缩小副本到 0)
kubectl -n redis scale deploy/my-redis --replicas=0

# 4. 拷贝 RDB 到 PVC (替换 PVC 名)
kubectl -n redis cp /tmp/dump-20260101-020000.rdb <helper-pod>:/data/dump.rdb
# 或用临时 pod 挂载 PVC 拷入

# 5. 重启 redis
kubectl -n redis scale deploy/my-redis --replicas=1
```

## 多实例隔离

同命名空间可部署多套实例，通过 `common.instanceName` 隔离：

```bash
helm install cache-a ./helm/redis-standalone -n middleware --set common.instanceName=redis-cache-a
helm install cache-b ./helm/redis-standalone -n middleware --set common.instanceName=redis-cache-b
```

所有资源以 instanceName 为前缀，selector 用 `redis-standalone.k8s.io/*` 三维匹配（chart + instance + component），不会与同集群其他应用冲突，也不会与 `redis-sentinel` chart 冲突（label 前缀不同）。
