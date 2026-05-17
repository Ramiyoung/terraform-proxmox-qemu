# ─── Snippet cloud-init user-data stocké sur Proxmox ─────────────────────────
# Le provider bpg/proxmox permet d'uploader un fichier cloud-init "vendor"
# dans le datastore Proxmox (doit avoir le content type "Snippets" activé).
# Ce snippet est injecté en plus du cloud-init natif de Proxmox.

resource "proxmox_virtual_environment_file" "user_data" {
  content_type = "snippets"
  datastore_id = var.cloudinit_storage_pool
  node_name    = var.node_name

  source_raw {
    # Générer le user-data depuis le template en passant toutes les variables
    data = templatefile("${path.module}/user-data.yaml.tpl", {
      vm_user        = var.vm_user
      ssh_public_key = trimspace(var.ssh_public_key)

      lvm_disk      = var.lvm_disk
      lvm_vg_name   = var.lvm_vg_name
      lvm_root_gb   = var.lvm_root_gb
      lvm_home_gb   = var.lvm_home_gb
      lvm_var_gb    = var.lvm_var_gb
      lvm_varlog_gb = var.lvm_varlog_gb
      lvm_varlib_gb = var.lvm_varlib_gb
      lvm_swap_gb   = var.lvm_swap_gb
    })

    # Nom de fichier unique par VM pour éviter les collisions entre instances
    file_name = "ci-userdata-${var.vm_name}.yaml"
  }
}

# ─── VM QEMU ──────────────────────────────────────────────────────────────────

resource "proxmox_virtual_environment_vm" "this" {
  vm_id       = var.vm_id
  name        = var.vm_name
  description = var.vm_description
  node_name   = var.node_name

  tags            = var.tags
  on_boot         = var.start_on_boot
  vm_state        = var.vm_state
  stop_on_destroy = true

  # ─── Clonage depuis template ────────────────────────────────────────────────
  clone {
    vm_id = var.clone_vm_id
    full  = true            # Clone complet (pas de snapshot chaîné)
  }

  # ─── Agent QEMU ─────────────────────────────────────────────────────────────
  # Nécessaire pour que Proxmox récupère les IPs et fasse les fstrim
  agent {
    enabled = true
    trim    = true
    type    = "virtio"
  }

  # ─── CPU ────────────────────────────────────────────────────────────────────
  cpu {
    cores   = var.cpu_cores
    sockets = 1
    # "host" expose les instructions réelles du processeur physique
    # → meilleure perf pour containerd/runc et les workloads Kubernetes
    type    = var.cpu_type
    flags   = []
  }

  # ─── Mémoire ────────────────────────────────────────────────────────────────
  memory {
    dedicated = var.memory_mb
    # Ballooning désactivé : évite que le driver mémoire fausse
    # les métriques de ressources utilisées par le scheduler Kubernetes
    floating  = 0
  }

  # ─── Disque OS ──────────────────────────────────────────────────────────────
  # virtio-scsi expose /dev/sda dans la VM (cohérent avec lvm_disk = /dev/sda)
  disk {
    datastore_id = var.storage_pool
    interface    = "scsi0"
    size         = var.disk_size_gb
    discard      = "on"         # TRIM/UNMAP pour récupérer l'espace libéré
    iothread     = true         # Un thread I/O dédié par disque (perf ++)
    file_format  = "raw"        # Format raw = pas de surcoût de conversion
    ssd          = true         # Indique à l'OS que c'est du SSD (trimming)
  }

  # ─── Réseau ─────────────────────────────────────────────────────────────────
  network_device {
    bridge  = var.network_bridge
    model   = "virtio"
    enabled = true
  }

  # ─── Cloud-Init ─────────────────────────────────────────────────────────────
  initialization {
    datastore_id      = var.cloudinit_storage_pool
    # Référence le snippet user-data uploadé ci-dessus
    user_data_file_id = proxmox_virtual_environment_file.user_data.id

    ip_config {
      ipv4 {
        address = var.ip_address
        gateway = var.gateway
      }
    }

    dns {
      servers = var.dns_servers
    }
  }

  # ─── Options BIOS / Machine ─────────────────────────────────────────────────
  bios    = "seabios"
  machine = "q35"             # Q35 = chipset moderne, meilleur support PCIe

  # ─── Affichage (headless pour VMs serveur) ──────────────────────────────────
  vga {
    type   = "serial0"
    memory = 0
  }

  # ─── Ordre de boot ──────────────────────────────────────────────────────────
  boot_order = ["scsi0"]

  # ─── Dépendance : le snippet doit exister avant que la VM démarre ───────────
  depends_on = [proxmox_virtual_environment_file.user_data]

  lifecycle {
    # Ne pas redéployer la VM si le fichier user-data change après le premier apply
    # (le partitionnement ne doit tourner qu'une fois)
    ignore_changes = [
      initialization[0].user_data_file_id,
    ]
  }
}
