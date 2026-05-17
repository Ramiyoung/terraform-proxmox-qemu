#!/usr/bin/env bash
# =============================================================================
# lvm-partition-setup.sh
#
# Exécuté UNE SEULE FOIS au premier boot via cloud-init (runcmd).
# Recrée le partitionnement du disque principal avec LVM, avec les
# points de montage séparés pour /, /home, /var, /var/log, /var/lib.
#
# Schéma de partitionnement (exemple pour un disque de 32G) :
#
#   /dev/vda1  200M   EFI / BIOS boot (non-LVM)
#   /dev/vda2  1G     /boot           (ext4, non-LVM)
#   /dev/vda3  reste  LVM PV → VG "system"
#     ├── LV root    →  /              (ext4)
#     ├── LV home    →  /home          (ext4)
#     ├── LV var     →  /var           (ext4)
#     ├── LV varlog  →  /var/log       (ext4)
#     ├── LV varlib  →  /var/lib       (ext4)
#     └── LV swap    →  swap
#
# Les tailles sont injectées via des variables d'environnement par cloud-init.
# Si elles ne sont pas définies, des valeurs par défaut raisonnables sont utilisées.
#
# ⚠️  CE SCRIPT EFFACE TOUTES LES DONNÉES SUR LE DISQUE CIBLE.
#     Il est conçu pour tourner sur une VM fraîchement clonée, sans données.
# =============================================================================
set -euo pipefail

# ─── Variables (surchargées par cloud-init via environment) ───────────────────
DISK="${LVM_DISK:-/dev/vda}"
VG_NAME="${LVM_VG_NAME:-system}"

# Tailles des LV (en GiB sauf indication contraire)
LV_ROOT_GB="${LVM_ROOT_GB:-8}"
LV_HOME_GB="${LVM_HOME_GB:-4}"
LV_VAR_GB="${LVM_VAR_GB:-4}"
LV_VARLOG_GB="${LVM_VARLOG_GB:-2}"
LV_VARLIB_GB="${LVM_VARLIB_GB:-6}"
LV_SWAP_GB="${LVM_SWAP_GB:-2}"

LOG_FILE="/var/log/lvm-partition-setup.log"

# ─── Logging ──────────────────────────────────────────────────────────────────
exec > >(tee -a "$LOG_FILE") 2>&1
echo "=== $(date -Iseconds) : Démarrage du partitionnement LVM ==="

# ─── Détection du disque ──────────────────────────────────────────────────────
# Proxmox avec virtio-scsi expose /dev/sda ; avec virtio-blk → /dev/vda
if [[ ! -b "$DISK" ]]; then
  for candidate in /dev/vda /dev/sda /dev/nvme0n1; do
    if [[ -b "$candidate" ]]; then
      DISK="$candidate"
      echo "Disque détecté automatiquement : $DISK"
      break
    fi
  done
fi
[[ -b "$DISK" ]] || { echo "ERREUR : Aucun disque bloc trouvé."; exit 1; }

DISK_SIZE_GB=$(( $(blockdev --getsize64 "$DISK") / 1024 / 1024 / 1024 ))
echo "Disque cible : $DISK (${DISK_SIZE_GB}G)"

# Vérification de la place disponible (marge de sécurité : 2G)
NEEDED=$(( LV_ROOT_GB + LV_HOME_GB + LV_VAR_GB + LV_VARLOG_GB + LV_VARLIB_GB + LV_SWAP_GB + 2 + 1 ))
if (( DISK_SIZE_GB < NEEDED )); then
  echo "ERREUR : Disque trop petit (${DISK_SIZE_GB}G < ${NEEDED}G requis)."
  exit 1
fi

# ─── Schéma de nommage des partitions ────────────────────────────────────────
# nvme0n1 → nvme0n1p1, nvme0n1p2, nvme0n1p3
# sda/vda → sda1, sda2, sda3
if [[ "$DISK" =~ nvme ]]; then
  PART_BOOT="${DISK}p1"
  PART_BOOTFS="${DISK}p2"
  PART_LVM="${DISK}p3"
