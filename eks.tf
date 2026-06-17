# EKS 클러스터
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.23.0"

  name               = var.project
  kubernetes_version = var.eks_cluster_version

  # EKS 클러스터 API 엔드포인트 접근 제어
  endpoint_public_access = true

  # 보안 그룹을 생성할 VPC
  vpc_id = module.vpc.vpc_id
  # 노드그룹을 사용할 경우 노드가 생성되는 서브넷
  subnet_ids = module.vpc.private_subnets
  # 컨트롤 플레인으로 연결된 ENI를 생성할 서브넷
  control_plane_subnet_ids = module.vpc.private_subnets

  # 클러스터를 생성한 IAM 객체에서 쿠버네티스 어드민 권한 할당
  enable_cluster_creator_admin_permissions = true

  # 불필요한 리소스 생성 비활성화
  create_cloudwatch_log_group = false
  create_node_security_group  = false
  create_security_group       = false

  fargate_profiles = {
    # Karpenter를 Fargate에 실행
    karpenter = {
      selectors = [
        {
          namespace = "karpenter"
          labels = {
            "app.kubernetes.io/name" = "karpenter"
          }
        }
      ]
      iam_role_name            = "${var.project}-karpenter-fargate-role"
      iam_role_use_name_prefix = false
    }
    # CoreDNS를 Fargate에 실행
    coredns = {
      selectors = [
        {
          namespace = "kube-system"
          labels = {
            "k8s-app" = "kube-dns"
          }
        }
      ]
      iam_role_name            = "${var.project}-coredns-fargate-role"
      iam_role_use_name_prefix = false
    }
  }

  # 로깅 비활성화
  enabled_log_types = []

  # 리소스 이름
  security_group_use_name_prefix      = false
  iam_role_use_name_prefix            = false
  node_security_group_use_name_prefix = false
}

# 필수 EKS 애드온
locals {
  eks_addons_essential = [
    "kube-proxy",
    "vpc-cni"
  ]
}

data "aws_eks_addon_version" "coredns" {
  addon_name         = "coredns"
  kubernetes_version = module.eks.cluster_version
}

resource "aws_eks_addon" "coredns" {
  cluster_name  = module.eks.cluster_name
  addon_name    = "coredns"
  addon_version = data.aws_eks_addon_version.coredns.version

  configuration_values = jsonencode({
    # Karpenter가 실행되려면 CoreDNS가 필수 구성요소기 때문에 Fargate에 배포
    computeType  = "Fargate"
    replicaCount = 1
  })

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    module.eks.fargate_profiles
  ]
}

data "aws_eks_addon_version" "essential" {
  for_each = toset(local.eks_addons_essential)

  addon_name         = each.key
  kubernetes_version = module.eks.cluster_version
}

resource "aws_eks_addon" "essential" {
  for_each = toset(local.eks_addons_essential)

  cluster_name                = module.eks.cluster_name
  addon_name                  = each.key
  addon_version               = data.aws_eks_addon_version.essential[each.key].version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  preserve                    = true
}

# Karpenter 구성에 필요한 AWS 리소스 생성
data "aws_iam_policy_document" "karpenter" {
  statement {
    sid = "IRSA"

    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.oidc_provider_arn, "/^(.*provider/)/", "")}:sub"
      values   = ["system:serviceaccount:karpenter:karpenter"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.oidc_provider_arn, "/^(.*provider/)/", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "21.23.0"

  cluster_name = module.eks.cluster_name
  namespace    = "karpenter"

  iam_role_name                   = "${module.eks.cluster_name}-karpenter-role"
  node_iam_role_name              = "${module.eks.cluster_name}-node-role"
  node_iam_role_use_name_prefix   = false
  iam_policy_use_name_prefix      = false
  iam_role_use_name_prefix        = false
  create_pod_identity_association = false

  iam_role_override_assume_policy_documents = [data.aws_iam_policy_document.karpenter.json]

  enable_inline_policy = true

  # Karpenter가 생성할 노드에 부여할 역할에 기본 정책 이외에 추가할 IAM 정책
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    AmazonEBSCSIDriverPolicy     = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  }
}

