# 01 - 自动故障转移 (Auto Failover)

master 宕机后，Sentinel 在 ~15s 内完成选举，新 master 就绪后流量自动切换。

## 架构设计

```
                    ┌────────────────────────────────────────┐
                    │  Sentinel (3 副本, quorum=2)             │
                    │  互相监控, 共同决策                      │
                    └────────────┬───────────────────────────┘
                                 │ 监控 + 选举
        ┌────────────────────────┼────────────────────────┐
        ▼                        ▼                        ▼
   ┌─────────┐              ┌─────────┐              ┌─────────┐
   │ redis-0 │←──复制────────│ redis-1 │←──复制────────│ redis-2 │
   │ master  │              │  slave  │              │  slave  │
   └─────────┘              └─────────┘              └─────────┘
```

**核心机制**：
- Sentinel 以 `quorum=2` 监控 master，2/3 sentinel 同意才触发 failover
- master 宕机 → `down-after-milliseconds`（默认 30s，测试可调小）后标记 ODOWN
- sentinel 选举新 master → `SLAVEOF NO ONE` 提升 slave → 其余 slave 跟随新 master
- master 流量切换由 [02-master-routing.md](02-master-routing.md) 的 role-tagger 完成

**为什么用 3 副本**：quorum=2 需要 3 个 sentinel 才能容忍 1 个挂掉，避免单点。

## 实现设计

### 涉及文件

| 文件 | 作用 |
|------|------|
| [helm/redis-sentinel/templates/statefulset-sentinel.yaml](../helm/redis-sentinel/templates/statefulset-sentinel.yaml) | Sentinel StatefulSet（3 副本、Parallel） |
| [helm/redis-sentinel/templates/configmap-sentinel.yaml](../helm/redis-sentinel/templates/configmap-sentinel.yaml) | `entrypoint.sh`：发现 master → 生成 sentinel.conf → 启动 |
| [helm/redis-sentinel/templates/services.yaml](../helm/redis-sentinel/templates/services.yaml) | `<inst>-sentinel-hl` Headless Service |

### 关键实现

**1. Sentinel 发现 master（entrypoint.sh）**

Sentinel 启动时不知道 master 是谁，按顺序：
1. 问其他 sentinel：`SENTINEL get-master-addr-by-name mymaster`，且验证返回的 IP 可达
2. 扫描 redis pod：`ROLE` 返回 master 的那个
3. fallback 到 `redis-0`（冷启动默认 master）
4. **死 IP 检测**：sentinel.conf 持久化的旧 master 在全集群重启时已不存在，必须验证可达才用，否则 fallback 到 redis-0

**2. DNS → IP 解析（Redis 5 限制）**

Redis 5 Sentinel 不支持 `sentinel resolve-hostnames`，monitor 目标必须是 IP。`entrypoint.sh` 用 `getent hosts` 解析：

```sh
MASTER_IP="$(getent hosts "${INSTANCE_NAME}-0.${REDIS_HL}.${NAMESPACE}.svc" | awk '{print $1}')"
echo "sentinel monitor mymaster ${MASTER_IP} 6379 ${quorum}"
```

**3. 冷启动等待**

DNS 在 redis pod 未就绪时不解析，`entrypoint.sh` 重试 20 次（~60s）覆盖 redis 启动时间。

### 关键参数（values.yaml）

| 参数 | 默认 | 说明 |
|------|------|------|
| `sentinel.replicas` | `3` | 副本数（奇数，建议 3/5） |
| `sentinel.quorum` | `2` | 选举同意数（建议 `(replicas/2)+1`） |
| `sentinel.config` | `[]` | 追加到 sentinel.conf，可设 `down-after`、`failover-timeout` 等 |

```yaml
sentinel:
  replicas: 3
  quorum: 2
  config:
    - "sentinel down-after-milliseconds mymaster 5000"   # 测试用快速 failover
    - "sentinel failover-timeout mymaster 15000"
```

## 使用说明

```bash
# 部署（测试用快速 failover 参数）
helm install ftest ./helm/redis-sentinel -n redis --create-namespace \
  --set common.instanceName=ftest \
  --set common.auth.password=testpw \
  --set 'sentinel.config[0]=sentinel down-after-milliseconds mymaster 5000' \
  --set 'sentinel.config[1]=sentinel failover-timeout mymaster 15000'

# 等待就绪
kubectl -n redis wait pod -l app=ftest --for=condition=ready --timeout=180s
kubectl -n redis get pod -l app=ftest,redis-role=master
```

## 校验

### 1. master 标识

```bash
# 通过 sentinel 查询
kubectl -n redis exec ftest-sentinel-0 -c sentinel -- \
  redis-cli -p 26379 SENTINEL get-master-addr-by-name mymaster

# 通过 pod label
kubectl -n redis get pod -l app=ftest,redis-role=master \
  -o jsonpath='{.items[0].metadata.name}'; echo
```

### 2. 触发 failover（模拟 master 宕机）

```bash
MASTER=$(kubectl -n redis get pod -l app=ftest,redis-role=master -o jsonpath='{.items[0].metadata.name}')
echo "原 master: $MASTER"

# 模拟宕机: 删除 pod (StatefulSet 会重建, 但 sentinel 会先判它 down)
kubectl -n redis delete pod "$MASTER" --force --grace-period=0

# 观察新 master 产生 (应 <30s)
kubectl -n redis get pod -l app=ftest,redis-role=master -w
# Ctrl+C 退出 watch

# 验证写入仍可用
kubectl -n redis exec -it $(kubectl -n redis get pod -l app=ftest,redis-role=master -o jsonpath='{.items[0].metadata.name}') -c redis -- \
  redis-cli -a testpw SET failover_test ok
```

### 3. sentinel 健康检查

```bash
# quorum 状态
kubectl -n redis exec ftest-sentinel-0 -c sentinel -- \
  redis-cli -p 26379 SENTINEL master mymaster | head -8

# sentinel 互连数 (应 = replicas-1 = 2)
kubectl -n redis exec ftest-sentinel-0 -c sentinel -- \
  redis-cli -p 26379 SENTINEL sentinels mymaster | grep -c ip
```

## 清理

```bash
helm uninstall ftest -n redis
kubectl -n redis delete pvc -l app.kubernetes.io/instance=ftest --force
# 确认无残留
kubectl -n redis get all -l app.kubernetes.io/instance=ftest
```

## 注意事项

1. **`down-after-milliseconds` 生产建议 ≥ 30s**：避免网络抖动误判触发不必要的 failover
2. **failover 期间写入会失败**：~5-15s 不可写，应用需重试或断路
3. **数据丢失窗口**：异步复制，master 宕机瞬间未同步的写入会丢失（Redis 主从模式固有）
4. **不要直接 `kubectl delete` master pod 测试**：StatefulSet 立即重建同名 pod，可能产生"原 master 复活"的混淆。生产演练建议用 `kubectl cordon` + drain 节点
