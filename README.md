# Layered OpenTofu Architecture

This repository defines six independent OpenTofu layers:

1. `global_identity_layer`
2. `networking_layer`
3. `platform_data_layer`
4. `platform_layer`
5. `project_data_layer`
6. `project_layer`

Each layer is a standalone OpenTofu project; `scripts/tofu-layer-run.sh` uses `terraform.<profile>.<workspace>.tfvars` and selects or creates the OpenTofu workspace named `<workspace>` (the same value as the third argument).

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

Backend settings (`tf_state_bucket`, `tf_state_key`, `tf_state_region`, `tf_state_encrypt`) live in `terraform.<AWS_PROFILE>.<workspace>.tfvars` per layer. `tf_state_key` is a layer prefix (optionally encode environment in the path). The third script argument sets both the tfvars filename segment and the OpenTofu workspace name. `scripts/tofu-layer-run.sh` passes `workspace_key_prefix=` (empty) so remote state is not stored under the default `env:` path; non-default workspaces use `<workspace>/<tf_state_key>/...` in the bucket.

Optional: `TF_STATE_DYNAMODB_TABLE` in the environment adds DynamoDB state locking.

GitHub Actions sets `AWS_PROFILE=ci`, writes `layers/<layer>/terraform.ci.<workspace>.tfvars` with the four `tf_state_*` values (bucket/region from repository secrets; `tf_state_key` is `opentofu/<layer_name>`), then runs `tofu-layer-run.sh`.

## Local Usage

```bash
export AWS_PROFILE=<AWS_PROFILE>
./scripts/tofu-layer-run.sh global_identity_layer layers/global_identity_layer dev plan
```

Use a full `terraform.<profile>.<workspace>.tfvars` in the layer directory (not only backend keys) so `plan`/`apply` have all required variables. If you change backend or workspace layout, migrate remote state as needed (see OpenTofu S3 backend and workspace docs).

## GitHub Actions Usage

Run one of the layer workflows manually and provide:

- `workspace`: same value for `terraform.ci.<workspace>.tfvars` and OpenTofu workspace (`dev`, `stage`, `prod`, etc.)
- `action`: `plan` or `apply`

See rollout order in `docs/rollout-order.md`.
