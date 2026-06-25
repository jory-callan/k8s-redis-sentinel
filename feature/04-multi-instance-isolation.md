# 04 - 多实例隔离（Multi-Instance Isolation）

同命名空间可部署多套 Redis 集群，按 `instanceName` 完全隔离，互不干扰。

## 架构设计

```
namespace: redis
┌──────────────────────────────────────────────────────────────┐
│                                                                │
│  实例A: app=appA                                                │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐                        │
│  │appA-0    │ │appA-1    │ │appA-2    │ ← Service appA-master │
│  │(master)  │ │(slave)   │ │(slave)   │   selector:            │
│  └──────────┘ └──────────┘ └──────────┘   app=appA             │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐   redis-role=master   │
│  │appA-s-0  │ │appA-s-1  │ │appA-s-2  │                        │
│  └──────────┘ └──────────┘ └──────────┘                        │
│                                                                │
│  实例B: app=appB                                                │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐                        │
│  │appB-0    │ │appB-1    │ │appB-2    │ ← Service appB-master │
│  │(master)  │ │(slave)   │ │(slave)   │   selector:            │
│  └──────────┘ └──────────┘ └──────────┘   app=appB             │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐   redis-role=master   │
│  │appB-s-0  │ │appB-s-1  │ │appB-s-2  │                        │
│  └──────────┘ └──────────┘ └──────────┘                        │
│                                                                │
└──────────────────────────────────────────────────────────────┘
```

**隔离维度**：
1. **资源名前缀**：所有 K8s 资源（StatefulSet/Service/ConfigMap/Secret/SA/Role）都以 `<instanceName>` 开头
2. **label 前缀**：`app=<instance>` 严格匹配，Service selector 不会跨实例
3. **RBAC 锁定**：role-tagger 只能 patch 本实例的 3 个 pod（`resourceNames` 锁定）
4. **Redis 配置隔离**：每个实例独立的 redis.conf / sentinel.conf / startup.sh
5. **数据隔离**：每个实例独立 PVC

## 实现设计

### 涉及文件

所有模板都通过 `include "redis-sentinel.instanceName"` 注入前缀：

| 文件 | 资源名模式 |
|------|-----------|
| statefulset-redis.yaml | `<inst>` (StatefulSet) → `<inst>-0/1/2` (Pod) |
| statefulset-sentinel.yaml | `<inst>-sentinel` → `<inst>-sentinel-0/1/2` |
| services.yaml | `<inst>-hl` / `<inst>-master` / `<inst>-read` / `<inst>-sentinel-hl` |
| configmap-redis.yaml | `<inst>-config` |
| configmap-sentinel.yaml | `<inst>-sentinel-config` |
| secret.yaml | `<inst>-secret` |
| backup-secret.yaml | `<inst>-backup-secret` |
| rbac.yaml | `<inst>-role-tagger` (SA/Role/RoleBinding) |
| pdb.yaml | `<inst>-pdb` / `<inst>-sentinel-pdb` |
| backup-cronjob.yaml | `<inst>-backup` |

### instanceName 解析（_helpers.tpl）

```gotemplate
{{- define "redis-sentinel.instanceName" -}}
{{- if .Values.common.instanceName -}}
{{- .Values.common.instanceName -}}
{{- else -}}
{{- .Release.Name -}}    # 默认用 release name
{{- end -}}
{{- end -}}
```

### RBAC resourceNames 锁定

```yaml
# rbac.yaml
resourceNames:
  - {{ include "redis-sentinel.redisName" . }}-0
  - {{ include "redis-sentinel.redisName" . }}-1
  - {{ include "redis-sentinel.redisName" . }}-2
verbs: ["get", "patch"]
```

→ 实例 A 的 role-tagger **无法 patch 实例 B 的 pod**（被 403 拒绝）。

### 长度限制

K8s 资源名最长 63 字符，Pod 名 = `instance + "-sentinel-0"`（最长后缀 12 字符），故 `instanceName` 最长 42 字符。

## 使用说明

```bash
# 部署实例 A (业务 saas)
helm install appA ./helm/redis-sentinel -n redis --create-namespace \
  --set common.instanceName=redis-saas \
  --set common.auth.password=pwA

# 部署实例 B (业务 log) — 同 namespace, 互不影响
helm install appB ./helm/redis-sentinel -n redis \
  --set common.instanceName=redis-log \
  --set common.auth.password=pwB
```

应用访问：
```bash
# 实例 A
redis://redis-saas-master.redis.svc.cluster.local:6379  (密码 pwA)

# 实例 B
redis://redis-log-master.redis.svc.cluster.local:6379  (密码 pwB)
```

## 校验

### 1. 两套集群独立运行

```bash
# 各自都有 1 个 master
kubectl -n redis get pod -l app=redis-saas,redis-role=master
kubectl -n redis get pod -l app=redis-log,redis-role=master

# Service endpoint 各自指向自己的 master
kubectl -n redis get endpoints redis-saas-master
kubectl -n redis get endpoints redis-log-master
```

### 2. 数据隔离

```bash
# 在实例 A 写 key, 实例 B 看不到
kubectl -n redis exec -it redis-saas-0 -c redis -- redis-cli -a pwA SET shared only-in-A
kubectl -n redis exec -it redis-log-0 -c redis -- redis-cli -a pwB GET shared
# 预期: (nil)
```

### 3. RBAC 越权测试

```bash
# 尝试用实例 A 的 SA patch 实例 B 的 pod → 应被拒绝
SA_TOKEN=$(kubectl -n redis exec redis-saas-0 -c role-tagger -- cat /var/run/secrets/kubernetes.io/serviceaccount/token 2>/dev/null)

kubectl -n redis auth can-i --as=system:serviceaccount:redis:redis-saas-role-tagger \
  patch pod redis-log-0
# 预期: no

kubectl -n redis auth can-i --as=system:serviceaccount:redis:redis-saas-role-tagger \
  patch pod redis-saas-1
# 预期: yes (自己的 pod 可以)
```

### 4. failover 不串扰

```bash
# 杀掉实例 A 的 master, 实例 B 不受影响
A_MASTER=$(kubectl -n redis get pod -l app=redis-saas,redis-role=master -o jsonpath='{.items[0].metadata.name}')
kubectl -n redis delete pod "$A_MASTER" --force --grace-period=0

# 实例 B 仍可正常读写
kubectl -n redis exec -it redis-log-0 -c redis -- redis-cli -a pwB SET ok yes
# 预期: OK
```

## 清理

```bash
helm uninstall appA -n redis
helm uninstall appB -n redis
kubectl -n redis delete pvc -l 'app.kubernetes.io/instance in (appA,appB)' --force
```

## 注意事项

1. **`instanceName` 必须唯一**：同 namespace 内重名会导致资源冲突（Helm install 失败）
2. **跨 namespace 也要避免重名**：虽然资源在不同 ns，但 RBAC `resourceNames` 不区分 namespace，重名可能造成权限混淆
3. **资源配额**：多实例共享 namespace 时注意 `ResourceQuota`，3 redis + 3 sentinel × N 实例可能耗尽节点资源
4. **NetworkPolicy 跨实例**：默认 `networkPolicy.redisIngressFrom` 是 namespace 级，多实例同 namespace 时业务 pod 能访问所有实例。如需更严格隔离，用 `podSelector` 限定
5. **PVC 命名**：`data-<inst>-0` 自动带实例前缀，不会冲突