# Karpenter를 배포할 네임 스페이스
resource "kubernetes_namespace_v1" "karpenter" {
  metadata {
    name = "karpenter"
  }
}

# Karpenter
resource "helm_release" "karpenter_crd" {
  name       = "karpenter-crd"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter-crd"
  version    = var.karpenter_chart_version
  namespace  = kubernetes_namespace_v1.karpenter.metadata[0].name
}

resource "helm_release" "karpenter" {
  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = var.karpenter_chart_version
  namespace  = kubernetes_namespace_v1.karpenter.metadata[0].name

  skip_crds = true

  values = [
    <<-EOT
    replicas: 1
    settings:
      clusterName: ${module.eks.cluster_name}
      clusterEndpoint: ${module.eks.cluster_endpoint}
      interruptionQueue: ${module.karpenter.queue_name}
      featureGates:
        spotToSpotConsolidation: true
    serviceAccount:
      annotations:
        eks.amazonaws.com/role-arn: ${module.karpenter.iam_role_arn}
    serviceMonitor:
      enabled: true
    EOT
  ]

  depends_on = [
    module.karpenter,
    module.eks.fargate_profiles,
    aws_eks_addon.coredns,
    module.vpc.private_route_table_ids,
    module.vpc.private_nat_gateway_route_ids,
    module.vpc.private_route_table_association_ids,
    module.vpc.public_route_table_ids,
    module.vpc.public_internet_gateway_route_id,
    module.vpc.public_route_table_association_ids,
    helm_release.prometheus_operator_crds
  ]
}

# Karpenter 기본 노드 클래스
resource "kubectl_manifest" "karpenter_default_node_class" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: default
    spec:
      amiSelectorTerms: 
      - alias: bottlerocket@latest
      role: ${module.karpenter.node_iam_role_name}
      subnetSelectorTerms:
      - tags:
          karpenter.sh/discovery: ${module.eks.cluster_name}
      securityGroupSelectorTerms:
      - id: ${module.eks.cluster_primary_security_group_id}
      blockDeviceMappings:
      - deviceName: /dev/xvda
        ebs:
          volumeSize: 20Gi
          volumeType: gp3
          encrypted: true
      metadataOptions:
        httpPutResponseHopLimit: 2
  YAML

  wait = true

  depends_on = [
    helm_release.karpenter_crd,
    helm_release.karpenter
  ]
}

# Karpenter Nodeclaim이 삭제될때까지 대기
resource "time_sleep" "wait_node_termination" {
  depends_on = [kubectl_manifest.karpenter_default_node_class]

  destroy_duration = "60s"
}

# Karpenter 기본 노드 풀
resource "kubectl_manifest" "karpenter_default_nodepool" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: default
    spec:
      template:
        spec:
          requirements:
          - key: kubernetes.io/arch
            operator: In
            values: ["amd64"]
          - key: kubernetes.io/os
            operator: In
            values: ["linux"]
          - key: karpenter.sh/capacity-type
            operator: In
            values: ["on-demand", "spot"]
          - key: karpenter.k8s.aws/instance-category
            operator: In
            values: ["m","c","r"]
          - key: karpenter.k8s.aws/instance-generation
            operator: Gt
            values: ["5"]
          - key: karpenter.k8s.aws/instance-memory
            operator: Gt
            values: ["4096"]
          - key: karpenter.k8s.aws/instance-size
            operator: In
            values: ["large", "xlarge", "2xlarge"]
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: ${kubectl_manifest.karpenter_default_node_class.name}
      disruption:
        consolidationPolicy: WhenEmptyOrUnderutilized
        consolidateAfter: Never
  YAML

  wait = true

  depends_on = [
    time_sleep.wait_node_termination,
    module.vpc.natgw_ids,
    aws_eks_addon.essential
  ]
}

