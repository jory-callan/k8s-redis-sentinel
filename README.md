# Redis-Sentinel on K8s

1主2从 Redis Sentinel 自动故障转移集群，纯 K8s 原生 YAML，零 Operator。

Redis 5.0.8 · K8s 1.19+ · 应用零改动 · Prometheus Exporter · 密码认证 · 多实例隔离

---

## 特性

- **自动故障转移**: master 宕机 ~15s 内 sentinel 选举新 master，Service 自动切流量
- **应用零改动**: `<instance>-master.svc` 始终指向当前 master，业务无需感知 failover
- **防脑裂**: 三重保险（脚本防自举 + `min-slaves-to-write` + sentinel quorum）
- **多实例隔离**: 同命名空间可部署多套集群，按业务实例名隔离所有资源
- **零事件风暴**: role-tagger sidecar + label 路由，替代 readinessProbe=ROLE 方案
- **Prometheus 监控**: 内置 redis_exporter sidecar（Redis + Sentinel 各一个）
- **密码认证**: 可选，支持 existingSecret
- **持久化**: 可选 PVC 或 emptyDir

## 部署方式

### 方式 1: Helm Chart（推荐）

```bash
# 默认实例 (instance=release name)
helm install my-redis ./helm/redis-sentinel -n redis --create-namespace

# 业务实例 (推荐: 中间件前缀+业务名)
helm install log ./helm/redis-sentinel -n redis \
  --set common.instanceName=redis-saas-log \
  --set common.auth.password=mypassword

# 自定义配置
helm install log ./helm/redis-sentinel -n redis -f my-values.yaml
```

详见 [docs/helm.md](docs/helm.md)。

### 方式 2: 原生 YAML + 脚本

```bash
# 默认实例 (instance=redis, ns=redis)
./install.sh

# 业务实例
./install.sh redis-saas-log

# 指定命名空间
./install.sh redis-saas-log middleware
```

## 验证

```bash
# 状态检测
./check.sh                             # 默认实例
./check.sh redis-saas-log               # 业务实例
./check.sh redis-saas-log middleware

# 完整测试 (含 failover 验证)
./test.sh                              # 默认实例
./test.sh redis-saas-log               # 业务实例
# Modes: install | verify | failover | cleanup | full (默认)
```

## 清理

```bash
# Helm 方式
helm uninstall <release> -n <namespace>
kubectl -n <namespace> delete pvc data-<instance>-0 data-<instance>-1 data-<instance>-2

# 脚本方式 (交互确认)
./cleanup.sh                            # 默认实例
./cleanup.sh redis-saas-log             # 业务实例
```

> **注意**: StatefulSet 的 PVC 默认不会被 K8s 自动删除，需手动清理。

## 应用连接

以 instance=`redis-saas-log`、ns=`redis` 为例：

| 用途 | 地址 |
|------|------|
| 写操作 (Master) | `redis-saas-log-master.redis.svc:6379` |
| 读操作 (所有节点) | `redis-saas-log-read.redis.svc:6379` |
| Sentinel | `redis-saas-log-sentinel-0.redis-saas-log-sentinel-hl.redis.svc:26379` |
| Redis 指标 | `redis-saas-log-exporter.redis.svc:9121` |
| Sentinel 指标 | `redis-saas-log-sentinel-exporter.redis.svc:9121` |

```bash
# 带密码连接
redis-cli -h redis-saas-log-master.redis.svc -a 'redis123'

# 从 Secret 获取密码
kubectl get secret redis-saas-log-secret -n redis -o jsonpath='{.data.redis-password}' | base64 -d
```

## 文档

完整文档位于 [docs/](docs/) 目录：

- [docs/README.md](docs/README.md) — 文档索引
- [docs/architecture.md](docs/architecture.md) — 架构设计与鲁棒性
- [docs/multi-instance.md](docs/multi-instance.md) — 多实例隔离与命名规范
- [docs/helm.md](docs/helm.md) — Helm Chart 使用与配置
- [docs/monitoring.md](docs/monitoring.md) — Prometheus 监控配置
- [docs/production.md](docs/production.md) — 生产就绪评估
- [docs/attempts.md](docs/attempts.md) — 设计演进与尝试路径
- [docs/pitfalls.md](docs/pitfalls.md) — 踩坑记录与解决方案

[AGENTS.md](AGENTS.md) — 项目目标、方案与编码规范（给 AI 协作者参考）。

## 已知限制

- **Redis 5.0.x**: 不支持 `sentinel resolve-hostnames`，需显式 DNS→IP 转换
- **PVC 要求**: 启用持久化时集群需有默认 StorageClass
- **冷启动**: `<instance>-0` 必须可调度，否则 `<instance>-1/2` 会 crash loop 等待
- **实例名长度**: 最长 42 字符（Pod 名需 ≤ 63 字符）
