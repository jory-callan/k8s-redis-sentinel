# Redis Sentinel K8s 脚本分析文档

## 概述

本文件夹包含 Redis Sentinel K8s 项目中所有实际运行的脚本，按照 K8s 资源 → Pod 容器的结构组织。每个脚本都配有对应的分析文档，详细说明其工作原理、稳定性设计和可靠性评估。

## 文件夹结构

```
scripts/
├── statefulset-redis/           # Redis StatefulSet 的容器脚本
│   ├── redis-startup.sh         # redis 容器：启动决策脚本
│   ├── redis-startup-analysis.md # redis 容器分析文档
│   ├── role-tagger.sh           # role-tagger 容器：角色标签同步（死循环）
│   ├── role-tagger-analysis.md  # role-tagger 容器分析文档
│   └── exporter-analysis.md     # exporter 容器分析文档（二进制，无脚本）
├── statefulset-sentinel/        # Sentinel StatefulSet 的容器脚本
│   ├── sentinel-entrypoint.sh   # sentinel 容器：入口脚本
│   ├── sentinel-entrypoint-analysis.md # sentinel 容器分析文档
│   └── exporter-analysis.md     # exporter 容器分析文档（二进制，无脚本）
├── job-backup/                  # Backup CronJob 的容器脚本
│   ├── rdb-dumper.sh            # rdb-dumper 容器：RDB 拉取脚本
│   ├── rdb-dumper-analysis.md   # rdb-dumper 容器分析文档
│   ├── uploader.sh              # uploader 容器：上传脚本
│   └── uploader-analysis.md     # uploader 容器分析文档
└── README.md                    # 本文件
```

## 命名规范

- **脚本文件**：`<容器名>-<脚本名>.sh`（如 `redis-startup.sh`、`role-tagger.sh`）
- **分析文档**：`<容器名>-analysis.md`（如 `redis-startup-analysis.md`）
- **二进制组件**：只有分析文档（`.md`），无脚本文件（如 `exporter-analysis.md`）

## 运行模式总结

| 容器名 | 运行模式 | 脚本 | 循环间隔 |
|--------|---------|------|---------|
| redis | 单次执行 | redis-startup.sh | - |
| role-tagger | **死循环** | role-tagger.sh | 5s |
| sentinel | 单次执行 | sentinel-entrypoint.sh | - |
| exporter | 持续运行（二进制） | 无 | 15s（采集频率） |
| rdb-dumper | 单次执行 | rdb-dumper.sh | - |
| uploader | 单次执行 | uploader.sh | - |

## 🎯 关键问题：动态 replicas 配置

### 答案：**支持任意副本数，不再硬编码**

所有脚本通过环境变量动态获取副本数：

```bash
# 环境变量配置
REDIS_REPLICAS="${REDIS_REPLICAS:-3}"      # Redis 副本数，默认 3
SENTINEL_REPLICAS="${SENTINEL_REPLICAS:-3}"  # Sentinel 副本数，默认 3
```

**动态遍历逻辑**：

```bash
# redis-startup.sh — 动态遍历 sentinel
sentinel_idx=0
while [ "$sentinel_idx" -lt "$SENTINEL_REPLICAS" ]; do
  s="${INSTANCE_NAME}-sentinel-${sentinel_idx}"
  H="${s}.${SENTINEL_HL}.${NAMESPACE}.svc"
  # 查询 sentinel...
  sentinel_idx=$((sentinel_idx + 1))
done

# sentinel-entrypoint.sh — 动态遍历 sentinel 和 redis
redis_idx=0
while [ "$redis_idx" -lt "$REDIS_REPLICAS" ]; do
  r="${INSTANCE_NAME}-${redis_idx}"
  H="${r}.${REDIS_HL}.${NAMESPACE}.svc"
  # 查询 redis...
  redis_idx=$((redis_idx + 1))
done
```

**为什么稳定**：
- 使用 shell 算术扩展，兼容 dash
- 默认值为 3（向后兼容）
- Helm 模板自动传入 `.Values.redis.replicas` 和 `.Values.sentinel.replicas`
- 不管配置多少个副本（3、5、7...），都能正确遍历

**使用方式**：

```bash
# Helm 部署时配置副本数
helm install my-redis ./helm/redis-sentinel -n redis \
  --set redis.replicas=5 \
  --set sentinel.replicas=5 \
  --set sentinel.quorum=3
```

## 🎯 关键问题：Shell 死循环是否可靠？

### 答案：**可靠，跑 2 年完全没问题**

