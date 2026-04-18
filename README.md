# Layered OpenTofu Architecture

This repository defines six independent OpenTofu layers:

1. `global_identity_layer`
2. `networking_layer`
3. `platform_data_layer`
4. `platform_layer`
5. `project_data_layer`
6. `project_layer`

Each layer is a standalone OpenTofu project; `scripts/tofu-layer-run.sh` selects or creates a named workspace and uses `terraform.<profile>.<workspace>.tfvars`.

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

Backend settings (`tf_state_bucket`, `tf_state_key`, `tf_state_region`, `tf_state_encrypt`) live in `terraform.<AWS_PROFILE>.<workspace>.tfvars` per layer. `tf_state_key` is a layer prefix only (no environment segment). `scripts/tofu-layer-run.sh` reads that file for `tofu init`, selects or creates the OpenTofu workspace named `<workspace>`, and passes `-var-file` for plan/apply. Non-default workspace state objects in S3 use the path `env:/<workspace>/<tf_state_key>/terraform_<profile>.tfstate`.

Optional: `TF_STATE_DYNAMODB_TABLE` in the environment adds DynamoDB state locking.

GitHub Actions sets `AWS_PROFILE=ci`, writes `layers/<layer>/terraform.ci.<workspace>.tfvars` with the four `tf_state_*` values (bucket/region from repository secrets; `tf_state_key` is `opentofu/<layer_name>`), then runs `tofu-layer-run.sh`.

## Local Usage

```bash
export AWS_PROFILE=<AWS_PROFILE>
./scripts/tofu-layer-run.sh global_identity_layer layers/global_identity_layer dev plan
```

Use a full `terraform.<profile>.<workspace>.tfvars` in the layer directory (not only backend keys) so `plan`/`apply` have all required variables. If you previously used `terraform.<profile>.tfvars` and state keys that included the environment in the path, rename the file, shorten `tf_state_key` to the layer prefix, and migrate remote state into the workspace layout (see OpenTofu workspace and S3 backend docs).

## GitHub Actions Usage

Run one of the layer workflows manually and provide:

- `workspace`: target workspace (`dev`, `stage`, `prod`, etc.)
- `action`: `plan` or `apply`

See rollout order in `docs/rollout-order.md`.
