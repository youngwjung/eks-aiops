# 모니터링 스택을 설치할 네임스페이스
resource "kubernetes_namespace_v1" "monitoring" {
  metadata {
    name = "monitoring"
  }

  depends_on = [
    aws_eks_addon.this["aws-ebs-csi-driver"]
  ]
}

resource "helm_release" "prometheus_operator_crds" {
  name       = "prometheus-operator-crds"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "prometheus-operator-crds"
  version    = var.prometheus_operator_crds_chart_version
}

# Thanos 사이드카에서 Prometheus 지표를 보낼 버킷
resource "aws_s3_bucket" "thanos" {
  bucket = "${local.account_id}-thanos-storage"

  force_destroy = true
}

# 위에서 생성한 버킷에 대한 접근 설정
resource "aws_iam_policy" "thanos_s3_access" {
  name = "thanos-s3-access"

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
          aws_s3_bucket.thanos.arn,
          "${aws_s3_bucket.thanos.arn}/*"
        ]
      },
    ]
  })
}

# Thanos 컴포넌트에 부여할 IAM 역할
module "thanos_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.8.1"

  name = "thanos"

  additional_policy_arns = {
    s3_access = aws_iam_policy.thanos_s3_access.arn
  }

  associations = {
    "${kubernetes_namespace_v1.monitoring.metadata[0].name}-promethes" = {
      cluster_name    = module.eks.cluster_name
      namespace       = kubernetes_namespace_v1.monitoring.metadata[0].name
      service_account = "prometheus-prometheus"
      tags = {
        app = "${kubernetes_namespace_v1.monitoring.metadata[0].name}-prometheus"
      }
    }
    "${kubernetes_namespace_v1.monitoring.metadata[0].name}-thanos-thanos" = {
      cluster_name    = module.eks.cluster_name
      namespace       = kubernetes_namespace_v1.monitoring.metadata[0].name
      service_account = "thanos-thanos"
      tags = {
        app = "${kubernetes_namespace_v1.monitoring.metadata[0].name}-thanos-thanos"
      }
    }
  }

  depends_on = [
    aws_eks_addon.this["eks-pod-identity-agent"]
  ]
}

# Thanos 사이드카 설정 파일 (https://thanos.io/tip/thanos/storage.md/#s3)
resource "kubernetes_secret_v1" "prometheus_object_store_config" {
  metadata {
    name      = "thanos-objstore-config"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
  }

  data = {
    "thanos.yml" = yamlencode({
      type = "s3"
      config = {
        bucket   = aws_s3_bucket.thanos.bucket
        endpoint = replace(aws_s3_bucket.thanos.bucket_regional_domain_name, "${aws_s3_bucket.thanos.bucket}.", "")
      }
    })
  }
}

# Kube-prometheus-stack
resource "helm_release" "kube_prometheus_stack" {
  name       = "prometheus"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = var.kube_prometheus_stack_chart_version
  namespace  = kubernetes_namespace_v1.monitoring.metadata[0].name
  skip_crds  = true
  timeout    = 900

  values = [
    templatefile("${path.module}/helm-values/kube-prometheus-stack.yaml", {
      cluster_name                 = var.project
      alertmanager_hostname        = "alertmanager.${aws_route53_zone.this.name}"
      grafana_hostname             = "grafana.${aws_route53_zone.this.name}"
      thanos_hostname              = "thanos.${aws_route53_zone.this.name}"
      thanos_objconfig_secret_name = kubernetes_secret_v1.prometheus_object_store_config.metadata[0].name
      gateway_name                 = local.envoy_gateway_name
      gateway_namespace            = local.envoy_gateway_namespace
      gateway_listener             = local.envoy_gateway_listener
    })
  ]

  depends_on = [
    helm_release.prometheus_operator_crds,
    module.thanos_pod_identity,
    kubernetes_storage_class_v1.ebs
  ]
}

# Thanos 컴포넌트에서 사용할 오브젝트 스토리지 (S3) 설정 파일
resource "kubernetes_secret_v1" "thanos_object_store_config" {
  metadata {
    name      = "objstore-config"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
  }

  data = {
    "objstore.yml" = yamlencode({
      type = "s3"
      config = {
        bucket   = aws_s3_bucket.thanos.bucket
        endpoint = replace(aws_s3_bucket.thanos.bucket_regional_domain_name, "${aws_s3_bucket.thanos.bucket}.", "")
      }
    })
  }
}

# Thanos
resource "helm_release" "thanos" {
  name       = "thanos"
  repository = "oci://ghcr.io/thanos-community/helm-charts"
  chart      = "thanos"
  version    = var.thanos_chart_version
  namespace  = kubernetes_namespace_v1.monitoring.metadata[0].name

  values = [
    templatefile("${path.module}/helm-values/thanos.yaml", {
      query_hostname               = "thanos.${aws_route53_zone.this.name}"
      thanos_objconfig_secret_name = kubernetes_secret_v1.thanos_object_store_config.metadata[0].name
      gateway_name                 = local.envoy_gateway_name
      gateway_namespace            = local.envoy_gateway_namespace
      gateway_listener             = local.envoy_gateway_listener
    })
  ]

  depends_on = [
    helm_release.kube_prometheus_stack,
    module.thanos_pod_identity,
    kubernetes_storage_class_v1.ebs
  ]
}