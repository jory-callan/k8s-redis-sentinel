# 06 - 网络隔离（NetworkPolicy）

启用后 Redis/Sentinel pod 入站流量默认全拒绝，仅放行必要的同实例流量 + 业务 pod + Prometheus 抓取。

## 架构设计

```
┌──────────────────────────────────────────────────────────────┐
│  namespace: redis                                            │
│                                                               │
│  Redis pod (app=ftest)                                        │
│  ┌──────────────────────────────────────────────┐             │
│  │ Ingress (default deny, 仅放行):              │             │
│  │                                              │             │
│  │  :6379 ← 同实例 redis pod (复制/role-tagger) │             │
│  │  :6379 ← 同实例 sentinel pod (监控)          │             │
│  │  :6379 ← 业务 namespace=app, pod app=web    │ ← 配置项     │
│  │  :9121 ← Prometheus namespace=monitoring     │ ← 抓 metrics │
│  │                                              │             │
│  │  Egress: 全放行 (默认)                       │             │
│  └──────────────────────────────────────────────┘             │
│                                                               │
│  Sentinel pod (app=ftest-sentinel)                            │
│  ┌──────────────────────────────────────────────┐             │
│  │  :26379 ← 同实例 redis pod (startup 查询)   │             │
│  │  :26379 ← 同实例 sentinel pod (互连/选举)    │             │
│  │  :9121  ← Prometheus                        │             │
│  └──────────────────────────────────────────────┘             │
└──────────────────────────────────────────────────────────────┘
```

**设计原则**：
1. **默认拒绝**：`policyTypes: [Ingress]` + 不写 `ingress: []` 等价于 deny all
2. **最小放行**：只放行运行必须的流量（复制、监控、抓取）+ 显式配置的业务流量
3. **不限制 egress**：redis/sentinel 需要主动连其他 pod（DNS、API server、对端 redis），egress 放行
4. **role-tagger 不受影响**：通过 localhost `127.0.0.1:6379` 访问同 pod 的 redis，不走网络

## 实现设计

### 涉及文件

| 文件 | 作用 |
|------|------|
| [helm/redis-sentinel/templates/networkpolicy.yaml](../helm/redis-sentinel/templates/networkpolicy.yaml) | 2 个 NetworkPolicy（redis + sentinel） |

### 关键实现

**1. Redis pod 6379 放行规则**

```yaml
ingress:
  # 同实例 redis + sentinel + backup (复制 / sentinel 监控 / rdb 拉取)
  - from:
      - podSelector: { matchLabels: { redis-sentinel.k8s.io/instance: <inst>, redis-sentinel.k8s.io/component: redis } }
      - podSelector: { matchLabels: { redis-sentinel.k8s.io/instance: <inst>, redis-sentinel.k8s.io/component: sentinel } }
      - podSelector: { matchLabels: { redis-sentinel.k8s.io/instance: <inst>, redis-sentinel.k8s.io/component: backup } }
    ports: [{ port: 6379 }]

  # 业务 pod (跨 namespace, 由 redisIngressFrom 配置)
  - from:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: app   # 业务 namespace
        podSelector:
          matchLabels:
            app: web                            # 业务 pod
    ports: [{ port: 6379 }]
```

**2. 9121 (exporter) 放行 Prometheus**

```yaml
- from:
    - podSelector: {}                                    # 同 namespace (本地测试)
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: monitoring         # Prometheus ns
  ports: [{ port: 9121 }]
```

**3. Sentinel pod 26379 仅放同实例**

```yaml
- from:
    - podSelector: { matchLabels: { redis-sentinel.k8s.io/instance: <inst>, redis-sentinel.k8s.io/component: redis } }        # redis pod (startup 查询)
    - podSelector: { matchLabels: { redis-sentinel.k8s.io/instance: <inst>, redis-sentinel.k8s.io/component: sentinel } } # sentinel (互连/选举)
  ports: [{ port: 26379 }]
```

### namespaceSelector 的坑

K8s 1.21+ 自动给 namespace 加 `kubernetes.io/metadata.name` label，可直接用 namespace 名匹配。1.19/1.20 需手动给 namespace 加此 label：

```bash
kubectl label ns app kubernetes.io/metadata.name=app
```

### 关键参数

