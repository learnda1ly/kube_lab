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
  description = "VMID of the RHEL 9 cloud-init template to clone (not the Ubuntu k3s template)"
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
  description = "Linux bridge for RHEL 9 VM NICs (LAN; independent of k3s topology)"
  type        = string
  default     = "vmbr0"
}

variable "vlan_id" {
  description = "Optional VLAN tag for RHEL 9 VM NICs"
  type        = number
  default     = null
}

variable "ssh_user" {
  description = "Cloud-init / SSH user created on RHEL 9 VMs (cloud-user on official RHEL cloud images)"
  type        = string
  default     = "cloud-user"
}

variable "ssh_public_keys" {
  description = "SSH public keys injected via cloud-init"
  type        = list(string)
}

variable "dns_servers" {
  description = "DNS servers for RHEL 9 cloud-init network config"
  type        = list(string)
  default     = ["1.1.1.1", "8.8.8.8"]
}

variable "gateway" {
  description = "Default IPv4 gateway for RHEL 9 VMs"
  type        = string
}

variable "lab_name" {
  description = "Logical lab name used in Proxmox tags (not the k3s cluster_name)"
  type        = string
  default     = "rhel9-uf"
}

variable "hosts" {
  description = "RHEL 9 test hosts (Splunk UF install/upgrade targets; not k3s nodes)"
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
      name    = "rhel9-uf-01"
      vmid    = 240
      cores   = 2
      memory  = 2048
      disk_gb = 40
      ip      = "192.168.1.40"
      cidr    = 24
    },
    {
      name    = "rhel9-uf-02"
      vmid    = 241
      cores   = 2
      memory  = 2048
      disk_gb = 40
      ip      = "192.168.1.41"
      cidr    = 24
    },
    {
      name    = "rhel9-uf-03"
      vmid    = 242
      cores   = 2
      memory  = 2048
      disk_gb = 40
      ip      = "192.168.1.42"
      cidr    = 24
    }
  ]
}
