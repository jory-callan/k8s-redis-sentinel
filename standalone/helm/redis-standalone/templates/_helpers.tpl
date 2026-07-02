{{/*
═══════════════════════════════════════════════════════════════
  Redis-Standalone Helm Chart — Helpers
═══════════════════════════════════════════════════════════════
*/}}

{{/*
  instanceName: 资源前缀, 用于多实例隔离
  优先级: common.instanceName > .Release.Name
*/}}
{{- define "redis-standalone.instanceName" -}}
{{- .Values.common.instanceName | default .Release.Name -}}
{{- end -}}

{{/*
  Redis Deployment / Pod / Service 名称
*/}}
{{- define "redis-standalone.redisName" -}}
{{- include "redis-standalone.instanceName" . -}}
{{- end -}}

{{/*
  Secret 名称 (existingSecret 优先)
*/}}
{{- define "redis-standalone.secretName" -}}
{{- if .Values.common.auth.existingSecret -}}
{{- .Values.common.auth.existingSecret -}}
{{- else -}}
{{- include "redis-standalone.instanceName" . -}}-secret
{{- end -}}
{{- end -}}

{{/*
  Backup Secret 名称 (existingSecret 优先)
*/}}
{{- define "redis-standalone.backupSecretName" -}}
{{- if .Values.backup.existingSecret -}}
{{- .Values.backup.existingSecret -}}
{{- else -}}
{{- include "redis-standalone.instanceName" . -}}-backup-secret
{{- end -}}
{{- end -}}

{{/*
  ConfigMap 名称
*/}}
{{- define "redis-standalone.configMapName" -}}
{{- include "redis-standalone.instanceName" . -}}-config
{{- end -}}

{{/*
  PVC 名称 (独立 PVC 资源, Deployment 引用)
  注: Deployment 不支持 volumeClaimTemplates, 需单独创建 PVC
*/}}
{{- define "redis-standalone.pvcName" -}}
{{- include "redis-standalone.instanceName" . -}}-data
{{- end -}}

{{/*
  通用 labels
  注意: app.kubernetes.io/* 是 Helm 标准 label, 但不能直接用作 Service/NetPol/PDB
  的 selector —— 因为别的 chart 也可能有同名 instance. 为彻底隔离, 额外引入
  chart 专属 label (与 redis-sentinel chart 前缀不同, 两者可同集群混部):
    redis-standalone.k8s.io/chart:     chart 标识 (固定值, 区分本 chart 与其他应用)
    redis-standalone.k8s.io/instance:  实例名 (区分同 chart 多实例)
  下面 redisLabels 会再加 component label, 让 selector 3 维匹配.
*/}}
{{- define "redis-standalone.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: redis-standalone
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
redis-standalone.k8s.io/chart: redis-standalone
redis-standalone.k8s.io/instance: {{ include "redis-standalone.instanceName" . }}
{{- end -}}

{{/*
  Redis Pod labels
  component=redis 与 instance 组成 selector 唯一锁定本实例的 redis pod,
  不会与集群内任何其他 chart/应用误匹配.
*/}}
{{- define "redis-standalone.redisLabels" -}}
{{ include "redis-standalone.labels" . }}
app: {{ include "redis-standalone.redisName" . }}
redis-standalone.k8s.io/component: redis
{{- end -}}

{{/*
  Redis selector labels (Deployment/Service/NetPol/PDB 用)
  3 维匹配, 彻底隔离: chart + instance + component
*/}}
{{- define "redis-standalone.redisSelectorLabels" -}}
redis-standalone.k8s.io/chart: redis-standalone
redis-standalone.k8s.io/instance: {{ include "redis-standalone.instanceName" . }}
redis-standalone.k8s.io/component: redis
{{- end -}}

{{/*
  Backup pod labels (CronJob pod template)
  component=backup 让 NetworkPolicy 6379 ingress 规则能识别并放行 backup pod 访问.
*/}}
{{- define "redis-standalone.backupLabels" -}}
{{ include "redis-standalone.labels" . }}
app: {{ include "redis-standalone.redisName" . }}
redis-standalone.k8s.io/component: backup
{{- end -}}

{{/*
  Backup selector labels (NetworkPolicy 用, 放行 backup pod 访问 redis:6379)
*/}}
{{- define "redis-standalone.backupSelectorLabels" -}}
redis-standalone.k8s.io/chart: redis-standalone
redis-standalone.k8s.io/instance: {{ include "redis-standalone.instanceName" . }}
redis-standalone.k8s.io/component: backup
{{- end -}}

{{/*
  Redis 镜像引用
*/}}
{{- define "redis-standalone.redisImage" -}}
{{- printf "%s:%s" .Values.redis.image.repository .Values.redis.image.tag -}}
{{- end -}}

{{/*
  Redis Exporter 镜像引用
*/}}
{{- define "redis-standalone.redisExporterImage" -}}
{{- printf "%s:%s" .Values.redis.exporter.image.repository .Values.redis.exporter.image.tag -}}
{{- end -}}

{{/*
  PING 探针命令 (带可选密码)
  Redis 6.2 redis-cli 兼容 -a (避免在进程列表泄露密码用 2>/dev/null 抑制警告)
*/}}
{{- define "redis-standalone.pingProbe" -}}
- sh
- -c
- |
  P="${REDIS_PASSWORD:-}"
  if [ -n "$P" ]; then redis-cli -a "$P" PING 2>/dev/null; else redis-cli PING 2>/dev/null; fi | grep -q PONG
{{- end -}}
