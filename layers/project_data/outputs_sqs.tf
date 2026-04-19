output "sqs_queues" {
  description = "SQS queues from sqs_queues (id/url, arn, region). Empty map when sqs_queues is empty."
  value = {
    for key, q in aws_sqs_queue.app : key => {
      id     = q.id
      arn    = q.arn
      region = var.aws_region
    }
  }
}

output "sqs_dlqs" {
  description = "Dead-letter queues for entries with dlq_enabled = true (id/url, arn, region). Empty map when none enabled."
  value = {
    for key, q in aws_sqs_queue.dlq : key => {
      id     = q.id
      arn    = q.arn
      region = var.aws_region
    }
  }
}
