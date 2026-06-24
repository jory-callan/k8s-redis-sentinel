# Redis-Sentinel on K8s — 1主2从自动故障转移

Redis 5.0.8 · K8s 原生 · 零 Operator · 应用零改动 · Prometheus Exporter · 密码认证

---

## 架构

```
                    ┌──────────────────────┐
                    │  redis-master.svc    │  ← 只路由到 master (redis-role label)
                    │  (port 6379)         │
                    └──────────┬───────────┘
                               │
         ┌─────────────────────┼─────────────────────┐
         │                     │                     │
    ┌────▼────┐          ┌────▼────┐          ┌────▼────┐
    │ redis-0 │          │ redis-1 │          │ redis-2 │
    │ master  │◄────────►│ slave   │◄────────►│ slave   │
    │ :6379   │          │ :6379   │          │ :6379   │
    │ :9121   │          │ :9121   │          │ :9121   │
    └────┬────┘          └────┬────┘          └────┬────┘
         │                     │                     │
    ┌────▼─────┐         ┌────▼─────┐         ┌────▼─────┐
    │sentinel-0│         │sentinel-1│         │sentinel-2│
    │ :26379   │         │ :26379   │         │ :26379   │
    └──────────┘         └──────────┘         └──────────┘
```

## 快速开始

### 部署

```bash
# 修改密码 (可选)
vim 01-secret.yaml

# 一键部署
./install.sh
```

### 测试 (含 failover 验证)

```bash
./test.sh              # 完整: 部署→验证→failover→验证
./test.sh install      # 只部署
./test.sh verify       # 只验证
./test.sh failover     # 只测 failover
./test.sh cleanup      # 清理
```

### 清理

```bash
./cleanup.sh
```

## 文件清单 (按序 Apply)

| # | 文件 | 作用 |
|---|------|------|
| 00 | `00-namespace.yaml` | namespace `redis` |
| 01 | `01-secret.yaml` | Redis 密码 (修改后需 delete 再 apply) |
| 02 | `02-configmap-redis.yaml` | redis.conf + startup.sh |
| 03 | `03-configmap-sentinel.yaml` | sentinel entrypoint.sh |
| 04 | `04-services.yaml` | 6 个 Service |
| 05 | `05-statefulset-redis.yaml` | Redis 3副本 (Parallel + PVC + role-tagger sidecar) |
| 06 | `06-statefulset-sentinel.yaml` | Sentinel 3副本 (Parallel) |
| 07 | `07-pdb.yaml` | PDB minAvailable:2 |
| 08 | `08-rbac.yaml` | role-tagger sidecar 的 RBAC |

## 应用连接

| 用途 | 地址 | 说明 |
|------|------|------|
| 写操作 | `redis-master.redis.svc:6379` | 只路由到 master |
| 读操作 | `redis-read.redis.svc:6379` | 所有节点 (含 slave) |
| 写 (外网) | `<node-ip>:30001` | NodePort |
| 读 (外网) | `<node-ip>:30002` | NodePort |
| Sentinel | `sentinel-0.sentinel-hl.redis.svc:26379` | 各哨兵 |
| Redis 指标 | `redis-exporter.redis.svc:9121` | Prometheus |
| Sentinel 指标 | `sentinel-exporter.redis.svc:9121` | Prometheus |

### 带密码连接

```bash
redis-cli -h redis-master.redis.svc -a 'redis123'
# 或从 Secret 获取
redis-cli -h redis-master.redis.svc -a "$(kubectl get secret redis-secret -n redis -o jsonpath='{.data.redis-password}' | base64 -d)"
```

## 鲁棒性设计

### 1. 防脑裂 (三重保险)

| 层级 | 策略 | 效果 |
|------|------|------|
| 启动 | Parallel + 脚本防脑裂 | ordinal>0 永不自举 master |
| 运行 | `min-slaves-to-write 1` | master 无 slave ACK 时拒写 |
| 选举 | sentinel quorum=2 | 2/3 哨兵同意才 failover |

### 2. 应用零改动

`role-tagger` sidecar 每 5s 从 redis_exporter metrics 获取 ROLE，PATCH pod label `redis-role=master|slave`。`redis-master.svc` selector 为 `redis-role=master` → 只路由到 master。failover 时 sidecar 更新 label，Service 自动切流量（~5s）。readinessProbe 改为 PING，所有 pod Ready，无事件风暴。

### 3. 冷启动鲁棒性

```
1. redis-0 启动 → 无 sentinel → ordinal=0 → 自举 master
2. sentinel 启动 → 扫描 → 发现 redis-0 → 配置 monitor
3. redis-1/2 启动 → 问 sentinel → 得到 redis-0 → 成为 slave
```

### 4. Failover 流程

```
1. master 宕机 → sentinel 5s 后标记 SDOWN
2. quorum=2 选举新 master → 5-10s
3. slave 自动 SLAVEOF 新 master
4. 旧 master 恢复 → startup.sh 问 sentinel → 发现非己 → 自动变 slave
5. role-tagger sidecar → 更新 pod label → redis-master.svc 切流量 (~5s)
```

## 监控 (Prometheus)

```yaml
scrape_configs:
  - job_name: 'redis'
    kubernetes_sd_configs:
      - role: endpoints
    relabel_configs:
      - source_labels: [__meta_kubernetes_service_name]
        regex: '(redis|sentinel)-exporter'
        action: keep
    metrics_path: /metrics
```

## 已知限制

- **Redis 5.0.x**: 不支持 `sentinel resolve-hostnames`，entrypoint.sh 显式 DNS→IP 转换。
- **PVC 要求**: 集群需有默认 StorageClass (minikube/kind/k3s 默认有)。
- **冷启动**: redis-0 必须可调度，否则 redis-1/2 会 crash loop 等待。

## 文档

- [ATTEMPTS.md](ATTEMPTS.md) — 设计演进和尝试路径
- [PITFALLS.md](PITFALLS.md) — 踩坑记录和解决方案
