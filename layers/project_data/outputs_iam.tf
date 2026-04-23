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
