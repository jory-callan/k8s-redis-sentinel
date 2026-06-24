# ATTEMPTS.md — 尝试路径文档

记录设计演进过程和每次尝试的思路。

---

## V2 (当前版本) — 2026-06-25

### 设计目标
1. 自动故障转移（5-10s）
2. 应用零改动（redis-master.svc 固定指向 master）
3. 防脑裂
4. 密码认证（可选）
5. Prometheus 监控
6. 读写分离

### 核心设计决策

#### 决策 1: Parallel 替代 OrderedReady

**旧版问题**: OrderedReady 导致 redis-0 节点故障时整个集群阻塞。
**新版方案**: podManagementPolicy: Parallel，所有 pod 同时启动。
**防脑裂**: 移到 startup.sh 中 — ordinal>0 永不自举为 master，只等 redis-0。
**代价**: 冷启动时如果 redis-0 迟迟不启动，redis-1/2 会 crash loop 重试。
**优势**: 不阻塞调度，redis-0 一旦就绪，redis-1/2 立即连接。

#### 决策 2: readinessProbe = ROLE=master

**目标**: redis-master.svc 自动只路由到 master，应用零改动。
**方案**: readinessProbe 检查 `redis-cli ROLE | head -1 | grep master`。
  - master pod → Ready → redis-master.svc 有 endpoint
  - slave pods → NotReady → redis-master.svc 无 endpoint
**failover 时**: 新 master 通过 readiness → Service 自动切流量。
**副作用**: slave 是 NotReady，headless DNS 默认不解析。
**修复**: redis-hl service 设 `publishNotReadyAddresses: true`。

#### 决策 3: 不设 set -e

**原因**: redis:5.0.8 镜像的 /bin/sh 是 dash，dash 中 `set -e` + `local` + `$()` 组合会导致脚本静默退出。
**方案**: 所有脚本不设 `set -e`，用显式 `||` 和返回值检查。

#### 决策 4: startup.sh 三分支决策

```
1. 问 sentinel → 有 master 信息 → 按信息启动 (master/slave)
2. 无 sentinel → ordinal=0 → 自举为 master
3. 无 sentinel → ordinal>0 → 等 redis-0 (永不自举，防脑裂)
```

比旧版的 6 阶段简单很多。关键改进: ordinal>0 **不再有 standalone fallback**，避免脑裂。

#### 决策 5: PVC 持久化 + 默认 StorageClass 要求

Redis StatefulSet 使用 volumeClaimTemplates (1Gi PVC)。
Sentinel 使用 emptyDir (无持久化需求)。
**前提**: 集群需要有默认 StorageClass (minikube/kind/k3s 默认有)。

### 文件结构 (精简)

| 文件 | 用途 |
|------|------|
| 00-namespace.yaml | namespace |
| 01-secret.yaml | 密码 (可选) |
| 02-configmap-redis.yaml | redis.conf + startup.sh |
| 03-configmap-sentinel.yaml | entrypoint.sh |
| 04-services.yaml | 所有 6 个 Service |
| 05-statefulset-redis.yaml | Redis (Parallel + PVC) |
| 06-statefulset-sentinel.yaml | Sentinel (Parallel + emptyDir) |
| 07-pdb.yaml | 2 个 PDB |
| install.sh | 生产部署 |
| test.sh | 测试套件 |
| cleanup.sh | 清理 |

### 待验证项
- [x] 冷启动: redis-0 先成为 master，redis-1/2 成为 slave ✅ (k3s 1.31.5)
- [x] failover: 杀 master 后 ~15s 选举新 master ✅ (redis-0→redis-1)
- [x] 旧 master 恢复后自动降级为 slave ✅ (redis-0 重启后变 slave)
- [x] redis-master.svc 只路由到 master ✅ (endpoint 自动切换)
- [x] redis-read.svc 路由到所有节点 ✅
- [x] 密码认证 ✅ (NOAUTH 拒绝无密码)
- [x] Redis exporter ✅ (redis_up=1)
- [x] Sentinel exporter ✅ (requirepass 修复, ckquorum=1, ok_sentinels=3)
- [x] 旧 master 重启后正确连接新 master ✅ (坑 17 修复)

### V2 测试结果 (2026-06-25, k3s 1.31.5)

**环境**: 3 节点 k3s (k3s-server-1/2/3), K8s 1.31.5

**部署**: install.sh 成功，redis-0=master, redis-1/2=slave, 3 sentinel Ready

**Failover 测试**:
1. `kubectl delete pod redis-0 --force` (杀 master)
2. ~15s 后 redis-1 成为新 master
3. redis-0 重启后自动降级为 slave
4. redis-master.svc endpoint 自动切到 redis-1 (10.42.2.12)
5. 通过 redis-master.svc 写入成功，slave 复制正常

**修复的 bug**:
- 坑 12: `timeout 2 cli ...` 不能包裹 shell 函数 → 改为函数内部 `timeout 2 redis-cli ...`
- 坑 13: redis-cli 5.0 不支持 `--timeout` → 用 `timeout` 命令
- 坑 14: kubectl wait 对 slave 永远超时 → 只等 redis-0
- 坑 16: Sentinel exporter redis_up=0 → Sentinel 加 `requirepass` (不是 IS_SENTINEL 标志)
- 坑 17: sentinel failover 中返回过时 master IP → SLAVEOF 前验证 IP 可达 + 重试

---

## V1 (旧版，已删除) — 问题记录

1. install.sh 末尾 echo 块语法错误 (裸命令 + set -e 导致退出)
2. test.sh 密码替换不匹配 (sed 模式与实际密码不符)
3. readinessProbe=ROLE=master + OrderedReady 冲突 (slave 永不 Ready → redis-2 永不启动)
4. 脚本过于复杂 (6 阶段 startup, 420 行 test.sh)
5. 端口信息不一致 (README 说 30080, YAML 用 30002)
