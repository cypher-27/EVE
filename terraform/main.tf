# terraform/main.tf

# 1. Leer el Contrato Maestro (Single Source of Truth)
locals {
  lab_state = yamldecode(file("../lab-state.yaml"))
  
  # Filtramos VMs activas
  active_vms = {
    for env in local.lab_state.entornos : env.nombre => env
    if env.estado == "presente" && try(env.tipo, "vm") == "vm"
  }

  # Filtramos LXCs activos
  active_lxcs = {
    for env in local.lab_state.entornos : env.nombre => env
    if env.estado == "presente" && try(env.tipo, "vm") == "lxc"
  }
}

# 2. Generador de contraseñas aleatorias para los LXC (Seguridad Zero-Touch)
resource "random_password" "lxc_password" {
  for_each = local.active_lxcs
  length   = 16
  special  = true
}

# ==============================================================================
# RECURSO 1: VIRTUAL MACHINES (KVM)
# ==============================================================================
resource "proxmox_vm_qemu" "entorno_vm" {
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
          # Leemos el disco desde el YAML
          size     = each.value.recursos.disco 
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
  ipconfig0 = "ip=${each.value.red.ip},gw=${each.value.red.gateway}"
  ciuser    = "admin"
  
  sshkeys   = <<EOF
  ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM9kG6lsmZBCtkdYOAIZwNJ5foJRHrRItjpNlQYrX4zT admin@eve
  EOF
}

# ==============================================================================
# RECURSO 2: LINUX CONTAINERS (LXC)
# ==============================================================================
resource "proxmox_lxc" "entorno_lxc" {
  for_each    = local.active_lxcs

  hostname    = each.value.nombre
  target_node = each.value.nodo_proxmox
  vmid        = each.value.vmid

  features {
    nesting = true # Permite correr systemd/docker dentro de forma más estable
  }
  
  # Plantilla base (Asegúrate de haberla descargado en Proxmox)
  ostemplate   = each.value.os == "alpine" ? "local:vztmpl/alpine-3.23-default_20260116_amd64.tar.xz" : "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
  unprivileged = true
  
  # Asignamos la contraseña generada aleatoriamente
  password     = random_password.lxc_password[each.key].result
  
  # Inyectamos tu llave SSH pública al root del contenedor
  ssh_public_keys = <<EOF
  ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM9kG6lsmZBCtkdYOAIZwNJ5foJRHrRItjpNlQYrX4zT admin@eve
  EOF

  cores  = each.value.recursos.cores
  memory = each.value.recursos.memoria

  rootfs {
    storage = "local-zfs"
    # Leemos el disco desde el YAML y le añadimos la "G" de Gigabytes
    size    = "${each.value.recursos.disco}G" 
  }

  network {
    name   = "eth0"
    bridge = "vmbr0"
    ip     = each.value.red.ip
    gw     = each.value.red.gateway
  }
  
  # Start on boot
  start = true
}
