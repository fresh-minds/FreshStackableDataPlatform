terraform {
  required_version = ">= 1.5.0"

  required_providers {
    stackit = {
      source  = "stackitcloud/stackit"
      version = "~> 0.96"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}
