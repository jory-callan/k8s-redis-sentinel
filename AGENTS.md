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

### 决策 2: readinessProbe = ROLE=master

**目标**: redis-master.svc 自动只路由到 master，应用零改动。
**方案**: readinessProbe 检查 `ROLE | head -1 | grep master`。
  - master → Ready → Service 有 endpoint
  - slave → NotReady → Service 无 endpoint
**failover**: 新 master 通过 readiness → Service 自动切流量。
**副作用**: slave NotReady → headless DNS 默认不解析。
**修复**: redis-hl 设 `publishNotReadyAddresses: true`。

### 决策 3: 不设 set -e

**问题**: dash (redis:5.0.8 的 /bin/sh) + `local` + `$()` + `set -e` → 脚本静默退出。
**方案**: 移除所有 `set -e`，改为显式 `||` 错误处理。
**详见**: [PITFALLS.md](PITFALLS.md) 坑 1。

### 决策 4: startup.sh 三分支决策

```
1. 问 sentinel → 有 master → 按信息启动
2. 无 sentinel → ordinal=0 → 自举 master
3. 无 sentinel → ordinal>0 → 等 redis-0 (永不自举，防脑裂)
```

**关键改进**: ordinal>0 **无 standalone fallback** — 宁可 crash loop 也不脑裂。

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
| `05-statefulset-redis.yaml` | Redis 3副本 (Parallel + PVC 1Gi) |
| `06-statefulset-sentinel.yaml` | Sentinel 3副本 (Parallel + emptyDir) |
| `07-pdb.yaml` | 2 个 PDB (minAvailable:2) |
| `install.sh` | 生产部署 |
| `test.sh` | 测试套件 (deploy/verify/failover/cleanup) |
| `cleanup.sh` | 交互式清理 |
| `ATTEMPTS.md` | 尝试路径文档 |
| `PITFALLS.md` | 坑文档 |

## 健康检查参数

| Component | Probe | InitialDelay | Period | FailureThreshold | MaxWait |
|-----------|-------|--------------|--------|-----------------|---------|
| redis | startup | 5s | 5s | 30 | 150s |
| redis | readiness | 5s | 3s | 3 | 14s |
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
