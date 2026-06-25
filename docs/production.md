# 生产就绪评估

## 稳定性评估

**已验证的能力**（实测通过）：
- 部署、复制、读写分离正常
- 故障转移 ~15s 完成，Service 自动切流量
- role-tagger 标签正确更新（直接查 redis，不依赖 exporter）
- exporter 挂掉不影响 role-tagger 工作（实测验证）
- exporter 指标正常暴露

**稳定性测试矩阵**（down-after=1s, failover-timeout=5s 极限参数实测）：

| 场景 | 操作 | 结果 |
|------|------|------|
| 1 | 断开 1 个 redis (slave) | ✓ 自动恢复，读写正常 |
| 2 | 断开 2 个 redis | ✓ 自动恢复，读写正常 |
| 3 | 断开全部 3 个 redis | ✓ 全集群重启自愈，读写正常 |
| 4 | 断开 1 个 sentinel | ✓ 集群稳定，读写正常 |
| 5 | 断开 2 个 sentinel (剩 1) | ✓ 无 failover，保持原 master |
| 6 | 断开全部 3 个 sentinel | ✓ 集群仍运行（仅无法 failover） |
| 7 | 同时断开 1 redis + 1 sentinel | ✓ failover 成功，读写正常 |
| 8 | 同时断开 2 redis + 2 sentinel | ✓ 自动恢复，读写正常 |
| 9 | 同时断开全部 3 redis + 3 sentinel | ✓ 全集群重启自愈 |
| 10 | RBAC 越权测试 | ✓ patch 其他 pod 被 403 拒绝 |

**关键结论**：
- 单点故障（1 个 pod 挂）：无感知，自动恢复
- 多点故障（2 个挂）：failover 后恢复，~15s 不可写
- 全集群故障（全挂）：重启后自动自愈，ordinal=0 自举 master
- sentinel 全挂：不影响运行，只影响 failover 能力
- RBAC 最小权限：只能 patch 当前实例的 3 个 redis pod，无法 list/update/操作其他 pod

**生产就绪进展**（除备份外已补齐关键项）：

| 类别 | 状态 | 说明 |
|------|------|------|
| 监控告警 | ✅ 已完成 | Chart 内置 `ServiceMonitor` + `PrometheusRule`（11 条告警），`monitoring.enabled=true` 即启用，详见 [monitoring.md](monitoring.md) |
| 网络隔离 | ✅ 已完成 | Chart 内置 `NetworkPolicy` 模板，`networkPolicy.enabled=true` 即启用，仅放行同实例 pod + 配置的业务 pod + Prometheus 抓取 |
| 内存上限 | ✅ 已完成 | `redis.maxmemory` + `redis.maxmemoryPolicy` 可配置，防 OOM；`check.sh` 显示使用率并 >80% 告警 |
| 密码 | ✅ 保留现状 | `password` 明文 / `existingSecret` 两种方式均可用（按需选择） |
| 备份 | ✅ 已完成 | Chart 内置备份 CronJob（`backup.enabled=true`），`redis-cli --rdb` 拉取 → gzip → 上传 MinIO/S3，含保留策略与恢复流程；实测备份/恢复链路通过，详见 [backup.md](backup.md) |
| 版本 | ⚠️ 评估 | Redis 5.0.8（项目非目标锁定 5.0.x，需评估可接受 CVE） |
| 演练覆盖 | ⚠️ 待补 | k3s 多节点已测，生产节点 drain/网络分区演练见 [production-drills.md](production-drills.md) |
| PVC | ⚠️ 保留 | K8s 默认 `helm uninstall` 不删 PVC（防误删）；`install.sh uninstall --purge` 可彻底清理 |

**建议**：补齐备份后即可承接生产负载；上核心业务前按 [production-drills.md](production-drills.md) 做节点级故障演练。

备份已就绪，建议同时：备份凭证改用 `existingSecret`（[backup.md](backup.md)），并在 [production-drills.md](production-drills.md) 的演练中加入"从 MinIO 恢复"一项。

## 生产推荐配置

```bash
helm install my-app ./helm/redis-sentinel -n redis \
  --set common.instanceName=my-app \
  --set common.auth.password=<强密码> \
  --set redis.maxmemory=1gb \
  --set redis.maxmemoryPolicy=allkeys-lru \
  --set networkPolicy.enabled=true \
  --set 'networkPolicy.redisIngressFrom[0].namespace=app' \
  --set 'networkPolicy.redisIngressFrom[0].podSelector.app=web' \
  --set monitoring.enabled=true \
  --set monitoring.alerts.enabled=true \
  --set backup.enabled=true \
  --set backup.endpoint=http://minio.minio.svc.cluster.local:80 \
  --set backup.bucket=redis-test \
  --set backup.existingSecret=my-app-backup-secret \
  --set backup.retentionDays=7
```

或在 `values.yaml` 自定义后 `helm install my-app ./helm/redis-sentinel -f my-values.yaml`。备份相关参数详见 [backup.md](backup.md)。

### 关键参数说明

| 参数 | 生产建议 | 说明 |
|------|---------|------|
| `redis.maxmemory` | `1gb`（按业务） | 设上限防 OOM，`0` = 无限制（不推荐生产） |
| `redis.maxmemoryPolicy` | `allkeys-lru` | 全键 LRU 淘汰，`noeviction` 满了直接拒绝写入 |
| `networkPolicy.enabled` | `true` | 限制 6379/26379 仅授权来源访问 |
| `networkPolicy.redisIngressFrom` | 业务 namespace | 允许哪些 pod 访问 Redis |
| `monitoring.enabled` | `true` | 需 Prometheus Operator |
| `monitoring.alerts.enabled` | `true` | 11 条关键告警 |
| `common.podAntiAffinity` | `true`（默认） | pod 跨节点分散（preferred） |

## role-tagger 切换机制

是**定时轮询**，不是事件驱动。看 [statefulset-redis.yaml](file:///Users/czw/code/redis-sentinel-k8s/helm/redis-sentinel/templates/statefulset-redis.yaml) 的 sidecar 逻辑：

```
while true; do
  1. curl telnet://127.0.0.1:6379 发送 AUTH + INFO replication (redis 协议)
  2. 从响应中提取 role:master 或 role:slave
  3. 只有 role 变化时才 PATCH pod label（减少 API 压力）
  4. sleep 5s
done
```

**关键改进**：直接用 curl telnet 模式发 redis 协议查询角色，**不依赖 exporter 容器**。即使 exporter 挂了，role-tagger 仍能正常工作（已实测验证）。

**不是"选举成功后立即切换"**，流程是：

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

**为什么不用事件驱动**：Redis 5 没有角色变更的 webhook/通知机制，只能轮询。轮询间隔 5s 是性能与延迟的折中——更短增加 API 压力，更长 failover 后写入延迟。

**为什么用 curl telnet 而非 redis-cli**：`curlimages/curl` 镜像只有 ~4MB，且 curl 支持 telnet 协议发送原始 redis 命令。`redis:alpine` 镜像虽有 redis-cli 但 busybox wget 不支持 PATCH method，无法调用 K8s API。curlimages/curl 同时满足两个需求（查 redis + 调 K8s API）。

**注意**：curlimages/curl 镜像的 curl 二进制在 `/usr/bin/curl`，但用 `command:` 覆盖 entrypoint 后 shell hash 缓存里没有 curl，需在脚本开头 `hash -r` 清除缓存。