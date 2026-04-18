# Rollout Order

Recommended rollout sequence:

1. `global_identity_layer`
2. `networking_layer`
3. `platform_data_layer`
4. `platform_layer`
5. `project_data_layer`
6. `project_layer`

Run each layer with the same OpenTofu workspace name (for example `dev`, `stage`, `prod`) so remote state and dependencies stay aligned per environment. Use matching `terraform.<profile>.<workspace>.tfvars` files and the layer-only `tf_state_key` prefix (see `scripts/tofu-layer-run.sh`).
