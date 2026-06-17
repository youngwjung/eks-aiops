variable "project" {
  description = "프로젝트 이름"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC 대역대"
  type        = string
  default     = "10.0.0.0/16"
}

variable "eks_cluster_version" {
  description = "EKS 클러스터 버전"
  type        = string
}

variable "prometheus_operator_crds_chart_version" {
  description = "Prometheus Operator CRD Helm 차트 버전 "
  type        = string
}

variable "karpenter_chart_version" {
  description = "Karpenter Helm 차트 버전"
  type        = string
}

variable "aws_load_balancer_controller_chart_version" {
  description = "AWS Load Balancer Controller Helm 차트 버전"
  type        = string
}

variable "envoy_gateway_chart_version" {
  description = "Envoy Gateway Helm 차트 버전"
  type        = string
}


variable "kube_prometheus_stack_chart_version" {
  description = "Kube-prometheus-stack Helm 차트 버전 "
  type        = string
}

variable "thanos_chart_version" {
  description = "Thanos Helm 차트 버전 "
  type        = string
}

variable "loki_chart_version" {
  description = "Loki Helm 차트 버전 "
  type        = string
}

variable "k8s_monitoring_chart_version" {
  description = "Kubernetes Monitoring 스택 Helm 차트 버전 "
  type        = string
}

variable "tempo_distributed_chart_version" {
  description = "Tempo Helm 차트 버전 "
  type        = string
}

variable "gitlab_chart_version" {
  description = "GitLab Helm 차트 버전 "
  type        = string
}

variable "argocd_chart_version" {
  description = "ArgoCD Helm 차트 버전 "
  type        = string
}

variable "mattermost_operator_chart_version" {
  description = "Mattermost Operator Helm 차트 버전"
  type        = string
}