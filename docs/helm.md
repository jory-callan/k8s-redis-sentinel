# Helm Chart 使用指南

## 快速开始

```bash
# 默认实例 (instance=release name)
helm install my-redis ./helm/redis-sentinel -n redis --create-namespace

# 业务实例 (推荐)
helm install log ./helm/redis-sentinel -n redis \
  --set common.instanceName=redis-saas-log \
  --set common.auth.password=mypassword

# 自定义 values 文件
helm install log ./helm/redis-sentinel -n redis -f my-values.yaml
```

## 配置结构

values.yaml 按 Pod 类型划分：

```yaml
common:        # 共享配置
  instanceName  # 实例名（默认 release name）
  auth          # 认证（密码 / existingSecret）
  podAntiAffinity

redis:         # Redis Pod 配置
  image         # 镜像
  replicas      # 副本数
  resources     # 资源限制
  persistence    # 持久化（PVC / emptyDir）
  exporter       # Prometheus exporter sidecar
  roleTagger     # role-tagger sidecar
  config         # redis.conf 额外配置（数组）
  probes         # 健康检查参数

sentinel:      # Sentinel Pod 配置
  image
  replicas
  quorum        # failover quorum
  resources
  exporter
  config         # sentinel.conf 额外配置（数组）
  probes

service:       # Service 配置
  type          # ClusterIP / NodePort / LoadBalancer
  nodePort      # NodePort 端口

pdb:           # PodDisruptionBudget
  enabled
  minAvailable
```

## 常用配置示例

### 1. 基本部署（默认值）

```bash
helm install my-redis ./helm/redis-sentinel -n redis --create-namespace
```

### 2. 自定义密码和实例名

```bash
helm install log ./helm/redis-sentinel -n redis \
  --set common.instanceName=redis-saas-log \
  --set common.auth.password=super-secret
```

### 3. 使用已有 Secret

```bash
# 先创建 Secret
kubectl create secret generic my-redis-secret --from-literal=redis-password=mypassword -n redis

# 部署时引用
helm install log ./helm/redis-sentinel -n redis \
  --set common.auth.existingSecret=my-redis-secret
```

### 4. 禁用持久化（缓存场景）

```bash
helm install cache ./helm/redis-sentinel -n redis \
  --set redis.persistence.enabled=false
```

### 5. 禁用 exporter

```bash
helm install log ./helm/redis-sentinel -n redis \
  --set redis.exporter.enabled=false \
  --set sentinel.exporter.enabled=false
```

### 6. 自定义镜像和副本数

```bash
helm install log ./helm/redis-sentinel -n redis \
  --set redis.image.repository=myregistry.com/redis \
  --set redis.image.tag=6.2.14 \
  --set redis.replicas=5 \
  --set sentinel.replicas=5 \
  --set sentinel.quorum=3
```

### 7. NodePort 暴露

```bash
helm install log ./helm/redis-sentinel -n redis \
  --set service.type=NodePort \
  --set service.nodePort.master=30010 \
  --set service.nodePort.read=30011
```

### 8. 自定义 redis.conf 配置

```yaml
# my-values.yaml
redis:
  config:
    - "save 900 1"
    - "save 300 10"
    - "appendonly yes"
    - "appendfilename appendonly.aof"
    - "maxmemory 512mb"
    - "maxmemory-policy allkeys-lru"
```

```bash
helm install log ./helm/redis-sentinel -n redis -f my-values.yaml
```

### 9. 自定义资源限制

```yaml
# my-values.yaml
redis:
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 1
      memory: 1Gi

sentinel:
  resources:
    requests:
      cpu: 20m
      memory: 32Mi
```

## config 数组说明

`redis.config` 和 `sentinel.config` 是字符串数组，每项一行直接追加到 conf 文件：

```yaml
redis:
  config:
    - "save 900 1"           # → 追加 "save 900 1" 到 redis.conf
    - "maxmemory 512mb"      # → 追加 "maxmemory 512mb" 到 redis.conf
```

**自动生成的配置**（无需手动添加）：
- redis.conf: `port`、`dir`、`daemonize`、`protected-mode`、`slave-announce-ip`、`requirepass`、`masterauth`
- sentinel.conf: `port`、`dir`、`daemonize`、`protected-mode`、`sentinel monitor`、`sentinel announce-ip`、`requirepass`、`sentinel auth-pass`

## 升级

```bash
# 修改 values 后升级
helm upgrade log ./helm/redis-sentinel -n redis -f my-values.yaml

# ConfigMap 变更会自动触发 Pod 滚动重启（通过 checksum 注解）
```

## 回滚

```bash
helm history log -n redis
helm rollback log 1 -n redis
```

## 卸载

```bash
helm uninstall log -n redis

# 注意: StatefulSet 的 PVC 不会被自动删除，需手动清理
kubectl -n redis delete pvc data-redis-saas-log-0 data-redis-saas-log-1 data-redis-saas-log-2
```

## 验证部署

```bash
# 查看 Pod 状态
kubectl -n redis get pods -l "app in (redis-saas-log,redis-saas-log-sentinel)"

# 查看 Service
kubectl -n redis get svc -l "app in (redis-saas-log,redis-saas-log-sentinel)"

# 验证 master
kubectl -n redis exec redis-saas-log-sentinel-0 -- redis-cli -p 26379 SENTINEL get-master-addr-by-name mymaster

# 验证 role-tagger 标签
kubectl -n redis get pods -l "app=redis-saas-log" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.labels.redis-role}{"\n"}{end}'
```
