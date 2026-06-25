# 架构设计

## 拓扑

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

- **Redis Pod**: 3 副本（1 主 2 从），每 Pod 含 3 个容器：`redis` + `exporter` + `role-tagger`
- **Sentinel Pod**: 3 副本，每 Pod 含 2 个容器：`sentinel` + `exporter`
- **Service**: 6 个（2 个 Headless + 2 个 ClusterIP + 2 个 Exporter）

## Pod 内容器职责

### Redis Pod

| 容器 | 镜像 | 职责 |
|------|------|------|
| `redis` | `redis:5.0.8` | 运行 Redis 实例，startup.sh 决定 master/slave 角色 |
| `exporter` | `oliver006/redis_exporter` | 暴露 Prometheus 指标（端口 9121） |
| `role-tagger` | `curlimages/curl` | 每 5s 用 curl telnet 直接查 redis ROLE，PATCH pod label `redis-role`（不依赖 exporter） |

### Sentinel Pod

| 容器 | 镜像 | 职责 |
|------|------|------|
| `sentinel` | `redis:5.0.8` | 运行 Redis Sentinel，监控 master，协调 failover |
| `exporter` | `oliver006/redis_exporter` | 暴露 Sentinel 指标（端口 9121） |

## 鲁棒性设计

### 1. 防脑裂（三重保险）

| 层级 | 策略 | 效果 |
|------|------|------|
| 启动 | Parallel + 脚本防脑裂 | ordinal>0 永不自举 master，宁可 crash loop |
| 运行 | `min-slaves-to-write 1` | master 无 slave ACK 时拒写，防数据丢失 |
| 选举 | sentinel quorum=2 | 2/3 哨兵同意才 failover，防误判 |

### 2. 应用零改动（role-tagger 机制）

`role-tagger` sidecar 每 5s 用 `curl telnet://127.0.0.1:6379` 发送 redis 协议（AUTH + INFO replication），直接从 redis 查询 ROLE，PATCH pod label `redis-role=master|slave`。`<instance>-master.svc` selector 为 `redis-role=master` → 只路由到 master。failover 时 sidecar 更新 label，Service 自动切流量（~5s）。readinessProbe 改为 PING，所有 pod Ready，无事件风暴。

**关键**：role-tagger **不依赖 exporter 容器**——直接查 redis，exporter 挂掉不影响标签更新（实测验证）。

**切换流程**（非事件驱动，定时轮询）:

```
sentinel 选举新 master
  ↓
新 master 的 redis 进程角色变为 master
  ↓ (role-tagger 下次轮询，最多 5s)
role-tagger 发现 role 变了 → PATCH label redis-role=master
  ↓ (K8s endpoints controller，~1-2s)
Master Service endpoints 更新 → 流量切到新 master
```

**总延迟约 5-7s**（轮询间隔 5s + endpoints 更新 1-2s）。

### 3. 冷启动鲁棒性

```
1. <instance>-0 启动 → 无 sentinel → ordinal=0 → 自举 master
2. sentinel 启动 → 扫描 → 发现 <instance>-0 → 配置 monitor
3. <instance>-1/2 启动 → 问 sentinel → 得到 <instance>-0 → 成为 slave
```

**死 IP fallback**: sentinel 持久化的 sentinel.conf 可能记录已不存在的 master IP（全集群重启场景）。startup.sh 验证 sentinel 返回的 master IP 可达性，不可达则 fallback 到冷启动逻辑。

### 4. Failover 流程

```
1. master 宕机 → sentinel 5s 后标记 SDOWN
2. quorum=2 选举新 master → 5-10s
3. slave 自动 SLAVEOF 新 master
4. 旧 master 恢复 → startup.sh 问 sentinel → 发现非己 → 自动变 slave
5. role-tagger sidecar → 更新 pod label → <instance>-master.svc 切流量 (~5s)
```

**总 failover 时间**: ~15-20s（sentinel 检测 5s + 选举 5-10s + 标签更新 5s）。

## 健康检查

| Component | Probe | InitialDelay | Period | FailureThreshold | MaxWait | 作用 |
|-----------|-------|--------------|--------|-----------------|---------|------|
| redis | startup | 5s | 5s | 30 | 150s | 冷启动宽容期 |
| redis | readiness (PING) | 5s | 5s | 3 | 20s | 流量就绪（所有 pod） |
| redis | liveness | 10s | 10s | 3 | 40s | 进程存活 |
| sentinel | startup | 5s | 5s | 40 | 200s | master 发现宽容期 |
| sentinel | readiness | 5s | 5s | 3 | 20s | master 可达性 |
| sentinel | liveness | 10s | 10s | 3 | 40s | 进程存活 |

## 持久化

- **PVC 模式**（默认）: `volumeClaimTemplates`，每个 Redis Pod 独立 PVC，数据持久化
- **emptyDir 模式**（`persistence.enabled=false`）: 数据随 Pod 删除而丢失，适合缓存场景
- Sentinel 始终用 emptyDir（sentinel.conf 不需要持久化，反而避免死 IP 问题）

## PodDisruptionBudget

两个 PDB（Redis + Sentinel），各 `minAvailable: 2`，确保自愿驱逐时仍保留 quorum。
