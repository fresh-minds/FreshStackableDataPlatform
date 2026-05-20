resource "stackit_public_ip" "platform_ingress" {
  project_id = var.project_id
  labels     = var.labels

  lifecycle {
    # network_interface_id is set by yawol when the cluster's
    # ingress-nginx LoadBalancer Service is provisioned — must NOT be
    # managed by terraform or every apply would fight the CCM.
    ignore_changes = [
      network_interface_id,
    ]
    # The IP itself survives `terraform destroy` so apex + wildcard DNS
    # A-records in Azure DNS keep working across cluster rebuilds. To
    # actually release the IP, `terraform state rm stackit_public_ip.platform_ingress`
    # and then destroy.
    prevent_destroy = true
  }
}
