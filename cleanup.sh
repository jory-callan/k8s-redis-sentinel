#!/bin/bash
set -euo pipefail

echo "=== WARNING: This will delete ALL Redis data (PVCs) ==="
read -rp "Type 'yes' to confirm: " CONFIRM
[ "$CONFIRM" != "yes" ] && echo "Aborted." && exit 1

kubectl -n redis delete statefulset redis --ignore-not-found --cascade=foreground 2>/dev/null
kubectl -n redis delete statefulset sentinel --ignore-not-found --cascade=foreground 2>/dev/null

sleep 5

kubectl -n redis delete pdb --all --ignore-not-found 2>/dev/null
kubectl -n redis delete svc --all --ignore-not-found 2>/dev/null
kubectl -n redis delete cm --all --ignore-not-found 2>/dev/null
kubectl -n redis delete secret --all --ignore-not-found 2>/dev/null
kubectl delete ns redis --ignore-not-found --cascade=foreground 2>/dev/null

echo "=== All Redis resources removed ==="
