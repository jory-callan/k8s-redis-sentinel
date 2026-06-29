## 集群不可用场景全分析

### 一、Redis 层

#### 场景1：全集群重启 + redis-0 无法启动

```
触发条件：
- 所有 redis pod 同时重启（如节点维护、升级）
- redis-0 的 PVC 损坏/丢失/无法挂载

发生概率：极低（需要 PVC 存储故障 + 全集群同时重启）

结果：
- redis-0 无法启动 → 无人自举为 master
- redis-1/2 → ordinal>0 永不自举 → crash loop
- ❌ 集群永久不可用（需人工删除 PVC 或修复存储）
```

**这是最严重的限制。**

#### 场景2：master 宕机 + 所有 slave 同时宕机

```
触发条件：
- master 所在节点故障
- slave 也在同一节点（未配置 podAntiAffinity）

发生概率：低（默认配置了 podAntiAffinity）

结果：
- 所有 redis 都宕机
- ❌ 集群不可用，直到 K8s 重新调度
```

#### 场景3：master 宕机 + slave 复制延迟过大

```
触发条件：
- master 持续高写入
- slave 复制延迟 > 10 秒
- master 宕机

发生概率：中（高负载场景）

结果：
- sentinel 选举新 master
- 但 slave 数据落后 → 数据丢失
- ⚠️ 集群可用但数据不完整
```

#### 场景4：master 宕机 + 无可用 slave

```
触发条件：
- master 宕机
- 所有 slave 的 replica-priority=0（永不成为 master）
- 或所有 slave 与 master 断开 > 10 秒

发生概率：极低（默认 priority=100）

结果：
- sentinel 无法找到合适的 slave
- ❌ failover 失败，集群不可用
```

#### 场景5：redis OOM 或资源耗尽

```
触发条件：
- maxmemory 设置过高
- 节点内存不足

发生概率：中（未正确配置资源限制）

结果：
- redis 被 OOMKill
- K8s 重启 pod
- ⚠️ 短暂不可用
```

---

### 二、Sentinel 层

#### 场景6：sentinel 数量不足 quorum

```
触发条件：
- quorum=2
- 2 个 sentinel 同时宕机
- 只剩 1 个 sentinel

发生概率：低

结果：
- master 宕机时无法达成 quorum
- ❌ 无法 failover，集群不可用
```

#### 场景7：sentinel 持久化配置损坏

```
触发条件：
- sentinel 的 /data/sentinel.conf 文件损坏
- 或 PVC 数据不一致

发生概率：极低

结果：
- sentinel 无法启动
- ❌ 无法监控，无法 failover
```

#### 场景8：sentinel failover 超时

```
触发条件：
- failover-timeout=5000（5秒）
- slave 数据量大，同步慢

发生概率：中（大数据量场景）

结果：
- failover 超时
- sentinel 重试
- ⚠️ 可能多次失败后才成功
```

#### 场景9：网络分区导致脑裂

```
触发条件：
- quorum=2
- 网络分区：分区 A(1 sentinel) + 分区 B(2 sentinel)
- 分区 B 触发 failover

发生概率：极低

结果：
- 分区 A：旧 master 继续运行
- 分区 B：新 master 被提升
- ❌ 双 master（脑裂）
- 恢复后数据冲突
```

#### 场景10：sentinel 选举抖动

```
触发条件：
- down-after-milliseconds=1000（1秒，极敏感）
- 网络抖动

发生概率：中（网络不稳定环境）

结果：
- sentinel 频繁触发 failover
- master 来回切换
- ⚠️ 集群不稳定，写入中断
```

---

### 三、K8s 基础设施层

#### 场景11：API server 不可用

```
触发条件：
- kube-apiserver 故障或过载

发生概率：低

结果：
- role-tagger 无法 PATCH label
- ❌ failover 后 Service 无法切换流量
- 应用连接旧 master（已宕机）→ 连接失败
```

**这是 role-tagger 方案的固有限制。**

#### 场景12：CoreDNS 故障

```
触发条件：
- CoreDNS 宕机或不可达

发生概率：低

结果：
- 脚本无法解析 DNS（redis-0.xxx.svc）
- ❌ redis 无法找到 master
- 应用无法连接 redis-master.svc
```

#### 场景13：kubelet 故障

```
触发条件：
- 节点 kubelet 宕机

发生概率：低

结果：
- pod 无法重启
- ❌ 集群无法恢复
```

#### 场景14：CNI 网络插件故障

```
触发条件：
- Calico/Flannel 等网络插件故障

发生概率：低

结果：
- pod 之间无法通信
- ❌ redis/sentinel/role-tagger 全部失效
```

#### 场景15：PVC 存储后端故障

```
触发条件：
- StorageClass 后端故障（如 NFS/Ceph 宕机）

发生概率：低

结果：
- PVC 无法挂载
- ❌ redis/sentinel 无法启动
```

---

### 四、role-tagger 层

#### 场景16：role-tagger 全部故障

