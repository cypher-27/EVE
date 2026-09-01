terraform {
  required_providers {
    proxmox = {
      source  = "telmate/proxmox"
      version = "3.0.2-rc07"
    }
  }
}

provider "proxmox" {
  # Credentials and URL are injected automatically from SOPS via
  # environment variables PM_API_URL, PM_API_TOKEN_ID, etc.
  pm_tls_insecure = true
}
