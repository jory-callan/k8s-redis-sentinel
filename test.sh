#!/bin/bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════
# test.sh — Redis Sentinel robustness test suite
#
# Usage:
#   ./test.sh [INSTANCE_NAME] [NAMESPACE] [MODE]
#
# Modes:
#   full     Deploy → verify → failover → verify (default)
#   install  Deploy only
#   verify   Verify cluster state
#   failover Failover test only
#   cleanup  Cleanup all resources
#
# Examples:
#   ./test.sh                              # full test, instance=redis, ns=redis
#   ./test.sh redis-saas-log               # full test, instance=redis-saas-log
#   ./test.sh redis-saas-log middleware verify
# ═══════════════════════════════════════════════════════════════

DIR="$(cd "$(dirname "$0")" && pwd)"

# Parse args: instance namespace mode
INSTANCE="${1:-redis}"
NS="${2:-redis}"
MODE="${3:-full}"

# Colors
G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; N='\033[0m'
ok()   { echo -e "  ${G}✓${N} $1"; }
bad()  { echo -e "  ${R}✗${N} $1"; }
info() { echo -e "  ${Y}→${N} $1"; }

# Get password from secret (or empty if no secret)
get_pass() {
  kubectl -n "$NS" get secret "$INSTANCE-secret" -o jsonpath='{.data.redis-password}' 2>/dev/null | base64 -d 2>/dev/null || echo ""
}

# redis-cli with auth — runs inside a redis pod
rcli() {
  local pod="$1"; shift
  local pass; pass="$(get_pass)"
  if [ -n "$pass" ]; then
    kubectl -n "$NS" exec "$pod" -- redis-cli -a "$pass" "$@" 2>/dev/null
  else
    kubectl -n "$NS" exec "$pod" -- redis-cli "$@" 2>/dev/null
  fi
}

# ── Install ────────────────────────────────────────────────────
install() {
  echo ""
  echo "╔══════════════════════════════════════════════╗"
  echo "║  Phase 1: Deploy ($INSTANCE in $NS)           ║"
  echo "╚══════════════════════════════════════════════╝"
  echo ""

  for f in 00-namespace 01-secret 02-configmap-redis 03-configmap-sentinel \
           04-services 05-statefulset-redis 06-statefulset-sentinel 07-pdb; do
    info "apply $f.yaml"
    sed -e "s/__INSTANCE_NAME__/$INSTANCE/g" -e "s/__NAMESPACE__/$NS/g" "$DIR/$f.yaml" | kubectl apply -f -
  done

  echo ""
  info "Waiting for redis pods (300s)..."
  # Wait for StatefulSet controller to create pods first (race condition)
  i=0
  while [ "$i" -lt 30 ]; do
    c="$(kubectl -n "$NS" get pod -l "app=$INSTANCE" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    [ "$c" -ge 3 ] && break
    i=$((i+1)); sleep 2
  done
  kubectl -n "$NS" wait pod --for=condition=Ready -l "app=$INSTANCE" --timeout=300s && ok "redis pods ready" || bad "redis pods timeout"

  info "Waiting for sentinel pods (200s)..."
  i=0
  while [ "$i" -lt 30 ]; do
    c="$(kubectl -n "$NS" get pod -l "app=$INSTANCE-sentinel" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    [ "$c" -ge 3 ] && break
    i=$((i+1)); sleep 2
  done
  kubectl -n "$NS" wait pod --for=condition=Ready -l "app=$INSTANCE-sentinel" --timeout=200s && ok "sentinel pods ready" || bad "sentinel pods timeout"
  echo ""
}