```
触发条件：
- role-tagger sidecar 全部崩溃

发生概率：低（有 livenessProbe）

结果：
- label 不更新
- failover 后 Service 仍指向旧 master
- ❌ 流量不切换，应用连接失败
```

#### 场景17：role-tagger 延迟更新

```
触发条件：
- role-tagger 每 5 秒轮询一次
- failover 在两次轮询之间完成

发生概率：高（必然发生）

结果：
- 最坏情况延迟 5 秒
- ⚠️ 短暂流量中断（~5s）
```

---

### 五、配置错误

#### 场景18：密码不一致

```
触发条件：
- redis 密码与 sentinel 密码不一致

发生概率：低（Helm 统一配置）

结果：
- sentinel 无法 AUTH
- ❌ 无法监控 master
```

#### 场景19：NetworkPolicy 错误

```
触发条件：
- NetworkPolicy 阻止 redis-sentinel 通信
- 或阻止 role-tagger 访问 API server

发生概率：中（配置错误）

结果：
- ❌ sentinel 无法监控
- ❌ role-tagger 无法更新 label
```

---

### 六、数据层

#### 场景20：RDB/AOF 文件损坏

```
触发条件：
- PVC 数据损坏
- 或 redis 异常退出导致 RDB 不完整

发生概率：低

结果：
- redis 无法加载 RDB
- ❌ redis 无法启动
```

#### 场景21：主从复制数据不一致

```
触发条件：
- 异步复制
- master 写入后立即宕机
- slave 还没同步

发生概率：中（高写入场景）

结果：
- ⚠️ 数据丢失（最后一次同步后的写入）
```

---

### 概率与影响矩阵

| 场景 | 概率 | 影响 | 恢复时间 | 可自愈 |
|------|------|------|---------|--------|
| 1. 全集群重启+redis-0 PVC损坏 | 极低 | 致命 | 需人工 | ❌ |
| 2. master+slave同节点宕机 | 低 | 致命 | ~60s | ✅ |
| 3. slave复制延迟+master宕机 | 中 | 数据丢失 | 不可逆 | ❌ |
| 4. master宕机+无可用slave | 极低 | 致命 | 需人工 | ❌ |
| 5. redis OOM | 中 | 短暂中断 | ~30s | ✅ |
| 6. sentinel不足quorum | 低 | 致命 | 需人工 | ❌ |
| 7. sentinel配置损坏 | 极低 | 致命 | 需人工 | ❌ |
| 8. failover超时 | 中 | 短暂中断 | ~10s | ✅ |
| 9. 网络分区脑裂 | 极低 | 数据冲突 | 需人工 | ❌ |
| 10. 选举抖动 | 中 | 不稳定 | 持续 | ❌ |
| 11. API server故障 | 低 | 流量不切换 | 需人工 | ❌ |
| 12. CoreDNS故障 | 低 | 全面失效 | 需人工 | ❌ |
| 13. kubelet故障 | 低 | 无法恢复 | 需人工 | ❌ |
| 14. CNI故障 | 低 | 全面失效 | 需人工 | ❌ |
| 15. PVC后端故障 | 低 | 无法启动 | 需人工 | ❌ |
| 16. role-tagger全故障 | 低 | 流量不切换 | ~30s | ✅ |
| 17. role-tagger延迟 | 高 | 短暂中断 | ~5s | ✅ |
| 18. 密码不一致 | 低 | 无法监控 | 需人工 | ❌ |
| 19. NetworkPolicy错误 | 中 | 通信阻断 | 需人工 | ❌ |
| 20. RDB损坏 | 低 | 无法启动 | 需人工 | ❌ |
| 21. 复制数据丢失 | 中 | 数据丢失 | 不可逆 | ❌ |

---

### 最需要关注的 TOP 5 风险

| 排名 | 风险 | 原因 | 缓解措施 |
|------|------|------|---------|
| 1 | 全集群重启+redis-0 PVC损坏 | 唯一致命且无法自愈的场景 | 定期备份 PVC + RDB CronJob |
| 2 | 网络分区脑裂 | 数据冲突难以修复 | quorum=3 |
| 3 | role-tagger延迟 | 必然发生，影响业务 | 缩短轮询间隔（2-3s） |
| 4 | slave复制延迟 | 高负载下数据丢失 | 监控复制延迟告警 |
| 5 | API server故障 | role-tagger 无法工作 | 监控 API server 健康 |

---

### 诚实结论

**没有任何分布式系统是 100% 可用的。** 你的方案已经覆盖了 99% 的常见故障场景。剩下 1% 的极端场景（如全集群重启 + PVC 损坏、网络分区脑裂）是分布式系统的固有限制，只能通过备份、监控、人工干预来缓解。

**如果你的老大要求 100% 可用，那是不现实的。** 即使是 Redis Cluster、ZooKeeper、etcd 都有类似的限制。正确的做法是：
1. 接受这些限制
2. 配置监控告警
3. 制定应急预案
4. 定期备份