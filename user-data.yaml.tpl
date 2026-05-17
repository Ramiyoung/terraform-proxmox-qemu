#cloud-config
# =============================================================================
# user-data.yaml.tpl — Injecté via Terraform templatefile()
# Gère : compte sudoers, SSH, partitionnement LVM au premier boot
# =============================================================================

# ─── Comportement global ──────────────────────────────────────────────────────
# Désactiver la création de l'utilisateur par défaut "debian" du provider
users:
  - name: ${vm_user}
    gecos: "${vm_user} admin"
    groups: [sudo, adm, systemd-journal]
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: true                  # Connexion par mot de passe désactivée
    ssh_authorized_keys:
      - ${ssh_public_key}

# Désactiver root SSH
disable_root: true

# ─── Paramètres SSH ───────────────────────────────────────────────────────────
ssh_pwauth: false                      # Authentification par mot de passe SSH : off

# Regénérer les clés hôtes SSH (propres à chaque clone)
ssh_deletekeys: true
ssh_genkeytypes: [rsa, ecdsa, ed25519]

# ─── Configuration système de base ────────────────────────────────────────────
package_update: true
package_upgrade: false                 # Upgrade complet différé (trop lent au boot)

packages:
  - qemu-guest-agent
  - lvm2
  - parted
  - gdisk
  - e2fsprogs
  - cloud-utils
  - rsync
  - net-tools

# ─── Partitionnement LVM (premier boot uniquement) ────────────────────────────
# Le script /usr/local/sbin/lvm-partition-setup.sh a été préinstallé
# dans l'image par virt-customize (create-template.sh).
# On lui passe les tailles via des variables d'environnement.
#
# ⚠️  ATTENTION : ce runcmd provoque un reboot à la fin.
#     cloud-init marque sa propre phase comme terminée avant le reboot,
#     donc les modules suivants (final) tournent au second boot.
#
# cloud-init garantit que runcmd ne s'exécute qu'une seule fois (first boot).

write_files:
  # Fichier sentinel : si présent, le partitionnement a déjà été fait
  - path: /etc/cloud/lvm-setup-pending
    content: "1"
    permissions: "0644"

  # Configuration sudoers sécurisée (pas de TTY requis pour les scripts)
  - path: /etc/sudoers.d/90-cloud-init-users
    content: |
      # Généré par cloud-init — ne pas modifier manuellement
      ${vm_user} ALL=(ALL) NOPASSWD:ALL
    permissions: "0440"

  # Hardening SSH de base
  - path: /etc/ssh/sshd_config.d/99-hardening.conf
    content: |
      # Cloud-init hardening SSH
      PermitRootLogin no
      PasswordAuthentication no
      ChallengeResponseAuthentication no
      PubkeyAuthentication yes
      AuthorizedKeysFile .ssh/authorized_keys
      X11Forwarding no
      AllowAgentForwarding no
      MaxAuthTries 3
      LoginGraceTime 30
    permissions: "0644"

runcmd:
  # Activer l'agent QEMU immédiatement
  - systemctl enable --now qemu-guest-agent

  # Lancer le partitionnement LVM si le sentinel est présent
  - |
    if [ -f /etc/cloud/lvm-setup-pending ]; then
      export LVM_DISK="${lvm_disk}"
      export LVM_VG_NAME="${lvm_vg_name}"
      export LVM_ROOT_GB="${lvm_root_gb}"
      export LVM_HOME_GB="${lvm_home_gb}"
      export LVM_VAR_GB="${lvm_var_gb}"
      export LVM_VARLOG_GB="${lvm_varlog_gb}"
      export LVM_VARLIB_GB="${lvm_varlib_gb}"
      export LVM_SWAP_GB="${lvm_swap_gb}"
      rm -f /etc/cloud/lvm-setup-pending
      /usr/local/sbin/lvm-partition-setup.sh
    fi

# ─── Finalisation ─────────────────────────────────────────────────────────────
final_message: |
  Cloud-init terminé pour ${vm_user}@$HOSTNAME.
  Durée : $UPTIME secondes depuis le boot.
