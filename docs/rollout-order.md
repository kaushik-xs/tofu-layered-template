# Rollout Order

Recommended rollout sequence:

1. `global_identity_layer`
2. `networking_layer`
3. `platform_data_layer`
4. `platform_layer`
5. `project_data_layer`
6. `project_layer`

Run each layer with the same workspace name to keep state and dependencies aligned per environment.