# ── Verify ────────────────────────────────────────────────────
verify() {
  echo ""
  echo "╔══════════════════════════════════════════════╗"
  echo "║  Phase 2: Verify cluster state               ║"
  echo "╚══════════════════════════════════════════════╝"
  echo ""

  local errors=0

  # 2a. Find master
  info "Checking redis roles..."
  local master_pod="" master_ip=""
  for i in 0 1 2; do
    pod="${INSTANCE}-${i}"
    local role; role="$(rcli "$pod" role | head -1 || echo '?')"
    echo "    $pod: $role"
    if [ "$role" = "master" ]; then
      master_pod="$pod"
      master_ip="$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.status.podIP}')"
    fi
  done
  [ -n "$master_pod" ] && ok "Master: $master_pod ($master_ip)" || { bad "No master found"; errors=$((errors+1)); }

  # 2b. Replication
  info "Checking replication..."
  local slave_count; slave_count="$(rcli "$master_pod" role | grep -c "^[0-9]" || echo 0)"
  if [ "$slave_count" -ge 2 ]; then
    ok "Master has $slave_count slaves"
  else
    bad "Expected 2 slaves, got $slave_count"
    errors=$((errors+1))
  fi

  # 2c. Sentinel awareness
  info "Checking sentinel..."
  local s_master; s_master="$(rcli "${INSTANCE}-sentinel-0" -p 26379 SENTINEL get-master-addr-by-name mymaster | head -1 || echo '')"
  if [ -n "$s_master" ] && [ "$s_master" != "nil" ]; then
    ok "Sentinel reports master: $s_master"
    [ "$s_master" = "$master_ip" ] && ok "  IP matches" || { bad "  IP mismatch: sentinel=$s_master actual=$master_ip"; errors=$((errors+1)); }
  else
    bad "Sentinel cannot find master"
    errors=$((errors+1))
  fi

  # 2d. Password auth
  local pass; pass="$(get_pass)"
  if [ -n "$pass" ]; then
    info "Testing password auth..."
    rcli "$master_pod" SET testkey "hello" | grep -q OK && ok "SET with auth works" || { bad "SET failed"; errors=$((errors+1)); }
    local val; val="$(rcli "$master_pod" GET testkey)"
    [ "$val" = "hello" ] && ok "GET with auth works" || { bad "GET failed (got: $val)"; errors=$((errors+1)); }
    kubectl -n "$NS" exec "$master_pod" -- redis-cli GET testkey 2>/dev/null | grep -q NOAUTH && ok "Unauth rejected" || bad "Unauth not rejected"
  fi

  # 2e. Exporter metrics
  info "Checking exporter metrics..."
  local metrics; metrics="$(kubectl -n "$NS" exec "${INSTANCE}-0" -c exporter -- wget -qO- http://127.0.0.1:9121/metrics 2>/dev/null || echo '')"
  echo "$metrics" | grep -q "redis_up 1" && ok "Redis exporter healthy" || bad "Redis exporter not responding"

  # 2f. master svc routing
  info "Checking ${INSTANCE}-master.svc routing..."
  local route; route="$(kubectl -n "$NS" run test-route --image=redis:5.0.8 --rm -i --restart=Never -- \
    sh -c "redis-cli -h ${INSTANCE}-master $([ -n "$pass" ] && echo "-a '$pass'") ROLE 2>/dev/null | head -1" 2>/dev/null || echo '?')"
  echo "$route" | grep -q master && ok "${INSTANCE}-master.svc routes to master" || bad "${INSTANCE}-master.svc routing failed"

  echo ""
  if [ "$errors" -eq 0 ]; then
    echo -e "  ${G}═══ All checks passed ═══${N}"
  else
    echo -e "  ${R}═══ $errors check(s) failed ═══${N}"
  fi
  echo ""
  return "$errors"
}

