# 05 - 监控告警（Prometheus）

Chart 内置 `ServiceMonitor` + `PrometheusRule`，启用即自动接入 Prometheus Operator，无需手动配置。

## 架构设计

```
┌──────────────────────────────────────────────────────────────┐
│  Redis Pod                                                    │
│  ┌────────────┐         ┌──────────────────────┐             │
│  │ redis      │ ←────── │ redis-exporter       │ :9121       │
│  │ :6379      │  REDIS  │ (oliver0066/redis_   │             │
│  └────────────┘  _ADDR  │  exporter)           │             │
│                          └──────────┬───────────┘             │
└─────────────────────────────────────┼────────────────────────┘
                                      │ /metrics
                                      ▼
┌──────────────────────────────────────────────────────────────┐
│  Service <inst>-exporter  (selector: app=<inst>)             │
│  port: metrics=9121                                          │
└──────────────────────────┬───────────────────────────────────┘
                           │
                           ▼
┌──────────────────────────────────────────────────────────────┐
│  ServiceMonitor (CRD)                                        │
│  selector: app in (<inst>, <inst>-sentinel)                  │
│  namespaceSelector: <Release.Namespace>                      │
└──────────────────────────┬───────────────────────────────────┘
                           │ Prometheus Operator 自动发现
                           ▼
┌──────────────────────────────────────────────────────────────┐
│  Prometheus → 抓取 → 告警引擎 → 命中 PrometheusRule            │
└──────────────────────────┬───────────────────────────────────┘
                           ▼
                   Alertmanager → 通知
```

**11 条内置告警**（见下表）覆盖：实例存活、master 唯一性、脑裂检测、复制健康、内存压力、持久化失败等关键场景。

## 实现设计

### 涉及文件

| 文件 | 作用 |
|------|------|
| [helm/redis-sentinel/templates/statefulset-redis.yaml](../helm/redis-sentinel/templates/statefulset-redis.yaml) | exporter sidecar（`redis.exporter.enabled`） |
| [helm/redis-sentinel/templates/statefulset-sentinel.yaml](../helm/redis-sentinel/templates/statefulset-sentinel.yaml) | sentinel exporter sidecar |
| [helm/redis-sentinel/templates/services.yaml](../helm/redis-sentinel/templates/services.yaml) | `<inst>-exporter` / `<inst>-sentinel-exporter` Service |
| [helm/redis-sentinel/templates/servicemonitor.yaml](../helm/redis-sentinel/templates/servicemonitor.yaml) | ServiceMonitor + PrometheusRule |

### 关键实现

**1. exporter 通过环境变量传密码**（不写入命令行，避免 ps 泄露）：

```yaml
env:
  - name: REDIS_ADDR
    value: redis://127.0.0.1:6379
  - name: REDIS_PASSWORD
    valueFrom:
      secretKeyRef:
        name: <inst>-secret
        key: redis-password
```

**2. ServiceMonitor 用 `matchExpressions` 同时选 redis + sentinel**：

```yaml
selector:
  matchExpressions:
    - key: app
      operator: In
      values: [<inst>, <inst>-sentinel]
```

**3. PrometheusRule 告警带 `instance` label**：多实例同 Prometheus 抓取时告警互不混淆。

### 11 条告警清单

| Alert | Severity | 触发条件 | 含义 |
|-------|----------|----------|------|
| RedisDown | critical | `redis_up == 0` (1m) | Redis 实例宕机 |
| RedisNoMaster | critical | `count(redis_instance_info{role=master}) == 0` (1m) | 无 master，写不可用 |
| RedisMultipleMasters | critical | `count(redis_instance_info{role=master}) > 1` (30s) | **脑裂检测** |
| RedisInsufficientSlaves | warning | `max(redis_connected_slaves) < 2` (2m) | slave 不足，无 failover 候选 |
| RedisInsufficientSentinels | warning | `max(redis_sentinel_sentinels) < 2` (2m) | sentinel 不足，quorum 风险 |
| RedisMasterDown | critical | `max(redis_sentinel_master_status) == 0` (30s) | sentinel 判定 master 宕机 |
| RedisMemoryHigh | warning | `used/max > 0.9` (5m) | 内存使用率 > 90% |
| RedisReplicationBroken | warning | `redis_master_link_up == 0` (2m) | slave 复制链路断开 |
| RedisRejectedConnections | warning | `rate(rejected_connections_total[5m]) > 0` (5m) | 连接被拒绝（maxclients/密码错） |
| RedisEvictingKeys | warning | `rate(evicted_keys_total[5m]) > 0` (5m) | 内存压力正在淘汰 key |
| RedisBgSaveFailed | warning | `rdb_last_bgsave_status != 0` (1m) | RDB 持久化失败 |

