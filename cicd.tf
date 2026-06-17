# S3 버킷
resource "aws_s3_bucket" "gitlab" {
  bucket = "${local.account_id}-gitlab-storage"

  force_destroy = true
}

# 위에서 생성한 버킷에 대한 접근 설정
resource "aws_iam_policy" "gitlab_s3_access" {
  name = "gitlab-s3-access"

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
          aws_s3_bucket.gitlab.arn,
          "${aws_s3_bucket.gitlab.arn}/*"
        ]
      },
    ]
  })
}

# Postgres 인스턴스에 부여할 보안그룹
module "gitlab_postgres_sg" {
  source  = "terraform-aws-modules/security-group/aws//modules/postgresql"
  version = "6.0.0"

  name        = "gitlab-rds-sg"
  description = "gitlab rds security group"
  vpc_id      = module.vpc.vpc_id

  ingress_referenced_security_group_id = {
    eks = module.eks.cluster_primary_security_group_id
  }
}

# Postgres 인스턴스
module "gitlab_postgres" {
  source  = "terraform-aws-modules/rds/aws"
  version = "7.2.0"

  identifier            = "gitlab"
  engine                = "postgres"
  engine_version        = "18.3"
  instance_class        = "db.t4g.micro"
  storage_type          = "gp3"
  allocated_storage     = 20
  max_allocated_storage = 100

  # 보안
  username               = "db_admin"
  vpc_security_group_ids = [module.gitlab_postgres_sg.id]

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
data "aws_secretsmanager_secret" "gitlab_postgres" {
  arn = module.gitlab_postgres.db_instance_master_user_secret_arn
}

data "aws_secretsmanager_secret_version" "gitlab_postgres" {
  secret_id = data.aws_secretsmanager_secret.gitlab_postgres.id
}

# Redis 인스턴스에 부여할 보안그룹
module "gitlab_redis_sg" {
  source  = "terraform-aws-modules/security-group/aws//modules/redis"
  version = "6.0.0"

  name        = "gitlab-redis-sg"
  description = "gitlab redis security group"
  vpc_id      = module.vpc.vpc_id

  ingress_referenced_security_group_id = {
    eks = module.eks.cluster_primary_security_group_id
  }
}

# Redis 인스턴스
module "gitlab_redis" {
  source  = "terraform-aws-modules/elasticache/aws"
  version = "1.10.3"

  replication_group_id = "gitlab"
  engine               = "valkey"
  engine_version       = "8.0"
  node_type            = "cache.t4g.micro"


  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.database_subnets
  security_group_ids = [
    module.gitlab_redis_sg.id
  ]

  create_parameter_group = true
  parameter_group_family = "valkey8"

  log_delivery_configuration = {}
  transit_encryption_mode    = "preferred"

  apply_immediately = true
}

# GitLab을 설치할 네임스페이스
resource "kubernetes_namespace_v1" "gitlab" {
  metadata {
    name = "gitlab"
  }

  depends_on = [
    aws_eks_addon.this["aws-ebs-csi-driver"]
  ]
}

# IAM 권한
module "gitlab_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.8.1"

  name = "gitlab"

  additional_policy_arns = {
    s3_access = aws_iam_policy.gitlab_s3_access.arn
  }

  associations = {
    (module.eks.cluster_name) = {
      cluster_name    = module.eks.cluster_name
      namespace       = kubernetes_namespace_v1.gitlab.metadata[0].name
      service_account = "gitlab"
      tags = {
        app = "gitlab"
      }
    }
  }

  depends_on = [
    aws_eks_addon.this["eks-pod-identity-agent"]
  ]
}

# Postgres 패스워드를 저장할 Secret
resource "kubernetes_secret_v1" "gitlab_postgres" {
  metadata {
    name      = "gitlab-postgres"
    namespace = kubernetes_namespace_v1.gitlab.metadata[0].name
  }

  data = {
    password = jsondecode(data.aws_secretsmanager_secret_version.gitlab_postgres.secret_string)["password"]
  }

  type = "kubernetes.io/basic-auth"
}

# S3 연결 정보
resource "kubernetes_secret_v1" "gitlab_s3_connection" {
  metadata {
    name      = "gitlab-s3-connection"
    namespace = kubernetes_namespace_v1.gitlab.metadata[0].name
  }

  data = {
    config = <<-EOT
      provider: AWS
      region: ap-northeast-2
      use_iam_profile: true
    EOT
  }

  type = "Opaque"
}

resource "kubernetes_job_v1" "gitlab_init_db" {
  metadata {
    name      = "init-db"
    namespace = kubernetes_namespace_v1.gitlab.metadata[0].name
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
            psql -h $DB_HOST -U $DB_USER -d postgres -c "CREATE DATABASE gitlab;" || echo "Database 'gitlab' creation failed or already exists. Continuing..."
            EOF
          ]

          env {
            name  = "DB_HOST"
            value = module.gitlab_postgres.db_instance_address
          }
          env {
            name  = "DB_USER"
            value = jsondecode(data.aws_secretsmanager_secret_version.gitlab_postgres.secret_string)["username"]
          }
          env {
            name  = "DB_PASSWORD"
            value = jsondecode(data.aws_secretsmanager_secret_version.gitlab_postgres.secret_string)["password"]
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
    module.gitlab_postgres,
    kubernetes_job_v1.karpenter_node_warmup
  ]
}

# GitLab
resource "helm_release" "gitlab" {
  name       = "gitlab"
  repository = "https://charts.gitlab.io"
  chart      = "gitlab"
  version    = var.gitlab_chart_version
  namespace  = kubernetes_namespace_v1.gitlab.metadata[0].name
  timeout    = 900

  values = [
    templatefile("${path.module}/helm-values/gitlab.yaml", {
      domain            = aws_route53_zone.this.name
      db_host           = module.gitlab_postgres.db_instance_address
      db_username       = jsondecode(data.aws_secretsmanager_secret_version.gitlab_postgres.secret_string)["username"]
      db_secret         = kubernetes_secret_v1.gitlab_postgres.metadata[0].name
      redis_host        = module.gitlab_redis.replication_group_primary_endpoint_address
      s3_secret         = kubernetes_secret_v1.gitlab_s3_connection.metadata[0].name
      gateway_name      = local.envoy_gateway_name
      gateway_namespace = local.envoy_gateway_namespace
      gateway_listener  = local.envoy_gateway_listener
    })
  ]

  depends_on = [
    module.gitlab_pod_identity,
    kubernetes_storage_class_v1.ebs
  ]
}

# Argo CD를 설치할 네임스페이스
resource "kubernetes_namespace_v1" "argocd" {
  metadata {
    name = "argocd"
  }
}

# Argo CD 어드민 비밀번호의 bcrypt hash 생성
resource "htpasswd_password" "argocd" {
  password = "admin"
}

# Argo CD
resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version
  namespace  = kubernetes_namespace_v1.argocd.metadata[0].name

  values = [
    templatefile("${path.module}/helm-values/argocd.yaml", {
      hostname              = "argocd.${aws_route53_zone.this.name}"
      server_admin_password = htpasswd_password.argocd.bcrypt
      gateway_name          = local.envoy_gateway_name
      gateway_namespace     = local.envoy_gateway_namespace
      gateway_listener      = local.envoy_gateway_listener
    })
  ]
}