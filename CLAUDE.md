# opentofu-nuke

Multi-cloud Infrastructure-as-Code project built with **OpenTofu 1.11.6** (hard-pinned). Manages AWS and GCP resources across multiple environments using a six-layer architecture where each layer is an independent OpenTofu project sharing state via S3 remote backends.

## Architecture: Six-Layer Model

Layers must be deployed in this order (each may depend on the previous via remote state):

| # | Layer | Purpose |
|---|-------|---------|
| 1 | `global_identity` | Route53 hosted zones, IAM, GitHub/Vault integration |
| 2 | `networking` | VPCs, subnets, static IPs, firewall rules (AWS + GCP) |
| 3 | `platform_data` | Shared compute + databases (RDS, Cloud SQL) without DNS |
| 4 | `platform` | Shared application layer (placeholder) |
| 5 | `project_data` | Project compute + databases + S3, without DNS |
| 6 | `project` | Project runtime compute + Route53 DNS records |

## Key Constraints

- **OpenTofu version: 1.11.6** — do not change; enforced by `scripts/tofu-layer-run.sh`
- **Backend: AWS S3 + DynamoDB** — no local state, no other backends
- **Providers: AWS, GCP, GitHub, Vault** — configured in `layers/*/providers.tf`
- **Workspace naming:** `terraform.<aws_profile>.<workspace>.tfvars` — these files are gitignored; use `terraform.tfvars.example` as a template
- **tfvars examples:** whenever a variable is added or changed in any layer, the corresponding `terraform.tfvars.example` in that layer **must** be updated to reflect it

## Repository Layout

```
layers/                     # Six independent OpenTofu projects
  global_identity/          # IAM, Route53, GitHub, Vault
  networking/               # VPCs, subnets, static IPs, NAT, firewall
  platform_data/            # Shared compute + Cloud SQL + RDS
  platform/                 # Placeholder
  project_data/             # Project compute + RDS + Cloud SQL + S3
  project/                  # Project compute + Route53 DNS

scripts/
  tofu-layer-run.sh         # Master orchestration script — all layer ops run through here
  migration/gcp/
    cloudsql-export.sh      # Export Cloud SQL PostgreSQL
    vm-import.sh            # Import PostgreSQL into GCP VM (Docker)

playbooks/                  # Ansible roles for post-deployment config
  deployment.yml            # Main playbook
  db.yml                    # Database config playbook
  roles/                    # awscli, docker, caddy, zerotier, ufw, rclone, ghcli, etc.

.github/workflows/          # One GitHub Actions workflow per layer (manual dispatch)

docs/
  rollout-order.md          # Deployment sequence and workspace guide
```

## Modules (within layers)

Each layer that creates resources uses local modules under `layers/<layer>/modules/`:

**Networking layer:**
- `aws_region_networking` — VPCs, subnets, internet gateways, route tables
- `aws_region_static_ips` — Elastic IPs
- `gcp_project_networking` — VPCs, subnets, firewall rules, Cloud NAT, IAP SSH
- `gcp_project_static_ips` — Static external IPs

**Project / Project_data layers:**
- `aws_compute_instances` — EC2 (Amazon Linux 2023 / Ubuntu 24.04, Ansible provisioner, EIP association)
- `gcp_compute_instances` — Compute Engine VMs (similar capabilities)
- `aws_postgres_rds` — Amazon RDS PostgreSQL
- `gcp_postgres_cloudsql` — GCP Cloud SQL PostgreSQL

## Running Layers Locally

All layer operations go through `scripts/tofu-layer-run.sh`:

```bash
# Format: ./scripts/tofu-layer-run.sh <layer> <command> <aws_profile> <workspace>
./scripts/tofu-layer-run.sh networking plan <aws_profile> prod
./scripts/tofu-layer-run.sh project_data apply <aws_profile> dev
```

The script handles: OpenTofu version validation, S3 backend config injection, DynamoDB lock config, tfvars loading, workspace selection, and per-profile `TF_DATA_DIR` isolation.

## State Management

- Remote state in S3; workspace key prefix is empty (workspace-based organization)
- DynamoDB table used for optional state locking
- Each layer references upstream layer outputs via `terraform_remote_state` data sources
- Local `.terraform/` directories and lock files are gitignored

## Post-Deployment Automation

Compute modules use `local-exec` provisioners to run Ansible playbooks after instance creation. Template variables (`public_ip`, `private_ip`, `instance_id`, etc.) are passed to scripts. Inventory supports direct IP-based execution.

## CI/CD

GitHub Actions workflows in `.github/workflows/` — one per layer, triggered via `workflow_dispatch` (manual). Workflows run the same `tofu-layer-run.sh` script with environment-specific inputs.

## Environments / Profiles

`<aws_profile>` is an AWS credentials profile passed to `tofu-layer-run.sh`. Workspaces: `dev`, `stage`, `prod` (or custom names).

## Migration Scripts

Located in `scripts/migration/gcp/`:
- `cloudsql-export.sh` — Dumps a Cloud SQL PostgreSQL database to GCS
- `vm-import.sh` — Imports a PostgreSQL dump into a Docker-based PostgreSQL instance on a GCP VM; designed for local execution with SSH
