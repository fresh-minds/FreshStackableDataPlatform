output "cluster_name" {
  value = azurerm_kubernetes_cluster.aks.name
}

output "resource_group" {
  value = azurerm_kubernetes_cluster.aks.resource_group_name
}

output "location" {
  value = azurerm_kubernetes_cluster.aks.location
}

output "kubernetes_version" {
  value = azurerm_kubernetes_cluster.aks.kubernetes_version
}

output "node_resource_group" {
  description = "AKS-managed RG that contains the VMSS, Load Balancer, NICs, etc."
  value       = azurerm_kubernetes_cluster.aks.node_resource_group
}

output "get_credentials_command" {
  value = "az aks get-credentials --resource-group ${azurerm_kubernetes_cluster.aks.resource_group_name} --name ${azurerm_kubernetes_cluster.aks.name} --overwrite-existing"
}

# ---- Node pools ----

output "node_pools" {
  description = "Summary of all node pools and their sizing (cost-relevant)."
  value = {
    system = {
      vm_size    = var.node_vm_size
      node_count = var.node_count
    }
    user = var.user_pool_enabled ? {
      vm_size   = var.user_pool_vm_size
      min_count = var.user_pool_min_count
      max_count = var.user_pool_max_count
      enabled   = true
    } : { enabled = false }
    spot = var.spot_pool_enabled ? {
      vm_size   = var.spot_pool_vm_size
      min_count = var.spot_pool_min_count
      max_count = var.spot_pool_max_count
      taint     = "workload=batch:NoSchedule"
      enabled   = true
    } : { enabled = false }
  }
}

# ---- VPN ----

output "vpn_enabled" {
  value = var.vpn_gateway_enabled
}

output "vpn_gateway_name" {
  value = var.vpn_gateway_enabled ? azurerm_virtual_network_gateway.vpn[0].name : null
}

output "vpn_gateway_public_ip" {
  description = "VPN Gateway public IP (allocated dynamically; visible after provisioning completes)."
  value       = var.vpn_gateway_enabled ? azurerm_public_ip.vpn[0].ip_address : null
}

output "vpn_client_pool" {
  value = var.vpn_client_address_pool
}

output "aks_vnet_address_space" {
  description = "AKS auto-VNet address space (added to VPN client routes via the Windows P2S profile)."
  value       = var.vpn_gateway_enabled ? data.azurerm_virtual_network.aks_vnet[0].address_space : []
}

output "vpn_client_cert_dir" {
  description = "Local directory containing the client cert+key. Use scripts/azure/vpn-windows-setup.sh to package as .pfx."
  value       = var.vpn_gateway_enabled ? var.vpn_client_cert_export_dir : null
}
