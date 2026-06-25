#!/bin/bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════
# install.sh — Deploy a Redis-Sentinel instance
#
# Usage:
#   ./install.sh [INSTANCE_NAME] [NAMESPACE]
#
# Examples:
#   ./install.sh                              # instance=redis, ns=redis
#   ./install.sh redis-saas-log               # instance=redis-saas-log, ns=redis
#   ./install.sh redis-saas-log middleware    # instance=redis-saas-log, ns=middleware
#
# Naming convention (instance=redis-saas-log):
#   StatefulSet:        redis-saas-log / redis-saas-log-sentinel
#   Headless Service:   redis-saas-log-hl / redis-saas-log-sentinel-hl
#   ClusterIP Service:  redis-saas-log-master / redis-saas-log-read
#   Pod DNS:            redis-saas-log-0.redis-saas-log-hl.<ns>.svc
#
# K8s name limit: 63 chars. Pod name = instance + "-sentinel-0" (max).
# So instance name max ≈ 42 chars (safe margin).
# ═══════════════════════════════════════════════════════════════

DIR="$(cd "$(dirname "$0")" && pwd)"

INSTANCE="${1:-redis}"
NS="${2:-redis}"

# Validate instance name (K8s name: [a-z0-9]([-a-z0-9]*[a-z0-9])?)
if ! echo "$INSTANCE" | grep -Eq '^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'; then
  echo "Error: instance name '$INSTANCE' is invalid"
  echo "  Must be lowercase alphanumeric with hyphens (K8s naming rule)"
  exit 1
fi

# Length check: longest pod name = instance + "-sentinel-0" (12 chars)
# K8s limit = 63 chars, so instance max = 63 - 12 = 51. Use 42 for safety.
if [ "${#INSTANCE}" -gt 42 ]; then
  echo "Error: instance name '$INSTANCE' too long (${#INSTANCE} chars, max 42)"
  echo "  Pod name = instance + '-sentinel-0' must be <= 63 chars (K8s limit)"
  exit 1
fi

echo "=== Deploying Redis-Sentinel instance: $INSTANCE (namespace: $NS) ==="
echo ""

# Render templates (replace __INSTANCE_NAME__ and __NAMESPACE__) and apply
for f in 00-namespace 01-secret 02-configmap-redis 03-configmap-sentinel \
         04-services 05-statefulset-redis 06-statefulset-sentinel \
         07-pdb 08-rbac; do
  echo "  applying $f.yaml"
  sed -e "s/__INSTANCE_NAME__/$INSTANCE/g" \
      -e "s/__NAMESPACE__/$NS/g" \
      "$DIR/$f.yaml" | kubectl apply -f -
done

echo ""
echo "=== Waiting for pods ready ==="
# Wait for StatefulSet controller to create pods first (kubectl wait fails
# with "no matching resources found" if pods don't exist yet — race condition)
i=0
while [ "$i" -lt 30 ]; do
  c="$(kubectl -n "$NS" get pod -l "app=$INSTANCE" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  [ "$c" -ge 3 ] && break
  i=$((i+1)); sleep 2
done
kubectl -n "$NS" wait pod --for=condition=Ready -l "app=$INSTANCE" --timeout=300s
kubectl -n "$NS" wait pod --for=condition=Ready -l "app=$INSTANCE-sentinel" --timeout=200s

echo ""
echo "=== Verify ==="
PASS="$(kubectl -n "$NS" get secret "$INSTANCE-secret" -o jsonpath='{.data.redis-password}' 2>/dev/null | base64 -d 2>/dev/null || echo '')"

# Find actual master (may not be ${INSTANCE}-0 after failover)
MASTER_POD=""
for i in 0 1 2; do
  p="${INSTANCE}-${i}"
  ROLE="$(kubectl -n "$NS" exec "$p" -c redis -- sh -c "redis-cli -a '${PASS}' role 2>/dev/null || true" | head -1)"
  if [ "$ROLE" = "master" ]; then
    MASTER_POD="$p"
    break
  fi
done
echo "  master pod: ${MASTER_POD:-not found}"

SENTINEL_MASTER="$(kubectl -n "$NS" exec "${INSTANCE}-sentinel-0" -c sentinel -- sh -c "redis-cli -p 26379 -a '${PASS}' SENTINEL get-master-addr-by-name mymaster 2>/dev/null || true" | head -1)"
echo "  sentinel reports master: ${SENTINEL_MASTER:-unknown}"

echo ""
echo "=== Done ==="
echo "  Write:   ${INSTANCE}-master.${NS}.svc:6379"
echo "  Read:    ${INSTANCE}-read.${NS}.svc:6379"
echo "  Metrics: ${INSTANCE}-exporter.${NS}.svc:9121"
echo "  Password: ${PASS:-<none>}"
