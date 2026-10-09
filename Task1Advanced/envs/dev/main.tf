terraform {
  required_version = ">= 1.11.4, < 2.0.0"
  required_providers {
    yandex = {
      source  = "yandex-cloud/yandex"
      version = "0.140.1"
    }
  }
}

provider "yandex" {
  folder_id = var.folder_id
  zone      = var.zone
}
locals {
  environment = "dev"
}
module "vm_module" {
  source             = "../../modules/vm"
  name               = "future-${local.environment}-vm"
  folder_id          = var.folder_id
  zone               = var.zone
  image_id           = var.image_id
  subnet_id          = var.subnet_id
  security_group_ids = var.security_group_ids
  ssh_public_key     = var.ssh_public_key
  platform_id        = var.vm.platform_id
  cores              = var.vm.cores
  memory_gb          = var.vm.memory_gb
  boot_disk_gb       = var.vm.boot_disk_gb
  data_disk_gb       = var.vm.data_disk_gb
  disk_type          = var.vm.disk_type
  ssh_user           = var.vm.ssh_user
  assign_public_ip   = var.vm.assign_public_ip
  labels             = { environment = local.environment, project = "future-2-0" }
}
