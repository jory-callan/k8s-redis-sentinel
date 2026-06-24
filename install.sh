#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Deploying Redis-Sentinel to namespace: redis ==="

kubectl apply -f "$DIR/00-namespace.yaml"
kubectl apply -f "$DIR/01-secret.yaml"
kubectl apply -f "$DIR/02-configmap-redis.yaml"
kubectl apply -f "$DIR/03-configmap-sentinel.yaml"
kubectl apply -f "$DIR/04-services.yaml"
kubectl apply -f "$DIR/05-statefulset-redis.yaml"
kubectl apply -f "$DIR/06-statefulset-sentinel.yaml"
kubectl apply -f "$DIR/07-pdb.yaml"
kubectl apply -f "$DIR/08-rbac.yaml"

echo ""
echo "=== Waiting for pods ready ==="
# All redis pods become Ready (readinessProbe=PING, not ROLE).
# Master routing is handled by redis-role label (set by role-tagger sidecar).
kubectl -n redis wait pod --for=condition=Ready -l app=redis --timeout=300s
kubectl -n redis wait pod --for=condition=Ready -l app=sentinel --timeout=200s

echo ""
echo "=== Verify ==="
PASS="$(kubectl -n redis get secret redis-secret -o jsonpath='{.data.redis-password}' 2>/dev/null | base64 -d 2>/dev/null || echo '')"

# Find actual master (may not be redis-0 after failover)
MASTER_POD=""
for p in redis-0 redis-1 redis-2; do
  ROLE="$(kubectl -n redis exec "$p" -c redis -- sh -c "redis-cli -a '${PASS}' role 2>/dev/null || true" | head -1)"
  if [ "$ROLE" = "master" ]; then
    MASTER_POD="$p"
    break
  fi
done
echo "  master pod: ${MASTER_POD:-not found}"

SENTINEL_MASTER="$(kubectl -n redis exec sentinel-0 -c sentinel -- sh -c "redis-cli -p 26379 -a '${PASS}' SENTINEL get-master-addr-by-name mymaster 2>/dev/null || true" | head -1)"
echo "  sentinel reports master: ${SENTINEL_MASTER:-unknown}"

echo ""
echo "=== Done ==="
echo "  Write:   redis-master.redis.svc:6379  (or <node-ip>:30001)"
echo "  Read:    redis-read.redis.svc:6379    (or <node-ip>:30002)"
echo "  Metrics: redis-exporter.redis.svc:9121"
echo "  Password: ${PASS:-<none>}"
