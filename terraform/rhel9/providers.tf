provider "proxmox" {
  endpoint = var.proxmox_endpoint
  # If null, bpg/proxmox reads PROXMOX_VE_API_TOKEN from the environment.
  api_token = var.proxmox_api_token
  insecure  = var.proxmox_insecure

  ssh {
    agent    = true
    username = var.proxmox_ssh_username
  }
}
