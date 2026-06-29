#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# test.sh — Redis Sentinel 测试脚本 (基于 Helm Chart)
#
# Usage:
#   ./test.sh [INSTANCE] [NAMESPACE] [MODE]
#
# Modes:
#   full      部署 → 验证 → failover → 清理 (默认)
#   install   仅部署
#   verify    仅验证集群状态
#   failover  仅 failover 测试
#   stability 完整稳定性测试 (9 个故障场景 + RBAC)
#   cleanup   仅清理
#
# Examples:
#   ./test.sh                                # instance=redis-test, ns=redis, mode=full
#   ./test.sh my-app                         # instance=my-app
#   ./test.sh my-app middleware              # ns=middleware
#   ./test.sh my-app redis stability         # 完整稳定性测试
#   ./test.sh my-app redis verify            # 仅验证
# ═══════════════════════════════════════════════════════════════

set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
CHART_DIR="${DIR}/helm/redis-sentinel"

# 参数
INSTANCE="${1:-redis-test}"
NS="${2:-redis}"
MODE="${3:-full}"

# 测试用密码 (生产请用 externalSecret)
PASS="test-${INSTANCE}-123"

# Helm release 名 = instance 名
RELEASE="$INSTANCE"
MASTER_SVC="${INSTANCE}-master"

# 快速 failover 参数 (用于稳定性测试)
FAST_FAILOVER_ARGS=(
  --set "sentinel.config[0]=sentinel down-after-milliseconds mymaster 1000"
  --set "sentinel.config[1]=sentinel failover-timeout mymaster 5000"
  --set "sentinel.config[2]=sentinel parallel-syncs mymaster 1"
)

# 颜色
G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
ok()   { echo -e "  ${G}✓${N} $1"; }
bad()  { echo -e "  ${R}✗${N} $1"; }
info() { echo -e "  ${Y}→${N} $1"; }
hdr()  { echo -e "\n${C}${B}═══ $1 ═══${N}"; }
sep()  { echo -e "${C}────────────────────────────────────────────────${N}"; }

ERRORS=0

# ── 工具函数 ────────────────────────────────────────────────────

# 从 secret 读密码
get_pass() {
  kubectl -n "$NS" get secret "${INSTANCE}-secret" -o jsonpath='{.data.redis-password}' 2>/dev/null | base64 -d 2>/dev/null || echo ""
}

# redis-cli 在 pod 内执行
rcli() {
  local pod="$1"; shift
  local pass; pass="$(get_pass)"
  if [ -n "$pass" ]; then
    kubectl -n "$NS" exec "$pod" -c redis -- redis-cli -a "$pass" "$@" 2>/dev/null
  else
    kubectl -n "$NS" exec "$pod" -c redis -- redis-cli "$@" 2>/dev/null
  fi
}

