# Rollout Order

Recommended rollout sequence:

1. `global_identity`
2. `networking`
3. `platform_data`
4. `platform`
5. `project`

Use the same workspace name (second argument to `scripts/tofu-layer-run.sh`, for example `dev`, `stage`, `prod`) across layers in an environment so remote state, tfvars files, and dependencies stay aligned. That name selects `terraform.<profile>.<workspace>.tfvars` and the OpenTofu workspace (see `scripts/tofu-layer-run.sh`).