else
  PART_BOOT="${DISK}1"
  PART_BOOTFS="${DISK}2"
  PART_LVM="${DISK}3"
fi

# ─── Démontage préventif ──────────────────────────────────────────────────────
echo "Démontage des partitions existantes…"
# Démonter dans l'ordre inverse (les sous-montages d'abord)
for mnt in /var/log /var/lib /var /home /boot /boot/efi; do
  mountpoint -q "$mnt" && umount "$mnt" || true
done

# Désactiver le swap LVM s'il existe
swapoff -a || true

# Désactiver les LV et VG existants si présents
if vgdisplay "$VG_NAME" &>/dev/null; then
  echo "Désactivation du VG $VG_NAME existant…"
  vgchange -an "$VG_NAME" || true
  vgremove -f "$VG_NAME" || true
fi

# ─── Partitionnement GPT avec sgdisk ──────────────────────────────────────────
echo "Création de la table de partitions GPT sur $DISK…"

# Effacer la table existante
sgdisk --zap-all "$DISK"

# Créer les partitions :
#   1 : BIOS boot (pour GRUB legacy, non utilisé avec UEFI mais utile en cas de mix)
#   2 : /boot (ext4, 1G)
#   3 : LVM PV (tout le reste)
sgdisk \
  --new=1:0:+1M    --typecode=1:ef02 --change-name=1:"BIOS boot" \
  --new=2:0:+1G    --typecode=2:8300 --change-name=2:"boot" \
  --new=3:0:0      --typecode=3:8e00 --change-name=3:"LVM" \
  "$DISK"

# Forcer la relecture de la table de partitions
partprobe "$DISK"
sleep 2  # laisser udev créer les device nodes

echo "Table de partitions créée :"
sgdisk --print "$DISK"

# ─── Formatage de /boot ───────────────────────────────────────────────────────
echo "Formatage de /boot (${PART_BOOTFS})…"
mkfs.ext4 -L boot -F "$PART_BOOTFS"

# ─── Création du Physical Volume et Volume Group ──────────────────────────────
echo "Création du PV sur $PART_LVM…"
pvcreate -ff -y "$PART_LVM"

echo "Création du VG '$VG_NAME'…"
vgcreate "$VG_NAME" "$PART_LVM"

# ─── Création des Logical Volumes ─────────────────────────────────────────────
echo "Création des Logical Volumes…"

lvcreate -L "${LV_ROOT_GB}G"    -n root    "$VG_NAME"
lvcreate -L "${LV_HOME_GB}G"    -n home    "$VG_NAME"
lvcreate -L "${LV_VAR_GB}G"     -n var     "$VG_NAME"
lvcreate -L "${LV_VARLOG_GB}G"  -n varlog  "$VG_NAME"
lvcreate -L "${LV_VARLIB_GB}G"  -n varlib  "$VG_NAME"
lvcreate -L "${LV_SWAP_GB}G"    -n swap    "$VG_NAME"

echo "Logical Volumes créés :"
lvs "$VG_NAME"

# ─── Formatage des LV ─────────────────────────────────────────────────────────
echo "Formatage des systèmes de fichiers…"

mkfs.ext4 -L root    "/dev/$VG_NAME/root"
mkfs.ext4 -L home    "/dev/$VG_NAME/home"
mkfs.ext4 -L var     "/dev/$VG_NAME/var"
mkfs.ext4 -L varlog  "/dev/$VG_NAME/varlog"
mkfs.ext4 -L varlib  "/dev/$VG_NAME/varlib"
mkswap    -L swap    "/dev/$VG_NAME/swap"

# ─── Montage et remplissage du nouveau système de fichiers ────────────────────
# On fait un pivot root : on copie tout le système courant vers le nouveau layout
NEWROOT="/mnt/newroot"
mkdir -p "$NEWROOT"

echo "Montage du nouveau root…"
mount "/dev/$VG_NAME/root" "$NEWROOT"

mkdir -p "$NEWROOT"/{boot,home,var}
mount "$PART_BOOTFS"          "$NEWROOT/boot"
mount "/dev/$VG_NAME/var"     "$NEWROOT/var"

