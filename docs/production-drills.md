# 生产故障演练清单

上核心业务前，按本清单逐项演练，验证集群自愈能力。所有命令中 `<instance>` 替换为实际实例名（如 `my-app`），namespace 默认 `redis`。

前置：部署一个 3 节点以上的生产集群（podAntiAffinity 已默认开启，redis/sentinel 分散在不同节点）。

## 演练前准备

```bash
# 1. 确认集群拓扑（pod 分布到不同节点）
kubectl -n redis get pod -o wide -l "app in (<instance>,<instance>-sentinel)"

# 2. 基线健康检查（记录当前 master）
./check.sh <instance> redis

# 3. 准备一个测试客户端持续写入
kubectl -n redis run writer --rm -it --restart=Never --image=redis:5.0.8 -- \
  redis-cli -h <instance>-master.redis -a <密码> -r 1000000 INCR counter
```

## 演练 1：删除单个 Redis Pod

模拟：master 或 slave 进程崩溃。

```bash
# 找到当前 master
MASTER=$(kubectl -n redis get pod -l app=<instance>,redis-role=master -o jsonpath='{.items[0].metadataName}')
echo "master: $MASTER"

# 删除 master pod
kubectl -n redis delete pod "$MASTER" --grace-period=0 --force

# 预期：~15s 内选出新 master，<instance>-master.svc 自动切流量
# 验证：writer 客户端短暂报错后恢复；check.sh 显示新 master
./check.sh <instance> redis
```

**通过标准**：writer 中断 < 30s；新 master 唯一；旧 master 重启后变 slave。

## 演练 2：节点 drain（滚动维护）

模拟：节点硬件维护 / kubelet 升级。

```bash
# 找到 master 所在节点
MASTER_NODE=$(kubectl -n redis get pod -l app=<instance>,redis-role=master -o jsonpath='{.items[0].spec.nodeName}')
echo "draining node: $MASTER_NODE"

# drain 该节点（驱逐所有 pod）
kubectl drain "$MASTER_NODE" --ignore-daemonsets --delete-emptydir-data --force --timeout=60s

# 等待新 pod 在其他节点起来 + failover 完成
sleep 30
./check.sh <instance> redis

# 恢复节点
kubectl uncordon "$MASTER_NODE"
```

**通过标准**：被驱逐的 pod 在其他节点重建；master 切换 < 30s；恢复后集群自愈到 3 副本。

> 注意：测试环境若只有 3 节点且 redis/sentinel 各 3 副本，drain 一个节点可能同时丢失 1 redis + 1 sentinel，仍应保持 quorum。若要测「节点丢失导致多数派丢失」，需构造更小集群或调小副本数。

## 演练 3：网络分区（节点隔离）

模拟：节点网络故障，pod 不可达但进程存活。

```bash
# 方法 A：用临时 DENY NetworkPolicy 模拟网络隔离（仅隔离 pod 间，不隔离 kubelet）
kubectl -n redis apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: drill-deny
spec:
  podSelector:
    matchLabels:
      app: <instance>
  policyTypes: [Ingress, Egress]
  ingress: []
  egress: []
EOF

# 等 30s 观察 failover
sleep 30
./check.sh <instance> redis

# 清理
kubectl -n redis delete networkpolicy drill-deny
```

方法 B（更接近真实网络分区，需节点 SSH 权限）：在节点上 `iptables -I INPUT -s <其他节点CIDR> -j DROP`，演练后 `iptables -D INPUT 1` 恢复。

**通过标准**：被隔离的 pod 不再被选为 master；其余 sentinel 重新选主；恢复后原 master 降为 slave。

## 演练 4：Sentinel 多数派丢失

模拟：2/3 sentinel 同时宕机，quorum 不足。

```bash
# 删除两个 sentinel
kubectl -n redis delete pod <instance>-sentinel-1 --force --grace-period=0
kubectl -n redis delete pod <instance>-sentinel-2 --force --grace-period=0

# 预期：当前 master 继续服务（不切流量）；但**无法 failover**（quorum 不足）
./check.sh <instance> redis   # ok_sentinels 应为 1，告警 RedisInsufficientSentinels

# 此时删除 master 测试「降级模式」
kubectl -n redis delete pod -l app=<instance>,redis-role=master --force --grace-period=0
sleep 30
./check.sh <instance> redis   # 预期：无新 master（quorum 不足），写入不可用，读取可用

# 恢复：sentinel 重建后自动恢复 quorum 并选出新 master
kubectl -n redis delete pod <instance>-sentinel-1 <instance>-sentinel-2 --force --grace-period=0  # 触发重建
sleep 60
./check.sh <instance> redis
```

