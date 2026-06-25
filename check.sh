#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# check.sh — Redis Sentinel 实例健康检查
#
# 输出原生关键性指标和健康结论:
#   - Pod 状态 (Ready / restartCount / 节点分布)
#   - Redis 角色 (master/slave + 复制延迟)
#   - Sentinel 状态 (quorum / ok_sentinels / ok_slaves)
#   - Service 路由 (master svc → master IP)
#   - Exporter 指标 (redis_up / connected_slaves / 内存 / QPS)
#   - PDB ( disruptionsAllowed )
#   - 健康结论 (PASS / FAIL + 问题清单)
#
# Usage:
#   ./check.sh [instance] [namespace]
#   ./check.sh                          # instance=redis, ns=redis
#   ./check.sh redis-saas-log          # 指定实例
#   ./check.sh redis-saas-log middleware
# ═══════════════════════════════════════════════════════════════

set -u

INSTANCE="${1:-redis}"
NS="${2:-redis}"

# 颜色
G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
ok()   { echo -e "  ${G}✓${N} $1"; }
bad()  { echo -e "  ${R}✗${N} $1"; }
warn() { echo -e "  ${Y}!${N} $1"; }
info() { echo -e "  ${Y}→${N} $1"; }
hdr()  { echo -e "\n${C}${B}═══ $1 ═══${N}"; }

# 从 secret 读密码
PASS="$(kubectl -n "$NS" get secret "${INSTANCE}-secret" -o jsonpath='{.data.redis-password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")"

ERRORS=0
WARNINGS=0
ISSUES=()

record_issue() {
  ISSUES+=("$1")
  ERRORS=$((ERRORS+1))
}
record_warn() {
  ISSUES+=("[warn] $1")
  WARNINGS=$((WARNINGS+1))
}

# redis-cli (在 pod 内执行)
rcli() {
  local pod="$1"; shift
  if [ -n "$PASS" ]; then
    kubectl -n "$NS" exec "$pod" -c redis -- redis-cli -a "$PASS" "$@" 2>/dev/null
  else
    kubectl -n "$NS" exec "$pod" -c redis -- redis-cli "$@" 2>/dev/null
  fi
}

# sentinel-cli
scli() {
  local pod="$1"; shift
  if [ -n "$PASS" ]; then
    kubectl -n "$NS" exec "$pod" -c sentinel -- redis-cli -p 26379 -a "$PASS" "$@" 2>/dev/null
  else
    kubectl -n "$NS" exec "$pod" -c sentinel -- redis-cli -p 26379 "$@" 2>/dev/null
  fi
}

# 从 exporter 读指标
get_metric() {
  local metric="$1"
  kubectl -n "$NS" run check-metric --image=curlimages/curl:7.88.1 --rm -i --restart=Never -- \
    -sf "http://${INSTANCE}-exporter.${NS}.svc:9121/metrics" 2>/dev/null \
    | grep "^${metric} " | awk '{print $NF}' | head -1
}

get_sentinel_metric() {
  local metric="$1"
  kubectl -n "$NS" run check-sm --image=curlimages/curl:7.88.1 --rm -i --restart=Never -- \
    -sf "http://${INSTANCE}-sentinel-exporter.${NS}.svc:9121/metrics" 2>/dev/null \
    | grep "^${metric}" | awk -F' ' '{print $NF}' | head -1
}

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Redis Sentinel 健康检查"
echo "  instance=${INSTANCE}  ns=${NS}  $(date '+%Y-%m-%d %H:%M:%S')"
echo "═══════════════════════════════════════════════════════════════"

# ── 1. Pod 状态 ────────────────────────────────────────────────

hdr "1. Pod 状态"

if ! kubectl -n "$NS" get pod >/dev/null 2>&1; then
  bad "namespace '${NS}' 不存在或无 pod"
  exit 1
fi

MASTER_POD=""
MASTER_IP=""
ALL_NODES=""

