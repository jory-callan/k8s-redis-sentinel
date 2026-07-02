# AGENTS.md — Redis-Standalone K8s 项目上下文

> 本文档面向 AI 协作者（如 Cursor、Copilot、Claude Code），描述项目目标、方案选型与编码规范。修改代码前请先通读本文。

## 项目目标

构建一个 **生产可用、零 Operator、应用零改动** 的 Redis 单机模式部署，运行在 Kubernetes 上。

### 核心目标

1. **简单可靠**: 单副本 Deployment + PVC，最少移动部件
2. **数据持久**: PVC + RDB 快照，Pod 重启数据不丢
3. **可观测**: 内置 Prometheus exporter，支持监控告警
4. **可备份**: CronJob 定时拉 RDB 上传对象存储（数据安全最后防线）
5. **多实例隔离**: 同命名空间可部署多套，按实例名隔离
6. **与 sentinel chart 隔离**: 独立 label 前缀，可同集群混部

### 非目标

- **不提供故障转移** — master 宕机即停服，靠 Pod 重启恢复（如需 failover 用 `redis-sentinel` chart）
- **不提供数据复制** — 单点无副本，数据安全靠 PVC + 备份
- **不追求高可用** — 适用缓存/非关键业务/可接受短暂中断的场景
- **不内置主从切换** — 单机模式无 slave 概念

### 与 redis-sentinel chart 的关系

本 chart 与同仓库的 `redis-sentinel` chart **互补**，非替代：

| 维度 | redis-standalone | redis-sentinel |
|------|-----------------|----------------|
| 工作负载 | Deployment（1 副本） | StatefulSet（3 副本 + 3 哨兵） |
| 故障转移 | 无 | ~15s 自动 |
| 数据安全 | PVC + 备份 | PVC + 实时复制 |
| 适用 | 缓存/非关键 | 关键业务 |
| Label 前缀 | `redis-standalone.k8s.io/*` | `redis-sentinel.k8s.io/*` |
| 复杂度 | 低 | 高 |

## 技术栈

- Redis 6.2（官方镜像）
- K8s 1.19+
- 纯 YAML + Shell 脚本（零 Operator）
- Helm Chart
- Prometheus redis_exporter

## 方案选型

### 1. Deployment 替代 StatefulSet

**原因**: 单机模式无需稳定网络标识（无主从复制、无哨兵查询），Deployment 更简单。
**PVC 处理**: Deployment 不支持 `volumeClaimTemplates`（StatefulSet 专属），故独立创建 PVC 资源由 Deployment 引用。
**风险**: Pod 重新调度到其他节点时，若 StorageClass 不支持跨节点挂载（如 local-path），PVC 可能无法挂载导致 Pod Pending。建议用网络存储（CSI/网络块存储）。

### 2. 独立 Label 前缀

**原因**: 与 `redis-sentinel` chart 区分，两者可同集群混部不冲突。
**方案**: 使用 `redis-standalone.k8s.io/*` 前缀（sentinel chart 用 `redis-sentinel.k8s.io/*`）。
**selector**: 三维匹配 `chart + instance + component`，彻底隔离。

### 3. PDB 默认禁用

**问题**: 单副本 + PDB `minAvailable:1` 会阻塞所有 voluntary eviction（含节点 drain），导致集群运维受阻。
**方案**: 默认禁用 PDB，仅在需要严格阻止驱逐时显式启用。

### 4. 无 sidecar（仅 exporter）

**对比**: sentinel chart 有 role-tagger sidecar（PATCH pod label 维护 master/slave 角色）。单机模式无角色概念，无需 role-tagger，故无 ServiceAccount/RBAC。
**仅有**: exporter sidecar（可选，Prometheus 抓取）。

### 5. 不设 set -e

**原因**: dash（redis 镜像的 /bin/sh）+ `local` + `$()` + `set -e` → 脚本静默退出（与 sentinel chart 同坑）。
**方案**: 移除 `set -e`，用 `set -u` + 显式 `||` 错误处理。

### 6. startup.sh 极简

**对比**: sentinel chart 的 startup.sh 有三分支角色决策（sentinel 查询 + DNS 扫描 + 冷启动）。
**单机**: 无角色决策，直接 `exec redis-server /data/redis.conf`，仅处理密码注入。

## 编码规范

### Shell 脚本

