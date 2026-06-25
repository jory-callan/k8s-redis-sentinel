#!/bin/bash
# 稳定性测试套件：验证各种故障场景下的自愈能力
# 快速 failover 参数：down-after=1s, failover-timeout=5s
# 用法: ./test-stability.sh [scenario]

set -u

NS="${NS:-redis}"
INSTANCE="${INSTANCE:-redis-stab}"
PASS="stab123"
MASTER_SVC="${INSTANCE}-master"
HELM_NAME="${INSTANCE}"

# 快速 failover 参数
HELM_ARGS=(
  --set common.instanceName="${INSTANCE}"
  --set common.auth.password="${PASS}"
  --set sentinel.config[0]="sentinel down-after-milliseconds mymaster 1000"
  --set sentinel.config[1]="sentinel failover-timeout mymaster 5000"
  --set sentinel.config[2]="sentinel parallel-syncs mymaster 1"
)

# ── 工具函数 ──────────────────────────────────────
log() { echo -e "\033[36m[$(date +%H:%M:%S)]\033[0m $*"; }
ok()  { echo -e "  \033[32m✓ $*\033[0m"; }
fail(){ echo -e "  \033[31m✗ $*\033[0m"; }
sep() { echo -e "\033[33m════════════════════════════════════════════════\033[0m"; }

# 等待集群稳定（有且仅有 1 个 master）
wait_stable() {
  local max="${1:-60}"
  local i=0
  while [ "$i" -lt "$max" ]; do
    local masters
    masters=$(kubectl -n "$NS" get pods -l "app=${INSTANCE}" -o jsonpath='{range .items[*]}{.metadata.labels.redis-role}{" "}{end}' 2>/dev/null | tr ' ' '\n' | grep -c master || echo 0)
    if [ "$masters" = "1" ]; then
      return 0
    fi
    i=$((i+1)); sleep 1
  done
  return 1
}

# 检查读写
check_rw() {
  local key="rw-test-$(date +%s)"
  local val="ok"
  kubectl -n "$NS" run tmp-rw-$key --image=redis:5.0.8-alpine --rm -i --restart=Never -- \
    sh -c "redis-cli -h ${MASTER_SVC} -a ${PASS} SET ${key} ${val} 2>/dev/null && \
           redis-cli -h ${MASTER_SVC} -a ${PASS} GET ${key} 2>/dev/null" 2>&1 | grep -vE "Warning|Defaulted|deleted" | tr -d '\r'
}

# 检查数据一致性
check_data_consistency() {
  local key="consistency-$(date +%s)"
  kubectl -n "$NS" run tmp-set --image=redis:5.0.8-alpine --rm -i --restart=Never -- \
    redis-cli -h "${MASTER_SVC}" -a "${PASS}" SET "$key" "check-value" 2>/dev/null | grep -v Warning
  sleep 2  # 等复制
  # 查所有 slave 是否有这个 key
  local slaves
  slaves=$(kubectl -n "$NS" get pods -l "app=${INSTANCE},redis-role=slave" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}')
  local all_ok=1
  for s in $slaves; do
    local val
    val=$(kubectl -n "$NS" exec "$s" -c redis -- redis-cli -a "${PASS}" GET "$key" 2>/dev/null | grep -v Warning)
    if [ "$val" != "check-value" ]; then
      all_ok=0
    fi
  done
  [ "$all_ok" = "1" ] && ok "数据一致性: 所有 slave 同步成功" || fail "数据一致性: slave 未同步"
}

# 获取状态
status() {
  echo "--- Pod 状态 ---"
  kubectl -n "$NS" get pods -l "app in (${INSTANCE},${INSTANCE}-sentinel)" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.labels.redis-role}{"\t"}{.status.phase}{"\n"}{end}' 2>/dev/null | column -t
  echo "--- Master Service ---"
  kubectl -n "$NS" get endpoints "${MASTER_SVC}" 2>/dev/null | tail -1
}

# 删除 pod
kill_pod() {
  local kind="$1"; shift
  local pods="$*"
  log "删除 ${kind}: ${pods}"
  kubectl -n "$NS" delete pod $pods --force --grace-period=0 2>&1 | grep -E "deleted|force" | head -5
}

