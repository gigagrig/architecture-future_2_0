output "vm" {
  description = "VM identity, addresses and attached disk."
  value = {
    id           = module.vm_module.id
    name         = module.vm_module.name
    private_ip   = module.vm_module.private_ip
    public_ip    = module.vm_module.public_ip
    data_disk_id = module.vm_module.data_disk_id
  }
}
