# project

This layer hosts project runtime resources and services: **compute** (`computes`) and optional **Route53** records.

## Route53

**Hosted zones** are created in **global_identity** (`route53_hosted_zone_names`). This layer supports the same **`route53_records`** variable shape as global_identity; `aws_route53_record` resources use **zone IDs** from `global_identity` remote state (`global_identity_outputs.route53_hosted_zone_ids`). Split records between layers (e.g. identity DNS in global, app DNS in project) so the **same zone + name + type** is not managed in **both** stacks.
