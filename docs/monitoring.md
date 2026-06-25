# Prometheus 监控配置

## 指标暴露

每个实例暴露两个 exporter Service：

| Service | 端口 | 指标 |
|---------|------|------|
| `<instance>-exporter` | 9121 | Redis 指标 |
| `<instance>-sentinel-exporter` | 9121 | Sentinel 指标 |

## 内置监控模板（推荐）

Chart 已内置 `ServiceMonitor` + `PrometheusRule`（需 Prometheus Operator，CRD `monitoring.coreos.com/v1`），开箱即用：

```bash
helm install my-app ./helm/redis-sentinel -n redis \
  --set common.instanceName=my-app \
  --set common.auth.password=secret \
  --set monitoring.enabled=true \
  --set monitoring.alerts.enabled=true
```

启用后自动创建：
- **ServiceMonitor**：让 Prometheus Operator 自动发现并抓取 `<instance>-exporter` 和 `<instance>-sentinel-exporter`（端口 metrics，间隔 15s）
- **PrometheusRule**：11 条关键告警规则（见下表）

`monitoring.alerts.namespace` 留空时 PrometheusRule 创建到 release 所在 namespace；若 Prometheus 只从特定 namespace 选规则，需显式指定。

### 内置告警规则

| Alert | 触发条件 | 严重度 |
|-------|---------|--------|
| RedisDown | `redis_up == 0` 持续 1m | critical |
| RedisNoMaster | `count(redis_instance_info{role="master"}) == 0` 持续 1m | critical |
| RedisMultipleMasters | `count(redis_instance_info{role="master"}) > 1` 持续 30s | critical（脑裂） |
| RedisInsufficientSlaves | `max(redis_connected_slaves) < 2` 持续 2m | warning |
| RedisInsufficientSentinels | `max(redis_sentinel_sentinels) < 2` 持续 2m | warning |
| RedisMasterDown | `max(redis_sentinel_master_status) == 0` 持续 30s | critical |
| RedisMemoryHigh | `used/max > 0.9`（仅 maxmemory>0）持续 5m | warning |
| RedisReplicationBroken | `redis_master_link_up == 0` 持续 2m | warning |
| RedisRejectedConnections | `rate(redis_rejected_connections_total[5m]) > 0` 持续 5m | warning |
| RedisEvictingKeys | `rate(redis_evicted_keys_total[5m]) > 0` 持续 5m | warning |
| RedisBgSaveFailed | `redis_rdb_last_bgsave_status != 0` 持续 1m | warning |

每条告警带 `instance: <instanceName>` 标签，方便多实例区分路由。

## 静态抓取（无 Prometheus Operator 时）

若集群未部署 Prometheus Operator，用静态配置抓取：

```yaml
scrape_configs:
  - job_name: 'redis'
    kubernetes_sd_configs:
      - role: endpoints
    relabel_configs:
      - source_labels: [__meta_kubernetes_service_name]
        regex: '.*-exporter'
        action: keep
      - source_labels: [__meta_kubernetes_namespace]
        regex: 'redis'
        action: keep
    metrics_path: /metrics
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

## Grafana Dashboard

推荐使用官方 Redis Dashboard：
- ID: [11835](https://grafana.com/grafana/dashboards/11835) — Redis Dashboard for Prometheus
- ID: [14695](https://grafana.com/grafana/dashboards/14695) — Redis Sentinel
