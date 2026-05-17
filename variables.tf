# ─── Connexion Proxmox ────────────────────────────────────────────────────────

variable "proxmox_endpoint" {
  description = "URL de l'API Proxmox VE (ex: https://192.168.1.10:8006)"
  type        = string
}

variable "proxmox_api_token" {
  description = "Token API Proxmox au format 'user@realm!tokenid=uuid'"
  type        = string
  sensitive   = true
}

variable "proxmox_insecure" {
  description = "Désactiver la vérification TLS (utile avec un certificat auto-signé)"
  type        = bool
  default     = true
}

variable "proxmox_ssh_user" {
  description = "Utilisateur SSH pour les opérations nécessitant un accès shell (ex: root)"
  type        = string
  default     = "root"
}

# ─── Identité de la VM ────────────────────────────────────────────────────────

variable "vm_id" {
  description = "VMID unique dans Proxmox"
  type        = number
}

variable "vm_name" {
  description = "Nom de la VM"
  type        = string
}

variable "vm_description" {
  description = "Description affichée dans l'UI Proxmox"
  type        = string
  default     = ""
}

variable "node_name" {
  description = "Nœud Proxmox cible"
  type        = string
}

variable "clone_vm_id" {
  description = "VMID du template à cloner"
  type        = number
}

# ─── Ressources ───────────────────────────────────────────────────────────────

variable "cpu_cores" {
  description = "Nombre de cœurs vCPU"
  type        = number
}

variable "cpu_type" {
  description = "Type de CPU exposé à la VM"
  type        = string
  default     = "host"
}

variable "memory_mb" {
  description = "RAM en MiB"
  type        = number
}

variable "disk_size_gb" {
  description = "Taille du disque OS en GiB"
  type        = number
}

# ─── Stockage ─────────────────────────────────────────────────────────────────

variable "storage_pool" {
  description = "Datastore Proxmox pour le disque VM"
  type        = string
  default     = "local-lvm"
}

variable "cloudinit_storage_pool" {
  description = "Datastore pour les snippets cloud-init (doit avoir 'Snippets' activé)"
  type        = string
  default     = "local"
}

# ─── Réseau ───────────────────────────────────────────────────────────────────

variable "network_bridge" {
  description = "Bridge réseau Proxmox"
  type        = string
  default     = "vmbr0"
}

variable "ip_address" {
  description = "Adresse IP statique avec masque CIDR (ex: 192.168.1.10/24)"
  type        = string
}

variable "gateway" {
  description = "Passerelle par défaut"
  type        = string
}

variable "dns_servers" {
  description = "Serveurs DNS"
  type        = list(string)
  default     = ["1.1.1.1", "8.8.8.8"]
}

# ─── SSH & utilisateur cloud-init ─────────────────────────────────────────────

variable "ssh_public_key" {
  description = "Clé SSH publique à injecter via cloud-init"
  type        = string
}

variable "vm_user" {
  description = "Utilisateur créé par cloud-init"
  type        = string
  default     = "ubuntu"
}

# ─── Comportement de la VM ────────────────────────────────────────────────────

variable "tags" {
  description = "Tags Proxmox associés à la VM"
  type        = list(string)
  default     = []
}

variable "start_on_boot" {
  description = "Démarrer la VM automatiquement avec le nœud Proxmox"
  type        = bool
  default     = true
}

variable "vm_state" {
  description = "État souhaité de la VM après provisionnement (running / stopped)"
  type        = string
  default     = "running"
}

# ─── Partitionnement LVM ──────────────────────────────────────────────────────

variable "lvm_disk" {
  description = "Périphérique disque cible dans la VM (virtio-blk = /dev/vda, virtio-scsi = /dev/sda)"
  type        = string
  default     = "/dev/sda"
}

variable "lvm_vg_name" {
  description = "Nom du Volume Group LVM"
  type        = string
  default     = "system"
}

variable "lvm_root_gb" {
  description = "Taille du LV / en GiB"
  type        = number
  default     = 8
}

variable "lvm_home_gb" {
  description = "Taille du LV /home en GiB"
  type        = number
  default     = 4
}

variable "lvm_var_gb" {
  description = "Taille du LV /var en GiB"
  type        = number
  default     = 4
}

variable "lvm_varlog_gb" {
  description = "Taille du LV /var/log en GiB"
  type        = number
  default     = 2
}

variable "lvm_varlib_gb" {
  description = "Taille du LV /var/lib en GiB"
  type        = number
  default     = 6
}

variable "lvm_swap_gb" {
  description = "Taille du LV swap en GiB (0 = pas de swap)"
  type        = number
  default     = 2
}
