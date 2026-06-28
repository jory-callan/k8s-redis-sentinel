# sentinel 容器分析文档

## 容器信息

| 项目 | 值 |
|------|-----|
| 容器名 | `sentinel` |
| 镜像 | `redis:5.0.8` |
| 运行模式 | 单次执行（脚本退出后 redis-sentinel 接管） |
| 脚本 | [sentinel-entrypoint.sh](sentinel-entrypoint.sh) |
| 进程 | `redis-sentinel /data/sentinel.conf` |

## 核心职责

1. **发现 master**：询问其他 sentinel 或扫描 redis pod 获取 master IP
2. **验证可达性**：确认 master IP 可达（防全集群重启时的旧 IP）
3. **生成配置**：动态生成 sentinel.conf（monitor、密码、自定义配置）
4. **启动 Sentinel**：调用 `exec redis-sentinel`，将进程替换为 Sentinel 主进程

## 发现流程

```
┌─────────────────────────────────────────────────────────────────────┐
│                      Sentinel 发现流程                              │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  等待 master（最多 60s）                                             │
│       │                                                             │
│       └── 尝试发现 master：                                          │
│             │                                                       │
│             ├── 问其他 sentinel（sentinel-0, -1, -2）               │
│             │       │                                               │
│             │       └── 获取 master IP → 验证可达 → 返回 IP         │
│             │                                                       │
│             └── 扫描 redis pod（redis-0, -1, -2）                   │
│                     │                                               │
│                     └── 查询 ROLE → 找到 ROLE=master → 返回 IP      │
│                                                                     │
│  如果都没找到 → 默认使用 redis-0                                     │
│       │                                                             │
│       └── 解析 redis-0 DNS → 获取 IP → 生成 sentinel.conf          │
│                                                                     │
│  exec redis-sentinel /data/sentinel.conf                            │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

## 稳定性设计

### 1. 动态 replicas 配置（支持任意副本数）

```bash
# 动态 replicas 配置
# REDIS_REPLICAS: Redis StatefulSet 副本数（默认 3）
# SENTINEL_REPLICAS: Sentinel StatefulSet 副本数（默认 3）
REDIS_REPLICAS="${REDIS_REPLICAS:-3}"
SENTINEL_REPLICAS="${SENTINEL_REPLICAS:-3}"
```

**为什么稳定**：
- 通过环境变量配置副本数，不再硬编码
- 默认值为 3（向后兼容），但可以通过环境变量覆盖
- Helm 模板会自动将 `.Values.redis.replicas` 和 `.Values.sentinel.replicas` 传入

```bash
# 动态遍历所有 sentinel（从 0 到 SENTINEL_REPLICAS-1）
sentinel_idx=0
while [ "$sentinel_idx" -lt "$SENTINEL_REPLICAS" ]; do
  s="${INSTANCE_NAME}-sentinel-${sentinel_idx}"
  H="${s}.${SENTINEL_HL}.${NAMESPACE}.svc"
  IP="$(cli -h "${H}" -p 26379 SENTINEL get-master-addr-by-name mymaster ...)"
  sentinel_idx=$((sentinel_idx + 1))
done

# 动态遍历所有 redis pod（从 0 到 REDIS_REPLICAS-1）
redis_idx=0
while [ "$redis_idx" -lt "$REDIS_REPLICAS" ]; do
  r="${INSTANCE_NAME}-${redis_idx}"
  H="${r}.${REDIS_HL}.${NAMESPACE}.svc"
  ROLE="$(cli -h "${H}" -p 6379 ROLE ...)"
  redis_idx=$((redis_idx + 1))
done
```

**为什么稳定**：
- 使用 shell 算术扩展计算范围，兼容 dash
- 不管配置多少个 sentinel 或 redis（3、5、7...），都能正确遍历
- 不会遗漏新增的节点

### 2. 幽灵 slave 清理（防止 slave 数量无限增长）

```bash
# Clean up stale sentinel.conf entries to avoid ghost slaves
# When redis pod restarts with new IP, old 'sentinel known-slave' entries
# remain in persistent sentinel.conf, causing slave count to grow indefinitely.
if [ -f /data/sentinel.conf ]; then
  OLD_SLAVES=$(grep -c '^sentinel known-slave mymaster' /data/sentinel.conf 2>/dev/null || echo 0)
  if [ "${OLD_SLAVES}" -gt 0 ]; then
    echo "[sentinel] cleaning ${OLD_SLAVES} stale known-slave entries from sentinel.conf"
    sed -i '/^sentinel known-slave mymaster/d' /data/sentinel.conf
  fi
