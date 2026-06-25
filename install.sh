#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# install.sh — Redis Sentinel 实例安装/卸载 (基于 Helm)
#
# Usage:
#   ./install.sh <command> [instance] [namespace] [options]
#
# Commands:
#   install     安装实例 (或 update 更新配置)
#   uninstall   卸载实例 (默认保留数据, --purge 连同 PVC 删除)
#   list        列出所有实例
#   upgrade     升级/更新配置 (helm upgrade)
#
# Examples:
#   ./install.sh install my-app                       # 安装 my-app 到 redis ns
#   ./install.sh install my-app middleware            # 安装到 middleware ns
#   ./install.sh install my-app redis --password secretpw
#   ./install.sh install my-app redis --values my-values.yaml
#   ./install.sh install my-app redis --persistence-size 5Gi
#   ./install.sh uninstall my-app                    # 卸载 (保留 PVC)
#   ./install.sh uninstall my-app redis --purge       # 卸载并删 PVC
#   ./install.sh list                                # 列出所有实例
#   ./install.sh upgrade my-app redis --password newpw
# ═══════════════════════════════════════════════════════════════

set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
CHART_DIR="${DIR}/helm/redis-sentinel"

# 颜色
G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
ok()   { echo -e "  ${G}✓${N} $1"; }
bad()  { echo -e "  ${R}✗${N} $1"; }
info() { echo -e "  ${Y}→${N} $1"; }
hdr()  { echo -e "\n${C}${B}═══ $1 ═══${N}"; }

# 解析参数
COMMAND="${1:-}"
[ -z "$COMMAND" ] && { echo "Usage: $0 <install|uninstall|list|upgrade> [instance] [namespace] [options]"; exit 1; }
shift

INSTANCE="${1:-redis}"
NS="${2:-redis}"
shift 2 2>/dev/null || shift $# 2>/dev/null || true

# 可选参数默认值
PASSWORD=""
VALUES_FILE=""
PURGE_PVC=false
PERSISTENCE_SIZE=""
REPLICAS=""
NO_PASSWORD=false
EXISTING_SECRET=""

# 解析 --options
while [ $# -gt 0 ]; do
  case "$1" in
    --password)         PASSWORD="$2"; shift 2 ;;
    --values|-f)        VALUES_FILE="$2"; shift 2 ;;
    --purge)           PURGE_PVC=true; shift ;;
    --persistence-size) PERSISTENCE_SIZE="$2"; shift 2 ;;
    --replicas)        REPLICAS="$2"; shift 2 ;;
    --no-password)     NO_PASSWORD=true; shift ;;
    --existing-secret) EXISTING_SECRET="$2"; shift 2 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

RELEASE="$INSTANCE"

# ── 构建 helm 参数 ──────────────────────────────────────────────

# 设置全局 HELM_ARGS 数组 (macOS bash 3.2 兼容, 不用 mapfile)
build_helm_args() {
  HELM_ARGS=()
  HELM_ARGS+=("--set" "common.instanceName=${INSTANCE}")

  if [ "$NO_PASSWORD" = "true" ]; then
    HELM_ARGS+=("--set" "common.auth.enabled=false")
  elif [ -n "$EXISTING_SECRET" ]; then
    HELM_ARGS+=("--set" "common.auth.existingSecret=${EXISTING_SECRET}")
  elif [ -n "$PASSWORD" ]; then
    HELM_ARGS+=("--set" "common.auth.password=${PASSWORD}")
  fi

  [ -n "$PERSISTENCE_SIZE" ] && HELM_ARGS+=("--set" "redis.persistence.size=${PERSISTENCE_SIZE}")
  [ -n "$REPLICAS" ] && HELM_ARGS+=("--set" "redis.replicas=${REPLICAS}" "--set" "sentinel.replicas=${REPLICAS}")
  [ -n "$VALUES_FILE" ] && HELM_ARGS+=("-f" "$VALUES_FILE")
}

# 确保 namespace 存在
ensure_ns() {
  kubectl get ns "$NS" >/dev/null 2>&1 || {
    info "创建 namespace ${NS}"
    kubectl create ns "$NS" >/dev/null
  }
}