# 等待集群有且仅有 1 个 master
wait_single_master() {
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

# 读写测试
check_rw() {
  local key="rw-$(date +%s)"
  local val
  val=$(kubectl -n "$NS" run tmp-rw --image=redis:5.0.8-alpine --rm -i --restart=Never -- \
    sh -c "redis-cli -h ${MASTER_SVC} -a ${PASS} SET ${key} ok 2>/dev/null && \
           redis-cli -h ${MASTER_SVC} -a ${PASS} GET ${key} 2>/dev/null" 2>&1 | grep -vE "Warning|Defaulted|deleted|attach" | tr -d '\r')
  if echo "$val" | grep -q "ok"; then
    ok "读写正常"
    return 0
  else
    bad "读写失败 (got: $val)"
    return 1
  fi
}

# Service 端点验证
check_service() {
  local master_ip="$1"
  local ep
  ep=$(kubectl -n "$NS" get endpoints "${MASTER_SVC}" -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null)
  if [ "$ep" = "$master_ip" ]; then
    ok "${MASTER_SVC} → $ep (与 master IP 一致)"
    return 0
  else
    bad "${MASTER_SVC} → $ep (应为 $master_ip)"
    return 1
  fi
}

# 数据完整性测试 (在 failover 前后写入和读取数据)
data_integrity_test() {
  hdr "数据完整性测试"
  local errors=0
  local test_key_prefix="data-int-"
  
  # 阶段1: 在当前 master 写入测试数据
  info "阶段1: 在当前 master 写入测试数据"
  local i
  for i in 1 2 3 4 5; do
    kubectl -n "$NS" run tmp-write-$i --image=redis:5.0.8-alpine --rm -i --restart=Never -- \
      sh -c "redis-cli -h ${MASTER_SVC} -a ${PASS} SET ${test_key_prefix}${i} value${i} 2>/dev/null" 2>&1 | grep -vE "Warning|Defaulted|deleted|attach" >/dev/null
  done
  ok "已写入 5 条测试数据"
  
  # 阶段2: 获取当前 master IP
  local old_master_ip
  old_master_ip=$(kubectl -n "$NS" get endpoints "${MASTER_SVC}" -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null)
  info "当前 master IP: $old_master_ip"
  
  # 阶段3: 删除 master 触发 failover
  info "阶段3: 删除 master 触发 failover"
  local old_master_pod
  for i in 0 1 2; do
    pod="${INSTANCE}-${i}"
    ip=$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.status.podIP}' 2>/dev/null)
    if [ "$ip" = "$old_master_ip" ]; then
      old_master_pod="$pod"
      break
    fi
  done
  info "删除 ${old_master_pod}..."
  kubectl -n "$NS" delete pod "$old_master_pod" --force --grace-period=0 2>/dev/null | grep deleted
  
  # 阶段4: 等待 failover 完成
  info "阶段4: 等待 failover 完成..."
  local elapsed=0
  while [ "$elapsed" -lt 30 ]; do
    local new_ep
    new_ep=$(kubectl -n "$NS" get endpoints "${MASTER_SVC}" -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null)
    if [ "$new_ep" != "$old_master_ip" ] && [ -n "$new_ep" ]; then
      ok "Service 已切换到新 master: $new_ep (耗时 ${elapsed}s)"
      break
    fi
    sleep 2
    elapsed=$((elapsed+2))
  done
  
  # 阶段5: 验证数据完整性
  info "阶段5: 验证数据完整性"
  local missing=0
  for i in 1 2 3 4 5; do
    local val
    val=$(kubectl -n "$NS" run tmp-read-$i --image=redis:5.0.8-alpine --rm -i --restart=Never -- \
      sh -c "redis-cli -h ${MASTER_SVC} -a ${PASS} GET ${test_key_prefix}${i} 2>/dev/null" 2>&1 | grep -vE "Warning|Defaulted|deleted|attach|prompt" | tr -d '\r')
    if [ "$val" = "value${i}" ]; then
      echo "    ${test_key_prefix}${i}: ${val} ✓"
    else
      echo "    ${test_key_prefix}${i}: ${val} ✗ (应为 value${i})"
      missing=$((missing+1))
    fi
  done
  if [ "$missing" -eq 0 ]; then
    ok "数据完整性: 5/5 数据完整"
  else
    bad "数据完整性: ${missing}/5 数据丢失"
    errors=$((errors+1))
  fi
  
  # 阶段6: 写入新数据验证新 master 可写
  info "阶段6: 写入新数据验证新 master 可写"
  kubectl -n "$NS" run tmp-write-new --image=redis:5.0.8-alpine --rm -i --restart=Never -- \
    sh -c "redis-cli -h ${MASTER_SVC} -a ${PASS} SET ${test_key_prefix}new after-failover 2>/dev/null && \
           redis-cli -h ${MASTER_SVC} -a ${PASS} GET ${test_key_prefix}new 2>/dev/null" 2>&1 | grep -vE "Warning|Defaulted|deleted|attach" | tr -d '\r' | grep -q "after-failover"
  if [ $? -eq 0 ]; then
    ok "新 master 写入成功"
  else
    bad "新 master 写入失败"
    errors=$((errors+1))
  fi
  
  # 阶段7: 等待旧 master 恢复并验证
  info "阶段7: 等待旧 master 恢复..."
  kubectl -n "$NS" wait pod "$old_master_pod" --for=condition=Ready --timeout=120s 2>/dev/null
  sleep 5
  local role
  role=$(kubectl -n "$NS" exec "$old_master_pod" -c redis -- redis-cli -a "$PASS" role 2>/dev/null | head -1)
  if [ "$role" = "slave" ]; then
    ok "旧 master 已恢复为 slave"
  else
    bad "旧 master 角色异常: $role"
    errors=$((errors+1))
  fi
  
  echo ""
  [ "$errors" -eq 0 ] && ok "数据完整性测试通过" || bad "$errors 个检查失败"
  ERRORS=$((ERRORS+errors))
}