for i in 0 1 2; do
  pod="${INSTANCE}-${i}"
  if ! kubectl -n "$NS" get pod "$pod" >/dev/null 2>&1; then
    bad "$pod: 不存在"
    record_issue "$pod 不存在"
    continue
  fi

  ready="$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.status.containerStatuses[0].ready}')"
  restarts="$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.status.containerStatuses[0].restartCount}')"
  ip="$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.status.podIP}')"
  node="$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.spec.nodeName}')"
  role="$(rcli "$pod" role 2>/dev/null | head -1 || echo 'unreachable')"
  ALL_NODES="${ALL_NODES} ${node}"

  # 检查 role-tagger label
  label_role="$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.metadata.labels.redis-role}' 2>/dev/null)"

  if [ "$role" = "master" ]; then
    [ "$ready" = "true" ] && ok "$pod: ${B}master${N}  IP=$ip  node=$node  restarts=$restarts" || { bad "$pod: master 但 NotReady"; record_issue "$pod NotReady"; }
    [ "$label_role" = "master" ] || warn "$pod: redis-role=$label_role (应=master, role-tagger 可能未同步)"
    MASTER_POD="$pod"
    MASTER_IP="$ip"
  elif [ "$role" = "slave" ]; then
    [ "$ready" = "true" ] && ok "$pod: slave   IP=$ip  node=$node  restarts=$restarts" || { bad "$pod: slave 但 NotReady"; record_issue "$pod NotReady"; }
    [ "$label_role" = "slave" ] || warn "$pod: redis-role=$label_role (应=slave)"
  else
    bad "$pod: $role  (IP=$ip node=$node restarts=$restarts ready=$ready)"
    record_issue "$pod 状态异常: $role"
  fi

  # 重启次数过高
  if [ "${restarts:-0}" -gt 5 ] 2>/dev/null; then
    warn "$pod: restarts=$restarts (过高, 可能在 crash loop)"
    record_warn "$pod restarts=$restarts"
  fi
done

[ -n "$MASTER_POD" ] && ok "当前 master: ${B}${MASTER_POD}${N} ($MASTER_IP)" || { bad "未找到 master"; record_issue "无 master"; }

# 节点分布检查 (同节点多 pod 是风险)
node_count=$(echo "$ALL_NODES" | tr ' ' '\n' | grep -v '^$' | sort -u | wc -l | tr -d ' ')
pod_count=$(echo "$ALL_NODES" | tr ' ' '\n' | grep -v '^$' | wc -l | tr -d ' ')
if [ "$pod_count" -gt 1 ] && [ "$node_count" = "1" ]; then
  warn "所有 Redis pod 在同一节点 ($ALL_NODES), 节点宕机会全挂"
  record_warn "所有 redis pod 单节点部署"
else
  ok "节点分布: $pod_count pod 跨 $node_count 节点"
fi

# ── 2. Sentinel Pod 状态 ──────────────────────────────────────

hdr "2. Sentinel Pod 状态"
SENT_READY_COUNT=0
for i in 0 1 2; do
  pod="${INSTANCE}-sentinel-${i}"
  if ! kubectl -n "$NS" get pod "$pod" >/dev/null 2>&1; then
    bad "$pod: 不存在"
    record_issue "$pod 不存在"
    continue
  fi
  ready="$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.status.containerStatuses[0].ready}')"
  restarts="$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.status.containerStatuses[0].restartCount}')"
  ip="$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.status.podIP}')"
  if [ "$ready" = "true" ]; then
    ok "$pod: ready  IP=$ip  restarts=$restarts"
    SENT_READY_COUNT=$((SENT_READY_COUNT+1))
  else
    bad "$pod: NotReady  restarts=$restarts"
    record_issue "$pod NotReady"
  fi
done

if [ "$SENT_READY_COUNT" -lt 2 ]; then
  warn "仅 $SENT_READY_COUNT 个 sentinel Ready (quorum=2 无法达成, 无法 failover)"
  record_warn "仅 $SENT_READY_COUNT sentinel Ready"
