# 03 - 防脑裂启动（Split-Brain Prevention）

**核心保证**：任何情况下都不会出现两个 master，即使全集群重启、网络分区、sentinel 全挂。

## 架构设计

### 脑裂风险场景

```
场景A: 全集群重启
  redis-0 慢启动, redis-1 先起来 → 如果 redis-1 自举 master → redis-0 也自举 → 双 master!

场景B: sentinel 返回死 IP
  全集群重启后 sentinel.conf 持久化的旧 master IP 已不存在
  → 如果 SLAVEOF 死 IP → 永远不同步

场景C: 网络分区
  redis-1 与 sentinel 失联 → sentinel 仍认为旧 master 在
  → redis-1 如果自举 → 双 master
```

### 防护策略

```
┌─────────────────────────────────────────────────────────────┐
│  startup.sh 角色决策 (每个 redis pod 启动时执行)              │
│                                                              │
│  1. 问 sentinel → 有 master                                  │
│       ├ 验证可达                                              │
│       │  ├ 可达 → 跟随 (SLAVEOF master_ip)                   │
│       │  └ 不可达 → fallback 到冷启动 ↓                      │
│       └ master=自己 → 自举                                   │
│                                                              │
│  2. 无 sentinel / 死 IP fallback                             │
│       ├ ordinal=0 → 自举 master (唯一自举点)                  │
│       └ ordinal>0 → 等 redis-0 (永不自举, 宁可 crash loop)   │
└─────────────────────────────────────────────────────────────┘
```

**核心规则**：**只有 `ordinal=0` 在冷启动时能自举 master**。`ordinal>0` 在任何 fallback 路径下都只是等待 redis-0，宁可 crash 退出由 K8s 重启，也绝不独立成 master。

## 实现设计

### 涉及文件

| 文件 | 作用 |
|------|------|
| [helm/redis-sentinel/templates/configmap-redis.yaml](../helm/redis-sentinel/templates/configmap-redis.yaml) | `startup.sh` 三分支决策 |
| [helm/redis-sentinel/templates/statefulset-redis.yaml](../helm/redis-sentinel/templates/statefulset-redis.yaml) | `podManagementPolicy: Parallel` |

### startup.sh 关键代码

```sh
# 1. 问 sentinel 拿 master (带可达性验证)
MASTER_IP="$(get_master_from_sentinel)"   # 重试 5x ~15s

if [ -n "${MASTER_IP}" ]; then
  # 验证 master 可达 (5 次重试)
  # 失败 → fallback 到冷启动 (不 SLAVEOF 死 IP)
  ...
fi

# 2. 冷启动: 无 sentinel 或 sentinel 返回死 IP
if [ "${ORDINAL}" = "0" ]; then
  echo "[role] master (cold start, ordinal=0)"
  exec redis-server /data/redis.conf   # 唯一自举点
fi

# 3. ordinal>0: 等 redis-0 (永不自举, 防脑裂)
REDIS_0="${INSTANCE_NAME}-0.${REDIS_HL}.${NAMESPACE}.svc"
i=0
while [ "$i" -lt 30 ]; do
  if cli -h "${REDIS_0}" PING | grep -q PONG; then
    exec redis-server /data/redis.conf --slaveof "${REDIS_0}" 6379
  fi
  sleep 2
done

# 等 60s 还不行 → crash (K8s 重启), 绝不 standalone
echo "[error] cannot reach ${REDIS_0} after 60s, exiting"
exit 1
```

### 为什么不用 OrderedReady

`podManagementPolicy: OrderedReady` 会让 redis-0 不就绪时 redis-1/2 完全不启动，阻塞调度。改用 `Parallel`：

- 所有 pod 同时启动 → 都 crash loop 等 redis-0
- redis-0 一就绪 → redis-1/2 立即 SLAVEOF
- 防脑裂逻辑移到 startup.sh 脚本层（更可控）

**代价**：redis-0 迟迟不就绪时 redis-1/2 持续 crash（可接受，不阻塞调度）。

