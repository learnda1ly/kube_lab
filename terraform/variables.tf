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
  description = "Datastore for the cloud-init drive (must support content-type images, e.g. local-lvm)"
  type        = string
  default     = "local-lvm"
}

variable "bridge" {
  description = "Linux bridge for k3s VM NICs (cluster / LAN)"
  type        = string
  default     = "vmbr0"
}

variable "vlan_id" {
  description = "Optional VLAN tag for k3s VM NICs"
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
  description = "DNS servers for k3s cloud-init network config"
  type        = list(string)
  default     = ["1.1.1.1", "8.8.8.8"]
}

variable "gateway" {
  description = "Default IPv4 gateway for k3s cluster nodes"
  type        = string
}

variable "lab_network" {
  description = "Proxmox NAT / lab bridge for non-k3s VMs (nfs-01). Create underlay with scripts/setup-lab-bridge.sh first."
  type = object({
    bridge      = string
    vlan_id     = optional(number)
    gateway     = string
    dns_servers = list(string)
  })
  default = {
    bridge      = "vmbr1"
    vlan_id     = null
    gateway     = "10.10.10.1"
    dns_servers = ["10.10.10.1", "1.1.1.1"]
  }
}

variable "lab_cidr" {
  description = "Lab / storage CIDR (vmbr1). Written to inventory for k3s static routes."
  type        = string
  default     = "10.10.10.0/24"
}

variable "proxmox_lan_ip" {
  description = "Proxmox host IPv4 on the LAN (vmbr0). Next-hop for k3s → lab_cidr routes."
  type        = string
  default     = "192.168.1.228"
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

variable "nfs_server" {
  description = "Dedicated NFS VM on lab_network for cluster persistent volumes (Splunk, etc.)"
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
    name    = "nfs-01"
    vmid    = 210
    cores   = 2
    memory  = 2048
    disk_gb = 200
    ip      = "10.10.10.30"
    cidr    = 24
  }
}

variable "nfs_export_path" {
  description = "Filesystem path exported by the NFS VM"
  type        = string
  default     = "/srv/nfs/k3s"
}

variable "nfs_client_cidr" {
  description = "CIDR allowed to mount the NFS export (k3s cluster LAN, not lab_cidr)"
  type        = string
  default     = "192.168.1.0/24"
}