# Terraform – Cluster Kubernetes sur Proxmox VE 9.x

Provisionnement d'un cluster Kubernetes (contrôleurs + workers) via Terraform
et le provider [bpg/proxmox](https://github.com/bpg/terraform-provider-proxmox).

## Prérequis

| Élément | Version |
|---|---|
| Terraform | ≥ 1.6 |
| Provider bpg/proxmox | ~> 0.78 |
| Proxmox VE | 9.1.x |

---

## Structure du projet

```
terraform-proxmox-k8s/
├── versions.tf               # Contraintes de version du provider
├── provider.tf               # Configuration du provider Proxmox
├── variables.tf              # Déclarations de toutes les variables
├── main.tf                   # Instanciation des modules (controllers + workers)
├── outputs.tf                # Sorties (IPs, noms, SSH)
├── terraform.tfvars.example  # Exemple de configuration (à copier)
└── modules/
    └── vm/
        ├── main.tf           # Ressource proxmox_virtual_environment_vm
        ├── variables.tf      # Variables du module
        └── outputs.tf        # Sorties du module
```

---

## 1. Préparer le template Proxmox (cloud-init)

Sur votre hôte Proxmox, exécuter **une seule fois** :

```bash
# Télécharger l'image Ubuntu 24.04 LTS (Noble) cloud
wget -q https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img \
  -O /var/lib/vz/images/noble-server-cloudimg-amd64.img

# Créer la VM template (VMID 9000)
qm create 9000 --name "ubuntu-2404-template" --memory 2048 --cores 2 \
  --net0 virtio,bridge=vmbr0 --ostype l26 --machine q35

# Importer le disque cloud
qm importdisk 9000 /var/lib/vz/images/noble-server-cloudimg-amd64.img local-lvm

# Configurer le disque et le boot
qm set 9000 --virtio0 local-lvm:vm-9000-disk-0,discard=on,iothread=1
qm set 9000 --boot order=virtio0
qm set 9000 --ide2 local:cloudinit
qm set 9000 --serial0 socket --vga serial0

# Activer l'agent QEMU (requis par le provider bpg)
qm set 9000 --agent enabled=1

# Convertir en template
qm template 9000
```

> **Pré-requis agent QEMU** : l'image cloud Ubuntu inclut `qemu-guest-agent` par défaut.

---

## 2. Créer un token API Proxmox

Dans l'UI Proxmox : **Datacenter → Permissions → API Tokens → Add**

Ou en ligne de commande :

```bash
# Créer l'utilisateur terraform (optionnel si on utilise root@pam)
pveum user add terraform@pam --comment "Terraform provisioning"

# Créer le token
pveum user token add terraform@pam k8s --privsep 0

# Attribuer les permissions nécessaires
pveum acl modify / -user terraform@pam -role Administrator
```

---

## 3. Configurer Terraform

```bash
# Cloner / copier ce répertoire
cd terraform-proxmox-k8s

# Copier et éditer les variables
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars
```

Variables clés à adapter :

| Variable | Description |
|---|---|
| `proxmox_endpoint` | URL de votre Proxmox (ex: `https://192.168.1.10:8006`) |
| `proxmox_api_token` | Token au format `user@realm!id=uuid` |
| `proxmox_node` | Nom du nœud Proxmox (visible dans l'UI) |
| `ssh_public_key` | Votre clé publique SSH |
| `vm_template_id` | VMID du template créé à l'étape 1 (défaut: 9000) |

---

## 4. Déployer

```bash
terraform init
terraform validate
terraform plan
terraform apply
```

Après `apply`, les IPs et commandes SSH sont affichées dans les outputs :

```
outputs:
  controllers = [{ name = "k8s-controller-01", ip_address = "192.168.1.110/24", vm_id = 200 }]
  workers     = [{ name = "k8s-worker-01", ... }, { name = "k8s-worker-02", ... }]
  ssh_connection_examples = [
    "ssh ubuntu@192.168.1.110  # k8s-controller-01",
    "ssh ubuntu@192.168.1.120  # k8s-worker-01",
    ...
  ]
```

---

## 5. Initialiser Kubernetes (kubeadm)

Une fois les VMs démarrées :

```bash
# Sur le contrôleur
ssh ubuntu@192.168.1.110
sudo kubeadm init --pod-network-cidr=10.244.0.0/16

# Copier la config kubectl
mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Installer un CNI (ex: Flannel)
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

# Sur chaque worker (avec le token affiché par kubeadm init)
sudo kubeadm join 192.168.1.110:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>
```

---

## Dimensionnement homelab (i7-4790K / 32 GiB / 2.75 To)

| Profil | Ctrl | Workers | RAM totale VMs | vCPU total |
|---|---|---|---|---|
| **Standalone (défaut)** | 1×(2c/4G/30G) | 2×(2c/6G/50G) | 16 GiB | 6 vCPU |
| **HA etcd** | 3×(2c/4G/30G) | 2×(2c/6G/50G) | 24 GiB | 10 vCPU |

> Proxmox lui-même consomme ~2-4 GiB de RAM. Le profil standalone laisse ~12-14 GiB libres
> pour l'overcommit ou des VMs supplémentaires.

---

## Détruire l'infrastructure

```bash
terraform destroy
```