### 关键参数

| 参数 | 默认 | 说明 |
|------|------|------|
| `monitoring.enabled` | `false` | 总开关（含 ServiceMonitor） |
| `monitoring.interval` | `15s` | 抓取间隔 |
| `monitoring.alerts.enabled` | `true` | 是否创建 PrometheusRule |
| `monitoring.alerts.namespace` | `""` (= Release ns) | PrometheusRule 所在 ns |
| `redis.exporter.enabled` | `true` | redis exporter sidecar |
| `sentinel.exporter.enabled` | `true` | sentinel exporter sidecar |

## 使用说明

```bash
helm install ftest ./helm/redis-sentinel -n redis --create-namespace \
  --set common.instanceName=ftest \
  --set common.auth.password=testpw \
  --set monitoring.enabled=true \
  --set monitoring.alerts.enabled=true \
  --set networkPolicy.enabled=true \
  --set networkPolicy.prometheusNamespace=monitoring
```

## 校验

### 1. exporter 指标暴露

```bash
# 直接 curl exporter
kubectl -n redis exec ftest-0 -c exporter -- wget -qO- http://localhost:9121/metrics | head -20
# 预期: 看到 redis_up / redis_instance_info / redis_connected_slaves 等指标
```

### 2. Service 存在

```bash
kubectl -n redis get svc -l app=ftest
# 预期: ftest-exporter (ClusterIP, 9121)
```

### 3. ServiceMonitor 被创建

```bash
kubectl -n redis get servicemonitor ftest
kubectl -n redis describe servicemonitor ftest
```

### 4. PrometheusRule 被创建

```bash
kubectl -n redis get prometheusrule ftest-alerts
# 查看具体告警规则
kubectl -n redis get prometheusrule ftest-alerts -o yaml | grep -E "alert:|expr:" | head -30
```

### 5. Prometheus 已抓取（需 Prometheus Operator）

```bash
# 在 Prometheus UI 查询
# up{job="ftest"} 应为 1
# redis_instance_info{instance="ftest",role="master"} 应有 1 条
```

### 6. 触发告警验证

```bash
# 模拟 master 宕机 → RedisMasterDown / RedisNoMaster 告警
MASTER=$(kubectl -n redis get pod -l app=ftest,redis-role=master -o jsonpath='{.items[0].metadata.name}')
kubectl -n redis delete pod "$MASTER" --force --grace-period=0

# 等 1-2 分钟, Prometheus UI 应看到 RedisMasterDown 触发
```

## 清理

```bash
helm uninstall ftest -n redis
# ServiceMonitor / PrometheusRule 随 release 一起删除
kubectl -n redis delete pvc -l app.kubernetes.io/instance=ftest --force
```

## 注意事项

1. **需 Prometheus Operator**：ServiceMonitor / PrometheusRule 是 CRD，集群需已安装 [Prometheus Operator](https://prometheus-operator.dev/)
2. **prometheusNamespace**：Prometheus 跨 namespace 抓取需要 `networkPolicy.prometheusNamespace` 放行，否则 NetworkPolicy 会阻断抓取
3. **告警 label**：所有告警带 `instance: <inst>`，便于多实例区分
4. **exporter 不影响 role-tagger**：role-tagger 直接查 redis（curl telnet），exporter 挂掉不影响 master 流量切换。两者完全解耦
5. **告警 ns**：`monitoring.alerts.namespace` 默认与 release 同 ns。若 Prometheus 只读特定 ns 的 rule，需显式指定（如 `monitoring`）
6. **密码抓取**：ServiceMonitor 通过 `params.password` 传 secret name，exporter 通过 `REDIS_PASSWORD` env 连接。两套机制独立，均不写入命令行
