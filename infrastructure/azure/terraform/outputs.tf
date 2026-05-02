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
