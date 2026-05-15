# ---- VPN VNet (separate from the AKS auto-VNet, peered to it below) ----
#
# We don't want to recreate AKS to switch it to BYO-VNet, so we keep the
# AKS auto-VNet in the MC_* resource group and add a sibling VNet here for
# the VPN Gateway. VNet peering links them so VPN clients can reach AKS.

resource "azurerm_virtual_network" "vpn" {
  count               = var.vpn_gateway_enabled ? 1 : 0
  name                = "${var.cluster_name}-vpn-vnet"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  address_space       = var.vpn_vnet_address_space
  tags                = var.tags
}

resource "azurerm_subnet" "gateway" {
  count                = var.vpn_gateway_enabled ? 1 : 0
  name                 = "GatewaySubnet" # Azure-mandated name
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vpn[0].name
  address_prefixes     = [var.vpn_gateway_subnet_prefix]
}

# ---- AKS auto-VNet lookup (for peering target) ----
#
# AKS without BYO-VNet creates its own VNet in the node_resource_group with
# a name like 'aks-vnet-XXXXXXXX'. We discover it via the resources data
# source so the peering keeps working through AKS recreations.
data "azurerm_resources" "aks_vnet" {
  count               = var.vpn_gateway_enabled ? 1 : 0
  resource_group_name = azurerm_kubernetes_cluster.aks.node_resource_group
  type                = "Microsoft.Network/virtualNetworks"
}

data "azurerm_virtual_network" "aks_vnet" {
  count               = var.vpn_gateway_enabled ? 1 : 0
  name                = data.azurerm_resources.aks_vnet[0].resources[0].name
  resource_group_name = azurerm_kubernetes_cluster.aks.node_resource_group
}

# ---- VNet peering (bi-directional) ----
#
# vpn-vnet -> aks auto-vnet
resource "azurerm_virtual_network_peering" "vpn_to_aks" {
  count                        = var.vpn_gateway_enabled ? 1 : 0
  name                         = "vpn-to-aks"
  resource_group_name          = data.azurerm_resource_group.rg.name
  virtual_network_name         = azurerm_virtual_network.vpn[0].name
  remote_virtual_network_id    = data.azurerm_virtual_network.aks_vnet[0].id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  # We're not pushing AKS traffic out via the VPN GW (that would hairpin the
  # cluster's egress), so gateway transit stays off in both directions.
  allow_gateway_transit = false
  use_remote_gateways   = false
}

# aks auto-vnet -> vpn-vnet
resource "azurerm_virtual_network_peering" "aks_to_vpn" {
  count                        = var.vpn_gateway_enabled ? 1 : 0
  name                         = "aks-to-vpn"
  resource_group_name          = azurerm_kubernetes_cluster.aks.node_resource_group
  virtual_network_name         = data.azurerm_virtual_network.aks_vnet[0].name
  remote_virtual_network_id    = azurerm_virtual_network.vpn[0].id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
  use_remote_gateways          = false
}
