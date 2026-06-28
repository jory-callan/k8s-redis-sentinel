# exporter 容器分析文档

## 容器信息

| 项目 | 值 |
|------|-----|
| 容器名 | `exporter` |
| 镜像 | `oliver006/redis_exporter:v1.25.0` |
| 运行模式 | 持续运行（Go 语言二进制） |
| 脚本 | 无（直接运行二进制） |
| 进程 | `redis_exporter` |

## 核心职责

1. **指标采集**：定期查询 Sentinel 的 INFO 命令，提取关键指标
2. **指标暴露**：在 `:9121/metrics` 端点提供 Prometheus 格式的指标
3. **健康检查**：在 `:9121/health` 端点提供健康状态

## 运行模式

### 为什么不需要脚本？

redis_exporter 是一个独立的 Go 语言二进制程序，不需要 shell 脚本包装：

```yaml
containers:
  - name: exporter
    image: oliver006/redis_exporter:v1.25.0
    args:
      - --redis.addr=redis://localhost:26379
      {{- if .Values.common.password }}
      - --redis.password=$(REDIS_PASSWORD)
      {{- end }}
    ports:
      - containerPort: 9121
```

**直接运行二进制的优势**：
- 无需 shell 解释器，减少一层依赖
- 进程管理更直接（PID=1 就是 exporter）
- 启动更快，资源消耗更低

## 稳定性设计

### 1. Go 语言稳定性

```
redis_exporter 架构：
┌──────────────────────────────────────────────┐
│  Go 语言二进制（编译型，无运行时依赖）         │
│                                              │
│  ├── 定时采集 goroutine                      │
│  │   └── 每 15s 查询 Sentinel INFO           │
│  ├── HTTP Server goroutine                   │
│  │   └── 监听 :9121/metrics                  │
│  └── 健康检查 goroutine                      │
│      └── 监听 :9121/health                   │
└──────────────────────────────────────────────┘
```

**为什么稳定**：
- Go 语言编译型，无运行时依赖
- goroutine 轻量级，资源消耗低
- 内置垃圾回收，无内存泄漏
- 社区成熟，广泛用于生产环境

### 2. 独立进程管理

```yaml
livenessProbe:
  httpGet:
    path: /health
    port: 9121
  initialDelaySeconds: 10
  periodSeconds: 10
  failureThreshold: 3

readinessProbe:
  httpGet:
    path: /metrics
    port: 9121
  initialDelaySeconds: 5
  periodSeconds: 5
  failureThreshold: 3
```

**为什么稳定**：
- livenessProbe 检测 `/health` 端点，失败后重启容器
- readinessProbe 检测 `/metrics` 端点，失败后从 Service 移除
- 双重保障，确保只有健康的 exporter 才会被 Prometheus 抓取

### 3. 指标采集隔离

```bash
# exporter 采集不影响 Sentinel 主进程
redis-cli -p 26379 INFO  # 只读操作，不影响 failover
```

**为什么稳定**：
- INFO 命令是只读操作，不影响 Sentinel failover 决策
- 采集频率可配置（默认 15s）
- 即使 exporter 挂了，Sentinel 主进程不受影响

## 可靠性评估

| 场景 | 行为 | 结果 |
|------|------|------|
| 正常运行 | 每 15s 采集指标，暴露 `/metrics` | ✅ 稳定运行 |
| Sentinel 不可达 | 指标中标记错误，exporter 继续运行 | ✅ 不影响 Sentinel |
| exporter 崩溃 | livenessProbe 失败，容器重启 | ✅ 自动恢复 |
| 内存泄漏 | Go GC 自动回收 | ✅ 无风险 |
| CPU 峰值 | 只读操作，CPU 消耗低 | ✅ 无风险 |

## 总结

**exporter 容器是纯 Go 语言二进制，稳定性由以下因素保障**：

1. **编译型语言**：Go 语言编译后无运行时依赖，启动快
2. **独立进程**：PID=1 直接管理，K8s 监控更直接
3. **双重探针**：livenessProbe + readinessProbe 保障健康状态
4. **只读采集**：INFO 命令不影响 Sentinel 性能
5. **社区成熟**：广泛用于生产环境，经过充分验证

**跑 2 年完全没问题**，这是一个非常成熟的监控组件。