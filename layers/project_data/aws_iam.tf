locals {
  # Resolve effective bucket/queue keys — ["*"] expands to all logical keys from the respective map variables
  _iam_s3_bucket_keys = {
    for user_key, user in var.iam_users : user_key =>
    user.s3_access != null
    ? (contains(user.s3_access.bucket_keys, "*") ? keys(var.s3_buckets) : user.s3_access.bucket_keys)
    : []
  }

  _iam_sqs_queue_keys = {
    for user_key, user in var.iam_users : user_key =>
    user.sqs_access != null
    ? (contains(user.sqs_access.queue_keys, "*") ? keys(var.sqs_queues) : user.sqs_access.queue_keys)
    : []
  }

  # Build the flat list of IAM policy statements for each user
  _iam_policy_statements = {
    for user_key, user in var.iam_users : user_key => concat(
      # S3 bucket-level actions (e.g. s3:ListBucket) — applied to the bucket ARN itself
      (user.s3_access != null
        && length(user.s3_access.bucket_actions) > 0
      && length(local._iam_s3_bucket_keys[user_key]) > 0) ? [
        {
          Effect   = "Allow"
          Action   = user.s3_access.bucket_actions
          Resource = [for bk in local._iam_s3_bucket_keys[user_key] : aws_s3_bucket.app[bk].arn]
        }
      ] : [],
      # S3 object-level actions (e.g. s3:GetObject, s3:PutObject) — applied to objects inside the bucket
      (user.s3_access != null
        && length(user.s3_access.object_actions) > 0
      && length(local._iam_s3_bucket_keys[user_key]) > 0) ? [
        {
          Effect   = "Allow"
          Action   = user.s3_access.object_actions
          Resource = [for bk in local._iam_s3_bucket_keys[user_key] : "${aws_s3_bucket.app[bk].arn}/*"]
        }
      ] : [],
      # SQS actions — applied to the queue ARN
      (user.sqs_access != null
        && length(user.sqs_access.actions) > 0
      && length(local._iam_sqs_queue_keys[user_key]) > 0) ? [
        {
          Effect   = "Allow"
          Action   = user.sqs_access.actions
          Resource = [for qk in local._iam_sqs_queue_keys[user_key] : aws_sqs_queue.app[qk].arn]
        }
      ] : [],
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
    if u.s3_access != null || u.sqs_access != null
  }

  name = "${each.value.username}-policy"
  user = aws_iam_user.app[each.key].name

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local._iam_policy_statements[each.key]
  })
}