# ── install ────────────────────────────────────────────────────

do_install() {
  hdr "安装 ${INSTANCE} (ns=${NS})"

  # 检查是否已存在
  if helm status "$RELEASE" -n "$NS" >/dev/null 2>&1; then
    bad "实例 ${INSTANCE} 已存在, 请用 upgrade 更新或先 uninstall"
    exit 1
  fi

  ensure_ns

  # 验证实例名长度 (≤42 字符, Pod 名 ≤63)
  if [ "${#INSTANCE}" -gt 42 ]; then
    bad "实例名 ${INSTANCE} 超过 42 字符 (Pod 名会超 63 限制)"
    exit 1
  fi

  # 生成随机密码 (未指定时)
  if [ "$NO_PASSWORD" = "false" ] && [ -z "$PASSWORD" ] && [ -z "$EXISTING_SECRET" ]; then
    PASSWORD="$(head -c 16 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 16)"
    info "未指定密码, 自动生成: ${PASSWORD}"
  fi

  info "helm install ${RELEASE}..."
  build_helm_args

  helm install "$RELEASE" "$CHART_DIR" -n "$NS" "${HELM_ARGS[@]}" 2>&1 | sed 's/^/    /'

  info "等待 Pod Ready (最多 300s)..."
  if kubectl -n "$NS" wait pod --for=condition=Ready \
      -l "app in (${INSTANCE},${INSTANCE}-sentinel)" --timeout=300s 2>&1 | tail -1; then
    sleep 8  # 等 role-tagger 更新 label
    ok "部署完成"
    echo ""
    info "连接信息:"
    echo "    Master:    ${INSTANCE}-master.${NS}.svc:6379"
    echo "    Read:      ${INSTANCE}-read.${NS}.svc:6379"
    if [ "$NO_PASSWORD" = "false" ]; then
      echo "    密码:       ${PASSWORD:-<from existingSecret ${EXISTING_SECRET}>}"
      echo "    redis-cli -h ${INSTANCE}-master.${NS}.svc -a '${PASSWORD}'"
    fi
    echo ""
    info "查看状态: ./check.sh ${INSTANCE} ${NS}"
  else
    bad "Pod 未在 300s 内 Ready, 请用 kubectl describe 排查"
    exit 1
  fi
}

# ── upgrade ────────────────────────────────────────────────────

do_upgrade() {
  hdr "升级 ${INSTANCE} (ns=${NS})"

  if ! helm status "$RELEASE" -n "$NS" >/dev/null 2>&1; then
    bad "实例 ${INSTANCE} 不存在, 请先 install"
    exit 1
  fi

  info "helm upgrade ${RELEASE}..."
  build_helm_args

  helm upgrade "$RELEASE" "$CHART_DIR" -n "$NS" "${HELM_ARGS[@]}" 2>&1 | sed 's/^/    /'

  info "等待滚动更新完成..."
  kubectl -n "$NS" rollout status sts/"${INSTANCE}" --timeout=300s 2>&1 | tail -1
  kubectl -n "$NS" rollout status sts/"${INSTANCE}-sentinel" --timeout=300s 2>&1 | tail -1
  ok "升级完成"
}

# ── uninstall ──────────────────────────────────────────────────

