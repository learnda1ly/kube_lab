output "control_plane_ips" {
  description = "Control-plane node IPv4 addresses"
  value = [
    for n in local.nodes : n.ip if n.role == "control_plane"
  ]
}

output "worker_ips" {
  description = "Worker node IPv4 addresses"
  value = [
    for n in local.nodes : n.ip if n.role == "worker"
  ]
}

output "nfs_server_ip" {
  description = "NFS server IPv4 address"
  value       = var.nfs_server.ip
}

output "nfs_export_path" {
  description = "NFS export path on the NFS VM"
  value       = var.nfs_export_path
}

output "ansible_inventory_path" {
  description = "Path to generated Ansible inventory"
  value       = local_file.ansible_inventory.filename
}

output "vm_ids" {
  description = "Map of node name to Proxmox VMID"
  value = merge(
    {
      for name, vm in proxmox_virtual_environment_vm.node : name => vm.vm_id
    },
    {
      (var.nfs_server.name) = proxmox_virtual_environment_vm.nfs.vm_id
    }
  )
}