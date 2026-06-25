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

**但还不能直接投入生产**，存在以下不足：

| 类别 | 问题 | 风险 |
|------|------|------|
| 版本 | Redis 5.0.8（2019），有已知 CVE | 安全风险 |
| 测试覆盖 | 只在 k3s 单节点测过，未测节点宕机/网络分区/磁盘满 | 生产场景未验证 |
| 备份 | 无外部备份机制（RDB/AOF 只在 PVC 内） | PVC 丢失=数据丢失 |
| 监控 | 只有 metrics 暴露，无 ServiceMonitor/PrometheusRule/告警 | 故障无感知 |
| 密码 | values.yaml 明文密码 | 应用 externalSecret + KMS |
| 网络 | 无 NetworkPolicy | 任意 pod 可访问 |
| PVC | Helm uninstall 不删 PVC（K8s 默认） | 残留资源 |

**建议**：上生产前至少补齐备份、监控告警、NetworkPolicy，并做多节点故障演练。

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