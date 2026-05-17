# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

This repository contains reusable Terraform modules. Currently implemented: **terraform-proxmox-k8s** — deploys a Kubernetes cluster (control plane + workers) on Proxmox VE using cloud-init and LVM partitioning.

## Common Commands

```bash
# From terraform-proxmox-k8s/
terraform init
terraform validate
terraform fmt -recursive
terraform plan
terraform apply
terraform destroy

# Check formatting only
terraform fmt -check -recursive
```

## Module Structure

```
terraform-proxmox-k8s/        # Root module: deploys full K8s cluster
├── modules/vm/               # Reusable VM primitive (clone + cloud-init + LVM)
│   └── user-data.yaml.tpl    # Cloud-init template rendered per VM
└── pve-template/             # Run on Proxmox host — creates the base VM template
    ├── create-template.sh    # Downloads cloud image, injects packages, converts to template
    └── lvm-partition-setup.sh # Copied into template image; runs at first VM boot
```

## Two-Phase Deployment

**Phase 1 — Template** (run once on the Proxmox host):
```bash
cd pve-template/
./create-template.sh [VMID] [STORAGE] [DISK_SIZE_GB]
# e.g.: ./create-template.sh 9000 local-lvm 32
```
This creates VMID 9000 (default): Ubuntu 24.04 cloud image with qemu-guest-agent, lvm2, parted, and `lvm-partition-setup.sh` pre-installed at `/usr/local/sbin/`.

**Phase 2 — Cluster** (standard Terraform workflow):
```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set proxmox_endpoint, proxmox_api_token, ssh_public_key
terraform init && terraform apply
```

Kubernetes itself is not managed by Terraform — use `kubeadm init` / `kubeadm join` after the VMs are up (outputs provide IPs and SSH commands).

## Architecture

The root module instantiates `modules/vm` twice via `count`: once for controllers (`k8s-controller-0N`, VMIDs 200+) and once for workers (`k8s-worker-0N`, VMIDs 210+). Both sets share the same VM module; differentiation comes from variables (CPU, RAM, disk, IP prefix, LVM sizes).

### Cloud-init + LVM Flow (first boot only)

`modules/vm/main.tf` uploads a rendered `user-data.yaml.tpl` as a Proxmox snippet, then clones the template. On first boot:
1. Cloud-init runs `lvm-partition-setup.sh` via `runcmd`
2. Script partitions the disk (GPT: BIOS boot + `/boot` + LVM PV), creates LVs, pivot-roots the running system, updates fstab/GRUB, and reboots
3. Sentinel file `/etc/cloud/lvm-setup-pending` prevents re-running on subsequent boots
4. `lifecycle { ignore_changes = [initialization] }` prevents Terraform from re-triggering this after the first apply

### Key LVM Sizing Distinction

| Partition | Controller default | Worker default |
|---|---|---|
| `/var/lib` | 8 GiB (etcd) | 25 GiB (containerd images) |

All other LVM sizes are shared variables. Adjust `controller_lvm_varlib_gb` / `worker_lvm_varlib_gb` before applying — resizing after is manual.

### Provider Constraints

```hcl
terraform >= 1.6.0
bpg/proxmox ~> 0.78
```

`~> 0.78` allows minor/patch upgrades within the 0.x series but blocks 1.0 until tested. The `bpg/proxmox` provider requires both API token access and an SSH connection to the Proxmox host (used to upload cloud-init snippets to the local datastore).

## Module Style Notes

- Variables controlling LVM sizes are split per role (controller vs worker) — keep this pattern when adding new roles.
- Cloud-init filenames are scoped per VM (`ci-userdata-${vm_name}.yaml`) to avoid collisions during scaling.
- Memory ballooning is disabled intentionally — fixed RAM allocation is required for accurate Kubernetes scheduler metrics.
- `cpu_type = "host"` is intentional — exposes native CPU instructions (nested virt, AVX, etc.) needed for container workloads.
