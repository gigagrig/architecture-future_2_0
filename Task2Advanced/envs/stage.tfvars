# Preliminary VM sizing; location and credentials come from the environment.
vm = {
  platform_id      = "standard-v3"
  cores            = 4
  memory_gb        = 8
  boot_disk_gb     = 20
  data_disk_gb     = 50
  disk_type        = "network-ssd"
  ssh_user         = "ubuntu"
  assign_public_ip = false
}
