# terraform/main.tf

resource "proxmox_vm_qemu" "test_server" {
  name        = "eve-test-01"
  target_node = "makima"
  clone       = "debian13-template" # El nombre de tu template (ID 9000)

  # Configuración básica (puedes subirla si quieres, heredó 1GB/1C)
  cores   = 1
  memory  = 1024
  agent   = 1

  # Configuración de Disco
  scsihw = "virtio-scsi-single"
  
  disks {
    scsi {
      scsi0 {
        disk {
          size    = "20"
          storage = "local-zfs"
          iothread = true
        }
      }
    }
  }

  # Configuración de Red
  network {
    model  = "virtio"
    bridge = "vmbr0"
  }

  # Cloud-Init (La magia de la automatización)
  os_type = "cloud-init"
  ipconfig0 = "ip=192.168.1.50/24,gw=192.168.1.1" # IP temporal de prueba
  
  # Usuario y llaves SSH (Terraform las inyecta por ti)
  ciuser     = "admin"
  sshkeys    = <<EOF
  ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM9kG6lsmZBCtkdYOAIZwNJ5foJRHrRItjpNlQYrX4zT admin@eve
  EOF
}