else
  ok "Sentinel 数: $SENT_READY_COUNT Ready (quorum=2 可达成)"
fi

# ── 3. Redis 复制状态 ─────────────────────────────────────────

hdr "3. Redis 复制状态"

if [ -n "$MASTER_POD" ]; then
  info "master ($MASTER_POD) INFO replication:"
  rcli "$MASTER_POD" INFO replication 2>/dev/null | grep -E "^(role|connected_slaves|slave[0-9]|master_repl_offset|repl_backlog)" | sed 's/^/    /'

  connected_slaves="$(rcli "$MASTER_POD" INFO replication 2>/dev/null | grep '^connected_slaves:' | cut -d: -f2 | tr -d '\r')"
  if [ "${connected_slaves:-0}" -lt 2 ]; then
    warn "master connected_slaves=$connected_slaves (应=2, 复制可能未建立)"
    record_warn "master connected_slaves=$connected_slaves"
  else
    ok "master connected_slaves=$connected_slaves"
  fi

  echo ""
  info "各 slave 复制状态:"
  for i in 0 1 2; do
    pod="${INSTANCE}-${i}"
    [ "$pod" = "$MASTER_POD" ] && continue
    if ! kubectl -n "$NS" get pod "$pod" >/dev/null 2>&1; then continue; fi
    link_status="$(rcli "$pod" INFO replication 2>/dev/null | grep master_link_status | cut -d: -f2 | tr -d '\r')"
    master_host="$(rcli "$pod" INFO replication 2>/dev/null | grep master_host | cut -d: -f2 | tr -d '\r')"
    lag="$(rcli "$pod" INFO replication 2>/dev/null | grep master_last_io_seconds_ago | cut -d: -f2 | tr -d '\r')"
    sync="$(rcli "$pod" INFO replication 2>/dev/null | grep master_sync_in_progress | cut -d: -f2 | tr -d '\r')"
    if [ "$link_status" = "up" ] && [ "${sync:-0}" = "0" ]; then
      ok "$pod: slave → $master_host  link=up  lag=${lag}s"
    elif [ "$link_status" = "down" ]; then
      bad "$pod: slave → $master_host  link=down  (复制断开)"
      record_issue "$slave 复制断开"
    else
      warn "$pod: slave → $master_host  link=$link_status  sync=$sync  lag=${lag}s"
    fi
    # lag 过大
    if [ -n "${lag:-}" ] && [ "${lag:-0}" -gt 30 ] 2>/dev/null; then
      warn "$pod: master_last_io_seconds_ago=$lag (复制延迟 >30s)"
      record_warn "$pod 复制延迟 ${lag}s"
    fi
  done
fi

# ── 4. Sentinel 核心信息 ──────────────────────────────────────

hdr "4. Sentinel 核心信息"

SENT_MASTER=""
OK_SENTINELS=""
OK_SLAVES=""
QUORUM=""

