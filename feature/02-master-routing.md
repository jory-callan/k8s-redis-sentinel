# 02 - Master 流量切换（role-tagger + 应用零改动 + 零事件风暴）

`<inst>-master.svc` 始终只路由到当前 master，业务代码无需感知 failover；同时消除 slave 的 readinessProbe 失败事件风暴。

## 架构设计

### 旧方案问题

```
readinessProbe: ROLE | grep master
  → slave NotReady (Service 无 endpoint)
  → K8s 每 period 产生一次 "Readiness probe failed" 事件
  → 实测: 10 分钟 309 次事件, 1 年数千万次
  → 压力 etcd / kubelet / API server
```

### 新方案（sidecar + label）

```
┌─────────────────────────────────────────────────────────────┐
│  Redis Pod                                                    │
│  ┌──────────────┐      ┌──────────────────────────────┐     │
│  │ redis        │      │ role-tagger sidecar           │     │
│  │ 6379         │←─────│ 每 5s: curl telnet 查 ROLE     │     │
│  │              │      │ 变化时 PATCH pod label         │     │
│  │              │      │ redis-role=master|slave        │     │
│  └──────────────┘      └───────────────┬──────────────┘     │
│                                        │ PATCH via K8s API  │
└────────────────────────────────────────┼────────────────────┘
                                         ▼
                          pod.metadata.labels.redis-role
                                         │
┌──────────────────────────────────────────────────────────────┐
│  Service <inst>-master                                       │
│  selector:                                                   │
│    redis-sentinel.k8s.io/chart: redis-sentinel               │
│    redis-sentinel.k8s.io/instance: <inst>                   │
│    redis-sentinel.k8s.io/component: redis                    │
│    redis-role: master   ← 只选 master pod                     │
└──────────────────────────────────────────────────────────────┘
                  ↑
                  │ endpoints controller (~1-2s)
                  │
            应用: redis://<inst>-master:6379
            (failover 后自动切到新 master)
```

**关键设计点**：
1. role-tagger **直接查 redis**（curl telnet 发送 redis 协议），**不依赖 exporter 容器**
2. readinessProbe 改为 PING（所有 pod 都 Ready，零失败事件）
3. **只在 role 变化时才 PATCH label**（减少 API 压力，常态零调用）
4. RBAC 用 `resourceNames` 锁定只能 patch 本实例 3 个 pod

## 实现设计

### 涉及文件

| 文件 | 作用 |
|------|------|
| [helm/redis-sentinel/templates/statefulset-redis.yaml](../helm/redis-sentinel/templates/statefulset-redis.yaml) | role-tagger sidecar 定义（含 inline 脚本） |
| [helm/redis-sentinel/templates/services.yaml](../helm/redis-sentinel/templates/services.yaml) | `<inst>-master` Service（selector 含 `redis-role=master`） |
| [helm/redis-sentinel/templates/rbac.yaml](../helm/redis-sentinel/templates/rbac.yaml) | SA + Role + RoleBinding（最小权限） |

### role-tagger 脚本逻辑

```sh
# 1. 用 curl telnet:// 发送 redis 协议 (无需 redis-cli, 镜像仅 ~4MB)
AUTH_CMD="AUTH ${REDIS_PASSWORD}\r\n"
ROLE="$(printf "${AUTH_CMD}INFO replication\r\n" \
        | curl -s --max-time 3 telnet://127.0.0.1:6379 \
        | grep '^role:' | cut -d: -f2 | tr -d '[:space:]')"

# 2. role 变化才 PATCH (减少 API 调用)
if [ "$ROLE" != "$LAST_ROLE" ]; then
  curl -X PATCH \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/merge-patch+json" \
    --data '{"metadata":{"labels":{"redis-role":"'"$ROLE"'"}}}' \
    "$APISERVER/api/v1/namespaces/$NS/pods/$POD_NAME"
fi

# 3. 每轮 touch 心跳文件 (livenessProbe 检测)
: > /tmp/last_alive
sleep 5
```

### RBAC 最小权限

