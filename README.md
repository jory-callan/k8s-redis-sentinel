# Redis-Sentinel on K8s — 1主2从自动故障转移

Redis 5.0.8 · K8s 原生 · 零 Operator · 应用零改动 · Prometheus Exporter · 密码认证 · 多实例隔离

---

## 架构

```
                    ┌──────────────────────────┐
                    │  <instance>-master.svc   │  ← 只路由到 master (redis-role label)
                    │  (ClusterIP, port 6379)  │
                    └────────────┬─────────────┘
                                 │
         ┌───────────────────────┼───────────────────────┐
         │                       │                       │
    ┌────▼────┐            ┌────▼────┐            ┌────▼────┐
    │ <ins>-0 │            │ <ins>-1 │            │ <ins>-2 │
    │ master  │◄──────────►│ slave   │◄──────────►│ slave   │
    │ :6379   │            │ :6379   │            │ :6379   │
    │ :9121   │            │ :9121   │            │ :9121   │
    └────┬────┘            └────┬────┘            └────┬────┘
         │                       │                       │
    ┌────▼─────────┐       ┌────▼─────────┐       ┌────▼─────────┐
    │<ins>-sentinel-0│     │<ins>-sentinel-1│     │<ins>-sentinel-2│
    │ :26379        │      │ :26379        │      │ :26379        │
    └───────────────┘      └───────────────┘      └───────────────┘
```

## 多实例部署

同一命名空间可部署多套 Redis 集群，通过 **实例名称** 隔离所有资源（StatefulSet / Service / ConfigMap / Secret / PVC / RBAC）。

### 命名规范

| 资源类型 | 命名规则 | 示例 (instance=`redis-saas-log`) |
|----------|----------|----------------------------------|
| Redis StatefulSet | `<instance>` | `redis-saas-log` |
| Sentinel StatefulSet | `<instance>-sentinel` | `redis-saas-log-sentinel` |
| Redis Pod | `<instance>-{0,1,2}` | `redis-saas-log-0` |
| Sentinel Pod | `<instance>-sentinel-{0,1,2}` | `redis-saas-log-sentinel-0` |
| Headless Service (Redis) | `<instance>-hl` | `redis-saas-log-hl` |
| Headless Service (Sentinel) | `<instance>-sentinel-hl` | `redis-saas-log-sentinel-hl` |
| Master Service (ClusterIP) | `<instance>-master` | `redis-saas-log-master` |
| Read Service (ClusterIP) | `<instance>-read` | `redis-saas-log-read` |
| Exporter Service | `<instance>-exporter` | `redis-saas-log-exporter` |
| Sentinel Exporter | `<instance>-sentinel-exporter` | `redis-saas-log-sentinel-exporter` |
| ConfigMap (Redis) | `<instance>-config` | `redis-saas-log-config` |
| ConfigMap (Sentinel) | `<instance>-sentinel-config` | `redis-saas-log-sentinel-config` |
| Secret | `<instance>-secret` | `redis-saas-log-secret` |
| PDB | `<instance>-pdb` / `<instance>-sentinel-pdb` | `redis-saas-log-pdb` |
| RBAC | `<instance>-role-tagger` | `redis-saas-log-role-tagger` |

**命名约定**:
- Headless Service 以 `-hl` 结尾
- NodePort Service 以 `-np` 结尾（默认不创建，按需自行添加）
- Master / Read Service 默认 ClusterIP

**长度限制**: K8s 资源名最长 63 字符。Pod 名 = `<instance>-sentinel-0` (最长后缀 12 字符)，故实例名最长 **42 字符**。`install.sh` 会自动校验。

### 自定义 Service

默认不创建 NodePort / LoadBalancer。如需外部访问，自行创建 Service 并使用相同 selector：

```yaml
# 例: 为 redis-saas-log 暴露 NodePort
apiVersion: v1
kind: Service
metadata:
  name: redis-saas-log-master-np   # 以 -np 结尾
  namespace: redis
spec:
  type: NodePort
  selector:
    app: redis-saas-log
    redis-role: master             # 只路由到 master
  ports:
    - port: 6379
      nodePort: 30010              # 自行选择未占用端口
```

## 快速开始

### 部署

```bash
# 默认实例 (instance=redis, ns=redis)
./install.sh

# 业务实例 (推荐: 中间件前缀+业务名)
./install.sh redis-saas-log

# 指定命名空间
./install.sh redis-saas-log middleware

# 修改密码 (可选，删除 01-secret.yaml 即降级为无密码)
vim 01-secret.yaml
```

### 测试 (含 failover 验证)

```bash
./test.sh                              # 默认实例完整测试
./test.sh redis-saas-log               # 业务实例完整测试
./test.sh redis-saas-log middleware verify   # 指定 ns + 只验证
# Modes: install | verify | failover | cleanup | full (默认)
```

### 状态检测