if [ "$SENT_READY_COUNT" -gt 0 ]; then
  for i in 0 1 2; do
    pod="${INSTANCE}-sentinel-${i}"
    if ! kubectl -n "$NS" get pod "$pod" >/dev/null 2>&1; then continue; fi
    master_addr="$(scli "$pod" SENTINEL get-master-addr-by-name mymaster 2>/dev/null | head -2 | tr '\n' ':' | sed 's/:$//')"
    tracked_slaves="$(scli "$pod" SENTINEL master mymaster 2>/dev/null | grep -A1 'num-slaves' | tail -1 | tr -d '\r')"
    ok_sents="$(scli "$pod" SENTINEL master mymaster 2>/dev/null | grep -A1 'num-other-sentinels' | tail -1 | tr -d '\r')"
    quorum="$(scli "$pod" SENTINEL master mymaster 2>/dev/null | grep -A1 'quorum' | tail -1 | tr -d '\r')"
    flags="$(scli "$pod" SENTINEL master mymaster 2>/dev/null | grep -A1 'flags' | tail -1 | tr -d '\r')"

    [ -z "$SENT_MASTER" ] && SENT_MASTER="$master_addr"
    [ -z "$OK_SENTINELS" ] && OK_SENTINELS="$ok_sents"
    [ -z "$OK_SLAVES" ] && OK_SLAVES="$tracked_slaves"
    [ -z "$QUORUM" ] && QUORUM="$quorum"

    ok "$pod: master=$master_addr  tracked_slaves=$tracked_slaves  other_sentinels=$ok_sents  quorum=$quorum  flags=$flags"

    # 检查 master 是否 sdown/odown
    if echo "$flags" | grep -qE "sdown|odown"; then
      bad "$pod: master flags=$flags (sentinel 已判 master 宕机)"
      record_issue "$pod sentinel 判 master down"
    fi
  done

  # sentinel 报告的 master IP 与实际 master IP 一致?
  if [ -n "$SENT_MASTER" ] && [ -n "$MASTER_IP" ]; then
    sent_ip="$(echo "$SENT_MASTER" | cut -d: -f1)"
    if [ "$sent_ip" = "$MASTER_IP" ]; then
      ok "Sentinel 报告 master IP ($sent_ip) 与实际 ($MASTER_IP) 一致"
    else
      bad "Sentinel 报告 master IP=$sent_ip, 实际=$MASTER_IP (不一致, 可能 failover 进行中或状态陈旧)"
      record_issue "sentinel 与实际 master IP 不一致"
    fi
  fi
else
  bad "无 sentinel 可用"
  record_issue "无 sentinel"
fi

# ── 5. Service 路由 ────────────────────────────────────────────

hdr "5. Service 路由"

info "${INSTANCE}-master.svc endpoint:"
EP_IP="$(kubectl -n "$NS" get endpoints "${INSTANCE}-master" -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null)"
EP_READY="$(kubectl -n "$NS" get endpoints "${INSTANCE}-master" -o jsonpath='{.subsets[0].addresses[*].ip}' 2>/dev/null | tr ' ' ',')"
EP_NOTREADY="$(kubectl -n "$NS" get endpoints "${INSTANCE}-master" -o jsonpath='{.subsets[0].notReadyAddresses[*].ip}' 2>/dev/null | tr ' ' ',')"

if [ -n "$EP_IP" ]; then
  if [ "$EP_IP" = "$MASTER_IP" ]; then
    ok "${INSTANCE}-master → $EP_IP (与 master IP 一致)"
  else
    bad "${INSTANCE}-master → $EP_IP (与 master IP $MASTER_IP 不一致!)"
    record_issue "master svc 路由错误"
  fi
else
  bad "${INSTANCE}-master 无 endpoint (所有 pod 都没 redis-role=master label?)"
  record_issue "master svc 无 endpoint"
fi
ok "Ready: ${EP_READY:-无}  NotReady: ${EP_NOTREADY:-无}"

info "${INSTANCE}-read.svc endpoints:"
READ_EPS="$(kubectl -n "$NS" get endpoints "${INSTANCE}-read" -o jsonpath='{.subsets[0].addresses[*].ip}' 2>/dev/null | tr ' ' ',')"
READ_N="$(echo "$READ_EPS" | tr ',' '\n' | grep -c . || echo 0)"
ok "read endpoints: ${READ_EPS:-无} ($READ_N 个)"

# ── 6. Exporter 原生指标 ──────────────────────────────────────

hdr "6. Exporter 原生指标 (redis_up / 内存 / QPS)"

REDIS_UP="$(get_metric 'redis_up' 2>/dev/null)"
if [ "$REDIS_UP" = "1" ]; then
  ok "redis_up = 1 (exporter 能连 redis)"