do_uninstall() {
  hdr "卸载 ${INSTANCE} (ns=${NS})"

  if ! helm status "$RELEASE" -n "$NS" >/dev/null 2>&1; then
    bad "实例 ${INSTANCE} 不存在"
    exit 1
  fi

  if [ "$PURGE_PVC" = "true" ]; then
    echo -e "  ${R}${B}⚠️  --purge 将删除所有 PVC (数据永久丢失!)${N}"
    read -rp "  输入 'yes' 确认删除数据: " CONFIRM
    [ "$CONFIRM" != "yes" ] && { echo "  已取消"; exit 0; }
  fi

  info "helm uninstall ${RELEASE}..."
  helm uninstall "$RELEASE" -n "$NS" 2>&1 | sed 's/^/    /'

  # 等 pod 终止
  info "等待 Pod 终止..."
  kubectl -n "$NS" delete pod -l "app in (${INSTANCE},${INSTANCE}-sentinel)" --force --grace-period=0 2>/dev/null | sed 's/^/    /' || true

  if [ "$PURGE_PVC" = "true" ]; then
    info "删除 PVC..."
    kubectl -n "$NS" delete pvc -l "app.kubernetes.io/instance=${RELEASE}" 2>&1 | sed 's/^/    /'
    ok "PVC 已删除 (数据已清除)"
  else
    info "保留 PVC (数据未删除)"
    info "如需彻底删除: kubectl -n ${NS} delete pvc -l app.kubernetes.io/instance=${RELEASE}"
  fi

  ok "卸载完成"
}

# ── list ───────────────────────────────────────────────────────

do_list() {
  hdr "所有 Redis Sentinel 实例"
  echo ""
  printf "%-12s %-20s %-10s %-12s %-26s %-12s\n" "NAMESPACE" "INSTANCE" "REVISION" "STATUS" "UPDATED" "REPLICAS"
  echo "───────────────────────────────────────────────────────────────────────────────────────────────────────"

  # 遍历所有 namespace, 找出本 chart 的 release
  for ns in $(kubectl get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
    # 用 -o json 输出, 避免 awk 解析空白
    releases_json=$(helm list -n "$ns" -o json 2>/dev/null || echo "[]")
    count=$(echo "$releases_json" | python3 -c "import sys, json; d=json.load(sys.stdin); print(len(d))" 2>/dev/null || echo 0)
    idx=0
    while [ "$idx" -lt "$count" ]; do
      name=$(echo "$releases_json" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d[$idx]['name'])" 2>/dev/null)
      chart=$(echo "$releases_json" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d[$idx]['chart'])" 2>/dev/null)
      rev=$(echo "$releases_json" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d[$idx]['revision'])" 2>/dev/null)
      status=$(echo "$releases_json" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d[$idx]['status'])" 2>/dev/null)
      updated=$(echo "$releases_json" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d[$idx]['updated'])" 2>/dev/null | cut -d. -f1)
      # 只显示本 chart
      echo "$chart" | grep -qi "redis-sentinel" || { idx=$((idx+1)); continue; }
      # 读 instanceName
      inst=$(helm get values "$name" -n "$ns" -o json 2>/dev/null | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('common',{}).get('instanceName','') or d.get('name',''))" 2>/dev/null)
      [ -z "$inst" ] && inst="$name"
      # 读 replicas
      r_repl=$(helm get values "$name" -n "$ns" -o json 2>/dev/null | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('redis',{}).get('replicas',3))" 2>/dev/null)
      s_repl=$(helm get values "$name" -n "$ns" -o json 2>/dev/null | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('sentinel',{}).get('replicas',3))" 2>/dev/null)
      printf "%-12s %-20s %-10s %-12s %-26s %s+%s\n" "$ns" "$inst" "$rev" "$status" "$updated" "$r_repl" "$s_repl"
      idx=$((idx+1))
    done
  done
  echo ""
}

# ── Main ────────────────────────────────────────────────────────

case "$COMMAND" in
  install)   do_install ;;
  uninstall) do_uninstall ;;
  upgrade)   do_upgrade ;;
  list)
    INSTANCE=""; NS=""
    do_list
    ;;
  *)
    echo "Usage: $0 <install|uninstall|list|upgrade> [instance] [namespace] [options]"
    echo ""
    echo "Options:"
    echo "  --password <pw>             指定密码"
    echo "  --existing-secret <name>    用已有 Secret (key: redis-password)"
    echo "  --no-password               禁用密码 (不安全)"
    echo "  --values <file>             自定义 values 文件"
    echo "  --persistence-size <size>   持久化大小 (如 5Gi)"
    echo "  --replicas <n>              副本数 (默认 3)"
    echo "  --purge                     卸载时连同 PVC 一起删"
    exit 1
    ;;
esac
