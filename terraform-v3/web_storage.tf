# Private static web origin.

resource "aws_s3_bucket" "web" {
  # checkov:skip=CKV2_AWS_62:Static web assets do not drive an event workflow.
  # checkov:skip=CKV_AWS_144:Cross-Region replication is customer-selected from recovery and data residency requirements.
  # checkov:skip=CKV_AWS_145:SSE-S3 protects non-confidential static assets and avoids granting CloudFront access to the document KMS key.
  bucket = "${local.name}-web-${local.account}-${random_id.suffix.hex}"
}

resource "aws_s3_bucket_public_access_block" "web" {
  bucket                  = aws_s3_bucket.web.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "web" {
  bucket = aws_s3_bucket.web.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "web" {
  bucket = aws_s3_bucket.web.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "web" {
  bucket = aws_s3_bucket.web.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "web" {
  bucket = aws_s3_bucket.web.id

  depends_on = [aws_s3_bucket_versioning.web]

  rule {
    id     = "expire-noncurrent-web-assets"
    status = "Enabled"
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = var.multipart_abort_days
    }
  }
}
