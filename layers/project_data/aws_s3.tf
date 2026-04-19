resource "aws_s3_bucket" "app" {
  for_each = var.s3_buckets

  bucket        = each.value.bucket
  force_destroy = each.value.force_destroy

  tags = merge(
    { Name = each.value.bucket },
    each.value.tags,
  )
}

resource "aws_s3_bucket_versioning" "app" {
  for_each = var.s3_buckets

  bucket = aws_s3_bucket.app[each.key].id

  versioning_configuration {
    status = each.value.versioning_enabled ? "Enabled" : "Suspended"
  }
}

resource "aws_s3_bucket_public_access_block" "app" {
  for_each = var.s3_buckets

  bucket = aws_s3_bucket.app[each.key].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
