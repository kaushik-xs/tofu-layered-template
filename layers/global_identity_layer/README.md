# global_identity_layer

This layer hosts global identity and security integrations.

## Route53 Hosted Zones

Configure one or more hosted zones with a single variable:

```hcl
route53_hosted_zone_names = [
  "example.com",
  "example.org",
]
```

## Constraints

- OpenTofu version is hard-pinned to `1.11.6`.
- Backend state is configured via S3 backend config at init time.

## Workspace Usage

Use workspaces for environment boundaries (`dev`, `stage`, `prod`).


## Resources 

This may contain the following resources

AWS
- Route53
- IAM

GCP
- IAM

Github
- Users, teams
