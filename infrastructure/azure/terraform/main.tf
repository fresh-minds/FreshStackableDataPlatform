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
