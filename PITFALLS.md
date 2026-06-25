# PITFALLS.md — 坑文档

记录踩过的坑和解决方案，避免重复踩。

---

## 坑 1: dash + set -e + local + $() = 静默退出

**现象**: 容器启动脚本静默退出，没有任何错误信息。
**根因**: redis:5.0.8 镜像的 `/bin/sh` 是 dash (不是 bash)。dash 中 `set -e` 与 `local` 变量声明在命令替换 `$()` 内部交互异常 — 函数返回非零时 `set -e` 无预警触发脚本退出。
**复现**:
```sh
#!/bin/sh
set -e
foo() {
  local x="$(false)"   # false 返回 1, set -e 触发, 脚本退出
  echo "unreachable"
}
foo
echo "never reached"
```
**解决**: 所有脚本不设 `set -e`，改为显式 `||` 错误处理和返回值检查。
**经验**: 容器启动脚本优先用 `set -u` (未定义变量报错) + 手动 exit code 检查，而非 `set -e`。

---

## 坑 2: readinessProbe=ROLE=master 与 OrderedReady 冲突

**现象**: redis-1/2 永远不启动，StatefulSet 卡在 redis-1。
**根因**: OrderedReady 要求前一个 pod Ready 后才创建下一个。但 readinessProbe 检查 `ROLE=master`，slave 永远 NotReady → redis-1 不 Ready → redis-2 不创建。
**解决**: 改用 `podManagementPolicy: Parallel`。所有 pod 同时启动，startup.sh 负责角色分配。
**关键**: Parallel + 脚本防脑裂 (ordinal>0 永不自举 master) 比 OrderedReady 更优 — 不阻塞调度，且防脑裂逻辑在脚本中更可控。

---

## 坑 3: headless Service 默认不解析 NotReady pod

**现象**: `redis-1.redis-hl.redis.svc` DNS 解析失败，但 redis-1 pod 在运行。
**根因**: headless Service 默认只发布 Ready pod 的 DNS A 记录。readinessProbe=ROLE=master 导致 slave 是 NotReady，DNS 不解析。
**影响**: sentinel 扫描 redis pod 时无法通过 DNS 连接 slave (但 sentinel 通过 master 的 INFO 发现 slave，用 IP 连接，所以不影响核心功能)。
**解决**: redis-hl Service 设 `publishNotReadyAddresses: true`，所有 pod 都可 DNS 解析。
**注意**: redis-master.svc (ClusterIP) 不设此选项 — 它只应路由到 Ready (master) pod。

---

## 坑 4: Redis 5 不支持 sentinel resolve-hostnames

**现象**: sentinel.conf 中 `sentinel monitor mymaster redis-0.redis-hl... 6379 2` 不工作。
**根因**: Redis 5.0.x 的 sentinel 不支持 `sentinel resolve-hostnames yes`，monitor 目标必须是 IP。
**解决**: sentinel entrypoint.sh 中用 `getent hosts` 将 DNS 解析为 IP 再写入 sentinel.conf。
**冷启动问题**: headless DNS 在 pod 未就绪时不解析 → `getent hosts` 失败 → 回退到 127.0.0.1。
**缓解**: entrypoint.sh 有 20 次重试 (~60s)，覆盖 redis-0 启动时间。

---

## 坑 5: Probe 必须带密码

**现象**: Pod 永远 NotReady，startupProbe/livenessProbe 全部失败。
**根因**: 设置 `requirepass` 后，所有 redis-cli 命令必须 `-a <pass>`。但 probe 命令不含密码 → NOAUTH → probe 失败。
**解决**: 所有 probe 命令检查 `$REDIS_PASSWORD`，有密码时加 `-a "$PASS"`。
**模板**:
```sh
P="${REDIS_PASSWORD:-}"
if [ -n "$P" ]; then redis-cli -a "$P" PING 2>/dev/null; else redis-cli PING 2>/dev/null; fi | grep -q PONG
```
**注意**: `2>/dev/null` 必须有 — `redis-cli -a` 会在 stderr 输出 Warning 污染管道。

---

## 坑 6: redis-cli -a 的 Warning 污染 stderr

**现象**: `redis-cli -a password PING | grep PONG` 失败，但手动执行能看到 PONG。
**根因**: `redis-cli -a <pass>` 在 stderr 输出 `Warning: Using a password with '-a' or -u option on the command line interface may not be safe.`。如果 stderr 混入 stdout 管道，grep 会匹配到 Warning 而非 PONG。
**解决**: 所有 redis-cli 调用加 `2>/dev/null` 重定向 stderr。
**注意**: probe 命令和脚本中的 `$(...)` 命令替换都要处理。

---

## 坑 7: Secret stringData 不可更新

