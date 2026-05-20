resource "stackit_ske_cluster" "cluster" {
  project_id             = var.project_id
  name                   = var.cluster_name
  kubernetes_version_min = var.kubernetes_version_min

  node_pools = [
    {
      name               = var.node_pool_name
      machine_type       = var.node_machine_type
      minimum            = var.node_minimum
      maximum            = var.node_maximum
      availability_zones = var.node_availability_zones
      volume_type        = var.node_volume_type
      volume_size        = var.node_volume_size_gb
    }
  ]

  maintenance = {
    enable_kubernetes_version_updates    = true
    enable_machine_image_version_updates = true
    start                                = "01:00:00Z"
    end                                  = "02:00:00Z"
  }

  network = {
    control_plane = {
      access_scope = "PUBLIC"
    }
  }

  lifecycle {
    ignore_changes = [
      kubernetes_version_min,
      node_pools[0].minimum,
      node_pools[0].maximum,
    ]
  }
}

resource "stackit_ske_kubeconfig" "admin" {
  project_id     = var.project_id
  cluster_name   = stackit_ske_cluster.cluster.name
  expiration     = var.kubeconfig_expiration_seconds
  refresh        = true
  refresh_before = 300
}

resource "local_file" "kubeconfig" {
  content         = stackit_ske_kubeconfig.admin.kube_config
  filename        = "${path.module}/${var.kubeconfig_path}"
  file_permission = "0600"
}