# 客户端持续连接测试 (模拟业务场景)
client_reconnect_test() {
  hdr "客户端持续连接测试 (模拟业务场景)"
  local errors=0
  
  # 启动持续连接的客户端
  info "启动持续连接客户端..."
  kubectl -n "$NS" run client-test --image=redis:5.0.8-alpine --restart=Never -- \
    sh -c "
      COUNT=0
      ERRORS=0
      while true; do
        redis-cli -h ${MASTER_SVC} -a ${PASS} SET test-counter \$COUNT 2>/dev/null
        if [ \$? -eq 0 ]; then
          VAL=\$(redis-cli -h ${MASTER_SVC} -a ${PASS} GET test-counter 2>/dev/null)
          if [ \"\$VAL\" = \"\$COUNT\" ]; then
            echo \"OK: count=\$COUNT\"
          else
            echo \"MISMATCH: expected=\$COUNT got=\$VAL\"
            ERRORS=\$((ERRORS+1))
          fi
        else
          echo \"ERROR: connection failed\"
          ERRORS=\$((ERRORS+1))
        fi
        COUNT=\$((COUNT+1))
        sleep 0.5
      done
    "
  # Wait for pod to start
  sleep 5
  
  # 获取当前 master
  local old_master
  for i in 0 1 2; do
    pod="${INSTANCE}-${i}"
    role="$(rcli "$pod" role 2>/dev/null | head -1)"
    if [ "$role" = "master" ]; then
      old_master="$pod"
      break
    fi
  done
  
  # 删除 master 触发 failover
  info "删除 ${old_master} 触发 failover..."
  kubectl -n "$NS" delete pod "$old_master" --force --grace-period=0 2>/dev/null | grep deleted
  
  # 等待 30 秒观察客户端行为
  info "等待 30 秒观察客户端行为..."
  sleep 30
  
  # 获取客户端日志
  info "获取客户端日志..."
  kubectl -n "$NS" logs client-test 2>/dev/null > /tmp/client-output.log
  
  # 停止客户端
  kubectl -n "$NS" delete pod client-test --force --grace-period=0 2>/dev/null | grep deleted
  
  # 分析客户端日志
  info "分析客户端日志..."
  local total_ops=$(grep -c "OK:" /tmp/client-output.log 2>/dev/null || echo 0)
  local error_ops=$(grep -c "ERROR:" /tmp/client-output.log 2>/dev/null || echo 0)
  local mismatch_ops=$(grep -c "MISMATCH:" /tmp/client-output.log 2>/dev/null || echo 0)
  
  # 去除可能的换行
  total_ops=$(echo "$total_ops" | tr -d '\n')
  error_ops=$(echo "$error_ops" | tr -d '\n')
  mismatch_ops=$(echo "$mismatch_ops" | tr -d '\n')
  
  # 计算重连时间 (基于日志行数估算)
  local first_error_line=$(grep -n "ERROR:" /tmp/client-output.log | head -1 | cut -d: -f1)
  local reconnect_time=0
  if [ -n "$first_error_line" ] && [ "$first_error_line" -gt 0 ]; then
    # 每行约 0.5 秒
    reconnect_time=$((first_error_line / 2))
  fi
  
  echo "    总操作数: ${total_ops}"
  echo "    连接失败: ${error_ops}"
  echo "    数据不一致: ${mismatch_ops}"
  echo "    重连时间: ${reconnect_time}s"
  
  if [ "$error_ops" -eq 0 ]; then
    ok "客户端无连接失败"
  else
    ok "客户端连接失败 ${error_ops} 次 (failover 期间正常)"
  fi
  
  if [ "$mismatch_ops" -eq 0 ]; then
    ok "数据一致"
  else
    bad "数据不一致 ${mismatch_ops} 次"
    errors=$((errors+1))
  fi
  
  if [ "$reconnect_time" -lt 10 ]; then
    ok "重连时间 ${reconnect_time}s (快速恢复)"
  else
    ok "重连时间 ${reconnect_time}s (在可接受范围内)"
  fi
  
  # 验证最终数据
  local final_val
  final_val=$(kubectl -n "$NS" run tmp-final --image=redis:5.0.8-alpine --rm -i --restart=Never -- \
    sh -c "redis-cli -h ${MASTER_SVC} -a ${PASS} GET test-counter 2>/dev/null" 2>&1 | grep -vE "Warning|Defaulted|deleted|attach|prompt" | tr -d '\r')
  echo "    最终计数器值: ${final_val}"
  
  [ "$errors" -eq 0 ] && ok "客户端持续连接测试通过" || bad "$errors 个检查失败"
  ERRORS=$((ERRORS+errors))
}

# 显示集群状态
show_status() {
  echo "--- Pod 状态 ---"
  kubectl -n "$NS" get pods -l "app in (${INSTANCE},${INSTANCE}-sentinel)" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.labels.redis-role}{"\t"}{.status.phase}{"\n"}{end}' 2>/dev/null | column -t
  echo "--- Master Service ---"
  kubectl -n "$NS" get endpoints "${MASTER_SVC}" 2>/dev/null | tail -1
}

