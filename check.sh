#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# check.sh — Redis Sentinel 集群状态检测
#
# Usage: ./check.sh
#
# 检测内容:
#   - Pod 状态 (Ready / IP / 重启次数 / 节点)
#   - Redis 角色 (master/slave) + slaves 信息
#   - Sentinel 状态 + master 地址 + ok_sentinels/ok_slaves
#   - Service endpoint (redis-master 是否路由到 master)
#   - Exporter 指标 (redis_up / ckquorum)
# ═══════════════════════════════════════════════════════════════

NS="redis"
PASS="$(kubectl -n "$NS" get secret redis-secret -o jsonpath='{.data.redis-password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")"

# Colors
G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
ok()   { echo -e "  ${G}✓${N} $1"; }
bad()  { echo -e "  ${R}✗${N} $1"; }
info() { echo -e "  ${Y}→${N} $1"; }
hdr()  { echo -e "\n${C}${B}[$1]${N}"; }

# redis-cli with auth — runs inside a redis pod
rcli() {
  local pod="$1"; shift
  if [ -n "$PASS" ]; then
    kubectl -n "$NS" exec "$pod" -c redis -- redis-cli -a "$PASS" "$@" 2>/dev/null
  else
    kubectl -n "$NS" exec "$pod" -c redis -- redis-cli "$@" 2>/dev/null
  fi
}

# sentinel-cli with auth
scli() {
  local pod="$1"; shift
  if [ -n "$PASS" ]; then
    kubectl -n "$NS" exec "$pod" -c sentinel -- redis-cli -p 26379 -a "$PASS" "$@" 2>/dev/null
  else
    kubectl -n "$NS" exec "$pod" -c sentinel -- redis-cli -p 26379 "$@" 2>/dev/null
  fi
}

ERRORS=0

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Redis Sentinel 集群状态检测  ($(date '+%Y-%m-%d %H:%M:%S'))"
echo "═══════════════════════════════════════════════════════════════"

# ── 1. Pod 状态 ────────────────────────────────────────────────
hdr "Pod 状态"

if ! kubectl -n "$NS" get pod >/dev/null 2>&1; then
  bad "namespace '$NS' 不存在或无 pod"
  exit 1
fi

MASTER_POD=""
MASTER_IP=""
for pod in redis-0 redis-1 redis-2; do
  if ! kubectl -n "$NS" get pod "$pod" >/dev/null 2>&1; then
    bad "$pod: 不存在"
    ERRORS=$((ERRORS+1))
    continue
  fi

  ready="$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.status.containerStatuses[0].ready}')"
  restarts="$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.status.containerStatuses[0].restartCount}')"
  ip="$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.status.podIP}')"
  node="$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.spec.nodeName}')"
  role="$(rcli "$pod" role 2>/dev/null | head -1 || echo 'unreachable')"

  # All pods should be Ready (readinessProbe=PING, not ROLE).
  # Master routing is handled by redis-role label (set by role-tagger sidecar).
  if [ "$role" = "master" ]; then
    [ "$ready" = "true" ] && ok "$pod: master  IP=$ip  node=$node  restarts=$restarts" || { bad "$pod: master 但 NotReady"; ERRORS=$((ERRORS+1)); }
    MASTER_POD="$pod"
    MASTER_IP="$ip"
  elif [ "$role" = "slave" ]; then
    [ "$ready" = "true" ] && ok "$pod: slave   IP=$ip  node=$node  restarts=$restarts" || { bad "$pod: slave 但 NotReady"; ERRORS=$((ERRORS+1)); }
  else
    bad "$pod: $role  IP=$ip  node=$node  restarts=$restarts  ready=$ready"
    ERRORS=$((ERRORS+1))
  fi
done

[ -n "$MASTER_POD" ] && ok "当前 master: $MASTER_POD ($MASTER_IP)" || { bad "未找到 master"; ERRORS=$((ERRORS+1)); }

