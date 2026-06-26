{{/*
═══════════════════════════════════════════════════════════════
  Redis-Sentinel Helm Chart — Helpers
═══════════════════════════════════════════════════════════════
*/}}

{{/*
  instanceName: 资源前缀, 用于多实例隔离
  优先级: common.instanceName > .Release.Name
*/}}
{{- define "redis-sentinel.instanceName" -}}
{{- .Values.common.instanceName | default .Release.Name -}}
{{- end -}}

{{/*
  Redis StatefulSet / Pod / Service 名称
*/}}
{{- define "redis-sentinel.redisName" -}}
{{- include "redis-sentinel.instanceName" . -}}
{{- end -}}

{{/*
  Sentinel StatefulSet / Pod / Service 名称
*/}}
{{- define "redis-sentinel.sentinelName" -}}
{{- include "redis-sentinel.instanceName" . -}}-sentinel
{{- end -}}

{{/*
  Headless Service 名称 (Redis)
*/}}
{{- define "redis-sentinel.redisHl" -}}
{{- include "redis-sentinel.instanceName" . -}}-hl
{{- end -}}

{{/*
  Headless Service 名称 (Sentinel)
*/}}
{{- define "redis-sentinel.sentinelHl" -}}
{{- include "redis-sentinel.sentinelName" . -}}-hl
{{- end -}}

{{/*
  Secret 名称 (existingSecret 优先)
*/}}
{{- define "redis-sentinel.secretName" -}}
{{- if .Values.common.auth.existingSecret -}}
{{- .Values.common.auth.existingSecret -}}
{{- else -}}
{{- include "redis-sentinel.instanceName" . -}}-secret
{{- end -}}
{{- end -}}

{{/*
  Backup Secret 名称 (existingSecret 优先)
*/}}
{{- define "redis-sentinel.backupSecretName" -}}
{{- if .Values.backup.existingSecret -}}
{{- .Values.backup.existingSecret -}}
{{- else -}}
{{- include "redis-sentinel.instanceName" . -}}-backup-secret
{{- end -}}
{{- end -}}

