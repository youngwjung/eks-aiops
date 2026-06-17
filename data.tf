# 현재 Terraform을 실행하는 IAM 객체
data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
}

# 현재 설정된 AWS 리전에 있는 가용영역 정보 불러오기
data "aws_availability_zones" "azs" {}

locals {
  azs = slice(data.aws_availability_zones.azs.names, 0, min(4, length(data.aws_availability_zones.azs.names)))
}

# EKS 클러스터 인증 토큰
data "aws_eks_cluster_auth" "this" {
  name = module.eks.cluster_name
}

# Route53 호스트존
data "aws_route53_zone" "fitcloud" {
  provider = aws.youngwjung

  name = "fitcloud.click."
}

# ArgoCD 서버 HTTPRoute
data "kubernetes_resource" "argocd_server_httproute" {
  api_version = "gateway.networking.k8s.io/v1"
  kind        = "HTTPRoute"

  metadata {
    name      = "argocd-server"
    namespace = kubernetes_namespace_v1.argocd.metadata[0].name
  }

  depends_on = [ 
    helm_release.argocd
  ]
}