# ── 2. Sentinel Pod 状态 ──────────────────────────────────────
hdr "Sentinel Pod 状态"
for pod in sentinel-0 sentinel-1 sentinel-2; do
  if ! kubectl -n "$NS" get pod "$pod" >/dev/null 2>&1; then
    bad "$pod: 不存在"
    ERRORS=$((ERRORS+1))
    continue
  fi
  ready="$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.status.containerStatuses[0].ready}')"
  restarts="$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.status.containerStatuses[0].restartCount}')"
  ip="$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.status.podIP}')"
  node="$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.spec.nodeName}')"
  if [ "$ready" = "true" ]; then
    ok "$pod: ready  IP=$ip  node=$node  restarts=$restarts"
  else
    bad "$pod: NotReady  IP=$ip  restarts=$restarts"
    ERRORS=$((ERRORS+1))
  fi
done

# ── 3. Redis 角色与复制信息 ───────────────────────────────────
hdr "Redis 角色与复制"

if [ -n "$MASTER_POD" ]; then
  info "master ($MASTER_POD) role 输出:"
  rcli "$MASTER_POD" role 2>/dev/null | sed 's/^/    /'

  echo ""
  info "master 复制状态:"
  rcli "$MASTER_POD" INFO replication 2>/dev/null | grep -E "^(role|connected_slaves|slave[0-9])" | sed 's/^/    /'

  echo ""
  info "各 slave 复制状态:"
  for pod in redis-0 redis-1 redis-2; do
    [ "$pod" = "$MASTER_POD" ] && continue
    link_status="$(rcli "$pod" INFO replication 2>/dev/null | grep master_link_status | cut -d: -f2 | tr -d '\r')"
    master_host="$(rcli "$pod" INFO replication 2>/dev/null | grep master_host | cut -d: -f2 | tr -d '\r')"
    lag="$(rcli "$pod" INFO replication 2>/dev/null | grep master_last_io_seconds_ago | cut -d: -f2 | tr -d '\r')"
    if [ "$link_status" = "up" ]; then
      ok "$pod: slave → $master_host  link=$link_status  last_io=${lag}s"
    else
      bad "$pod: slave → $master_host  link=$link_status  last_io=${lag}s"
      ERRORS=$((ERRORS+1))
    fi
  done
fi

# ── 4. Sentinel 核心信息 ──────────────────────────────────────
hdr "Sentinel 核心信息"

# Get actual online slave count from master (truth source)
ONLINE_SLAVES=""
if [ -n "$MASTER_POD" ]; then
  ONLINE_SLAVES="$(rcli "$MASTER_POD" INFO replication 2>/dev/null | grep '^connected_slaves:' | cut -d: -f2 | tr -d '\r')"
  [ -z "$ONLINE_SLAVES" ] && ONLINE_SLAVES="0"
fi

SENT_MASTER=""
for pod in sentinel-0 sentinel-1 sentinel-2; do
  if ! kubectl -n "$NS" get pod "$pod" >/dev/null 2>&1; then continue; fi
  master_addr="$(scli "$pod" SENTINEL get-master-addr-by-name mymaster 2>/dev/null | head -2 | tr '\n' ':' | sed 's/:$//')"
  # num-slaves includes historical IPs (S_DOWN slaves not yet cleaned up).
  # Use master's connected_slaves as the actual online count.
  tracked_slaves="$(scli "$pod" SENTINEL master mymaster 2>/dev/null | grep -A1 'num-slaves' | tail -1 | tr -d '\r')"
  ok_sentinels="$(scli "$pod" SENTINEL master mymaster 2>/dev/null | grep -A1 'num-other-sentinels' | tail -1 | tr -d '\r')"
  sdown="$(scli "$pod" SENTINEL master mymaster 2>/dev/null | grep -A1 'sdown-time' | tail -1 | tr -d '\r')"
  ftimeout="$(scli "$pod" SENTINEL master mymaster 2>/dev/null | grep -A1 'failover-timeout' | tail -1 | tr -d '\r')"
  quorum="$(scli "$pod" SENTINEL master mymaster 2>/dev/null | grep -A1 'quorum' | tail -1 | tr -d '\r')"

  [ -z "$SENT_MASTER" ] && SENT_MASTER="$master_addr"
  ok "$pod: master=$master_addr  online=$ONLINE_SLAVES  tracked=$tracked_slaves  sentinels=$ok_sentinels  quorum=$quorum"
done