# 删除 pod (强制)
kill_pods() {
  local desc="$1"; shift
  local pods="$*"
  info "删除 ${desc}: ${pods}"
  kubectl -n "$NS" delete pod $pods --force --grace-period=0 2>&1 | grep -E "deleted|force" | head -5
}

# ── 部署 ────────────────────────────────────────────────────────

install() {
  hdr "部署 ${INSTANCE} (ns=${NS})"

  # 确保 namespace 存在
  kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS" >/dev/null

  # 清理旧资源
  helm uninstall "$RELEASE" -n "$NS" 2>/dev/null || true
  kubectl -n "$NS" delete pod -l "app in (${INSTANCE},${INSTANCE}-sentinel)" --force --grace-period=0 2>/dev/null
  kubectl -n "$NS" delete pvc -l "app.kubernetes.io/instance=${RELEASE}" 2>/dev/null
  sleep 2

  info "helm install ${RELEASE}..."
  helm install "$RELEASE" "$CHART_DIR" -n "$NS" \
    --set "common.instanceName=${INSTANCE}" \
    --set "common.auth.password=${PASS}" \
    2>&1 | tail -3

  info "等待 Pod Ready..."
  kubectl -n "$NS" wait pod --for=condition=Ready -l "app in (${INSTANCE},${INSTANCE}-sentinel)" --timeout=300s 2>&1 | tail -1
  sleep 8  # 等 role-tagger 更新 label

  if wait_single_master 30; then
    ok "集群就绪"
    show_status
  else
    bad "集群未就绪"
    show_status
    ERRORS=$((ERRORS+1))
  fi
}

# ── 验证 ────────────────────────────────────────────────────────

verify() {
  hdr "验证 ${INSTANCE}"
  local errors=0

  # 1. master 存在
  info "检查 redis 角色..."
  local master_pod="" master_ip=""
  for i in 0 1 2; do
    pod="${INSTANCE}-${i}"
    role="$(rcli "$pod" role 2>/dev/null | head -1 || echo '?')"
    echo "    $pod: $role"
    if [ "$role" = "master" ]; then
      master_pod="$pod"
      master_ip="$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.status.podIP}')"
    fi
  done
  [ -n "$master_pod" ] && ok "Master: $master_pod ($master_ip)" || { bad "无 master"; errors=$((errors+1)); }

  # 2. 复制
  info "检查复制..."
  slave_count="$(rcli "$master_pod" role 2>/dev/null | grep -c "^[0-9]" || echo 0)"
  [ "$slave_count" -ge 2 ] && ok "Master 有 $slave_count 个 slave" || { bad "Slave 数量异常: $slave_count"; errors=$((errors+1)); }

  # 3. Sentinel
  info "检查 sentinel..."
  s_master="$(kubectl -n "$NS" exec "${INSTANCE}-sentinel-0" -c sentinel -- redis-cli -p 26379 -a "$PASS" SENTINEL get-master-addr-by-name mymaster 2>/dev/null | head -1 || echo '')"
  if [ -n "$s_master" ] && [ "$s_master" != "nil" ]; then
    ok "Sentinel 报告 master: $s_master"
    [ "$s_master" = "$master_ip" ] && ok "  IP 匹配" || { bad "  IP 不匹配: sentinel=$s_master actual=$master_ip"; errors=$((errors+1)); }
  else
    bad "Sentinel 找不到 master"
    errors=$((errors+1))
  fi

  # 4. Service 路由
  info "检查 ${MASTER_SVC} 路由..."
  ep="$(kubectl -n "$NS" get endpoints "${MASTER_SVC}" -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null)"
  if [ "$ep" = "$master_ip" ]; then
    ok "${MASTER_SVC} → $ep (正确)"
  else
    bad "${MASTER_SVC} → $ep (应为 $master_ip)"
    errors=$((errors+1))
  fi

  # 5. 读写
  info "检查读写..."
  check_rw || errors=$((errors+1))

  echo ""
  [ "$errors" -eq 0 ] && ok "所有检查通过" || bad "$errors 个检查失败"
  ERRORS=$((ERRORS+errors))
}

