# RHEL 9 Splunk UF test lab — separate Terraform root from terraform/ (k3s).
# Own state file; apply/destroy here never touches k3s or nfs-01.

resource "proxmox_virtual_environment_vm" "rhel9" {
  for_each = { for h in var.hosts : h.name => h }

  name      = each.value.name
  node_name = var.proxmox_node
  vm_id     = each.value.vmid
  tags      = [var.lab_name, "rhel9", "splunk-uf"]

  stop_on_destroy = true

  # Same PVE 9 guest-agent hang as k3s nodes; keep false for plan/refresh.
  agent {
    enabled = false
  }

  cpu {
    cores = each.value.cores
    type  = "host"
  }

  memory {
    dedicated = each.value.memory
  }

  disk {
    datastore_id = var.vm_datastore
    interface    = "scsi0"
    size         = each.value.disk_gb
    discard      = "on"
    file_format  = "raw"
  }

  clone {
    vm_id = var.template_id
    full  = true
  }

  network_device {
    bridge  = var.bridge
    model   = "virtio"
    vlan_id = var.vlan_id
  }

  initialization {
    datastore_id = var.snippet_datastore

    ip_config {
      ipv4 {
        address = "${each.value.ip}/${each.value.cidr}"
        gateway = var.gateway
      }
    }

    dns {
      servers = var.dns_servers
    }

    user_account {
      username = var.ssh_user
      keys     = var.ssh_public_keys
    }
  }

  operating_system {
    type = "l26"
  }

  serial_device {
    device = "socket"
  }

  vga {
    type = "serial0"
  }

  lifecycle {
    ignore_changes = [clone]
  }
}

# Separate inventory — never mixed with ansible/inventory/hosts.proxmox.yml (k3s).
resource "local_file" "ansible_inventory" {
  filename = "${path.module}/../../ansible/inventory/hosts.rhel9.yml"
  content = yamlencode({
    all = {
      children = {
        rhel9_uf = {
          hosts = {
            for h in var.hosts : h.name => {
              ansible_host = h.ip
              ansible_user = var.ssh_user
            }
          }
          vars = {
            ansible_become = true
          }
        }
      }
    }
  })
}
