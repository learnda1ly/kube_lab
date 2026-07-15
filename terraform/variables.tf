variable "proxmox_endpoint" {
  description = "Proxmox API endpoint, e.g. https://proxmox.home:8006/"
  type        = string
}

variable "proxmox_api_token" {
  description = "Proxmox API token (user@realm!tokenid=secret). Prefer PROXMOX_VE_API_TOKEN env."
  type        = string
  sensitive   = true
  default     = null
}

variable "proxmox_insecure" {
  description = "Skip TLS verification for Proxmox API (common with home lab certs)"
  type        = bool
  default     = true
}

variable "proxmox_ssh_username" {
  description = "SSH user for bpg/proxmox provider operations that need node SSH"
  type        = string
  default     = "root"
}

variable "proxmox_node" {
  description = "Proxmox node name to place VMs on"
  type        = string
}

variable "template_id" {
  description = "VMID of the cloud-init template to clone (Ubuntu 22.04/24.04 recommended)"
  type        = number
}

variable "vm_datastore" {
  description = "Datastore for VM disks"
  type        = string
  default     = "local-lvm"
}

variable "snippet_datastore" {
  description = "Datastore that allows Snippets (for cloud-init user-data if used)"
  type        = string
  default     = "local"
}

variable "bridge" {
  description = "Linux bridge for VM NICs"
  type        = string
  default     = "vmbr0"
}

variable "vlan_id" {
  description = "Optional VLAN tag for VM NICs"
  type        = number
  default     = null
}

variable "ssh_user" {
  description = "Cloud-init / SSH user created on VMs"
  type        = string
  default     = "ubuntu"
}

variable "ssh_public_keys" {
  description = "SSH public keys injected via cloud-init"
  type        = list(string)
}

variable "dns_servers" {
  description = "DNS servers for cloud-init network config"
  type        = list(string)
  default     = ["1.1.1.1", "8.8.8.8"]
}

variable "gateway" {
  description = "Default IPv4 gateway for cluster nodes"
  type        = string
}

variable "control_plane" {
  description = "Control-plane node definition (single-node k3s by default)"
  type = object({
    name    = string
    vmid    = number
    cores   = number
    memory  = number
    disk_gb = number
    ip      = string
    cidr    = number
  })
  default = {
    name    = "k3s-cp-01"
    vmid    = 200
    cores   = 2
    memory  = 4096
    disk_gb = 40
    ip      = "192.168.1.20"
    cidr    = 24
  }
}

variable "workers" {
  description = "Worker node definitions"
  type = list(object({
    name    = string
    vmid    = number
    cores   = number
    memory  = number
    disk_gb = number
    ip      = string
    cidr    = number
  }))
  default = [
    {
      name    = "k3s-wk-01"
      vmid    = 201
      cores   = 2
      memory  = 4096
      disk_gb = 40
      ip      = "192.168.1.21"
      cidr    = 24
    },
    {
      name    = "k3s-wk-02"
      vmid    = 202
      cores   = 2
      memory  = 4096
      disk_gb = 40
      ip      = "192.168.1.22"
      cidr    = 24
    }
  ]
}

variable "cluster_name" {
  description = "Logical cluster name used in tags / Ansible inventory"
  type        = string
  default     = "homelab"
}