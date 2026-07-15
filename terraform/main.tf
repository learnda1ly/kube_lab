locals {
  nodes = concat(
    [
      merge(var.control_plane, {
        role = "control_plane"
      })
    ],
    [
      for w in var.workers : merge(w, {
        role = "worker"
      })
    ]
  )
}

resource "proxmox_virtual_environment_vm" "node" {
  for_each = { for n in local.nodes : n.name => n }

  name      = each.value.name
  node_name = var.proxmox_node
  vm_id     = each.value.vmid
  tags      = [var.cluster_name, "k3s", each.value.role]

  stop_on_destroy = true

  agent {
    enabled = true
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
}

# Ansible inventory generated from Terraform so rebuild stays aligned with infra.
resource "local_file" "ansible_inventory" {
  filename = "${path.module}/../ansible/inventory/hosts.proxmox.yml"
  content = yamlencode({
    all = {
      children = {
        k3s_cluster = {
          children = {
            control_plane = {
              hosts = {
                for n in local.nodes : n.name => {
                  ansible_host = n.ip
                  ansible_user = var.ssh_user
                } if n.role == "control_plane"
              }
            }
            workers = {
              hosts = {
                for n in local.nodes : n.name => {
                  ansible_host = n.ip
                  ansible_user = var.ssh_user
                } if n.role == "worker"
              }
            }
          }
          vars = {
            cluster_name = var.cluster_name
          }
        }
      }
    }
  })
}