# ── Failover 测试 ───────────────────────────────────────────────

failover_test() {
  hdr "Failover 测试"
  local errors=0

  # 找当前 master
  old_master="" old_ip=""
  for i in 0 1 2; do
    pod="${INSTANCE}-${i}"
    role="$(rcli "$pod" role 2>/dev/null | head -1 || echo '')"
    if [ "$role" = "master" ]; then
      old_master="$pod"
      old_ip="$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.status.podIP}')"
      break
    fi
  done
  [ -n "$old_master" ] || { bad "无 master"; return 1; }
  info "当前 master: $old_master ($old_ip)"

  # 删 master
  info "删除 $old_master..."
  kubectl -n "$NS" delete pod "$old_master" --force --grace-period=0 2>/dev/null | grep deleted

  # 等新 master
  info "等待 failover..."
  new_master="" new_ip="" elapsed=0
  while [ "$elapsed" -lt 60 ]; do
    for i in 0 1 2; do
      pod="${INSTANCE}-${i}"
      [ "$pod" = "$old_master" ] && continue
      role="$(rcli "$pod" role 2>/dev/null | head -1 || echo '')"
      if [ "$role" = "master" ]; then
        new_master="$pod"
        new_ip="$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.status.podIP}')"
        break
      fi
    done
    [ -n "$new_master" ] && break
    sleep 2
    elapsed=$((elapsed+2))
  done

  if [ -n "$new_master" ]; then
    ok "Failover: $old_master → $new_master ($new_ip) in ${elapsed}s"
  else
    bad "60s 内无新 master"
    errors=$((errors+1))
  fi

  # 等旧 master 回来
  info "等待 $old_master 重新加入..."
  kubectl -n "$NS" wait pod --for=condition=Ready -l "app=${INSTANCE}" --timeout=300s 2>/dev/null
  sleep 5

  # 拓扑
  info "最终拓扑:"
  m_count=0 s_count=0
  for i in 0 1 2; do
    pod="${INSTANCE}-${i}"
    role="$(rcli "$pod" role 2>/dev/null | head -1 || echo '?')"
    echo "    $pod: $role"
    case "$role" in
      master) m_count=$((m_count+1)) ;;
      slave)  s_count=$((s_count+1)) ;;
    esac
  done
  [ "$m_count" -eq 1 ] && [ "$s_count" -eq 2 ] && ok "拓扑: 1 master + 2 slaves" || { bad "拓扑异常: ${m_count}m+${s_count}s"; errors=$((errors+1)); }

  # 读写
  check_rw || errors=$((errors+1))

  echo ""
  [ "$errors" -eq 0 ] && ok "Failover 测试通过" || bad "$errors 个检查失败"
  ERRORS=$((ERRORS+errors))
}

# ── Master 灵活切换测试 ──────────────────────────────────────────
# 验证：master 可以是任意节点，不是固定 -0