# 빠른 진행을 위한 노드 생성
resource "kubernetes_job_v1" "karpenter_node_warmup" {
  metadata {
    name      = "karpenter-node-warmup"
    namespace = kubernetes_namespace_v1.karpenter.metadata[0].name
  }

  spec {
    template {
      metadata {
        name = "karpenter-node-warmup"
      }
      spec {
        container {
          name    = "warmup"
          image   = "public.ecr.aws/docker/library/busybox:stable"
          command = ["/bin/sh", "-c", "echo 'node warmed up' && sleep 5"]
        }
        restart_policy = "OnFailure"
      }
    }
  }

  wait_for_completion = true

  timeouts {
    create = "10m"
  }

  depends_on = [
    kubectl_manifest.karpenter_default_nodepool
  ]
}

# EKS 애드온
locals {
  eks_addons = [
    "aws-ebs-csi-driver",
    "eks-pod-identity-agent",
    "metrics-server",
    "snapshot-controller"
  ]
}

data "aws_eks_addon_version" "this" {
  for_each = toset(local.eks_addons)

  addon_name         = each.key
  kubernetes_version = module.eks.cluster_version
}

resource "aws_eks_addon" "this" {
  for_each = toset(local.eks_addons)

  cluster_name                = module.eks.cluster_name
  addon_name                  = each.key
  addon_version               = data.aws_eks_addon_version.this[each.key].version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    kubectl_manifest.karpenter_default_nodepool,
    kubernetes_job_v1.karpenter_node_warmup,
    aws_eks_addon.essential
  ]
}

# EBS CSI 드라이버를 사용하는 스토리지 클래스
resource "kubernetes_storage_class_v1" "ebs" {
  metadata {
    name = "ebs"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" : "true"
    }
  }
  storage_provisioner = "ebs.csi.aws.com"
  volume_binding_mode = "WaitForFirstConsumer"
  parameters = {
    type      = "gp3"
    encrypted = "true"
  }

  depends_on = [
    aws_eks_addon.this["aws-ebs-csi-driver"]
  ]
}

# ExternalDNS
module "external_dns_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.8.1"

  name = "external-dns"

  attach_external_dns_policy    = true
  external_dns_hosted_zone_arns = ["*"]

  policy_name_prefix = "${var.project}_"

  associations = {
    (module.eks.cluster_name) = {
      cluster_name    = module.eks.cluster_name
      namespace       = "external-dns"
      service_account = "external-dns"
      tags = {
        app = "external-dns"
      }
    }
  }

  depends_on = [
    aws_eks_addon.this["eks-pod-identity-agent"]
  ]
}

data "aws_eks_addon_version" "external_dns" {
  addon_name         = "external-dns"
  kubernetes_version = module.eks.cluster_version
}

resource "aws_eks_addon" "external_dns" {
  cluster_name  = module.eks.cluster_name
  addon_name    = data.aws_eks_addon_version.external_dns.addon_name
  addon_version = data.aws_eks_addon_version.external_dns.version

  configuration_values = jsonencode({
    sources = [
      "gateway-httproute"
    ]
    domainFilters = [
      aws_route53_zone.this.name
    ]
  })

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    module.external_dns_pod_identity,
    kubernetes_job_v1.karpenter_node_warmup
  ]
}

# AWS Load Balancer Controller
module "aws_load_balancer_controller_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.8.1"

  name = "aws-load-balancer-controller"

  attach_aws_lb_controller_policy = true

  policy_name_prefix = "${var.project}_"

  associations = {
    (module.eks.cluster_name) = {
      cluster_name    = module.eks.cluster_name
      namespace       = "kube-system"
      service_account = "aws-load-balancer-controller"
      tags = {
        app = "aws-load-balancer-controller"
      }
    }
  }

  depends_on = [
    aws_eks_addon.this["eks-pod-identity-agent"]
  ]
}

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.aws_load_balancer_controller_chart_version
  namespace  = "kube-system"

  values = [
    <<-EOT
    clusterName: ${module.eks.cluster_name}
    EOT
  ]

  depends_on = [
    kubectl_manifest.karpenter_default_nodepool,
    kubernetes_job_v1.karpenter_node_warmup,
    module.aws_load_balancer_controller_pod_identity
  ]
}