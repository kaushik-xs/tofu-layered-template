# Layered OpenTofu Architecture

This repository defines six independent OpenTofu layers:

1. `global_identity_layer`
2. `networking_layer`
3. `platform_data_layer`
4. `platform_layer`
5. `project_data_layer`
6. `project_layer`

Each layer is a standalone OpenTofu project with workspace support.

## Hard Constraints

- OpenTofu must be exactly `1.11.6`.
- Every layer uses an S3 backend for state.
- Every layer includes AWS and GCP providers.
- `global_identity_layer` also includes GitHub and Vault providers.

## Directory Layout

- `layers/<layer_name>/`: one OpenTofu project per layer
- `.github/workflows/`: one manual rollout workflow per layer
- `scripts/tofu-layer-run.sh`: shared rollout script with strict version checks

## Backend State

Backend settings (`tf_state_bucket`, `tf_state_key`, `tf_state_region`, `tf_state_encrypt`) live in `terraform.<AWS_PROFILE>.tfvars` per layer (see `scripts/tofu-init-from-tfvars.sh`). `scripts/tofu-layer-run.sh` reads the same file for `tofu init` and passes `-var-file` for plan/apply.

Optional: `TF_STATE_DYNAMODB_TABLE` in the environment adds DynamoDB state locking.

GitHub Actions sets `AWS_PROFILE=ci`, writes `layers/<layer>/terraform.ci.tfvars` with the four `tf_state_*` values (bucket/region from repository secrets; key `opentofu/<layer_name>/<workspace>/terraform.tfstate`), then runs `tofu-layer-run.sh`.

## Local Usage

```bash
export AWS_PROFILE=regere
./scripts/tofu-init-from-tfvars.sh layers/global_identity_layer
./scripts/tofu-layer-run.sh global_identity_layer layers/global_identity_layer dev plan
```

Use a full `terraform.<profile>.tfvars` in the layer directory (not only backend keys) so `plan`/`apply` have all required variables.

## GitHub Actions Usage

Run one of the layer workflows manually and provide:

- `workspace`: target workspace (`dev`, `stage`, `prod`, etc.)
- `action`: `plan` or `apply`

See rollout order in `docs/rollout-order.md`.