# ── 测试场景 ──────────────────────────────────────

setup() {
  sep
  log "部署测试集群 (instance=${INSTANCE}, down-after=1s, failover-timeout=5s)"
  sep
  helm uninstall "${HELM_NAME}" -n "$NS" 2>/dev/null || true
  kubectl -n "$NS" delete pod -l "app in (${INSTANCE},${INSTANCE}-sentinel)" --force --grace-period=0 2>/dev/null
  kubectl -n "$NS" delete pvc -l "app.kubernetes.io/instance=${HELM_NAME}" 2>/dev/null
  sleep 3
  helm install "${HELM_NAME}" ./helm/redis-sentinel -n "$NS" "${HELM_ARGS[@]}" 2>&1 | tail -2
  log "等待所有 Pod Ready..."
  kubectl -n "$NS" wait pod --for=condition=Ready -l "app in (${INSTANCE},${INSTANCE}-sentinel)" --timeout=300s 2>&1 | tail -1
  sleep 10  # 等 role-tagger 更新 label
  if wait_stable 30; then
    ok "集群就绪，有 1 个 master"
    status
  else
    fail "集群未稳定"
    status
    exit 1
  fi
}

test_redis_1() {
  sep
  log "场景 1: 断开 1 个 redis (slave)"
  sep
  local slave_pod
  slave_pod=$(kubectl -n "$NS" get pods -l "app=${INSTANCE},redis-role=slave" -o jsonpath='{.items[0].metadata.name}')
  kill_pod "redis slave" "$slave_pod"
  log "等待恢复 (max 60s)..."
  if wait_stable 60; then
    ok "恢复成功 (有 1 个 master)"
    check_rw && ok "读写正常" || fail "读写失败"
    status
  else
    fail "未恢复"
    status
  fi
}

test_redis_2() {
  sep
  log "场景 2: 断开 2 个 redis (1 master + 1 slave)"
  sep
  kill_pod "master + slave" "$(kubectl -n "$NS" get pods -l "app=${INSTANCE}" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}')"
  log "等待恢复 (max 90s)..."
  if wait_stable 90; then
    ok "恢复成功"
    check_rw && ok "读写正常" || fail "读写失败"
    status
  else
    fail "未恢复"
    status
  fi
}

test_redis_3() {
  sep
  log "场景 3: 断开所有 3 个 redis"
  sep
  kill_pod "all redis" "$(kubectl -n "$NS" get pods -l "app=${INSTANCE}" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}')"
  log "等待恢复 (max 120s)..."
  if wait_stable 120; then
    ok "恢复成功"
    check_rw && ok "读写正常" || fail "读写失败"
    status
  else
    fail "未恢复"
    status
  fi
}

test_sentinel_1() {
  sep
  log "场景 4: 断开 1 个 sentinel"
  sep
  kill_pod "sentinel" "${INSTANCE}-sentinel-0"
  log "等待 (30s)..."
  sleep 30
  if wait_stable 30; then
    ok "集群仍稳定 (sentinel 容错)"
    check_rw && ok "读写正常" || fail "读写失败"
    status
  else
    fail "集群不稳定"
    status
  fi
}

test_sentinel_2() {
  sep
  log "场景 5: 断开 2 个 sentinel (剩 1 个)"
  sep
  kill_pod "2 sentinels" "${INSTANCE}-sentinel-0 ${INSTANCE}-sentinel-1"
  log "等待 (30s)..."
  sleep 30
  local masters
  masters=$(kubectl -n "$NS" get pods -l "app=${INSTANCE}" -o jsonpath='{range .items[*]}{.metadata.labels.redis-role}{" "}{end}' 2>/dev/null | tr ' ' '\n' | grep -c master || echo 0)
  if [ "$masters" = "1" ]; then
    ok "集群仍稳定 (无 failover，保持原 master)"
    check_rw && ok "读写正常" || fail "读写失败"
  else
    fail "集群异常 (masters=${masters})"
  fi
  status
}

