# Preliminary sizing; supply location, IDs and SSH key separately.
vm = {
  platform_id      = "standard-v3"
  cores            = 8
  memory_gb        = 16
  boot_disk_gb     = 20
  data_disk_gb     = 100
  disk_type        = "network-ssd"
  ssh_user         = "ubuntu"
  assign_public_ip = false
}
