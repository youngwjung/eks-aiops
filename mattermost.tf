# S3 버킷
resource "aws_s3_bucket" "mattermost" {
  bucket = "${local.account_id}-mattermost-storage"

  force_destroy = true
}

# 위에서 생성한 버킷에 대한 접근 설정
resource "aws_iam_policy" "mattermost_s3_access" {
  name = "mattermost-s3-access"

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
          aws_s3_bucket.mattermost.arn,
          "${aws_s3_bucket.mattermost.arn}/*"
        ]
      },
    ]
  })
}

# Postgres 인스턴스에 부여할 보안그룹
module "mattermost_postgres_sg" {
  source  = "terraform-aws-modules/security-group/aws//modules/postgresql"
  version = "6.0.0"

  name        = "mattermost-rds-sg"
  description = "mattermost rds security group"
  vpc_id      = module.vpc.vpc_id

  ingress_referenced_security_group_id = {
    eks = module.eks.cluster_primary_security_group_id
  }
}

# Postgres 인스턴스
module "mattermost_postgres" {
  source  = "terraform-aws-modules/rds/aws"
  version = "7.2.0"

  identifier            = "mattermost"
  engine                = "postgres"
  engine_version        = "18.3"
  instance_class        = "db.t4g.micro"
  storage_type          = "gp3"
  allocated_storage     = 20
  max_allocated_storage = 100

  # 보안
  username               = "db_admin"
  vpc_security_group_ids = [module.mattermost_postgres_sg.id]

  # DB subnet group
  create_db_subnet_group = true
  subnet_ids             = module.vpc.database_subnets

  # DB parameter group
  family = "postgres18"

  # DB 변경사항을 바로 반영
  apply_immediately = true

  # 삭제시 스냅샷 저장하지 않음
  skip_final_snapshot = true
}

# Postgres 인증 정보
data "aws_secretsmanager_secret" "mattermost_postgres" {
  arn = module.mattermost_postgres.db_instance_master_user_secret_arn
}

data "aws_secretsmanager_secret_version" "mattermost_postgres" {
  secret_id = data.aws_secretsmanager_secret.mattermost_postgres.id
}

resource "kubernetes_job_v1" "mattermost_init_db" {
  metadata {
    name      = "init-db"
    namespace = kubernetes_namespace_v1.mattermost.metadata[0].name
  }

  spec {
    template {
      metadata {
        name = "init-db"
      }
      spec {
        container {
          name    = "postgres-client"
          image   = "postgres:alpine"
          command = ["/bin/sh", "-c"]
          args = [
            <<-EOF
            export PGPASSWORD=$DB_PASSWORD
            psql -h $DB_HOST -U $DB_USER -d postgres -c "CREATE DATABASE mattermost;" || echo "Database 'mattermost' creation failed or already exists. Continuing..."
            EOF
          ]

          env {
            name  = "DB_HOST"
            value = module.mattermost_postgres.db_instance_address
          }
          env {
            name  = "DB_USER"
            value = jsondecode(data.aws_secretsmanager_secret_version.mattermost_postgres.secret_string)["username"]
          }
          env {
            name  = "DB_PASSWORD"
            value = jsondecode(data.aws_secretsmanager_secret_version.mattermost_postgres.secret_string)["password"]
          }
        }
        restart_policy = "OnFailure"
      }
    }
  }

  wait_for_completion = true

  timeouts {
    create = "5m"
  }

  depends_on = [
    module.mattermost_postgres,
    kubernetes_job_v1.karpenter_node_warmup
  ]
}

# Mattermost를 배포할 네임 스페이스
resource "kubernetes_namespace_v1" "mattermost" {
  metadata {
    name = "mattermost"
  }
}

# Mattermost에 부여할 IAM 역할
module "mattermost_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.6.1"

  name = "${module.eks.cluster_name}-cluster-mattermost-role"

  policies = {
    mattermost_s3_access = aws_iam_policy.mattermost_s3_access.arn
  }
  create_policy = false

  oidc_providers = {
    mattermost = {
      provider_arn = module.eks.oidc_provider_arn
      namespace_service_accounts = [
        "mattermost-operator:mattermost"
      ]
    }
  }
}

# Mattermost에서 사용할 DB 연결 정보
locals {
  mattermost_postgres_url      = module.mattermost_postgres.db_instance_address
  mattermost_postgres_user     = jsondecode(data.aws_secretsmanager_secret_version.mattermost_postgres.secret_string)["username"]
  mattermost_postgres_password = jsondecode(data.aws_secretsmanager_secret_version.mattermost_postgres.secret_string)["password"]
}

resource "kubernetes_secret_v1" "mattermost_postgresql_connection_string" {
  metadata {
    name      = "mattermost-postgresql-connection-string"
    namespace = kubernetes_namespace_v1.mattermost.metadata[0].name
  }

  data = {
    DB_CONNECTION_STRING = "postgres://${local.mattermost_postgres_user}:${urlencode(local.mattermost_postgres_password)}@${local.mattermost_postgres_url}:5432/mattermost?sslmode=require"
  }
}

# Mattermost에서 사용할 ServiceAccount
resource "kubernetes_service_account_v1" "mattermost" {
  metadata {
    name      = "mattermost"
    namespace = kubernetes_namespace_v1.mattermost.metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = module.mattermost_irsa.arn
    }
  }
}

# Mattermost Operator
resource "helm_release" "mattermost_operator" {
  name       = "mattermost-operator"
  repository = "https://helm.mattermost.com"
  chart      = "mattermost-operator"
  version    = var.mattermost_operator_chart_version
  namespace  = kubernetes_namespace_v1.mattermost.metadata[0].name

  values = [
    templatefile("${path.module}/helm-values/mattermost.yaml", {
      bucket_name                      = aws_s3_bucket.mattermost.bucket
      bucket_endpoint                  = replace(aws_s3_bucket.mattermost.bucket_regional_domain_name, "${aws_s3_bucket.mattermost.bucket}.", "")
      db_connection_string_secret_name = kubernetes_secret_v1.mattermost_postgresql_connection_string.metadata[0].name
    })
  ]

  depends_on = [
    kubernetes_job_v1.mattermost_init_db,
    kubernetes_service_account_v1.mattermost,
    kubectl_manifest.karpenter_default_nodepool,
    kubectl_manifest.envoy_proxy
  ]
}

resource "kubectl_manifest" "mattermost_httproute" {
  yaml_body = <<-YAML
    apiVersion: gateway.networking.k8s.io/v1
    kind: HTTPRoute
    metadata:
      name: mattermost
      namespace: ${kubernetes_namespace_v1.mattermost.metadata[0].name}
    spec:
      parentRefs:
      - name: ${local.envoy_gateway_name}
        namespace: ${local.envoy_gateway_namespace}
        sectionName: ${local.envoy_gateway_listener}
      hostnames:
      - mattermost.${aws_route53_zone.this.name}
      rules:
      - matches:
        - path:
            type: PathPrefix
            value: /
        backendRefs:
        - name: mattermost
          port: 8065
  YAML

  wait = true

  depends_on = [
    helm_release.mattermost_operator
  ]
}