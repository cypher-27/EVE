# terraform/main.tf

# 1. Read the Master Contract (Single Source of Truth)
locals {
  lab_state = yamldecode(file("../lab-state.yaml"))

  # Filter active VMs
  active_vms = {
    for env in local.lab_state.entornos : env.nombre => env
    if env.estado == "presente" && try(env.tipo, "vm") == "vm"
  }

  # Filter active LXCs
  active_lxcs = {
    for env in local.lab_state.entornos : env.nombre => env
    if env.estado == "presente" && try(env.tipo, "vm") == "lxc"
  }
}

# 2. Random password generator for LXCs (Zero-Touch Security)
resource "random_password" "lxc_password" {
  for_each = local.active_lxcs
  length   = 16
  special  = true
}

# ==============================================================================
# RESOURCE 1: VIRTUAL MACHINES (KVM)
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

  # Cloud-init — also as a legacy disk{} block for consistency with Telmate
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

  # Explicit DNS — we don't rely on whatever Proxmox has configured by default
  nameserver = "1.1.1.1 8.8.8.8"

  sshkeys = <<EOF
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM9kG6lsmZBCtkdYOAIZwNJ5foJRHrRItjpNlQYrX4zT admin@eve
EOF

  # Terraform doesn't mark the resource as "ready" until SSH actually responds.
  # This eliminates the race condition between "created in Proxmox" and "OS actually up".
  provisioner "remote-exec" {
    inline = ["echo 'VM ready — SSH and cloud-init confirmed'"]

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
# RESOURCE 2: LINUX CONTAINERS (LXC)
# ==============================================================================
resource "proxmox_lxc" "entorno_lxc" {
  for_each = local.active_lxcs

  hostname    = each.value.nombre
  target_node = each.value.nodo_proxmox
  vmid        = each.value.vmid

  # We use our new Golden Template if it's Alpine
  ostype     = each.value.os == "alpine" ? "alpine" : "debian"
  ostemplate = each.value.os == "alpine" ? "local:vztmpl/alpine-eve-custom.tar.zst" : "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"

  unprivileged = true
  password     = random_password.lxc_password[each.key].result

  # Explicit DNS — the custom Alpine image does NOT ship resolv.conf,
  # so it used to depend entirely on the Proxmox node's fallback. Not anymore.
  nameserver = "1.1.1.1 8.8.8.8"

  ssh_public_keys = <<EOF
  ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM9kG6lsmZBCtkdYOAIZwNJ5foJRHrRItjpNlQYrX4zT admin@eve
  EOF

  cores  = each.value.recursos.cores
  memory = each.value.recursos.memoria

  # Primary Disk (Root)
  rootfs {
    storage = try(each.value.efimero, false) && each.value.nodo_proxmox == "makima" ? "hdd_data" : "local-zfs"
    size    = "${each.value.recursos.disco}G"
  }

  # Data Disk (Optional - only if present in the YAML)
  # Uses a dynamic block so it doesn't fail if the LXC has no disco_datos
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

  # Same as the VM: Terraform blocks the apply until SSH responds.
  # Root, because that's what ansible/node-config/setup_base.yml defines for LXC.
  provisioner "remote-exec" {
    inline = ["echo 'LXC ready — SSH confirmed'"]

    connection {
      type        = "ssh"
      user        = "root"
      private_key = file("~/.ssh/eve_admin")
      host        = split("/", each.value.red.ip)[0]
      timeout     = "3m"
    }
  }
}