mkdir -p "$NEWROOT/var/log" "$NEWROOT/var/lib"
mount "/dev/$VG_NAME/varlog"  "$NEWROOT/var/log"
mount "/dev/$VG_NAME/varlib"  "$NEWROOT/var/lib"
mount "/dev/$VG_NAME/home"    "$NEWROOT/home"

echo "Copie du système de fichiers courant vers le nouveau layout…"
# rsync -aHAX préserve : liens symboliques, attributs étendus, ACL, devices
rsync -aHAX --info=progress2 \
  --exclude=/proc \
  --exclude=/sys \
  --exclude=/dev \
  --exclude=/run \
  --exclude=/mnt \
  --exclude=/tmp \
  --exclude="$LOG_FILE" \
  / "$NEWROOT/"

# Recréer les points de montage manquants
for d in proc sys dev run tmp mnt; do
  mkdir -p "$NEWROOT/$d"
done
chmod 1777 "$NEWROOT/tmp"

# ─── Mise à jour de /etc/fstab ────────────────────────────────────────────────
echo "Génération du nouveau /etc/fstab…"
cat > "$NEWROOT/etc/fstab" <<FSTAB
# <file system>              <mount point>  <type>  <options>                <dump>  <pass>
LABEL=root                   /              ext4    defaults,errors=remount-ro  0       1
LABEL=boot                   /boot          ext4    defaults                    0       2
LABEL=home                   /home          ext4    defaults                    0       2
LABEL=var                    /var           ext4    defaults                    0       2
LABEL=varlog                 /var/log       ext4    defaults                    0       2
LABEL=varlib                 /var/lib       ext4    defaults                    0       2
LABEL=swap                   none           swap    sw                          0       0
FSTAB

echo "Nouveau /etc/fstab :"
cat "$NEWROOT/etc/fstab"

# ─── Mise à jour de GRUB ──────────────────────────────────────────────────────
echo "Mise à jour de GRUB dans le nouveau root…"

# Monter les pseudo-systèmes de fichiers pour le chroot
for d in proc sys dev dev/pts run; do
  mount --bind "/$d" "$NEWROOT/$d" || true
done

chroot "$NEWROOT" /bin/bash -euc "
  # Mettre à jour le fichier de configuration GRUB
  sed -i 's|GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"net.ifnames=0 biosdevname=0\"|' /etc/default/grub
  update-grub
  grub-install --target=i386-pc --recheck ${DISK}
  update-initramfs -u -k all
"

# Démonter le chroot
for d in dev/pts dev proc sys run; do
  umount "$NEWROOT/$d" || true
done

# ─── Nettoyage ────────────────────────────────────────────────────────────────
echo "Démontage du nouveau root…"
umount "$NEWROOT/home"
umount "$NEWROOT/var/log"
umount "$NEWROOT/var/lib"
umount "$NEWROOT/var"
umount "$NEWROOT/boot"
umount "$NEWROOT"

vgchange -an "$VG_NAME"

echo ""
echo "=== $(date -Iseconds) : Partitionnement LVM terminé avec succès ==="
echo ""
echo "Récapitulatif :"
echo "  Disque : $DISK"
echo "  VG     : $VG_NAME"
echo "  /          → /dev/$VG_NAME/root   (${LV_ROOT_GB}G)"
echo "  /boot      → $PART_BOOTFS         (1G)"
echo "  /home      → /dev/$VG_NAME/home   (${LV_HOME_GB}G)"
echo "  /var       → /dev/$VG_NAME/var    (${LV_VAR_GB}G)"
echo "  /var/log   → /dev/$VG_NAME/varlog (${LV_VARLOG_GB}G)"
echo "  /var/lib   → /dev/$VG_NAME/varlib (${LV_VARLIB_GB}G)"
echo "  swap       → /dev/$VG_NAME/swap   (${LV_SWAP_GB}G)"
echo ""
echo "La VM va redémarrer dans 5 secondes pour activer le nouveau layout."
sleep 5
reboot