```yaml
resourceNames:            # 锁定本实例 3 个 pod
  - <inst>-0
  - <inst>-1
  - <inst>-2
verbs: ["get", "patch"]   # 无 list/update/delete
```

### 为什么用 curl 而非 redis-cli

- `curlimages/curl` 仅 ~4MB，且 curl 支持 telnet 协议发原始 redis 命令
- 同时具备 PATCH K8s API 的能力（busybox 的 wget 不支持 PATCH method）
- 一个镜像满足两个需求（查 redis + 调 API）

### 关键参数

| 参数 | 默认 | 说明 |
|------|------|------|
| `redis.roleTagger.intervalSeconds` | `5` | 轮询间隔 |
| `redis.roleTagger.livenessTimeoutSeconds` | `60` | 心跳超时（无心跳则重启 sidecar） |
| `redis.roleTagger.image.repository` | `curlimages/curl` | 镜像 |

## 使用说明

应用侧只需连接 `<inst>-master:6379`，无需关心 failover：

```bash
helm install ftest ./helm/redis-sentinel -n redis --create-namespace \
  --set common.instanceName=ftest \
  --set common.auth.password=testpw

# 应用访问 (在集群内)
kubectl run app --rm -i --restart=Never --image=redis:5.0.8 -- \
  redis-cli -h ftest-master.redis.svc.cluster.local -a testpw SET k1 v1
```

## 校验

### 1. label 正确

```bash
# 每个 redis pod 应有 redis-role label
kubectl -n redis get pod -l app=ftest -L redis-role
# 预期: 1 个 master + 2 个 slave
```

### 2. master Service endpoint 唯一

```bash
# 应只有 1 个 endpoint (当前 master)
kubectl -n redis get endpoints ftest-master
kubectl -n redis describe svc ftest-master | grep -A2 Endpoints
```

### 3. role-tagger 日志

```bash
kubectl -n redis logs <redis-master-pod> -c role-tagger --tail=5
# 预期看到 "role=master (label updated, http=200)"
```

### 4. 零事件风暴验证（核心）

```bash
# 启动后观察 5 分钟, slave 的 readiness 事件应为 0
kubectl -n redis get events --field-selector \
  involvedObject.name=ftest-1,reason=ReadinessProbe --since=5m
# 预期: <empty> (无事件)

# 对比旧方案会有的失败事件
kubectl -n redis get events --field-selector reason=FailedScheduling --since=5m
```

### 5. failover 后流量切换

```bash
MASTER=$(kubectl -n redis get pod -l app=ftest,redis-role=master -o jsonpath='{.items[0].metadata.name}')
kubectl -n redis delete pod "$MASTER" --force --grace-period=0

# 持续写入, 应在 ~15s 后恢复
for i in $(seq 1 60); do
  kubectl -n redis run w --rm -i --restart=Never --image=redis:5.0.8 -- \
    redis-cli -h ftest-master.redis.svc.cluster.local -a testpw INCR counter 2>/dev/null \
    || echo "fail at ${i}s"
  sleep 1
done

# master Service endpoint 已切到新 pod
kubectl -n redis get endpoints ftest-master
```

## 清理

```bash
helm uninstall ftest -n redis
kubectl -n redis delete pvc -l app.kubernetes.io/instance=ftest --force
```

## 注意事项

1. **切换延迟 ~5-7s**：role-tagger 轮询 5s + endpoints controller 1-2s。不能做到"选举成功即切"
2. **不能用事件驱动**：Redis 5 无角色变更 webhook，只能轮询。5s 是 API 压力与延迟的折中
3. **`hash -r` 坑**：curlimages/curl 镜像用 `command:` 覆盖 entrypoint 后 shell hash 缓存无 curl，脚本开头必须 `hash -r`
4. **role-tagger 挂了不影响 redis**：sidecar 崩溃 → livenessProbe 重启它 → 期间 label 不更新但 Service 仍指向旧 master。**关键**：role-tagger 不在 redis 写入链路上
5. **exporter 挂了不影响 role-tagger**：role-tagger 直接查 redis，不读 exporter metrics
