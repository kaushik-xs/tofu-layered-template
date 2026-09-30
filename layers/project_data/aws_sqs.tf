locals {
  _sqs_with_dlq = { for k, v in var.sqs_queues : k => v if v.dlq_enabled }

  # Companion dead-letter queue name per queue with dlq_enabled. Also used by aws_iam.tf to build DLQ ARNs.
  _sqs_dlq_names = { for k, v in local._sqs_with_dlq : k => v.fifo_queue ? "${v.name}-dlq.fifo" : "${v.name}-dlq" }
}

resource "aws_sqs_queue" "dlq" {
  for_each = local._sqs_with_dlq

  name       = local._sqs_dlq_names[each.key]
  fifo_queue = each.value.fifo_queue

  message_retention_seconds = each.value.message_retention_seconds

  tags = merge(
    { Name = local._sqs_dlq_names[each.key] },
    each.value.tags,
  )
}

resource "aws_sqs_queue" "app" {
  for_each = var.sqs_queues

  name       = each.value.name
  fifo_queue = each.value.fifo_queue

  visibility_timeout_seconds = each.value.visibility_timeout_seconds
  message_retention_seconds  = each.value.message_retention_seconds
  max_message_size           = each.value.max_message_size
  delay_seconds              = each.value.delay_seconds
  receive_wait_time_seconds  = each.value.receive_wait_time_seconds

  redrive_policy = each.value.dlq_enabled ? jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[each.key].arn
    maxReceiveCount     = each.value.dlq_max_receive_count
  }) : null

  tags = merge(
    { Name = each.value.name },
    each.value.tags,
  )
}
