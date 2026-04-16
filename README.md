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

GitHub Actions passes backend configuration at init time:

- `TF_STATE_BUCKET`
- `TF_STATE_REGION`
- `TF_STATE_DYNAMODB_TABLE` (optional)

State key format:

- `opentofu/<layer_name>/<workspace>/terraform.tfstate`

## Local Usage

```bash
tofu init \
  -backend-config="bucket=$TF_STATE_BUCKET" \
  -backend-config="region=$TF_STATE_REGION" \
  -backend-config="key=opentofu/networking_layer/dev/terraform.tfstate"
tofu workspace select dev || tofu workspace new dev
tofu plan
```

## GitHub Actions Usage

Run one of the layer workflows manually and provide:

- `workspace`: target workspace (`dev`, `stage`, `prod`, etc.)
- `action`: `plan` or `apply`

See rollout order in `docs/rollout-order.md`.
