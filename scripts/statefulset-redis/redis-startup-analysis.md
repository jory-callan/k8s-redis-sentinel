# redis 容器分析文档

## 容器信息

| 项目 | 值 |
|------|-----|
| 容器名 | `redis` |
| 镜像 | `redis:5.0.8` |
| 运行模式 | 单次执行（脚本退出后 redis-server 接管） |
| 脚本 | [redis-startup.sh](redis-startup.sh) |
| 进程 | `redis-server /data/redis.conf` |

## 核心职责

1. **构建 redis.conf**：复制模板配置，替换 `__ANNOUNCE_IP__` 为实际 IP，追加密码配置
2. **角色决策**：根据 sentinel 信息和 ordinal 决定以 master 还是 slave 身份启动
3. **启动 Redis**：调用 `exec redis-server`，将进程替换为 Redis 主进程

## 决策流程

```
┌─────────────────────────────────────────────────────────────────────┐
│                         启动决策树                                  │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  问 sentinel 有没有 master？                                         │
│       │                                                             │
│       ├── 有 master ──→ 验证 master 可达？                           │
│       │                     │                                       │
│       │                     ├── 可达 ──→ 我是 master？               │
│       │                     │                     │                 │
│       │                     │                     ├── 是 ──→ exec redis-server
│       │                     │                     │                 │
│       │                     │                     └── 否 ──→ exec redis-server --slaveof
│       │                     │                                       │
│       │                     └── 不可达 ──→ 回退到冷启动               │
│       │                                                             │
│       └── 无 sentinel ──→ 冷启动逻辑                                │
│                             │                                       │
│                             ├── ordinal=0 ──→ exec redis-server (自举 master)
│                             │                                       │
│                             └── ordinal>0 ──→ 等待 redis-0 就绪后跟随
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
```

**为什么稳定**：
- 使用 shell 算术扩展计算范围，兼容 dash
- 不管配置多少个 sentinel（3、5、7...），都能正确遍历
- 不会遗漏新增的 sentinel 节点

### 2. 防脑裂（最关键）

```bash
# ordinal > 0: wait for redis-0 (NEVER self-promote — prevents split-brain)
if [ "${ORDINAL}" = "0" ]; then
  exec redis-server /data/redis.conf  # ordinal=0 才能自举
else
  # ordinal>0 只能等待 redis-0，永不自举
  while [ "$i" -lt 30 ]; do
    if cli -h "${REDIS_0}" -p 6379 PING | grep -q PONG; then
      exec redis-server /data/redis.conf --slaveof "${REDIS_0}" 6379
    fi
    sleep 2
  done
  exit 1  # 等不到就退出，让 K8s 重启，绝不自己当 master
fi
```

**为什么稳定**：
- 只有 ordinal=0 能自举为 master，消除了双 master 的可能性
- ordinal>0 宁可 crash loop 也不自己当 master
- 即使网络分区导致 redis-0 不可达，ordinal>0 也不会变成 master

### 2. 死 IP 检测

```bash
# 验证 sentinel 返回的 master 是否可达
if [ -n "${MASTER_IP}" ]; then
  MASTER_REACHABLE=0
  while [ "$i" -lt 5 ]; do
    if cli -h "${MASTER_IP}" -p 6379 PING | grep -q PONG; then
      MASTER_REACHABLE=1
      break
    fi
    # 不可达时重新查询 sentinel，可能已经选出新 master
    NEW_IP="$(get_master_from_sentinel)"
    [ -n "${NEW_IP}" ] && MASTER_IP="${NEW_IP}"
    sleep 3
  done
  
  if [ "${MASTER_REACHABLE}" != "1" ]; then
    echo "[warn] sentinel master ${MASTER_IP} unreachable, fallback to cold start"
    # 不跟随死 IP，回退到冷启动逻辑
  fi
fi
```

**为什么稳定**：
- 全集群重启时，sentinel 可能从持久化配置中读取到旧的 master IP
- 必须验证可达性，不可达则回退到冷启动
- 不会出现"跟随一个死 master"的情况

### 3. 不设 set -e

```bash
#!/bin/sh
# No 'set -e' (dash + local + $() = silent exit, see PITFALLS.md #1)
```

**为什么稳定**：
- Redis 5.0.8 使用 dash 作为 /bin/sh
- dash 中 `local x="$(cmd)"` 在 cmd 失败时会静默退出（bug）
- 移除 `set -e`，改用显式的 `||` 错误处理，避免脚本意外退出

### 4. timeout 包裹外部命令

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
- `2>/dev/null` 避免错误输出污染日志

### 5. exec 替换进程

```bash
exec redis-server /data/redis.conf
```

**为什么稳定**：
- `exec` 用 redis-server 替换当前 shell 进程
- Redis 成为容器的 PID=1 进程，K8s 直接管理 Redis
- 如果 Redis 崩溃，容器立即退出并重启

## 可靠性评估

| 场景 | 行为 | 结果 |
|------|------|------|
| 正常启动 | 脚本执行决策，exec redis-server | ✅ Redis 正常运行 |
| sentinel 未就绪 | 回退到冷启动逻辑 | ✅ ordinal=0 自举 master |
| master IP 不可达 | 回退到冷启动逻辑 | ✅ 不会跟随死 master |
| ordinal>0 启动时 redis-0 未就绪 | 等待 redis-0（最多 60s） | ✅ 60s 内 redis-0 就绪则正常跟随 |
| ordinal>0 等待超时 | 脚本退出，K8s 重启 pod | ✅ 重试直到 redis-0 就绪 |
| 脚本错误 | 脚本退出，K8s 重启 pod | ✅ 自动重试 |

## 总结

**redis 容器是整个集群的核心，其稳定性设计体现在**：

1. **防脑裂优先**：ordinal>0 永不自举，消除双 master 风险
2. **死 IP 保护**：验证 sentinel 返回的 master 可达性，避免跟随死节点
3. **dash 兼容**：不设 `set -e`，避免静默退出
4. **超时保护**：`timeout` 包裹所有外部命令，防止 hang
5. **进程替换**：`exec` 让 Redis 成为 PID=1，K8s 直接管理

这些设计确保了即使在极端场景下（全集群重启、网络分区、sentinel 故障），也不会出现数据不一致或脑裂问题。