```bash
./check.sh                             # 默认实例
./check.sh redis-saas-log               # 业务实例
./check.sh redis-saas-log middleware
```

### 清理

```bash
./cleanup.sh                            # 默认实例 (交互确认)
./cleanup.sh redis-saas-log             # 业务实例
```

## 文件清单 (按序 Apply)

| # | 文件 | 作用 |
|---|------|------|
| 00 | `00-namespace.yaml` | namespace (默认 `redis`) |
| 01 | `01-secret.yaml` | Redis 密码 (修改后需 delete 再 apply) |
| 02 | `02-configmap-redis.yaml` | redis.conf + startup.sh |
| 03 | `03-configmap-sentinel.yaml` | sentinel entrypoint.sh |
| 04 | `04-services.yaml` | 6 个 Service (2x hl, 2x ClusterIP, 2x exporter) |
| 05 | `05-statefulset-redis.yaml` | Redis 3副本 (Parallel + PVC + role-tagger sidecar) |
| 06 | `06-statefulset-sentinel.yaml` | Sentinel 3副本 (Parallel) |
| 07 | `07-pdb.yaml` | PDB minAvailable:2 |
| 08 | `08-rbac.yaml` | role-tagger sidecar 的 RBAC |

> 所有文件含 `__INSTANCE_NAME__` 和 `__NAMESPACE__` 占位符，由 `install.sh` / `test.sh` 通过 `sed` 渲染。

## 应用连接

以 instance=`redis-saas-log`、ns=`redis` 为例：

| 用途 | 地址 | 类型 |
|------|------|------|
| 写操作 (Master) | `redis-saas-log-master.redis.svc:6379` | ClusterIP |
| 读操作 (所有节点) | `redis-saas-log-read.redis.svc:6379` | ClusterIP |
| Redis 指标 | `redis-saas-log-exporter.redis.svc:9121` | ClusterIP |
| Sentinel 指标 | `redis-saas-log-sentinel-exporter.redis.svc:9121` | ClusterIP |
| Sentinel | `redis-saas-log-sentinel-0.redis-saas-log-sentinel-hl.redis.svc:26379` | Headless |
| 外部访问 | 自行创建 `-np` Service | NodePort (按需) |

### 带密码连接

```bash
redis-cli -h redis-saas-log-master.redis.svc -a 'redis123'
# 或从 Secret 获取
redis-cli -h redis-saas-log-master.redis.svc \
  -a "$(kubectl get secret redis-saas-log-secret -n redis -o jsonpath='{.data.redis-password}' | base64 -d)"
```

## 鲁棒性设计

### 1. 防脑裂 (三重保险)

| 层级 | 策略 | 效果 |
|------|------|------|
| 启动 | Parallel + 脚本防脑裂 | ordinal>0 永不自举 master |
| 运行 | `min-slaves-to-write 1` | master 无 slave ACK 时拒写 |
| 选举 | sentinel quorum=2 | 2/3 哨兵同意才 failover |

### 2. 应用零改动

`role-tagger` sidecar 每 5s 从 redis_exporter metrics 获取 ROLE，PATCH pod label `redis-role=master|slave`。`<instance>-master.svc` selector 为 `redis-role=master` → 只路由到 master。failover 时 sidecar 更新 label，Service 自动切流量（~5s）。readinessProbe 改为 PING，所有 pod Ready，无事件风暴。

### 3. 冷启动鲁棒性

```
1. <instance>-0 启动 → 无 sentinel → ordinal=0 → 自举 master
2. sentinel 启动 → 扫描 → 发现 <instance>-0 → 配置 monitor
3. <instance>-1/2 启动 → 问 sentinel → 得到 <instance>-0 → 成为 slave
```

### 4. Failover 流程

```
1. master 宕机 → sentinel 5s 后标记 SDOWN
2. quorum=2 选举新 master → 5-10s
3. slave 自动 SLAVEOF 新 master
4. 旧 master 恢复 → startup.sh 问 sentinel → 发现非己 → 自动变 slave
5. role-tagger sidecar → 更新 pod label → <instance>-master.svc 切流量 (~5s)
```

## 监控 (Prometheus)

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

## 已知限制

- **Redis 5.0.x**: 不支持 `sentinel resolve-hostnames`，entrypoint.sh 显式 DNS→IP 转换。
- **PVC 要求**: 集群需有默认 StorageClass (minikube/kind/k3s 默认有)。
- **冷启动**: `<instance>-0` 必须可调度，否则 `<instance>-1/2` 会 crash loop 等待。
- **实例名长度**: 最长 42 字符 (Pod 名需 ≤ 63 字符)。

## 文档

- [AGENTS.md](AGENTS.md) — 项目上下文和架构决策
- [ATTEMPTS.md](ATTEMPTS.md) — 设计演进和尝试路径
- [PITFALLS.md](PITFALLS.md) — 踩坑记录和解决方案