# ── Failover test ─────────────────────────────────────────────
failover_test() {
  echo ""
  echo "╔══════════════════════════════════════════════╗"
  echo "║  Phase 3: Failover test                      ║"
  echo "╚══════════════════════════════════════════════╝"
  echo ""

  local errors=0

  # Find current master
  local old_master="" old_ip=""
  for i in 0 1 2; do
    pod="${INSTANCE}-${i}"
    local role; role="$(rcli "$pod" role | head -1 || echo '')"
    if [ "$role" = "master" ]; then
      old_master="$pod"
      old_ip="$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.status.podIP}')"
      break
    fi
  done
  [ -n "$old_master" ] || { bad "No master found"; return 1; }
  info "Current master: $old_master ($old_ip)"

  # Kill master
  info "Killing $old_master..."
  kubectl -n "$NS" delete pod "$old_master" --force --grace-period=0 2>/dev/null || true

  # Wait for new master (up to 60s)
  info "Waiting for failover..."
  local new_master="" new_ip="" elapsed=0
  while [ "$elapsed" -lt 60 ]; do
    for i in 0 1 2; do
      pod="${INSTANCE}-${i}"
      [ "$pod" = "$old_master" ] && continue
      local role; role="$(rcli "$pod" role | head -1 || echo '')"
      if [ "$role" = "master" ]; then
        new_master="$pod"
        new_ip="$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.status.podIP}')"
        break
      fi
    done
    [ -n "$new_master" ] && break
    sleep 2
    elapsed=$((elapsed + 2))
  done

  if [ -n "$new_master" ]; then
    ok "Failover: $old_master → $new_master ($new_ip) in ${elapsed}s"
  else
    bad "No new master elected after 60s"
    errors=$((errors+1))
  fi

  # Wait for old master to come back
  info "Waiting for $old_master to rejoin..."
  kubectl -n "$NS" wait pod --for=condition=Ready -l "app=$INSTANCE" --timeout=300s 2>/dev/null || true
  sleep 5

  # Check old master rejoined as slave
  local old_role; old_role="$(rcli "$old_master" role | head -1 || echo '?')"
  if [ "$old_role" = "slave" ]; then
    ok "Old master ($old_master) rejoined as slave"
  else
    info "Old master role: $old_role (may still be transitioning)"
  fi

  # Verify topology
  info "Final topology:"
  local m_count=0 s_count=0
  for i in 0 1 2; do
    pod="${INSTANCE}-${i}"
    local role; role="$(rcli "$pod" role | head -1 || echo '?')"
    echo "    $pod: $role"
    case "$role" in
      master) m_count=$((m_count+1)) ;;
      slave)  s_count=$((s_count+1)) ;;
    esac
  done
  if [ "$m_count" -eq 1 ] && [ "$s_count" -eq 2 ]; then
    ok "Topology: 1 master + 2 slaves"
  else
    bad "Topology: $m_count master(s) + $s_count slave(s) (expected 1+2)"
    errors=$((errors+1))
  fi

  # Write after failover
  info "Testing write after failover..."
  rcli "$new_master" SET failover_test "ok" | grep -q OK && ok "Write succeeds" || { bad "Write failed"; errors=$((errors+1)); }

  echo ""
  if [ "$errors" -eq 0 ]; then
    echo -e "  ${G}═══ Failover test passed ═══${N}"
  else
    echo -e "  ${R}═══ $errors failover check(s) failed ═══${N}"
  fi
  echo ""
  return "$errors"
}

# ── Cleanup ───────────────────────────────────────────────────
cleanup() {
  echo ""
  echo "╔══════════════════════════════════════════════╗"
  echo "║  Cleanup ($INSTANCE in $NS)                  ║"
  echo "╚══════════════════════════════════════════════╝"
  echo ""
  kubectl -n "$NS" delete statefulset "$INSTANCE" --ignore-not-found --cascade=foreground 2>/dev/null || true
  kubectl -n "$NS" delete statefulset "$INSTANCE-sentinel" --ignore-not-found --cascade=foreground 2>/dev/null || true
  sleep 3
  kubectl -n "$NS" delete pdb "$INSTANCE-pdb" "$INSTANCE-sentinel-pdb" --ignore-not-found 2>/dev/null || true
  kubectl -n "$NS" delete svc "$INSTANCE-hl" "$INSTANCE-master" "$INSTANCE-read" "$INSTANCE-exporter" \
      "$INSTANCE-sentinel-hl" "$INSTANCE-sentinel-exporter" --ignore-not-found 2>/dev/null || true
  kubectl -n "$NS" delete cm "$INSTANCE-config" "$INSTANCE-sentinel-config" --ignore-not-found 2>/dev/null || true
  kubectl -n "$NS" delete secret "$INSTANCE-secret" --ignore-not-found 2>/dev/null || true
  kubectl -n "$NS" delete sa "$INSTANCE-role-tagger" --ignore-not-found 2>/dev/null || true
  kubectl -n "$NS" delete role "$INSTANCE-role-tagger" --ignore-not-found 2>/dev/null || true
  kubectl -n "$NS" delete rolebinding "$INSTANCE-role-tagger" --ignore-not-found 2>/dev/null || true
  # Delete PVCs (data loss!)
  kubectl -n "$NS" delete pvc -l "app=$INSTANCE" --ignore-not-found 2>/dev/null || true
  ok "Instance $INSTANCE removed from $NS"
  echo ""
}

# ── Main ──────────────────────────────────────────────────────
case "$MODE" in
  install)  install ;;
  verify)   verify ;;
  failover) failover_test ;;
  cleanup)  cleanup ;;
  full)
    install
    verify
    failover_test
    echo "  Run ./test.sh $INSTANCE $NS cleanup to tear down"
    ;;
  *)
    echo "Usage: $0 [INSTANCE_NAME] [NAMESPACE] [install|verify|failover|cleanup|full]"
    exit 1
    ;;
esac
