locals {
  # Resolved logical bucket keys per s3_access group, keyed "<user_key>/s3/<group index>".
  # ["*"] expands to every key in s3_buckets, so the Allow and Deny statements built from the same
  # group always target an identical set of buckets.
  _iam_s3_group_bucket_keys = {
    for item in flatten([
      for user_key, user in var.iam_users : [
        for idx, group in user.s3_access : {
          key         = "${user_key}/s3/${idx}"
          bucket_keys = contains(group.bucket_keys, "*") ? keys(var.s3_buckets) : group.bucket_keys
        }
      ]
    ]) : item.key => item.bucket_keys
  }

  # Resource ARNs per sqs_access group, keyed "<user_key>/sqs/<group index>". ["*"] expands to every key
  # in sqs_queues; include_dlqs additionally targets the companion dead-letter queue of each selected
  # queue that has dlq_enabled (needed for redrive and DLQ inspection).
  _iam_sqs_group_arns = {
    for item in flatten([
      for user_key, user in var.iam_users : [
        for idx, group in user.sqs_access : {
          key = "${user_key}/sqs/${idx}"
          arns = concat(
            [for qk in(contains(group.queue_keys, "*") ? keys(var.sqs_queues) : group.queue_keys) : aws_sqs_queue.app[qk].arn],
            group.include_dlqs ? [
              for qk in(contains(group.queue_keys, "*") ? keys(var.sqs_queues) : group.queue_keys) :
              aws_sqs_queue.dlq[qk].arn if contains(keys(aws_sqs_queue.dlq), qk)
            ] : [],
          )
        }
      ]
    ]) : item.key => item.arns
  }

  # One entry per permission group, keyed "<user_key>/s3|sqs/<group index>", carrying the IAM policy
  # statements that group produces. s3_access and sqs_access are lists of permission groups — each group
  # targets a subset of resources with its own actions, enabling per-resource permission differences on
  # the same user. deny_* actions emit explicit Deny statements over the same resources; an explicit Deny
  # always wins in IAM, so a group can grant broad access (e.g. s3:*) and carve destructive actions back out.
  # Groups are kept separate so an oversized user can be split into one managed policy per group below.
  _iam_access_groups = {
    for item in flatten([
      for user_key, user in var.iam_users : concat(
        [
          for idx, group in user.s3_access : {
            key      = "${user_key}/s3/${idx}"
            user_key = user_key
            name     = "${user.username}-s3-${idx}"
            statements = concat(
              # Bucket-level actions (e.g. s3:ListBucket) — applied to the bucket ARN itself
              length(group.bucket_actions) > 0 && length(local._iam_s3_group_bucket_keys["${user_key}/s3/${idx}"]) > 0 ? [
                {
                  Effect   = "Allow"
                  Action   = group.bucket_actions
                  Resource = [for bk in local._iam_s3_group_bucket_keys["${user_key}/s3/${idx}"] : aws_s3_bucket.app[bk].arn]
                }
              ] : [],
              # Object-level actions (e.g. s3:GetObject, s3:PutObject) — applied to objects inside the bucket
              length(group.object_actions) > 0 && length(local._iam_s3_group_bucket_keys["${user_key}/s3/${idx}"]) > 0 ? [
                {
                  Effect   = "Allow"
                  Action   = group.object_actions
                  Resource = [for bk in local._iam_s3_group_bucket_keys["${user_key}/s3/${idx}"] : "${aws_s3_bucket.app[bk].arn}/*"]
                }
              ] : [],
              # Explicit Deny on the bucket ARN (e.g. s3:DeleteBucket) — overrides the Allow above
              length(group.deny_bucket_actions) > 0 && length(local._iam_s3_group_bucket_keys["${user_key}/s3/${idx}"]) > 0 ? [
                {
                  Effect   = "Deny"
                  Action   = group.deny_bucket_actions
                  Resource = [for bk in local._iam_s3_group_bucket_keys["${user_key}/s3/${idx}"] : aws_s3_bucket.app[bk].arn]
                }
              ] : [],
              # Explicit Deny on objects (e.g. s3:DeleteObject) — overrides the Allow above
              length(group.deny_object_actions) > 0 && length(local._iam_s3_group_bucket_keys["${user_key}/s3/${idx}"]) > 0 ? [
                {
                  Effect   = "Deny"
                  Action   = group.deny_object_actions
                  Resource = [for bk in local._iam_s3_group_bucket_keys["${user_key}/s3/${idx}"] : "${aws_s3_bucket.app[bk].arn}/*"]
                }
              ] : [],
            )
          }
        ],
        [
          for idx, group in user.sqs_access : {
            key      = "${user_key}/sqs/${idx}"
            user_key = user_key
            name     = "${user.username}-sqs-${idx}"
            statements = concat(
              length(group.actions) > 0 && length(local._iam_sqs_group_arns["${user_key}/sqs/${idx}"]) > 0 ? [
                {
                  Effect   = "Allow"
                  Action   = group.actions
                  Resource = local._iam_sqs_group_arns["${user_key}/sqs/${idx}"]
                }
              ] : [],
              # Explicit Deny on the same queues (e.g. sqs:DeleteQueue, sqs:PurgeQueue)
              length(group.deny_actions) > 0 && length(local._iam_sqs_group_arns["${user_key}/sqs/${idx}"]) > 0 ? [
                {
                  Effect   = "Deny"
                  Action   = group.deny_actions
                  Resource = local._iam_sqs_group_arns["${user_key}/sqs/${idx}"]
                }
              ] : [],
            )
          }
        ],
      )
    ]) : item.key => item
  }

  _iam_users_with_access = {
    for k, u in var.iam_users : k => u
    if length(u.s3_access) > 0 || length(u.sqs_access) > 0
  }

  # Every statement for a user, S3 groups first then SQS groups — the single-document form.
  _iam_policy_statements = {
    for user_key, user in local._iam_users_with_access : user_key => flatten(concat(
      [for idx, _ in user.s3_access : local._iam_access_groups["${user_key}/s3/${idx}"].statements],
      [for idx, _ in user.sqs_access : local._iam_access_groups["${user_key}/sqs/${idx}"].statements],
    ))
  }

  _iam_policy_json = {
    for user_key, statements in local._iam_policy_statements : user_key => jsonencode({
      Version   = "2012-10-17"
      Statement = statements
    })
  }

  # AWS caps an inline user policy at 2048 characters and a customer managed policy at 6144.
  # Users that still fit keep the single inline policy; larger ones get one customer managed policy per
  # permission group instead, which both clears the inline cap and keeps each document well under 6144
  # as more buckets and queues are added.
  _iam_inline_users = {
    for k, u in local._iam_users_with_access : k => u
    if length(local._iam_policy_json[k]) <= 2048
  }

  _iam_managed_policies = {
    for key, group in local._iam_access_groups : key => group
    if length(group.statements) > 0 && length(lookup(local._iam_policy_json, group.user_key, "")) > 2048
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
  for_each = local._iam_inline_users

  name = "${each.value.username}-policy"
  user = aws_iam_user.app[each.key].name

  policy = local._iam_policy_json[each.key]
}

resource "aws_iam_policy" "app" {
  for_each = local._iam_managed_policies

  name        = each.value.name
  description = "project_data ${each.value.name} — generated from iam_users.${each.value.user_key}"

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = each.value.statements
  })

  lifecycle {
    precondition {
      condition     = length(jsonencode({ Version = "2012-10-17", Statement = each.value.statements })) <= 6144
      error_message = "IAM managed policy ${each.value.name} exceeds the 6144-character AWS limit. Split this permission group in iam_users into several groups with fewer bucket_keys / queue_keys, or trim its action lists."
    }
  }
}

resource "aws_iam_user_policy_attachment" "app" {
  for_each = local._iam_managed_policies

  user       = aws_iam_user.app[each.value.user_key].name
  policy_arn = aws_iam_policy.app[each.key].arn
}
