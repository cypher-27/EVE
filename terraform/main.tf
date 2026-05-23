# terraform/main.tf

# 1. Leer el Contrato Maestro (Single Source of Truth)
locals {
  lab_state = yamldecode(file("../lab-state.yaml"))

  # Mapa de decisión: [Nodo][Entorno] = StoragePool
  storage_map = {
    "makima" = {
      "main" = "local-zfs" # SSD 100GB
      "dev"  = "hdd_data"  # HDD 850GB
    }
    "reze" = {
      "main" = "local-zfs" # HDD 850GB
      "dev"  = "local-zfs" # HDD 850GB (Porque no hay hdd_data)
    }
  }
  
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
  vmid        = each.value.vmid
  target_node = each.value.nodo_proxmox
  clone       = each.value.plantilla
  full_clone  = true
  agent       = 1

  boot   = "order=scsi0"

  cpu {
    cores   = each.value.recursos.cores
    sockets = 1
    type    = "host"
  }

  memory = each.value.recursos.memoria
  scsihw = "virtio-scsi-single"

  # SIN bloque disks — el clone hereda el disco de la plantilla (disk-0)
  # Terraform no toca los discos, Proxmox los maneja al clonar

  network {
    id     = 0
    model  = "virtio"
    bridge = "vmbr0"
  }

  os_type   = "cloud-init"
  ipconfig0 = "ip=${each.value.red.ip},gw=${each.value.red.gateway}"
  ciuser    = "admin"

  sshkeys = <<EOF
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM9kG6lsmZBCtkdYOAIZwNJ5foJRHrRItjpNlQYrX4zT admin@eve
EOF

  lifecycle {
    ignore_changes = [
      clone,
      full_clone,
      disk,
    ]
  }
}

# ==============================================================================
# RECURSO 2: LINUX CONTAINERS (LXC)
# ==============================================================================
resource "proxmox_lxc" "entorno_lxc" {
  for_each    = local.active_lxcs

  hostname    = each.value.nombre
  target_node = each.value.nodo_proxmox
  vmid        = each.value.vmid
  
  # Usamos nuestro nuevo Golden Template si es Alpine
  ostype       = each.value.os == "alpine" ? "alpine" : "debian"
  ostemplate   = each.value.os == "alpine" ? "local:vztmpl/alpine-eve-custom.tar.zst" : "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
  
  unprivileged = true
  password     = random_password.lxc_password[each.key].result
  
  ssh_public_keys = <<EOF
  ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM9kG6lsmZBCtkdYOAIZwNJ5foJRHrRItjpNlQYrX4zT admin@eve
  EOF

  cores  = each.value.recursos.cores
  memory = each.value.recursos.memoria
  
  # Disco Principal (Root)
  rootfs {
    # Aquí buscamos en el mapa usando el nodo y la variable que manda el orquestador
    storage = local.storage_map[each.value.nodo_proxmox][var.eve_env]
    size    = "${each.value.recursos.disco}G"
  }

  # Disco de Datos (Opcional - Solo si existe en el YAML)
  # Usamos un bloque dinámico para que no falle si el LXC no tiene disco_datos
  dynamic "mountpoint" {
    for_each = lookup(each.value.recursos, "disco_datos", null) != null ? [1] : []
    content {
      slot    = 0
      key     = "mp0"
      storage = each.value.recursos.disco_datos.storage
      mp      = "/var/lib/victoria-metrics" # Donde VM guarda los datos
      size    = each.value.recursos.disco_datos.size
    }
  }

  network {
    name   = "eth0"
    bridge = "vmbr0"
    ip     = each.value.red.ip
    gw     = each.value.red.gateway
  }

  features {
    nesting = true
  } 
  # Start on boot
  start = true
}
