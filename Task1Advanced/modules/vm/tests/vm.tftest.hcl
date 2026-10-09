mock_provider "yandex" {}

variables {
  name               = "fixture-vm"
  folder_id          = "mock-folder"
  zone               = "ru-central1-a"
  image_id           = "mock-image"
  platform_id        = "standard-v3"
  cores              = 2
  memory_gb          = 4
  boot_disk_gb       = 20
  data_disk_gb       = 30
  disk_type          = "network-ssd"
  subnet_id          = "mock-subnet"
  security_group_ids = ["mock-sg"]
  ssh_user           = "ubuntu"
  ssh_public_key     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMockOnlyNotForAuthentication"
  labels             = { environment = "fixture" }
}

run "private_vm_and_attached_disk" {
  command = apply
  assert {
    condition     = output.public_ip == null
    error_message = "Private VMs must not expose a public IP."
  }
  assert {
    condition     = one(yandex_compute_instance.vm.secondary_disk).disk_id == output.data_disk_id
    error_message = "The created data disk must be attached to the VM."
  }
  assert {
    condition     = yandex_compute_instance.vm.network_interface[0].subnet_id == var.subnet_id
    error_message = "The caller's subnet must be used."
  }
  assert {
    condition     = yandex_compute_instance.vm.resources[0].cores == 2 && yandex_compute_disk.data.size == 30
    error_message = "Compute and storage parameters must reach resources."
  }
}

run "larger_environment" {
  command = plan
  variables {
    name         = "fixture-prod"
    cores        = 8
    memory_gb    = 16
    data_disk_gb = 100
  }
  assert {
    condition     = yandex_compute_instance.vm.resources[0].memory == 16 && yandex_compute_disk.data.size == 100
    error_message = "A second environment must override sizing."
  }
}

run "reject_invalid_cpu" {
  command = plan
  variables {
    cores = 1.5
  }
  expect_failures = [var.cores]
}

run "reject_private_key" {
  command = plan
  variables {
    ssh_public_key = "-----BEGIN OPENSSH PRIVATE KEY-----"
  }
  expect_failures = [var.ssh_public_key]
}

run "reject_missing_security_group" {
  command = plan
  variables {
    security_group_ids = []
  }
  expect_failures = [var.security_group_ids]
}
