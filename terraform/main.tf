# terraform/main.tf

resource "proxmox_vm_qemu" "test_server" {
  name        = "eve-test-01"
  target_node = "makima"
  clone       = "debian13-template"
  agent       = 1

  boot        = "order=scsi0;ide2"

  cpu {
    cores   = 1
    sockets = 1
    type    = "host"
  }

  memory  = 1024
  scsihw  = "virtio-scsi-single"
  
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
  ipconfig0 = "ip=192.168.1.50/24,gw=192.168.1.1"
  
  ciuser     = "admin"
  sshkeys    = <<EOF
  ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM9kG6lsmZBCtkdYOAIZwNJ5foJRHrRItjpNlQYrX4zT admin@eve
  EOF
}