### sentinel 端的防护

`configmap-sentinel.yaml` 的 `entrypoint.sh`：
- 问其他 sentinel 拿到 master 后**必须验证 IP 可达**才用
- fallback redis-0 时也用 `getent hosts` 解析，**绝不 fallback 到 127.0.0.1**（会监控自己，死锁）

## 使用说明

```bash
helm install ftest ./helm/redis-sentinel -n redis --create-namespace \
  --set common.instanceName=ftest \
  --set common.auth.password=testpw

kubectl -n redis wait pod -l app=ftest --for=condition=ready --timeout=180s
```

## 校验

### 1. 正常启动只有 1 个 master

```bash
# 通过 ROLE 命令直接查 (不依赖 label)
for i in 0 1 2; do
  ROLE=$(kubectl -n redis exec ftest-$i -c redis -- \
    redis-cli -a testpw ROLE 2>/dev/null | head -1)
  echo "ftest-$i: $ROLE"
done
# 预期: 1 个 master + 2 个 slave, 绝不出现 2 个 master
```

### 2. 模拟全集群重启自愈

```bash
# 缩容到 0 (清掉所有 pod)
kubectl -n redis scale statefulset ftest --replicas=0
kubectl -n redis scale statefulset ftest-sentinel --replicas=0
sleep 5
kubectl -n redis get pod -l 'app in (ftest,ftest-sentinel)'

# 同时扩容回来
kubectl -n redis scale statefulset ftest --replicas=3
kubectl -n redis scale statefulset ftest-sentinel --replicas=3

# 等待恢复, 验证仍只有 1 个 master
sleep 60
for i in 0 1 2; do
  kubectl -n redis exec ftest-$i -c redis -- redis-cli -a testpw ROLE 2>/dev/null | head -1
done
```

### 3. 模拟 sentinel 死 IP（高级）

```bash
# 在 redis-0 启动前, 给 sentinel 注入一个不存在的 master IP
# (模拟 sentinel.conf 持久化的旧 master 在全集群重启后已死)
kubectl -n redis exec ftest-sentinel-0 -c sentinel -- \
  redis-cli -p 26379 SENTINEL RESET mymaster

# 观察 redis pod 日志, 应看到 "[warn] sentinel master X.X.X.X unreachable, fallback to cold start"
kubectl -n redis logs ftest-1 -c redis --tail=10 | grep fallback
```

### 4. 验证 ordinal>0 不自举

```bash
# 让 redis-0 不启动, 观察 redis-1/2 是否 crash
kubectl -n redis scale statefulset ftest --replicas=1
kubectl -n redis delete pod ftest-0 --force --grace-period=0
kubectl -n redis scale statefulset ftest --replicas=3

# redis-1/2 应该 crash loop, 绝不成为 master
kubectl -n redis get pod -l app=ftest -w
# 预期: ftest-1/2 状态 CrashLoopBackOff, 不会出现 master
```

## 清理

```bash
helm uninstall ftest -n redis
kubectl -n redis delete pvc -l app.kubernetes.io/instance=ftest --force
```

## 注意事项

1. **redis-0 是单点自举点**：如果 redis-0 节点故障且 PVC 不可用，集群无法自举。生产建议用持久化 PVC + 跨节点副本
2. **`set -e` 禁用**：dash + `local` + `$()` + `set -e` 会静默退出（见 [docs/pitfalls.md](../docs/pitfalls.md) 坑 1）。所有错误用显式 `||` 处理
3. **`timeout` 包裹 redis-cli**：`getent hosts`、redis-cli 都可能 hang，用 `timeout 2` 防卡死
4. **冷启动时间窗**：redis-0 启动前的 ~60s 内 redis-1/2 持续 crash，属正常现象，不要误判为故障
5. **不要给 ordinal>0 加 standalone fallback**：这是防脑裂的关键。即使"看起来 redis-0 永远起不来"，也宁可让集群不可用也不要双 master