**现象**: 修改 01-secret.yaml 的密码后 `kubectl apply` 不生效。
**根因**: `kubectl apply` 对 Secret 的 `stringData` 字段有特殊行为 — 已存在的 Secret 不会更新 stringData。
**解决**: 修改密码后先 `kubectl delete secret redis-secret -n redis` 再 `kubectl apply -f 01-secret.yaml`。
**替代**: 用 `data` (base64) 代替 `stringData`，但可读性差。

---

## 坑 8: volumeClaimTemplates 不可更新

**现象**: `kubectl apply` 修改 StatefulSet 的 volumeClaimTemplates 报错。
**根因**: StatefulSet 的 `volumeClaimTemplates` 是不可变字段。
**解决**: 测试模式需要 emptyDir 时，必须删除 StatefulSet 重建，或用 awk 去掉 volumeClaimTemplates 再 apply。
**当前方案**: 直接用 PVC (1Gi)，不再支持 emptyDir 测试模式。大多数集群 (minikube/kind/k3s) 有默认 StorageClass。

---

## 坑 9: NodePort 端口冲突

**现象**: Service 创建失败，报 NodePort 已被占用。
**根因**: 30001/30002 可能被其他 Service 占用 (如 ingress-nginx 常用 30080)。
**解决**: 部署前检查 `kubectl get svc -A | grep -E '3000[12]'`。
**当前分配**: 30001 (master write), 30002 (read)。

---

## 坑 10: 冷启动 chicken-and-egg

**现象**: sentinel 等 redis master，redis 等 sentinel 告知角色，互相等待。
**根因**:
- sentinel entrypoint.sh 扫描 redis pod 找 master
- redis startup.sh 问 sentinel 找 master
**解决**: 打破循环 — redis-0 在无 sentinel 时自举为 master (ordinal=0 特殊处理)。sentinel 找到 redis-0 后配置，redis-1/2 再从 sentinel 获取 master 信息。
**启动顺序**:
```
1. redis-0 启动 → 无 sentinel → ordinal=0 → 自举 master
2. sentinel-0/1/2 启动 → 扫描 → 发现 redis-0 是 master → 配置
3. redis-1/2 启动 → 问 sentinel → 得到 redis-0 → 成为 slave
```

---

## 坑 11: min-slaves-to-write 导致 failover 后写入失败

**潜在风险**: redis.conf 设 `min-slaves-to-write 1`。failover 期间，新 master 可能暂时没有 slave ACK → 拒绝写入。
**缓解**: `min-slaves-max-lag 10` 给 10s 宽容期。failover 后 slave 会快速 rejoin。
**注意**: 这是防脑裂的必要代价 — 宁可短暂拒写，不可脑裂丢数据。

---

## 坑 12: timeout 命令不能包裹 shell 函数

**现象**: `timeout 2 cli -h ... PING` 静默失败，但手动执行 `redis-cli -a pass -h ... PING` 正常返回 PONG。
**根因**: `timeout` 是外部命令，通过 `execvp` 调用参数。它只能执行**外部命令**（如 `redis-cli`），不能执行 **shell 函数**（如 `cli()`）。`timeout 2 cli ...` 会尝试找名为 `cli` 的可执行文件，找不到就静默失败（被 `2>/dev/null` 吞掉）。
**复现**:
```sh
#!/bin/sh
cli() { redis-cli "$@"; }
timeout 2 cli PING   # 失败：timeout 找不到 cli 可执行文件
```
**解决**: 把 `timeout` 放在函数**内部**，直接包裹 `redis-cli` 外部命令：
```sh
cli() {
  timeout 2 redis-cli -a "${REDIS_PASSWORD}" "$@" 2>/dev/null
}
```
**经验**: `timeout` 只能包裹外部命令。要超时执行函数，用 `timeout 2 sh -c 'func args'`（但函数不在子 shell 中，不可行）。

---

## 坑 13: redis-cli 5.0 不支持 --timeout 参数

**现象**: `redis-cli --timeout 2000 PING` 报 `Unrecognized option or bad number of args for: '--timeout'`。
**根因**: `--timeout`（socket 超时，毫秒）是 Redis 6+ 才有的选项。Redis 5.0.x 的 redis-cli 没有。
**解决**: 用 `timeout` 命令包裹 redis-cli（见坑 12 的正确用法）。
**注意**: redis-cli 5.0 有 `--connect-timeout`（连接超时，秒），但没有 socket 超时。

---

## 坑 14: kubectl wait -l app=redis 对 slave 永远超时

**现象**: install.sh 中 `kubectl wait pod -l app=redis --for=condition=Ready` 会一直等到超时。
**根因**: readinessProbe=ROLE=master 导致 slave 永远 NotReady。`kubectl wait` 等待所有匹配 pod Ready，slave 永远不 Ready → 超时。
**解决**: install.sh 只等 redis-0（master），或用 `--timeout` + `|| true` 容忍 slave 超时。
**当前方案**: `kubectl wait pod -l app=redis --timeout=300s || true`（容忍超时）。