test_sentinel_3() {
  sep
  log "场景 6: 断开所有 3 个 sentinel"
  sep
  kill_pod "all sentinels" "${INSTANCE}-sentinel-0 ${INSTANCE}-sentinel-1 ${INSTANCE}-sentinel-2"
  log "等待 (30s)..."
  sleep 30
  local masters
  masters=$(kubectl -n "$NS" get pods -l "app=${INSTANCE}" -o jsonpath='{range .items[*]}{.metadata.labels.redis-role}{" "}{end}' 2>/dev/null | tr ' ' '\n' | grep -c master || echo 0)
  if [ "$masters" = "1" ]; then
    ok "集群仍稳定 (sentinel 全挂不影响运行，只是无法 failover)"
    check_rw && ok "读写正常" || fail "读写失败"
  else
    fail "集群异常 (masters=${masters})"
  fi
  status
}

test_combo_1() {
  sep
  log "场景 7: 同时断开 1 redis + 1 sentinel"
  sep
  kill_pod "1 redis + 1 sentinel" "${INSTANCE}-0 ${INSTANCE}-sentinel-0"
  log "等待恢复 (max 90s)..."
  if wait_stable 90; then
    ok "恢复成功"
    check_rw && ok "读写正常" || fail "读写失败"
    status
  else
    fail "未恢复"
    status
  fi
}

test_combo_2() {
  sep
  log "场景 8: 同时断开 2 redis + 2 sentinel"
  sep
  kill_pod "2 redis + 2 sentinel" "${INSTANCE}-0 ${INSTANCE}-1 ${INSTANCE}-sentinel-0 ${INSTANCE}-sentinel-1"
  log "等待恢复 (max 120s)..."
  if wait_stable 120; then
    ok "恢复成功"
    check_rw && ok "读写正常" || fail "读写失败"
    status
  else
    fail "未恢复"
    status
  fi
}

test_combo_3() {
  sep
  log "场景 9: 同时断开 3 redis + 3 sentinel (全挂)"
  sep
  kill_pod "all" "${INSTANCE}-0 ${INSTANCE}-1 ${INSTANCE}-2 ${INSTANCE}-sentinel-0 ${INSTANCE}-sentinel-1 ${INSTANCE}-sentinel-2"
  log "等待恢复 (max 180s)..."
  if wait_stable 180; then
    ok "恢复成功 (全集群重启自愈)"
    check_rw && ok "读写正常" || fail "读写失败"
    status
  else
    fail "未恢复"
    status
  fi
}

