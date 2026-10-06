output "id" {
  description = "VM ID."
  value       = yandex_compute_instance.vm.id
}
output "name" {
  description = "VM name."
  value       = yandex_compute_instance.vm.name
}
output "private_ip" {
  description = "VM private IPv4 address."
  value       = yandex_compute_instance.vm.network_interface[0].ip_address
}
output "public_ip" {
  description = "Public IPv4 address, or null when disabled."
  value       = var.assign_public_ip ? yandex_compute_instance.vm.network_interface[0].nat_ip_address : null
}
output "data_disk_id" {
  description = "Attached data disk ID."
  value       = yandex_compute_disk.data.id
}
