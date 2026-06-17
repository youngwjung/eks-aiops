# Trace를 저장할 버킷
resource "aws_s3_bucket" "tempo" {
  bucket = "${local.account_id}-tempo-storage"

  force_destroy = true
}

# 위에서 생성한 버킷에 대한 접근 설정
resource "aws_iam_policy" "tempo_s3_access" {
  name = "tempo-s3-access"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "s3:ListBucket",
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:PutObject",
          "s3:GetObjectTagging",
          "s3:PutObjectTagging"
        ]
        Effect = "Allow"
        Resource = [
          aws_s3_bucket.tempo.arn,
          "${aws_s3_bucket.tempo.arn}/*"
        ]
      },
    ]
  })
}

# Tracing 스택을 설치할 네임스페이스
resource "kubernetes_namespace_v1" "tracing" {
  metadata {
    name = "tracing"
  }
}

# Tempo 컴포넌트에 부여할 IAM 역할
module "tempo_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.8.1"

  name = "tempo"

  additional_policy_arns = {
    s3_access = aws_iam_policy.tempo_s3_access.arn
  }

  associations = {
    "${kubernetes_namespace_v1.tracing.metadata[0].name}-tempo" = {
      cluster_name    = module.eks.cluster_name
      namespace       = kubernetes_namespace_v1.tracing.metadata[0].name
      service_account = "tempo"
      tags = {
        app = "${kubernetes_namespace_v1.tracing.metadata[0].name}-tempo"
      }
    }
  }

  depends_on = [
    aws_eks_addon.this["eks-pod-identity-agent"]
  ]
}

# Tempo
resource "helm_release" "tempo" {
  name       = "tempo"
  repository = "oci://ghcr.io/grafana-community/helm-charts"
  chart      = "tempo-distributed"
  version    = var.tempo_distributed_chart_version
  namespace  = kubernetes_namespace_v1.tracing.metadata[0].name

  values = [
    templatefile("${path.module}/helm-values/tempo.yaml", {
      s3_bucket   = aws_s3_bucket.tempo.bucket
      s3_endpoint = replace(aws_s3_bucket.tempo.bucket_regional_domain_name, "${aws_s3_bucket.tempo.bucket}.", "")
    })
  ]

  depends_on = [
    module.tempo_pod_identity,
    helm_release.kube_prometheus_stack
  ]
}

# Kubernetes Monitoring 스택
resource "helm_release" "k8s_monitoring_tracing" {
  name       = "k8s-monitoring-trace"
  repository = "oci://ghcr.io/grafana/helm-charts"
  chart      = "k8s-monitoring"
  version    = var.k8s_monitoring_chart_version
  namespace  = kubernetes_namespace_v1.tracing.metadata[0].name

  values = [
    templatefile("${path.module}/helm-values/k8s-monitoring-tracing.yaml", {
      cluster_name = var.project
    })
  ]

  depends_on = [
    helm_release.tempo
  ]
}