else
  bad "redis_up = ${REDIS_UP:-?} (exporter 无法连 redis)"
  record_issue "redis_up=${REDIS_UP:-?}"
fi

# 核心指标 (从 master pod 直接查, 比 exporter 更可靠)
if [ -n "$MASTER_POD" ]; then
  info "Redis 原生关键指标 (master $MASTER_POD):"
  echo ""
  echo "    ┌────────────────────────────┬───────────────────────┐"
  printf "    │ %-26s │ %-21s │\n" "指标" "值"
  echo "    ├────────────────────────────┼───────────────────────┤"

  # 角色
  role="$(rcli "$MASTER_POD" role 2>/dev/null | head -1)"
  printf "    │ %-26s │ %-21s │\n" "role" "${role:-?}"

  # connected_slaves
  cs="$(rcli "$MASTER_POD" INFO replication 2>/dev/null | grep '^connected_slaves:' | cut -d: -f2 | tr -d '\r')"
  printf "    │ %-26s │ %-21s │\n" "connected_slaves" "${cs:-?}"

  # master_repl_offset
  ro="$(rcli "$MASTER_POD" INFO replication 2>/dev/null | grep '^master_repl_offset:' | cut -d: -f2 | tr -d '\r')"
  printf "    │ %-26s │ %-21s │\n" "master_repl_offset" "${ro:-?}"

  # 内存
  used_mem="$(rcli "$MASTER_POD" INFO memory 2>/dev/null | grep '^used_memory:' | cut -d: -f2 | tr -d '\r')"
  used_mem_h="$(rcli "$MASTER_POD" INFO memory 2>/dev/null | grep '^used_memory_human:' | cut -d: -f2 | tr -d '\r')"
  printf "    │ %-26s │ %-21s │\n" "used_memory" "${used_mem:-?} bytes"

  maxmem="$(rcli "$MASTER_POD" CONFIG GET maxmemory 2>/dev/null | tail -1)"
  if [ -n "$maxmem" ] && [ "$maxmem" != "0" ]; then
    mem_pct=$(awk "BEGIN {printf \"%.1f\", (${used_mem:-0}/${maxmem})*100}" 2>/dev/null)
    printf "    │ %-26s │ %-21s │\n" "maxmemory" "$maxmem bytes (${mem_pct}%)"
    if awk "BEGIN {exit !(${mem_pct:-0} > 80)}" 2>/dev/null; then
      warn "内存使用率 ${mem_pct}% (>80%)"
      record_warn "内存使用率 ${mem_pct}%"
    fi
  else
    printf "    │ %-26s │ %-21s │\n" "maxmemory" "0 (无限制)"
  fi

  # 客户端连接数
  clients="$(rcli "$MASTER_POD" INFO clients 2>/dev/null | grep '^connected_clients:' | cut -d: -f2 | tr -d '\r')"
  printf "    │ %-26s │ %-21s │\n" "connected_clients" "${clients:-?}"

  # 键数
  db_size="$(rcli "$MASTER_POD" DBSIZE 2>/dev/null | tr -d '\r' || echo '?')"
  printf "    │ %-26s │ %-21s │\n" "db_size (key count)" "${db_size:-?}"

  # 拒绝连接数
  rejected="$(rcli "$MASTER_POD" INFO stats 2>/dev/null | grep '^rejected_connections:' | cut -d: -f2 | tr -d '\r')"
  printf "    │ %-26s │ %-21s │\n" "rejected_connections" "${rejected:-0}"
  if [ "${rejected:-0}" -gt 0 ] 2>/dev/null; then
    warn "rejected_connections=$rejected (有连接被拒绝)"
    record_warn "rejected_connections=$rejected"
  fi

  # 过期/淘汰 key 数
  expired="$(rcli "$MASTER_POD" INFO stats 2>/dev/null | grep '^expired_keys:' | cut -d: -f2 | tr -d '\r')"
  evicted="$(rcli "$MASTER_POD" INFO stats 2>/dev/null | grep '^evicted_keys:' | cut -d: -f2 | tr -d '\r')"
  printf "    │ %-26s │ %-21s │\n" "expired_keys" "${expired:-0}"
  printf "    │ %-26s │ %-21s │\n" "evicted_keys" "${evicted:-0}"
  if [ "${evicted:-0}" -gt 0 ] 2>/dev/null; then
    warn "evicted_keys=$evicted (有 key 被淘汰, 可能内存不足)"
    record_warn "evicted_keys=$evicted"
  fi

  # QPS (instantaneous_ops_per_sec)
  qps="$(rcli "$MASTER_POD" INFO stats 2>/dev/null | grep '^instantaneous_ops_per_sec:' | cut -d: -f2 | tr -d '\r')"
  printf "    │ %-26s │ %-21s │\n" "instantaneous_ops_per_sec" "${qps:-?}"

  # RDB 最后一次 bgsave 状态
  bgsave="$(rcli "$MASTER_POD" INFO persistence 2>/dev/null | grep '^rdb_last_bgsave_status:' | cut -d: -f2 | tr -d '\r')"
  printf "    │ %-26s │ %-21s │\n" "rdb_last_bgsave_status" "${bgsave:-?}"
  if [ "$bgsave" != "ok" ]; then
    warn "rdb_last_bgsave_status=$bgsave (bgsave 失败)"
    record_warn "rdb_last_bgsave_status=$bgsave"
  fi

  # min-slaves-to-write 配置检查
  min_slaves="$(rcli "$MASTER_POD" CONFIG GET min-slaves-to-write 2>/dev/null | tail -1)"
  printf "    │ %-26s │ %-21s │\n" "min-slaves-to-write" "${min_slaves:-?}"

  echo "    └────────────────────────────┴───────────────────────┘"

  # Sentinel 关键指标
  if [ -n "$OK_SENTINELS" ]; then
    echo ""
    info "Sentinel 关键指标:"
    echo "    ┌────────────────────────────┬───────────────────────┐"
    printf "    │ %-26s │ %-21s │\n" "指标" "值"
    echo "    ├────────────────────────────┼───────────────────────┤"
    printf "    │ %-26s │ %-21s │\n" "sentinel master" "${SENT_MASTER:-?}"
    ok_sent_total=$((${OK_SENTINELS:-0} + 1))
    printf "    │ %-26s │ %-21s │\n" "ok_sentinels" "$ok_sent_total"
    printf "    │ %-26s │ %-21s │\n" "ok_slaves" "${OK_SLAVES:-?}"
    printf "    │ %-26s │ %-21s │\n" "quorum" "${QUORUM:-?}"
    echo "    └────────────────────────────┴───────────────────────┘"

    # quorum 检查
    total_sent=$((${OK_SENTINELS:-0} + 1))
    if [ "$total_sent" -lt "${QUORUM:-2}" ] 2>/dev/null; then
      bad "sentinel 总数=$total_sent < quorum=${QUORUM} (无法 failover)"
      record_issue "sentinel 数 < quorum"
    fi

    # ok_slaves 检查
    if [ "${OK_SLAVES:-0}" -lt 1 ] 2>/dev/null; then
      warn "sentinel ok_slaves=0 (sentinel 认为无可用 slave, 无法 failover)"
      record_warn "sentinel ok_slaves=0"
    fi

    # sentinel ckquorum (Redis 原生命令)
    ckq="$(scli "${INSTANCE}-sentinel-0" SENTINEL ckquorum mymaster 2>/dev/null | tail -1)"
    if echo "$ckq" | grep -q "OK"; then
      ok "SENTINEL ckquorum: $ckq"
    else
      warn "SENTINEL ckquorum: $ckq"
      record_warn "ckquorum 失败: $ckq"
    fi
  fi
