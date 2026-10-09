variable "folder_id" {
  description = "Target cloud folder."
  type        = string
}
variable "zone" {
  description = "Zone of the existing subnet."
  type        = string
}
variable "image_id" {
  description = "Pinned cloud-init compatible image ID."
  type        = string
}
variable "subnet_id" {
  description = "Existing subnet ID."
  type        = string
}
variable "security_group_ids" {
  description = "Existing restricted security groups."
  type        = list(string)
}
variable "ssh_public_key" {
  description = "Public SSH key supplied through TF_VAR_ssh_public_key."
  type        = string
}
variable "vm" {
  description = "Environment-specific VM sizing and options."
  type = object({
    platform_id      = string
    cores            = number
    memory_gb        = number
    boot_disk_gb     = number
    data_disk_gb     = number
    disk_type        = string
    ssh_user         = string
    assign_public_ip = bool
  })
}
variable "environment" {
  description = "Environment name; must match the selected backend key."
  type        = string
  validation {
    condition     = contains(["dev", "stage", "prod"], var.environment)
    error_message = "Use dev, stage or prod."
  }
}
