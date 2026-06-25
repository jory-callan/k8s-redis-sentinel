# AGENTS.md — Redis-Sentinel K8s 项目上下文

> 本文档面向 AI 协作者（如 Cursor、Copilot、Claude Code），描述项目目标、方案选型与编码规范。修改代码前请先通读本文。

## 项目目标

构建一个 **生产可用、零 Operator、应用零改动** 的 Redis Sentinel 自动故障转移集群，部署在 Kubernetes 上。

### 核心目标

1. **自动故障转移**: master 宕机后 ~15s 内完成选举与流量切换
2. **应用零改动**: `<instance>-master.svc` 始终指向当前 master，业务代码无需感知 failover
3. **防脑裂**: 任何情况下不会出现双 master
4. **多实例隔离**: 同命名空间可部署多套集群，按业务实例名隔离
5. **零事件风暴**: 不给 etcd/kubelet/API server 产生持续失败事件
6. **可观测**: 内置 Prometheus exporter，支持监控告警

### 非目标

- 不追求支持 Redis Cluster（分片）— 本项目是 Sentinel 主从模式
- 不追求支持 Redis 6+ 特性（如 ACL、`sentinel resolve-hostnames`）— 锁定 5.0.x
- 不内置备份恢复 — 由外部机制（如 Velero、Barman）负责

## 技术栈

- Redis 5.0.8（官方镜像）
- K8s 1.19+
- 纯 YAML + Shell 脚本（零 Operator）
- Helm Chart（可选，推荐）
- Prometheus redis_exporter

## 方案选型

### 1. Parallel 替代 OrderedReady

**问题**: OrderedReady 导致 redis-0 节点故障时整个集群阻塞。
**方案**: `podManagementPolicy: Parallel`，所有 pod 同时启动。
**防脑裂**: 移到 startup.sh — ordinal>0 永不自举为 master，只等 redis-0。
**代价**: 冷启动时 redis-0 迟迟不启动 → redis-1/2 crash loop 重试（可接受）。
**优势**: 不阻塞调度，redis-0 一旦就绪，redis-1/2 立即连接。

### 2. sidecar + label 替代 readinessProbe 路由

**目标**: `<instance>-master.svc` 自动只路由到 master，应用零改动，且不产生事件风暴。
**旧方案**: readinessProbe 检查 `ROLE | grep master` → slave NotReady → Service 无 endpoint。
**问题**: slave 持续产生 `Readiness probe failed` 事件（10 分钟 309 次，1 年数千万次），给 etcd/kubelet/API server 压力。
**新方案**: role-tagger sidecar + pod label:
1. `role-tagger` sidecar（`curlimages/curl`）每 5s 用 `curl telnet://127.0.0.1:6379` 发送 redis 协议（AUTH + INFO replication），直接从 redis 查询 ROLE，PATCH pod label `redis-role=master|slave`
2. readinessProbe 改为 PING（所有 pod Ready，零失败事件）
3. `<instance>-master.svc` selector 改为 `redis-role=master` → 只路由到 master
4. RBAC: ServiceAccount + Role（patch pod label）+ RoleBinding
**failover**: 新 master → sidecar 更新 label → Service 自动切流量（~5s）。
**优势**: 消除事件风暴，slave 也 Ready（headless DNS 正常），无需 `publishNotReadyAddresses`。
**关键**: role-tagger **不依赖 exporter 容器**——直接用 curl telnet 模式发 redis 协议查询角色，exporter 挂掉不影响标签更新（实测验证）。
**坑**: curlimages/curl 镜像用 `command:` 覆盖 entrypoint 后，shell hash 缓存无 curl，需脚本开头 `hash -r`。

### 3. 不设 set -e

**问题**: dash（redis:5.0.8 的 /bin/sh）+ `local` + `$()` + `set -e` → 脚本静默退出。
**方案**: 移除所有 `set -e`，改为显式 `||` 错误处理。
**详见**: [docs/pitfalls.md](docs/pitfalls.md) 坑 1。

### 4. startup.sh 三分支决策 + 死 IP fallback

```
1. 问 sentinel → 有 master → 验证可达 → 可达则跟随
2. 问 sentinel → 有 master → 验证失败 → fallback 到冷启动
3. 无 sentinel → ordinal=0 → 自举 master
4. 无 sentinel → ordinal>0 → 等 redis-0（永不自举，防脑裂）
```

**关键改进**:
- ordinal>0 **无 standalone fallback** — 宁可 crash loop 也不脑裂
- sentinel 返回死 IP 时 fallback 到冷启动（全集群重启自愈）

### 5. Redis 5.0.x DNS 限制

**问题**: Redis 5 Sentinel 不支持 `sentinel resolve-hostnames`，monitor 目标必须是 IP。
**方案**: entrypoint.sh 用 `getent hosts` 解析 DNS→IP。
**冷启动**: DNS 在 pod 未就绪时不解析 → 20 次重试（~60s）覆盖启动时间。

## 编码规范

### Shell 脚本

