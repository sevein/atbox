{{- define "atbox.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "atbox.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "atbox.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | quote }}
app.kubernetes.io/name: {{ include "atbox.name" . | quote }}
app.kubernetes.io/instance: {{ .Release.Name | quote }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service | quote }}
{{- end -}}

{{- define "atbox.selectorLabels" -}}
app.kubernetes.io/name: {{ include "atbox.name" . | quote }}
app.kubernetes.io/instance: {{ .Release.Name | quote }}
{{- end -}}

{{- define "atbox.commonEnv" -}}
- name: ATOM_ELASTICSEARCH_HOST
  value: {{ .Values.external.elasticsearchHost | quote }}
- name: ATOM_MEMCACHED_HOST
  value: {{ .Values.external.memcachedHost | quote }}
- name: ATOM_NAMESPACE
  value: {{ .Values.atom.namespace | quote }}
- name: ATOM_CACHE_NAMESPACE
  value: {{ default .Values.atom.namespace .Values.atom.cacheNamespace | quote }}
- name: ATOM_MYSQL_DSN
  valueFrom:
    secretKeyRef:
      name: {{ include "atbox.fullname" . }}-database
      key: mysql-dsn
- name: ATOM_MYSQL_USERNAME
  valueFrom:
    secretKeyRef:
      name: {{ include "atbox.fullname" . }}-database
      key: mysql-username
- name: ATOM_MYSQL_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "atbox.fullname" . }}-database
      key: mysql-password
{{- end -}}

{{- define "atbox.podSecurityContext" -}}
securityContext:
  allowPrivilegeEscalation: false
  capabilities:
    drop:
      - NET_RAW
{{- end -}}