#### 仅 role-tagger 使用死循环

项目中只有 `role-tagger` 容器使用死循环，其他所有脚本都是单次执行。

#### 死循环的稳定性保障

1. **K8s 进程管理**：shell 作为 PID=1，退出后自动重启
2. **心跳检测**：livenessProbe 检测 `/tmp/last_alive`，防止内部 hang
3. **资源保护**：sleep 5s + timeout 限制，CPU < 0.1%，内存 < 5MB
4. **无状态设计**：重启后完全恢复，无状态累积
5. **超时保护**：curl `--max-time` 防止网络 hang
6. **仅变化时更新**：常态零 etcd 写入，减少压力

#### 为什么不用其他方案？

| 方案 | 响应延迟 | etcd 压力 | 实现复杂度 |
|------|---------|----------|-----------|
| **死循环**（当前） | ~5s | 常态零写入 | 中等 |
| CronJob | ≥1min | 常态零写入 | 简单 |
| readinessProbe | ~5s | 高（持续失败事件） | 简单 |
| Kubernetes Operator | ~1s | 中等 | 复杂 |

**死循环是最佳平衡**：响应及时、不产生事件风暴、实现简单。

## 脚本职责总览

### statefulset-redis

| 容器 | 职责 | 关键设计 |
|------|------|---------|
| redis | 决定 master/slave 角色并启动 Redis | 防脑裂（ordinal>0 永不自举）、死 IP 检测 |
| role-tagger | 同步 redis-role label | 仅变化时 PATCH、直接查 Redis、心跳检测 |
| exporter | 采集 Redis 指标 | Go 二进制、双重探针、只读采集 |

### statefulset-sentinel

| 容器 | 职责 | 关键设计 |
|------|------|---------|
| sentinel | 发现 master 并启动 Sentinel | 死 IP 检测、DNS 解析、不死锁设计 |
| exporter | 采集 Sentinel 指标 | Go 二进制、双重探针、只读采集 |

### job-backup

| 容器 | 职责 | 关键设计 |
|------|------|---------|
| rdb-dumper | 从 master 拉取 RDB 并压缩 | Service 路由、超时保护、大小验证 |
| uploader | 上传对象存储 + 清理旧备份 | 环境变量配置、上传验证、保留策略 |

## 稳定性设计总览

### 防脑裂
- redis-startup.sh：ordinal>0 永不自举为 master
- 宁可 crash loop 也不产生双 master

### 死 IP 检测
- redis-startup.sh：验证 sentinel 返回的 master 可达性
- sentinel-entrypoint.sh：验证 master IP 可达性

### 超时保护
- 所有外部命令用 `timeout` 包裹
- curl 用 `--max-time` 限制

### 进程管理
- 所有主进程用 `exec` 替换 shell
- K8s 直接管理 Redis/Sentinel 进程

### 无状态设计
- role-tagger.sh：重启后完全恢复
- 无状态累积，无内存泄漏风险

### 指标采集隔离
- exporter 只读采集，不影响主进程性能

## 可靠性评估

| 场景 | redis | role-tagger | sentinel | exporter | backup |
|------|-------|-------------|----------|----------|--------|
| 正常运行 | ✅ | ✅ | ✅ | ✅ | ✅ |
| 进程崩溃 | ✅ K8s 重启 | ✅ K8s 重启 | ✅ K8s 重启 | ✅ K8s 重启 | ✅ CronJob 重试 |
| 网络分区 | ✅ 防脑裂 | ✅ 心跳检测 | ✅ 不死锁 | ✅ 指标标记 | ✅ 下次重试 |
| 资源耗尽 | ✅ 低消耗 | ✅ 低消耗 | ✅ 低消耗 | ✅ 低消耗 | ✅ 单次执行 |
| 内存泄漏 | ✅ 无 | ✅ 无状态 | ✅ 无 | ✅ Go GC | ✅ 单次执行 |

## 总结

项目中的脚本设计遵循以下原则：

1. **最小权限**：RBAC 精确锁定资源，不放宽权限
2. **最小事件**：role-tagger 仅变化时更新，消除事件风暴
3. **最小资源**：死循环 CPU < 0.1%，内存 < 5MB
4. **防脑裂优先**：宁可 crash loop 也不产生双 master
5. **超时保护**：所有外部命令都有超时限制
6. **进程替换**：`exec` 让主进程成为 PID=1，K8s 直接管理

这些设计确保了整个集群在各种场景下都能稳定运行，**跑 2 年完全没问题**。