{{/*
  通用 labels
  注意: app.kubernetes.io/* 是 Helm 标准 label, 但不能直接用作 Service/NetPol/PDB
  的 selector —— 因为别的 chart 也可能有同名 instance (如另一个 redis chart 用了
  同 release name). 为彻底隔离, 额外引入 chart 专属 label:
    redis-sentinel.k8s.io/chart:     chart 标识 (固定值, 区分本 chart 与其他应用)
    redis-sentinel.k8s.io/instance:  实例名 (区分同 chart 多实例)
  下面 redisLabels/sentinelLabels 会再加 component label, 让 selector 4 维匹配.
*/}}
{{- define "redis-sentinel.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: redis-sentinel
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
redis-sentinel.k8s.io/chart: redis-sentinel
redis-sentinel.k8s.io/instance: {{ include "redis-sentinel.instanceName" . }}
{{- end -}}

{{/*
  Redis Pod labels
  component=redis 与 instance 组成 selector 唯一锁定本实例的 redis pod,
  不会与集群内任何其他 chart/应用误匹配.
  redis-role 由 role-tagger sidecar 动态维护 (master|slave), 仅用于 master Service 流量路由.
*/}}
{{- define "redis-sentinel.redisLabels" -}}
{{ include "redis-sentinel.labels" . }}
app: {{ include "redis-sentinel.redisName" . }}
redis-sentinel.k8s.io/component: redis
redis-role: slave
{{- end -}}

{{/*
  Sentinel Pod labels
*/}}
{{- define "redis-sentinel.sentinelLabels" -}}
{{ include "redis-sentinel.labels" . }}
app: {{ include "redis-sentinel.sentinelName" . }}
redis-sentinel.k8s.io/component: sentinel
{{- end -}}

{{/*
  Redis selector labels (StatefulSet/Service/NetPol/PDB 用)
  4 维匹配, 彻底隔离: chart + instance + component
*/}}
{{- define "redis-sentinel.redisSelectorLabels" -}}
redis-sentinel.k8s.io/chart: redis-sentinel
redis-sentinel.k8s.io/instance: {{ include "redis-sentinel.instanceName" . }}
redis-sentinel.k8s.io/component: redis
{{- end -}}

{{/*
  Sentinel selector labels
*/}}
{{- define "redis-sentinel.sentinelSelectorLabels" -}}
redis-sentinel.k8s.io/chart: redis-sentinel
redis-sentinel.k8s.io/instance: {{ include "redis-sentinel.instanceName" . }}
redis-sentinel.k8s.io/component: sentinel
{{- end -}}

{{/*
  Backup pod labels (CronJob pod template)
  component=backup 让 NetworkPolicy 6379 ingress 规则能识别并放行 backup pod 访问 master.
  backup pod 不是 redis/slave, 所以不用 redisSelectorLabels, 而是用独立的 backup selector.
*/}}
{{- define "redis-sentinel.backupLabels" -}}
{{ include "redis-sentinel.labels" . }}
app: {{ include "redis-sentinel.redisName" . }}
redis-sentinel.k8s.io/component: backup
{{- end -}}

{{/*
  Backup selector labels (NetworkPolicy 用, 放行 backup pod 访问 master:6379)
*/}}
{{- define "redis-sentinel.backupSelectorLabels" -}}
redis-sentinel.k8s.io/chart: redis-sentinel
redis-sentinel.k8s.io/instance: {{ include "redis-sentinel.instanceName" . }}
redis-sentinel.k8s.io/component: backup
{{- end -}}

{{/*
  Redis 镜像引用
*/}}
{{- define "redis-sentinel.redisImage" -}}
{{- printf "%s:%s" .Values.redis.image.repository .Values.redis.image.tag -}}
{{- end -}}

{{/*
  Sentinel 镜像引用
*/}}
{{- define "redis-sentinel.sentinelImage" -}}
{{- printf "%s:%s" .Values.sentinel.image.repository .Values.sentinel.image.tag -}}
{{- end -}}

{{/*
  Redis Exporter 镜像引用
*/}}
{{- define "redis-sentinel.redisExporterImage" -}}
{{- printf "%s:%s" .Values.redis.exporter.image.repository .Values.redis.exporter.image.tag -}}
{{- end -}}

{{/*
  Sentinel Exporter 镜像引用
*/}}
{{- define "redis-sentinel.sentinelExporterImage" -}}
{{- printf "%s:%s" .Values.sentinel.exporter.image.repository .Values.sentinel.exporter.image.tag -}}
{{- end -}}

{{/*
  role-tagger 镜像引用
*/}}
{{- define "redis-sentinel.roleTaggerImage" -}}
{{- printf "%s:%s" .Values.redis.roleTagger.image.repository .Values.redis.roleTagger.image.tag -}}
{{- end -}}

{{/*
  PING 探针命令 (带可选密码)
*/}}
{{- define "redis-sentinel.pingProbe" -}}
- sh
- -c
- |
  P="${REDIS_PASSWORD:-}"
  if [ -n "$P" ]; then redis-cli -a "$P" PING 2>/dev/null; else redis-cli PING 2>/dev/null; fi | grep -q PONG
{{- end -}}

{{/*
  Sentinel PING 探针命令 (带可选密码)
*/}}
{{- define "redis-sentinel.sentinelPingProbe" -}}
- sh
- -c
- |
  P="${REDIS_PASSWORD:-}"
  if [ -n "$P" ]; then redis-cli -a "$P" -p 26379 PING 2>/dev/null; else redis-cli -p 26379 PING 2>/dev/null; fi | grep -q PONG
{{- end -}}

{{/*
  Sentinel readiness 探针 (检查 master 可达)
*/}}
{{- define "redis-sentinel.sentinelReadinessProbe" -}}
- sh
- -c
- |
  P="${REDIS_PASSWORD:-}"
  if [ -n "$P" ]; then M=$(redis-cli -a "$P" -p 26379 SENTINEL get-master-addr-by-name mymaster 2>/dev/null); else M=$(redis-cli -p 26379 SENTINEL get-master-addr-by-name mymaster 2>/dev/null); fi
  echo "$M" | head -1 | grep -qv "^nil$" && [ -n "$M" ]
{{- end -}}