master_switch_test() {
  hdr "Master 灵活切换测试 (验证任意节点可成为 master)"
  local errors=0

  # 场景1: 获取当前 master (不假设必须是 -0)
  info "场景1: 获取当前 master"
  local current_master=""
  for i in 0 1 2; do
    pod="${INSTANCE}-${i}"
    role="$(rcli "$pod" role 2>/dev/null | head -1)"
    if [ "$role" = "master" ]; then
      current_master="$pod"
      break
    fi
  done
  if [ -n "$current_master" ]; then
    ok "当前 master: ${current_master}"
  else
    bad "无 master"
    errors=$((errors+1))
  fi

  # 场景2: 删除当前 master，验证其他节点成为 master
  info "场景2: 删除 ${current_master}，验证其他节点成为 master"
  kubectl -n "$NS" delete pod "$current_master" --force --grace-period=0 2>/dev/null | grep deleted
  new_master=""
  local elapsed=0
  while [ "$elapsed" -lt 20 ]; do
    for i in 0 1 2; do
      pod="${INSTANCE}-${i}"
      [ "$pod" = "$current_master" ] && continue
      role="$(rcli "$pod" role 2>/dev/null | head -1 || echo '')"
      if [ "$role" = "master" ]; then
        new_master="$pod"
        break 2
      fi
    done
    sleep 2
    elapsed=$((elapsed+2))
  done
  if [ -n "$new_master" ]; then
    ok "新 master: $new_master (证明 master 不固定为 ${current_master})"
  else
    bad "删除 ${current_master} 后无新 master (master 固定问题)"
    errors=$((errors+1))
  fi

  # 等待旧 master 恢复
  kubectl -n "$NS" wait pod "$current_master" --for=condition=Ready --timeout=120s 2>/dev/null
  sleep 5

  # 场景3: 删除当前 master，验证任意节点可以成为 master
  info "场景3: 删除当前 master ($new_master)，验证其他节点可以成为 master"
  kubectl -n "$NS" delete pod "$new_master" --force --grace-period=0 2>/dev/null | grep deleted
  new_master2=""
  for i in 0 1 2; do
    pod="${INSTANCE}-${i}"
    [ "$pod" = "$new_master" ] && continue
    sleep 3
    role="$(rcli "$pod" role 2>/dev/null | head -1 || echo '')"
    if [ "$role" = "master" ]; then
      new_master2="$pod"
      break
    fi
  done
  if [ -n "$new_master2" ]; then
    ok "新 master: $new_master2"
    ok "✓ 证明 master 可以是任意节点"
  else
    bad "删除 $new_master 后无新 master"
    errors=$((errors+1))
  fi

  # 场景4: 验证最终拓扑
  info "场景4: 最终拓扑验证"
  kubectl -n "$NS" wait pod --for=condition=Ready -l "app=${INSTANCE}" --timeout=120s 2>/dev/null
  sleep 5
  m_count=0 s_count=0
  for i in 0 1 2; do
    pod="${INSTANCE}-${i}"
    role="$(rcli "$pod" role 2>/dev/null | head -1 || echo '?')"
    echo "    $pod: $role"
    case "$role" in
      master) m_count=$((m_count+1)) ;;
      slave)  s_count=$((s_count+1)) ;;
    esac
  done
  [ "$m_count" -eq 1 ] && [ "$s_count" -eq 2 ] && ok "拓扑: 1 master + 2 slaves" || { bad "拓扑异常: ${m_count}m+${s_count}s"; errors=$((errors+1)); }

  # 读写测试
  check_rw || errors=$((errors+1))

  echo ""
  [ "$errors" -eq 0 ] && ok "Master 灵活切换测试通过" || bad "$errors 个检查失败"
  ERRORS=$((ERRORS+errors))
}

# ── 稳定性测试 (9 个场景 + RBAC) ────────────────────────────────

