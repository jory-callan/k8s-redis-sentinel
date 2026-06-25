# Prometheus 监控配置

## 指标暴露

每个实例暴露两个 exporter Service：

| Service | 端口 | 指标 |
|---------|------|------|
| `<instance>-exporter` | 9121 | Redis 指标 |
| `<instance>-sentinel-exporter` | 9121 | Sentinel 指标 |

## Prometheus 抓取配置

### 方式 1: 静态配置

```yaml
scrape_configs:
  - job_name: 'redis'
    kubernetes_sd_configs:
      - role: endpoints
    relabel_configs:
      - source_labels: [__meta_kubernetes_service_name]
        regex: '.*-exporter'        # 匹配所有实例的 exporter
        action: keep
      - source_labels: [__meta_kubernetes_namespace]
        regex: 'redis'
        action: keep
    metrics_path: /metrics
```

### 方式 2: ServiceMonitor（Prometheus Operator）

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: redis-sentinel
  namespace: redis
spec:
  selector:
    matchExpressions:
      - key: app
        operator: Exists
  namespaceSelector:
    matchNames:
      - redis
  endpoints:
    - port: metrics
      interval: 15s
```

## 关键指标

### Redis 健康度

| 指标 | 说明 | 告警阈值 |
|------|------|----------|
| `redis_instance_info{role="master"}` | master 角色计数 | 应为 1 |
| `redis_connected_clients` | 连接数 | 视业务 |
| `redis_used_memory_bytes` | 内存使用 | 接近 maxmemory |
| `redis_commands_processed_total` | 命令吞吐 | 突降告警 |
| `redis_keyspace_hits_total` / `redis_keyspace_misses_total` | 命中率 | 命中率下降 |
| `redis_replication_offset` | 复制偏移 | master/slave 差距大告警 |

### Sentinel 健康度

| 指标 | 说明 | 告警阈值 |
|------|------|----------|
| `redis_sentinel_masters` | 监控的 master 数 | 应为 1 |
| `redis_sentinel_master_status` | master 状态 | 0=down 告警 |
| `redis_sentinel_master_address` | master 地址 | 变化告警 |
| `redis_sentinel_slaves` | slave 数 | <2 告警 |
| `redis_sentinel_sentinels` | sentinel 数 | <2 告警 |

## 告警规则示例

```yaml
groups:
  - name: redis-sentinel
    rules:
      # master 不唯一
      - alert: RedisMultipleMasters
        expr: count(redis_instance_info{role="master"}) > 1
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Multiple Redis masters detected (possible split-brain)"

      # 无 master
      - alert: RedisNoMaster
        expr: count(redis_instance_info{role="master"}) == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "No Redis master"

      # slave 数量不足
      - alert: RedisInsufficientSlaves
        expr: redis_sentinel_slaves < 2
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "Redis has fewer than 2 slaves"

      # sentinel 数量不足
      - alert: RedisInsufficientSentinels
        expr: redis_sentinel_sentinels < 2
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "Redis Sentinel quorum at risk"

      # master down
      - alert: RedisMasterDown
        expr: redis_sentinel_master_status == 0
        for: 30s
        labels:
          severity: critical
        annotations:
          summary: "Redis master is down according to sentinel"

      # 内存使用高
      - alert: RedisMemoryHigh
        expr: redis_used_memory_bytes / redis_memory_max_bytes > 0.9
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Redis memory usage > 90%"
```

## Grafana Dashboard

推荐使用官方 Redis Dashboard：
- ID: [11835](https://grafana.com/grafana/dashboards/11835) — Redis Dashboard for Prometheus
- ID: [14695](https://grafana.com/grafana/dashboards/14695) — Redis Sentinel
