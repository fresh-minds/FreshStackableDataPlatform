variable "subscription_id" {
  description = "Azure subscription ID."
  type        = string
}

variable "tenant_id" {
  description = "Azure AD tenant ID."
  type        = string
}

variable "resource_group_name" {
  description = "Existing resource group that will hold the AKS cluster."
  type        = string
  default     = "dev-stackable-rg"
}

variable "location" {
  description = "Azure region. Must match the existing resource group."
  type        = string
  default     = "westeurope"
}

variable "cluster_name" {
  description = "AKS cluster name."
  type        = string
  default     = "uwv-platform-aks"
}

variable "dns_prefix" {
  description = "DNS prefix for the AKS API server."
  type        = string
  default     = "uwv-platform"
}

variable "node_count" {
  description = "Number of nodes in the default node pool."
  type        = number
  default     = 3
}

variable "node_vm_size" {
  description = "VM size for the default node pool."
  type        = string
  default     = "Standard_D8s_v5"
}

variable "node_os_disk_size_gb" {
  description = "OS disk size per node."
  type        = number
  default     = 128
}

variable "kubernetes_version" {
  description = "AKS Kubernetes version. Empty = pick latest GA in the region (default_version)."
  type        = string
  default     = ""
}

variable "sp_client_id" {
  description = "Service principal client ID used as AKS cluster identity."
  type        = string
}

variable "sp_client_secret" {
  description = "Service principal client secret. Pass via TF_VAR_sp_client_secret env var, never commit."
  type        = string
  sensitive   = true
}

variable "tags" {
  description = "Tags applied to all created resources."
  type        = map(string)
  default = {
    project     = "uwv-data-platform"
    environment = "dev"
    managed_by  = "terraform"
    purpose     = "reference-implementation"
  }
}

# ---- VPN Gateway (Point-to-Site) ----

variable "vpn_gateway_enabled" {
  description = "Provision the VPN Gateway + supporting VNet. Set false to skip VPN entirely (saves ~€28/month)."
  type        = bool
  default     = true
}

variable "vpn_vnet_address_space" {
  description = "Address space of the VPN VNet (must NOT overlap with AKS auto-VNet, default 10.224.0.0/12)."
  type        = list(string)
  default     = ["10.1.0.0/16"]
}

variable "vpn_gateway_subnet_prefix" {
  description = "GatewaySubnet CIDR (must be /27 or larger). Subnet name MUST be 'GatewaySubnet' (Azure requirement)."
  type        = string
  default     = "10.1.255.0/27"
}

variable "vpn_client_address_pool" {
  description = "CIDR pool for VPN client IPs (kept separate from VNet space; routed through the tunnel)."
  type        = list(string)
  default     = ["172.16.0.0/24"]
}

variable "vpn_gateway_sku" {
  description = <<-DESC
    VPN Gateway SKU. Azure deprecations make this less negotiable than it sounds:
      - 'Basic' was retired (no new deployments).
      - 'VpnGw1'..'VpnGw5' (non-AZ) are no longer accepted for new gateways.
    The minimum usable SKU is now 'VpnGw1AZ' (~€240-260/mo, supports SSTP/IKEv2/OpenVPN,
    zone-redundant). Higher SKUs add throughput and tunnels, not features for our case.
  DESC
  type        = string
  default     = "VpnGw1AZ"
}

variable "vpn_client_cert_export_dir" {
  description = "Local directory where the generated client cert/key + Windows .pfx is written. Gitignored."
  type        = string
  default     = "../vpn-client"
}
