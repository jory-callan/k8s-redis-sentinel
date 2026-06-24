# AGENTS.md — Redis-Sentinel K8s 项目上下文

## 项目概述

1主2从 Redis Sentinel 自动故障转移集群，纯 K8s 原生 YAML，零 Operator。
Redis 5.0.8 · K8s 1.19+ · 官方镜像

## 架构决策日志

### 决策 1: Parallel 替代 OrderedReady

**问题**: OrderedReady 导致 redis-0 节点故障时整个集群阻塞。
**方案**: `podManagementPolicy: Parallel`，所有 pod 同时启动。
**防脑裂**: 移到 startup.sh — ordinal>0 永不自举为 master，只等 redis-0。
**代价**: 冷启动时 redis-0 迟迟不启动 → redis-1/2 crash loop 重试 (可接受)。
**优势**: 不阻塞调度，redis-0 一旦就绪，redis-1/2 立即连接。

### 决策 2: sidecar + label 替代 readinessProbe 路由 (V3 优化)

**目标**: redis-master.svc 自动只路由到 master，应用零改动，且不产生事件风暴。
**旧方案 (V2)**: readinessProbe 检查 `ROLE | grep master` → slave NotReady → Service 无 endpoint。
**问题**: slave 持续产生 `Readiness probe failed` 事件 (10分钟 309 次, 1年数千万次), 给 etcd/kubelet/API server 压力。
**新方案 (V3)**: role-tagger sidecar + pod label:
1. `role-tagger` sidecar (`curlimages/curl`) 每 5s 从 redis_exporter metrics 获取 ROLE, PATCH pod label `redis-role=master|slave`
2. readinessProbe 改为 PING (所有 pod Ready, 零失败事件)
3. redis-master.svc selector 改为 `redis-role=master` → 只路由到 master
4. RBAC: ServiceAccount + Role (patch pod label) + RoleBinding
**failover**: 新 master → sidecar 更新 label → Service 自动切流量 (~5s)。
**优势**: 消除事件风暴, slave 也 Ready (headless DNS 正常), 无需 `publishNotReadyAddresses`。
**详见**: [PITFALLS.md](PITFALLS.md) 坑 18。

### 决策 3: 不设 set -e

**问题**: dash (redis:5.0.8 的 /bin/sh) + `local` + `$()` + `set -e` → 脚本静默退出。
**方案**: 移除所有 `set -e`，改为显式 `||` 错误处理。
**详见**: [PITFALLS.md](PITFALLS.md) 坑 1。

### 决策 4: startup.sh 三分支决策 + 死 IP fallback

```
1. 问 sentinel → 有 master → 验证可达 → 可达则跟随
2. 问 sentinel → 有 master → 验证失败 → fallback 到冷启动 (坑 21)
3. 无 sentinel → ordinal=0 → 自举 master
4. 无 sentinel → ordinal>0 → 等 redis-0 (永不自举，防脑裂)
```

**关键改进**:
- ordinal>0 **无 standalone fallback** — 宁可 crash loop 也不脑裂
- sentinel 返回死 IP 时 fallback 到冷启动 (V3.2 修复, 全集群重启自愈)

### 决策 5: Redis 5.0.x DNS 限制

**问题**: Redis 5 Sentinel 不支持 `sentinel resolve-hostnames`，monitor 目标必须是 IP。
**方案**: entrypoint.sh 用 `getent hosts` 解析 DNS→IP。
**冷启动**: DNS 在 pod 未就绪时不解析 → 20 次重试 (~60s) 覆盖启动时间。

## 文件角色说明

| 文件 | 用途 |
|------|------|
| `00-namespace.yaml` | namespace `redis` |
| `01-secret.yaml` | 密码 (可选，删除即降级为无密码) |
| `02-configmap-redis.yaml` | redis.conf + startup.sh |
| `03-configmap-sentinel.yaml` | entrypoint.sh |
| `04-services.yaml` | 6 个 Service (redis-hl/master/read, sentinel-hl, 2x exporter) |
| `05-statefulset-redis.yaml` | Redis 3副本 (Parallel + PVC 1Gi + role-tagger sidecar) |
| `06-statefulset-sentinel.yaml` | Sentinel 3副本 (Parallel + emptyDir) |
| `07-pdb.yaml` | 2 个 PDB (minAvailable:2) |
| `08-rbac.yaml` | role-tagger sidecar 的 RBAC (ServiceAccount + Role + RoleBinding) |
| `install.sh` | 生产部署 |
| `test.sh` | 测试套件 (deploy/verify/failover/cleanup) |
| `check.sh` | 集群状态检测 (pod/role/slaves/sentinel/service/exporter/pdb) |
| `cleanup.sh` | 交互式清理 |
| `ATTEMPTS.md` | 尝试路径文档 |
| `PITFALLS.md` | 坑文档 |

## 健康检查参数

| Component | Probe | InitialDelay | Period | FailureThreshold | MaxWait |
|-----------|-------|--------------|--------|-----------------|---------|
| redis | startup | 5s | 5s | 30 | 150s |
| redis | readiness (PING) | 5s | 5s | 3 | 20s |
| redis | liveness | 10s | 10s | 3 | 40s |
| sentinel | startup | 5s | 5s | 40 | 200s |
| sentinel | readiness | 5s | 5s | 3 | 20s |
| sentinel | liveness | 10s | 10s | 3 | 40s |

## 连接方式

| 用途 | 地址 | 类型 |
|------|------|------|
| 写操作 (Master) | `redis-master.redis.svc:6379` | NodePort :30001 |
| 读操作 (所有节点) | `redis-read.redis.svc:6379` | NodePort :30002 |
| Redis 指标 | `redis-exporter.redis.svc:9121` | ClusterIP |
| Sentinel 指标 | `sentinel-exporter.redis.svc:9121` | ClusterIP |
| Sentinel | `sentinel-0.sentinel-hl.redis.svc:26379` | Headless |
