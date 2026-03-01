# terraform/main.tf

# 1. Leer el Contrato Maestro (Single Source of Truth)
locals {
  # Cargamos el archivo YAML
  lab_state = yamldecode(file("../lab-state.yaml"))
  
  # Filtramos SOLO las máquinas que tienen el estado "presente".
  # Si cambias el estado a "ausente" en el YAML, Terraform la destruirá automáticamente.
  active_vms = {
    for env in local.lab_state.entornos : env.nombre => env
    if env.estado == "presente"
  }
}

# 2. Iterar y crear las máquinas dinámicamente
resource "proxmox_vm_qemu" "entorno" {
  # Este for_each es el motor. Creará un recurso por cada elemento en active_vms
  for_each    = local.active_vms

  name        = each.value.nombre
  target_node = each.value.nodo_proxmox
  clone       = each.value.plantilla
  agent       = 1

  boot        = "order=scsi0;ide2"

  cpu {
    cores   = each.value.recursos.cores
    sockets = 1
    type    = "host"
  }

  memory = each.value.recursos.memoria
  scsihw = "virtio-scsi-single"
  
  disks {
    ide {
      ide2 {
        cloudinit {
          storage = "local-zfs"
        }
      }
    }
    scsi {
      scsi0 {
        disk {
          size     = 20
          storage  = "local-zfs"
          iothread = true
        }
      }
    }
  }

  network {
    id     = 0
    model  = "virtio"
    bridge = "vmbr0"
  }

  os_type   = "cloud-init"
  
  # Inyectamos la IP y el Gateway directamente desde el YAML
  ipconfig0 = "ip=${each.value.red.ip},gw=${each.value.red.gateway}"
  
  ciuser     = "admin"
  
  # Como es tu llave pública, está bien dejarla hardcodeada aquí.
  sshkeys    = <<EOF
  ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM9kG6lsmZBCtkdYOAIZwNJ5foJRHrRItjpNlQYrX4zT admin@eve
  EOF
}

