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
  for_each = local.active_vms

  name        = each.value.nombre
  vmid        = each.value.vmid
  target_node = each.value.nodo_proxmox
  clone       = each.value.plantilla
  full_clone  = true
  agent       = 1

  boot     = "order=scsi0"
  bootdisk = "scsi0"

  cpu {
    cores   = each.value.recursos.cores
    sockets = 1
    type    = "host"
  }

  memory = each.value.recursos.memoria
  scsihw = "virtio-scsi-single"

  disk {
    slot     = "scsi0"
    type     = "disk"
    storage  = try(each.value.efimero, false) && each.value.nodo_proxmox == "makima" ? "hdd_data" : "local-zfs"
    size     = "${each.value.recursos.disco}G"
    iothread = true
    discard  = true
    format   = "raw"
  }

  # Cloud-init — también como bloque legacy disk{} para consistencia con Telmate
  disk {
    slot    = "ide2"
    type    = "cloudinit"
    storage = "local-zfs"
  }

  network {
    id     = 0
    model  = "virtio"
    bridge = "vmbr0"
  }

  os_type   = "cloud-init"
  ipconfig0 = "ip=${each.value.red.ip},gw=${each.value.red.gateway}"
  ciuser    = "admin"

  # DNS explícito — no dependemos de lo que Proxmox tenga configurado por defecto
  nameserver = "1.1.1.1 8.8.8.8"

  sshkeys = <<EOF
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM9kG6lsmZBCtkdYOAIZwNJ5foJRHrRItjpNlQYrX4zT admin@eve
EOF

  # Terraform no marca el recurso como "listo" hasta que SSH responde de verdad.
  # Esto elimina el race condition entre "creado en Proxmox" y "OS realmente arriba".
  provisioner "remote-exec" {
    inline = ["echo 'VM lista — SSH y cloud-init confirmados'"]

    connection {
      type        = "ssh"
      user        = "admin"
      private_key = file("~/.ssh/eve_admin")
      host        = split("/", each.value.red.ip)[0]
      timeout     = "5m"
    }
  }

  lifecycle {
    ignore_changes = [
      clone,
      full_clone,
      disk,
      bootdisk,
      startup_shutdown,
    ]
  }
}

# ==============================================================================
# RECURSO 2: LINUX CONTAINERS (LXC)
# ==============================================================================
resource "proxmox_lxc" "entorno_lxc" {
  for_each = local.active_lxcs

  hostname    = each.value.nombre
  target_node = each.value.nodo_proxmox
  vmid        = each.value.vmid

  # Usamos nuestro nuevo Golden Template si es Alpine
  ostype     = each.value.os == "alpine" ? "alpine" : "debian"
  ostemplate = each.value.os == "alpine" ? "local:vztmpl/alpine-eve-custom.tar.zst" : "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"

  unprivileged = true
  password     = random_password.lxc_password[each.key].result

  # DNS explícito — la imagen custom de Alpine NO trae resolv.conf embebido,
  # así que dependía por completo del fallback del nodo Proxmox. Ya no.
  nameserver = "1.1.1.1 8.8.8.8"

  ssh_public_keys = <<EOF
  ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM9kG6lsmZBCtkdYOAIZwNJ5foJRHrRItjpNlQYrX4zT admin@eve
  EOF

  cores  = each.value.recursos.cores
  memory = each.value.recursos.memoria

  # Disco Principal (Root)
  rootfs {
    storage = try(each.value.efimero, false) && each.value.nodo_proxmox == "makima" ? "hdd_data" : "local-zfs"
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
      mp      = each.value.recursos.disco_datos.mp
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

  # Igual que en la VM: Terraform bloquea el apply hasta que SSH responda.
  # Root, porque así lo define ansible/node-config/setup_base.yml para tipo_lxc.
  provisioner "remote-exec" {
    inline = ["echo 'LXC listo — SSH confirmado'"]

    connection {
      type        = "ssh"
      user        = "root"
      private_key = file("~/.ssh/eve_admin")
      host        = split("/", each.value.red.ip)[0]
      timeout     = "3m"
    }
  }
}
