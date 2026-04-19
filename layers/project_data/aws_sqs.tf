locals {
  _sqs_with_dlq = { for k, v in var.sqs_queues : k => v if v.dlq_enabled }
}

resource "aws_sqs_queue" "dlq" {
  for_each = local._sqs_with_dlq

  name       = each.value.fifo_queue ? "${each.value.name}-dlq.fifo" : "${each.value.name}-dlq"
  fifo_queue = each.value.fifo_queue

  message_retention_seconds = each.value.message_retention_seconds

  tags = merge(
    { Name = each.value.fifo_queue ? "${each.value.name}-dlq.fifo" : "${each.value.name}-dlq" },
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