fi

# ── 7. PDB ────────────────────────────────────────────────────

hdr "7. PDB (PodDisruptionBudget)"

for pdb in "${INSTANCE}-pdb" "${INSTANCE}-sentinel-pdb"; do
  min="$(kubectl -n "$NS" get pdb "$pdb" -o jsonpath='{.spec.minAvailable}' 2>/dev/null)"
  allowed="$(kubectl -n "$NS" get pdb "$pdb" -o jsonpath='{.status.disruptionsAllowed}' 2>/dev/null)"
  cur="$(kubectl -n "$NS" get pdb "$pdb" -o jsonpath='{.status.currentHealthy}' 2>/dev/null)"
  if [ -n "$min" ]; then
    ok "$pdb: minAvailable=$min  currentHealthy=$cur  disruptionsAllowed=$allowed"
    if [ "${allowed:-0}" = "0" ]; then
      warn "$pdb disruptionsAllowed=0 (无法再驱逐, 维护时可能阻塞)"
      record_warn "$pdb disruptionsAllowed=0"
    fi
  else
    bad "$pdb: 不存在"
    record_issue "$pdb 不存在"
  fi
done

# ── 8. role-tagger 状态 ──────────────────────────────────────

hdr "8. role-tagger sidecar 状态"

for i in 0 1 2; do
  pod="${INSTANCE}-${i}"
  if ! kubectl -n "$NS" get pod "$pod" >/dev/null 2>&1; then continue; fi
  rt_restarts="$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{range .status.containerStatuses[?(@.name=="role-tagger")]}{.restartCount}{end}' 2>/dev/null)"
  rt_ready="$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{range .status.containerStatuses[?(@.name=="role-tagger")]}{.ready}{end}' 2>/dev/null)"
  if [ -n "$rt_restarts" ]; then
    if [ "$rt_ready" = "true" ] && [ "${rt_restarts:-0}" -lt 3 ]; then
      ok "$pod role-tagger: ready  restarts=$rt_restarts"
    else
      warn "$pod role-tagger: ready=$rt_ready  restarts=$rt_restarts"
      [ "${rt_restarts:-0}" -ge 3 ] && record_warn "$pod role-tagger restarts=$rt_restarts"
    fi
  fi
