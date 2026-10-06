variable "name" {
  description = "VM name; also used as a prefix for its data disk."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,50}[a-z0-9]$", var.name))
    error_message = "Use 3-52 lowercase letters, digits or hyphens."
  }
}
variable "folder_id" {
  description = "Target Yandex Cloud folder."
  type        = string
}
variable "zone" {
  description = "Availability zone shared by VM, disk and subnet."
  type        = string
}
variable "image_id" {
  description = "Pinned boot image ID with cloud-init support."
  type        = string
}
variable "platform_id" {
  description = "Compute platform supported in the selected zone."
  type        = string
}
variable "cores" {
  description = "Number of vCPUs."
  type        = number
  validation {
    condition     = var.cores >= 2 && var.cores == floor(var.cores)
    error_message = "cores must be an integer >= 2; also check platform limits."
  }
}
variable "memory_gb" {
  description = "RAM in GB."
  type        = number
  validation {
    condition     = var.memory_gb > 0
    error_message = "memory_gb must be positive."
  }
}
variable "boot_disk_gb" {
  description = "Boot disk size in GB, at least as large as the image."
  type        = number
  validation {
    condition     = var.boot_disk_gb > 0 && var.boot_disk_gb == floor(var.boot_disk_gb)
    error_message = "boot_disk_gb must be a positive integer."
  }
}
variable "data_disk_gb" {
  description = "Attached data disk size in GB."
  type        = number
  validation {
    condition     = var.data_disk_gb > 0 && var.data_disk_gb == floor(var.data_disk_gb)
    error_message = "data_disk_gb must be a positive integer."
  }
}
variable "disk_type" {
  description = "Disk type for boot and data volumes."
  type        = string
  validation {
    condition     = contains(["network-hdd", "network-ssd"], var.disk_type)
    error_message = "Use network-hdd or network-ssd in this MVP."
  }
}
variable "subnet_id" {
  description = "Existing subnet in the selected zone."
  type        = string
}
variable "security_group_ids" {
  description = "Existing security groups in the subnet's VPC."
  type        = list(string)
  validation {
    condition     = length(var.security_group_ids) > 0
    error_message = "Provide at least one explicit security group."
  }
}
variable "ssh_user" {
  description = "Linux user provisioned by cloud-init."
  type        = string
  validation {
    condition     = can(regex("^[a-z_][a-z0-9_-]*$", var.ssh_user))
    error_message = "Provide a valid Linux user name."
  }
}
variable "ssh_public_key" {
  description = "Public SSH key only; never a private key."
  type        = string
  validation {
    condition     = can(regex("^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+) [A-Za-z0-9+/=]+( .*)?$", trimspace(var.ssh_public_key)))
    error_message = "Provide a single OpenSSH public key."
  }
}
variable "assign_public_ip" {
  description = "Whether to allocate a public IPv4 address."
  type        = bool
  default     = false
}
variable "labels" {
  description = "Environment and ownership labels supplied by the caller."
  type        = map(string)
  default     = {}
}
