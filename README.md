# terraform-proxmox-qemu

Module Terraform pour créer une VM QEMU sur Proxmox VE via le provider [bpg/proxmox](https://github.com/bpg/terraform-provider-proxmox).

Fonctionnalités incluses :
- Clonage depuis un template cloud image
- Injection cloud-init (utilisateur, clé SSH, durcissement SSH)
- Partitionnement LVM au premier boot (layout `/`, `/home`, `/var`, `/var/log`, `/var/lib`, swap)

## Prérequis

| Élément | Version |
|---|---|
| Terraform | ≥ 1.6 |
| Provider bpg/proxmox | ~> 0.78 |
| Proxmox VE | 9.1.x |

---

## 1. Préparer le template Proxmox

Sur l'hôte Proxmox, exécuter **une seule fois** :

```bash
cd pve-template/
./create-template.sh [VMID] [STORAGE] [DISK_SIZE_GB]

# Exemple :
./create-template.sh 9000 local-lvm 32
```

Le script télécharge une image Ubuntu 24.04 LTS, y préinstalle `qemu-guest-agent`, `lvm2`, `parted` et le script de partitionnement, puis convertit la VM en template.

---

## 2. Créer un token API Proxmox

Dans l'UI : **Datacenter → Permissions → API Tokens → Add**

Ou en ligne de commande sur l'hôte Proxmox :

```bash
pveum user add terraform@pam --comment "Terraform provisioning"
pveum user token add terraform@pam qemu --privsep 0
pveum acl modify / -user terraform@pam -role Administrator
```

Le token est au format `terraform@pam!qemu=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`.

---

## 3. Utilisation

### En tant que module

```hcl
module "vm" {
  source = "github.com/Ramiyoung/terraform-proxmox-qemu"

  # Connexion Proxmox
  proxmox_endpoint  = "https://192.168.1.10:8006"
  proxmox_api_token = "terraform@pam!qemu=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
  proxmox_insecure  = true
  proxmox_ssh_user  = "root"

  # VM
  vm_id        = 100
  vm_name      = "my-vm"
  node_name    = "pve"
  clone_vm_id  = 9000

  cpu_cores    = 2
  memory_mb    = 2048
  disk_size_gb = 20

  # Réseau
  ip_address = "192.168.1.100/24"
  gateway    = "192.168.1.1"

  # Accès
  ssh_public_key = "ssh-ed25519 AAAAC3Nz..."
  vm_user        = "ubuntu"

  # LVM (optionnel — valeurs par défaut raisonnables)
  lvm_disk      = "/dev/sda"
  lvm_root_gb   = 8
  lvm_varlib_gb = 6
}

output "ssh" {
  value = "ssh ${module.vm.vm_name}@${module.vm.ip_address}"
}
```

### En standalone (apply direct)

```bash
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars    # renseigner endpoint, token, ssh_public_key, ip…

terraform init
terraform validate
terraform plan
terraform apply
```

---

## Variables

### Connexion Proxmox

| Variable | Type | Défaut | Description |
|---|---|---|---|
| `proxmox_endpoint` | string | — | URL de l'API Proxmox (ex: `https://192.168.1.10:8006`) |
| `proxmox_api_token` | string | — | Token API au format `user@realm!id=uuid` |
| `proxmox_insecure` | bool | `true` | Désactiver la vérification TLS |
| `proxmox_ssh_user` | string | `"root"` | Utilisateur SSH pour l'upload des snippets cloud-init |

### VM

| Variable | Type | Défaut | Description |
|---|---|---|---|
| `vm_id` | number | — | VMID unique dans Proxmox |
| `vm_name` | string | — | Nom de la VM |
| `vm_description` | string | `""` | Description affichée dans l'UI |
| `node_name` | string | — | Nœud Proxmox cible |
| `clone_vm_id` | number | — | VMID du template à cloner |
| `cpu_cores` | number | — | Nombre de vCPU |
| `cpu_type` | string | `"host"` | Type CPU exposé à la VM |
| `memory_mb` | number | — | RAM en MiB |
| `disk_size_gb` | number | — | Taille du disque OS en GiB |
| `storage_pool` | string | `"local-lvm"` | Datastore pour le disque |
| `cloudinit_storage_pool` | string | `"local"` | Datastore pour les snippets cloud-init |
| `network_bridge` | string | `"vmbr0"` | Bridge réseau Proxmox |
| `ip_address` | string | — | IP statique avec CIDR (ex: `192.168.1.10/24`) |
| `gateway` | string | — | Passerelle |
| `dns_servers` | list(string) | `["1.1.1.1", "8.8.8.8"]` | Serveurs DNS |
| `ssh_public_key` | string | — | Clé publique SSH injectée via cloud-init |
| `vm_user` | string | `"ubuntu"` | Utilisateur créé par cloud-init |
| `tags` | list(string) | `[]` | Tags Proxmox |
| `start_on_boot` | bool | `true` | Démarrage automatique avec l'hôte |
| `vm_state` | string | `"running"` | État après provisionnement |

### Partitionnement LVM

| Variable | Défaut | Description |
|---|---|---|
| `lvm_disk` | `"/dev/sda"` | Périphérique cible (virtio-scsi → `/dev/sda`, virtio-blk → `/dev/vda`) |
| `lvm_vg_name` | `"system"` | Nom du Volume Group |
| `lvm_root_gb` | `8` | Taille du LV `/` |
| `lvm_home_gb` | `4` | Taille du LV `/home` |
| `lvm_var_gb` | `4` | Taille du LV `/var` |
| `lvm_varlog_gb` | `2` | Taille du LV `/var/log` |
| `lvm_varlib_gb` | `6` | Taille du LV `/var/lib` |
| `lvm_swap_gb` | `2` | Taille du LV swap (`0` = pas de swap) |

---

## Outputs

| Output | Description |
|---|---|
| `vm_id` | VMID Proxmox de la VM créée |
| `vm_name` | Nom de la VM |
| `ip_address` | IP configurée via cloud-init |
| `ipv4_addresses` | IPs remontées par l'agent QEMU (après démarrage) |

---

## Détruire

```bash
terraform destroy
```