done

# ── 9. PVC 状态 ───────────────────────────────────────────────

hdr "9. PVC 持久化卷"

for i in 0 1 2; do
  pvc="data-${INSTANCE}-${i}"
  pvc_status="$(kubectl -n "$NS" get pvc "$pvc" -o jsonpath='{.status.phase}' 2>/dev/null)"
  pvc_size="$(kubectl -n "$NS" get pvc "$pvc" -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null)"
  if [ -n "$pvc_status" ]; then
    [ "$pvc_status" = "Bound" ] && ok "$pvc: $pvc_status ($pvc_size)" || { bad "$pvc: $pvc_status (应 Bound)"; record_issue "$pvc 非 Bound"; }
  fi
done

# ── Summary ───────────────────────────────────────────────────

echo ""
echo "═══════════════════════════════════════════════════════════════"
if [ "$ERRORS" -eq 0 ] && [ "$WARNINGS" -eq 0 ]; then
  echo -e "  ${G}${B}✓ 健康 (PASS)${N}  master=${MASTER_POD:-?} ($MASTER_IP)"
elif [ "$ERRORS" -eq 0 ]; then
  echo -e "  ${Y}${B}! 健康 (PASS, ${WARNINGS} 个警告)${N}  master=${MASTER_POD:-?} ($MASTER_IP)"
else
  echo -e "  ${R}${B}✗ 不健康 (FAIL, ${ERRORS} 个错误, ${WARNINGS} 个警告)${N}  master=${MASTER_POD:-?} ($MASTER_IP)"
  echo ""
  echo -e "  ${R}问题清单:${N}"
  for issue in "${ISSUES[@]}"; do
    echo -e "    ${R}•${N} $issue"
  done
fi
echo "═══════════════════════════════════════════════════════════════"
echo ""
exit $ERRORS