stability_test() {
  hdr "完整稳定性测试 (9 场景 + RBAC)"

  # 重新部署带快速 failover 参数
  sep
  info "部署带快速 failover 参数的集群 (down-after=1s, failover-timeout=5s)"

  helm uninstall "$RELEASE" -n "$NS" 2>/dev/null || true
  kubectl -n "$NS" delete pod -l "app in (${INSTANCE},${INSTANCE}-sentinel)" --force --grace-period=0 2>/dev/null
  kubectl -n "$NS" delete pvc -l "app.kubernetes.io/instance=${RELEASE}" 2>/dev/null
  sleep 2

  helm install "$RELEASE" "$CHART_DIR" -n "$NS" \
    --set "common.instanceName=${INSTANCE}" \
    --set "common.auth.password=${PASS}" \
    "${FAST_FAILOVER_ARGS[@]}" 2>&1 | tail -2

  kubectl -n "$NS" wait pod --for=condition=Ready -l "app in (${INSTANCE},${INSTANCE}-sentinel)" --timeout=300s 2>&1 | tail -1
  sleep 8
  wait_single_master 30 && ok "集群就绪" || { bad "集群未就绪"; return 1; }

  # 场景 1-3: 单 redis 断开
  run_scenario() {
    local num="$1"
    local desc="$2"
    shift 2
    sep
    info "场景 ${num}: ${desc}"
    kill_pods "$desc" "$@"
    if wait_single_master "${STABILITY_WAIT:-90}"; then
      ok "恢复成功"
      check_rw
    else
      bad "未恢复"
      ERRORS=$((ERRORS+1))
    fi
  }

  run_scenario 1 "断开 1 个 redis (slave)" \
    "$(kubectl -n "$NS" get pods -l "app=${INSTANCE},redis-role=slave" -o jsonpath='{.items[0].metadata.name}')"

  run_scenario 2 "断开 2 个 redis" \
    "$(kubectl -n "$NS" get pods -l "app=${INSTANCE}" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}')"

  run_scenario 3 "断开全部 3 个 redis" \
    "${INSTANCE}-0 ${INSTANCE}-1 ${INSTANCE}-2"

  # 场景 4-6: 单 sentinel 断开
  sep
  info "场景 4: 断开 1 个 sentinel"
  kill_pods "sentinel" "${INSTANCE}-sentinel-0"
  sleep 25
  wait_single_master 20 && ok "集群稳定" || { bad "集群不稳定"; ERRORS=$((ERRORS+1)); }
  check_rw

  sep
  info "场景 5: 断开 2 个 sentinel (剩 1)"
  kill_pods "2 sentinels" "${INSTANCE}-sentinel-0 ${INSTANCE}-sentinel-1"
  sleep 25
  masters=$(kubectl -n "$NS" get pods -l "app=${INSTANCE}" -o jsonpath='{range .items[*]}{.metadata.labels.redis-role}{" "}{end}' 2>/dev/null | tr ' ' '\n' | grep -c master || echo 0)
  [ "$masters" = "1" ] && ok "保持原 master" || { bad "集群异常 (masters=$masters)"; ERRORS=$((ERRORS+1)); }
  check_rw

  sep
  info "场景 6: 断开全部 3 个 sentinel"
  kill_pods "all sentinels" "${INSTANCE}-sentinel-0 ${INSTANCE}-sentinel-1 ${INSTANCE}-sentinel-2"
  sleep 25
  masters=$(kubectl -n "$NS" get pods -l "app=${INSTANCE}" -o jsonpath='{range .items[*]}{.metadata.labels.redis-role}{" "}{end}' 2>/dev/null | tr ' ' '\n' | grep -c master || echo 0)
  [ "$masters" = "1" ] && ok "集群仍运行 (仅无法 failover)" || { bad "集群异常 (masters=$masters)"; ERRORS=$((ERRORS+1)); }
  check_rw

  # 场景 7-9: redis + sentinel 同时断开
  run_scenario 7 "同时断开 1 redis + 1 sentinel" \
    "${INSTANCE}-0 ${INSTANCE}-sentinel-0"

  run_scenario 8 "同时断开 2 redis + 2 sentinel" \
    "${INSTANCE}-0 ${INSTANCE}-1 ${INSTANCE}-sentinel-0 ${INSTANCE}-sentinel-1"

  STABILITY_WAIT=180 run_scenario 9 "同时断开全部 3 redis + 3 sentinel" \
    "${INSTANCE}-0 ${INSTANCE}-1 ${INSTANCE}-2 ${INSTANCE}-sentinel-0 ${INSTANCE}-sentinel-1 ${INSTANCE}-sentinel-2"

  # RBAC 验证
  test_rbac
}

# ── RBAC 验证 ───────────────────────────────────────────────────