test_rbac() {
  sep
  log "场景 10: RBAC 权限验证 (尝试 patch 其他 pod)"
  sep
  # 部署第二个实例
  helm install rbac-target ./helm/redis-sentinel -n "$NS" \
    --set common.instanceName=rbac-target --set common.auth.password=rbac123 2>&1 | tail -1
  kubectl -n "$NS" wait pod --for=condition=Ready -l "app in (rbac-target,rbac-target-sentinel)" --timeout=120s 2>&1 | tail -1
  sleep 10
  # 尝试用 redis-stab 的 SA 去 patch rbac-target 的 pod
  local token
  token=$(kubectl -n "$NS" get secret -l "app.kubernetes.io/instance=${HELM_NAME}" -o jsonpath='{.items[0].data.token}' 2>/dev/null | base64 -d 2>/dev/null)
  if [ -z "$token" ]; then
    # 找 SA token
    token=$(kubectl -n "$NS" exec "${INSTANCE}-0" -c role-tagger -- cat /var/run/secrets/kubernetes.io/serviceaccount/token 2>/dev/null)
  fi
  log "尝试用 ${INSTANCE} 的 SA patch rbac-target-0 的 label..."
  local result
  result=$(kubectl -n "$NS" auth can-i patch pods --as=system:serviceaccount:${NS}:${INSTANCE}-role-tagger 2>&1)
  if echo "$result" | grep -q "no"; then
    ok "RBAC 收紧: SA 无法 patch 任意 pod (can-i: no)"
  else
    log "can-i 结果: $result"
    # 实际测试 patch rbac-target-0
    result=$(kubectl -n "$NS" exec "${INSTANCE}-0" -c role-tagger -- sh -c '
      TOKEN="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
      CACERT="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
      NS="$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)"
      curl -s -o /tmp/resp -w "%{http_code}" --cacert "$CACERT" -X PATCH \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/merge-patch+json" \
        --data "{\"metadata\":{\"labels\":{\"redis-role\":\"master\"}}}" \
        "https://kubernetes.default.svc/api/v1/namespaces/$NS/pods/rbac-target-0"
    ' 2>&1)
    if echo "$result" | grep -q "403"; then
      ok "RBAC 收紧: patch rbac-target-0 被拒绝 (403 Forbidden)"
    else
      fail "RBAC 漏洞: patch 返回 $result"
    fi
  fi
  # 测试能否 patch 自己的 pod
  log "验证 SA 能 patch 自己的 pod (${INSTANCE}-0)..."
  result=$(kubectl -n "$NS" exec "${INSTANCE}-0" -c role-tagger -- sh -c '
    TOKEN="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
    CACERT="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
    NS="$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)"
    curl -s -o /dev/null -w "%{http_code}" --cacert "$CACERT" -X PATCH \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/merge-patch+json" \
      --data "{\"metadata\":{\"labels\":{\"redis-role\":\"master\"}}}" \
      "https://kubernetes.default.svc/api/v1/namespaces/$NS/pods/'"${INSTANCE}"'-0"
  ' 2>&1)
  if echo "$result" | grep -q "200"; then
    ok "RBAC 正确: patch 自己的 pod 成功 (200)"
  else
    fail "RBAC 错误: patch 自己的 pod 返回 $result"
  fi
  # 测试能否 list pods
  log "验证 SA 无法 list pods..."
  result=$(kubectl -n "$NS" exec "${INSTANCE}-0" -c role-tagger -- sh -c '
    TOKEN="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
    CACERT="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
    NS="$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)"
    curl -s -o /dev/null -w "%{http_code}" --cacert "$CACERT" \
      -H "Authorization: Bearer $TOKEN" \
      "https://kubernetes.default.svc/api/v1/namespaces/$NS/pods"
  ' 2>&1)
  if echo "$result" | grep -q "403"; then
    ok "RBAC 收紧: list pods 被拒绝 (403)"
  else
    fail "RBAC 漏洞: list pods 返回 $result"
  fi
  # 清理
  helm uninstall rbac-target -n "$NS" 2>&1 | tail -1
  kubectl -n "$NS" delete pod -l "app in (rbac-target,rbac-target-sentinel)" --force 2>/dev/null
}

cleanup() {
  sep
  log "清理测试资源"
  sep
  helm uninstall "${HELM_NAME}" -n "$NS" 2>/dev/null
  kubectl -n "$NS" delete pod -l "app in (${INSTANCE},${INSTANCE}-sentinel)" --force 2>/dev/null
  kubectl -n "$NS" delete pvc -l "app.kubernetes.io/instance=${HELM_NAME}" 2>/dev/null
  echo "done"
}

# ── 主流程 ──────────────────────────────────────
case "${1:-all}" in
  setup)   setup ;;
  r1)      test_redis_1 ;;
  r2)      test_redis_2 ;;
  r3)      test_redis_3 ;;
  s1)      test_sentinel_1 ;;
  s2)      test_sentinel_2 ;;
  s3)      test_sentinel_3 ;;
  c1)      test_combo_1 ;;
  c2)      test_combo_2 ;;
  c3)      test_combo_3 ;;
  rbac)    test_rbac ;;
  cleanup) cleanup ;;
  all)
    setup
    test_redis_1
    test_redis_2
    test_redis_3
    test_sentinel_1
    test_sentinel_2
    test_sentinel_3
    test_combo_1
    test_combo_2
    test_combo_3
    test_rbac
    cleanup
    ;;
  *)
    echo "用法: $0 [setup|r1|r2|r3|s1|s2|s3|c1|c2|c3|rbac|cleanup|all]"
    echo "  setup  - 部署测试集群"
    echo "  r1/r2/r3 - 断开 1/2/3 个 redis"
    echo "  s1/s2/s3 - 断开 1/2/3 个 sentinel"
    echo "  c1/c2/c3 - 同时断开 1+1/2+2/3+3 个 redis+sentinel"
    echo "  rbac   - RBAC 权限验证"
    echo "  cleanup - 清理"
    echo "  all    - 运行所有测试"
    ;;
esac
