resource "yandex_compute_disk" "data" {
  name      = "${var.name}-data"
  folder_id = var.folder_id
  zone      = var.zone
  type      = var.disk_type
  size      = var.data_disk_gb
  labels    = var.labels
}

resource "yandex_compute_instance" "vm" {
  name                      = var.name
  folder_id                 = var.folder_id
  zone                      = var.zone
  platform_id               = var.platform_id
  labels                    = var.labels
  allow_stopping_for_update = true

  resources {
    cores  = var.cores
    memory = var.memory_gb
  }

  boot_disk {
    initialize_params {
      image_id = var.image_id
      type     = var.disk_type
      size     = var.boot_disk_gb
    }
  }

  secondary_disk {
    disk_id     = yandex_compute_disk.data.id
    device_name = "data"
    auto_delete = false
  }

  network_interface {
    subnet_id          = var.subnet_id
    security_group_ids = var.security_group_ids
    nat                = var.assign_public_ip
  }

  metadata = {
    user-data = join("\n", ["#cloud-config", yamlencode({
      ssh_pwauth = false
      users = [{
        name                = var.ssh_user
        groups              = ["sudo"]
        shell               = "/bin/bash"
        sudo                = ["ALL=(ALL) NOPASSWD:ALL"]
        lock_passwd         = true
        ssh_authorized_keys = [trimspace(var.ssh_public_key)]
      }]
    })])
  }
}