1. **不设 `set -e`**: dash 兼容性问题（见坑 1）。用 `set -u`（未定义变量报错）+ 显式 `||` 错误处理。
2. **不设 `set -o pipefail`**: dash 不支持。用 `command | grep -q . || exit 1` 替代。
3. **`local` 慎用**: dash 中 `local x="$(cmd)"` 在 cmd 失败时可能静默退出。改为 `x="$(cmd)"` 不加 `local`。
4. **`timeout` 包裹外部命令**: redis-cli 等可能 hang，用 `timeout 2 redis-cli ...` 防止脚本卡死。
5. **错误信息前缀**: 用 `[role]`、`[cold]`、`[warn]`、`[error]` 等前缀，便于日志检索。
6. **注释说明 "为什么"**: 不解释 "做什么"（代码已说明），解释 "为什么这么做"（决策理由）。

### YAML

1. **资源名含实例前缀**: 所有资源名以 `<instance>` 开头，支持多实例隔离。
2. **label 规范**:
   - `app: <instance>` 或 `app: <instance>-sentinel`
   - `redis-role: master|slave`（仅 Redis pod，由 role-tagger 维护）
3. **Pod 管理策略**: 一律 `Parallel`，防脑裂逻辑在脚本层。
4. **探针**: startup/readiness/liveness 三件套，startup 给足冷启动时间。
5. **checksum/config 注解**: ConfigMap 变更时自动滚动重启 Pod。

### Helm Chart

1. **values 结构**: `common`（共享）+ `redis`（Redis pod）+ `sentinel`（Sentinel pod），按 Pod 划分而非按功能划分。
2. **config 用数组**: `redis.config` 和 `sentinel.config` 是字符串数组，每项一行直接追加到 conf 文件，无需关心 key 名。
3. **namespace 不在 values**: 由 Helm `-n` 参数决定，模板用 `.Release.Namespace`。
4. **instanceName 默认 release name**: 用户不指定时用 `.Release.Name`。
5. **条件渲染**: exporter/persistence/pdb 等用 `{{- if .Values.xxx.enabled }}` 控制。

## 文件角色

### 根目录

| 文件 | 用途 |
|------|------|
| `test.sh` | 测试脚本（基于 Helm，支持 full/install/verify/failover/stability/cleanup） |
| `README.md` | 项目说明 |
| `AGENTS.md` | 本文件（给 AI 协作者参考） |

### Helm Chart（`helm/redis-sentinel/`）

| 文件 | 用途 |
|------|------|
| `Chart.yaml` | Chart 元数据 |
| `values.yaml` | 可配置参数（common + redis + sentinel） |
| `templates/_helpers.tpl` | 模板助手（名称/标签/镜像/探针） |
| `templates/secret.yaml` | 密码 Secret |
| `templates/configmap-redis.yaml` | redis.conf + startup.sh |
| `templates/configmap-sentinel.yaml` | entrypoint.sh |
| `templates/services.yaml` | 6 个 Service |
| `templates/statefulset-redis.yaml` | Redis StatefulSet |
| `templates/statefulset-sentinel.yaml` | Sentinel StatefulSet |
| `templates/pdb.yaml` | 2 个 PDB |
| `templates/rbac.yaml` | role-tagger RBAC（resourceNames 限当前实例 3 pod，仅 get/patch） |
| `templates/networkpolicy.yaml` | NetworkPolicy（可选，限同实例+业务 pod+Prometheus 入站） |
| `templates/servicemonitor.yaml` | ServiceMonitor + PrometheusRule（可选，11 条告警） |
| `templates/backup-secret.yaml` | 备份对象存储凭证 Secret（可选，`backup.enabled` 且未用 `existingSecret`） |
| `templates/backup-cronjob.yaml` | 备份 CronJob（可选，`redis-cli --rdb` → gzip → `rclone copyto` → 保留清理） |
| `templates/NOTES.txt` | 部署后提示 |

### 文档（`docs/`）

| 文件 | 用途 |
|------|------|
| `README.md` | 文档索引 |
| `architecture.md` | 架构设计与鲁棒性 |
| `multi-instance.md` | 多实例隔离与命名规范 |
| `helm.md` | Helm Chart 使用与配置 |
| `monitoring.md` | Prometheus 监控配置 |
| `backup.md` | 备份与恢复（CronJob → 对象存储，rclone 支持 S3/MinIO/阿里云 OSS/腾讯云 COS/AWS S3 等 40+ 后端） |
| `production.md` | 生产就绪评估 |
| `production-drills.md` | 生产故障演练清单（节点 drain/网络分区/多数派丢失等） |
| `attempts.md` | 设计演进与尝试路径 |
| `pitfalls.md` | 踩坑记录与解决方案 |

## 健康检查参数

| Component | Probe | InitialDelay | Period | FailureThreshold | MaxWait |
|-----------|-------|--------------|--------|-----------------|---------|
| redis | startup | 5s | 5s | 30 | 150s |
| redis | readiness (PING) | 5s | 5s | 3 | 20s |
| redis | liveness | 10s | 10s | 3 | 40s |
| sentinel | startup | 5s | 5s | 40 | 200s |
| sentinel | readiness | 5s | 5s | 3 | 20s |
| sentinel | liveness | 10s | 10s | 3 | 40s |

## 修改代码前的检查清单

1. 是否破坏了防脑裂逻辑？（ordinal>0 永不自举）
2. 是否引入了 `set -e`？（dash 兼容性）
3. 是否引入了 readinessProbe=ROLE？（事件风暴）
4. 资源名是否含实例前缀？（多实例隔离）
5. ConfigMap 变更是否会触发 Pod 滚动重启？（checksum 注解）
6. 是否更新了相关文档？（docs/ 下的对应文件）
