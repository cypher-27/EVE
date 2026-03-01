terraform {
  required_providers {
    proxmox = {
      source  = "telmate/proxmox"
      version = "3.0.2-rc07"
    }
  }
}

provider "proxmox" {
  # Las credenciales y la URL se inyectan automáticamente desde SOPS
  # a través de las variables de entorno PM_API_URL, PM_API_TOKEN_ID, etc.
  pm_tls_insecure = true
}
