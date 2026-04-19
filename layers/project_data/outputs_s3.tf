output "s3_buckets" {
  description = "Application S3 buckets from s3_buckets (id, arn, region). Empty map when s3_buckets is empty."
  value = {
    for key, b in aws_s3_bucket.app : key => {
      id     = b.id
      arn    = b.arn
      region = var.aws_region
    }
  }
}
