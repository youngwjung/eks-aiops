# Envoy Gateway
resource "kubernetes_namespace_v1" "envoy_gateway" {
  metadata {
    name = "envoy-gateway-system"
  }

  depends_on = [
    helm_release.aws_load_balancer_controller
  ]
}

resource "helm_release" "envoy_gateway" {
  name       = "envoy-gateway"
  repository = "oci://docker.io/envoyproxy"
  chart      = "gateway-helm"
  version    = var.envoy_gateway_chart_version
  namespace  = kubernetes_namespace_v1.envoy_gateway.metadata[0].name

  depends_on = [
    helm_release.aws_load_balancer_controller
  ]
}

# Envoy Proxy
resource "kubectl_manifest" "envoy_proxy" {
  yaml_body = <<-YAML
    apiVersion: gateway.envoyproxy.io/v1alpha1
    kind: EnvoyProxy
    metadata:
      name: envoy-config
      namespace: ${kubernetes_namespace_v1.envoy_gateway.metadata[0].name}
    spec:
      provider:
        type: Kubernetes
        kubernetes:
          envoyService:
            type: LoadBalancer
            annotations: 
              service.beta.kubernetes.io/aws-load-balancer-type: external
              service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
              service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
              service.beta.kubernetes.io/aws-load-balancer-backend-protocol: tcp
              service.beta.kubernetes.io/aws-load-balancer-ssl-ports: "443"
              service.beta.kubernetes.io/aws-load-balancer-ssl-cert: ${aws_acm_certificate_validation.this.certificate_arn}
              service.beta.kubernetes.io/aws-load-balancer-proxy-protocol: "*"
              service.beta.kubernetes.io/aws-load-balancer-target-group-attributes: preserve_client_ip.enabled=true
      telemetry:
        tracing:
          samplingRate: 1
          provider:
            type: OpenTelemetry
            backendRefs:
            - name: k8s-monitoring-trace-alloy-receiver
              namespace: tracing
              port: 4317
  YAML

  wait = true

  depends_on = [
    helm_release.envoy_gateway
  ]
}

# Gateway Class
resource "kubectl_manifest" "envoy_gateway_class" {
  yaml_body = <<-YAML
    apiVersion: gateway.networking.k8s.io/v1
    kind: GatewayClass
    metadata:
      name: eg
    spec:
      controllerName: gateway.envoyproxy.io/gatewayclass-controller
      parametersRef:
        group: gateway.envoyproxy.io
        kind: EnvoyProxy
        name: ${kubectl_manifest.envoy_proxy.name}
        namespace: ${kubectl_manifest.envoy_proxy.namespace}
  YAML

  wait = true

  depends_on = [
    helm_release.envoy_gateway
  ]
}

# Gateway
locals {
  envoy_gateway_listener = "https"
}

resource "kubectl_manifest" "envoy_gateway" {
  yaml_body = <<-YAML
    apiVersion: gateway.networking.k8s.io/v1
    kind: Gateway
    metadata:
      name: eg
      namespace: ${kubernetes_namespace_v1.envoy_gateway.metadata[0].name}
    spec:
      gatewayClassName: ${kubectl_manifest.envoy_gateway_class.name}
      listeners:
        - name: ${local.envoy_gateway_listener}
          protocol: HTTP
          port: 443
          allowedRoutes:
            namespaces:
              from: All
        - name: http
          protocol: HTTP
          port: 80
          allowedRoutes:
            namespaces:
              from: All
  YAML

  wait = true

  depends_on = [
    helm_release.envoy_gateway
  ]
}

locals {
  envoy_gateway_name      = kubectl_manifest.envoy_gateway.name
  envoy_gateway_namespace = kubectl_manifest.envoy_gateway.namespace
}

# ClientTrafficPolicy
resource "kubectl_manifest" "client_traffic_policy" {
  yaml_body = <<-YAML
    apiVersion: gateway.envoyproxy.io/v1alpha1
    kind: ClientTrafficPolicy
    metadata:
      name: eg
      namespace: ${kubernetes_namespace_v1.envoy_gateway.metadata[0].name}
    spec:
      targetRefs:
        - group: gateway.networking.k8s.io
          kind: Gateway
          name: ${kubectl_manifest.envoy_gateway.name}
      enableProxyProtocol: true
      headers:
        earlyRequestHeaders:
          add:
          - name: X-Forwarded-Proto
            value: https
      clientIPDetection:
        xForwardedFor:
          numTrustedHops: 1
  YAML

  wait = true

  depends_on = [
    helm_release.envoy_gateway
  ]
}

# HTTP -> HTTPS Redirect
resource "kubectl_manifest" "http_to_https_redirect" {
  yaml_body = <<-YAML
    apiVersion: gateway.networking.k8s.io/v1
    kind: HTTPRoute
    metadata:
      name: http-to-https-redirect
      namespace: ${kubernetes_namespace_v1.envoy_gateway.metadata[0].name}
    spec:
      parentRefs:
        - name: ${kubectl_manifest.envoy_gateway.name} 
          sectionName: http
      rules:
        - filters:
            - type: RequestRedirect
              requestRedirect:
                scheme: https
                statusCode: 301
  YAML

  wait = true

  depends_on = [
    helm_release.envoy_gateway
  ]
}

# Envoy Proxy 지표
resource "kubectl_manifest" "envoy_proxy_metrics" {
  yaml_body = <<-YAML
    apiVersion: monitoring.coreos.com/v1
    kind: PodMonitor
    metadata:
      name: envoy-gateway-proxy
      namespace: ${kubernetes_namespace_v1.envoy_gateway.metadata[0].name}
    spec:
      selector:
        matchLabels:
          app.kubernetes.io/name: envoy
          app.kubernetes.io/component: proxy
      namespaceSelector:
        any: true
      jobLabel: proxy-stats
      podMetricsEndpoints:
        - path: /stats/prometheus
          interval: 15s
          port: metrics
  YAML

  wait = true

  depends_on = [
    helm_release.prometheus_operator_crds
  ]
}