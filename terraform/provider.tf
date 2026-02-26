# terraform/provider.tf

terraform {
  required_providers {
    proxmox = {
      source  = "telmate/proxmox"
      version = "3.0.2-rc06"
    }
  }
}

provider "proxmox" {
  # URL de la API de Makima (o Reze)
  pm_api_url          = "https://192.168.1.20:8006/api2/json"
  
  # Token de seguridad (Usaremos variables para no exponer el Secret)
  pm_api_token_id     = var.proxmox_token_id
  pm_api_token_secret = var.proxmox_token_secret
  
  # Como usamos certificados auto-firmados en el lab, desactivamos la validación SSL
  pm_tls_insecure     = true
}

