# Rollout Order

Recommended rollout sequence:

1. `global_identity_layer`
2. `networking_layer`
3. `platform_data_layer`
4. `platform_layer`
5. `project_data_layer`
6. `project_layer`

Use the same workspace name (third argument to `scripts/tofu-layer-run.sh`, for example `dev`, `stage`, `prod`) across layers in an environment so remote state, tfvars files, and dependencies stay aligned. That name selects `terraform.<profile>.<workspace>.tfvars` and the OpenTofu workspace (see `scripts/tofu-layer-run.sh`).
