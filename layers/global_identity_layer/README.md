# global_identity_layer

This layer hosts global identity and security integrations.

## Constraints

- OpenTofu version is hard-pinned to `1.11.6`.
- Backend state is configured via S3 backend config at init time.

## Workspace Usage

Use workspaces for environment boundaries (`dev`, `stage`, `prod`).
