output "rhel9_ips" {
  description = "RHEL 9 test host IPv4 addresses"
  value       = [for h in var.hosts : h.ip]
}

output "rhel9_hosts" {
  description = "Map of RHEL 9 host name to IP"
  value = {
    for h in var.hosts : h.name => h.ip
  }
}

output "vm_ids" {
  description = "Map of RHEL 9 host name to Proxmox VMID"
  value = {
    for name, vm in proxmox_virtual_environment_vm.rhel9 : name => vm.vm_id
  }
}

output "ansible_inventory_path" {
  description = "Path to generated RHEL 9 Ansible inventory (not the k3s inventory)"
  value       = local_file.ansible_inventory.filename
}