1. **不设 `set -e`**: dash 兼容性问题。用 `set -u` + 显式 `||` 错误处理。
2. **不设 `set -o pipefail`**: dash 不支持。
3. **`local` 慎用**: dash 中 `local x="$(cmd)"` 在 cmd 失败时可能静默退出。
4. **`timeout` 包裹外部命令**: redis-cli 等可能 hang。
5. **错误信息前缀**: 用 `[startup]`、`[auth]`、`[role]`、`[error]` 等前缀。
6. **注释说明 "为什么"**: 不解释 "做什么"。

### YAML

1. **资源名含实例前缀**: 所有资源名以 `<instance>` 开头。
2. **label 规范**:
   - `app: <instance>`（可读性）
   - `redis-standalone.k8s.io/chart: redis-standalone`（chart 标识，固定值）
   - `redis-standalone.k8s.io/instance: <instance>`（实例隔离，用于 selector）
   - `redis-standalone.k8s.io/component: redis|backup`（组件区分，用于 selector）
   - 所有 Deployment/Service/NetworkPolicy/PDB selector 使用 `redis-standalone.k8s.io/*` 三元组
3. **探针**: startup/readiness/liveness 三件套。
4. **checksum/config 注解**: ConfigMap 变更时自动滚动重启 Pod。

### Helm Chart

1. **values 结构**: `common`（共享）+ `redis`（Redis pod），单 pod 无需按功能划分。
2. **config 用数组**: `redis.config` 是字符串数组，每项一行直接追加到 conf 文件。
3. **namespace 不在 values**: 由 Helm `-n` 参数决定，模板用 `.Release.Namespace`。
4. **instanceName 默认 release name**: 用户不指定时用 `.Release.Name`。
5. **条件渲染**: exporter/persistence/pdb/networkpolicy/monitoring/backup 用 `{{- if .Values.xxx.enabled }}` 控制。

## 文件角色

### Helm Chart（`helm/redis-standalone/`）

| 文件 | 用途 |
|------|------|
| `Chart.yaml` | Chart 元数据 |
| `values.yaml` | 可配置参数（common + redis） |
| `templates/_helpers.tpl` | 模板助手（名称/标签/镜像/探针） |
| `templates/secret.yaml` | 密码 Secret |
| `templates/configmap.yaml` | redis.conf + startup.sh |
| `templates/pvc.yaml` | 数据 PVC（持久化） |
| `templates/deployment.yaml` | Redis Deployment（含 exporter sidecar） |
| `templates/service.yaml` | 2 个 Service（redis + exporter） |
| `templates/pdb.yaml` | PDB（默认禁用） |
| `templates/networkpolicy.yaml` | NetworkPolicy（可选） |
| `templates/servicemonitor.yaml` | ServiceMonitor + PrometheusRule（可选，6 条告警） |
| `templates/backup-secret.yaml` | 备份对象存储凭证 Secret（可选） |
| `templates/backup-cronjob.yaml` | 备份 CronJob（可选，rclone 上传） |
| `templates/NOTES.txt` | 部署后提示 |

### 根目录

| 文件 | 用途 |
|------|------|
| `README.md` | 项目说明 + 恢复时间表 |
| `AGENTS.md` | 本文件（给 AI 协作者参考） |

## 健康检查参数

| Probe | InitialDelay | Period | FailureThreshold | MaxWait |
|-------|--------------|--------|-----------------|---------|
| startup | 5s | 5s | 30 | 150s |
| readiness | 5s | 5s | 3 | 20s |
| liveness | 30s | 10s | 3 | 60s |

> 单机模式无冷启动等待逻辑，liveness initialDelay 仅需覆盖 RDB 加载时间。

## 修改代码前的检查清单

1. 是否破坏了单机模式的简单性？（不应引入复制/sentinel/角色决策）
2. 是否引入了 `set -e`？（dash 兼容性）
3. 资源名是否含实例前缀？（多实例隔离）
4. Label 是否用了 `redis-standalone.k8s.io/*` 前缀？（与 sentinel chart 隔离）
5. ConfigMap 变更是否会触发 Pod 滚动重启？（checksum 注解）
6. PVC 是否被 Deployment 正确引用？（pvc.yaml + deployment.yaml 一致）
7. 是否更新了 README 的恢复时间表？（如有参数影响恢复时间）