**通过标准**：sentinel < quorum 时不再 failover（防脑裂）；恢复后集群自愈；运维应收到 `RedisInsufficientSentinels` 告警。

## 演练 5：磁盘写满

模拟：PVC 满或节点磁盘满，RDB/AOF 写入失败。

```bash
# 在 master pod 内填充磁盘到接近满
kubectl -n redis exec -it <instance>-0 -c redis -- sh -c 'dd if=/dev/zero of=/data/fill bs=1M count=9000' # 按实际 PVC 大小调整

# 预期：BGSAVE 失败，告警 RedisBgSaveFailed；写入仍可用（RDB 失败不阻塞）
./check.sh <instance> redis

# 清理
kubectl -n redis exec <instance>-0 -c redis -- rm -f /data/fill
```

**通过标准**：`redis_rdb_last_bgsave_status != 0` 告警触发；主从不中断；磁盘释放后 BGSAVE 恢复成功。

## 演练 6：密码错配

模拟：应用配置密码与 Redis 实际密码不一致。

```bash
# 用错误密码连接（应被拒）
kubectl -n redis run badpw --rm -it --restart=Never --image=redis:5.0.8 -- \
  redis-cli -h <instance>-master.redis -a WRONG-PASSWORD PING
# 预期：WRONGPASS Invalid username/passwordpair
```

**通过标准**：错误密码无法连接（防未授权访问）；NetworkPolicy 启用时，未授权 pod 根本无法到端口。

## 演练 7：多实例隔离

模拟：一个实例的故障不影响另一个实例。

```bash
# 假设有实例 A 和 B
# 把 A 的 master 删掉
kubectl -n redis delete pod -l app=A,redis-role=master --force --grace-period=0

# 验证 B 完全不受影响
./check.sh B redis   # B 的 master 不变
```

**通过标准**：A failover 期间 B 服务正常；A 的 role-tagger 只改 A 的 pod label（RBAC resourceNames 限制）。

## 演练 8：role-tagger sidecar 故障

模拟：sidecar 进程崩溃，标签不更新。

```bash
# 找到 master pod，杀掉 role-tagger
MASTER_POD=$(kubectl -n redis get pod -l app=<instance>,redis-role=master -o jsonpath='{.items[0].metadataName}')
kubectl -n redis exec "$MASTER_POD" -c role-tagger -- sh -c 'kill 1' 2>/dev/null || true

# 此时手动触发 failover（删 master），验证：流量切换会延迟（标签不更新）
kubectl -n redis delete pod "$MASTER_POD" --force --grace-period=0
sleep 30
./check.sh <instance> redis
# 预期：新 master 已选出（redis 层），但 <instance>-master.svc 仍指向旧 pod（role-tagger 挂了没更新 label）

# role-tagger 会自动重启（容器 restartPolicy），恢复后标签更新
sleep 30
./check.sh <instance> redis   # 标签应已同步
```

**通过标准**：role-tagger 重启后标签自动同步；sidecar 故障不影响 redis 本身；恢复后流量切到新 master。

## 演练结果记录

每项演练后记录：

| 演练 | 中断时长 | 是否通过 | 备注 |
|------|---------|---------|------|
| 1. 删 master | | | |
| 2. 节点 drain | | | |
| 3. 网络分区 | | | |
| 4. sentinel 多数派丢失 | | | |
| 5. 磁盘写满 | | | |
| 6. 密码错配 | | | |
| 7. 多实例隔离 | | | |
| 8. role-tagger 故障 | | | |

## 红线（演练中若出现，立即停止并排查）

- 出现 **2 个 master**（脑裂）— 检查防脑裂逻辑
- failover 后 **写入丢失**（已确认的写入）— 检查复制完整性
- sentinel 恢复后**无法收敛**（持续 s_down/o_down）— 检查 sentinel 配置
- role-tagger 改了**其他实例的 label** — 检查 RBAC resourceNames
