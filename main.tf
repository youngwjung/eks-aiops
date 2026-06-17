# 요구되는 테라폼 제공자 목록
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.49.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "3.2.0"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "2.4.1"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "3.2.0"
    }
    htpasswd = {
      source  = "loafoe/htpasswd"
      version = "1.0.4"
    }
    time = {
      source  = "hashicorp/time"
      version = "0.14.0"
    }
    argocd = {
      source  = "argoproj-labs/argocd"
      version = "7.15.3"
    }
  }
}

provider "aws" {
  alias = "youngwjung"

  assume_role {
    role_arn = "arn:aws:iam::491818659652:role/CrossRoute53Role"
  }
}

# Kubernetes 제공자 설정
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

# Kubectl 제공자 설정
provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
  lazy_load              = true
}

# Helm 제공자 설정
provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
  debug = true
}

# ArgoCD 제공자 설정
provider "argocd" {
  server_addr = "${data.kubernetes_resource.argocd_server_httproute.object.spec.hostnames[0]}:443"
  username    = "admin"
  password    = htpasswd_password.argocd.password
}