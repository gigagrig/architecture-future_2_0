# Preliminary sizing; supply location, IDs and SSH key separately.
vm = {
  platform_id      = "standard-v3"
  cores            = 2
  memory_gb        = 4
  boot_disk_gb     = 20
  data_disk_gb     = 20
  disk_type        = "network-ssd"
  ssh_user         = "ubuntu"
  assign_public_ip = false
}
