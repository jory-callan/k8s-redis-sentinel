# 生产就绪评估

## 稳定性评估

**已验证的能力**（实测通过）：
- 部署、复制、读写分离正常
- 故障转移 ~15s 完成，Service 自动切流量
- role-tagger 标签正确更新
- exporter 指标正常暴露

**但还不能直接投入生产**，存在以下不足：

| 类别 | 问题 | 风险 |
|------|------|------|
| 版本 | Redis 5.0.8（2019），有已知 CVE | 安全风险 |
| 测试覆盖 | 只在 k3s 单节点测过，未测节点宕机/网络分区/磁盘满 | 生产场景未验证 |
| 备份 | 无外部备份机制（RDB/AOF 只在 PVC 内） | PVC 丢失=数据丢失 |
| 监控 | 只有 metrics 暴露，无 ServiceMonitor/PrometheusRule/告警 | 故障无感知 |
| 密码 | values.yaml 明文密码 | 应用 externalSecret + KMS |
| 网络 | 无 NetworkPolicy | 任意 pod 可访问 |
| role-tagger | 依赖 exporter 存活，exporter 挂则标签不更新 | 路由卡在旧 master |
| PVC | Helm uninstall 不删 PVC（K8s 默认） | 残留资源 |

**建议**：上生产前至少补齐备份、监控告警、NetworkPolicy，并做多节点故障演练。

## role-tagger 切换机制

是**定时轮询**，不是事件驱动。看 [statefulset-redis.yaml](file:///Users/czw/code/redis-sentinel-k8s/helm/redis-sentinel/templates/statefulset-redis.yaml) 的 sidecar 逻辑：

```
while true; do
  1. curl http://127.0.0.1:9121/metrics 获取 redis_instance_info
  2. 从中提取 role="master" 或 role="slave"
  3. 只有 role 变化时才 PATCH pod label（减少 API 压力）
  4. sleep 5s
done
```

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

**潜在问题**：如果 exporter 容器挂了，role-tagger 拿不到 metrics，标签不会更新，Master Service 会卡在旧 master。livenessProbe 会在 60s 后重启 sidecar，但期间路由是错的。生产建议加 exporter 健康告警。