# Warn if tracked >> online (historical IPs not yet cleaned)
if [ -n "$ONLINE_SLAVES" ] && [ -n "$tracked_slaves" ] && [ "$tracked_slaves" -gt "$ONLINE_SLAVES" ] 2>/dev/null; then
  info "Sentinel tracked=$tracked_slaves > online=$ONLINE_SLAVES (历史 IP, 30min 后自动清理, 不影响 failover)"
fi

# ── 5. Service 路由验证 ───────────────────────────────────────
hdr "Service 路由"

info "redis-master.svc endpoint (应只指向 master):"
ep="$(kubectl -n "$NS" get endpoints redis-master -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null)"
if [ -n "$ep" ]; then
  if [ "$ep" = "$MASTER_IP" ]; then
    ok "redis-master → $ep (与 master IP 一致)"
  else
    bad "redis-master → $ep (与 master IP $MASTER_IP 不一致!)"
    ERRORS=$((ERRORS+1))
  fi
else
  bad "redis-master 无 endpoint"
  ERRORS=$((ERRORS+1))
fi

info "redis-read.svc endpoints (应包含所有节点):"
read_eps="$(kubectl -n "$NS" get endpoints redis-read -o jsonpath='{.subsets[0].addresses[*].ip}' 2>/dev/null | tr ' ' ',')"
read_nots="$(kubectl -n "$NS" get endpoints redis-read -o jsonpath='{.subsets[0].notReadyAddresses[*].ip}' 2>/dev/null | tr ' ' ',')"
ok "Ready: $read_eps"
ok "NotReady: $read_nots"

# ── 6. Exporter 指标 ──────────────────────────────────────────
hdr "Exporter 指标"

redis_up="$(kubectl -n "$NS" run check-re --image=curlimages/curl:7.88.1 --rm -i --restart=Never -- -sf http://redis-exporter:9121/metrics 2>/dev/null | grep '^redis_up ' | awk '{print $2}')"
if [ "$redis_up" = "1" ]; then
  ok "redis_exporter: redis_up=1"
else
  bad "redis_exporter: redis_up=$redis_up (应为 1)"
  ERRORS=$((ERRORS+1))
fi

sent_ckq="$(kubectl -n "$NS" run check-se --image=curlimages/curl:7.88.1 --rm -i --restart=Never -- -sf http://sentinel-exporter:9121/metrics 2>/dev/null | grep '^redis_sentinel_master_ckquorum_status{' | awk -F' ' '{print $NF}')"
if [ "$sent_ckq" = "1" ]; then
  ok "sentinel_exporter: ckquorum_status=1"
else
  bad "sentinel_exporter: ckquorum_status=$sent_ckq (应为 1)"
  ERRORS=$((ERRORS+1))
fi

sent_slaves="$(kubectl -n "$NS" run check-se2 --image=curlimages/curl:7.88.1 --rm -i --restart=Never -- -sf http://sentinel-exporter:9121/metrics 2>/dev/null | grep '^redis_sentinel_master_ok_slaves{' | awk -F' ' '{print $NF}')"
sent_sents="$(kubectl -n "$NS" run check-se3 --image=curlimages/curl:7.88.1 --rm -i --restart=Never -- -sf http://sentinel-exporter:9121/metrics 2>/dev/null | grep '^redis_sentinel_master_ok_sentinels{' | awk -F' ' '{print $NF}')"
ok "sentinel_exporter: ok_slaves=$sent_slaves  ok_sentinels=$sent_sents"

# ── 7. PDB ────────────────────────────────────────────────────
hdr "PDB"
for pdb in redis-pdb sentinel-pdb; do
  min="$(kubectl -n "$NS" get pdb $pdb -o jsonpath='{.spec.minAvailable}' 2>/dev/null)"
  allowed="$(kubectl -n "$NS" get pdb $pdb -o jsonpath='{.status.disruptionsAllowed}' 2>/dev/null)"
  ok "$pdb: minAvailable=$min  disruptionsAllowed=$allowed"
done

# ── Summary ───────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════"
if [ "$ERRORS" -eq 0 ]; then
  echo -e "  ${G}${B}✓ 集群状态正常${N}  (master=$MASTER_POD, $MASTER_IP)"
else
  echo -e "  ${R}${B}✗ 发现 $ERRORS 个问题${N}  (master=$MASTER_POD, $MASTER_IP)"
fi
echo "═══════════════════════════════════════════════════════════════"
echo ""
exit $ERRORS
