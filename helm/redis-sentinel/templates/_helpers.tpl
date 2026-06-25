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
*/}}
{{- define "redis-sentinel.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: redis-sentinel
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end -}}

{{/*
  Redis Pod labels
*/}}
{{- define "redis-sentinel.redisLabels" -}}
{{ include "redis-sentinel.labels" . }}
app: {{ include "redis-sentinel.redisName" . }}
redis-role: slave
{{- end -}}

{{/*
  Sentinel Pod labels
*/}}
{{- define "redis-sentinel.sentinelLabels" -}}
{{ include "redis-sentinel.labels" . }}
app: {{ include "redis-sentinel.sentinelName" . }}
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
