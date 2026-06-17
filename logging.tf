# 로그를 저장할 버킷
resource "aws_s3_bucket" "loki" {
  bucket = "${local.account_id}-loki-storage"

  force_destroy = true
}

# 위에서 생성한 버킷에 대한 접근 설정
resource "aws_iam_policy" "loki_s3_access" {
  name = "loki-s3-access"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "s3:ListBucket",
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:PutObject"
        ]
        Effect = "Allow"
        Resource = [
          aws_s3_bucket.loki.arn,
          "${aws_s3_bucket.loki.arn}/*"
        ]
      },
    ]
  })
}

# 로깅 스택을 설치할 네임스페이스
resource "kubernetes_namespace_v1" "logging" {
  metadata {
    name = "logging"
  }
}

# Loki 컴포넌트에 부여할 IAM 역할
module "loki_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.8.1"

  name = "loki"

  additional_policy_arns = {
    s3_access = aws_iam_policy.loki_s3_access.arn
  }

  associations = {
    "${kubernetes_namespace_v1.logging.metadata[0].name}-loki" = {
      cluster_name    = module.eks.cluster_name
      namespace       = kubernetes_namespace_v1.logging.metadata[0].name
      service_account = "loki"
      tags = {
        app = "${kubernetes_namespace_v1.logging.metadata[0].name}-loki"
      }
    }
  }

  depends_on = [
    aws_eks_addon.this["eks-pod-identity-agent"]
  ]
}

# Loki
resource "helm_release" "loki" {
  name       = "loki"
  repository = "oci://ghcr.io/grafana-community/helm-charts"
  chart      = "loki"
  version    = var.loki_chart_version
  namespace  = kubernetes_namespace_v1.logging.metadata[0].name

  values = [
    templatefile("${path.module}/helm-values/loki.yaml", {
      s3_bucket        = aws_s3_bucket.loki.bucket
      s3_bucket_region = aws_s3_bucket.loki.bucket_region
    })
  ]

  depends_on = [
    module.loki_pod_identity,
    helm_release.kube_prometheus_stack
  ]
}

# Kubernetes Monitoring 스택
resource "helm_release" "k8s_monitoring_logging" {
  name       = "k8s-monitoring-log"
  repository = "oci://ghcr.io/grafana/helm-charts"
  chart      = "k8s-monitoring"
  version    = var.k8s_monitoring_chart_version
  namespace  = kubernetes_namespace_v1.logging.metadata[0].name

  values = [
    templatefile("${path.module}/helm-values/k8s-monitoring-logging.yaml", {
      cluster_name = var.project
    })
  ]

  depends_on = [
    helm_release.loki
  ]
}