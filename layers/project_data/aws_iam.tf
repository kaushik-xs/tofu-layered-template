locals {
  # Build the flat list of IAM policy statements for each user.
  # s3_access and sqs_access are lists of permission groups — each group targets a subset of
  # resources with its own actions, enabling per-resource permission differences on the same user.
  # ["*"] in bucket_keys / queue_keys expands to all logical keys defined in s3_buckets / sqs_queues.
  _iam_policy_statements = {
    for user_key, user in var.iam_users : user_key => concat(
      flatten([
        for group in user.s3_access : concat(
          # Bucket-level actions (e.g. s3:ListBucket) — applied to the bucket ARN itself
          length(group.bucket_actions) > 0 && length(group.bucket_keys) > 0 ? [
            {
              Effect   = "Allow"
              Action   = group.bucket_actions
              Resource = [for bk in (contains(group.bucket_keys, "*") ? keys(var.s3_buckets) : group.bucket_keys) : aws_s3_bucket.app[bk].arn]
            }
          ] : [],
          # Object-level actions (e.g. s3:GetObject, s3:PutObject) — applied to objects inside the bucket
          length(group.object_actions) > 0 && length(group.bucket_keys) > 0 ? [
            {
              Effect   = "Allow"
              Action   = group.object_actions
              Resource = [for bk in (contains(group.bucket_keys, "*") ? keys(var.s3_buckets) : group.bucket_keys) : "${aws_s3_bucket.app[bk].arn}/*"]
            }
          ] : [],
        )
      ]),
      flatten([
        for group in user.sqs_access : (
          length(group.actions) > 0 && length(group.queue_keys) > 0 ? [
            {
              Effect   = "Allow"
              Action   = group.actions
              Resource = [for qk in (contains(group.queue_keys, "*") ? keys(var.sqs_queues) : group.queue_keys) : aws_sqs_queue.app[qk].arn]
            }
          ] : []
        )
      ]),
    )
  }
}

resource "aws_iam_user" "app" {
  for_each = var.iam_users

  name = each.value.username

  tags = merge(
    { Name = each.value.username },
    each.value.tags,
  )
}

resource "aws_iam_access_key" "app" {
  for_each = var.iam_users

  user = aws_iam_user.app[each.key].name
}

resource "aws_iam_user_policy" "app" {
  for_each = {
    for k, u in var.iam_users : k => u
    if length(u.s3_access) > 0 || length(u.sqs_access) > 0
  }

  name = "${each.value.username}-policy"
  user = aws_iam_user.app[each.key].name

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local._iam_policy_statements[each.key]
  })
}
