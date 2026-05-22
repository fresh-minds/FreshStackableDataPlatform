# Use the existing resource group; do NOT create or destroy it.
data "azurerm_resource_group" "rg" {
  name = var.resource_group_name
}

# Pick latest GA Kubernetes version when var.kubernetes_version is empty.
data "azurerm_kubernetes_service_versions" "current" {
  location        = var.location
  include_preview = false
}

locals {
  k8s_version = var.kubernetes_version != "" ? var.kubernetes_version : data.azurerm_kubernetes_service_versions.current.latest_version
}

resource "azurerm_kubernetes_cluster" "aks" {
  name                = var.cluster_name
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  dns_prefix          = var.dns_prefix
  kubernetes_version  = local.k8s_version
  sku_tier            = "Free"

  # Per user request: AKS cluster identity = the existing service principal.
  service_principal {
    client_id     = var.sp_client_id
    client_secret = var.sp_client_secret
  }

  # ---- System node pool ----
  # Hosts kube-system, CoreDNS, metrics-server. App workloads will also land
  # here in single-pool mode; with user_pool_enabled = true the scheduler
  # will additionally fill the larger user pool as that becomes available.
  #
  # We intentionally do NOT set `only_critical_addons_enabled = true` because
  # that taints the system pool with CriticalAddonsOnly=true:NoSchedule,
  # which would evict every existing platform pod (none of them tolerate it).
  # If you want a strictly-dedicated system pool in production, add the
  # toleration to all platform Deployments first, then flip this on.
  default_node_pool {
    name            = "system"
    node_count      = var.node_count
    vm_size         = var.node_vm_size
    os_disk_size_gb = var.node_os_disk_size_gb
    os_disk_type    = "Managed"
    type            = "VirtualMachineScaleSets"
    max_pods        = 60

    upgrade_settings {
      max_surge = "33%"
    }
  }

  network_profile {
    network_plugin    = "azure"
    network_policy    = "azure"
    load_balancer_sku = "standard"
  }

  # Cost / sandbox profile: no Azure Monitor, no Defender, no Key Vault CSI.
  # Add later in a production profile.

  tags = var.tags

  lifecycle {
    ignore_changes = [
      # Avoid spurious diffs when AKS auto-upgrades patch versions.
      kubernetes_version,
      default_node_pool[0].node_count,
    ]
  }
}

# ---- User node pool ----
#
# Application workloads (Stackable services, OpenMetadata, Keycloak, Portal,
# Multica, Vector, etc.). Autoscaler scales 1..4 nodes on demand.
resource "azurerm_kubernetes_cluster_node_pool" "user" {
  count                 = var.user_pool_enabled ? 1 : 0
  name                  = "user"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.aks.id
  vm_size               = var.user_pool_vm_size
  os_disk_size_gb       = var.node_os_disk_size_gb
  os_disk_type          = "Managed"
  mode                  = "User"
  max_pods              = 60

  auto_scaling_enabled = true
  min_count            = var.user_pool_min_count
  max_count            = var.user_pool_max_count

  node_labels = {
    "workload" = "general"
  }

  upgrade_settings {
    max_surge = "33%"
  }

  tags = var.tags

  lifecycle {
    ignore_changes = [
      node_count, # autoscaler manages this
    ]
  }
}

# ---- Spot node pool (optional) ----
#
# Preemptible nodes (70-90% cheaper than on-demand). Tainted so only pods that
# explicitly tolerate `workload=batch:NoSchedule` land here. Suitable for
# Spark executors, dbt runs, ad-hoc batch jobs that can recover from eviction.
resource "azurerm_kubernetes_cluster_node_pool" "spot" {
  count                 = var.spot_pool_enabled ? 1 : 0
  name                  = "spot"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.aks.id
  vm_size               = var.spot_pool_vm_size
  os_disk_size_gb       = var.node_os_disk_size_gb
  os_disk_type          = "Managed"
  mode                  = "User"
  max_pods              = 60

  priority        = "Spot"
  eviction_policy = "Delete"
  spot_max_price  = var.spot_pool_max_price

  auto_scaling_enabled = true
  min_count            = var.spot_pool_min_count
  max_count            = var.spot_pool_max_count

  # Spot pools get a Kubernetes-controlled taint automatically
  # (kubernetes.azure.com/scalesetpriority=spot:NoSchedule). We add a more
  # workload-meaningful taint that pods can opt into.
  node_labels = {
    "workload"                              = "batch"
    "kubernetes.azure.com/scalesetpriority" = "spot"
  }
  node_taints = [
    "workload=batch:NoSchedule",
  ]

  tags = var.tags

  lifecycle {
    ignore_changes = [
      node_count,
    ]
  }
}
