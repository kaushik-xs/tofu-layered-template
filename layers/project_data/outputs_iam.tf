output "iam_users" {
  description = "IAM users created from iam_users. Contains access_key_id and secret_access_key — marked sensitive. Retrieve with: tofu output -json iam_users. Empty map when iam_users is empty."
  sensitive   = true
  value = {
    for key, user in aws_iam_user.app : key => {
      arn               = user.arn
      username          = user.name
      access_key_id     = aws_iam_access_key.app[key].id
      secret_access_key = aws_iam_access_key.app[key].secret
    }
  }
}

output "iam_user_policies" {
  description = "Policy attachment per IAM user: inline_policy is the single embedded policy (used while it fits the 2048-character AWS limit), managed_policy_arns lists the customer managed policies created per permission group when it does not. Not sensitive — names and ARNs only."
  value = {
    for key, user in aws_iam_user.app : key => {
      username      = user.name
      inline_policy = try(aws_iam_user_policy.app[key].name, null)
      managed_policy_arns = [
        for pk, p in aws_iam_policy.app : p.arn
        if local._iam_managed_policies[pk].user_key == key
      ]
    }
  }
}
