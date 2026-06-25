#!/bin/bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════
# cleanup.sh — Delete a Redis-Sentinel instance (including data!)
#
# Usage:
#   ./cleanup.sh [INSTANCE_NAME] [NAMESPACE]
#   ./cleanup.sh                              # instance=redis, ns=redis
#   ./cleanup.sh redis-saas-log               # instance=redis-saas-log
#
# WARNING: This deletes PVCs (all data loss)!
# ═══════════════════════════════════════════════════════════════

INSTANCE="${1:-redis}"
NS="${2:-redis}"

echo "=== WARNING: This will delete instance '$INSTANCE' in namespace '$NS' ==="
echo "=== This includes PVCs (ALL DATA WILL BE LOST)! ==="
read -rp "Type 'yes' to confirm: " CONFIRM
[ "$CONFIRM" != "yes" ] && echo "Aborted." && exit 1

kubectl -n "$NS" delete statefulset "$INSTANCE" --ignore-not-found --cascade=foreground 2>/dev/null || true
kubectl -n "$NS" delete statefulset "$INSTANCE-sentinel" --ignore-not-found --cascade=foreground 2>/dev/null || true

sleep 5

kubectl -n "$NS" delete pdb "$INSTANCE-pdb" "$INSTANCE-sentinel-pdb" --ignore-not-found 2>/dev/null || true
kubectl -n "$NS" delete svc "$INSTANCE-hl" "$INSTANCE-master" "$INSTANCE-read" "$INSTANCE-exporter" \
    "$INSTANCE-sentinel-hl" "$INSTANCE-sentinel-exporter" --ignore-not-found 2>/dev/null || true
kubectl -n "$NS" delete cm "$INSTANCE-config" "$INSTANCE-sentinel-config" --ignore-not-found 2>/dev/null || true
kubectl -n "$NS" delete secret "$INSTANCE-secret" --ignore-not-found 2>/dev/null || true
kubectl -n "$NS" delete sa "$INSTANCE-role-tagger" --ignore-not-found 2>/dev/null || true
kubectl -n "$NS" delete role "$INSTANCE-role-tagger" --ignore-not-found 2>/dev/null || true
kubectl -n "$NS" delete rolebinding "$INSTANCE-role-tagger" --ignore-not-found 2>/dev/null || true
kubectl -n "$NS" delete pvc -l "app=$INSTANCE" --ignore-not-found 2>/dev/null || true

echo "=== Instance '$INSTANCE' removed from '$NS' ==="
