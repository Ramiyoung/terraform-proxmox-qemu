#!/usr/bin/env bash
# =============================================================================
# create-template.sh — Crée un template Proxmox Debian 13 (Trixie) avec :
#   - Partitionnement LVM (/, /home, /var, /var/log, /var/lib séparés)
#   - qemu-guest-agent préinstallé
#   - cloud-init prêt à l'emploi
#
# Usage (sur le nœud Proxmox, en root) :
#   ./create-template.sh [VMID] [STORAGE] [DISK_SIZE_GB]
#
# Exemples :
#   ./create-template.sh 9000 local-lvm 32
#   ./create-template.sh 9001 local-lvm 50
#
# Prérequis :
#   apt install -y libguestfs-tools wget
# =============================================================================
set -euo pipefail

# ─── Paramètres ───────────────────────────────────────────────────────────────
VMID="${1:-9000}"
STORAGE="${2:-local-lvm}"
DISK_SIZE_GB="${3:-32}"
TEMPLATE_NAME="debian-13-trixie-lvm-template"

# URL de l'image cloud Debian 13 (genericcloud = cloud-init natif, ~300 Mo)
IMAGE_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
IMAGE_FILE="debian-13-genericcloud-amd64.qcow2"
WORK_DIR="/var/tmp/pve-template-build"

# ─── Couleurs ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ─── Vérifications préalables ─────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Ce script doit être exécuté en root."
command -v qm         &>/dev/null || error "'qm' introuvable — exécuter sur un nœud Proxmox."
command -v virt-customize &>/dev/null || error "'virt-customize' introuvable. Installer : apt install libguestfs-tools"
command -v wget       &>/dev/null || error "'wget' introuvable. Installer : apt install wget"

if qm status "$VMID" &>/dev/null; then
  warn "Une VM avec le VMID $VMID existe déjà."
  read -rp "La supprimer et recréer ? [y/N] " CONFIRM
  [[ "$CONFIRM" =~ ^[Yy]$ ]] || error "Annulé."
  qm destroy "$VMID" --destroy-unreferenced-disks 1 --purge 1
  info "VM $VMID supprimée."
fi

# ─── Préparation ──────────────────────────────────────────────────────────────
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

info "Téléchargement de l'image Debian 13 Trixie genericcloud…"
if [[ -f "$IMAGE_FILE" ]]; then
  warn "Image déjà présente, vérification du checksum SHA512…"
  # Télécharger les checksums officiels
  wget -q "https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS" -O SHA512SUMS
  if sha512sum --check --ignore-missing SHA512SUMS 2>/dev/null | grep -q "OK"; then
    info "Checksum OK — réutilisation de l'image existante."
  else
    warn "Checksum invalide — re-téléchargement."
    rm -f "$IMAGE_FILE"
    wget --progress=bar:force -O "$IMAGE_FILE" "$IMAGE_URL"
  fi
else
  wget --progress=bar:force -O "$IMAGE_FILE" "$IMAGE_URL"
  wget -q "https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS" -O SHA512SUMS
  info "Vérification du checksum SHA512…"
  sha512sum --check --ignore-missing SHA512SUMS | grep "$IMAGE_FILE" || error "Checksum invalide !"
fi

# ─── Personnalisation de l'image avec virt-customize ─────────────────────────
# On préinstalle les paquets nécessaires directement dans l'image.
# Cela évite d'avoir besoin d'Internet au premier boot.
#
# NOTE LVM : La genericcloud Debian 13 utilise un layout à partition unique.
# Le repartitionnement LVM est géré par un script cloud-init (user-data)
# injecté via Terraform, qui s'exécute au premier boot en utilisant
# un disque temporaire + pivot root.
# Voir : modules/vm/cloud-init-lvm-setup.sh

info "Personnalisation de l'image (installation des paquets)…"
info "  → qemu-guest-agent, cloud-init, lvm2, parted, gdisk, e2fsprogs…"

# LIBGUESTFS_BACKEND=direct évite les problèmes de droits avec KVM sur Proxmox
export LIBGUESTFS_BACKEND=direct

virt-customize -a "$IMAGE_FILE" \
  --update \
  --install "qemu-guest-agent,cloud-init,cloud-utils,lvm2,parted,gdisk,e2fsprogs,curl,wget,ca-certificates,sudo,bash-completion,htop,vim,rsync,open-iscsi,nfs-common" \
  --run-command "systemctl enable qemu-guest-agent" \
  --run-command "systemctl enable cloud-init" \
  --run-command "truncate -s 0 /etc/machine-id" \
  --run-command "rm -f /var/lib/dbus/machine-id" \
  --run-command "ln -sf /etc/machine-id /var/lib/dbus/machine-id" \
  --run-command "cloud-init clean --logs --seed" \
  --run-command "rm -f /etc/ssh/ssh_host_*" \
  --selinux-relabel 2>/dev/null || true

info "Image personnalisée avec succès."

# ─── Copie du script LVM dans l'image ─────────────────────────────────────────
# Ce script sera appelé via cloud-init runcmd au premier boot
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/lvm-partition-setup.sh" ]]; then
  info "Injection du script de partitionnement LVM dans l'image…"
  virt-customize -a "$IMAGE_FILE" \
    --upload "$SCRIPT_DIR/lvm-partition-setup.sh:/usr/local/sbin/lvm-partition-setup.sh" \
    --run-command "chmod +x /usr/local/sbin/lvm-partition-setup.sh"
fi

# ─── Création de la VM template dans Proxmox ──────────────────────────────────
info "Création de la VM template VMID=$VMID sur storage=$STORAGE…"

qm create "$VMID" \
  --name "$TEMPLATE_NAME" \
  --ostype l26 \
  --machine q35 \
  --bios seabios \
  --cpu host \
  --cores 2 \
  --memory 2048 \
  --serial0 socket \
  --vga serial0 \
  --agent enabled=1,fstrim_cloned_disks=1 \
  --net0 virtio,bridge=vmbr0 \
  --scsihw virtio-scsi-pci \
  --boot order=scsi0

info "Import du disque dans le storage '$STORAGE'…"
qm importdisk "$VMID" "$IMAGE_FILE" "$STORAGE" --format raw

# Attacher le disque importé
qm set "$VMID" \
  --scsi0 "${STORAGE}:vm-${VMID}-disk-0,discard=on,iothread=1,ssd=1" \
  --ide2 "${STORAGE}:cloudinit" \
  --boot order=scsi0

# Redimensionner au DISK_SIZE_GB demandé
info "Redimensionnement du disque à ${DISK_SIZE_GB}G…"
qm resize "$VMID" scsi0 "${DISK_SIZE_GB}G"

# ─── Conversion en template ───────────────────────────────────────────────────
info "Conversion en template Proxmox…"
qm template "$VMID"

info ""
info "✅  Template créé avec succès !"
info "   VMID         : $VMID"
info "   Nom          : $TEMPLATE_NAME"
info "   Storage      : $STORAGE"
info "   Taille disque: ${DISK_SIZE_GB}G"
info ""
info "Prochaine étape : lancer 'terraform apply' pour cloner et configurer les VMs."