---

## 坑 15: oliver006/redis_exporter 是 scratch 镜像，没有 shell

**现象**: `kubectl exec pod -c exporter -- sh -c '...'` 报 `exec: "sh": executable file not found`。
**根因**: `oliver006/redis_exporter` 基于 scratch 镜像，只有 redis_exporter 二进制，没有 sh/curl/wget。
**影响**: 不能在 exporter 容器内执行命令测试 metrics。
**解决**: 从其他容器（如 redis 容器）访问 `127.0.0.1:9121`（同 pod 共享网络），或用 `kubectl run` 临时 pod。
**注意**: redis:5.0.8 镜像也没有 wget/curl，需要用 `curlimages/curl` 等专用镜像测试。

---

## 坑 16: Sentinel exporter redis_up=0 — Sentinel 未设 requirepass

**现象**: Sentinel exporter 的 `redis_up 0`（连不上 sentinel）。
**根因**: Sentinel 默认不设 `requirepass`，但 exporter 容器带了 `REDIS_PASSWORD` 环境变量。exporter 用密码连接 Sentinel → Sentinel 不需要密码 → 认证失败 → `redis_up 0`。
**解决**: 在 entrypoint.sh 生成 sentinel.conf 时加 `requirepass ${REDIS_PASSWORD}`，让 Sentinel 也需要密码认证。这样 exporter 带密码连接就能成功。
**验证**: `redis_sentinel_master_ckquorum_status 1`，`redis_sentinel_master_ok_sentinels 3`。
**注意**: 不需要 `REDIS_EXPORTER_IS_SENTINEL=true` 环境变量 — redis_exporter 能自动识别 Sentinel。

---

## 坑 17: sentinel 在 failover 过程中返回过时的 master IP

**现象**: redis-0 被 kill 后重启，startup.sh 问 sentinel 得到 master IP `10.42.0.166`（redis-0 的旧 IP，已不存在），redis-0 SLAVEOF 10.42.0.166 → 连接超时 → `master_link_status:down`。
**根因**: redis-0 被 kill 后，sentinel 开始 failover（需要 5s sdown + 选举时间）。如果 redis-0 重启太快（在 sentinel 完成 failover 之前），sentinel 的 `get-master-addr-by-name` 还返回旧 IP。
**时间线**:
1. redis-0 被 kill → IP 10.42.0.166 消失
2. sentinel 标记 SDOWN (5s) → 选举新 master redis-1 (10.42.2.12)
3. redis-0 重启 → 问 sentinel → sentinel 还在 failover 中 → 返回旧 IP 10.42.0.166
4. redis-0 SLAVEOF 10.42.0.166 → 连不上
**解决**: startup.sh 在 SLAVEOF 前验证 master IP 可达（PING）。不可达则重试问 sentinel（最多 5 次，每次间隔 3s），直到 sentinel 更新到正确的 IP。
```sh
while [ "$i" -lt 5 ]; do
  i=$((i + 1))
  cli -h "${MASTER_IP}" -p 6379 PING 2>/dev/null | grep -q PONG && break
  echo "[warn] master ${MASTER_IP} unreachable, retrying sentinel..."
  sleep 3
  NEW_IP="$(get_master_from_sentinel)"
  [ -n "${NEW_IP}" ] && MASTER_IP="${NEW_IP}"
done
```
**验证**: redis-0 重启后 `master_host:10.42.2.12`，`master_link_status:up`，数据复制正常。

---

## 坑 18: readinessProbe=ROLE=master 导致事件风暴

**现象**: slave pod 持续产生 `Readiness probe failed` 事件，10 分钟 309 次，1 年累计数千万次。
**根因**: readinessProbe 检查 `ROLE | grep master`，slave 永远不通过 → 每 3s 产生一个失败事件。
**影响**:
- etcd 压力：K8s 事件默认 TTL=1h，同时存在 ~3600 个事件持续写入/删除
- kubelet 压力：每 3s 执行一次 `redis-cli ROLE` 命令
- API server 压力：频繁创建/更新 Event 对象
- 监控告警噪音：持续报 "Unhealthy"
**解决**: 用 **sidecar + label** 方案替代 readinessProbe 路由：
1. 加 `role-tagger` sidecar（`curlimages/curl`），每 5s 从 redis_exporter metrics 获取 ROLE，PATCH pod label `redis-role=master|slave`
2. readinessProbe 改为检查 PING（健康），所有 pod 都 Ready
3. redis-master.svc selector 改为 `redis-role=master`，只路由到 master
4. 加 RBAC（ServiceAccount + Role + RoleBinding）
**优势**:
- 消除所有 readiness probe 失败事件
- slave 也 Ready → headless DNS 正常解析
- failover 后 label 自动更新（~5s），Service 自动切换
**验证**: failover 测试（杀 redis-2 master）→ redis-1 成为新 master → label 自动更新 → redis-master.svc endpoint 自动切换到 redis-1。所有 pod 3/3 Ready，零失败事件。

