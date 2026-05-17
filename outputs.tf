output "vm_id" {
  description = "VMID Proxmox de la VM créée"
  value       = proxmox_virtual_environment_vm.this.vm_id
}

output "vm_name" {
  description = "Nom de la VM"
  value       = proxmox_virtual_environment_vm.this.name
}

output "ip_address" {
  description = "Adresse IP configurée via cloud-init"
  value       = var.ip_address
}

output "ipv4_addresses" {
  description = "Adresses IPv4 remontées par l'agent QEMU (disponibles après démarrage)"
  value       = proxmox_virtual_environment_vm.this.ipv4_addresses
}