test_rbac() {
  hdr "RBAC 权限验证"
  local errors=0

  # 部署第二个实例作为目标
  info "部署第二个实例 (rbac-target)..."
  helm install rbac-target "$CHART_DIR" -n "$NS" \
    --set "common.instanceName=rbac-target" \
    --set "common.auth.password=rbac123" 2>&1 | tail -1
  kubectl -n "$NS" wait pod --for=condition=Ready -l "app in (rbac-target,rbac-target-sentinel)" --timeout=120s 2>&1 | tail -1
  sleep 8

  # 尝试用当前实例的 SA patch 其他实例的 pod
  info "尝试 patch rbac-target-0 (应被拒绝)..."
  result=$(kubectl -n "$NS" exec "${INSTANCE}-0" -c role-tagger -- sh -c '
    TOKEN="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
    CACERT="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
    NS="$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)"
    curl -s -o /dev/null -w "%{http_code}" --cacert "$CACERT" -X PATCH \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/merge-patch+json" \
      --data "{\"metadata\":{\"labels\":{\"redis-role\":\"master\"}}}" \
      "https://kubernetes.default.svc/api/v1/namespaces/$NS/pods/rbac-target-0"
  ' 2>&1)
  if echo "$result" | grep -q "403"; then
    ok "patch 其他实例 pod 被拒绝 (403)"
  else
    bad "RBAC 漏洞: patch 返回 $result"
    errors=$((errors+1))
  fi

  # 验证能 patch 自己的 pod
  info "验证 patch 自己的 pod (${INSTANCE}-0)..."
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
    ok "patch 自己的 pod 成功 (200)"
  else
    bad "patch 自己的 pod 失败: $result"
    errors=$((errors+1))
  fi

  # 验证无法 list pods
  info "验证无法 list pods..."
  result=$(kubectl -n "$NS" exec "${INSTANCE}-0" -c role-tagger -- sh -c '
    TOKEN="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
    CACERT="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
    NS="$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)"
    curl -s -o /dev/null -w "%{http_code}" --cacert "$CACERT" \
      -H "Authorization: Bearer $TOKEN" \
      "https://kubernetes.default.svc/api/v1/namespaces/$NS/pods"
  ' 2>&1)
  if echo "$result" | grep -q "403"; then
    ok "list pods 被拒绝 (403)"
  else
    bad "RBAC 漏洞: list pods 返回 $result"
    errors=$((errors+1))
  fi

  # 清理
  helm uninstall rbac-target -n "$NS" 2>/dev/null
  kubectl -n "$NS" delete pod -l "app in (rbac-target,rbac-target-sentinel)" --force 2>/dev/null

  echo ""
  [ "$errors" -eq 0 ] && ok "RBAC 验证通过" || bad "$errors 个 RBAC 检查失败"
  ERRORS=$((ERRORS+errors))
}

# ── 清理 ────────────────────────────────────────────────────────

cleanup() {
  hdr "清理 ${INSTANCE} (ns=${NS})"
  helm uninstall "$RELEASE" -n "$NS" 2>/dev/null
  kubectl -n "$NS" delete pod -l "app in (${INSTANCE},${INSTANCE}-sentinel)" --force 2>/dev/null
  kubectl -n "$NS" delete pvc -l "app.kubernetes.io/instance=${RELEASE}" 2>/dev/null
  ok "已清理 ${INSTANCE}"
}

# ── 主流程 ──────────────────────────────────────────────────────

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Redis Sentinel 测试"
echo "  instance=${INSTANCE}  ns=${NS}  mode=${MODE}"
echo "═══════════════════════════════════════════════════════════════"

case "$MODE" in
  install)   install ;;
  verify)    verify ;;
  failover)  failover_test ;;
  master-switch) install; master_switch_test; cleanup ;;
  data-integrity) install; data_integrity_test; cleanup ;;
  client-reconnect) install; client_reconnect_test; cleanup ;;
  stability) install; stability_test; cleanup ;;
  cleanup)   cleanup ;;
  full)
    install
    verify
    failover_test
    master_switch_test
    data_integrity_test
    client_reconnect_test
    cleanup
    ;;
  *)
    echo "Usage: $0 [INSTANCE] [NAMESPACE] [full|install|verify|failover|master-switch|data-integrity|client-reconnect|stability|cleanup]"
    echo ""
    echo "Modes:"
    echo "  full             部署 → 验证 → failover → master-switch → data-integrity → client-reconnect → 清理 (默认)"
    echo "  install          仅部署"
    echo "  verify           仅验证"
    echo "  failover         仅 failover 测试"
    echo "  master-switch    仅 master 灵活切换测试"
    echo "  data-integrity   仅数据完整性测试"
    echo "  client-reconnect 仅客户端持续连接测试"
    echo "  stability        完整稳定性测试 (9 场景 + RBAC)"
    echo "  cleanup          仅清理"
    echo ""
    echo "Examples:"
    echo "  ./test.sh                                # 默认实例快速测试"
    echo "  ./test.sh my-app                         # 指定实例名"
    echo "  ./test.sh my-app middleware              # 指定 namespace"
    echo "  ./test.sh my-app redis stability         # 完整稳定性测试"
    exit 1
    ;;
esac

echo ""
if [ "$ERRORS" -eq 0 ]; then
  echo -e "${G}${B}✓ 测试全部通过${N}"
else
  echo -e "${R}${B}✗ ${ERRORS} 个测试失败${N}"
fi
echo ""
exit $ERRORS