---

## 坑 19: Sentinel num-slaves 包含历史 IP

**现象**: `SENTINEL master mymaster` 报 `num-slaves=11`，但 master 实际只有 2 个 online slave。
**根因**: Pod 重建时 IP 变化（如 failover 测试 redis-2 从 `10.42.1.208` → `10.42.1.228` → `10.42.1.58`），Sentinel 把新 slave 加入列表，但**旧 slave 条目不立即删除**，保留约 30 分钟（直到确认 SDOWN 才清理）。
**影响**:
- **不影响 failover**: Sentinel 选举只看 `state=ok` 的 slave，历史 IP 都是 `S_DOWN/disconnected`
- **不影响复制**: master 只向 online slave 同步
- **不影响数据**: 完全无关
- **唯一影响**: `SENTINEL slaves` 返回列表有噪音，运维可能误判
**修复**: check.sh 区分 `online`（master connected_slaves）和 `tracked`（sentinel num-slaves），tracked > online 时提示"历史 IP，30min 后自动清理"。
**验证**: `online=2 tracked=11`，exporter `ok_slaves=2`（与 master connected_slaves 一致）。

---

## 坑 20: role-tagger sidecar 优化

**问题**: 原 sidecar 无日志、无 livenessProbe、每次循环都 PATCH label（即使 role 没变）。
**优化**:
1. 启动时等待 exporter ready（避免启动噪音）
2. 只在 role 变化时 PATCH label（减少 API 调用）
3. 输出日志（`[role-tagger] role=master (label updated, http=200)`）
4. 加 livenessProbe：检查 `/tmp/last_alive` 文件是否在 60s 内更新（sidecar 每次循环 touch 一次）
5. 检查 PATCH 返回的 HTTP code（200 才更新 LAST_ROLE）
**验证**: failover 时日志显示 `role=slave → role=master`，零重启，livenessProbe 无误杀。

---

## 坑 21: 全集群重启死锁 — sentinel 返回死 IP

**现象**: 同时删 3 个 redis + 2 个 sentinel 后，所有 redis pod 启动后都成为 slave 去连一个**不存在的旧 master IP**（`10.42.1.58`），没有任何 pod 自举为 master，集群死锁。
**根因**:
1. sentinel 启动时从**持久化的 sentinel.conf**（emptyDir 不会丢，因为是同一次 pod 生命周期）读到旧 master IP `10.42.1.58`
2. redis 启动时问 sentinel "谁是 master" → sentinel 返回死 IP `10.42.1.58`
3. startup.sh 的三分支逻辑：sentinel 返回了 master → 验证可达性失败 5 次 → **但没有 fallback 到冷启动**，而是继续 `SLAVEOF` 死 IP
4. 所有 redis 都成为 slave 去连死 IP → 没有自举 master → 集群死锁
**影响**: 全集群重启（如节点维护、断电）后集群无法自愈。
**修复**:
1. **startup.sh**: sentinel 返回的 master 验证可达性失败后，**fallback 到冷启动逻辑**（ordinal=0 自举，ordinal>0 等 redis-0）
2. **entrypoint.sh (sentinel)**: find_master 从其他 sentinel 拿到 master IP 后，**验证可达性**，不可达则继续扫描 redis pod
**验证**: 同时删 3 redis + 2 sentinel → redis-0 自举 master → redis-1/2 成为 slave → sentinel 监控新 master → 集群恢复。所有 pod 3/3 Ready。
**关键**: 这是"无论如何删除都能恢复"的关键修复。

---

## 坑 22: sentinel fallback 到 127.0.0.1 导致死锁

**现象**: 全集群重启时, 若 redis-0 pod 还没创建 (节点资源紧张/镜像拉取慢), sentinel fallback 到 `127.0.0.1` (自己), 永远不会发现真正的 master.
**根因**: entrypoint.sh 的 fallback 逻辑 `[ -z "${MASTER_IP}" ] && MASTER_IP="127.0.0.1"`. sentinel 监控 127.0.0.1:6379 (自己没有 redis), PING 失败但 sentinel 本身的 26379 端口 PING 成功, 所以 sentinel 不会 crash, 也不会重新 find_master.
**影响**: 全集群重启时若 redis-0 创建慢, sentinel 死锁.
**修复**: fallback 失败时 `exit 1` (crash 重启), 等 redis-0 创建后再启动.
**验证**: 删 sentinel 后重启, find_master 失败时 exit 1, K8s 重启, redis-0 创建后 find_master 成功.