| 参数 | 默认 | 说明 |
|------|------|------|
| `networkPolicy.enabled` | `false` | 总开关 |
| `networkPolicy.redisIngressFrom` | `[]` | 允许访问 6379 的业务来源（跨 ns） |
| `networkPolicy.prometheusNamespace` | `"monitoring"` | Prometheus 所在 ns（抓 9121） |

`redisIngressFrom` 每项格式：
```yaml
- namespace: app           # 业务 namespace (必填)
  podSelector:              # pod 标签 (可选, 留空=整个 ns)
    app: web
```

## 使用说明

```bash
# 部署 (限制只允许 app 命名空间的 web pod 访问)
helm install ftest ./helm/redis-sentinel -n redis --create-namespace \
  --set common.instanceName=ftest \
  --set common.auth.password=testpw \
  --set networkPolicy.enabled=true \
  --set 'networkPolicy.redisIngressFrom[0].namespace=app' \
  --set 'networkPolicy.redisIngressFrom[0].podSelector.app=web' \
  --set networkPolicy.prometheusNamespace=monitoring \
  --set monitoring.enabled=true

# 准备业务 ns
kubectl create ns app
kubectl -n app run web --image=redis:5.0.8 -- sleep 3600
kubectl -n app run other --image=redis:5.0.8 -- sleep 3600
```

## 校验

### 1. NetworkPolicy 已创建

```bash
kubectl -n redis get networkpolicy
# 预期: ftest-np, ftest-sentinel-np
```

### 2. 业务 pod 可访问（放行的）

```bash
kubectl -n app exec web -- redis-cli -h ftest-master.redis.svc.cluster.local -a testpw PING
# 预期: PONG
```

### 3. 非业务 pod 被拒绝

```bash
kubectl -n app exec other -- redis-cli -h ftest-master.redis.svc.cluster.local -a testpw PING
# 预期: 卡住或超时 (NetworkPolicy 静默丢弃)

# 加超时快速验证
kubectl -n app exec other -- timeout 3 redis-cli -h ftest-master.redis.svc.cluster.local -a testpw PING
# 预期: 空 (3s 超时, 无响应)
```

### 4. 跨 namespace 业务 pod 被拒（未配置的 ns）

```bash
kubectl run hacker --image=redis:5.0.8 -- sleep 3600   # default namespace
kubectl exec hacker -- timeout 3 redis-cli -h ftest-master.redis.svc.cluster.local -a testpw PING
# 预期: 空 (被拒)
```

### 5. 复制链路不受影响

```bash
# sentinel 仍能监控 redis (同实例放行)
kubectl -n redis exec ftest-sentinel-0 -c sentinel -- \
  redis-cli -p 26379 SENTINEL master mymaster | head -3

# slave 仍能复制 master
kubectl -n redis exec ftest-1 -c redis -- redis-cli -a testpw INFO replication | grep master_link_status
# 预期: up
```

### 6. Prometheus 仍能抓取

```bash
# 从 monitoring ns 的 prometheus pod 抓取 exporter
PROM_POD=$(kubectl -n monitoring get pod -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}')
kubectl -n monitoring exec "$PROM_POD" -- wget -qO- -T3 ftest-exporter.redis.svc.cluster.local:9121/metrics | head -3
# 预期: 指标输出
```

## 清理

```bash
helm uninstall ftest -n redis
kubectl delete ns app --force 2>/dev/null
kubectl delete pod hacker --force 2>/dev/null
kubectl -n redis delete pvc -l app.kubernetes.io/instance=ftest --force
```

## 注意事项

1. **K8s 1.19/1.20 需手动 label namespace**：`kubernetes.io/metadata.name` 是 1.21+ 自动加的。旧版本需 `kubectl label ns <ns> kubernetes.io/metadata.name=<ns>`
2. **podSelector 留空 = 整个 namespace**：`podSelector` 不写表示匹配 ns 内所有 pod
3. **role-tagger 走 localhost 不受影响**：通过 `127.0.0.1:6379` 访问同 pod redis，NetworkPolicy 不管 localhost
4. **egress 全放行**：不限制出站。如需限制（如仅允许访问 redis ns），需自行扩展 egress 规则
5. **多实例同 namespace 注意**：`redisIngressFrom` 是 ns 级，业务 pod 配置后能访问同 ns 内所有实例。如需更严格，用 `podSelector` 限定业务 pod 标签
6. **不要遗漏 prometheusNamespace**：开了 NetworkPolicy 又忘配 Prometheus ns，会导致指标抓取静默失败（告警全失效）
