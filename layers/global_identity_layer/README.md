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

Manage multiple DNS record types for each hosted zone using one variable:

```hcl
route53_records = {
  "example.com" = [
    {
      name    = "@"
      type    = "A"
      ttl     = 300
      records = ["203.0.113.10"]
    },
    {
      name    = "www"
      type    = "CNAME"
      records = ["example.com"]
    }
  ]
}
```

## Constraints

- OpenTofu version is hard-pinned to `1.11.6`.
- Backend state is configured via S3 backend config at init time.

## Workspace argument (tfvars + OpenTofu)

The third argument to `scripts/tofu-layer-run.sh` is used for both `terraform.<AWS_PROFILE>.<workspace>.tfvars` and the OpenTofu workspace name (created if missing). Init uses an empty `workspace_key_prefix`, so state is not under `env:/...`; non-`default` workspaces use `<workspace>/<tf_state_key>/terraform_<profile>.tfstate` in the bucket.


## Resources 

This may contain the following resources

AWS
- Route53
- IAM

GCP
- IAM

Github
- Users, teams
