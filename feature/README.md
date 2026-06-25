# 功能文档索引

每个功能文档统一结构：**架构设计 → 实现设计 → 使用说明 → 校验 → 清理**。

> 与 [docs/](../docs/) 的区别：`docs/` 偏架构与运维总览，`feature/` 偏每个功能的完整闭环（含校验与清理命令），便于交付验收与回归测试。

| # | 功能 | 文档 | 关键词 |
|---|------|------|--------|
| 01 | 自动故障转移 | [01-failover.md](01-failover.md) | Sentinel 选举、~15s 切换、quorum |
| 02 | Master 流量切换 | [02-master-routing.md](02-master-routing.md) | role-tagger、应用零改动、零事件风暴 |
| 03 | 防脑裂启动 | [03-split-brain-prevention.md](03-split-brain-prevention.md) | ordinal>0 不自举、Parallel、crash loop |
| 04 | 多实例隔离 | [04-multi-instance-isolation.md](04-multi-instance-isolation.md) | instanceName 前缀、RBAC 锁定 |
| 05 | 监控告警 | [05-monitoring.md](05-monitoring.md) | ServiceMonitor、PrometheusRule、11 条告警 |
| 06 | 网络隔离 | [06-network-policy.md](06-network-policy.md) | NetworkPolicy、最小放行 |
| 07 | 备份恢复 | [07-backup-restore.md](07-backup-restore.md) | CronJob、redis-cli --rdb、rclone（S3/MinIO/OSS/COS/Azure） |

## 通用约定

- 测试命名空间：`redis`（如无特别说明）
- 测试实例名：`ftest`（每篇文档可独立使用）
- 所有命令在仓库根目录 `/Users/czw/code/redis-sentinel-k8s` 执行
- 校验命令可直接复制粘贴执行
- 清理命令保证幂等，重复执行不报错
