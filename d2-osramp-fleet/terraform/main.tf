terraform {
  required_version = ">= 1.7"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.37"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 3.0"
    }
  }
}

// Create the  flux-system namespace.
resource "kubernetes_namespace" "flux_system" {
  metadata {
    name = "flux-system"
  }

  lifecycle {
    ignore_changes = [metadata]
  }
}

// Create a Kubernetes image pull secret for GHCR.
resource "kubernetes_secret" "git_auth" {
  depends_on = [kubernetes_namespace.flux_system]

  metadata {
    name      = "ghcr-auth"
    namespace = "flux-system"
  }

  data = {
    ".dockerconfigjson" = jsonencode({
      "auths" : {
        "ghcr.io" : {
          username = "flux"
          password = var.oci_token
          auth = base64encode(join(":", ["flux", var.oci_token]))
        }
      }
    })
  }

  type = "kubernetes.io/dockerconfigjson"
}

// Install the Flux Operator.
resource "helm_release" "flux_operator" {
  depends_on = [kubernetes_namespace.flux_system]

  name       = "flux-operator"
  namespace  = "flux-system"
  repository = "oci://ghcr.io/controlplaneio-fluxcd/charts"
  chart      = "flux-operator"
  wait       = true

  values = [
    file("values/operator.yaml")
  ]
}

// Configure the Flux instance.
resource "helm_release" "flux_instance" {
  depends_on = [helm_release.flux_operator]

  name       = "flux"
  namespace  = "flux-system"
  repository = "oci://ghcr.io/controlplaneio-fluxcd/charts"
  chart = "flux-instance"

  // Configure the Flux components and kustomize patches.
  values = [
    file("values/instance.yaml")
  ]

  // Configure the Flux distribution and sync from GitHub Container Registry.
  set = [
    {
      name  = "instance.distribution.version"
      value = var.flux_version
    },
    {
      name  = "instance.distribution.registry"
      value = var.flux_registry
    },
    {
      name  = "instance.distribution.artifact"
      value = "oci://ghcr.io/controlplaneio-fluxcd/flux-operator-manifests:latest"
    },
    {
      name  = "instance.sync.kind"
      value = "OCIRepository"
    },
    {
      name  = "instance.sync.url"
      value = var.oci_url
    },
    {
      name  = "instance.sync.path"
      value = var.oci_path
    },
    {
      name  = "instance.sync.ref"
      value = var.oci_tag
    },
    {
      name  = "instance.sync.pullSecret"
      value = "ghcr-auth"
    },
    {
      name  = "healthcheck.enabled"
      value = "true"
      type  = "auto"
    },
  ]
}