fi
```

**为什么稳定**：
- Redis Sentinel 会将 slave 列表持久化到 `sentinel.conf`（`sentinel known-slave` 条目）
- K8s 中 redis pod 重启后 IP 会变化，但旧的 `known-slave` 条目不会自动删除
- 新 slave 启动后，sentinel 又添加新的 `known-slave` 条目，导致 slave 数量不断增长
- 每次 sentinel 启动时清理旧条目，只保留当前活跃的 slave
- 不影响 monitor IP（monitor 配置是独立的）

**问题现象**：
```
# 多次删除 redis pod 后
sentinel-0: slave=2    ← 未经历过 failover，列表干净
sentinel-1: slave=8    ← 积累了大量幽灵 slave（旧 IP）
sentinel-2: slave=8    ← 同样积累了幽灵 slave
```

**修复效果**：
- sentinel 重启后自动清理旧的 `known-slave` 条目
- 重新发现当前活跃的 slave，slave 数量恢复为真实值（2）
- Monitor IP 不受影响，始终指向正确的 master

### 3. 死 IP 检测

```bash
find_master() {
  # 1. 问其他 sentinel
  sentinel_idx=0
  while [ "$sentinel_idx" -lt "$SENTINEL_REPLICAS" ]; do
    H="${s}.${SENTINEL_HL}.${NAMESPACE}.svc"
    IP="$(cli -h "${H}" -p 26379 SENTINEL get-master-addr-by-name mymaster ... | head -1)"
    if [ -n "${IP}" ] && [ "${IP}" != "nil" ]; then
      # 验证 master IP 可达性
      if cli -h "${IP}" -p 6379 PING 2>/dev/null | grep -q PONG; then
        echo "${IP}"
        return 0
      fi
    fi
  done
  # ...
}
```

**为什么稳定**：
- 全集群重启时，sentinel 可能从持久化配置中读取到旧的 master IP
- 必须验证可达性，不可达则继续扫描其他 sentinel
- 不会出现"sentinel 监控一个死 master"的情况

### 2. DNS 解析（Redis 5 限制）

```bash
# Redis 5.0 Sentinel 不支持 sentinel resolve-hostnames
# monitor 目标必须是 IP，不能是域名
IP="$(getent hosts "${H}" 2>/dev/null | awk '{print $1}')"
```

**为什么稳定**：
- Redis 5 Sentinel 的限制：monitor 命令只接受 IP
- 使用 `getent hosts` 将 DNS 解析为 IP
- 冷启动时 DNS 在 pod 未就绪时不解析，20 次重试（60s）覆盖启动时间

### 3. 不 fallback 到 127.0.0.1

```bash
if [ -z "${MASTER_IP}" ]; then
  echo "[cold] no master found, defaulting to ${INSTANCE_NAME}-0"
  MASTER_IP="$(getent hosts "${INSTANCE_NAME}-0.${REDIS_HL}.${NAMESPACE}.svc" 2>/dev/null | awk '{print $1}')"
  if [ -z "${MASTER_IP}" ]; then
    # Do NOT fallback to 127.0.0.1 — sentinel would monitor itself
    # and never discover the real master (deadlock).
    echo "[error] cannot resolve ${INSTANCE_NAME}-0, exiting (will retry on restart)"
    exit 1
  fi
fi
```

**为什么稳定**：
- 如果 fallback 到 127.0.0.1，sentinel 会监控自己
- 自己不是真正的 master，永远无法发现真正的 master（死锁）
- 宁可退出让 K8s 重启，也不进入死锁状态

### 4. exec 替换进程

```bash
exec redis-sentinel /data/sentinel.conf
```

**为什么稳定**：
- `exec` 用 redis-sentinel 替换当前 shell 进程
- Sentinel 成为容器的 PID=1 进程，K8s 直接管理
- 如果 Sentinel 崩溃，容器立即退出并重启

### 5. 不设 set -e

```bash
#!/bin/sh
# No 'set -e' (dash compatibility)
```

**为什么稳定**：
- Redis 5.0.8 使用 dash 作为 /bin/sh
- dash 中 `local x="$(cmd)"` 在 cmd 失败时会静默退出
- 移除 `set -e`，改用显式错误处理

### 6. timeout 包裹外部命令

```bash
cli() {
  if [ -n "${REDIS_PASSWORD:-}" ]; then
    timeout 2 redis-cli -a "${REDIS_PASSWORD}" "$@" 2>/dev/null
  else
    timeout 2 redis-cli "$@" 2>/dev/null
  fi
}
```

**为什么稳定**：
- redis-cli 可能因为网络问题 hang 住
- `timeout 2` 限制最长等待 2 秒，防止脚本卡死

## 可靠性评估

| 场景 | 行为 | 结果 |
|------|------|------|
| 正常启动 | 发现 master，生成配置，启动 sentinel | ✅ Sentinel 正常运行 |
| 其他 sentinel 未就绪 | 扫描 redis pod | ✅ 找到 master |
| master IP 不可达 | 继续扫描其他 sentinel | ✅ 不会监控死 IP |
| DNS 未解析 | 等待 60s，重试 20 次 | ✅ 覆盖冷启动时间 |
| redis-0 未就绪 | 退出，K8s 重启 | ✅ 自动重试 |
| 脚本错误 | 退出，K8s 重启 | ✅ 自动重试 |

## 总结

**sentinel 容器的稳定性设计体现在**：

1. **死 IP 检测**：验证 sentinel 返回的 master 可达性，避免监控死节点
2. **DNS 解析**：兼容 Redis 5 的 IP 限制，`getent hosts` 解析域名
3. **不死锁设计**：不 fallback 到 127.0.0.1，宁可重启也不进入死锁
4. **进程替换**：`exec` 让 Sentinel 成为 PID=1，K8s 直接管理
5. **dash 兼容**：不设 `set -e`，避免静默退出
6. **超时保护**：`timeout` 包裹所有外部命令，防止 hang

这些设计确保了 Sentinel 在各种场景下都能正确发现并监控 master，不会进入死锁或错误状态。