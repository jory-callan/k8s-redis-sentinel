# 多实例隔离

同一命名空间可部署多套 Redis 集群，通过 **实例名称**（instance）隔离所有资源。

## 命名规范

所有资源名以 `<instance>` 开头：

| 资源类型 | 命名规则 | 示例 (instance=`redis-saas-log`) |
|----------|----------|----------------------------------|
| Redis StatefulSet | `<instance>` | `redis-saas-log` |
| Sentinel StatefulSet | `<instance>-sentinel` | `redis-saas-log-sentinel` |
| Redis Pod | `<instance>-{0,1,2}` | `redis-saas-log-0` |
| Sentinel Pod | `<instance>-sentinel-{0,1,2}` | `redis-saas-log-sentinel-0` |
| Headless Service (Redis) | `<instance>-hl` | `redis-saas-log-hl` |
| Headless Service (Sentinel) | `<instance>-sentinel-hl` | `redis-saas-log-sentinel-hl` |
| Master Service | `<instance>-master` | `redis-saas-log-master` |
| Read Service | `<instance>-read` | `redis-saas-log-read` |
| Exporter Service | `<instance>-exporter` | `redis-saas-log-exporter` |
| Sentinel Exporter | `<instance>-sentinel-exporter` | `redis-saas-log-sentinel-exporter` |
| ConfigMap (Redis) | `<instance>-config` | `redis-saas-log-config` |
| ConfigMap (Sentinel) | `<instance>-sentinel-config` | `redis-saas-log-sentinel-config` |
| Secret | `<instance>-secret` | `redis-saas-log-secret` |
| PDB | `<instance>-pdb` / `<instance>-sentinel-pdb` | `redis-saas-log-pdb` |
| RBAC | `<instance>-role-tagger` | `redis-saas-log-role-tagger` |

## 命名约定

- Headless Service 以 `-hl` 结尾
- NodePort Service 以 `-np` 结尾（默认不创建，按需自行添加）
- Master / Read Service 默认 ClusterIP

## 长度限制

K8s 资源名最长 63 字符。Pod 名 = `<instance>-sentinel-0`（最长后缀 12 字符），故实例名最长 **42 字符**。

- Helm Chart 不强制校验，但超长会导致 K8s API 拒绝

## 实例命名建议

推荐格式：**中间件前缀 + 业务名**

| 业务 | 实例名 | 说明 |
|------|--------|------|
| SaaS 日志服务 | `redis-saas-log` | 中间件前缀 `redis` + 业务 `saas-log` |
| 订单缓存 | `redis-order` | |
| 用户会话 | `redis-user-session` | |

避免使用 `redis`、`redis-sentinel` 等通用名，防止与默认实例冲突。

## 部署多实例

### Helm 方式

```bash
# 实例 1: 日志服务
helm install log ./helm/redis-sentinel -n redis \
  --set common.instanceName=redis-saas-log

# 实例 2: 订单服务 (同命名空间)
helm install order ./helm/redis-sentinel -n redis \
  --set common.instanceName=redis-order
```

### 脚本方式

```bash
# 部署 + 验证 + failover + 清理
./test.sh redis-saas-log
./test.sh redis-order

# 仅部署
./test.sh redis-saas-log redis install
```

## 自定义 Service

默认不创建 NodePort / LoadBalancer。如需外部访问，自行创建 Service 并使用相同 selector：

```yaml
# 例: 为 redis-saas-log 暴露 NodePort
apiVersion: v1
kind: Service
metadata:
  name: redis-saas-log-master-np   # 以 -np 结尾
  namespace: redis
spec:
  type: NodePort
  selector:
    app: redis-saas-log
    redis-role: master             # 只路由到 master
  ports:
    - port: 6379
      nodePort: 30010              # 自行选择未占用端口
```

## 资源隔离验证

部署后可用以下命令验证实例隔离：

```bash
# 查看某实例的所有资源
kubectl -n redis get all,configmap,secret,pvc,sa,role,rolebinding -l "app in (redis-saas-log,redis-saas-log-sentinel)"

# 检查实例间无资源冲突
kubectl -n redis get svc | grep redis-
```
